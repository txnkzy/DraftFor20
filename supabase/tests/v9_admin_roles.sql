-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · v9 · admin as a role, and the public handle
--
-- The assertions that matter: an admin panel cannot be used to lock every
-- admin out of the admin panel, and hiding the button is not the check.
-- ═══════════════════════════════════════════════════════════════════════════

insert into auth.users (id, email, email_confirmed_at) values
  ('d0000000-0000-4000-8000-00000000000a', 'v9a@example.com', now()),
  ('d0000000-0000-4000-8000-00000000000b', 'v9b@example.com', now()),
  ('d0000000-0000-4000-8000-00000000000c', 'v9c@example.com', now())
on conflict (id) do update set email_confirmed_at = now();

do $t$
declare
  A uuid := 'd0000000-0000-4000-8000-00000000000a';
  B uuid := 'd0000000-0000-4000-8000-00000000000b';
  C uuid := 'd0000000-0000-4000-8000-00000000000c';
  v jsonb; v_err text; v_n int; v_h text; v_h2 text;
begin
  -- a clean slate: no admins from any source
  delete from public.df20_config where key = 'admin_user_ids';
  update public.profiles set is_admin = false where is_admin;
  delete from public.admin_audit;

  insert into public.profiles (id, email, handle) values
    (A, 'v9a@example.com', public.df20_gen_handle()),
    (B, 'v9b@example.com', public.df20_gen_handle()),
    (C, 'v9c@example.com', public.df20_gen_handle())
  on conflict (id) do update set email = excluded.email;
  update public.profiles set handle = public.df20_gen_handle()
   where id in (A,B,C) and handle is null;

  -- ── 1. handles are present, unique and not the email ───────────────────
  select handle into v_h  from public.profiles where id = A;
  select handle into v_h2 from public.profiles where id = B;
  assert v_h is not null and v_h2 is not null, 'every account gets a handle';
  assert v_h <> v_h2, 'handles are unique';
  assert v_h !~ '@', 'a handle is not an email address';
  assert v_h ~ '^[a-z0-9]{8}$', 'generated handles are 8 unambiguous characters, got ' || v_h;
  select count(distinct lower(handle)) into v_n from public.profiles where handle is not null;
  assert v_n = (select count(*) from public.profiles where handle is not null),
    'no two accounts share a handle';
  raise notice 'PASS  handles: minted, unique, not an email';

  -- ── 2. nobody is an admin, and a non-admin cannot make one ─────────────
  set local request.jwt.claim.sub = 'd0000000-0000-4000-8000-00000000000b';
  assert public.df20_is_admin() = false, 'a fresh account is not an admin';

  v_err := null;
  begin perform public.admin_set_admin(C, true);
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_NOT_AUTHORISED%',
    'a non-admin must be refused BY THE SERVER, got: ' || coalesce(v_err, 'accepted');
  raise notice 'PASS  the grant is refused server-side, not just hidden in the UI';

  -- ── 3. an admin can grant, and it is written down ──────────────────────
  update public.profiles set is_admin = true where id = A;
  set local request.jwt.claim.sub = 'd0000000-0000-4000-8000-00000000000a';
  assert public.df20_is_admin(), 'A is an admin';

  v := public.admin_set_admin(B, true);
  assert (v->>'is_admin')::boolean, 'B was granted';
  assert (select is_admin from public.profiles where id = B), 'and it stuck';
  assert exists (select 1 from public.admin_audit
                  where actor_id = A and target_id = B and action = 'admin_granted'),
    'the grant is in the audit trail';
  raise notice 'PASS  grant works and is logged with actor, target and time';

  -- ── 4. THE LAST ADMIN CANNOT BE REMOVED ────────────────────────────────
  assert public.df20_admin_count() = 2, 'two admins right now';
  v := public.admin_set_admin(A, false);          -- A steps down, B remains
  assert (v->>'is_admin')::boolean = false, 'A was revoked';
  assert public.df20_admin_count() = 1, 'one admin left';

  set local request.jwt.claim.sub = 'd0000000-0000-4000-8000-00000000000b';
  v_err := null;
  begin perform public.admin_set_admin(B, false);  -- the last one tries to leave
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_LAST_ADMIN%',
    'the final admin must not be removable, got: ' || coalesce(v_err, 'accepted');
  assert public.df20_admin_count() = 1, 'and nothing changed';
  raise notice 'PASS  the app can never be left with zero admins';

  -- ── 5. revoking clears the LEGACY config source too ────────────────────
  -- a uuid left in df20_config would silently re-grant on the next check
  insert into public.df20_config (key, value) values ('admin_user_ids', C::text)
  on conflict (key) do update set value = excluded.value;
  set local request.jwt.claim.sub = 'd0000000-0000-4000-8000-00000000000c';
  assert public.df20_is_admin(), 'the legacy config row still grants admin';

  set local request.jwt.claim.sub = 'd0000000-0000-4000-8000-00000000000b';
  perform public.admin_set_admin(C, false);
  set local request.jwt.claim.sub = 'd0000000-0000-4000-8000-00000000000c';
  assert public.df20_is_admin() = false,
    'revoking must clear the config row as well, or admin comes straight back';
  raise notice 'PASS  revoke clears both the column and the legacy config row';

  -- ── 6. handle validation ───────────────────────────────────────────────
  set local request.jwt.claim.sub = 'd0000000-0000-4000-8000-00000000000a';
  v := public.set_my_handle('Ari_Draft');
  assert v->>'handle' = 'ari_draft', 'handles are lowercased';

  v_err := null;
  begin perform public.set_my_handle('no spaces here');
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_BAD_HANDLE%', 'spaces refused';

  v_err := null;
  begin perform public.set_my_handle('admin');
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_RESERVED_HANDLE%', 'impersonating the service refused';

  set local request.jwt.claim.sub = 'd0000000-0000-4000-8000-00000000000b';
  v_err := null;
  begin perform public.set_my_handle('ari_draft');
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_HANDLE_TAKEN%', 'a taken handle is refused';
  raise notice 'PASS  handle validation: format, reserved words, uniqueness';

  -- ── cleanup ────────────────────────────────────────────────────────────
  delete from public.admin_audit;
  delete from public.df20_config where key = 'admin_user_ids';
  update public.profiles set is_admin = false where id in (A,B,C);
  delete from public.profiles where id in (A,B,C);

  raise notice '───────────────────────────────────────────────';
  raise notice 'v9 SUITE PASSED';
end $t$;

reset request.jwt.claim.sub;
