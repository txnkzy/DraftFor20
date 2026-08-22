"use client";

import { useCallback, useEffect, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Padlock } from "@/components/premium/Padlock";
import { UpgradeCard } from "@/components/premium/UpgradeCard";
import { readableError } from "@/lib/game/errors";
import type { PremiumState } from "@/lib/premium";
import type { RoomState } from "@/lib/game/types";
import { seatAccent } from "@/lib/game/view";
import { supabaseBrowser } from "@/lib/supabase/client";

interface HubTally {
  total: number;
  by_player: Record<string, number>;
}

/**
 * The Content tab: everything the host needs to film this room, and nothing
 * that touches the game.
 *
 * Free accounts are shown the whole tab locked rather than being shown
 * nothing. A padlock somebody can see is an upgrade path; a hidden tab is
 * just a feature nobody knows exists.
 */
export function ContentPanel({
  code,
  state,
  sessionToken,
  premium,
  onRecordMode,
}: {
  code: string;
  state: RoomState;
  sessionToken: string | null;
  premium: PremiumState;
  onRecordMode: () => void;
}) {
  const locked = !premium.active;
  const [obsUrl, setObsUrl] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [hub, setHub] = useState<{ tally: HubTally; complete: boolean } | null>(null);

  const voteUrl = typeof window === "undefined" ? "" : `${window.location.origin}/vote/${code}`;

  const readHub = useCallback(async (): Promise<{ tally: HubTally; complete: boolean } | null> => {
    if (!sessionToken || locked) return null;
    const { data } = await supabaseBrowser().rpc("get_audience_hub", {
      p_code: code,
      p_token: sessionToken,
    });
    return (data as { tally: HubTally; complete: boolean } | null) ?? null;
  }, [code, sessionToken, locked]);

  const loadHub = useCallback(async () => {
    const d = await readHub();
    if (d) setHub(d);
  }, [readHub]);

  useEffect(() => {
    let off = false;
    void (async () => {
      const first = await readHub();
      if (!off && first) setHub(first);
    })();
    const id = setInterval(() => void loadHub(), 5000);
    return () => {
      off = true;
      clearInterval(id);
    };
  }, [readHub, loadHub]);

  /* realtime is the fast path; the interval above is what makes a broken
     websocket cost latency instead of correctness, same as the board */
  const roomId = state.room.id;
  useEffect(() => {
    if (locked) return;
    const sb = supabaseBrowser();
    const ch = sb
      .channel(`room:${roomId}`)
      .on("broadcast", { event: "audience" }, () => void loadHub())
      .subscribe();
    return () => {
      void sb.removeChannel(ch);
    };
  }, [roomId, loadHub, locked]);

  async function mintObs(rotate = false) {
    if (!sessionToken) return;
    setBusy(true);
    setError(null);
    const { data, error: e } = await supabaseBrowser().rpc(
      rotate ? "rotate_obs_token" : "mint_obs_token",
      { p_code: code, p_token: sessionToken },
    );
    setBusy(false);
    if (e) {
      setError(readableError(e.message));
      return;
    }
    const d = data as { obs_token: string };
    setObsUrl(`${window.location.origin}/obs/${d.obs_token}`);
  }

  return (
    <div className="flex flex-col gap-8 py-2">
      {locked ? (
        <UpgradeCard feature="the Content tab" signedIn={premium.signedIn} compact />
      ) : null}

      {/* ── record mode ────────────────────────────────────────────────── */}
      <Section
        title="Record mode"
        locked={locked}
        blurb="Fullscreen, pure black, no navigation: a 9:16 frame with the right edge left clear for TikTok's buttons. Point your own screen recorder at it. Nothing is recorded by this site."
      >
        <Button variant="primary" disabled={locked} onClick={onRecordMode}>
          Enter record mode
        </Button>
      </Section>

      {/* ── OBS ────────────────────────────────────────────────────────── */}
      <Section
        title="OBS browser source"
        locked={locked}
        blurb="A link that renders this board with a transparent background and no interface at all. Paste it into an OBS Browser Source at 1080 x 1920. It is read-only: nobody who opens it can touch the game."
      >
        {obsUrl ? (
          <div className="flex flex-col gap-2">
            <CopyRow value={obsUrl} />
            <p className="type-num text-[0.75rem] leading-relaxed text-muted">
              width 1080 &middot; height 1920 &middot; tick &ldquo;shutdown source when not
              visible&rdquo; off. Add <span className="text-ink">?plate=0</span> for glyphs with
              no backing panels, or <span className="text-ink">?bg=solid</span> for an opaque
              board.
            </p>
            <div>
              <Button variant="quiet" size="sm" disabled={busy} onClick={() => void mintObs(true)}>
                Rotate link
              </Button>
            </div>
          </div>
        ) : (
          <Button variant="ghost" disabled={locked || busy || !sessionToken} onClick={() => void mintObs()}>
            {busy ? "Creating" : "Create browser source link"}
          </Button>
        )}
      </Section>

      {/* ── audience judge ─────────────────────────────────────────────── */}
      <Section
        title="Audience judge"
        locked={locked}
        blurb="Send this to the people watching. They see both rosters, vote blind, and only then see how the vote is going. Live tally below."
      >
        <div className="flex flex-col gap-3">
          <CopyRow value={voteUrl} />
          {!hub?.complete ? (
            <p className="type-label text-muted">
              voting opens the moment both rosters are full
            </p>
          ) : null}

          <ul className="flex flex-col">
            {state.players.map((p) => {
              const n = hub?.tally.by_player?.[p.id] ?? 0;
              const total = hub?.tally.total ?? 0;
              const pct = total > 0 ? Math.round((n / total) * 100) : 0;
              return (
                <li key={p.id} className="flex flex-col gap-1 border-b py-2.5 rule">
                  <div className="flex items-baseline gap-2">
                    <span
                      style={{ width: 8, height: 8, background: seatAccent(p.seat) }}
                      aria-hidden
                    />
                    <span className="type-display text-[0.875rem]">{p.display_name}</span>
                    <span className="type-num ml-auto text-[0.875rem] text-muted">
                      {n} {n === 1 ? "vote" : "votes"} &middot; {pct}%
                    </span>
                  </div>
                  <div style={{ height: 4, background: "color-mix(in oklab, var(--color-muted) 22%, transparent)" }}>
                    <div
                      style={{
                        width: `${pct}%`,
                        height: "100%",
                        background: seatAccent(p.seat),
                        transition: "width 260ms ease-out",
                      }}
                    />
                  </div>
                </li>
              );
            })}
          </ul>
          <p className="type-num text-[0.75rem] text-muted">
            {hub?.tally.total ?? 0} total &middot; one vote per browser
          </p>
        </div>
      </Section>

      {error ? <p className="text-[0.8125rem] text-coral">{error}</p> : null}
    </div>
  );
}

