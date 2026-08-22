"use client";

import { useEffect, useState } from "react";
import { Button } from "@/components/ui/Button";
import { supabaseBrowser } from "@/lib/supabase/client";

const KEY = (code: string) => `df20:setupresult:${code}`;

/**
 * Shown only to the person who built a manual list, only after the draft, and
 * only when nothing in it looks like a real person. Default is off: this
 * renders a question, never a pre-ticked box.
 *
 * Eligibility is decided server-side and re-checked on submit, so hiding or
 * faking this component cannot publish anything.
 */
export function LibraryOptIn({ code }: { code: string }) {
  const [token, setToken] = useState<string | null>(null);
  const [state, setState] = useState<string | null>(null);
  const [name, setName] = useState("");
  const [count, setCount] = useState(0);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      let t: string | null = null;
      try {
        t = localStorage.getItem(KEY(code));
      } catch {
        /* private browsing: no prompt, which is the safe direction */
      }
      if (!t) return;
      const { data } = await supabaseBrowser().rpc("offer_library_optin", { p_result_token: t });
      if (cancelled) return;
      const d = data as { status?: string; category_name?: string; item_count?: number } | null;
      setToken(t);
      setState(d?.status ?? null);
      setName(d?.category_name ?? "");
      setCount(d?.item_count ?? 0);
    })();
    return () => {
      cancelled = true;
    };
  }, [code]);

  async function answer(accept: boolean) {
    if (!token) return;
    setBusy(true);
    const { data } = await supabaseBrowser().rpc("submit_library_optin", {
      p_result_token: token,
      p_accept: accept,
    });
    setBusy(false);
    setState((data as { status?: string } | null)?.status ?? "declined");
  }

  if (!token || state !== "eligible") {
    if (state === "accepted") {
      return (
        <p className="type-label border border-teal px-3 py-2.5 text-teal">
          added to the shared library
        </p>
      );
    }
    return null;
  }

  return (
    <div className="flex flex-col gap-3 border p-4 rule">
      <div>
        <span className="type-label text-muted">you built this list</span>
        <p className="mt-1 text-[0.9375rem] leading-relaxed">
          Add <span className="text-ink">{name}</span> and its {count} items to the shared library
          so other hosts can draft it?
        </p>
      </div>
      <div className="flex gap-2">
        <Button variant="ghost" disabled={busy} onClick={() => void answer(true)}>
          Share it
        </Button>
        <Button variant="quiet" disabled={busy} onClick={() => void answer(false)}>
          No thanks
        </Button>
      </div>
      <p className="text-[0.75rem] leading-relaxed text-muted">
        Off by default. Only the category name and the items are stored, never who played or
        when. Lists that look like they contain real people&apos;s names are never offered here at
        all.
      </p>
    </div>
  );
}
