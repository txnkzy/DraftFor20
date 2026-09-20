"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/Button";
import { supabaseBrowser } from "@/lib/supabase/client";
import { USERNAME_RULES, USERNAME_SAYS, usernameCode, type UsernameProblem } from "@/lib/username";

/**
 * The username, beside the private email.
 *
 * CHOSEN, NOT ASSIGNED — since 0057, which reversed 0031. It was locked when
 * its only job was naming an account on an admin screen; a leaderboard makes
 * it a name people are seen under, and 'k3m9x2pq' at the top of a public
 * table is worth nothing to whoever earned it.
 *
 * Availability is checked as you type AND again by the database on save. The
 * check here is a courtesy that cannot be trusted: two people can pass it in
 * the same millisecond, and only the unique index decides. So a save that
 * comes back DF20_HANDLE_TAKEN is a normal outcome, not an error state.
 */

export function HandleRow({ email }: { email: string | null }) {
  const [handle, setHandle] = useState<string | null>(null);
  const [chosen, setChosen] = useState(true);
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState("");
  /* The ANSWER from the server, tagged with the name it answered about.
     Kept rather than a bare status so a reply for an old name can never be
     read as the verdict on the current one. */
  const [avail, setAvail] = useState<{ for: string; ok: boolean; problem: UsernameProblem | null } | null>(null);
  const [saveErr, setSaveErr] = useState<UsernameProblem | null>(null);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  /* Every check is stamped; only the newest may write. Without this a slow
     early request can land after a fast later one and overwrite a correct
     answer with a stale one — the field says "taken" for a name that is free. */
  const seq = useRef(0);

  /* Reads, and does NOT write: the write happens in the effect below, after
     an await and behind a cancellation flag. Setting state from inside a
     function the effect calls synchronously is what the cascading-render
     rule is about. */
  const read = useCallback(async () => {
    const { data } = await supabaseBrowser().rpc("my_handle");
    return data as { handle?: string | null; chosen?: boolean } | null;
  }, []);

  useEffect(() => {
    let off = false;
    void (async () => {
      const d = await read();
      if (off) return;
      setHandle(d?.handle ?? null);
      setChosen(Boolean(d?.chosen));
    })();
    return () => { off = true; };
  }, [read]);

  /* SHAPE IS DERIVED, NOT STORED. Deciding it in an effect meant calling
     setState synchronously while rendering, which cascades a second render
     for a value that is a pure function of the input. Only the round trip
     needs state, and it is written from the timeout rather than the effect
     body. */
  const typed = draft.trim().toLowerCase();
  const shape = typed ? usernameCode(typed) : null;
  const unchanged = typed !== "" && typed === handle;

  useEffect(() => {
    if (!typed || shape || unchanged) return;
    const mine = ++seq.current;
    const t = setTimeout(() => {
      void (async () => {
        const { data, error } = await supabaseBrowser().rpc("handle_available", { p_handle: typed });
        if (mine !== seq.current) return;
        if (error) return;
        const d = data as { available?: boolean; problem?: UsernameProblem | null } | null;
        setAvail({ for: typed, ok: Boolean(d?.available), problem: d?.problem ?? null });
      })();
    }, 350);
    return () => clearTimeout(t);
  }, [typed, shape, unchanged]);

  const state: "idle" | "checking" | "free" | "bad" =
    !typed || unchanged ? "idle"
    : shape ? "bad"
    : saveErr ? "bad"
    : avail && avail.for === typed ? (avail.ok ? "free" : "bad")
    : "checking";
  const problem: UsernameProblem | null =
    shape ?? saveErr ?? (avail && avail.for === typed && !avail.ok ? avail.problem : null);

  async function save() {
    if (!typed) return;
    setSaving(true);
    setSaveErr(null);
    const { data, error } = await supabaseBrowser().rpc("set_my_handle", { p_handle: typed });
    setSaving(false);
    if (error) {
      /* A save can fail for a name the check just called free: two people can
         pass it in the same millisecond and only the unique index decides.
         That is a normal outcome, so it reads as advice, not a fault. */
      const code = /DF20_HANDLE_([A-Z_]+)/.exec(error.message)?.[1]?.toLowerCase();
      setSaveErr(code && code in USERNAME_SAYS ? (code as UsernameProblem) : "taken");
      return;
    }
    setHandle((data as { handle?: string } | null)?.handle ?? typed);
    setChosen(true);
    setEditing(false);
    setSaved(true);
    setTimeout(() => setSaved(false), 2200);
  }

  return (
    <div className="mt-2">
      <dl className="flex flex-wrap items-baseline gap-x-6 gap-y-2">
        <div>
          <dt className="type-label text-muted">username</dt>
          <dd className="type-num mt-0.5 flex items-baseline gap-2 text-[0.9375rem] text-teal">
            {handle ? `@${handle}` : "…"}
            {handle && !editing ? (
              <button
                className="type-label text-muted hover:text-ink"
                onClick={() => { setDraft(handle); setEditing(true); setAvail(null); setSaveErr(null); }}
              >
                edit
              </button>
            ) : null}
            {saved ? <span className="type-label text-teal">saved</span> : null}
          </dd>
        </div>

        <div>
          <dt className="type-label text-muted">email &middot; only you see this</dt>
          <dd className="type-num mt-0.5 text-[0.9375rem] text-muted">{email}</dd>
        </div>
      </dl>

      {/* The nudge. Everyone who signed up before 0057 has a minted name, and
          it is the one that would appear on the leaderboard. */}
      {!editing && handle && !chosen ? (
        <div className="mt-3 border border-dashed p-3 rule">
          <p className="text-[0.8125rem] leading-snug text-muted">
            <span className="text-ink">This username was generated for you.</span> Pick your own
            — it&apos;s the name that shows on the leaderboard.
          </p>
          <Button
            variant="primary"
            size="sm"
            className="mt-2"
            onClick={() => { setDraft(""); setEditing(true); setAvail(null); setSaveErr(null); }}
          >
            Choose a username
          </Button>
        </div>
      ) : null}

      {editing ? (
        <div className="mt-3 max-w-sm">
          <label className="type-label text-muted" htmlFor="handle-input">new username</label>
          <div className="mt-1 flex items-start gap-2">
            <input
              id="handle-input"
              className="field type-num"
              value={draft}
              autoFocus
              maxLength={20}
              autoCapitalize="none"
              autoCorrect="off"
              spellCheck={false}
              placeholder="yourname"
              onChange={(e) => { setDraft(e.target.value.toLowerCase()); setSaveErr(null); }}
              onKeyDown={(e) => { if (e.key === "Enter" && state === "free") void save(); }}
            />
            <Button
              variant="primary"
              size="md"
              disabled={saving || state !== "free"}
              onClick={() => void save()}
            >
              {saving ? "Saving" : "Save"}
            </Button>
            <Button variant="ghost" size="md" disabled={saving} onClick={() => setEditing(false)}>
              Cancel
            </Button>
          </div>
          <p className="mt-1.5 text-[0.75rem] leading-snug">
            {state === "checking" ? (
              <span className="text-muted">checking…</span>
            ) : state === "free" ? (
              <span className="text-teal">available</span>
            ) : state === "bad" ? (
              <span className="text-coral">{USERNAME_SAYS[problem ?? "charset"]}</span>
            ) : (
              <span className="text-muted">{USERNAME_RULES}</span>
            )}
          </p>
        </div>
      ) : null}
    </div>
  );
}
