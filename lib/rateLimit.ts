import { createClient } from "@supabase/supabase-js";

/** Best-effort client IP behind Vercel's proxy. */
export function clientIp(req: Request): string {
  const fwd = req.headers.get("x-forwarded-for");
  if (fwd) return fwd.split(",")[0].trim();
  return req.headers.get("x-real-ip") ?? "unknown";
}

/**
 * Fixed-window limiter backed by a Postgres table. Fails OPEN: if the limiter
 * itself is broken we would rather let a room be created than take the app
 * down, since nothing here protects money.
 */
export async function allow(
  bucket: string,
  subject: string,
  limit: number,
  windowSeconds: number,
): Promise<boolean> {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) return true;
  try {
    const sb = createClient(url, key, { auth: { persistSession: false } });
    const { data, error } = await sb.rpc("df20_rate_limit", {
      p_bucket: bucket,
      p_subject: subject,
      p_limit: limit,
      p_window_seconds: windowSeconds,
    });
    if (error) return true;
    return data !== false;
  } catch {
    return true;
  }
}
