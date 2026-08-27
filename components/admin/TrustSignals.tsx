"use client";

import { useCallback, useEffect, useState } from "react";
import { TextInput } from "@/components/ui/Field";
import { supabaseBrowser } from "@/lib/supabase/client";

/**
 * Signals, not verdicts.
 *
 * Every column here is evidence a person reads and weighs. There is no score
 * and no "bot" label, because a single number invites acting on the number
 * instead of the evidence — and every one of these has an innocent
 * explanation that is usually the right one. A shared IP is a household. A
 * disposable address is somebody who does not trust us yet. A four-second
 * verification is a password manager.
 *
 * Nothing here takes an action. Whatever an admin decides happens through the
 * existing controls, deliberately, one account at a time.
 */
interface Signal {
  id: string;
  email: string | null;
  handle: string | null;
  created_at: string;
  premium: boolean;
  ip: string | null;
  user_agent: string | null;
  referrer: string | null;
  disposable: boolean | null;
  turnstile: string | null;
  ip_shared_with: number | null;
  seconds_to_verify: number | null;
  seconds_to_first_action: number | null;
  has_signup_record: boolean;
  has_played: boolean;
  rate_limit_hits: number;
}

const FILTERS = [
  { id: "all", label: "Everyone", hint: "" },
  { id: "no_action", label: "Never played", hint: "verified, then did nothing" },
  { id: "unverified", label: "Never verified", hint: "signed up, never confirmed" },
  { id: "fast_verify", label: "Verified <15s", hint: "often just a password manager" },
  { id: "shared_ip", label: "Shared IP", hint: "households and schools look like this too" },
  { id: "disposable", label: "Disposable email", hint: "burner address" },
];

