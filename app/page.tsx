import type { Metadata } from "next";
import Link from "next/link";
import { ScrollBidWarLoader } from "@/components/site/ScrollBidWarLoader";
import { SITE_URL } from "@/lib/site";
import { ReserveDiagram } from "@/components/site/ReserveDiagram";
import { ShareCard } from "@/components/results/ShareCard";
import { Footer, Header } from "@/components/site/Chrome";
import { SAMPLE_CARD } from "@/lib/demo/sample";

const schema = {
  "@context": "https://schema.org",
  "@type": "VideoGame",
  name: "DraftFor20",
  alternateName: ["The $20 Draft", "$20 Draft Game"],
  url: SITE_URL,
  description:
    "A live head-to-head auction draft game for any category. Two players split a fixed bankroll across a hidden deck, bidding under a server-run clock.",
  applicationCategory: "GameApplication",
  operatingSystem: "Web browser",
  gamePlatform: "Web browser",
  playMode: "MultiPlayer",
  numberOfPlayers: { "@type": "QuantitativeValue", minValue: 2, maxValue: 2 },
  genre: ["Party game", "Auction", "Strategy"],
  offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
};

export const metadata: Metadata = {
  title: "DraftFor20 — the $20 auction draft game for any category",
  description:
    "A live head-to-head auction draft on any category — football, movies, or one you type yourself. Two players, $20 each, and a card worth sharing.",
};

const STEPS = [
  {
    n: "01",
    head: "The deck deals",
    body: "Nobody nominates and nobody types anything. The server shuffles a hidden deck and flips one name at a time. Neither of you can see what is coming.",
  },
  {
    n: "02",
    head: "Whoever is up decides",
    body: "Take them for the $1 minimum, or hand them straight to your opponent for free. Turns alternate, so you both get the call.",
  },
  {
    n: "03",
    head: "The other one bids",
    body: "If you took them, they can push the price up. Raise, pass, raise again. The clock resets on every raise and it runs on the server.",
  },
  {
    n: "04",
    head: "It locks",
    body: "The money comes off, the name lands on a roster, the next card flips. When both rosters are full, whatever cash you have left is the argument.",
  },
];

const HOST_CONTROLS: [string, string][] = [
  ["Roster size", "How many players each team ends up with. No positions, no slots to fill."],
  ["Bankroll", "Any starting amount, not just $20. Both players get the same."],
  ["Minimum bid", "Sets the floor and the reserve maths for every pick."],
  ["Counter-bid clock", "10, 15, 20 or 30 seconds. Server-side, so nobody can stall it."],
  ["Gives each", "How many times you can dump a card on your opponent. Two by default."],
  ["Unlisted rooms", "Rooms are reachable by code only. Nothing is browsable."],
];

export default function Home() {
  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(schema) }}
      />
      <Header />

      <main>
        <section className="mx-auto w-full max-w-5xl px-4 py-14 lg:py-24">
          <p className="type-label text-coral">two players &middot; one bankroll &middot; no positions</p>
          <h1 className="type-display mt-4 max-w-3xl text-balance text-[2.75rem] leading-[0.94] sm:text-[4rem]">
            You don&apos;t pick. You pay.
          </h1>
          <p className="mt-5 max-w-xl text-[1.0625rem] leading-relaxed text-muted">
            DraftFor20 is a head-to-head auction draft game: it deals you a name and starts a
            clock. There are no positions and no rankings, so nothing in the app tells you who
            is good. That argument is the game.
          </p>
          <div className="mt-7 flex flex-wrap gap-2">
            <Link href="/new" className="btn btn-primary h-14 px-6 text-[0.9375rem]">
              Start a room
            </Link>
            <Link href="/join" className="btn btn-ghost h-14 px-6 text-[0.9375rem]">
              Join with a code
            </Link>
          </div>
          <p className="mt-3 text-[0.8125rem] text-muted">
            No signup. Your opponent just needs the code.
          </p>
        </section>

        <ScrollBidWarLoader />

        <section className="border-t rule">
          <div className="mx-auto w-full max-w-5xl px-4 py-14">
            <h2 className="type-display text-[1.75rem]">How a card goes</h2>
            <ol className="mt-7 grid gap-x-8 gap-y-7 sm:grid-cols-2 lg:grid-cols-4">
              {STEPS.map((s) => (
                <li key={s.n} className="border-t pt-3 rule-strong">
                  <span className="type-num text-[0.75rem] text-coral">{s.n}</span>
                  <h3 className="type-display mt-1 text-[1.0625rem]">{s.head}</h3>
                  <p className="mt-2 text-[0.875rem] leading-relaxed text-muted">{s.body}</p>
                </li>
              ))}
            </ol>
          </div>
        </section>

        <section className="border-t rule">
          <div className="mx-auto grid w-full max-w-5xl gap-8 px-4 py-14 lg:grid-cols-[1.1fr_1fr] lg:items-center">
            <div>
              <p className="type-label text-coral">the wall</p>
              <h2 className="type-display mt-2 text-[1.75rem]">
                You can never bid yourself short
              </h2>
              <p className="mt-4 text-[0.9375rem] leading-relaxed text-muted">
                You have to keep back the minimum for every player you still owe. That money is
                hatched off on the rail and the server refuses any bid that crosses it, so the
                wall is visible before you hit it and enforced after.
              </p>
              <p className="mt-3 text-[0.9375rem] leading-relaxed text-muted">
                Bids are re-checked against your live bankroll inside a single database
                transaction. Two fast taps cannot both slip through.
              </p>
            </div>
            <ReserveDiagram />
          </div>
        </section>

        <section className="border-t rule">
          <div className="mx-auto grid w-full max-w-5xl gap-8 px-4 py-14 lg:grid-cols-[1fr_0.75fr] lg:items-center">
            <div>
              <p className="type-label text-coral">the point of the whole thing</p>
              <h2 className="type-display mt-2 text-[1.75rem]">
                A vertical board, ready the second you finish
              </h2>
              <p className="mt-4 text-[0.9375rem] leading-relaxed text-muted">
                Both rosters, every price, both leftover totals, at 1080 by 1920. Screen-record it
                or download the PNG. There is no algorithmic winner and there never will be.
              </p>
            </div>
            <div className="mx-auto w-full max-w-[300px]">
              <ShareCard model={SAMPLE_CARD} />
            </div>
          </div>
        </section>

        <section className="border-t rule">
          <div className="mx-auto w-full max-w-5xl px-4 py-14">
            <h2 className="type-display text-[1.75rem]">What the host controls</h2>
            <dl className="mt-6 grid gap-x-10 sm:grid-cols-2">
              {HOST_CONTROLS.map(([term, def]) => (
                <div key={term} className="flex flex-col border-b py-3 rule sm:flex-row sm:gap-4">
                  <dt className="type-label w-40 shrink-0 pt-0.5 text-ink">{term}</dt>
                  <dd className="text-[0.875rem] leading-relaxed text-muted">{def}</dd>
                </div>
              ))}
            </dl>
            <div className="mt-8 flex flex-wrap gap-2">
              <Link href="/new" className="btn btn-primary h-12 px-5 text-[0.875rem]">
                Start a room
              </Link>
              <Link href="/login" className="btn btn-ghost h-12 px-5 text-[0.875rem]">
                Host sign in
              </Link>
            </div>
          </div>
        </section>
      </main>

      <Footer />
    </>
  );
}
