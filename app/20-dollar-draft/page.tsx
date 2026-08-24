import type { Metadata } from "next";
import Link from "next/link";
import { Footer, Header } from "@/components/site/Chrome";
import { SITE_URL } from "@/lib/site";

export const metadata: Metadata = {
  title: "Play the $20 Draft Game Online — Free 1v1 Auction Draft",
  description:
    "The $20 draft from TikTok, playable against a real opponent. Two people, $20 each, a hidden deck — bid, take, or hand it over. Free, no download, no account needed.",
  alternates: { canonical: `${SITE_URL}/20-dollar-draft` },
  openGraph: {
    title: "Play the $20 Draft Game Online — Free 1v1 Auction Draft",
    description:
      "The $20 draft, playable live against a real opponent instead of watched on video. Free, in the browser.",
    url: `${SITE_URL}/20-dollar-draft`,
  },
};

/**
 * schema.org VideoGame rather than WebApplication.
 *
 * VideoGame inherits everything useful from SoftwareApplication — category,
 * operating system, offers — and adds the properties that are actually true
 * here: it is multiplayer, it takes exactly two people, and it runs in a
 * browser. WebApplication could describe it, but it could equally describe a
 * spreadsheet; the more specific type is the more honest one.
 */
const schema = {
  "@context": "https://schema.org",
  "@type": "VideoGame",
  name: "DraftFor20",
  alternateName: ["The $20 Draft", "$20 Draft Game", "Muted Draft"],
  url: `${SITE_URL}/20-dollar-draft`,
  description:
    "A live head-to-head auction draft game. Two players split a fixed $20 bankroll across a hidden deck of picks, bidding against each other under a server-run clock.",
  applicationCategory: "GameApplication",
  operatingSystem: "Web browser",
  gamePlatform: "Web browser",
  playMode: "MultiPlayer",
  numberOfPlayers: { "@type": "QuantitativeValue", minValue: 2, maxValue: 2 },
  genre: ["Party game", "Auction", "Strategy"],
  offers: {
    "@type": "Offer",
    price: "0",
    priceCurrency: "USD",
    availability: "https://schema.org/InStock",
  },
};

const RULES = [
  {
    h: "You split $20, and that is the whole scoreboard",
    p: "Both players start with the same bankroll and the same number of roster slots. Whatever you do not spend, you keep — and at the end the leftover cash is the only number that matters. There is no points system and nothing calculates a winner.",
  },
  {
    h: "The deck deals the picks, not you",
    p: "Nobody chooses who comes up. The server shuffles a hidden list and turns over one name at a time. Neither player can see what is coming, which is what stops the whole thing being a memory test.",
  },
  {
    h: "Take it at a dollar, or give it away",
    p: "Whoever is up either takes the card at the minimum bid — and then the other player can bid it up — or hands it over for free, which burns a slot on their opponent's roster. Giving is limited, so it is a weapon with ammunition rather than a way out of every card.",
  },
  {
    h: "You can never bid yourself into a corner",
    p: "The server keeps back the minimum bid for every slot you still owe. You cannot spend money you need later, so nobody ends the game unable to fill their roster because they got excited on card two.",
  },
];

