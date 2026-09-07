import type { Metadata } from "next";
import Link from "next/link";
import { Footer, Header } from "@/components/site/Chrome";

export const metadata: Metadata = {
  alternates: { canonical: "/house-rules" },
  title: "$20 Draft House Rules — Variations Worth Playing",
  description:
    "Ten variations on the $20 auction draft: blind categories, themed rosters, tournaments, drinking-game scoring, snake-auction hybrids and the ones that sound good but break the game.",
};

/**
 * The variations page.
 *
 * Written as a set of rules somebody could actually run at a table, including
 * which ones the site supports directly and which are honour-system. The last
 * section is the useful half: variations that sound clever and are not, with
 * the reason. A list of only good ideas is a list somebody has not tested.
 */
const faq = {
  "@context": "https://schema.org",
  "@type": "FAQPage",
  mainEntity: [
    {
      "@type": "Question",
      name: "Can you play the $20 draft with more than two people?",
      acceptedAnswer: {
        "@type": "Answer",
        text:
          "The board is built for two. For a group, run it as a bracket: pairs draft head to head, the audience vote decides who advances, and the winners draft each other from a fresh category. A third person is better used as the category builder, since they can write a list neither player has seen.",
      },
    },
    {
      "@type": "Question",
      name: "What is a blind category draft?",
      acceptedAnswer: {
        "@type": "Answer",
        text:
          "A third person builds the category from a setup link and neither player sees it before the first card is dealt. Both players are then drafting genuinely blind, which removes the advantage the host normally has from having chosen the list.",
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

export default function HouseRulesPage() {
  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(faq) }}
      />
      <Header thin />
      <main className="mx-auto w-full max-w-2xl px-4 py-10">
        <h1 className="type-display text-[1.75rem]">House rules</h1>
        <p className="mt-4 text-[0.9375rem] leading-relaxed text-muted">
          The base game is two players, twenty dollars and a category. Everything below is a
          variation people actually run on top of it — some supported by the settings, some pure
          honour system. The last section is the one worth reading twice: the variations that
          sound clever and quietly ruin the draft.
        </p>

        <div className="mt-8 flex flex-col gap-7">
          <Rule heading="Blind category — the best one">
            <p>
              A third person builds the list from a setup link. Neither player sees it before the
              first card is dealt, and the builder does not play.
            </p>
            <p>
              This fixes the format&apos;s one structural unfairness. Normally the host picks the
              category, which means they have half-remembered the list and know roughly what is
              coming. Hand that job away and both players are reacting to the same surprise. It is
              also the funniest version, because the builder is writing to provoke you both.
            </p>
            <p>
              <strong className="text-ink">Supported directly.</strong> Create a room, send the
              setup link to your third person instead of building a category yourself.
            </p>
          </Rule>

          <Rule heading="Themed rosters">
            <p>
              Announce a theme before the first card and both players draft to it rather than for
              raw quality. &ldquo;Best breakfast&rdquo;, &ldquo;team that would survive a
              zombie outbreak&rdquo;, &ldquo;dinner party you would actually enjoy&rdquo;.
            </p>
            <p>
              The scoring is the audience vote, so a coherent five that tells a story beats an
              expensive five that does not. It also flattens knowledge gaps, which makes it the
              right variation when one of you knows the category far better than the other.
            </p>
            <p>
              <strong className="text-ink">Honour system,</strong> but the vote link does the
              enforcing for you.
            </p>
          </Rule>

          <Rule heading="Tournament bracket">
            <p>
              For four or eight people. Pairs draft head to head from the same category, the
              audience vote decides who advances, and winners draft each other from a fresh
              category in the next round. Losers become the audience, which keeps everyone in it.
            </p>
            <p>
              Run the final on a bigger roster than the earlier rounds — a ten-slot final after
              five-slot heats makes the last draft feel like a final rather than a repeat.
            </p>
          </Rule>

          <Rule heading="Rich and poor">
            <p>
              Give one player a larger bankroll and the other more roster slots to fill. Twenty
              five dollars for five slots against twenty dollars for seven is a real contest
              between quality and depth, and it is the closest this game gets to a handicap system
              for uneven players.
            </p>
            <p>
              <strong className="text-ink">Partly supported.</strong> The room settings are shared
              by both players, so run it as two rooms back to back and compare, or agree the
              constraint out loud and hold each other to it.
            </p>
          </Rule>

          <Rule heading="No-gives, and its opposite">
            <p>
              Set gives to zero and the only move on a card you do not want is to take it or let
              it go. It is a harsher, faster game — every bad card is your problem.
            </p>
            <p>
              Set gives to unlimited and it inverts: the draft becomes about burning the other
              person&apos;s roster with things they cannot use. Both are one setting at room
              creation, and they are the two most different-feeling drafts on the site.
            </p>
          </Rule>

          <Rule heading="Speed round">
            <p>
              Three seconds on the clock. Nobody has time to calculate, so you find out what you
              actually think things are worth. Best played as a decider after a normal draft ends
              in an argument.
            </p>
          </Rule>

          <Rule heading="Loser picks next">
            <p>
              A series format. Whoever loses the audience vote chooses the category for the next
              draft, and keeps choosing until they win one. It self-balances — the loser steers
              toward ground they are stronger on — and it is how a single game becomes an evening.
            </p>
          </Rule>

          <Rule heading="Variations that break it">
            <p>
              <strong className="text-ink">Letting both players see the deck first.</strong> It
              sounds fairer and it removes the entire game. If you know what is coming, every bid
              is a solved arithmetic problem and there is nothing to misjudge.
            </p>
            <p>
              <strong className="text-ink">Bidding in cents.</strong> Somebody always suggests it.
              Penny increments turn a bidding war into a war of attrition where the winner is
              whoever is most willing to sit there, and the clock stops meaning anything.
            </p>
            <p>
              <strong className="text-ink">A points system instead of the vote.</strong> Assigning
              each name a value beforehand makes the draft a maths exercise with a correct answer,
              and correct answers are the one thing this game is built not to have. The vote is
              not a weakness in the design — it is the design.
            </p>
            <p>
              <strong className="text-ink">Very large rosters.</strong> Past about ten slots the
              money stops mattering, because there is not enough to fight over per card. Twenty
              dollars over fifteen slots is a draft where almost everything goes for the minimum.
            </p>
          </Rule>

          <Rule heading="Start one">
            <p>
              Most of these are a setting away.{" "}
              <Link href="/new" className="text-ink underline">
                Create a room
              </Link>{" "}
              and set the bankroll, roster size, clock and gives to taste — or read{" "}
              <Link href="/how-to-play" className="text-ink underline">
                how to play
              </Link>{" "}
              first if the base game is still new, and{" "}
              <Link href="/draft-categories" className="text-ink underline">
                the category guide
              </Link>{" "}
              for what to draft.
            </p>
          </Rule>
        </div>
      </main>
      <Footer />
    </>
  );
}
