"use client";

import { Button } from "@/components/ui/Button";
import { formatCents } from "@/lib/money";
import type { OfferChoice } from "@/lib/game/types";

/**
 * The opener's call on a freshly dealt card. Two moves, and the second one is
 * the interesting one: handing the card to your opponent costs you nothing and
 * costs them a roster spot they did not choose. Gives are budgeted, so this is
 * a weapon you spend rather than a way to sit the draft out.
 *
 * THE THIRD MOVE IS NOT A CHOICE. A player who has spent down past the
 * minimum bid cannot Take, and once their gives are gone they cannot Give
 * either — and they still owe roster slots. This used to render a "Let it go"
 * button, which dealt the next card, which they also could not afford, until
 * the deck ran out and the results screen called them disqualified. Now the
 * card lands on their own roster for nothing. It is the floor of the format,
 * not a punishment, so it is presented as the move it is rather than as an
 * error state.
 */
export function OfferCard({
  minBidCents,
  canTake,
  canGive,
  canForce,
  givesLeft,
  givesUnlimited = false,
  opponentName,
  pending,
  onDecide,
}: {
  minBidCents: number;
  canTake: boolean;
  canGive: boolean;
  /** short of the minimum bid, but still owed slots: the card lands free */
  canForce: boolean;
  givesLeft: number;
  /** the cap cannot bind, so don't count down toward it */
  givesUnlimited?: boolean;
  opponentName: string;
  pending: boolean;
  onDecide: (choice: OfferChoice) => void;
}) {
  /* Broke, and nobody to hand it to. The card is theirs either way, so the
     only honest thing to render is the button that says so. */
  if (!canTake && !canGive && canForce) {
    return (
      <div className="flex flex-col gap-3">
        <Button
          variant="primary"
          size="lg"
          disabled={pending}
          onClick={() => onDecide("force")}
        >
          Take it free
        </Button>
        <p className="text-center text-[0.75rem] leading-snug text-muted">
          You can&apos;t cover the {formatCents(minBidCents)} minimum and you&apos;re out of
          gives, so this one lands on your roster for nothing. That&apos;s the cost of
          spending big earlier.
        </p>
      </div>
    );
  }

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
            {givesUnlimited ? (
              <>Gives are unlimited here.</>
            ) : (
              <>
                <span className="type-num text-teal">{givesLeft}</span> give
                {givesLeft === 1 ? "" : "s"} left.
              </>
            )}
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
