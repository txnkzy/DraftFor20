/**
 * The money rules, mirrored from supabase/migrations/0003_functions.sql.
 *
 * THIS FILE IS A UI HINT ONLY. It exists so the bid stepper can clamp itself
 * and the Rail can draw the reserved zone. The Postgres copy is the authority
 * and re-validates every submission against freshly read state. If the two
 * ever disagree, the server wins and the client is wrong.
 */

/** Money reserved to cover the minimum bid on every OTHER unfilled slot. */
export function reserveCents(minBidCents: number, openSlots: number): number {
  if (openSlots <= 1) return 0;
  return minBidCents * (openSlots - 1);
}

/**
 * Hard Cap and Reserve Rule combined.
 * `openSlots` INCLUDES the slot currently being bid on.
 */
export function maxLegalBid(
  bankrollCents: number,
  minBidCents: number,
  openSlots: number,
): number {
  if (openSlots <= 0) return 0;

  let v = bankrollCents - minBidCents * (openSlots - 1);

  // Underfunded room: the reserve cannot be met at all. Degrade to exactly one
  // minimum bid rather than locking the player out of every legal action.
  if (v < minBidCents) v = bankrollCents >= minBidCents ? minBidCents : 0;

  // HARD CAP. Redundant above, load-bearing when minBidCents is 0.
  return Math.max(Math.min(v, bankrollCents), 0);
}

/** Cannot afford even one minimum bid, and still owes slots. */
export function isBroke(
  bankrollCents: number,
  minBidCents: number,
  openSlots: number,
): boolean {
  return openSlots > 0 && bankrollCents < minBidCents;
}

/** Smallest legal raise over the standing bid. */
export function minRaise(currentBidCents: number, minBidCents: number): number {
  return currentBidCents + Math.max(minBidCents, 1);
}

/** A room where somebody is guaranteed to go broke. Shown as a host warning. */
export function isUnderfunded(
  bankrollCents: number,
  minBidCents: number,
  slotCount: number,
): boolean {
  return bankrollCents < minBidCents * slotCount;
}
