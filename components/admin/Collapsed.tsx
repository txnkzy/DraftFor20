"use client";

import { useState } from "react";

/**
 * Show the first few, keep the rest one tap away.
 *
 * Every list in this console rendered in full — accounts, billing events, the
 * audit log, the library — so reading the second thing on a page meant
 * scrolling past the ninetieth. Nothing is hidden: the count goes on the
 * button and the whole list is one press away, and under the cut-off no
 * button appears at all, so short lists look exactly as they did.
 *
 * A hook rather than a wrapper component because these lists are <tbody> and
 * <ul>: a <button> is not a valid child of either, so the caller has to place
 * it itself.
 */
export function useCollapsed<T>(items: T[], show = 8) {
  const [open, setOpen] = useState(false);
  const hidden = Math.max(items.length - show, 0);
  return {
    visible: open ? items : items.slice(0, show),
    hidden,
    open,
    toggle: () => setOpen((v) => !v),
    /** the button's words, so every list says the same thing */
    label: (noun: string) =>
      open ? `show fewer ${noun}` : `show all ${items.length} ${noun} (+${hidden})`,
  };
}
