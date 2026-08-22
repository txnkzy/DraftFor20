/** Everything in DraftFor20 is integer cents. There are no floats. */

export const DOLLAR = 100;

/** 700 -> "$7"   750 -> "$7.50"   0 -> "$0" */
export function formatCents(cents: number): string {
  const n = Math.round(cents);
  const sign = n < 0 ? "-" : "";
  const abs = Math.abs(n);
  const whole = Math.floor(abs / 100);
  const rem = abs % 100;
  return rem === 0
    ? `${sign}$${whole}`
    : `${sign}$${whole}.${String(rem).padStart(2, "0")}`;
}

/** Same, minus the dollar sign. For the split-flap digits. */
export function digitsOf(cents: number): string {
  return formatCents(cents).replace("$", "");
}

/** "20" | "20.50" | "$20.50" -> cents, or null if it isn't a number */
export function parseDollarsToCents(input: string): number | null {
  const cleaned = input.trim().replace(/^\$/, "").replace(/,/g, "");
  if (cleaned === "" || !/^\d*\.?\d{0,2}$/.test(cleaned)) return null;
  const value = Number(cleaned);
  if (!Number.isFinite(value)) return null;
  return Math.round(value * 100);
}

/** For prefilling a dollars input from cents. */
export function centsToInput(cents: number): string {
  return cents % 100 === 0 ? String(cents / 100) : (cents / 100).toFixed(2);
}
