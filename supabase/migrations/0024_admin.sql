-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0024 · the operator's console
--
-- Scope discipline: this covers things only this app knows. Revenue, MRR and
-- churn live in the Stripe dashboard; query health and table contents live in
-- the Supabase dashboard. Rebuilding either here would be a worse copy that
-- goes stale, so the admin page links out to them instead.
--
-- Every function below refuses everyone unless df20_is_admin() is true, which
-- reads a list of uuids from df20_config that no migration ever creates. With
-- that row absent — which is how this ships — there is no admin.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── the moderation queue exists, so accepting no longer publishes ─────────
do $$ begin
  alter table public.rooms drop constraint rooms_optin_chk;
exception when undefined_object then null; end $$;
alter table public.rooms add constraint rooms_optin_chk
  check (library_optin_state in
         ('none','eligible','ineligible','accepted','declined','pending','rejected'));

-- A host opting in is now a SUBMISSION, not a publication. The items still
-- pass the real-name heuristics first; a human then looks at them before
-- anything reaches a shelf every future room can draw from.
create or replace function public.submit_library_optin(
  p_result_token uuid, p_accept boolean
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_check jsonb;
begin
  select * into v_room from public.rooms where setup_result_token = p_result_token;
  if not found then raise exception 'DF20_NO_ROOM'; end if;

  if not coalesce(p_accept, false) then
    update public.rooms set library_optin_state = 'declined' where id = v_room.id;
    return jsonb_build_object('status','declined');
  end if;

  -- re-run eligibility at submit time; never trust the earlier answer
  v_check := public.offer_library_optin(p_result_token);
  if v_check->>'status' <> 'eligible' then
    return jsonb_build_object('status', v_check->>'status');
  end if;

  update public.rooms set library_optin_state = 'pending' where id = v_room.id;
  return jsonb_build_object('status','pending');
end $$;
grant execute on function public.submit_library_optin(uuid, boolean) to anon, authenticated;

-- ── the queue ─────────────────────────────────────────────────────────────
-- This is the ONE place room_pool items cross the boundary, and it is the
-- whole job: you cannot moderate a list you are not allowed to read. Admins
-- only, capped, and it never touches a room that is still being played.
create or replace function public.admin_library_queue()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'room_id', r.id,
             'category', r.category_name,
             'submitted_at', r.completed_at,
             'item_count', (select count(*) from public.room_pool p where p.room_id = r.id),
             'items', coalesce((select jsonb_agg(p.name order by p.name)
                                  from (select name from public.room_pool
                                         where room_id = r.id order by name limit 200) p),
                               '[]'::jsonb),
             'already_public', exists (
               select 1 from public.category_library l
                where l.name_norm = public.df20_norm_category(r.category_name)))
           order by r.completed_at desc)
      from public.rooms r
     where r.library_optin_state = 'pending'), '[]'::jsonb);
end $$;
grant execute on function public.admin_library_queue() to authenticated;

create or replace function public.admin_review_library(p_room uuid, p_approve boolean)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_id uuid; v_n int;
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;

  select * into v_room from public.rooms where id = p_room for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  if v_room.library_optin_state <> 'pending' then
    return jsonb_build_object('status', v_room.library_optin_state);
  end if;

  if not coalesce(p_approve, false) then
    update public.rooms set library_optin_state = 'rejected' where id = p_room;
    return jsonb_build_object('status','rejected');
  end if;

  insert into public.category_library (name, name_norm)
  values (v_room.category_name, public.df20_norm_category(v_room.category_name))
  on conflict (name_norm) do nothing
  returning id into v_id;

  if v_id is null then
    update public.rooms set library_optin_state = 'rejected' where id = p_room;
    return jsonb_build_object('status','already_exists');
  end if;

  -- name and items only. no room, no player, no timing.
  insert into public.category_library_items (library_id, name)
  select v_id, name from public.room_pool where room_id = p_room
  on conflict do nothing;

  select count(*) into v_n from public.category_library_items where library_id = v_id;
  update public.rooms set library_optin_state = 'accepted' where id = p_room;
  return jsonb_build_object('status','accepted', 'library_id', v_id, 'item_count', v_n);
