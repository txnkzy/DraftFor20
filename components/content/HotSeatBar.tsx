"use client";

import { seatAccent } from "@/lib/game/view";
import type { Seat } from "@/lib/game/session";
import type { RoomState } from "@/lib/game/types";

/**
 * Pass-and-play, for two people sharing one computer.
 *
 * A Content Creator room is usually filmed on one camera with both players in
 * the shot, and asking them to bring a second laptop to sit next to each other
 * is a strange thing to require. When this device holds both seats the page
 * hands the controls to whoever is up, automatically, every time the clock
 * moves — so nobody has to remember to switch.
 *
 * This bar exists for the moments the game is not driving: the lobby, and the
 * vote after the final whistle, where both people act but neither is "on the
 * clock". It also stays tappable during play as an override, because a rule
 * that cannot be overridden is a rule that will be wrong once on camera.
 */
export function HotSeatBar({
  state,
  seats,
  activePlayerId,
  autoSwitching,
  onSwitch,
}: {
  state: RoomState;
  seats: Seat[];
  activePlayerId: string | null;
  /** the clock is currently choosing for them, so say so rather than imply a choice */
  autoSwitching: boolean;
  onSwitch: (playerId: string) => void;
}) {
  if (seats.length < 2) return null;

  const held = seats
    .map((s) => ({ seat: s, player: state.players.find((p) => p.id === s.playerId) }))
    .filter((x): x is { seat: Seat; player: NonNullable<typeof x.player> } => Boolean(x.player))
    .sort((a, b) => a.player.seat - b.player.seat);

  if (held.length < 2) return null;

  return (
    <div className="border p-2 rule">
      <p className="type-label text-muted">
        {autoSwitching ? "one computer · controls follow the clock" : "one computer · who is acting"}
      </p>
      <div className="mt-2 grid grid-cols-2 gap-2">
        {held.map(({ player }) => {
          const on = player.id === activePlayerId;
          return (
            <button
              key={player.id}
              type="button"
              aria-pressed={on}
              aria-label={on ? `${player.display_name} is acting` : `Hand the controls to ${player.display_name}`}
              onClick={() => onSwitch(player.id)}
              className={`flex min-h-11 items-center justify-center gap-2 border px-2 text-[0.8125rem] ${on ? "" : "rule"}`}
              style={{
                borderColor: on ? seatAccent(player.seat) : undefined,
                background: on ? "var(--color-surface)" : "transparent",
                color: on ? "var(--color-ink)" : "var(--color-muted)",
              }}
            >
              <span
                aria-hidden
                style={{
                  width: 8,
                  height: 8,
                  flexShrink: 0,
                  background: seatAccent(player.seat),
                  opacity: on ? 1 : 0.45,
                }}
              />
              <span className="truncate">{player.display_name}</span>
            </button>
          );
        })}
      </div>
    </div>
  );
}
