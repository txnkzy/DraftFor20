import type { Metadata } from "next";
import Link from "next/link";
import { Footer, Header } from "@/components/site/Chrome";

export const metadata: Metadata = {
  alternates: { canonical: "/auction-draft-vs-snake-draft" },
  title: "Auction Draft vs Snake Draft — Which Is Better, and Why",
  description:
    "A snake draft asks who you like. An auction draft asks what they are worth. The real differences in fairness, pace, skill and how it feels to play — and when each format is the right choice.",
};

/**
 * Written for a question people genuinely type, not for a keyword.
 *
 * "Auction draft vs snake draft" is a real argument in fantasy sport, and the
 * honest answer is not "auction, obviously" — snake is better for some rooms
 * and this says so. A comparison page that concludes in favour of whoever
 * wrote it is the kind of page nobody links to.
 */
const faq = {
  "@context": "https://schema.org",
  "@type": "FAQPage",
  mainEntity: [
    {
      "@type": "Question",
      name: "Is an auction draft better than a snake draft?",
      acceptedAnswer: {
        "@type": "Answer",
        text:
          "For two players who want to argue about value, yes. An auction gives every player a price rather than a queue position, so nobody is locked out of anyone. A snake draft is better when you have many players, limited time, or people who have never drafted before, because it needs no budgeting and cannot go wrong.",
      },
    },
    {
      "@type": "Question",
      name: "What is the difference between an auction draft and a snake draft?",
      acceptedAnswer: {
        "@type": "Answer",
        text:
          "In a snake draft you take turns picking, and the order reverses each round. In an auction draft everyone has a budget and bids on each name as it comes up, so any player can have any name if they are willing to pay for it.",
      },
    },
    {
      "@type": "Question",
      name: "How long does an auction draft take?",
      acceptedAnswer: {
        "@type": "Answer",
        text:
          "Longer per pick than a snake draft, because every card is negotiated rather than chosen. A five-slot two-player auction with a 15 second clock takes about ten minutes. Fantasy football auctions with twelve managers can run two hours.",
      },
    },
  ],
};

function Rule({ heading, children }: { heading: string; children: React.ReactNode }) {
  return (
    <section className="border-t pt-4 rule">
      <h2 className="type-display text-[1rem]">{heading}</h2>
      <div className="mt-2 flex flex-col gap-3 text-[0.9375rem] leading-relaxed text-muted">
        {children}
      </div>
    </section>
  );
}

