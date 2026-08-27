"use client";

import { useCallback, useSyncExternalStore } from "react";

/**
 * Anonymous player identity. The server issues a session token once, at
 * create_room / join_room, and every mutating RPC authenticates from it.
 * It lives in localStorage so a refresh keeps your seat. Scoped to one room,
 * grants nothing outside it, and disclosed in the privacy policy.
 *
 * A device may hold MORE THAN ONE seat in the same room. That is pass-and-play:
 * two people sharing one computer each join normally, both tokens are kept
 * here, and one of them is active at a time. The server is not involved and
 * does not need to be — join_room already hands out an independent token per
 * player, and every RPC still authenticates the single token it is given. All
 * this file does is decide which of the tokens the page is currently holding.
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

/** what actually goes in localStorage now */
interface Book {
  seats: Seat[];
  /** playerId of the seat whose token the page is acting as */
  active: string | null;
}

const key = (code: string) => `df20:seat:${code.toUpperCase()}`;

const listeners = new Set<() => void>();
/* Parsed books are cached against the exact raw string they came from, so
   useSyncExternalStore keeps getting the SAME array and object back between
   renders. Re-parsing per call would hand React a new reference every time
   and spin. */
const cache = new Map<string, { raw: string | null; book: Book | null }>();
const NO_SEATS: Seat[] = [];

function emit() {
  listeners.forEach((l) => l());
}

function isSeat(v: unknown): v is Seat {
  return Boolean(v) && typeof (v as Seat).sessionToken === "string" && Boolean((v as Seat).playerId);
}

function readBook(code: string): Book | null {
  let raw: string | null = null;
  try {
    raw = localStorage.getItem(key(code));
  } catch {
    return null;
  }
  const hit = cache.get(code);
  if (hit && hit.raw === raw) return hit.book;

  let book: Book | null = null;
  try {
    const parsed: unknown = raw ? JSON.parse(raw) : null;
    if (isSeat(parsed)) {
      /* written before a device could hold two seats: one bare Seat */
      book = { seats: [parsed], active: parsed.playerId };
    } else if (parsed && Array.isArray((parsed as Book).seats)) {
      const seats = (parsed as Book).seats.filter(isSeat);
      const active = (parsed as Book).active;
      book = seats.length
        ? { seats, active: seats.some((s) => s.playerId === active) ? active : seats[0].playerId }
        : null;
    }
  } catch {
    book = null;
  }
  cache.set(code, { raw, book });
  return book;
}

function write(code: string, book: Book | null) {
  try {
    if (!book || book.seats.length === 0) localStorage.removeItem(key(code));
    else localStorage.setItem(key(code), JSON.stringify(book));
  } catch {
    /* private browsing: the seat just won't survive a refresh */
  }
  emit();
}

/** Record a seat this device now holds, and act as it. */
export function saveSeat(s: Seat) {
  const book = readBook(s.code);
  const seats = (book?.seats ?? []).filter((x) => x.playerId !== s.playerId).concat(s);
  write(s.code, { seats, active: s.playerId });
}

/** Act as another seat this device already holds. Unknown ids are ignored. */
export function setActiveSeat(code: string, playerId: string) {
  const book = readBook(code);
  if (!book || book.active === playerId) return;
  if (!book.seats.some((s) => s.playerId === playerId)) return;
  write(code, { seats: book.seats, active: playerId });
}

/** Drop every seat this device holds in the room. */
export function clearSeat(code: string) {
  write(code, null);
}

export function loadSeat(code: string): Seat | null {
  const book = readBook(code);
  if (!book) return null;
  return book.seats.find((s) => s.playerId === book.active) ?? book.seats[0] ?? null;
}

export function loadSeats(code: string): Seat[] {
  return readBook(code)?.seats ?? NO_SEATS;
}

function useStore<T>(code: string, read: (code: string) => T, server: () => T): T {
  const subscribe = useCallback((cb: () => void) => {
    listeners.add(cb);
    window.addEventListener("storage", cb);
    return () => {
      listeners.delete(cb);
      window.removeEventListener("storage", cb);
    };
  }, []);
  const getSnapshot = useCallback(() => read(code), [code, read]);
  return useSyncExternalStore(subscribe, getSnapshot, server);
}

/** The seat whose token this page is currently acting as. */
export function useSeat(code: string): Seat | null {
  return useStore(code, loadSeat, () => null);
}

/** Every seat this device holds in the room. Two of these means pass-and-play. */
export function useSeats(code: string): Seat[] {
  return useStore(code, loadSeats, () => NO_SEATS);
}
