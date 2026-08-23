"use client";

import { useState } from "react";
import { Button } from "@/components/ui/Button";
import { Padlock } from "@/components/premium/Padlock";
import { UpgradeDialog, useUpgradeDialog } from "@/components/premium/UpgradeDialog";
import { usePremium } from "@/lib/premium";

/**
 * The audience vote, now premium.
 *
 * Shown locked rather than hidden: this is the feature most worth paying for
 * on this screen, and the moment somebody has just finished a draft and wants
 * to settle an argument is exactly when the pitch lands. The lock names the
 * thing and opens the dialog rather than doing nothing.
 *
 * Voters never need an account or a plan — the gate is on the host who ran
 * the draft, which is why this component asks about MY premium and not the
 * visitor's.
 */
export function VoteLink({ code }: { code: string }) {
  const premium = usePremium();
  const upgrade = useUpgradeDialog();
  const [done, setDone] = useState(false);
  const url = typeof window === "undefined" ? "" : `${window.location.origin}/vote/${code}`;

  const locked = !premium.active;

  return (
    <div className="border p-4 rule" style={locked ? undefined : { borderColor: "var(--color-coral)" }}>
      <h2 className="type-display flex items-center gap-2 text-[1.125rem]">
        {locked ? <Padlock size={13} /> : null}
        Let them settle it
      </h2>
      <p className="mt-1.5 text-[0.875rem] leading-relaxed text-muted">
        Send a link to whoever is watching. They see both rosters, vote blind, and only then find
        out how everyone else called it — no account needed on their end.
      </p>

      {locked ? (
        <>
          <Button
            variant="primary"
            className="mt-3"
            onClick={() =>
              upgrade.ask(
                "Let your audience vote",
                "Turn a finished draft into an argument. Share one link and watch the tally come in live — the people voting never need an account.",
              )
            }
          >
            Unlock the audience vote
          </Button>
          <p className="mt-2 text-[0.75rem] text-muted">
            Premium, or a $1 pass for tonight.
          </p>
        </>
      ) : (
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
      )}

      {upgrade.open ? (
        <UpgradeDialog
          feature={upgrade.open.feature}
          why={upgrade.open.why}
          signedIn={premium.signedIn}
          returnTo={`/results/${code}`}
          onClose={upgrade.close}
        />
      ) : null}
    </div>
  );
}
