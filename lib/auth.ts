"use client";

import { useEffect, useState } from "react";
import { supabaseBrowser, supabaseConfigured } from "@/lib/supabase/client";

export interface HostUser {
  id: string;
  email: string | null;
}

/**
 * Current signed-in host, or null. Subscribes to auth changes so signing in
 * from another tab updates this one too.
 */
export function useHost(): { user: HostUser | null; loading: boolean } {
  const [user, setUser] = useState<HostUser | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    let unsubscribe: (() => void) | undefined;

    void (async () => {
      if (!supabaseConfigured()) {
        if (!cancelled) setLoading(false);
        return;
      }
      const sb = supabaseBrowser();
      const { data } = await sb.auth.getUser();
      if (cancelled) return;
      setUser(data.user ? { id: data.user.id, email: data.user.email ?? null } : null);
      setLoading(false);

      const { data: sub } = sb.auth.onAuthStateChange((_e, session) => {
        setUser(
          session?.user ? { id: session.user.id, email: session.user.email ?? null } : null,
        );
        setLoading(false);
      });
      unsubscribe = () => sub.subscription.unsubscribe();
    })();

    return () => {
      cancelled = true;
      unsubscribe?.();
    };
  }, []);

  return { user, loading };
}

/** The access token to send to our own route handlers so they can verify it. */
export async function accessToken(): Promise<string | null> {
  if (!supabaseConfigured()) return null;
  const { data } = await supabaseBrowser().auth.getSession();
  return data.session?.access_token ?? null;
}

/** Where to send someone to sign in and come back to exactly where they were. */
export function signInHref(next: string): string {
  return `/login?next=${encodeURIComponent(next)}`;
}

export function signUpHref(next: string): string {
  return `/signup?next=${encodeURIComponent(next)}`;
}

/**
 * Passwords go straight from the input to Supabase Auth and nowhere else.
 * Nothing here stores, hashes, logs or forwards one, and the browser SDK is
 * called with the publishable key exactly as every other request is.
 */
export interface AuthResult {
  ok: boolean;
  message?: string;
  needsConfirmation?: boolean;
}

const MIN_PASSWORD = 10;

/** Light client-side checks so people get told before a round trip. Real
 *  policy lives in Supabase → Auth → Providers → Email. */
export function passwordProblem(password: string, email: string): string | null {
  if (password.length < MIN_PASSWORD) {
    return `Passwords need at least ${MIN_PASSWORD} characters.`;
  }
  if (email && password.toLowerCase().includes(email.split("@")[0].toLowerCase())) {
    return "Don't put your email address in your password.";
  }
  if (/^(.)\1+$/.test(password)) {
    return "That's the same character over and over. Try something else.";
  }
  return null;
}

export async function signUpWithPassword(email: string, password: string, next: string): Promise<AuthResult> {
  const sb = supabaseBrowser();
  const { data, error } = await sb.auth.signUp({
    email: email.trim(),
    password,
    options: {
      emailRedirectTo: `${window.location.origin}/auth/callback?next=${encodeURIComponent(next)}`,
    },
  });
  if (error) return { ok: false, message: friendly(error.message) };
  // no session means Supabase is waiting on email confirmation
  return { ok: true, needsConfirmation: !data.session };
}

export async function signInWithPassword(email: string, password: string): Promise<AuthResult> {
  const sb = supabaseBrowser();
  const { error } = await sb.auth.signInWithPassword({ email: email.trim(), password });
  if (error) return { ok: false, message: friendly(error.message) };
  return { ok: true };
}

export async function signOut(): Promise<void> {
  await supabaseBrowser().auth.signOut();
}

/** Supabase's raw strings are terse and sometimes leak implementation detail. */
function friendly(raw: string): string {
  const m = raw.toLowerCase();
  if (m.includes("invalid login credentials")) return "That email and password don't match.";
  if (m.includes("email not confirmed")) return "Check your email and confirm the account first.";
  if (m.includes("already registered") || m.includes("already been registered")) {
    return "There's already an account with that email. Try signing in.";
  }
  if (m.includes("rate limit") || m.includes("too many")) {
    return "Too many attempts just now. Wait a minute and try again.";
  }
  if (m.includes("password")) return raw;
  return raw;
}
