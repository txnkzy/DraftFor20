#!/usr/bin/env bash
# Rebuild the paste-into-the-SQL-Editor bundle from the migrations.
# Additive and re-runnable from any partial state; ends with df20_selfcheck().
set -euo pipefail
cd "$(dirname "$0")"

OUT=APPLY_V7.sql
FILES=(
  0008_hardening 0009_categories 0010_category_rpc 0011_library_seed
  0012_match_tightening 0013_repair_and_selfcheck 0014_more_categories
  0015_signin_gate 0016_email_verified
  0017_profiles 0018_content 0019_billing 0020_selfcheck
  0021_timer 0022_scouting 0023_content_mode 0024_admin 0025_selfcheck
  0026_leave 0027_provenance 0028_admin_roles 0029_handles 0030_verify_gates
  0031_lock_handle 0032_profile_on_signup 0033_premium_line 0034_free_vote
  0035_load_indexes 0036_tally_poll 0037_circuit_breaker 0038_signup_signals
  0039_admin_signals 0040_signal_sanity
  0041_profiles_grant_hardening 0042_write_paths_and_grant_check
  0043_item_images 0044_onepiece 0045_dev_library_preview 0046_anime_categories
  0047_library_genres 0048_revoke_public_execute 0049_sports_categories
  0050_brand_categories 0051_library_pictures
  # NUMBERED 0041 BUT IT RUNS LAST, deliberately. Two files carry that number
  # — 0041_allow_broke and 0041_profiles_grant_hardening — because two people
  # numbered from 0040 at the same time. Ordering by the number would apply a
  # newer game rule before six migrations that postdate it; ordering by INTENT
  # is what matters, and the bundle is what defines apply order.
  0041_allow_broke
  # AFTER 0041_allow_broke, because it restates offer_decide and expire_turn
  # from that file. Swap the two and the Force branch is silently overwritten
  # by the version that has no Force in it — which is the exact shape of the
  # df20_clean_logo_url outage, a caller applied before its dependency.
  0055_force_or_take
)

{
  cat <<'HDR'
-- ═══════════════════════════════════════════════════════════════════════════
--  DraftFor20 v7 · ADDITIVE. Paste into the Supabase SQL Editor and Run.
--  Does NOT drop rooms. Safe to re-run. Ends with df20_selfcheck().
--
--  Built by supabase/build-bundle.sh — edit the migrations, not this file.
-- ═══════════════════════════════════════════════════════════════════════════

HDR
  for f in "${FILES[@]}"; do
    printf '\n-- ─────────── %s.sql ───────────\n\n' "$f"
    cat "migrations/$f.sql"
  done
  cat <<'FTR'

do $$
begin
  raise notice '%', public.df20_selfcheck();
  raise notice '%', public.df20_grant_check();
  raise notice 'free shelf: % categories', jsonb_array_length(public.list_free_categories());
end $$;
FTR
} > "$OUT"

echo "wrote $OUT ($(grep -c '' "$OUT") lines)"
