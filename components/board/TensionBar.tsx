"use client";

/** Server-authoritative countdown, drained right to left. Goes Klaxon at 5s. */
export function TensionBar({
  fraction,
  urgent,
  critical = false,
  height = 3,
}: {
  fraction: number;
  urgent: boolean;
  critical?: boolean;
  height?: number;
}) {
  return (
    <div
      className="relative w-full overflow-hidden"
      style={{ height, background: "color-mix(in oklab, var(--color-muted) 22%, transparent)" }}
      role="progressbar"
      aria-label="Time left to act"
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={Math.round(fraction * 100)}
    >
      <div
        className={`absolute inset-y-0 left-0 ${critical ? "anim-bar-critical" : ""}`}
        style={{
          width: `${fraction * 100}%`,
          background: urgent ? "var(--color-coral)" : "var(--color-coral)",
          transition: "width 90ms linear, background-color 160ms linear",
        }}
      />
    </div>
  );
}
