"use client";

import { useCallback, useEffect, useState } from "react";
import { supabaseBrowser } from "@/lib/supabase/client";

/**
 * The user ID, beside the private email.
 *
 * ASSIGNED, NOT CHOSEN. It is generated when the profile row is created and
 * cannot be changed from the app — 0031 revoked set_my_handle, including the
 * default PUBLIC grant, so it is not merely a missing button. An identifier
 * people can swap around is a poor identifier: it breaks every reference
 * anybody already wrote down.
 *
 * It exists so an account can be named — in the admin table, or anywhere a
 * reference is needed — without putting an email address on screen. The email
 * stays visible only here, to its owner, and to an admin.
 */
export function HandleRow({ email }: { email: string | null }) {
  const [handle, setHandle] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);

  const read = useCallback(async () => {
    const { data } = await supabaseBrowser().rpc("my_handle");
    return ((data as { handle?: string | null } | null)?.handle ?? null) as string | null;
  }, []);

  useEffect(() => {
    let off = false;
    void (async () => {
      const h = await read();
      if (!off) setHandle(h);
    })();
    return () => { off = true; };
  }, [read]);

  return (
    <dl className="mt-2 flex flex-wrap items-baseline gap-x-6 gap-y-2">
      <div>
        <dt className="type-label text-muted">user id</dt>
        <dd className="type-num mt-0.5 flex items-baseline gap-2 text-[0.9375rem] text-teal">
          {handle ?? "…"}
          {handle ? (
            <button
              className="type-label text-muted hover:text-ink"
              onClick={() =>
                void navigator.clipboard
                  .writeText(handle)
                  .then(() => {
                    setCopied(true);
                    setTimeout(() => setCopied(false), 1600);
                  })
                  .catch(() => undefined)
              }
            >
              {copied ? "copied" : "copy"}
            </button>
          ) : null}
        </dd>
      </div>

      <div>
        <dt className="type-label text-muted">email &middot; only you see this</dt>
        <dd className="type-num mt-0.5 text-[0.9375rem] text-muted">{email}</dd>
      </div>
    </dl>
  );
}
