"use client";

import {
  PolarAngleAxis,
  PolarGrid,
  PolarRadiusAxis,
  Radar,
  RadarChart,
  ResponsiveContainer,
} from "recharts";
import { Padlock } from "@/components/premium/Padlock";
import { UpgradeCard } from "@/components/premium/UpgradeCard";
import { formatCents } from "@/lib/money";

export interface ScoutAxis {
  key: string;
  label: string;
  /** 0-100, so the four can share one shape */
  score: number;
  /** the real figure, in its own units */
  raw: number;
  unit: "%" | "cents" | "raises";
  note: string;
}

export interface ScoutReport {
  signed_in: boolean;
  drafts: number;
  title?: string;
  window: { premium: boolean; counted: number; total: number; cap: number | null };
  axes?: ScoutAxis[];
  totals?: Record<string, number>;
}

/**
 * Four numbers about HOW somebody drafts, on one shape.
 *
 * ONE SERIES, so there is no categorical palette to get wrong and no legend
 * to need: the shape is you, drawn in the bone that already means "a player"
 * in this app, against a recessive grid. Coral, gold and teal all carry game
 * state elsewhere and would start lying if they were used for decoration
 * here.
 *
 * The four axes are normalised to 0-100 by the server so they can share a
 * radius. That makes the shape comparable and the numbers meaningless, which
 * is why the real figures are printed underneath in their own units — that
 * list is also the table view a chart owes anyone who cannot read the shape.
 */
const TITLES: Record<string, { name: string; blurb: string }> = {
  sniper: { name: "The Sniper", blurb: "You buy at the minimum and let them overpay." },
  whale: { name: "The Whale", blurb: "When you want a card you pay what it takes." },
  instigator: { name: "The Instigator", blurb: "You push the price up and walk away." },
  hoarder: { name: "The Hoarder", blurb: "You finish with money still in your pocket." },
  allrounder: { name: "No tell yet", blurb: "Nothing in your play stands out far enough to name." },
  unread: { name: "Unread", blurb: "Two finished drafts and this starts to mean something." },
};

function rawLabel(a: ScoutAxis): string {
  if (a.unit === "cents") return formatCents(a.raw);
  if (a.unit === "%") return `${a.raw}%`;
  return String(a.raw);
}

export function ScoutingReport({
  report,
  signedIn,
}: {
  report: ScoutReport;
  signedIn: boolean;
}) {
  const axes = report.axes ?? [];
  const w = report.window;
  const capped = !w.premium && w.total > w.counted;

  if (report.drafts === 0) {
    return (
      <section className="mt-9">
        <h2 className="type-display text-[1rem]">Scouting report</h2>
        <p className="mt-1.5 text-[0.875rem] leading-relaxed text-muted">
          Finish a draft and this fills in: how often you buy at the minimum, what you pay when
          you don&apos;t, how much of the bidding you start without finishing, and what you tend
          to have left at the end.
        </p>
      </section>
    );
  }

  const title = TITLES[report.title ?? "unread"] ?? TITLES.unread;
  const data = axes.map((a) => ({ axis: a.label, score: a.score }));

  return (
    <section className="mt-9">
      <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <h2 className="type-display text-[1rem]">Scouting report</h2>
        <span className="type-label text-muted">
          {w.premium ? `all ${w.counted} drafts` : `last ${w.counted} of ${w.total}`}
        </span>
      </div>

      <div className="mt-4 border p-4 rule">
        <p className="type-display text-[1.375rem]" style={{ color: "var(--color-teal)" }}>
          {title.name}
        </p>
        <p className="mt-1 text-[0.875rem] leading-relaxed text-muted">{title.blurb}</p>

        <div className="mt-4 h-[260px] w-full">
          <ResponsiveContainer width="100%" height="100%">
            <RadarChart data={data} outerRadius="72%">
              <PolarGrid
                stroke="color-mix(in oklab, var(--color-muted) 30%, transparent)"
                radialLines
              />
              <PolarAngleAxis
                dataKey="axis"
                tick={{
                  fill: "var(--color-muted)",
                  fontSize: 11,
                  fontFamily: "var(--font-display)",
                  letterSpacing: "0.09em",
                }}
              />
              {/* the radius is a normalised 0-100, and saying so is more
                  honest than an unlabelled ring */}
              <PolarRadiusAxis domain={[0, 100]} tick={false} axisLine={false} />
              <Radar
                dataKey="score"
                stroke="var(--color-ink)"
                strokeWidth={2}
                fill="var(--color-ink)"
                fillOpacity={0.16}
                dot={{ r: 4, fill: "var(--color-ink)", stroke: "none" }}
                isAnimationActive={false}
              />
            </RadarChart>
          </ResponsiveContainer>
        </div>

        {/* the same four numbers, in units that mean something */}
        <ul className="mt-2 flex flex-col">
          {axes.map((a) => (
            <li key={a.key} className="flex items-baseline gap-3 border-b py-2.5 rule">
              <span className="type-label w-[5.5rem] shrink-0 text-ink">{a.label}</span>
              <span className="type-num shrink-0 text-[1rem] text-gold">{rawLabel(a)}</span>
              <span className="min-w-0 flex-1 text-right text-[0.75rem] leading-snug text-muted">
                {a.note}
              </span>
            </li>
          ))}
        </ul>
      </div>

      {capped ? (
        <div className="mt-3">
          <p className="type-label flex items-center gap-1.5 text-muted">
            <Padlock size={12} /> reading your last {w.counted} drafts of {w.total}
          </p>
          <UpgradeCard feature="your full draft history" signedIn={signedIn} />
        </div>
      ) : null}
    </section>
  );
}
