import "server-only";

/**
 * Cloudflare Turnstile, verified server-side.
 *
 * OPTIONAL, like Stripe. With no keys set this returns "skipped" and signup
 * proceeds — a missing anti-bot key must never be the reason a real person
 * cannot make an account. The outcome is recorded either way, so an admin can
 * see which signups happened before the check was switched on.
 */
export type TurnstileOutcome = "passed" | "failed" | "skipped";

const VERIFY = "https://challenges.cloudflare.com/turnstile/v0/siteverify";

export function turnstileConfigured(): boolean {
  return Boolean((process.env.TURNSTILE_SECRET_KEY ?? "").trim());
}

export async function verifyTurnstile(
  token: string | null | undefined,
  ip: string | null,
): Promise<TurnstileOutcome> {
  const secret = (process.env.TURNSTILE_SECRET_KEY ?? "").trim();
  if (!secret) return "skipped";
  if (!token) return "failed";

  try {
    const body = new URLSearchParams({ secret, response: token });
    if (ip && ip !== "unknown") body.set("remoteip", ip);

    const res = await fetch(VERIFY, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body,
      cache: "no-store",
    });
    if (!res.ok) return "failed";
    const json = (await res.json()) as { success?: boolean };
    return json.success ? "passed" : "failed";
  } catch {
    // Cloudflare unreachable. Fail OPEN: an outage at their end must not
    // stop people signing up, and the outcome is recorded as skipped so the
    // gap is visible rather than silent.
    return "skipped";
  }
}
