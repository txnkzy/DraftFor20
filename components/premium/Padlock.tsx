"use client";

/**
 * The padlock, used everywhere a premium feature is visible but shut.
 *
 * Premium UI is never hidden: a feature nobody can see is a feature nobody
 * upgrades for. It is shown, locked, and clicking it explains the way in.
 *
 * Colour: muted, not coral or teal. Those two carry game state and a paywall
 * is not game state. Prices are gold, because gold is money.
 */
export function Padlock({ size = 12, open = false }: { size?: number; open?: boolean }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.6}
      aria-hidden
      style={{ display: "inline-block", verticalAlign: "-0.1em", flexShrink: 0 }}
    >
      <rect x="3" y="7" width="10" height="7" rx="1" />
      {open ? (
        <path d="M5.5 7V4.5a2.5 2.5 0 0 1 5 0" />
      ) : (
        <path d="M5.5 7V4.5a2.5 2.5 0 0 1 5 0V7" />
      )}
    </svg>
  );
}

export function LockChip({ label = "premium", active = false }: { label?: string; active?: boolean }) {
  return (
    <span
      className="type-label inline-flex items-center gap-1.5 border px-1.5 py-1"
      style={{
        color: active ? "var(--color-teal)" : "var(--color-muted)",
        borderColor: active
          ? "var(--color-teal)"
          : "color-mix(in oklab, var(--color-muted) 45%, transparent)",
      }}
    >
      <Padlock open={active} />
      {active ? "unlocked" : label}
    </span>
  );
}
