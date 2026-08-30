"use client";

import { useState } from "react";
import { Button } from "@/components/ui/Button";
import { FlipDigits } from "./FlipDigits";
import { centsToInput, digitsOf, formatCents, parseDollarsToCents } from "@/lib/money";
import { minRaise } from "@/lib/game/rules";

/**
 * The thumb zone. Stepper plus two hard-edged buttons, nothing else. Copy has
 * to be readable at a glance while a countdown drains.
 *
 * The amount is also TYPEABLE. The stepper is right for nudging a bid by one
 * increment, and wrong for jumping to $12 with a clock draining — that was
 * eleven taps. Tapping the number turns it into a field; the stepper and the
 * Raise button are unchanged, and a bid is still only ever placed by pressing
 * Raise, so a mistyped number cannot spend anything on its own.
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
  const ceiling = maxLegalBidCents;
  /* The TRUE legal floor, which is a single CENT over the standing bid in a
     room with no minimum. That is what the server will accept; it is not what
     anybody wants to press a plus button forty times to reach. */
  const legalFloor = minRaise(currentBidCents, minBidCents);
  const canRaise = ceiling >= legalFloor;

  /* BIDS MOVE IN WHOLE DOLLARS. The stepper used to nudge by the room's
     minimum bid, falling back to 25c when that was zero — so a $0-minimum
     room raised in quarters and the board filled up with $3.28 and $7.53.
     A dollar is the unit people say out loud, so a dollar is the unit.

     The floor is still clamped to the ceiling: a player with 40c of headroom
     over the standing bid can legally win with it, and rounding the floor up
     to a whole dollar would hide the only bid they had left. */
  const step = 100;
  const floor = canRaise ? Math.min(Math.max(legalFloor, currentBidCents + step), ceiling) : legalFloor;

  // remounted with a fresh key every turn, so plain initial state is the reset
  const [amount, setAmount] = useState(floor);
  /** null while showing the number, a draft string while it is being typed */
  const [typed, setTyped] = useState<string | null>(null);

  const clamp = (v: number) => Math.max(floor, Math.min(ceiling, v));

  /* What Raise would actually place right now. Tapping Raise straight from
     the field blurs it and commits in the same tick, but the click handler
     has already closed over the OLD amount — so it would have bid the number
     that was there before it was typed. Reading the draft here means the
     button and the field can never disagree. */
  const effective = clamp(
    typed !== null ? (parseDollarsToCents(typed) ?? amount) : amount,
  );
  const atMax = effective >= ceiling;

  /* THE STEPPER CLOSES THE FIELD. It used to nudge `amount` while the typed
     draft was still on screen, so the number the player was looking at did
     not move and neither did the Raise button — the counter simply froze
     until the page was reloaded. It only self-corrected if the field happened
     to blur first, which is not something a touch keyboard can be relied on
     to do. Stepping from what is displayed, and dropping the draft, is right
     whether or not a blur ever arrives. */
  function step_(direction: 1 | -1) {
    setTyped(null);
    setAmount(clamp(effective + direction * step));
  }

  function commit(raw: string) {
    setTyped(null);
    const cents = parseDollarsToCents(raw);
    // Gibberish, or an empty field, leaves the standing amount alone rather
    // than resetting it to the minimum under somebody's thumb.
    if (cents !== null) setAmount(clamp(cents));
  }

  return (
    <div className="flex flex-col gap-2.5">
      {canRaise ? (
        <div className="flex items-stretch gap-2">
          <Button
            variant="quiet"
            size="lg"
            className="w-14 shrink-0 text-lg"
            aria-label={`Lower the bid by ${formatCents(step)}`}
            disabled={pending || effective <= floor}
            onClick={() => step_(-1)}
          >
            &minus;
          </Button>

          <div className="panel flex flex-1 flex-col items-center justify-center py-1.5">
            <span className="type-label text-muted">your bid</span>
            {typed === null ? (
              <button
                type="button"
                className="text-[1.75rem] leading-none text-ink"
                aria-label={`Your bid, ${formatCents(amount)}. Tap to type an amount.`}
                disabled={pending}
                onClick={() => setTyped(centsToInput(amount))}
              >
                <span className="type-num">$</span>
                <FlipDigits text={digitsOf(amount)} />
              </button>
            ) : (
              <span className="flex items-baseline text-[1.75rem] leading-none text-ink">
                <span className="type-num">$</span>
                <input
                  autoFocus
                  inputMode="decimal"
                  className="type-num bg-transparent text-left text-[1.75rem] leading-none text-ink outline-none"
                  /* Sized to what has been typed rather than a fixed box, so
                     the "$" stays welded to its number instead of sitting a
                     centred field's worth of empty space away. The numeral
                     face is tabular, so a ch is exactly a digit. */
                  style={{ width: `${Math.max(typed.length, 1) + 0.5}ch` }}
                  aria-label={`Your bid in dollars, between ${formatCents(floor)} and ${formatCents(ceiling)}`}
                  value={typed}
                  // partial entries like "" and "12." have to survive being
                  // typed, so only the shape is policed here and the value is
                  // parsed on the way out
                  onChange={(e) => {
                    const v = e.target.value.replace(/[^\d.]/g, "");
                    if (/^\d*\.?\d{0,2}$/.test(v)) setTyped(v);
                  }}
                  onFocus={(e) => e.target.select()}
                  onBlur={(e) => commit(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === "Enter") {
                      e.preventDefault();
                      commit(e.currentTarget.value);
                    } else if (e.key === "Escape") {
                      e.preventDefault();
                      setTyped(null);
                    }
                  }}
                />
              </span>
            )}
          </div>

          <Button
            variant="quiet"
            size="lg"
            className="w-14 shrink-0 text-lg"
            aria-label={`Raise the bid by ${formatCents(step)}`}
            disabled={pending || atMax}
            onClick={() => step_(1)}
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
            onClick={() => onRaise(effective)}
          >
            Raise to {formatCents(effective)}
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
          ? `${formatCents(floor)} to ${formatCents(ceiling)}`
          : `${formatCents(currentBidCents)} is past your limit of ${formatCents(ceiling)}`}
      </p>
    </div>
  );
}
