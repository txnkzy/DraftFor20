"use client";

import { useCallback, useEffect, useState } from "react";
import { supabaseBrowser, supabaseConfigured } from "@/lib/supabase/client";

/**
 * ONE definition of premium, read from the server.
 *
 * `active` is the database's answer to "is profiles.premium_until in the
 * future", and nothing else in the app is allowed to decide it. A Stripe
 * subscription, a Game Night Pass and a manual admin grant all write that one
 * field, so this hook cannot tell them apart and no gate needs to.
 *
 * Nothing here is a security boundary. Every premium action is refused again
 * by the RPC behind it; this only decides what the UI shows.
 */
export interface ExportStyle {
  watermark: boolean;
  logo_url: string | null;
  accent: string | null;
  handle: string | null;
}

export interface PremiumState {
  loading: boolean;
  signedIn: boolean;
  active: boolean;
  until: string | null;
  source: "stripe_subscription" | "admin_grant" | "game_night_pass" | null;
  status: string | null;
  hasCustomer: boolean;
  exportStyle: ExportStyle;
}

const DEFAULT_EXPORT: ExportStyle = {
  // the watermark starts on for everyone, tier included
  watermark: true,
  logo_url: null,
  accent: null,
  handle: null,
};

const EMPTY: PremiumState = {
  loading: true,
  signedIn: false,
  active: false,
  until: null,
  source: null,
  status: null,
  hasCustomer: false,
  exportStyle: DEFAULT_EXPORT,
};

interface RawPremium {
  signed_in?: boolean;
  active?: boolean;
  until?: string | null;
  source?: PremiumState["source"];
  status?: string | null;
  has_customer?: boolean;
  export?: Partial<ExportStyle>;
}

export function parsePremium(raw: unknown): PremiumState {
  const d = (raw ?? {}) as RawPremium;
  return {
    loading: false,
    signedIn: Boolean(d.signed_in),
    active: Boolean(d.active),
    until: d.until ?? null,
    source: d.source ?? null,
    status: d.status ?? null,
    hasCustomer: Boolean(d.has_customer),
    exportStyle: {
      watermark: d.export?.watermark ?? true,
      logo_url: d.export?.logo_url ?? null,
      accent: d.export?.accent ?? null,
      handle: d.export?.handle ?? null,
    },
  };
}

/** One read of the server's answer. Never throws: a database without 0017
 *  applied is simply not premium, which is not a reason to break a page. */
async function readPremium(): Promise<PremiumState> {
  if (!supabaseConfigured()) return { ...EMPTY, loading: false };
  try {
    const { data, error } = await supabaseBrowser().rpc("my_premium");
    if (error) return { ...EMPTY, loading: false };
    return parsePremium(data);
  } catch {
    return { ...EMPTY, loading: false };
  }
}

export function usePremium(): PremiumState & { refresh: () => Promise<void> } {
  const [state, setState] = useState<PremiumState>(EMPTY);

  const refresh = useCallback(async () => {
    setState(await readPremium());
  }, []);

  useEffect(() => {
    let off = false;
    void (async () => {
      const next = await readPremium();
      if (!off) setState(next);
    })();
    return () => {
      off = true;
    };
  }, []);

  return { ...state, refresh };
}

/**
 * Which features the paywall covers.
 *
 * Free is the premade shelf and nothing else. Every flag here is mirrored by
 * a check in the database — these only decide what the UI shows, and 0033 is
 * what actually refuses the request.
 */
export const PREMIUM_GATES = {
  contentTab: true,
  obsLink: true,
  exportCustomisation: true,
  customCategories: true,
  /** the public vote link is free — it is the acquisition loop. Only the
   *  host's live tally in the Content tab is premium. */
  audienceVote: false,
} as const;

export const PLANS = {
  premium: { label: "Premium", price: "$5", period: "/month" },
  pass: { label: "Game Night Pass", price: "$1", period: "for 24 hours" },
} as const;

export type PlanId = keyof typeof PLANS;
