export type Phase = "lobby" | "offering" | "bidding" | "complete";
/** How the room is laid out. Chosen at creation and never changed after. */
export type ContentMode = "standard" | "creator";
export type RoomStatus = "lobby" | "live" | "complete" | "abandoned";
export type LotStatus = "offered" | "bidding" | "resolved" | "void";
export type BidAction =
  | "reveal" | "offer_take" | "offer_give" | "discard"
  | "raise" | "pass" | "timeout_pass" | "won" | "blocked_win";
export type OfferChoice = "take" | "give" | "discard";

export interface Room {
  id: string;
  code: string;
  title: string;
  status: RoomStatus;
  phase: Phase;
  roster_size: number;
  starting_bankroll_cents: number;
  min_bid_cents: number;
  gives_per_player: number;
  /** 0 means NO LIMIT: the window stays open until somebody acts. */
  timer_seconds: number;
  content_mode: ContentMode;
  is_private: boolean;
  brand_accent: string | null;
  brand_logo_url: string | null;
  host_profile_id: string | null;
  opener_seat: number;
  version: number;
  created_at: string;
  started_at: string | null;
  completed_at: string | null;
  /** set only when somebody left mid-draft; see leave_room in 0026 */
  abandoned_by: string | null;
  abandoned_at: string | null;
}

export interface Player {
  id: string;
  room_id: string;
  seat: number;
  display_name: string;
  bankroll_cents: number;
  is_host: boolean;
  profile_id: string | null;
  gives_used: number;
  last_seen_at: string;
  created_at: string;
  /* computed server-side */
  open_slots: number;
  max_legal_bid_cents: number;
  is_broke: boolean;
  gives_left: number;
}

export interface RosterEntry {
  id: string;
  room_id: string;
  player_id: string;
  pick_number: number;
  nfl_player_id: number | null;
  item_name: string;
  price_cents: number;
  gifted: boolean;
  won_at: string;
}

export interface Lot {
  id: string;
  room_id: string;
  nfl_player_id: number | null;
  item_name: string;
  opener_player_id: string | null;
  status: LotStatus;
  current_bid_cents: number;
  high_bidder_player_id: string | null;
  on_the_clock_player_id: string | null;
  turn_expires_at: string | null;
  turn_seq: number;
  winner_player_id: string | null;
  final_price_cents: number | null;
  gifted: boolean;
  created_at: string;
  resolved_at: string | null;
}

export interface BidEvent {
  id: number;
  room_id: string;
  lot_id: string;
  player_id: string | null;
  action: BidAction;
  amount_cents: number | null;
  turn_seq: number;
  created_at: string;
}

export interface Vote {
  id: string;
  room_id: string;
  voter_player_id: string;
  winner_player_id: string;
  created_at: string;
}

export interface RoomState {
  server_now: string;
  room: Room;
  /** cards still face-down. The order is never sent, only the count. */
  deck_remaining: number;
  players: Player[];
  roster: RosterEntry[];
  lot: Lot | null;
  events: BidEvent[];
  votes: Vote[];
}

/* ── derived helpers ─────────────────────────────────────────────────────── */

export function playerById(s: RoomState, id: string | null | undefined) {
  return s.players.find((p) => p.id === id) ?? null;
}

export function rosterOf(s: RoomState, playerId: string) {
  return s.roster
    .filter((r) => r.player_id === playerId)
    .sort((a, b) => a.pick_number - b.pick_number);
}

export function spentBy(s: RoomState, playerId: string): number {
  return s.roster
    .filter((r) => r.player_id === playerId)
    .reduce((t, r) => t + r.price_cents, 0);
}

/** Busted: finished short, or an impossible money state. */
export function isBusted(s: RoomState, playerId: string): boolean {
  const p = playerById(s, playerId);
  if (!p) return false;
  if (p.bankroll_cents < 0) return true;
  if (spentBy(s, playerId) > s.room.starting_bankroll_cents) return true;
  return s.room.status === "complete" && p.open_slots > 0;
}