export default function AuctionVsSnakePage() {
  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(faq) }}
      />
      <Header thin />
      <main className="mx-auto w-full max-w-2xl px-4 py-10">
        <h1 className="type-display text-[1.75rem]">Auction draft vs snake draft</h1>
        <p className="mt-4 text-[0.9375rem] leading-relaxed text-muted">
          A snake draft asks which name you want next. An auction draft asks what that name is
          worth to you, out loud, against somebody who disagrees. They produce different rosters,
          reward different skills, and feel almost nothing alike — and the second one is not
          automatically better, which is why this page says when it is not.
        </p>

        <div className="mt-8 flex flex-col gap-7">
          <Rule heading="How each one actually works">
            <p>
              <strong className="text-ink">A snake draft is a queue.</strong> Everyone picks in
              order, and the order reverses each round: 1-2-3, then 3-2-1. That reversal exists to
              soften the biggest flaw, which is that the first pick is simply worth more than the
              last. Whoever drafts first gets the best name available and nobody else can do
              anything about it.
            </p>
            <p>
              <strong className="text-ink">An auction is a market.</strong> Everyone gets the same
              budget. Names come up one at a time and anyone can bid. There is no pick order,
              because there are no picks — there are prices. If you want the best name in the
              category you can have it, and the only question is what you are prepared to give up
              to get it.
            </p>
            <p>
              That is the whole difference, and everything below follows from it.
            </p>
          </Rule>

          <Rule heading="Nobody is locked out of anybody">
            <p>
              The defining frustration of a snake draft is watching the one name you wanted go
              two picks before your turn. You did not lose it by being outmanoeuvred; you lost it
              because of where you were sitting. Nothing you could have done would have changed it.
            </p>
            <p>
              In an auction that cannot happen. Every name is available to every player, always.
              If your opponent takes the best card in the deck, they took it by spending, and the
              money they spent is money they no longer have for the next nine cards. The loss is
              something you chose to allow rather than something the format did to you.
            </p>
          </Rule>

          <Rule heading="The skill is different, not just harder">
            <p>
              Snake drafting rewards <strong className="text-ink">ranking</strong>. If your list
              is better than everyone else&apos;s, you win, because your only decision is who is
              top of the board when your turn comes.
            </p>
            <p>
              Auction drafting rewards <strong className="text-ink">pricing</strong>, which is a
              different thing entirely. Knowing that a name is the second best in the category is
              nearly useless on its own. What matters is whether it is worth $6 when you have $20
              and eight slots left — and whether your opponent thinks it is worth $7, which is the
              part you cannot look up.
            </p>
            <p>
              This is why auctions punish knowledge asymmetry less than people expect. The player
              who knows the category better still has an edge, but the player who reads
              <em> the other player</em> better has one too, and those are not the same person.
            </p>
          </Rule>

          <Rule heading="Where the snake draft genuinely wins">
            <p>
              <strong className="text-ink">Speed.</strong> A pick takes as long as it takes to say
              a name. An auction negotiates every card, so the same roster takes noticeably longer.
              With twelve fantasy managers that is the difference between forty minutes and two
              hours.
            </p>
            <p>
              <strong className="text-ink">Nothing to learn.</strong> Nobody has ever needed the
              rules of a snake draft explained twice. An auction asks a first-timer to hold a
              budget in their head while under a clock, and the classic beginner mistake — blowing
              most of the money on the first good card and filling the rest of the roster with
              whatever is left — is not fun to make.
            </p>
            <p>
              <strong className="text-ink">Large groups.</strong> Auctions scale badly. Ten people
              waiting to bid on a card that two of them care about is a lot of standing around.
            </p>
            <p>
              If you are running a twelve-person league in an hour with people who have never
              drafted, run a snake. It is the right tool.
            </p>
          </Rule>

          <Rule heading="What a $20 budget changes">
            <p>
              Most auction formats use a budget large enough to hide mistakes — $200 across a full
              fantasy roster means a $3 overpay disappears. A twenty dollar budget across five to
              ten slots does the opposite: it makes every dollar visible. Bidding $8 on one name
              is not a preference, it is a statement that you are prepared to fill four slots with
              scraps.
            </p>
            <p>
              It also makes the format work for two people, which conventional auctions do not.
              With two bidders there is no crowd to hide in — every raise is directly against one
              person who is watching your money go down, and both of you know exactly what the
              other can still afford.
            </p>
            <p>
              That visibility is the point. It is also why the format works on things that are not
              sport at all: cereal, films, cities, anything both of you have opinions about.
            </p>
          </Rule>

          <Rule heading="Which should you run?">
            <p>
              <strong className="text-ink">Snake</strong> if you have more than about six players,
              a hard time limit, or a table of complete beginners.
            </p>
            <p>
              <strong className="text-ink">Auction</strong> if the argument is the point. Two
              people, one category, real money pressure, and a result neither of you can blame on
              draft position.
            </p>
            <p>
              DraftFor20 is the second one, deliberately narrowed: two players, twenty dollars,
              any category you like.{" "}
              <Link href="/how-to-play" className="text-ink underline">
                How to play
              </Link>{" "}
              covers the strategy,{" "}
              <Link href="/house-rules" className="text-ink underline">
                house rules
              </Link>{" "}
              covers the variations people invent, or{" "}
              <Link href="/new" className="text-ink underline">
                start a room
              </Link>{" "}
              and find out.
            </p>
          </Rule>
        </div>
      </main>
      <Footer />
    </>
  );
}
