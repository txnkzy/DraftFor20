import type { Metadata } from "next";
import Link from "next/link";
import { Footer, Header } from "@/components/site/Chrome";

export const metadata: Metadata = {
  alternates: { canonical: "/how-to-play" },
  title: "How to Play the $20 Draft Well — Strategy, the Reserve Rule and Common Mistakes",
  description:
    "A strategy guide to the $20 auction draft: what the reserve rule actually stops you doing, when giving a card away beats taking it, why the opener is at a disadvantage, and the four mistakes that lose most drafts.",
};

/**
 * FAQPage structured data. The questions below are the ones people actually
 * ask in a first draft — they are answered in full on the page itself, which
 * is the condition for marking them up at all.
 */
const faq = {
  "@context": "https://schema.org",
  "@type": "FAQPage",
  mainEntity: [
    {
      "@type": "Question",
      name: "How much can I bid in the $20 draft?",
      acceptedAnswer: {
        "@type": "Answer",
        text: "Never more than your remaining bankroll, and never so much that you could not still afford the minimum bid on every slot you have left to fill. With $20, five slots and a $1 minimum, your first bid is capped at $16, because the other four slots need a dollar each held back.",
      },
    },
    {
      "@type": "Question",
      name: "Why would I give a card away instead of taking it?",
      acceptedAnswer: {
        "@type": "Answer",
        text: "Giving a card lands it on your opponent's roster for free, filling one of their slots with something they did not choose. It costs them a slot and costs you nothing but one of your limited gives. It is strongest late, when their remaining slots are scarce and a wasted one hurts.",
      },
    },
    {
      "@type": "Question",
      name: "Is the $20 draft played for real money?",
      acceptedAnswer: {
        "@type": "Answer",
        text: "No. The bankroll is a scoring unit that exists only inside one game room. There is no deposit, no withdrawal, no prize and no wagering of any kind.",
      },
    },
    {
      "@type": "Question",
      name: "What happens if I run out of money?",
      acceptedAnswer: {
        "@type": "Answer",
        text: "You are broke, not eliminated. You can no longer raise, but your remaining slots still fill through the take-and-give mechanic, so a draft never deadlocks because somebody overspent.",
      },
    },
  ],
};

function Part({ heading, children }: { heading: string; children: React.ReactNode }) {
  return (
    <section className="border-t pt-4 rule">
      <h2 className="type-display text-[1rem]">{heading}</h2>
      <div className="mt-2 flex flex-col gap-3 text-[0.9375rem] leading-relaxed text-muted">
        {children}
      </div>
    </section>
  );
}

const MISTAKES = [
  {
    t: "Spending big on the first good card",
    p: "The deck is shuffled, so the first strong name is not the last one. Paying $9 for it on card two feels decisive and leaves you passing on everything for the rest of the draft. The player who wins a card at $9 and then watches three better ones go for $2 has not won anything.",
  },
  {
    t: "Treating the minimum bid as free",
    p: "Every dollar you hold back is a dollar on the final scoreboard, and taking a card at the minimum still burns a roster slot. A slot spent on something you do not want is the most expensive thing in the game, because it cannot be undone and it cannot be sold.",
  },
  {
    t: "Saving gives for a card that never comes",
    p: "Gives expire worthless. If you finish with two unused gives you have effectively played the whole draft a tool short. Spend them on cards that are genuinely bad rather than waiting for one that is perfectly bad.",
  },
  {
    t: "Bidding to punish, not to win",
    p: "Raising purely to make your opponent pay more works right up until they pass and you own it. If you would be unhappy holding the card at your own bid, that bid is a bluff you cannot afford.",
  },
];

