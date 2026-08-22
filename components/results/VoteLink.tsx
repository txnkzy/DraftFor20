"use client";

import { useState } from "react";
import { Button } from "@/components/ui/Button";

/**
 * The audience vote link, offered to everyone regardless of tier.
 *
 * The Content tab's live tally is a premium feature. This is not, and should
 * not be: a stranger opening this link, arguing with two rosters and then
 * being asked whether they could do better is the cheapest room this app will
 * ever get. Locking it would be charging for our own distribution.
 */
export function VoteLink({ code }: { code: string }) {
  const [done, setDone] = useState(false);
  const url = typeof window === "undefined" ? "" : `${window.location.origin}/vote/${code}`;

  return (
    <div className="border p-4 rule">
      <h2 className="type-display text-[1.125rem]">Let them settle it</h2>
      <p className="mt-1.5 text-[0.875rem] leading-relaxed text-muted">
        Send this to whoever is watching. They see both rosters, vote blind, and only then find
        out how everyone else called it.
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
