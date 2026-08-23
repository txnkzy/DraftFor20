"use client";

import { useCallback, useEffect, useState } from "react";
import { Button } from "@/components/ui/Button";
import { TextInput } from "@/components/ui/Field";
import { readableError } from "@/lib/game/errors";
import { supabaseBrowser } from "@/lib/supabase/client";

/**
 * The public handle, beside the private email.
 *
 * Every account has one: it is generated when the profile row is created and
 * existing rows were backfilled, so this never renders empty. It exists so an
 * account can be named — in the admin table, on anything shared — without
 * putting an email address on screen. The email stays visible only here, to
 * its owner, and to an admin.
 */
export function HandleRow({ email }: { email: string | null }) {
  const [handle, setHandle] = useState<string | null>(null);
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const read = useCallback(async () => {
    const { data } = await supabaseBrowser().rpc("my_handle");
    return ((data as { handle?: string | null } | null)?.handle ?? null) as string | null;
  }, []);

  useEffect(() => {
    let off = false;
    void (async () => {
      const h = await read();
      if (!off) setHandle(h);
    })();
    return () => { off = true; };
  }, [read]);

  async function save() {
    setBusy(true);
    setError(null);
    const { error: e } = await supabaseBrowser().rpc("set_my_handle", {
      p_handle: draft.trim().toLowerCase(),
    });
    setBusy(false);
    if (e) {
      setError(readableError(e.message));
      return;
    }
    setHandle(await read());
    setEditing(false);
  }

  return (
    <div className="mt-1 flex flex-col gap-1">
      <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
        {/* the public one first: it is the one other people can see */}
        <span className="type-num text-[0.9375rem] text-teal">
          {handle ? `@${handle}` : "…"}
        </span>
        <span className="type-num text-[0.8125rem] text-muted">{email}</span>
        <span className="type-label text-muted/70">only you see the email</span>
        {!editing ? (
          <button
            className="type-label text-muted underline hover:text-ink"
            onClick={() => {
              setDraft(handle ?? "");
              setEditing(true);
              setError(null);
            }}
          >
            change
          </button>
        ) : null}
      </div>

      {editing ? (
        <div className="mt-2 flex flex-col gap-2">
          <div className="flex items-center gap-2">
            <span className="type-num text-[0.9375rem] text-muted">@</span>
            <TextInput
              value={draft}
              maxLength={20}
              autoFocus
              aria-label="your public handle"
              placeholder="3-20 characters"
              className="type-num"
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") void save();
                if (e.key === "Escape") setEditing(false);
              }}
            />
            <Button variant="primary" size="sm" disabled={busy || draft.trim().length < 3}
                    onClick={() => void save()}>
              {busy ? "Saving" : "Save"}
            </Button>
            <Button variant="quiet" size="sm" onClick={() => setEditing(false)}>
              Cancel
            </Button>
          </div>
          <p className="text-[0.75rem] leading-snug text-muted">
            Lowercase letters, numbers, hyphens and underscores. This is what other people can
            be shown instead of your email address.
          </p>
          {error ? <p className="text-[0.8125rem] text-coral">{error}</p> : null}
        </div>
      ) : null}
    </div>
  );
}
