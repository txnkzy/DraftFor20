"use client";

import { useState } from "react";
import { Button } from "@/components/ui/Button";
import { FlipDigits } from "./FlipDigits";
import { digitsOf, formatCents } from "@/lib/money";
import { minRaise } from "@/lib/game/rules";

/**
 * The thumb zone. Stepper plus two hard-edged buttons, nothing else. Copy has
 * to be readable at a glance while a countdown drains.
 */
export function ActionBar({
  currentBidCents,
  minBidCents,
  maxLegalBidCents,
  pending,
  onRaise,
  onPass,
}: {
  currentBidCents: number;
  minBidCents: number;
  maxLegalBidCents: number;
  pending: boolean;
  onRaise: (cents: number) => void;
  onPass: () => void;
}) {
  const floor = minRaise(currentBidCents, minBidCents);
  const ceiling = maxLegalBidCents;
  const canRaise = ceiling >= floor;
  const step = minBidCents > 0 ? minBidCents : 25;

  // remounted with a fresh key every turn, so plain initial state is the reset
  const [amount, setAmount] = useState(floor);

  const clamp = (v: number) => Math.max(floor, Math.min(ceiling, v));
  const atMax = amount >= ceiling;

  return (
    <div className="flex flex-col gap-2.5">
      {canRaise ? (
        <div className="flex items-stretch gap-2">
          <Button
            variant="quiet"
            size="lg"
            className="w-14 shrink-0 text-lg"
            aria-label={`Lower the bid by ${formatCents(step)}`}
            disabled={pending || amount <= floor}
            onClick={() => setAmount((a) => clamp(a - step))}
          >
            &minus;
          </Button>

          <div className="panel flex flex-1 flex-col items-center justify-center py-1.5">
            <span className="type-label text-muted">your bid</span>
            <span className="text-[1.75rem] leading-none text-ink">
              <span className="type-num">$</span>
              <FlipDigits text={digitsOf(amount)} />
            </span>
          </div>

          <Button
            variant="quiet"
            size="lg"
            className="w-14 shrink-0 text-lg"
            aria-label={`Raise the bid by ${formatCents(step)}`}
            disabled={pending || atMax}
            onClick={() => setAmount((a) => clamp(a + step))}
          >
            +
          </Button>
        </div>
      ) : null}

      <div className="flex items-stretch gap-2">
        {canRaise ? (
          <Button
            variant="primary"
            size="lg"
            className="flex-[2]"
            disabled={pending}
            onClick={() => onRaise(clamp(amount))}
          >
            Raise to {formatCents(amount)}
          </Button>
        ) : (
          <div className="panel flex flex-[2] items-center justify-center px-3 py-3 text-center">
            <span className="type-label text-coral">no room left &middot; you can only pass</span>
          </div>
        )}
        <Button variant="ghost" size="lg" className="flex-1" disabled={pending} onClick={onPass}>
          Pass
        </Button>
      </div>

      <p className="type-num text-center text-[0.6875rem] text-muted">
        {canRaise
          ? `most you can legally bid: ${formatCents(ceiling)}`
          : `${formatCents(currentBidCents)} is past your limit of ${formatCents(ceiling)}`}
      </p>
    </div>
  );
}
