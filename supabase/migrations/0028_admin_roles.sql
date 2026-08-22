-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0028 · admin as a role, not a config string
--
-- Admin has been a comma-separated list of uuids in df20_config since 0019.
-- That was fine for one person editing a table by hand and is wrong for a UI
-- toggle: string surgery to revoke, no way to count admins, nowhere to record
-- who did it.
--
-- This moves the truth to profiles.is_admin and BACKFILLS from the config row
-- — a backfill that is safe precisely because the source is known and exact,
-- unlike the provenance column in 0027 which was left null for that reason.
--
-- df20_is_admin() accepts EITHER source afterwards. That is deliberate: if the
-- backfill misses for any reason, the operator is not locked out of the panel
-- that grants admin, which is the one lockout with no way back.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.profiles
  add column if not exists is_admin boolean not null default false;

-- carry the existing admins across
update public.profiles p
   set is_admin = true
  from public.df20_config c,
       lateral unnest(string_to_array(c.value, ',')) u
 where c.key = 'admin_user_ids'
   and btrim(u) = p.id::text
   and p.is_admin = false;

create index if not exists profiles_is_admin_idx on public.profiles(id) where is_admin;

-- ── a permission this sensitive gets a paper trail ────────────────────────
-- Nothing general-purpose existed to log into: billing_events is billing.
-- Five columns is not new infrastructure, and "who made whom an admin" is not
-- a question to answer from memory.
create table if not exists public.admin_audit (
  id         bigserial primary key,
  actor_id   uuid references public.profiles(id) on delete set null,
  action     text not null,
  target_id  uuid references public.profiles(id) on delete set null,
  detail     text,
  at         timestamptz not null default now()
);
create index if not exists admin_audit_at_idx on public.admin_audit(at desc);
alter table public.admin_audit enable row level security;
revoke all on public.admin_audit from anon, authenticated;

-- ── either source counts ──────────────────────────────────────────────────
create or replace function public.df20_is_admin()
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select (select auth.uid()) is not null
     and (
       exists (select 1 from public.profiles p
                where p.id = (select auth.uid()) and p.is_admin)
       or exists (select 1 from public.df20_config c,
                       lateral unnest(string_to_array(c.value, ',')) u
                   where c.key = 'admin_user_ids'
                     and btrim(u) = (select auth.uid())::text)
     )
$$;
grant execute on function public.df20_is_admin() to anon, authenticated;

-- how many admins would remain if this one were removed
create or replace function public.df20_admin_count()
returns int language sql stable security definer
set search_path = public, pg_temp as $$
  select count(distinct id)::int from (
    select p.id from public.profiles p where p.is_admin
    union
    select p.id from public.profiles p, public.df20_config c,
           lateral unnest(string_to_array(c.value, ',')) u
     where c.key = 'admin_user_ids' and btrim(u) = p.id::text
  ) s
$$;
revoke all on function public.df20_admin_count() from anon, authenticated;

-- ── grant and revoke ──────────────────────────────────────────────────────
create or replace function public.admin_set_admin(p_user_id uuid, p_grant boolean)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_actor uuid; v_target public.profiles; v_remaining int; v_legacy boolean;
begin
  -- server-side, because hiding a button is not a permission check
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;
  v_actor := auth.uid();

  select * into v_target from public.profiles where id = p_user_id for update;
  if not found then raise exception 'DF20_NO_SUCH_USER'; end if;

  if coalesce(p_grant, false) then
    update public.profiles set is_admin = true, updated_at = now() where id = p_user_id;
    insert into public.admin_audit (actor_id, action, target_id, detail)
    values (v_actor, 'admin_granted', p_user_id, v_target.email);
    return jsonb_build_object('user_id', p_user_id, 'is_admin', true);
  end if;

  -- THE LAST ADMIN CANNOT BE REMOVED. An app with zero admins has no way
  -- back in through its own UI; the only repair is a hand-edit in the
  -- Supabase table editor, which is exactly what this feature replaced.
  v_remaining := public.df20_admin_count();
  if v_remaining <= 1 then
    raise exception 'DF20_LAST_ADMIN';
  end if;

  update public.profiles set is_admin = false, updated_at = now() where id = p_user_id;

  -- a uuid left in the legacy config row would silently re-grant on the next
  -- df20_is_admin() call, so revoking has to clear both sources
  select exists (select 1 from public.df20_config c,
                      lateral unnest(string_to_array(c.value, ',')) u
                  where c.key = 'admin_user_ids' and btrim(u) = p_user_id::text)
    into v_legacy;
  if v_legacy then
    update public.df20_config
       set value = coalesce((select string_agg(btrim(u), ',')
                               from unnest(string_to_array(value, ',')) u
                              where btrim(u) <> p_user_id::text and btrim(u) <> ''), '')
     where key = 'admin_user_ids';
    -- string_agg over an empty set is NULL, and value is NOT NULL. Removing
    -- the only listed uuid therefore has to remove the row, which is also the
    -- documented "row absent means nobody is an admin" state rather than an
    -- empty string nobody expects.
    delete from public.df20_config where key = 'admin_user_ids' and btrim(value) = '';
  end if;

  insert into public.admin_audit (actor_id, action, target_id, detail)
  values (v_actor, 'admin_revoked', p_user_id,
          v_target.email || case when v_legacy then ' (also cleared from df20_config)' else '' end);

  return jsonb_build_object('user_id', p_user_id, 'is_admin', false);
end $$;
grant execute on function public.admin_set_admin(uuid, boolean) to authenticated;

-- ── the audit trail, readable by admins ───────────────────────────────────
create or replace function public.admin_audit_log(p_limit int default 50)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'at', a.at, 'action', a.action, 'detail', a.detail,
             'actor', (select coalesce(x.display_name, x.email, x.id::text)
                         from public.profiles x where x.id = a.actor_id),
             'target', (select coalesce(x.display_name, x.email, x.id::text)
                          from public.profiles x where x.id = a.target_id))
           order by a.at desc)
      from (select * from public.admin_audit
             order by at desc
             limit least(greatest(coalesce(p_limit, 50), 1), 200)) a), '[]'::jsonb);
end $$;
grant execute on function public.admin_audit_log(int) to authenticated;