function duration(s: number | null): string {
  if (s === null) return "never";
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.round(s / 60)}m`;
  if (s < 86400) return `${Math.round(s / 3600)}h`;
  return `${Math.round(s / 86400)}d`;
}

/**
 * Which signals are actually PRESENT — things observed, never things missing.
 *
 * The first version flagged nearly every account, the creator's included, by
 * counting absent data as evidence: a backfilled profile row made
 * seconds_to_verify negative, negative satisfies "under 15 seconds", and the
 * oldest accounts in the system came out looking automated. Absence of
 * evidence is not evidence.
 *
 * The badge needs TWO signals, or one strong one. A single weak signal on its
 * own is the normal condition of a real account, and a badge that appears on
 * everything tells you nothing.
 */
function notable(r: Signal): { flags: string[]; strong: boolean } {
  const flags: string[] = [];
  let strong = false;

  // observed, and hard to explain innocently
  if (r.turnstile === "failed") {
    flags.push("failed the bot check");
    strong = true;
  }

  if (r.disposable) flags.push("disposable email");
  if ((r.ip_shared_with ?? 0) >= 3) {
    flags.push(`${r.ip_shared_with} other accounts from this IP`);
  }
  // only meaningful where the two timestamps are comparable at all
  if (r.seconds_to_verify !== null && r.seconds_to_verify < 15) {
    flags.push("verified within seconds");
  }
  if (!r.has_played) flags.push("never played anything");
  if (r.rate_limit_hits > 20) flags.push("heavy rate-limit use");

  return { flags, strong };
}

export function TrustSignals() {
  const [rows, setRows] = useState<Signal[]>([]);
  const [filter, setFilter] = useState("all");
  const [query, setQuery] = useState("");
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState<string | null>(null);

  const read = useCallback(async (f: string, q: string) => {
    const { data } = await supabaseBrowser().rpc("admin_user_signals", {
      p_query: q || null,
      p_filter: f,
    });
    return (data as Signal[] | null) ?? [];
  }, []);

  useEffect(() => {
    let off = false;
    void (async () => {
      const next = await read(filter, query);
      if (off) return;
      setRows(next);
      setLoading(false);
    })();
    return () => { off = true; };
  }, [read, filter, query]);

  const hint = FILTERS.find((f) => f.id === filter)?.hint ?? "";

  return (
    <section className="mt-11">
      <h2 className="type-display text-[1rem]">Trust signals</h2>
      <p className="mt-1.5 max-w-2xl text-[0.875rem] leading-relaxed text-muted">
        Evidence for you to weigh, not conclusions. Every one of these has an ordinary
        explanation that is usually the right one — a shared IP is a household, a burner address
        is somebody being careful, an instant verification is a password manager. Nothing here
        acts on its own.
      </p>

      <div className="mt-4 flex flex-wrap gap-1.5">
        {FILTERS.map((f) => (
          <button
            key={f.id}
            title={f.hint}
            onClick={() => { setFilter(f.id); setLoading(true); }}
            className={`type-label border px-2.5 py-1.5 ${
              filter === f.id ? "border-coral text-coral" : "text-muted rule hover:text-ink"
            }`}
          >
            {f.label}
          </button>
        ))}
      </div>

      <div className="mt-3">
        <TextInput
          value={query}
          placeholder="Search email, user id or IP"
          onChange={(e) => { setQuery(e.target.value); setLoading(true); }}
        />
      </div>

      <p className="type-label mt-3 text-muted">
        {loading ? "loading" : `${rows.length} account${rows.length === 1 ? "" : "s"}`}
        {hint ? ` · ${hint}` : ""}
      </p>

      <ul className="mt-2 flex flex-col">
        {rows.map((r) => {
          const { flags, strong } = notable(r);
          const worthLook = strong || flags.length >= 2;
          const isOpen = open === r.id;
          return (
            <li key={r.id} className="border-b py-3 rule">
              <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
                <button
                  className="type-num text-[0.875rem] text-teal hover:text-ink"
                  onClick={() => setOpen(isOpen ? null : r.id)}
                >
                  {r.handle ?? r.id.slice(0, 8)}
                </button>
                <span className="min-w-0 flex-1 truncate text-[0.8125rem] text-muted">
                  {r.email}
                </span>
                {r.premium ? <span className="type-label text-teal">premium</span> : null}
                {worthLook ? (
                  <span className="type-label text-gold" title={flags.join(" · ")}>
                    worth a look
                  </span>
                ) : null}
              </div>

              <div className="mt-1.5 flex flex-wrap gap-x-5 gap-y-1 text-[0.75rem] text-muted">
                <span>verified {duration(r.seconds_to_verify)}</span>
                <span>first action {duration(r.seconds_to_first_action)}</span>
                {r.ip ? (
                  <span className="type-num">
                    {r.ip}
                    {(r.ip_shared_with ?? 0) > 0 ? ` · +${r.ip_shared_with} here` : ""}
                  </span>
                ) : (
                  <span title="This account was created before signup signals were recorded.">
                    predates signal capture
                  </span>
                )}
                {r.disposable ? <span className="text-gold">disposable</span> : null}
                {r.turnstile && r.turnstile !== "skipped" ? (
                  <span>bot check {r.turnstile}</span>
                ) : null}
                {r.rate_limit_hits > 0 ? <span>{r.rate_limit_hits} limit hits</span> : null}
              </div>

              {isOpen ? (
                <div className="mt-2 border p-3 rule">
                  {flags.length > 0 ? (
                    <p className="text-[0.8125rem] leading-relaxed text-muted">
                      <span className="type-label text-gold">observed</span>{" "}
                      {flags.join(" · ")}. None of these is proof of anything on its own.
                    </p>
                  ) : (
                    <p className="text-[0.8125rem] text-muted">
                      Nothing stands out on this account.
                    </p>
                  )}
                  {!r.has_signup_record ? (
                    <p className="mt-1.5 text-[0.75rem] leading-relaxed text-muted">
                      Created before signup signals were recorded, so there is no IP, user agent
                      or bot-check result for it. That is chronology, not a finding.
                    </p>
                  ) : null}
                  <p className="mt-2 break-all font-mono text-[0.6875rem] text-muted">
                    {r.user_agent ?? "no user agent recorded"}
                  </p>
                  {r.referrer ? (
                    <p className="mt-1 break-all font-mono text-[0.6875rem] text-muted">
                      via {r.referrer}
                    </p>
                  ) : null}
                  <p className="type-num mt-2 text-[0.6875rem] text-muted">
                    signed up {new Date(r.created_at).toLocaleString()}
                  </p>
                </div>
              ) : null}
            </li>
          );
        })}
        {!loading && rows.length === 0 ? (
          <li className="type-label py-3 text-muted">nothing matches</li>
        ) : null}
      </ul>

      <p className="mt-4 text-[0.75rem] leading-relaxed text-muted">
        To act on an account, use the grant and revoke controls above &mdash; deliberately, one
        at a time. Nothing on this page changes anything by itself.
      </p>
    </section>
  );
}
