#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# DraftFor20 · concurrency proof
#
# Two clients fire place_bid at the same moment against the same board state.
# The room-row lock must serialize them, and the second must be rejected once
# it re-reads what the first one committed. Nothing here is mocked: it runs
# the real RPCs through two separate database sessions.
#
#   usage:  ./race.sh "postgresql://user:pass@host:5432/postgres"
# ═══════════════════════════════════════════════════════════════════════════
set -u
DB="${1:?pass a libpq connection string}"
q() { psql "$DB" -v ON_ERROR_STOP=1 -tAc "$1" || { echo "SEED FAILED: $1" >&2; exit 1; }; }

echo "── seeding a room in mid-bid ──"
SEED=$(q "
  with h as (select public.create_room('RACE TEST', 3, 2000, 100, 60, 'Ari', true, 2) j),
       g as (select public.join_room((select j->>'code' from h), 'Bo') j)
  select (select j->>'code' from h) || ' ' || (select j->>'session_token' from h)
                                    || ' ' || (select j->>'session_token' from g);")
read -r CODE HT GT <<< "$SEED"
q "select public.start_draft('$CODE','$HT');" > /dev/null
# the deck deals a card into 'offering'; the opener takes it at the minimum,
# which is what puts the opponent on the clock and opens the bidding
OPENER=$(q "select case when p.seat=1 then 'H' else 'G' end
              from public.lots l
              join public.players p on p.id = l.opener_player_id
              join public.rooms r on r.id = l.room_id
             where r.code='$CODE' and l.status='offered';")
if [ "$OPENER" = "H" ]; then OTOK="$HT"; else OTOK="$GT"; fi
q "select public.offer_decide('$CODE','$OTOK','take');" > /dev/null
SEQ=$(q "select turn_seq from public.lots l join public.rooms r on r.id=l.room_id
          where r.code='$CODE' and l.status='bidding';")
ONCLOCK=$(q "select case when p.seat=1 then 'H' else 'G' end
               from public.lots l
               join public.players p on p.id = l.on_the_clock_player_id
               join public.rooms r on r.id = l.room_id
              where r.code='$CODE' and l.status='bidding';")
if [ "$ONCLOCK" = "H" ]; then A_TOK="$HT"; B_TOK="$GT"; else A_TOK="$GT"; B_TOK="$HT"; fi
echo "room $CODE, opened at the minimum, on the clock at turn_seq=$SEQ"

FAIL=0

echo
echo "── RACE 1 · both players tap at the same instant ─────────────────────"
echo "   Bo raises to \$6 and holds the lock; Ari fires a \$7 raise built"
echo "   against turn_seq=$SEQ, the board as it looked before Bo moved."
psql "$DB" -tAc "begin; select public.place_bid('$CODE','$A_TOK',600,$SEQ); select pg_sleep(2); commit;" \
  > /tmp/df20_race_a.log 2>&1 &
A=$!
sleep 0.4
psql "$DB" -tAc "select public.place_bid('$CODE','$B_TOK',700,$SEQ);" > /tmp/df20_race_b.log 2>&1
B=$?
wait $A

SAID=$(grep -o 'DF20_[A-Z_]*' /tmp/df20_race_b.log | head -1)
echo "   Ari was rejected with: ${SAID:-<accepted>}"
FINAL=$(q "select current_bid_cents || ' ' || turn_seq from public.lots l
             join public.rooms r on r.id=l.room_id
            where r.code='$CODE' and l.status='bidding';")
read -r BID NEWSEQ <<< "$FINAL"
echo "   standing bid \$$((BID/100)), turn_seq $NEWSEQ"

[ "$B" -eq 0 ]       && { echo "   FAIL: the stale bid was accepted"; FAIL=1; }
[ "$SAID" != "DF20_STALE" ] && { echo "   FAIL: expected DF20_STALE, got ${SAID:-<accepted>}"; FAIL=1; }
[ "$BID" != "600" ]  && { echo "   FAIL: expected \$6 to stand, got $BID"; FAIL=1; }
[ "$NEWSEQ" != "$((SEQ+1))" ] && { echo "   FAIL: turn_seq should advance exactly once, got $NEWSEQ"; FAIL=1; }

echo
echo "── RACE 2 · one player double-taps ───────────────────────────────────"
echo "   Ari raises to \$8 twice at once. The second must not double-charge."
psql "$DB" -tAc "begin; select public.place_bid('$CODE','$B_TOK',800,$((SEQ+1))); select pg_sleep(2); commit;" \
  > /tmp/df20_race_c.log 2>&1 &
C=$!
sleep 0.4
psql "$DB" -tAc "select public.place_bid('$CODE','$B_TOK',900,$((SEQ+1)));" > /tmp/df20_race_d.log 2>&1
D=$?
wait $C
SAID2=$(grep -o 'DF20_[A-Z_]*' /tmp/df20_race_d.log | head -1)
echo "   the duplicate was rejected with: ${SAID2:-<accepted>}"
[ "$D" -eq 0 ] && { echo "   FAIL: the duplicate was accepted"; FAIL=1; }

echo
echo "── invariant sweep ───────────────────────────────────────────────────"
NEG=$(q "select count(*) from public.players p join public.rooms r on r.id=p.room_id
          where r.code='$CODE' and p.bankroll_cents < 0;")
OVER=$(q "select count(*) from (
            select p.id from public.players p join public.rooms r on r.id=p.room_id
             left join public.roster_entries e on e.player_id = p.id
             where r.code='$CODE'
             group by p.id, p.bankroll_cents, r.starting_bankroll_cents
            having coalesce(sum(e.price_cents),0) + p.bankroll_cents
                   <> r.starting_bankroll_cents) x;")
echo "   negative bankrolls: $NEG    books that do not balance: $OVER"
[ "$NEG" != "0" ]  && { echo "   FAIL: a bankroll went negative"; FAIL=1; }
[ "$OVER" != "0" ] && { echo "   FAIL: spend + leftover no longer equals the starting bankroll"; FAIL=1; }

q "delete from public.rooms where code='$CODE';" > /dev/null
echo
[ "$FAIL" -eq 0 ] && echo "PASS  concurrent actions serialize, stale submissions are refused" || exit 1
