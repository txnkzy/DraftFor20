"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { Button } from "@/components/ui/Button";
import { Field, TextInput } from "@/components/ui/Field";
import { Footer, Header, SetupNotice } from "@/components/site/Chrome";
import { passwordProblem, signUpWithPassword } from "@/lib/auth";
import { supabaseConfigured } from "@/lib/supabase/client";

export function SignUpClient() {
  if (!supabaseConfigured()) return <SetupNotice />;
  return <SignUp />;
}

function SignUp() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [sent, setSent] = useState(false);

  const next =
    typeof window === "undefined"
      ? "/host"
      : new URLSearchParams(window.location.search).get("next") || "/host";

  const emailOk = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email.trim());
  const mismatch = confirm.length > 0 && confirm !== password;
  const ready = emailOk && password.length > 0 && !mismatch && !busy;

  async function submit() {
    setError(null);
    const problem = passwordProblem(password, email);
    if (problem) {
      setError(problem);
      return;
    }
    if (password !== confirm) {
      setError("The two passwords don't match.");
      return;
    }
    setBusy(true);
    // password goes straight to Supabase Auth; nothing here keeps it
    const res = await signUpWithPassword(email, password, next);
    setBusy(false);
    if (!res.ok) {
      setError(res.message ?? "Could not create the account.");
      return;
    }
    if (res.needsConfirmation) {
      setSent(true);
    } else {
      router.push(next);
      router.refresh();
    }
  }

  if (sent) {
    return (
      <>
        <Header thin />
        <main className="mx-auto w-full max-w-sm px-4 py-14">
          <h1 className="type-display text-[1.75rem]">Check your email</h1>
          <p className="mt-3 text-[0.9375rem] leading-relaxed text-muted">
            We sent a confirmation link to <span className="text-ink">{email}</span>. Click it and
            you can host custom categories. You only ever have to do this once.
          </p>
          <p className="mt-4 text-[0.8125rem] leading-relaxed text-muted">
            Nothing on the free shelf needs an account, so you can go start a Football Draft in the
            meantime.
          </p>
          <Link href="/new" className="btn btn-ghost mt-6 h-11 px-4 text-[0.8125rem]">
            Back to starting a room
          </Link>
        </main>
        <Footer />
      </>
    );
  }

  return (
    <>
      <Header thin />
      <main className="mx-auto w-full max-w-sm px-4 py-14">
        <h1 className="type-display text-[1.75rem]">Create an account</h1>
        <p className="mt-2 text-[0.9375rem] leading-relaxed text-muted">
          Only needed to build your own category or hand the list to someone else. Football Draft,
          the ready-made shelf and playing are always free without one.
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

          <Field label="password" hint="At least 10 characters." htmlFor="password">
            <TextInput
              id="password"
              type="password"
              value={password}
              autoComplete="new-password"
              onChange={(e) => setPassword(e.target.value)}
            />
          </Field>

          <Field label="password again" htmlFor="confirm">
            <TextInput
              id="confirm"
              type="password"
              value={confirm}
              autoComplete="new-password"
              onChange={(e) => setConfirm(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && ready) void submit();
              }}
            />
          </Field>

          {mismatch ? (
            <p className="text-[0.8125rem] text-coral">Those two don&apos;t match yet.</p>
          ) : null}
          {error ? <p className="text-[0.875rem] text-coral">{error}</p> : null}

          <Button variant="primary" size="lg" disabled={!ready} onClick={() => void submit()}>
            {busy ? "Creating…" : "Create account"}
          </Button>

          <p className="text-[0.8125rem] text-muted">
            Already have an account?{" "}
            <Link className="text-gold" href={`/login?next=${encodeURIComponent(next)}`}>
              Sign in
            </Link>
          </p>
          <p className="text-[0.75rem] leading-relaxed text-muted">
            Your password is handled by Supabase Auth and never stored by DraftFor20. See the{" "}
            <Link className="text-gold" href="/privacy">
              privacy policy
            </Link>
            .
          </p>
        </div>
      </main>
      <Footer />
    </>
  );
}
