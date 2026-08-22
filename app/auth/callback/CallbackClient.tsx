"use client";

import { useEffect, useState } from "react";
import { Header } from "@/components/site/Chrome";
import { supabaseBrowser, supabaseConfigured } from "@/lib/supabase/client";

/**
 * This runs in the BROWSER on purpose.
 *
 * The old version exchanged the code in a route handler. createBrowserClient
 * uses PKCE, so the code verifier is generated and stored in the browser when
 * sign-up starts — the server has no way to see it, and the exchange failed
 * every time. Doing it here is the only place the verifier exists.
 *
 * Handles all three shapes Supabase can send back: a PKCE ?code, an email
 * ?token_hash, and tokens in the URL fragment.
 */
export function CallbackClient() {
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    void (async () => {
      if (!supabaseConfigured()) return;
      const sb = supabaseBrowser();
      const url = new URL(window.location.href);
      const params = url.searchParams;
      const hash = new URLSearchParams(url.hash.replace(/^#/, ""));

      const rawNext = params.get("next") ?? "/host";
      // same-origin paths only; never a protocol-relative or absolute URL
      const next = /^\/(?![/\\])/.test(rawNext) ? rawNext : "/host";

      let failed: string | null = null;
      try {
        if (params.get("code")) {
          const { error: e } = await sb.auth.exchangeCodeForSession(params.get("code")!);
          if (e) failed = e.message;
        } else if (params.get("token_hash")) {
          const { error: e } = await sb.auth.verifyOtp({
            token_hash: params.get("token_hash")!,
            type: (params.get("type") as "email" | "signup" | "magiclink" | "recovery") ?? "email",
          });
          if (e) failed = e.message;
        } else if (hash.get("access_token") && hash.get("refresh_token")) {
          const { error: e } = await sb.auth.setSession({
            access_token: hash.get("access_token")!,
            refresh_token: hash.get("refresh_token")!,
          });
          if (e) failed = e.message;
        } else if (params.get("error_description")) {
          failed = params.get("error_description");
        } else {
          failed = "That link didn't carry a sign-in token.";
        }
      } catch (e) {
        failed = (e as Error)?.message ?? "Sign-in failed.";
      }

      if (cancelled) return;
      if (failed) {
        setError(failed);
        return;
      }
      // full navigation so every server component re-reads the new session
      window.location.replace(next);
    })();

    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <>
      <Header thin />
      <main className="mx-auto w-full max-w-sm px-4 py-16">
        <h1 className="type-display text-[1.5rem]">{error ? "That link didn't work" : "Signing you in"}</h1>
        {error ? (
          <>
            <p className="mt-3 text-[0.9375rem] leading-relaxed text-muted">{error}</p>
            <a href="/login" className="btn btn-primary mt-5 h-11 px-4 text-[0.8125rem]">
              Back to sign in
            </a>
          </>
        ) : (
          <p className="type-label mt-2 text-muted">one moment</p>
        )}
      </main>
    </>
  );
}
