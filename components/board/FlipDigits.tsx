"use client";

/**
 * Split-flap money. Digits roll to their new value instead of swapping, which
 * is the whole reason the numeral face is a tabular mono: nothing shifts
 * sideways while a number is changing.
 */

const H = 1.06; // em, per digit cell

function Digit({ value }: { value: number }) {
  return (
    <span
      className="relative inline-block overflow-hidden align-baseline"
      style={{ height: `${H}em`, width: "1ch" }}
    >
      <span
        className="absolute left-0 top-0 flex flex-col will-change-transform"
        style={{
          transform: `translateY(${-value * 10}%)`,
          transition: "transform 320ms cubic-bezier(.2,.9,.3,1)",
        }}
      >
        {[0, 1, 2, 3, 4, 5, 6, 7, 8, 9].map((n) => (
          <span
            key={n}
            style={{ height: `${H}em`, lineHeight: `${H}em` }}
            className="text-center"
          >
            {n}
          </span>
        ))}
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
