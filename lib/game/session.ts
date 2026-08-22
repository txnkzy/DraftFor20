"use client";

import { useCallback, useSyncExternalStore } from "react";

/**
 * Anonymous player identity. The server issues a session token once, at
 * create_room / join_room, and every mutating RPC authenticates from it.
 * It lives in localStorage so a refresh keeps your seat. Scoped to one room,
 * grants nothing outside it, and disclosed in the privacy policy.
 *
 * Exposed as an external store rather than effect-synced state so the server
 * render and the hydrated client agree: the server always sees "no seat".
 */
export interface Seat {
  roomId: string;
  code: string;
  playerId: string;
  sessionToken: string;
  seat: number;
}

const key = (code: string) => `df20:seat:${code.toUpperCase()}`;

const listeners = new Set<() => void>();
const cache = new Map<string, { raw: string | null; value: Seat | null }>();

function emit() {
  listeners.forEach((l) => l());
}

export function saveSeat(s: Seat) {
  try {
    localStorage.setItem(key(s.code), JSON.stringify(s));
  } catch {
    /* private browsing: the seat just won't survive a refresh */
  }
  emit();
}

export function clearSeat(code: string) {
  try {
    localStorage.removeItem(key(code));
  } catch {
    /* no-op */
  }
  emit();
}

export function loadSeat(code: string): Seat | null {
  let raw: string | null = null;
  try {
    raw = localStorage.getItem(key(code));
  } catch {
    return null;
  }
  const hit = cache.get(code);
  if (hit && hit.raw === raw) return hit.value;
  let value: Seat | null = null;
  try {
    const parsed = raw ? (JSON.parse(raw) as Seat) : null;
    value = parsed?.sessionToken ? parsed : null;
  } catch {
    value = null;
  }
  cache.set(code, { raw, value });
  return value;
}

export function useSeat(code: string): Seat | null {
  const subscribe = useCallback((cb: () => void) => {
    listeners.add(cb);
    window.addEventListener("storage", cb);
    return () => {
      listeners.delete(cb);
      window.removeEventListener("storage", cb);
    };
  }, []);

  const getSnapshot = useCallback(() => loadSeat(code), [code]);

  return useSyncExternalStore(subscribe, getSnapshot, () => null);
}
