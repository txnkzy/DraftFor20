-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0031 · the user ID is assigned, not chosen
--
-- 0029 let an account rename its own handle. That is now the wrong shape: it
-- is a USER ID, it identifies the account wherever an email must not appear,
-- and an identifier people can swap around is a poor one — it breaks any
-- reference anybody wrote down.
--
-- Enforced by removing the grant rather than hiding the button, because the
-- anon key is public and set_my_handle was reachable with curl. The function
-- itself stays: it is how an operator fixes a genuinely bad handle from the
-- SQL editor, which is the only place that should be possible.
-- ═══════════════════════════════════════════════════════════════════════════

-- PUBLIC holds EXECUTE on every function by default, so revoking from anon
-- and authenticated alone changes nothing — the privilege comes in through
-- PUBLIC. That default grant is the one that has to go.
revoke all on function public.set_my_handle(text) from public;
revoke all on function public.set_my_handle(text) from anon, authenticated;

comment on function public.set_my_handle(text) is
  'Operator-only since 0031. The handle is a user ID: assigned at signup and '
  'not user-changeable. Callable from the SQL editor to correct one by hand.';