export default function TwentyDollarDraftPage() {
  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(schema) }}
      />
      <Header thin />

      <main className="mx-auto w-full max-w-3xl px-4 py-12">
        <p className="type-label text-muted">the $20 draft &middot; playable, not just watchable</p>
        <h1 className="type-display mt-3 text-balance text-[2.5rem] leading-[0.96] sm:text-[3.25rem]">
          Play the $20 draft game online
        </h1>
        <p className="mt-5 max-w-2xl text-[1.0625rem] leading-relaxed text-muted">
          You have probably seen the $20 draft on TikTok — two people, twenty dollars each,
          arguing over what a name is worth. It goes by a few names: the muted draft, the budget
          draft, the $20 auction. This is the same game, except you play it live against a real
          opponent instead of watching somebody else do it.
        </p>

        <div className="mt-7 flex flex-wrap gap-2">
          <Link href="/new" className="btn btn-primary h-14 px-6 text-[0.9375rem]">
            Start a free room
          </Link>
          <Link href="/join" className="btn btn-ghost h-14 px-6 text-[0.9375rem]">
            Join with a code
          </Link>
        </div>
        <p className="type-label mt-3 text-muted">
          no download &middot; no account needed &middot; about five minutes
        </p>

        {/* ── what the trend actually is ─────────────────────────────────── */}
        <section className="mt-14">
          <h2 className="type-display text-[1.5rem]">What is the $20 draft?</h2>
          <p className="mt-3 text-[0.9375rem] leading-relaxed text-muted">
            It started as a video format: two people are given a fixed budget — usually twenty
            dollars — and take turns bidding on names as they come up, building a roster out of
            whoever they can afford. The comedy is in the arguing, and in watching somebody blow
            half their money on card one and spend the rest of the game broke.
          </p>
          <p className="mt-3 text-[0.9375rem] leading-relaxed text-muted">
            The version people film usually runs on an honour system and a piece of paper. The
            problem with that is the money: it is genuinely hard to track who can afford what
            while also being funny on camera. That is the part this does for you.
          </p>
        </section>

        {/* ── how it works ───────────────────────────────────────────────── */}
        <section className="mt-12">
          <h2 className="type-display text-[1.5rem]">How it works</h2>
          <ol className="mt-4 flex flex-col">
            {RULES.map((r, i) => (
              <li key={r.h} className="border-b py-4 rule">
                <div className="flex gap-3">
                  <span className="type-num shrink-0 text-[0.875rem] text-gold">{i + 1}</span>
                  <div>
                    <h3 className="type-display text-[1.0625rem]">{r.h}</h3>
                    <p className="mt-1.5 text-[0.9375rem] leading-relaxed text-muted">{r.p}</p>
                  </div>
                </div>
              </li>
            ))}
          </ol>
        </section>

        {/* ── beyond football ────────────────────────────────────────────── */}
        <section className="mt-12">
          <h2 className="type-display text-[1.5rem]">It does not have to be football</h2>
          <p className="mt-3 text-[0.9375rem] leading-relaxed text-muted">
            The trend started with football players, and there is a Football Draft on the shelf
            ready to play. But the game works on anything people have opinions about — snacks,
            movie villains, dog breeds, cereal. There are premade categories to pick from, and if
            you want something that is not there you can type any category you like and the deck
            gets built for you.
          </p>
          <div className="mt-5 flex flex-wrap gap-2">
            <Link href="/new" className="btn btn-primary h-12 px-5 text-[0.875rem]">
              Pick a category and start
            </Link>
            <Link href="/" className="btn btn-ghost h-12 px-5 text-[0.875rem]">
              See how a card plays out
            </Link>
          </div>
        </section>

        {/* ── for people filming it ──────────────────────────────────────── */}
        <section className="mt-12">
          <h2 className="type-display text-[1.5rem]">If you are making videos of it</h2>
          <p className="mt-3 text-[0.9375rem] leading-relaxed text-muted">
            There is a mode built for filming: a vertical 9:16 board with the card and the clock
            centred, both rosters stacked, and the right edge kept clear of the buttons TikTok
            draws over your video. It comes with a transparent browser source for OBS and a
            results card you can post at the end. That part is{" "}
            <Link href="/pricing" className="text-ink underline">
              paid
            </Link>
            ; everything above is not.
          </p>
        </section>

        <p className="mt-14 text-[0.875rem] text-muted">
          <Link href="/" className="text-ink underline">
            DraftFor20
          </Link>{" "}
          &middot; a real-time auction draft game you can play in a browser.
        </p>
      </main>
      <Footer />
    </>
  );
}
