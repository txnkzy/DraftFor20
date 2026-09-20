/**
 * Proportion bars for the console.
 *
 * These are part-of-whole and progressive-loss figures, not plotted series,
 * so they are CSS rather than another Recharts canvas: no bundle cost, and
 * they read as the Rail the rest of the product already uses.
 *
 * COLOUR IS NOT DECORATION HERE. The palette is semantic — coral is tension,
 * gold is money, teal is a thing resolved — so a chart that grabbed coral for
 * "bad" would quietly cost the board its vocabulary. Completion is a
 * resolution, so it is teal; everything else is ink on a muted track. Every
 * bar prints its own number beside it, so nothing is carried by colour alone
 * and the colourblind case is covered by construction rather than by luck.
 */

export function Meter({
  label,
  value,
  of,
  suffix,
  tone = "ink",
  note,
}: {
  label: string;
  value: number;
  /** the whole this is a part of; omit for a bar already expressed 0-100 */
  of?: number;
  /** printed after the figure — "%" or " of 9" */
  suffix?: string;
  tone?: "ink" | "teal" | "gold";
  note?: string;
}) {
  const whole = of ?? 100;
  const pct = whole > 0 ? Math.max(0, Math.min(100, (value / whole) * 100)) : 0;
  const colour =
    tone === "teal" ? "var(--color-teal)" : tone === "gold" ? "var(--color-gold)" : "var(--color-ink)";

  return (
    <div>
      <div className="flex items-baseline gap-3">
        <span className="type-label min-w-0 flex-1 truncate text-muted">{label}</span>
        <span className="type-num shrink-0 text-[0.875rem]" style={{ color: colour }}>
          {value}
          {suffix ?? (of !== undefined ? ` / ${of}` : "")}
        </span>
      </div>
      {/* 6px track, 4px rounded data-end, sitting on the surface rather than a
          box of its own — the number above is the precise read, the bar is the
          shape of it. */}
      <div
        className="mt-1.5 w-full overflow-hidden"
        style={{ height: 6, background: "var(--color-surface)", borderRadius: 3 }}
        role="img"
        aria-label={`${label}: ${value}${of !== undefined ? ` of ${of}` : ""}`}
      >
        <div
          style={{
            width: `${pct}%`,
            height: "100%",
            background: colour,
            borderRadius: 3,
            transition: "width 320ms cubic-bezier(.2,.9,.3,1)",
          }}
        />
      </div>
      {note ? <p className="mt-1 text-[0.75rem] leading-snug text-muted">{note}</p> : null}
    </div>
  );
}

/**
 * The weekly funnel as a funnel.
 *
 * Four counts that only make sense against the first one — created is the
 * denominator and every later stage is a survivor of it. Four tiles made you
 * do that division in your head; descending bars do it for you, and the shape
 * of the drop-off is the finding.
 */
export function Funnel({
  steps,
}: {
  steps: { label: string; value: number; note?: string }[];
}) {
  const top = steps[0]?.value ?? 0;
  return (
    <div className="flex flex-col gap-3">
      {steps.map((s, i) => {
        const pct = top > 0 ? (s.value / top) * 100 : 0;
        return (
          <div key={s.label}>
            <div className="flex items-baseline gap-3">
              <span className="type-label min-w-0 flex-1 truncate text-muted">{s.label}</span>
              {i > 0 && top > 0 ? (
                <span className="type-num shrink-0 text-[0.6875rem] text-muted">
                  {Math.round(pct)}%
                </span>
              ) : null}
              <span className="type-num w-8 shrink-0 text-right text-[0.875rem] text-ink">
                {s.value}
              </span>
            </div>
            <div
              className="mt-1.5 w-full overflow-hidden"
              style={{ height: 10, background: "var(--color-surface)", borderRadius: 3 }}
              role="img"
              aria-label={`${s.label}: ${s.value} of ${top}`}
            >
              <div
                style={{
                  width: `${pct}%`,
                  height: "100%",
                  /* the first bar is the whole; the survivors are lighter, so
                     the eye reads the loss rather than four equal claims */
                  background: i === 0 ? "var(--color-ink)" : "var(--color-teal)",
                  opacity: i === 0 ? 1 : 1 - i * 0.18,
                  borderRadius: 3,
                  transition: "width 320ms cubic-bezier(.2,.9,.3,1)",
                }}
              />
            </div>
          </div>
        );
      })}
    </div>
  );
}
