-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0032 · a profile exists from the moment the account does
--
-- THE BUG THIS FIXES, which had two faces:
--
--   profiles rows were only ever created by df20_ensure_profile(), and that
--   runs on create_room / join_room / save_* — things a person DOES. Signing
--   up created an auth.users row and nothing else. So an account that signed
--   up and went straight to checkout had no profile, and:
--
--     · admin_list_profiles reads profiles, so it never saw them
--     · df20_apply_billing_event looks the buyer up in profiles, found
--       nothing, returned {matched:false} and wrote NOTHING — Stripe took
--       the money and the grant silently never happened
--
-- The trigger is the real fix. The backfill catches everyone already in that
-- state. The webhook change is belt and braces: taking money and writing
-- nothing is the one failure this system must not have, so it now creates the
-- profile itself rather than shrugging, and records a failure when it truly
-- cannot identify the buyer.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. every new account gets a profile, immediately ──────────────────────
create or replace function public.df20_on_auth_user_created()
returns trigger language plpgsql security definer
set search_path = public, pg_temp as $$
begin
  insert into public.profiles (id, email, handle)
  values (new.id, new.email, public.df20_gen_handle())
  on conflict (id) do nothing;
  return new;
exception when others then
  -- a profile that cannot be written must never block the signup itself;
  -- df20_ensure_profile() still backstops on the next authenticated action
  return new;
end $$;

drop trigger if exists df20_on_auth_user_created on auth.users;

do $$
begin
  create trigger df20_on_auth_user_created
    after insert on auth.users
    for each row execute function public.df20_on_auth_user_created();
  raise notice 'trigger installed: every new account now gets a profile row';
exception when insufficient_privilege then
  raise exception
    'DF20_TRIGGER_DENIED: could not create the trigger on auth.users. Run this '
    'migration from the Supabase SQL editor (which runs as postgres), not from '
    'a pooled application connection.';
end $$;

-- ── 2. everyone already stranded without one ──────────────────────────────
do $$
declare v_n int;
begin
  insert into public.profiles (id, email, handle)
  select u.id, u.email, public.df20_gen_handle()
    from auth.users u
    left join public.profiles p on p.id = u.id
   where p.id is null
  on conflict (id) do nothing;
  get diagnostics v_n = row_count;
  raise notice 'backfilled % account(s) that had no profile row', v_n;
end $$;

-- any profile that predates the handle column still needs one
update public.profiles
   set handle = public.df20_gen_handle()
 where handle is null;

-- ── 3. the webhook stops being able to fail silently ──────────────────────
create or replace function public.df20_apply_billing_event(
  p_secret          text,
  p_event_id        text,
  p_user_id         uuid,
  p_customer_id     text,
  p_subscription_id text,
  p_status          text,
  p_premium_until   timestamptz,
  p_source          text,
  p_extend_hours    int default null
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_expected text; v_id uuid; v_until timestamptz; v_rows int;
begin
  select value into v_expected from public.df20_config where key = 'billing_write_secret';
  if v_expected is null or p_secret is null or p_secret <> v_expected then
    raise exception 'DF20_NOT_AUTHORISED';
  end if;

  if p_source is not null and p_source not in
     ('stripe_subscription','admin_grant','game_night_pass') then
    raise exception 'DF20_BAD_SOURCE';
  end if;

  if p_user_id is not null then
    select id into v_id from public.profiles where id = p_user_id;
  end if;
  if v_id is null and p_customer_id is not null then
    select id into v_id from public.profiles where stripe_customer_id = p_customer_id;
  end if;

  -- Checkout carried a real account id but no profile row exists for it.
  -- Create it: somebody has paid, and refusing to record that because a row
  -- is missing is how money goes missing.
  if v_id is null and p_user_id is not null
     and exists (select 1 from auth.users u where u.id = p_user_id) then
    insert into public.profiles (id, email, handle)
    select u.id, u.email, public.df20_gen_handle()
      from auth.users u where u.id = p_user_id
    on conflict (id) do nothing;
    select id into v_id from public.profiles where id = p_user_id;
  end if;

  if v_id is null then
    -- genuinely cannot tell who paid. Record it so it surfaces in the console
    -- instead of vanishing into a 200 nobody reads.
    if p_event_id is not null then
      insert into public.billing_events (event_id, kind, status, detail)
      values (p_event_id, coalesce(p_source, 'stripe'), 'failed',
              'no profile matched: user_id=' || coalesce(p_user_id::text, 'null')
              || ' customer=' || coalesce(p_customer_id, 'null'))
      on conflict (event_id) do update
        set status = 'failed', detail = excluded.detail, processed_at = now();
    end if;
    return jsonb_build_object('matched', false);
  end if;

  if p_event_id is not null then
    insert into public.billing_events (event_id, kind)
    values (p_event_id, coalesce(p_source, 'stripe'))
    on conflict (event_id) do nothing;
    get diagnostics v_rows = row_count;
    if v_rows = 0 then
      return jsonb_build_object('matched', true, 'duplicate', true);
    end if;
  end if;

  if p_extend_hours is not null then
    select greatest(coalesce(premium_until, now()), now())
             + make_interval(hours => p_extend_hours)
      into v_until from public.profiles where id = v_id;
  else
    v_until := p_premium_until;
  end if;

  update public.profiles
     set premium_until          = coalesce(v_until, premium_until),
         premium_source         = coalesce(p_source, premium_source),
         subscription_status    = coalesce(p_status, subscription_status),
         stripe_customer_id     = coalesce(p_customer_id, stripe_customer_id),
         stripe_subscription_id = coalesce(p_subscription_id, stripe_subscription_id),
         updated_at             = now()
   where id = v_id;

  return jsonb_build_object('matched', true, 'user_id', v_id,
                            'premium_until', to_jsonb(v_until));
end $$;
revoke all on function public.df20_apply_billing_event(text,text,uuid,text,text,text,timestamptz,text,int)
  from public;
revoke all on function public.df20_apply_billing_event(text,text,uuid,text,text,text,timestamptz,text,int)
  from anon, authenticated;
