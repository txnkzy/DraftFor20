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
  0026_leave
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
  raise notice 'free shelf: % categories', jsonb_array_length(public.list_free_categories());
end $$;
FTR
} > "$OUT"

echo "wrote $OUT ($(grep -c '' "$OUT") lines)"
