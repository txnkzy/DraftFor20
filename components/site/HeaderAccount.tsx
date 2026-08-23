"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useHost, signInHref, signUpHref } from "@/lib/auth";
import { usePremium } from "@/lib/premium";

/** Sign in, or who you are signed in as. Hosting a custom category needs one.
 *  Signed in, this points at the profile: stats, decks and plan live there,
 *  and host settings are one link further in. */
export function HeaderAccount() {
  const { user } = useHost();
  const pathname = usePathname();

  // Default to "Sign in" while auth resolves rather than a blank placeholder:
  // signed-out is the common case, it is what the server can render, and a
  // gap that pops into a link a beat later reads as a broken header.
  if (!user) {
    const next = pathname || "/new";
    return (
      <span className="flex items-baseline gap-3">
        <Link href={signInHref(next)} className="type-label text-muted hover:text-ink">
          Sign in
        </Link>
        <Link href={signUpHref(next)} className="type-label text-muted hover:text-ink">
          Sign up
        </Link>
      </span>
    );
  }

  return (
    <span className="flex items-baseline gap-2">
      <PremiumMark />
      <Link href="/profile" className="type-label text-teal hover:text-ink" title={user.email ?? ""}>
        Profile
      </Link>
    </span>
  );
}

/**
 * A small mark next to Profile when premium is live.
 *
 * Rendered only for a signed-in visitor, so an anonymous page load does not
 * pay for the premium lookup on every single page.
 *
 * Teal, not gold: gold means money in this palette and this is not a figure —
 * it is the same "resolved, you have this" teal the padlock uses when open.
 */
function PremiumMark() {
  const premium = usePremium();
  if (!premium.active) return null;
  return (
    <span
      className="type-label border px-1.5 py-0.5"
      style={{ color: "var(--color-teal)", borderColor: "var(--color-teal)" }}
      title={
        premium.source === "game_night_pass"
          ? "Game Night Pass active"
          : "Premium active"
      }
    >
      {premium.source === "game_night_pass" ? "pass" : "premium"}
    </span>
  );
}
