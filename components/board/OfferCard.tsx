"use client";

import { Button } from "@/components/ui/Button";
import { formatCents } from "@/lib/money";
import type { OfferChoice } from "@/lib/game/types";

/**
 * The opener's call on a freshly dealt card. Two moves, and the second one is
 * the interesting one: handing the card to your opponent costs you nothing and
 * costs them a roster spot they did not choose. Gives are budgeted, so this is
 * a weapon you spend rather than a way to sit the draft out.
 */
export function OfferCard({
  minBidCents,
  canTake,
  canGive,
  givesLeft,
  opponentName,
  pending,
  onDecide,
}: {
  minBidCents: number;
  canTake: boolean;
  canGive: boolean;
  givesLeft: number;
  opponentName: string;
  pending: boolean;
  onDecide: (choice: OfferChoice) => void;
}) {
  if (!canTake && !canGive) {
    return (
      <div className="flex flex-col gap-3">
        <p className="text-[0.875rem] text-muted">
          You can&apos;t cover the minimum and {opponentName} has no room left. Nothing to do
          with this one.
        </p>
        <Button variant="ghost" size="lg" disabled={pending} onClick={() => onDecide("discard")}>
          Let it go
        </Button>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-stretch gap-2">
        <Button
          variant="primary"
          size="lg"
          className="flex-[3]"
          disabled={pending || !canTake}
          onClick={() => onDecide("take")}
        >
          Take &middot; {formatCents(minBidCents)}
        </Button>
        <Button
          variant="calm"
          size="lg"
          className="flex-[2]"
          disabled={pending || !canGive}
          onClick={() => onDecide("give")}
        >
          Give away
        </Button>
      </div>

      <p className="text-center text-[0.75rem] leading-snug text-muted">
        {canGive ? (
          <>
            Take them and {opponentName} can still bid you up. Give them away and they land on{" "}
            {opponentName}&apos;s roster for nothing, burning a spot they didn&apos;t pick.{" "}
            <span className="type-num text-teal">{givesLeft}</span> give
            {givesLeft === 1 ? "" : "s"} left.
          </>
        ) : givesLeft <= 0 ? (
          <>You&apos;re out of gives. Taking is the only move now.</>
        ) : (
          <>{opponentName}&apos;s roster is full, so there&apos;s nobody to hand this to.</>
        )}
      </p>
    </div>
  );
}
