"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { Button } from "@/components/ui/Button";
import { Field, TextInput } from "@/components/ui/Field";
import { Footer, Header, SetupNotice } from "@/components/site/Chrome";
import { signInWithPassword } from "@/lib/auth";
import { supabaseConfigured } from "@/lib/supabase/client";

export function LoginClient() {
  if (!supabaseConfigured()) return <SetupNotice />;
  return <Login />;
}

function Login() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [linkSent, setLinkSent] = useState(false);
  const [showLink, setShowLink] = useState(false);

  const next =
    typeof window === "undefined"
      ? "/host"
      : new URLSearchParams(window.location.search).get("next") || "/host";

  const emailOk = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email.trim());

  /**
   * Password sign-in sends NO email, which is the whole point: the old
   * magic-link-only flow burned an email on every single login and kept
   * tripping Supabase's sending quota.
   */
  async function submit() {
    if (busy) return; // guard against a double submit firing two auth calls
    setBusy(true);
    setError(null);
    const res = await signInWithPassword(email, password);
    setBusy(false);
    if (!res.ok) {
      setError(res.message ?? "Could not sign in.");
      return;
    }
    router.push(next);
    router.refresh();
  }

  /** Fallback for people who forgot the password. This one does send email. */
  async function sendLink() {
    if (busy) return;
    setBusy(true);
    setError(null);
    const res = await fetch("/api/auth/magic-link", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        email: email.trim(),
        redirectTo: `${window.location.origin}/auth/callback?next=${encodeURIComponent(next)}`,
      }),
    });
    const data = await res.json().catch(() => ({}));
    setBusy(false);
    if (!res.ok) {
      setError(data?.message ?? "Could not send the link.");
      return;
    }
    setLinkSent(true);
  }

  if (linkSent) {
    return (
      <>
        <Header thin />
        <main className="mx-auto w-full max-w-sm px-4 py-14">
          <h1 className="type-display text-[1.75rem]">Link sent</h1>
          <p className="mt-3 text-[0.9375rem] leading-relaxed text-muted">
            Open it on this device and you&apos;ll be signed in. It only works if an account
            already exists for <span className="text-ink">{email}</span>.
          </p>
        </main>
        <Footer />
      </>
    );
  }

  return (
    <>
      <Header thin />
      <main className="mx-auto w-full max-w-sm px-4 py-14">
        <h1 className="type-display text-[1.75rem]">Sign in</h1>
        <p className="mt-2 text-[0.9375rem] leading-relaxed text-muted">
          Needed to build your own category or hand the list to someone else. Playing and the
          ready-made shelf never need an account.
        </p>

        <div className="mt-7 flex flex-col gap-5">
          <Field label="email" htmlFor="email">
            <TextInput
              id="email"
              type="email"
              value={email}
              autoComplete="email"
              placeholder="you@example.com"
              onChange={(e) => setEmail(e.target.value)}
            />
          </Field>

          <Field label="password" htmlFor="password">
            <TextInput
              id="password"
              type="password"
              value={password}
              autoComplete="current-password"
              onChange={(e) => setPassword(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && emailOk && password) void submit();
              }}
            />
          </Field>

          {error ? <p className="text-[0.875rem] text-coral">{error}</p> : null}

          <Button
            variant="primary"
            size="lg"
            disabled={busy || !emailOk || password.length === 0}
            onClick={() => void submit()}
          >
            {busy ? "Signing in…" : "Sign in"}
          </Button>

          <p className="text-[0.8125rem] text-muted">
            No account yet?{" "}
            <Link className="text-gold" href={`/signup?next=${encodeURIComponent(next)}`}>
              Create one
            </Link>
          </p>

          <div className="border-t pt-4 rule">
            {showLink ? (
              <div className="flex flex-col gap-2">
                <p className="text-[0.8125rem] leading-relaxed text-muted">
                  We&apos;ll email a one-time link instead. Only works for an account that already
                  exists.
                </p>
                <Button variant="ghost" disabled={busy || !emailOk} onClick={() => void sendLink()}>
                  {busy ? "Sending…" : "Email me a link"}
                </Button>
              </div>
            ) : (
              <button
                className="type-label text-muted hover:text-ink"
                onClick={() => setShowLink(true)}
              >
                forgot your password?
              </button>
            )}
          </div>
        </div>
      </main>
      <Footer />
    </>
  );
}
