import type { Metadata } from "next";
import Link from "next/link";
import { Header } from "@/components/site/Chrome";
import { supabaseServer } from "@/lib/supabase/server";
import { SITE_URL } from "@/lib/site";
import { SortTabs } from "./SortTabs";

export const metadata: Metadata = {
  title: "Leaderboard — DraftFor20",
  description:
    "Who has drafted the most, and who the audience keeps voting for. Wins are decided by the blind audience vote, not by an algorithm.",
  alternates: { canonical: `${SITE_URL}/leaderboard` },
};

/* Rebuilt at most once a minute. The board reads every completed room, and a
   fresh count per visitor buys nobody anything — nothing here changes between
   one page view and the next. */
export const revalidate = 60;

type Sort = "wins" | "drafts" | "rate";

interface Row {
  rank: number;
  handle: string;
  display_name: string | null;
  drafts: number;
  wins: number;
  losses: number;
  undecided: number;
  win_pct: number;
  avg_leftover_cents: number;
}

const SORTS: { id: Sort; label: string; note: string }[] = [
  { id: "wins", label: "Most wins", note: "Drafts the audience voted them the winner of." },
  { id: "drafts", label: "Most drafts", note: "Completed drafts played while signed in." },
  {
    id: "rate",
    label: "Win rate",
    note: "Share of decided drafts won. Needs 5 drafts to appear — a single lucky win is not a record.",
  },
];

export default async function LeaderboardPage({
  searchParams,
}: {
  searchParams: Promise<{ sort?: string }>;
}) {
  const sp = await searchParams;
  const sort: Sort =
    sp.sort === "drafts" || sp.sort === "rate" ? sp.sort : "wins";

  const sb = await supabaseServer();
  let rows: Row[] = [];
  let failed = false;
  if (sb) {
    const { data, error } = await sb.rpc("df20_leaderboard", { p_sort: sort, p_limit: 50 });
    if (error) failed = true;
    else rows = (data as Row[] | null) ?? [];
  } else {
    failed = true;
  }

  const active = SORTS.find((s) => s.id === sort)!;

  return (
    <>
      <Header thin />
      <main className="mx-auto w-full max-w-3xl px-4 py-10">
        <h1 className="type-display text-[2rem]">Leaderboard</h1>
        <p className="mt-2 max-w-xl text-[0.9375rem] leading-relaxed text-muted">
          Wins are the audience&apos;s call, not ours. A draft counts here once it is finished
          and the vote has a clear majority &mdash; a tie is nobody&apos;s win.
        </p>

        <SortTabs sort={sort} />
        <p className="mt-2 text-[0.8125rem] text-muted">{active.note}</p>

        {failed ? (
          <p className="mt-8 type-label text-coral">the board could not be loaded</p>
        ) : rows.length === 0 ? (
          <div className="mt-8 border border-dashed p-6 rule">
            <p className="type-label text-muted">nobody qualifies yet</p>
            <p className="mt-2 text-[0.875rem] leading-relaxed text-muted">
              {sort === "rate"
                ? "Nobody has finished five drafts signed in yet."
                : "Finish a draft while signed in and you will appear here."}
            </p>
            <Link href="/new" className="btn btn-primary mt-4 h-11 px-4 text-[0.8125rem]">
              Start a room
            </Link>
          </div>
        ) : (
          <>
            {/* The table scrolls inside its own box rather than pushing the
                page sideways on a phone. */}
            <div className="mt-6 overflow-x-auto">
              <table className="w-full min-w-[34rem] border-collapse text-left">
                <thead>
                  <tr className="type-label text-muted">
                    <th className="w-10 border-b py-2 pr-2 rule">#</th>
                    <th className="border-b py-2 pr-2 rule">player</th>
                    <th className="border-b py-2 pr-2 text-right rule">drafts</th>
                    <th className="border-b py-2 pr-2 text-right rule">won</th>
                    <th className="border-b py-2 pr-2 text-right rule">lost</th>
                    <th className="border-b py-2 text-right rule">win rate</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((r) => (
                    <tr key={r.handle}>
                      <td className="type-num border-b py-3 pr-2 text-[0.8125rem] text-muted rule">
                        {r.rank}
                      </td>
                      <td className="border-b py-3 pr-2 rule">
                        <span className="text-[0.9375rem] text-ink">
                          {r.display_name ?? `@${r.handle}`}
                        </span>
                        {r.display_name ? (
                          <span className="type-num ml-2 text-[0.75rem] text-muted">
                            @{r.handle}
                          </span>
                        ) : null}
                      </td>
                      <td className="type-num border-b py-3 pr-2 text-right text-[0.9375rem] rule">
                        {r.drafts}
                      </td>
                      <td className="type-num border-b py-3 pr-2 text-right text-[0.9375rem] text-gold rule">
                        {r.wins}
                      </td>
                      <td className="type-num border-b py-3 pr-2 text-right text-[0.9375rem] text-muted rule">
                        {r.losses}
                      </td>
                      <td className="type-num border-b py-3 text-right text-[0.9375rem] rule">
                        {r.undecided === r.drafts ? (
                          <span className="text-muted">&mdash;</span>
                        ) : (
                          `${r.win_pct}%`
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            <p className="mt-4 text-[0.75rem] leading-relaxed text-muted">
              Only drafts played while signed in are counted &mdash; an anonymous seat has no
              account to credit. A dash under win rate means none of that player&apos;s drafts
              have been voted on yet.
            </p>
          </>
        )}
      </main>
    </>
  );
}