function Section({
  title,
  blurb,
  locked,
  children,
}: {
  title: string;
  blurb: string;
  locked: boolean;
  children: React.ReactNode;
}) {
  return (
    <section style={locked ? { opacity: 0.5 } : undefined}>
      <h3 className="type-display flex items-center gap-2 text-[1rem]">
        {locked ? <Padlock size={13} /> : null}
        {title}
      </h3>
      <p className="mt-1.5 text-[0.875rem] leading-relaxed text-muted">{blurb}</p>
      <div className="mt-3" style={locked ? { pointerEvents: "none" } : undefined} aria-disabled={locked}>
        {children}
      </div>
    </section>
  );
}

function CopyRow({ value }: { value: string }) {
  const [done, setDone] = useState(false);
  return (
    <div className="flex items-center gap-2 border p-2 rule">
      <span className="min-w-0 flex-1 truncate font-mono text-[0.75rem] text-muted">{value}</span>
      <Button
        variant="quiet"
        size="sm"
        onClick={() =>
          void navigator.clipboard
            .writeText(value)
            .then(() => {
              setDone(true);
              setTimeout(() => setDone(false), 1600);
            })
            .catch(() => undefined)
        }
      >
        {done ? "copied" : "Copy"}
      </Button>
    </div>
  );
}
