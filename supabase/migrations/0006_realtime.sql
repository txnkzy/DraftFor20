-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0006 · realtime
--
-- State is pushed with realtime.send() from inside each RPC's transaction, on
-- channel  room:<room_uuid>  with event "state" and a full public snapshot as
-- the payload. Clients drop any payload whose rooms.version is not greater
-- than the one they hold, so out-of-order delivery cannot rewind the board.
--
-- The channel is public. The room uuid is the capability, which is fine for a
-- game people livestream. Nothing secret is in the payload: df20_public_state
-- strips players.session_token and never reads an unrevealed room_deck row.
-- ═══════════════════════════════════════════════════════════════════════════

do $$
begin
  if to_regprocedure('realtime.send(jsonb, text, text, boolean)') is null then
    raise notice 'realtime.send() not found. Clients fall back to polling get_room_state.';
  else
    raise notice 'realtime.send() present. Broadcast fast path is live.';
  end if;
end $$;
