"use client";

import Link from "next/link";
import { track } from "@/lib/analytics";
import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Field, TextInput } from "@/components/ui/Field";
import { Footer, Header, SetupNotice } from "@/components/site/Chrome";
import { passwordProblem, safeNext } from "@/lib/auth";
import { Turnstile } from "@/components/site/Turnstile";
import { supabaseBrowser, supabaseConfigured } from "@/lib/supabase/client";
import { USERNAME_RULES, USERNAME_SAYS, usernameCode, type UsernameProblem } from "@/lib/username";

export function SignUpClient() {
  if (!supabaseConfigured()) return <SetupNotice />;
  return <SignUp />;
}

function SignUp() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [handle, setHandle] = useState("");
  /* "idle" until they type. The availability round trip is a courtesy — the
     unique index is what actually decides, so a name that passes here can
     still lose a race and come back taken. */
  const [avail, setAvail] = useState<{ for: string; ok: boolean; problem: UsernameProblem | null } | null>(null);
  const hSeq = useRef(0);
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [sent, setSent] = useState(false);
  const [taken, setTaken] = useState(false);
  const [turnstileToken, setTurnstileToken] = useState("");

  const next =
    typeof window === "undefined"
      ? "/"
      : safeNext(new URLSearchParams(window.location.search).get("next"));

  const emailOk = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email.trim());
  const mismatch = confirm.length > 0 && confirm !== password;

  /* SHAPE IS DERIVED, NOT STORED — deciding it inside the effect meant a
     synchronous setState and a wasted second render for a pure function of
     the input. Only the round trip needs state, and it is written from the
     timeout rather than the effect body.

     Every request is stamped and only the newest may write, or a slow early
     check lands after a fast later one and reports "taken" for a free name. */
  const typedHandle = handle.trim().toLowerCase();
  const hShape = typedHandle ? usernameCode(typedHandle) : null;

  useEffect(() => {
    if (!typedHandle || hShape) return;
    const mine = ++hSeq.current;
    const t = setTimeout(() => {
      void (async () => {
        const { data, error: e } = await supabaseBrowser().rpc("handle_available", { p_handle: typedHandle });
        if (mine !== hSeq.current) return;
        if (e) return;
        const d = data as { available?: boolean; problem?: UsernameProblem | null } | null;
        setAvail({ for: typedHandle, ok: Boolean(d?.available), problem: d?.problem ?? null });
      })();
    }, 350);
    return () => clearTimeout(t);
  }, [typedHandle, hShape]);

  const hState: "idle" | "checking" | "free" | "bad" =
    !typedHandle ? "idle"
    : hShape ? "bad"
    : avail && avail.for === typedHandle ? (avail.ok ? "free" : "bad")
    : "checking";
  const hProblem: UsernameProblem | null =
    hShape ?? (avail && avail.for === typedHandle && !avail.ok ? avail.problem : null);

  /* The username must be well formed AND not already reported taken. A
     "checking" state still blocks: letting someone submit mid-check is how
     you get a confident form and a generated name on the other side. */
  const handleOk = hShape === null && hState === "free";
  const ready = emailOk && handleOk && password.length > 0 && !mismatch && !busy;

  async function submit() {
    setError(null);
    const badHandle = usernameCode(handle);
    if (badHandle) {
      setError(USERNAME_SAYS[badHandle]);
      return;
    }
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
    // through our own route, not straight to Supabase: the Turnstile token
    // has to be checked BEFORE an account exists, and the request's signals
    // recorded once it does
    let res: {
      ok?: boolean;
      needsConfirmation?: boolean;
      alreadyRegistered?: boolean;
      message?: string;
    };
    try {
      const r = await fetch("/api/auth/signup", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ email: email.trim(), password, handle: handle.trim(), next, turnstileToken }),
      });
      res = (await r.json()) as typeof res;
    } catch {
      res = { ok: false, message: "Could not reach the server." };
    }
    setBusy(false);
    if (res.alreadyRegistered) {
      setTaken(true);
      return;
    }
    if (!res.ok) {
      setError(res.message ?? "Could not create the account.");
      return;
    }
    // an account now exists, whether or not the address is confirmed yet
    track("sign_up", { confirmation: res.needsConfirmation ? "pending" : "immediate" });
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
          <Field
            label="username"
            hint={
              hState === "checking" ? "checking…"
              : hState === "free" ? "available"
              : hState === "bad" ? USERNAME_SAYS[hProblem ?? "charset"]
              : USERNAME_RULES
            }
            htmlFor="handle"
          >
            <TextInput
              id="handle"
              value={handle}
              autoComplete="username"
              autoCapitalize="none"
              autoCorrect="off"
              spellCheck={false}
              maxLength={20}
              placeholder="yourname"
              onChange={(e) => setHandle(e.target.value.toLowerCase())}
            />
          </Field>

          <Field label="email" htmlFor="email">
            <TextInput
              id="email"
              type="email"
              value={email}
              autoComplete="email"
              placeholder="you@example.com"
              onChange={(e) => { setEmail(e.target.value); setTaken(false); }}
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
          {taken ? (
            <div className="border border-teal p-3">
              <p className="type-label text-teal">that email already has an account</p>
              <p className="mt-1.5 text-[0.875rem] leading-relaxed text-muted">
                One account per address. Sign in instead, or use{" "}
                <Link className="text-ink underline" href="/login?reset=1">
                  forgotten password
                </Link>{" "}
                if you cannot get in.
              </p>
              <Link
                href={`/login?next=${encodeURIComponent(next)}`}
                className="btn btn-primary mt-3 h-11 px-4 text-[0.8125rem]"
              >
                Sign in as {email.trim()}
              </Link>
            </div>
          ) : null}

          {error ? <p className="text-[0.875rem] text-coral">{error}</p> : null}

          <Turnstile onToken={setTurnstileToken} />

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
