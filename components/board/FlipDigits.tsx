"use client";

/**
 * Split-flap money. Digits roll to their new value instead of swapping, which
 * is the whole reason the numeral face is a tabular mono: nothing shifts
 * sideways while a number is changing.
 *
 * THE BASELINE. A digit is a window onto a strip of ten, so the window has to
 * clip — and an inline-block that clips reports its BOTTOM MARGIN EDGE as its
 * baseline rather than the baseline of the text inside it. Every digit
 * therefore sat higher than the "$" typed next to it and higher than the
 * clock beside it, which is what made a row of numbers look assembled out of
 * spare parts. The fix is to give the cell a real baseline of its own: an
 * invisible zero sits in normal flow and does nothing but establish it, and
 * the reel is taken out of flow on top. Both are line boxes of the same
 * height at the same font size, so the rolling digit lands exactly where the
 * invisible one already was.
 */

const H = 1.1; // em, per digit cell and per line box

function Digit({ value }: { value: number }) {
  return (
    <span
      className="relative inline-block text-center align-baseline"
      style={{ width: "1ch", lineHeight: `${H}em` }}
    >
      <span className="invisible" aria-hidden>
        0
      </span>
      <span
        className="absolute left-0 top-0 w-full overflow-hidden"
        style={{ height: `${H}em` }}
      >
        <span
          className="flex flex-col will-change-transform"
          style={{
            transform: `translateY(${-value * H}em)`,
            transition: "transform 320ms cubic-bezier(.2,.9,.3,1)",
          }}
        >
          {[0, 1, 2, 3, 4, 5, 6, 7, 8, 9].map((n) => (
            <span
              key={n}
              className="shrink-0 text-center"
              style={{ height: `${H}em`, lineHeight: `${H}em` }}
            >
              {n}
            </span>
          ))}
        </span>
      </span>
    </span>
  );
}

export function FlipDigits({
  text,
  className = "",
  urgent = false,
}: {
  /** already formatted, e.g. "$7" or "13.50" */
  text: string;
  className?: string;
  urgent?: boolean;
}) {
  return (
    <span
      className={`type-num inline-flex items-baseline ${className}`}
      style={{
        letterSpacing: urgent ? "-0.04em" : undefined,
        transition: "letter-spacing 160ms linear, color 160ms linear",
      }}
      aria-label={text}
    >
      {text.split("").map((ch, i) =>
        /\d/.test(ch) ? (
          <Digit key={`${i}-d`} value={Number(ch)} />
        ) : (
          <span key={`${i}-s`} aria-hidden style={{ lineHeight: `${H}em` }}>
            {ch}
          </span>
        ),
      )}
    </span>
  );
}
