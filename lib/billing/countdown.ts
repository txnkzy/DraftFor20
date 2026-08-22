/**
 * "23h 41m" — how long is left on a pass or a subscription period.
 *
 * Pure, and deliberately kept out of the component: reading the clock is
 * impure, so the component may only call this from an interval, and keeping
 * it here means the formatting can be tested without mounting anything.
 *
 * Returns null once the deadline has passed, so a lapsed pass renders nothing
 * rather than a negative clock.
 */
export function remaining(until: string, now: number = Date.now()): string | null {
  const ms = Date.parse(until) - now;
  if (!Number.isFinite(ms) || ms <= 0) return null;

  const h = Math.floor(ms / 3_600_000);
  const m = Math.floor((ms % 3_600_000) / 60_000);
  const s = Math.floor((ms % 60_000) / 1000);
  if (h >= 24) return `${Math.floor(h / 24)}d ${h % 24}h`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m ${s}s`;
}
