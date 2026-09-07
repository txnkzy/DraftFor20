-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0056 · who paid, and how much
--
-- billing_events recorded THAT something happened and nothing about what. The
-- console could say a pass was granted; it could not say to whom or for how
-- much, so "did we make anything this month" was a question only Stripe could
-- answer — and Stripe cannot say which DraftFor20 account a payment landed on.
--
-- Three columns and the join becomes possible. profile_id is written at the
-- moment the event is MATCHED, so it names the account that actually received
-- the access rather than an email looked up later and possibly changed since.
--
-- Amounts are stored in the settlement currency Stripe reports, with the code
-- beside them. A $1 pass bought on a UK card settles as 100 usd while Stripe
-- shows the buyer 77p; adding those two numbers together would be arithmetic
-- on different things, so the totals below group by currency rather than
-- pretending there is one.
--
-- The old overload is DROPPED rather than defaulted. A new argument with a
-- DEFAULT leaves both signatures resolvable and makes positional calls
-- ambiguous — the trap 0010 documents and 0041 had to work around already.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.billing_events
  add column if not exists profile_id   uuid references public.profiles(id) on delete set null,
  add column if not exists amount_cents int,
  add column if not exists currency     text;

create index if not exists billing_events_profile_idx
  on public.billing_events (profile_id) where profile_id is not null;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'df20_apply_billing_event'
  loop
    execute 'drop function if exists ' || r.sig;
  end loop;
end $$;

create or replace function public.df20_apply_billing_event(
  p_secret          text,
  p_event_id        text,
  p_user_id         uuid,
  p_customer_id     text,
  p_subscription_id text,
  p_status          text,
  p_premium_until   timestamptz,
  p_source          text,
  p_extend_hours    int,
  p_amount_cents    int,
  p_currency        text
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $BODY$

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
      insert into public.billing_events (event_id, kind, status, detail,
                                         amount_cents, currency)
      values (p_event_id, coalesce(p_source, 'stripe'), 'failed',
              'no profile matched: user_id=' || coalesce(p_user_id::text, 'null')
              || ' customer=' || coalesce(p_customer_id, 'null'),
              p_amount_cents, lower(nullif(p_currency, '')))
      on conflict (event_id) do update
        set status = 'failed', detail = excluded.detail, processed_at = now();
    end if;
    return jsonb_build_object('matched', false);
  end if;

  if p_event_id is not null then
    insert into public.billing_events (event_id, kind, profile_id,
                                       amount_cents, currency)
    values (p_event_id, coalesce(p_source, 'stripe'), v_id,
            p_amount_cents, lower(nullif(p_currency, '')))
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
end 
$BODY$;

revoke all on function public.df20_apply_billing_event(
  text,text,uuid,text,text,text,timestamptz,text,int,int,text) from public;
grant execute on function public.df20_apply_billing_event(
  text,text,uuid,text,text,text,timestamptz,text,int,int,text) to anon;

-- ── the events list, with a name against each line ────────────────────────
create or replace function public.admin_recent_events(p_limit int default 40)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'event_id', e.event_id, 'kind', e.kind, 'status', e.status,
             'detail', e.detail, 'at', e.processed_at,
             'amount_cents', e.amount_cents, 'currency', e.currency,
             -- who it landed on. Null on a failure row is the point: that is
             -- an event we could not tie to anybody.
             'profile_id', e.profile_id,
             'email', p.email,
             'handle', p.handle)
           order by e.processed_at desc)
      from (select * from public.billing_events
             order by processed_at desc
             limit least(greatest(coalesce(p_limit, 40), 1), 200)) e
      left join public.profiles p on p.id = e.profile_id), '[]'::jsonb);
end $$;
grant execute on function public.admin_recent_events(int) to authenticated;

-- ── the money, such as it is ──────────────────────────────────────────────
-- Grouped by currency because they are not addable, and counted only from
-- rows that actually succeeded: a failed event has an amount on it too, and
-- including those would report money that never arrived.
create or replace function public.admin_billing_stats()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;
  return jsonb_build_object(
    'totals', coalesce((
      select jsonb_agg(jsonb_build_object(
               'currency', currency, 'gross_cents', gross, 'payments', n)
             order by gross desc)
        from (select coalesce(currency, 'unknown') as currency,
                     sum(amount_cents) as gross, count(*) as n
                from public.billing_events
               where coalesce(status, 'ok') <> 'failed'
                 and amount_cents is not null and amount_cents > 0
               group by 1) t), '[]'::jsonb),

    'this_month', coalesce((
      select jsonb_agg(jsonb_build_object(
               'currency', currency, 'gross_cents', gross, 'payments', n)
             order by gross desc)
        from (select coalesce(currency, 'unknown') as currency,
                     sum(amount_cents) as gross, count(*) as n
                from public.billing_events
               where coalesce(status, 'ok') <> 'failed'
                 and amount_cents is not null and amount_cents > 0
                 and processed_at >= date_trunc('month', now())
               group by 1) t), '[]'::jsonb),

    'by_kind', coalesce((
      select jsonb_object_agg(kind, n)
        from (select coalesce(kind, 'unknown') as kind, count(*) as n
                from public.billing_events
               where coalesce(status, 'ok') <> 'failed'
               group by 1) k), '{}'::jsonb),

    'paying_accounts', (select count(distinct profile_id)
                          from public.billing_events
                         where profile_id is not null
                           and coalesce(status, 'ok') <> 'failed'
                           and coalesce(amount_cents, 0) > 0),
    'active_now',      (select count(*) from public.profiles where premium_until > now()),
    'subscriptions',   (select count(*) from public.profiles
                         where subscription_status = 'active'),
    'failed_events',   (select count(*) from public.billing_events where status = 'failed'),
    'first_payment',   (select min(processed_at) from public.billing_events
                         where coalesce(amount_cents, 0) > 0
                           and coalesce(status, 'ok') <> 'failed'));
end $$;
grant execute on function public.admin_billing_stats() to authenticated;

notify pgrst, 'reload schema';
