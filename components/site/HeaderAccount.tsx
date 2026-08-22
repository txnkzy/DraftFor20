"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useHost, signInHref, signUpHref } from "@/lib/auth";

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
    <Link href="/profile" className="type-label text-teal hover:text-ink" title={user.email ?? ""}>
      Profile
    </Link>
  );
}