export default function HowToPlayPage() {
  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(faq) }}
      />
      <Header thin />
      <main className="mx-auto w-full max-w-2xl px-4 py-10">
        <h1 className="type-display text-[1.75rem]">How to play the $20 draft well</h1>
        <p className="mt-4 text-[0.9375rem] leading-relaxed text-muted">
          The rules of the $20 draft take a minute to learn and are set out on the{" "}
          <Link href="/20-dollar-draft" className="text-ink underline">
            what is the $20 draft
          </Link>{" "}
          page. This one is about playing it well: what the spending limits actually stop you
          doing, when handing a card to your opponent beats keeping it, and the handful of
          mistakes that decide most first drafts.
        </p>

        <div className="mt-8 flex flex-col gap-7">
          <Part heading="The reserve rule is the only rule that matters">
            <p>
              Two limits govern every bid. The obvious one is that you cannot bid more money than
              you have. The one that actually shapes the game is the reserve: you must always keep
              back enough to pay the minimum bid on every slot you still owe.
            </p>
            <p>
              With a $20 bankroll, five slots and a $1 minimum, your very first bid is capped at
              $16 — one dollar reserved for each of the four slots you are not currently bidding
              on. Win that card and the cap on your next bid is recalculated against what is left.
              The board shows this as a hatched section of your money rail, and it is the number
              to watch rather than your raw balance.
            </p>
            <p>
              The practical consequence: your spending power collapses fastest at the start and
              flattens out at the end. A player with $6 and one slot left can spend all $6. A
              player with $6 and four slots left can spend $3. Same money, less than half the
              power, and the difference is invisible if you are only looking at the balance.
            </p>
          </Part>

          <Part heading="Being the opener is a disadvantage, and it alternates">
            <p>
              Whoever opens a card must commit first — take it at the minimum, or give it away.
              Only then does the other player get to raise or pass. That means the opener declares
              interest into a vacuum while the responder decides with full information.
            </p>
            <p>
              Because the opener alternates every card, this evens out across a draft. What it
              means in the moment is that opening a card you badly want is dangerous: taking it at
              a dollar tells your opponent exactly what to raise on. Some of the best drafting is
              opening a card you want at the minimum and being visibly relaxed about losing it.
            </p>
          </Part>

          <Part heading="Giving is an attack, not a surrender">
            <p>
              Giving a card away puts it on your opponent&rsquo;s roster for free. It costs them a
              slot they will never get back, and it costs you nothing except one of your limited
              gives. New players treat the give as a way of skipping cards they do not like. It is
              better understood as the only move in the game that spends your opponent&rsquo;s
              resources instead of your own.
            </p>
            <p>
              Gives are capped deliberately. Without a cap, both players dumping every card is a
              stable and extremely boring equilibrium: the draft ends with the money untouched and
              nothing bid on. The cap is what forces at least some real bidding.
            </p>
            <p>
              Timing: a give early costs your opponent a slot when they have plenty. The same give
              with two slots left is close to a whole card of damage. Hold them longer than feels
              comfortable — but spend them, because an unused give is worth nothing at the end.
            </p>
          </Part>

          <Part heading="Running out of money does not end your draft">
            <p>
              Go broke and you stop being able to raise, but you are not eliminated and the game
              does not stall. Your remaining slots keep filling through the take-and-give
              mechanic. This matters strategically: bankrupting your opponent does not remove them
              from the draft, it just means everything from that point lands on their roster at
              the minimum. Sometimes that is exactly what they wanted.
            </p>
          </Part>

          <Part heading="Four mistakes that lose most first drafts">
            <div className="mt-1 flex flex-col">
              {MISTAKES.map((m) => (
                <div key={m.t} className="border-t py-3.5 rule">
                  <p className="type-label text-gold">{m.t}</p>
                  <p className="mt-1.5">{m.p}</p>
                </div>
              ))}
            </div>
          </Part>

          <Part heading="There is no algorithmic winner, and that is the point">
            <p>
              Nothing in the game scores your roster. When both rosters are full the draft simply
              ends, and the leftover cash sits next to each player as the only hard number. Who
              actually won is decided by the people watching, through a one-tap vote, or by the
              two players arguing about it — which is the part the format exists for.
            </p>
            <p>
              This is worth knowing before your first draft, because it changes what you are
              optimising for. You are not building the roster a spreadsheet would like. You are
              building the roster you can defend out loud to someone who watched you pay $7 for
              it.
            </p>
          </Part>

          <Part heading="Common questions">
            <p>
              <strong className="text-ink">How much can I bid?</strong> Never more than your
              bankroll, and never so much that you could not still afford the minimum on every
              slot you have left. The board enforces this; you cannot get it wrong by accident.
            </p>
            <p>
              <strong className="text-ink">Can I see what is coming?</strong> No, and neither can
              your opponent. The deck is shuffled on the server and cards are revealed one at a
              time. Nobody holds the list.
            </p>
            <p>
              <strong className="text-ink">Is this played for real money?</strong> No. The
              bankroll is a scoring unit inside a single room. There is no deposit, withdrawal,
              prize or wagering of any kind.
            </p>
            <p>
              <strong className="text-ink">Do I need an account?</strong> Not to play. Hosting and
              joining drafts, every premade category and the results card all work signed out.
            </p>
          </Part>
        </div>

        <p className="mt-10 text-[0.9375rem] leading-relaxed text-muted">
          Ready to try it?{" "}
          <Link href="/new" className="text-ink underline">
            Start a room
          </Link>{" "}
          and send the code to one other person, or read{" "}
          <Link href="/about" className="text-ink underline">
            more about the game
          </Link>
          .
        </p>
      </main>
      <Footer />
    </>
  );
}
