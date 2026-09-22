"use client";

import { useSyncExternalStore } from "react";

/**
 * The token that proves a lineup is yours to play.
 *
 * Same shape as the draft's seat store and for the same reason: the server
 * issues it once, every mutating call authenticates from it, and a refresh
 * must not cost you the run. It is scoped to one lineup and grants nothing
 * outside it.
 *
 * Its absence is also what the share link relies on. Open somebody else's
 * /rank/ABC123 and there is no token here, so the page shows the finished
 * lineup and asks you to rate it rather than trying to resume a game that is
 * not yours.
 */
const key = (code: string) => `df20:lineup:${code.toUpperCase()}`;

export function saveLineupToken(code: string, token: string): void {
  try {
    localStorage.setItem(key(code), token);
  } catch {
    /* private mode: the run still works, it just cannot be resumed */
  }
}

export function readLineupToken(code: string): string | null {
  try {
    return localStorage.getItem(key(code));
  } catch {
    return null;
  }
}

/**
 * Read the token the way the draft's seat store does, so the server render
 * and the first client render agree instead of flipping.
 *
 * An effect would mean setState on mount — a cascading render for a value
 * that never changes after load — and, worse, a first paint that has already
 * decided you are a VISITOR before localStorage has been consulted. The
 * server snapshot is "unknown", so the page holds its loading state rather
 * than showing a rating form to the person who is mid-run.
 *
 * A primitive snapshot is safe to return uncached: React compares it by
 * value, so there is no re-render loop.
 */
export function useLineupToken(code: string): string | null | undefined {
  return useSyncExternalStore(
    subscribe,
    () => readLineupToken(code),
    () => undefined, // server: not known yet
  );
}

/* Nothing outside this tab writes the token, so there is nothing to listen
   to — but useSyncExternalStore requires a subscribe, and `storage` is the
   honest one: it fires if another tab clears it. */
function subscribe(onChange: () => void): () => void {
  window.addEventListener("storage", onChange);
  return () => window.removeEventListener("storage", onChange);
}

/** The per-visitor id a rating is recorded against. Not an identity — it only
 *  stops one browser rating the same lineup twice. */
export function voterKey(): string {
  const k = "df20:voter";
  try {
    const found = localStorage.getItem(k);
    if (found && found.length >= 16) return found;
    const made = `v_${crypto.randomUUID().replace(/-/g, "")}`;
    localStorage.setItem(k, made);
    return made;
  } catch {
    return `v_${crypto.randomUUID().replace(/-/g, "")}`;
  }
}

export interface LineupCard {
  name: string;
  image_url: string | null;
  image_license?: string | null;
}
export interface PlacedCard extends LineupCard {
  slot: number;
}
export interface LineupState {
  code: string;
  category: string;
  slot_count: number;
  revealed: number;
  status: "live" | "complete" | "abandoned";
  current: (LineupCard & { position: number }) | null;
  slots: PlacedCard[];
  open_slots: number[];
  token?: string;
}
