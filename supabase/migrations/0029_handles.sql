-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0029 · a public handle that is not an email address
--
-- profiles.email is the login credential and has been standing in as the
-- display identity, which means any surface that names an account leaks one.
-- This adds a handle that is safe to show.
--
-- GENERATED, NOT CHOSEN, at creation. A chosen handle needs a uniqueness
-- check inside the signup flow, a taken-name error state, and a decision
-- about what happens when someone abandons signup halfway — for a value whose
-- only job today is "something to display instead of an email". Everyone gets
-- one immediately, and set_my_handle() lets anyone who cares pick their own
-- afterwards, with the validation in one place rather than in the signup path.
--
-- admin_list_profiles is redefined HERE, not in 0028, because it reads this
-- column: a caller and its dependency in different files is the failure 0013
-- exists to prevent.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.profiles
  add column if not exists handle text;

create unique index if not exists profiles_handle_idx
  on public.profiles(lower(handle)) where handle is not null;

-- no i/l/o/0/1: a handle gets read aloud and typed back in
create or replace function public.df20_gen_handle()
returns text language plpgsql security definer
set search_path = public, pg_temp as $$
declare a text := 'abcdefghjkmnpqrstuvwxyz23456789'; v text; i int;
begin
  loop
    v := '';
    for i in 1..8 loop
      v := v || substr(a, 1 + floor(random() * length(a))::int, 1);
    end loop;
    exit when not exists (select 1 from public.profiles where lower(handle) = v);
  end loop;
  return v;
end $$;
revoke all on function public.df20_gen_handle() from anon, authenticated;

-- everyone who already has an account gets one now
do $$
declare r record;
begin
  for r in select id from public.profiles where handle is null loop
    update public.profiles set handle = public.df20_gen_handle() where id = r.id;
  end loop;
end $$;

-- ── every new account gets one at creation ────────────────────────────────
-- Same body as 0015 plus the handle. Still never a reason to refuse a room:
-- a handle that cannot be minted leaves the column null rather than raising.
create or replace function public.df20_ensure_profile()
returns uuid language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_uid uuid; v_email text;
begin
  v_uid := auth.uid();
  if v_uid is null then return null; end if;
  begin
    select u.email into v_email from auth.users u where u.id = v_uid;
  exception when others then v_email := null;
  end;

  insert into public.profiles (id, email, handle)
  values (v_uid, v_email, public.df20_gen_handle())
  on conflict (id) do nothing;

  -- an account that predates this column, or one whose insert raced
  update public.profiles set handle = public.df20_gen_handle()
   where id = v_uid and handle is null;

  return v_uid;
end $$;
revoke all on function public.df20_ensure_profile() from anon, authenticated;

-- ── or pick your own ──────────────────────────────────────────────────────
create or replace function public.set_my_handle(p_handle text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_uid uuid; v_h text;
begin
  v_uid := public.df20_ensure_profile();
  if v_uid is null then raise exception 'DF20_SIGNIN_REQUIRED'; end if;

  v_h := lower(btrim(coalesce(p_handle, '')));
  if v_h !~ '^[a-z0-9_-]{3,20}$' then raise exception 'DF20_BAD_HANDLE'; end if;
  -- words that would let one account be mistaken for the service itself
  if v_h ~ '^(admin|administrator|draftfor20|df20|support|help|root|system|mod|moderator|staff|official)$'
    then raise exception 'DF20_RESERVED_HANDLE'; end if;

  if exists (select 1 from public.profiles
              where lower(handle) = v_h and id <> v_uid) then
    raise exception 'DF20_HANDLE_TAKEN';
  end if;

  update public.profiles set handle = v_h, updated_at = now() where id = v_uid;
  return jsonb_build_object('handle', v_h);
end $$;
grant execute on function public.set_my_handle(text) to authenticated;

-- ── the admin table, now with the handle and the admin flag ───────────────
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
               'handle', p.handle, 'created_at', p.created_at,
               'premium_until', p.premium_until,
               'premium_source', p.premium_source,
               'subscription_status', p.subscription_status,
               'active', coalesce(p.premium_until > now(), false),
               'is_admin', p.is_admin,
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
          or lower(coalesce(p.handle, '')) like '%' || v_q || '%'
       order by p.created_at desc
       limit 200) s), '[]'::jsonb);
end $$;
grant execute on function public.admin_list_profiles(text) to authenticated;

-- ── the owner sees their own handle ───────────────────────────────────────
create or replace function public.my_handle()
returns jsonb language sql stable security definer
set search_path = public, pg_temp as $$
  select jsonb_build_object('handle', (select handle from public.profiles
                                        where id = (select auth.uid())))
$$;
grant execute on function public.my_handle() to authenticated;
