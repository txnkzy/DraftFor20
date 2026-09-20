"use client";

import Link from "next/link";

/** Plain links, not buttons: each sort is a real URL, so a board can be
 *  shared and the browser's back button does what it looks like it does. */
export function SortTabs({ sort }: { sort: string }) {
  const tabs = [
    { id: "wins", label: "Most wins" },
    { id: "drafts", label: "Most drafts" },
    { id: "rate", label: "Win rate" },
  ];
  return (
    <div className="mt-6 flex flex-wrap gap-2">
      {tabs.map((t) => (
        <Link
          key={t.id}
          href={`/leaderboard?sort=${t.id}`}
          aria-current={sort === t.id ? "page" : undefined}
          className={
            sort === t.id
              ? "btn btn-primary h-9 px-3 text-[0.6875rem]"
              : "btn btn-ghost h-9 px-3 text-[0.6875rem]"
          }
        >
          {t.label}
        </Link>
      ))}
    </div>
  );
}
