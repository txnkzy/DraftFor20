-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0035 · the indexes a spike needs
--
-- Measured, not guessed. On a 20k-room / 40k-player copy of this schema the
-- plans before these indexes were:
--
--   players by profile_id      Seq Scan, 40,000 rows read to return 60   2.28ms
--   rooms by host_profile_id   Seq Scan, 20,000 rows read to return 25   0.96ms
--   rooms by created_at        Seq Scan                                  2.20ms
--
-- Small numbers on a laptop with warm cache and no concurrency. The problem
-- is the SHAPE: every one is O(table), so they degrade linearly with growth
-- while the request rate is climbing at the same time.
--
-- Where they are on a hot path:
--   players.profile_id       my_profile_stats + my_scouting_report — every
--                            profile page load, twice
--   rooms.host_profile_id    df20_export_style — EVERY results card render,
--                            which is the image a viral post embeds
--   rooms.created_at         admin_activity, fourteen times per page load
--
-- The bid path was already correct: session_token lookup is an index scan on
-- players_token_idx, so the hottest write in the app never needed this.
-- ═══════════════════════════════════════════════════════════════════════════

-- partial: a room with no host account, or an anonymous seat, is not something
-- anybody looks up BY that column
create index if not exists players_profile_idx
  on public.players(profile_id) where profile_id is not null;

create index if not exists rooms_host_profile_idx
  on public.rooms(host_profile_id) where host_profile_id is not null;

create index if not exists rooms_created_idx
  on public.rooms(created_at);

-- the tally is the viral query: one room, thousands of rows, aggregated on
-- every spectator poll. Covering (room_id, winner_player_id) lets it group
-- without touching the heap.
create index if not exists audience_votes_tally_idx
  on public.audience_votes(room_id, winner_player_id);

-- admin_activity counts by status; cheap to serve from an index
create index if not exists rooms_status_idx
  on public.rooms(status) where code is not null;
