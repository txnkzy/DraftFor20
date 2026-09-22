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
  # NEVER REGISTERED until 20 Sep. All four were applied to the live database
  # by hand and left out of the bundle, so APPLY_V7.sql built a database
  # missing the activity funnel, the live-means-live sweep, the restored
  # server grants and the billing detail. A migration that is not in this
  # list does not exist as far as a fresh install is concerned.
  0052_activity_funnel 0053_live_means_live 0054_restore_server_grants
  0056_billing_detail
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
  0057_usernames_and_leaderboard
  0058_username_word_filter
  0060_abandon_stale_rooms
  0061_one_free_lookup
  0062_daily_finished
  # AFTER 0057: the profanity trigger guards profiles.handle, and that column
  # only becomes user-chosen in 0057. Applied before it, the trigger would
  # reference handle_chosen before the column exists.
  #
  0063_clean_names
  0064_quick_play
  # AFTER 0063: it folds that file's list into 0058's tables and then DROPS
  # df20_profanity. Run before 0063 and it would seed from a table that does
  # not exist yet, then delete the one 0063 is about to create.
  0066_one_word_filter
  0067_quick_play_cap
  # THE TIMESTAMPED FILES. A second naming scheme arrived with the Supabase
  # CLI; they sort after the numbered ones by name, which is also the order
  # they were written in.
  #
  # growth_metrics AFTER 0062_daily_finished: both define admin_activity and
  # the later one wins. The live database is running growth_metrics' version,
  # so this order is what reproduces production rather than quietly reverting
  # the admin dashboard to an older query.
  20260920041909_growth_metrics
  20260920134132_room_scouting_and_head_to_head
  # AFTER 0041_allow_broke: it restates df20_public_state to add the derived
  # rematch_code. Run it before and the field disappears, and "Run it back"
  # goes back to being a button that cannot find the room it made.
  20260920134315_rematch
  20260920135142_football_draft_recognisable
  # AFTER the rematch file, which it restates create_rematch from.
  0068_rematch_same_category
  # AFTER 0067, which is where df20_solo_quota is defined: this one
  # restates it to count lineups alongside solo rooms. Applied before it,
  # the older body wins and the daily cap silently stops seeing lineups.
  0069_lineups
  # ABSOLUTELY LAST. Four files define offer_decide and three of them have no
  # force branch, so whichever runs last wins. This one restores it. Lost
  # twice already — 8 Sep (12 days, ~550 dead drafts) and again on 20 Sep
  # within two hours of being fixed. Do not move it.
  0065_restore_force_or_take
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
