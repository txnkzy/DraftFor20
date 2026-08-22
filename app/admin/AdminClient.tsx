"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { Button } from "@/components/ui/Button";
import { TextInput } from "@/components/ui/Field";
import { Footer, Header, SetupNotice } from "@/components/site/Chrome";
import { supabaseBrowser, supabaseConfigured } from "@/lib/supabase/client";

/**
 * The operator's console.
 *
 * SCOPE IS THE DESIGN. Revenue, MRR, churn and payouts are Stripe's job;
 * table contents, query performance and logs are Supabase's. Both already do
 * it better than anything built here would, and a second copy of a number is
 * a second number to be wrong. This page covers only what neither of them
 * knows: who has premium and why, what is queued for the public library, and
 * how the app is actually being used. The rest is two links.
 *
 * NOBODY IS AN ADMIN BY DEFAULT. df20_is_admin() reads a comma-separated list
 * of uuids from df20_config.admin_user_ids, and no migration creates that
 * row — so on a fresh database every RPC behind this page refuses everyone
 * and there is no role system to misconfigure.
 */
type Tab = "users" | "library" | "activity" | "events";

interface Row {
  id: string;
  email: string | null;
  display_name: string | null;
  created_at: string;
  premium_until: string | null;
  premium_source: string | null;
  subscription_status: string | null;
  active: boolean;
  hosted: number;
  played: number;
  last_seat: string | null;
  decks: number;
}

interface QueueItem {
  room_id: string;
  category: string;
  submitted_at: string;
  item_count: number;
  items: string[];
  already_public: boolean;
}

interface LibraryItem {
  id: string;
  name: string;
  created_at: string;
  item_count: number;
}

interface Activity {
  rooms: { total: number; today: number; week: number; live: number; complete: number };
  daily: { day: string; rooms: number }[];
  categories: Record<string, number>;
  modes: { standard: number; creator: number };
  duration: { sample: number; avg_seconds: number | null; median_seconds: number | null };
  library: { public: number; pending: number; saved_decks: number };
  audience: { votes: number; rooms_voted_on: number };
  premium: { active: number; by_source: Record<string, number> };
}

interface EventRow {
  event_id: string;
  kind: string | null;
  status: string;
  detail: string | null;
  at: string;
}

export function AdminClient() {
  if (!supabaseConfigured()) return <SetupNotice />;
  return <Admin />;
}

