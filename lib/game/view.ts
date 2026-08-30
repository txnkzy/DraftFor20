import type { Phase, RoomState } from "./types";
import { playerById } from "./types";

/**
 * Player identity uses gold and bone, never coral or teal. Those two carry
 * game state (tension / resolved) and would stop reading as state the moment
 * they also meant "this is Bo".
 */
export function seatAccent(seat: number): string {
  return seat === 1 ? "var(--color-gold)" : "var(--color-ink)";
}

export interface BoardPlayerView {
  id: string;
  seat: number;
  name: string;
  bankrollCents: number;
  maxLegalBidCents: number;
  openSlots: number;
  filled: number;
  total: number;
  isBroke: boolean;
  isHost: boolean;
  givesLeft: number;
}

export interface BoardView {
  title: string;
  phase: Phase;
  /** the revealed card. Nothing is known about who is next. */
  itemName: string | null;
  /** the revealed card's picture, or null to draw one from the name */
  imageUrl: string | null;
  currentBidCents: number;
  highBidderSeat: number | null;
  onClockSeat: number | null;
  openerSeat: number | null;
  deckRemaining: number;
  startingCents: number;
  minBidCents: number;
  timerSeconds: number;
  /** true when the room was created with no countdown at all */
  noClock: boolean;
  fraction: number;
  seconds: number | null;
  urgent: boolean;
  /** final three seconds: the clock pulses rather than merely counting */
  critical: boolean;
  players: BoardPlayerView[];
  lotId: string | null;
  lastLock: {
    seat: number;
    itemName: string;
    priceCents: number;
    gifted: boolean;
    forced: boolean;
    lotId: string;
  } | null;
}

export function buildBoardView(
  s: RoomState,
  cd: { fraction: number; seconds: number | null; urgent: boolean; critical?: boolean },
): BoardView {
  const total = s.room.roster_size;
  const lot = s.lot;
  const live = lot && (lot.status === "offered" || lot.status === "bidding") ? lot : null;
  const resolved = lot && lot.status === "resolved" ? lot : null;
  const seatOf = (id: string | null | undefined) => playerById(s, id)?.seat ?? null;

  return {
    title: s.room.title,
    phase: s.room.phase,
    itemName: live?.item_name ?? null,
    imageUrl: live?.image_url ?? null,
    currentBidCents: live?.current_bid_cents ?? 0,
    highBidderSeat: seatOf(live?.high_bidder_player_id),
    onClockSeat: seatOf(live?.on_the_clock_player_id),
    openerSeat: seatOf(live?.opener_player_id),
    deckRemaining: s.deck_remaining,
    startingCents: s.room.starting_bankroll_cents,
    minBidCents: s.room.min_bid_cents,
    timerSeconds: s.room.timer_seconds,
    noClock: s.room.timer_seconds === 0,
    fraction: cd.fraction,
    seconds: cd.seconds,
    urgent: cd.urgent,
    critical: Boolean(cd.critical),
    lotId: live?.id ?? null,
    players: s.players.map((p) => ({
      id: p.id,
      seat: p.seat,
      name: p.display_name,
      bankrollCents: p.bankroll_cents,
      maxLegalBidCents: p.max_legal_bid_cents,
      openSlots: p.open_slots,
      filled: total - p.open_slots,
      total,
      isBroke: p.is_broke,
      isHost: p.is_host,
      givesLeft: p.gives_left,
    })),
    lastLock:
      resolved && resolved.winner_player_id
        ? {
            seat: seatOf(resolved.winner_player_id) ?? 1,
            itemName: resolved.item_name,
            priceCents: resolved.final_price_cents ?? 0,
            gifted: resolved.gifted,
            forced: resolved.forced,
            lotId: resolved.id,
          }
        : null,
  };
}
