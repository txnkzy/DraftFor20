"use client";

import { useCallback, useSyncExternalStore } from "react";

/**
 * Tiny WebAudio cues. Generated, not loaded, so this costs nothing in the
 * bundle and there is no asset to 404. Muted state is remembered.
 */
const KEY = "df20:muted";

export function isMuted(): boolean {
  try {
    return localStorage.getItem(KEY) === "1";
  } catch {
    return false;
  }
}

const listeners = new Set<() => void>();

export function setMuted(v: boolean) {
  try {
    localStorage.setItem(KEY, v ? "1" : "0");
  } catch {
    /* private browsing */
  }
  listeners.forEach((l) => l());
}

/** External store rather than effect-synced state, so the server render and
 *  the hydrated client agree: the server always reports "not muted". */
export function useMuted(): boolean {
  const subscribe = useCallback((cb: () => void) => {
    listeners.add(cb);
    window.addEventListener("storage", cb);
    return () => {
      listeners.delete(cb);
      window.removeEventListener("storage", cb);
    };
  }, []);
  return useSyncExternalStore(subscribe, isMuted, () => false);
}

let ctx: AudioContext | null = null;

/**
 * Why this exists.
 *
 * Every cue below fires from a useEffect reacting to state that arrived over
 * the network, never from a click handler. If the AudioContext is first
 * constructed there, browsers create it `suspended`, and resume() called
 * outside a user gesture is rejected. The old code did `void ctx.resume()`,
 * which threw that rejection away, so audio failed silently and permanently.
 *
 * It only ever appeared to work when the page happened to already have sticky
 * user activation, which is a race rather than a platform difference. So:
 * unlock explicitly on the first real gesture, and make every cue wait for a
 * live clock before scheduling.
 */
export function armAudio() {
  if (typeof window === "undefined") return () => {};
  const unlock = () => {
    try {
      ctx ??= new AudioContext();
      void ctx.resume();
      // a one-sample silent buffer is the standard way to convince a browser
      // the context is genuinely in use
      const b = ctx.createBuffer(1, 1, 22050);
      const src = ctx.createBufferSource();
      src.buffer = b;
      src.connect(ctx.destination);
      src.start(0);
      notifyReady();
    } catch {
      /* no audio device is not an error worth surfacing */
    }
  };
  const opts = { once: true, capture: true } as const;
  window.addEventListener("pointerdown", unlock, opts);
  window.addEventListener("keydown", unlock, opts);
  window.addEventListener("touchstart", unlock, opts);
  return () => {
    window.removeEventListener("pointerdown", unlock, true);
    window.removeEventListener("keydown", unlock, true);
    window.removeEventListener("touchstart", unlock, true);
  };
}

/** true once the context is actually running, so the UI can say so */
export function audioReady(): boolean {
  return ctx?.state === "running";
}
const readyListeners = new Set<() => void>();
function notifyReady() {
  readyListeners.forEach((l) => l());
}
export function useAudioReady(): boolean {
  const subscribe = useCallback((cb: () => void) => {
    readyListeners.add(cb);
    return () => {
      readyListeners.delete(cb);
    };
  }, []);
  return useSyncExternalStore(subscribe, audioReady, () => false);
}

function schedule(c: AudioContext, freq: number, ms: number, gain: number) {
  const t = c.currentTime;
  const osc = c.createOscillator();
  const amp = c.createGain();
  osc.type = "triangle";
  osc.frequency.setValueAtTime(freq, t);
  amp.gain.setValueAtTime(0, t);
  amp.gain.linearRampToValueAtTime(gain, t + 0.008);
  amp.gain.exponentialRampToValueAtTime(0.0001, t + ms / 1000);
  osc.connect(amp).connect(c.destination);
  osc.start(t);
  osc.stop(t + ms / 1000 + 0.02);
}

function tone(freq: number, ms: number, gain: number) {
  if (isMuted()) return;
  try {
    ctx ??= new AudioContext();
    const c = ctx;
    if (c.state === "running") {
      schedule(c, freq, ms, gain);
      return;
    }
    // suspended: resume FIRST, then read a fresh currentTime. Scheduling
    // against the frozen clock is what dropped the very first cue even when
    // resume eventually succeeded.
    void c
      .resume()
      .then(() => {
        notifyReady();
        if (c.state === "running") schedule(c, freq, ms, gain);
      })
      .catch(() => {
        /* still locked: the mute button shows "tap to enable" */
      });
  } catch {
    /* no audio device: silence is fine */
  }
}

/** someone pushed the price up */
export const cueRaise = () => tone(660, 120, 0.05);
/** a card locked into a roster */
export const cueLock = () => tone(392, 220, 0.045);
/** a fresh card hit the block */
export const cueDeal = () => tone(523, 90, 0.03);