function Admin() {
  const [isAdmin, setIsAdmin] = useState<boolean | null>(null);
  const [tab, setTab] = useState<Tab>("users");
  const [rows, setRows] = useState<Row[]>([]);
  const [queue, setQueue] = useState<QueueItem[]>([]);
  const [library, setLibrary] = useState<LibraryItem[]>([]);
  const [activity, setActivity] = useState<Activity | null>(null);
  const [events, setEvents] = useState<EventRow[]>([]);
  const [query, setQuery] = useState("");
  const [days, setDays] = useState("30");
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [sort, setSort] = useState<{ key: keyof Row; dir: 1 | -1 }>({
    key: "created_at",
    dir: -1,
  });

  const loadAll = useCallback(async (q: string) => {
    const sb = supabaseBrowser();
    const { data: admin } = await sb.rpc("df20_is_admin");
    if (!admin) return { admin: false };
    const [u, k, l, a, e] = await Promise.all([
      sb.rpc("admin_list_profiles", { p_query: q || null }),
      sb.rpc("admin_library_queue"),
      sb.rpc("admin_library_list"),
      sb.rpc("admin_activity"),
      sb.rpc("admin_recent_events", { p_limit: 40 }),
    ]);
    return {
      admin: true,
      rows: (u.data as Row[] | null) ?? [],
      queue: (k.data as QueueItem[] | null) ?? [],
      library: (l.data as LibraryItem[] | null) ?? [],
      activity: (a.data as Activity | null) ?? null,
      events: (e.data as EventRow[] | null) ?? [],
    };
  }, []);

  const apply = useCallback((next: Awaited<ReturnType<typeof loadAll>>) => {
    setIsAdmin(next.admin);
    if (!next.admin) return;
    setRows(next.rows ?? []);
    setQueue(next.queue ?? []);
    setLibrary(next.library ?? []);
    setActivity(next.activity ?? null);
    setEvents(next.events ?? []);
  }, []);

  useEffect(() => {
    let off = false;
    void (async () => {
      const next = await loadAll("");
      if (!off) apply(next);
    })();
    return () => {
      off = true;
    };
  }, [loadAll, apply]);

  const refresh = useCallback(async () => apply(await loadAll(query)), [apply, loadAll, query]);

  async function call(label: string, fn: string, args: Record<string, unknown>) {
    setBusy(label);
    setError(null);
    const { error: e } = await supabaseBrowser().rpc(fn, args);
    setBusy(null);
    if (e) {
      setError(e.message);
      return;
    }
    await refresh();
  }

  const sorted = useMemo(() => {
    const copy = [...rows];
    copy.sort((a, b) => {
      const av = a[sort.key];
      const bv = b[sort.key];
      if (av === bv) return 0;
      if (av === null || av === undefined) return 1;
      if (bv === null || bv === undefined) return -1;
      return (av < bv ? -1 : 1) * sort.dir;
    });
    return copy;
  }, [rows, sort]);

  if (isAdmin === null) {
    return (
      <>
        <Header thin />
        <main className="mx-auto w-full max-w-5xl px-4 py-14">
          <p className="type-label text-muted">checking</p>
        </main>
      </>
    );
  }

  if (!isAdmin) {
    return (
      <>
        <Header thin />
        <main className="mx-auto w-full max-w-5xl px-4 py-14">
          <h1 className="type-display text-[1.75rem]">Nothing here</h1>
          <p className="mt-2 text-[0.9375rem] text-muted">
            This page is for whoever runs DraftFor20, and this account isn&apos;t on that list.
          </p>
        </main>
        <Footer />
      </>
    );
  }

  const supabaseRef = (process.env.NEXT_PUBLIC_SUPABASE_URL ?? "").match(
    /https:\/\/([a-z0-9]+)\.supabase\.co/i,
  )?.[1];

  return (
    <>
      <Header thin />
      <main className="mx-auto w-full max-w-5xl px-4 py-10">
        <div className="flex flex-wrap items-baseline justify-between gap-3">
          <h1 className="type-display text-[1.75rem]">Console</h1>
          <div className="flex flex-wrap gap-3">
            {/* the money and the database already have dashboards */}
            <a
              className="type-label text-muted hover:text-ink"
              href="https://dashboard.stripe.com"
              target="_blank"
              rel="noreferrer"
            >
              Stripe &#8599;
            </a>
            <a
              className="type-label text-muted hover:text-ink"
              href={
                supabaseRef
                  ? `https://supabase.com/dashboard/project/${supabaseRef}`
                  : "https://supabase.com/dashboard"
              }
              target="_blank"
              rel="noreferrer"
            >
              Supabase &#8599;
            </a>
          </div>
        </div>
        <p className="mt-2 text-[0.875rem] leading-relaxed text-muted">
          Revenue lives in Stripe and query health lives in Supabase. This is the part only this
          app knows.
        </p>

        <nav className="mt-6 flex gap-4 border-b rule" aria-label="Console sections">
          {(
            [
              ["users", `Users ${rows.length}`],
              ["library", `Library ${queue.length > 0 ? `· ${queue.length} queued` : ""}`],
              ["activity", "Activity"],
              ["events", "Events"],
            ] as const
          ).map(([id, label]) => (
            <button
              key={id}
              onClick={() => setTab(id)}
              className="type-label -mb-px border-b-2 pb-2.5 pt-1"
              style={{
                color: tab === id ? "var(--color-ink)" : "var(--color-muted)",
                borderColor: tab === id ? "var(--color-coral)" : "transparent",
              }}
              aria-current={tab === id}
            >
              {label}
            </button>
          ))}
        </nav>

        {error ? <p className="mt-4 text-[0.8125rem] text-coral">{error}</p> : null}

        {tab === "users" ? (
          <section className="mt-6">
            <div className="flex flex-col gap-2 sm:flex-row">
              <TextInput
                value={query}
                placeholder="Search email or name"
                onChange={(e) => setQuery(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") void refresh();
                }}
              />
              <TextInput
                value={days}
                inputMode="numeric"
                className="type-num sm:max-w-[7rem]"
                aria-label="days to grant"
                onChange={(e) => setDays(e.target.value)}
              />
              <Button variant="ghost" className="shrink-0" onClick={() => void refresh()}>
                Search
              </Button>
            </div>

            <div className="mt-5 overflow-x-auto">
              <table className="w-full min-w-[46rem] border-collapse text-left">
                <thead>
                  <tr>
                    {(
                      [
                        ["email", "account"],
                        ["created_at", "joined"],
                        ["active", "premium"],
                        ["hosted", "hosted"],
                        ["played", "played"],
                        ["last_seat", "last seat"],
                      ] as const
                    ).map(([key, label]) => (
                      <th key={key} className="border-b pb-2 rule">
                        <button
                          className="type-label text-muted hover:text-ink"
                          onClick={() =>
                            setSort((p) =>
                              p.key === key ? { key, dir: p.dir === 1 ? -1 : 1 } : { key, dir: 1 },
                            )
                          }
                        >
                          {label}
                          {sort.key === key ? (sort.dir === 1 ? " ↑" : " ↓") : ""}
                        </button>
                      </th>
                    ))}
                    <th className="border-b pb-2 rule" />
                  </tr>
                </thead>
                <tbody>
                  {sorted.length === 0 ? (
                    <tr>
                      <td colSpan={7} className="type-label py-4 text-muted">
                        no accounts
                      </td>
                    </tr>
                  ) : null}
                  {sorted.map((r) => (
                    <tr key={r.id}>
                      <td className="border-b py-2.5 pr-3 rule">
                        <span className="type-display block truncate text-[0.8125rem]">
                          {r.display_name || r.email || r.id.slice(0, 8)}
                        </span>
                        {r.display_name && r.email ? (
                          <span className="block truncate text-[0.75rem] text-muted">
                            {r.email}
                          </span>
                        ) : null}
                      </td>
                      <td className="type-num border-b py-2.5 pr-3 text-[0.75rem] text-muted rule">
                        {new Date(r.created_at).toLocaleDateString()}
                      </td>
                      <td className="border-b py-2.5 pr-3 rule">
                        <span
                          className="type-label"
                          style={{ color: r.active ? "var(--color-teal)" : "var(--color-muted)" }}
                        >
                          {r.active ? (r.premium_source ?? "active") : "free"}
                        </span>
                        {r.active && r.premium_until ? (
                          <span className="type-num block text-[0.6875rem] text-muted">
                            to {new Date(r.premium_until).toLocaleDateString()}
                          </span>
                        ) : null}
                      </td>
                      <td className="type-num border-b py-2.5 pr-3 text-[0.8125rem] rule">
                        {r.hosted}
                      </td>
                      <td className="type-num border-b py-2.5 pr-3 text-[0.8125rem] rule">
                        {r.played}
                      </td>
                      <td className="type-num border-b py-2.5 pr-3 text-[0.75rem] text-muted rule">
                        {r.last_seat ? new Date(r.last_seat).toLocaleDateString() : "—"}
                      </td>
                      <td className="border-b py-2.5 text-right rule">
                        <div className="flex justify-end gap-1.5">
                          <Button
                            variant="ghost"
                            size="sm"
                            disabled={busy === r.id}
                            onClick={() =>
                              void call(r.id, "admin_set_premium", {
                                p_user_id: r.id,
                                p_days: Math.max(Number(days) || 30, 1),
                              })
                            }
                          >
                            +{Math.max(Number(days) || 30, 1)}d
                          </Button>
                          <Button
                            variant="quiet"
                            size="sm"
                            disabled={busy === r.id || !r.active}
                            onClick={() =>
                              void call(r.id, "admin_set_premium", { p_user_id: r.id, p_days: 0 })
                            }
                          >
                            Revoke
                          </Button>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="mt-3 text-[0.75rem] leading-relaxed text-muted">
              A grant writes the same <span className="type-num text-ink">premium_until</span> a
              subscription writes, so it unlocks exactly the same things. &ldquo;Last seat&rdquo;
              is the last time the account sat down in a room, not a live presence signal.
            </p>
          </section>
        ) : null}

        {tab === "library" ? (
          <section className="mt-6 flex flex-col gap-10">
            <div>
              <h2 className="type-display text-[1rem]">Waiting for review</h2>
              <p className="mt-1 text-[0.875rem] leading-relaxed text-muted">
                Lists a host offered to the public shelf after their draft. They have already
                passed the real-name heuristics; this is the human pass. Approving copies the
                names onto the shelf and nothing else — no room, no player, no timing.
              </p>
              {queue.length === 0 ? (
                <p className="type-label mt-4 border-b py-3 text-muted rule">nothing queued</p>
              ) : null}
              <ul className="mt-4 flex flex-col gap-4">
                {queue.map((q) => (
                  <li key={q.room_id} className="border p-4 rule">
                    <div className="flex flex-wrap items-baseline gap-3">
                      <span className="type-display text-[1rem]">{q.category}</span>
                      <span className="type-num text-[0.75rem] text-muted">
                        {q.item_count} items
                      </span>
                      {q.already_public ? (
                        <span className="type-label text-coral">name already on the shelf</span>
                      ) : null}
                      <div className="ml-auto flex gap-1.5">
                        <Button
                          variant="calm"
                          size="sm"
                          disabled={busy === q.room_id}
                          onClick={() =>
                            void call(q.room_id, "admin_review_library", {
                              p_room: q.room_id,
                              p_approve: true,
                            })
                          }
                        >
                          Approve
                        </Button>
                        <Button
                          variant="quiet"
                          size="sm"
                          disabled={busy === q.room_id}
                          onClick={() =>
                            void call(q.room_id, "admin_review_library", {
                              p_room: q.room_id,
                              p_approve: false,
                            })
                          }
                        >
                          Reject
                        </Button>
                      </div>
                    </div>
                    <p className="mt-3 text-[0.8125rem] leading-relaxed text-muted">
                      {q.items.join(" · ")}
                      {/* the RPC caps the sample at 200; say so rather than
                          letting the count and the list quietly disagree */}
                      {q.item_count > q.items.length ? (
                        <span className="type-label ml-2 text-coral">
                          + {q.item_count - q.items.length} more not shown
                        </span>
                      ) : null}
                    </p>
                  </li>
                ))}
              </ul>
            </div>

            <div>
              <h2 className="type-display text-[1rem]">On the shelf</h2>
              <ul className="mt-3 flex flex-col">
                {library.map((l) => (
                  <li key={l.id} className="flex items-baseline gap-3 border-b py-2.5 rule">
                    <span className="type-display text-[0.875rem]">{l.name}</span>
                    <span className="type-num text-[0.75rem] text-muted">{l.item_count}</span>
                    <Button
                      variant="quiet"
                      size="sm"
                      className="ml-auto"
                      disabled={busy === l.id}
                      onClick={() => void call(l.id, "admin_library_remove", { p_id: l.id })}
                    >
                      Remove
                    </Button>
                  </li>
                ))}
              </ul>
              <p className="mt-3 text-[0.75rem] leading-relaxed text-muted">
                Rooms copy their pool when they are created, so removing a category never
                disturbs a draft already using it.
              </p>
            </div>
          </section>
        ) : null}

        {tab === "activity" && activity ? (
          <section className="mt-6 flex flex-col gap-8">
            <dl className="grid grid-cols-2 gap-x-4 gap-y-5 sm:grid-cols-4">
              <Stat label="rooms today" value={activity.rooms.today} />
              <Stat label="this week" value={activity.rooms.week} />
              <Stat label="all time" value={activity.rooms.total} />
              <Stat label="live now" value={activity.rooms.live} />
            </dl>

            <div>
              <h2 className="type-display text-[1rem]">Rooms created</h2>
              <div className="mt-3 h-[200px] w-full">
                <ResponsiveContainer width="100%" height="100%">
                  <BarChart data={activity.daily}>
                    <CartesianGrid
                      vertical={false}
                      stroke="color-mix(in oklab, var(--color-muted) 20%, transparent)"
                    />
                    <XAxis
                      dataKey="day"
                      tickFormatter={(d: string) => d.slice(5)}
                      tick={{ fill: "var(--color-muted)", fontSize: 10 }}
                      axisLine={false}
                      tickLine={false}
                    />
                    <YAxis
                      allowDecimals={false}
                      width={28}
                      tick={{ fill: "var(--color-muted)", fontSize: 10 }}
                      axisLine={false}
                      tickLine={false}
                    />
                    <Tooltip
                      cursor={{ fill: "color-mix(in oklab, var(--color-muted) 12%, transparent)" }}
                      contentStyle={{
                        background: "var(--color-surface)",
                        border: "1px solid color-mix(in oklab, var(--color-muted) 40%, transparent)",
                        borderRadius: 3,
                        fontSize: 12,
                      }}
                      labelStyle={{ color: "var(--color-muted)" }}
                    />
                    <Bar dataKey="rooms" fill="var(--color-ink)" radius={[2, 2, 0, 0]} />
                  </BarChart>
                </ResponsiveContainer>
              </div>
            </div>

            <div className="grid gap-8 sm:grid-cols-2">
              <Split
                title="Where the picks came from"
                rows={[
                  ["Football Draft", activity.categories.football ?? 0],
                  ["other shelf categories", activity.categories.other_library ?? 0],
                  ["typed (wikipedia)", activity.categories.wikipedia ?? 0],
                  ["built by hand", activity.categories.manual ?? 0],
                  ["saved decks", activity.categories.saved ?? 0],
                ]}
              />
              <Split
                title="Room layout"
                rows={[
                  ["standard", activity.modes.standard],
                  ["content creator", activity.modes.creator],
                ]}
              />
              <Split
                title="Library"
                rows={[
                  ["public categories", activity.library.public],
                  ["waiting for review", activity.library.pending],
                  ["private saved decks", activity.library.saved_decks],
                ]}
              />
              <Split
                title="Premium and audience"
                rows={[
                  ["accounts with premium", activity.premium.active],
                  ...Object.entries(activity.premium.by_source).map(
                    ([k, n]) => [`  ${k}`, n] as [string, number],
                  ),
                  ["audience votes cast", activity.audience.votes],
                  ["drafts judged", activity.audience.rooms_voted_on],
                ]}
              />
            </div>

            <div>
              <h2 className="type-display text-[1rem]">How long a draft takes</h2>
              {activity.duration.sample === 0 ? (
                <p className="type-label mt-2 text-muted">
                  no finished drafts with a measurable start and end yet
                </p>
              ) : (
                <p className="mt-2 text-[0.9375rem] text-muted">
                  <span className="type-num text-ink">
                    {fmtDuration(activity.duration.median_seconds)}
                  </span>{" "}
                  median,{" "}
                  <span className="type-num text-ink">
                    {fmtDuration(activity.duration.avg_seconds)}
                  </span>{" "}
                  mean, over {activity.duration.sample} finished{" "}
                  {activity.duration.sample === 1 ? "draft" : "drafts"}.
                </p>
              )}
            </div>
          </section>
        ) : null}

        {tab === "events" ? (
          <section className="mt-6">
            <h2 className="type-display text-[1rem]">Billing events</h2>
            <p className="mt-1 text-[0.875rem] leading-relaxed text-muted">
              Every Stripe webhook this app has processed, and every one it failed to. This is
              the only error surface here — anything else worth reading is in Vercel&apos;s
              runtime logs, which is a log viewer nobody needs a second copy of.
            </p>
            <ul className="mt-4 flex flex-col">
              {events.length === 0 ? (
                <li className="type-label border-b py-3 text-muted rule">
                  nothing yet &middot; Stripe has never called
                </li>
              ) : null}
              {events.map((e) => (
                <li key={e.event_id} className="flex flex-wrap items-baseline gap-3 border-b py-2.5 rule">
                  <span
                    className="type-label shrink-0"
                    style={{
                      color: e.status === "failed" ? "var(--color-coral)" : "var(--color-teal)",
                    }}
                  >
                    {e.status}
                  </span>
                  <span className="type-display text-[0.8125rem]">{e.kind}</span>
                  <span className="min-w-0 flex-1 truncate font-mono text-[0.75rem] text-muted">
                    {e.detail || e.event_id}
                  </span>
                  <span className="type-num shrink-0 text-[0.75rem] text-muted">
                    {new Date(e.at).toLocaleString()}
                  </span>
                </li>
              ))}
            </ul>
          </section>
        ) : null}
      </main>
      <Footer />
    </>
  );
}

function Stat({ label, value }: { label: string; value: number }) {
  return (
    <div>
      <dt className="type-label text-muted">{label}</dt>
      <dd className="type-num text-[1.75rem] leading-none">{value}</dd>
    </div>
  );
}

function Split({ title, rows }: { title: string; rows: [string, number][] }) {
  const total = rows.reduce((t, [, n]) => t + n, 0);
  return (
    <div>
      <h3 className="type-label text-muted">{title}</h3>
      <ul className="mt-2 flex flex-col">
        {rows.map(([label, n]) => (
          <li key={label} className="flex items-baseline gap-2 border-b py-1.5 rule">
            <span className="min-w-0 flex-1 truncate text-[0.8125rem]">{label}</span>
            <span className="type-num text-[0.8125rem]">{n}</span>
            <span className="type-num w-10 shrink-0 text-right text-[0.6875rem] text-muted">
              {total > 0 ? `${Math.round((n / total) * 100)}%` : "—"}
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}

function fmtDuration(seconds: number | null): string {
  if (seconds === null || !Number.isFinite(seconds)) return "—";
  const m = Math.floor(seconds / 60);
  const s = Math.round(seconds % 60);
  return m > 0 ? `${m}m ${s}s` : `${s}s`;
}
