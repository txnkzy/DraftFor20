"use client";

import { useState } from "react";
import { Button } from "@/components/ui/Button";

/**
 * The audience vote link — free, on purpose, for everyone.
 *
 * This is the only path in the product that reaches somebody who has never
 * heard of it: a stranger opens the link, argues with two rosters, and is
 * asked whether they could draft better. Putting it behind the paywall
 * converts a handful of hosts and costs all of that reach.
 *
 * The host's LIVE tally in the Content tab is still premium. That is a
 * production tool. This is distribution, and distribution should not be
 * something you have to buy.
 */
export function VoteLink({ code }: { code: string }) {
  const [done, setDone] = useState(false);
  const url = typeof window === "undefined" ? "" : `${window.location.origin}/vote/${code}`;

  return (
    <div className="border p-4 rule">
      <h2 className="type-display text-[1.125rem]">Let them settle it</h2>
      <p className="mt-1.5 text-[0.875rem] leading-relaxed text-muted">
        Send this to whoever is watching. They see both rosters, vote blind, and only then find
        out how everyone else called it. No account needed, on either end.
      </p>
      <div className="mt-3 flex items-center gap-2 border p-2 rule">
        <span className="min-w-0 flex-1 truncate font-mono text-[0.75rem] text-muted">{url}</span>
        <Button
          variant="primary"
          size="sm"
          onClick={() =>
            void navigator.clipboard
              .writeText(url)
              .then(() => {
                setDone(true);
                setTimeout(() => setDone(false), 1600);
              })
              .catch(() => undefined)
          }
        >
          {done ? "copied" : "Copy vote link"}
        </Button>
      </div>
    </div>
  );
}