end $$;
grant execute on function public.admin_review_library(uuid, boolean) to authenticated;

-- ── what is already on the public shelf ───────────────────────────────────
create or replace function public.admin_library_list()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', l.id, 'name', l.name, 'created_at', l.created_at,
             'item_count', (select count(*) from public.category_library_items i
                             where i.library_id = l.id))
           order by l.name)
      from public.category_library l), '[]'::jsonb);
end $$;
grant execute on function public.admin_library_list() to authenticated;

create or replace function public.admin_library_remove(p_id uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_name text;
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;
  select name into v_name from public.category_library where id = p_id;
  if v_name is null then return jsonb_build_object('removed', false); end if;
  -- rooms copy their pool at creation, so pulling a category from the shelf
  -- never disturbs a draft that is already using it
  delete from public.category_library where id = p_id;
  return jsonb_build_object('removed', true, 'name', v_name);
end $$;
grant execute on function public.admin_library_remove(uuid) to authenticated;

-- ── the user table ────────────────────────────────────────────────────────
-- Same signature as 0019, more columns. "last seat" is the last time this
-- account sat down in a room; players.last_seen_at is only ever the row's
-- creation time, so quoting it as live presence would be a lie.
create or replace function public.admin_list_profiles(p_query text default null)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_q text;
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;
  v_q := lower(btrim(coalesce(p_query, '')));

  return coalesce((
    select jsonb_agg(x order by x->>'created_at' desc) from (
      select jsonb_build_object(
               'id', p.id, 'email', p.email, 'display_name', p.display_name,
               'created_at', p.created_at,
               'premium_until', p.premium_until,
               'premium_source', p.premium_source,
               'subscription_status', p.subscription_status,
               'active', coalesce(p.premium_until > now(), false),
               'hosted', (select count(*) from public.rooms r
                           where r.host_profile_id = p.id and r.code is not null
                             and r.status in ('live','complete')),
               'played', (select count(distinct pl.room_id) from public.players pl
                           where pl.profile_id = p.id),
               'last_seat', (select max(pl.created_at) from public.players pl
                              where pl.profile_id = p.id),
               'decks', (select count(*) from public.user_categories c
                          where c.owner_id = p.id)) as x
        from public.profiles p
       where v_q = ''
          or lower(coalesce(p.email, '')) like '%' || v_q || '%'
          or lower(coalesce(p.display_name, '')) like '%' || v_q || '%'
       order by p.created_at desc
       limit 200) s), '[]'::jsonb);
end $$;
grant execute on function public.admin_list_profiles(text) to authenticated;

-- ── activity ──────────────────────────────────────────────────────────────
create or replace function public.admin_activity()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;

  return jsonb_build_object(
    'rooms', jsonb_build_object(
      'total',  (select count(*) from public.rooms where code is not null),
      'today',  (select count(*) from public.rooms
                  where code is not null and created_at >= date_trunc('day', now())),
      'week',   (select count(*) from public.rooms
                  where code is not null and created_at >= now() - interval '7 days'),
      'live',   (select count(*) from public.rooms where status = 'live'),
      'complete',(select count(*) from public.rooms where status = 'complete')),

    -- fourteen days of bars for the chart
    'daily', coalesce((
      select jsonb_agg(jsonb_build_object('day', d::date, 'rooms', n) order by d)
        from (select g.d, (select count(*) from public.rooms r
                            where r.code is not null
                              and r.created_at >= g.d and r.created_at < g.d + interval '1 day') as n
                from generate_series(date_trunc('day', now()) - interval '13 days',
                                     date_trunc('day', now()), interval '1 day') g(d)) s),
      '[]'::jsonb),

    -- the built-in pool against everything else somebody chose
    'categories', jsonb_build_object(
      'football', (select count(*) from public.rooms
                    where code is not null and category_name = 'Football Draft'),
      'other_library', (select count(*) from public.rooms
                         where code is not null and pool_source in ('builtin','library')
                           and coalesce(category_name,'') <> 'Football Draft'),
      'wikipedia', (select count(*) from public.rooms
                     where code is not null and pool_source = 'wikipedia'),
      'manual', (select count(*) from public.rooms
                  where code is not null and pool_source = 'manual'),
      'saved', (select count(*) from public.rooms
                 where code is not null and pool_source = 'saved')),

    'modes', jsonb_build_object(
      'standard', (select count(*) from public.rooms
                    where code is not null and content_mode = 'standard'),
      'creator', (select count(*) from public.rooms
                   where code is not null and content_mode = 'creator')),

    -- Only completed drafts have a duration worth quoting, and the sample
    -- count comes from the SAME subquery as the averages. Two predicates that
    -- can drift apart is how a page ends up claiming an average over two
    -- drafts and then showing no average.
    'duration', (
      select jsonb_build_object(
               'sample', count(*),
               'avg_seconds', round(avg(secs)),
               'median_seconds', round(percentile_cont(0.5) within group (order by secs)))
        from (select extract(epoch from (completed_at - started_at)) as secs
                from public.rooms
               where status = 'complete'
                 and started_at is not null and completed_at is not null
                 and completed_at > started_at
                 and completed_at - started_at < interval '12 hours') d),

    'library', jsonb_build_object(
      'public', (select count(*) from public.category_library),
      'pending', (select count(*) from public.rooms where library_optin_state = 'pending'),
      'saved_decks', (select count(*) from public.user_categories)),

    'audience', jsonb_build_object(
      'votes', (select count(*) from public.audience_votes),
      'rooms_voted_on', (select count(distinct room_id) from public.audience_votes)),

    'premium', jsonb_build_object(
      'active', (select count(*) from public.profiles where premium_until > now()),
      'by_source', coalesce((select jsonb_object_agg(coalesce(premium_source,'none'), n)
                               from (select premium_source, count(*) as n
                                       from public.profiles
                                      where premium_until > now()
                                      group by premium_source) s), '{}'::jsonb)));
end $$;
grant execute on function public.admin_activity() to authenticated;

-- ── webhook events, including the ones that went wrong ────────────────────
-- billing_events already existed for idempotency. Two columns turn it into
-- the only error surface this app has, which is a fair trade against
-- standing up error tracking nobody asked for. Everything else worth seeing
-- is in Vercel's logs, which the page links to rather than mirrors.
alter table public.billing_events
  add column if not exists status text not null default 'ok',
  add column if not exists detail text;

create or replace function public.df20_log_billing_failure(
  p_secret text, p_event_id text, p_kind text, p_detail text
) returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_expected text;
begin
  select value into v_expected from public.df20_config where key = 'billing_write_secret';
  if v_expected is null or p_secret is null or p_secret <> v_expected then
    raise exception 'DF20_NOT_AUTHORISED';
  end if;

  insert into public.billing_events (event_id, kind, status, detail)
  values (coalesce(nullif(p_event_id, ''), 'unidentified-' || gen_random_uuid()::text),
          left(coalesce(p_kind, 'unknown'), 60), 'failed', left(coalesce(p_detail, ''), 500))
  on conflict (event_id) do update
    set status = 'failed', detail = excluded.detail, processed_at = now();
end $$;
revoke all on function public.df20_log_billing_failure(text,text,text,text) from anon, authenticated;

create or replace function public.admin_recent_events(p_limit int default 40)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'event_id', e.event_id, 'kind', e.kind, 'status', e.status,
             'detail', e.detail, 'at', e.processed_at) order by e.processed_at desc)
      from (select * from public.billing_events
             order by processed_at desc
             limit least(greatest(coalesce(p_limit, 40), 1), 200)) e), '[]'::jsonb);
end $$;
grant execute on function public.admin_recent_events(int) to authenticated;
