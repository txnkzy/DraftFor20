import { Rail } from "@/components/board/Rail";
import { formatCents } from "@/lib/money";

/** A real rail at a real moment: $13 left, 4 players still owed, $1 minimum. */
export function ReserveDiagram() {
  const starting = 2000;
  const bankroll = 1300;
  const maxLegal = 1000; // 13 - (1 x 3)

  return (
    <figure className="panel flex flex-col gap-3 p-5" style={{ borderRadius: "var(--radius-card)" }}>
      <div className="flex items-baseline justify-between">
        <span className="type-display text-[0.9375rem]">Ari</span>
        <span className="type-num text-[1.25rem] text-gold">{formatCents(bankroll)}</span>
      </div>

      <Rail
        startingCents={starting}
        bankrollCents={bankroll}
        maxLegalBidCents={maxLegal}
        markerCents={800}
        accent="var(--color-gold)"
        height={16}
      />

      <figcaption className="grid grid-cols-3 gap-2 pt-1">
        <Legend swatch="rail-spent" label="spent" value={formatCents(starting - bankroll)} />
        <Legend swatch="bg-gold" label="can bid" value={formatCents(maxLegal)} />
        <Legend swatch="hatch-reserve" label="reserved" value={formatCents(bankroll - maxLegal)} />
      </figcaption>

      <p className="text-[0.8125rem] leading-relaxed text-muted">
        Three players still owed at $1 each, so $3 is hatched off and untouchable. The marker is
        a standing bid of $8. Push it past the hatch and the server says no.
      </p>
    </figure>
  );
}

function Legend({ swatch, label, value }: { swatch: string; label: string; value: string }) {
  return (
    <div className="flex flex-col gap-1">
      <span className={`h-2 w-full ${swatch}`} aria-hidden />
      <span className="type-label text-muted">{label}</span>
      <span className="type-num text-[0.8125rem]">{value}</span>
    </div>
  );
}
