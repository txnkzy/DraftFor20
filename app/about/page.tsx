import type { Metadata } from "next";
import Link from "next/link";
import { Footer, Header } from "@/components/site/Chrome";
import { CONTACT_EMAIL, OPERATOR } from "@/lib/site";

export const metadata: Metadata = {
  alternates: { canonical: "/about" },
  title: "About DraftFor20 — who makes it and how it works",
  description:
    "DraftFor20 is a free two-player auction draft game that runs in the browser. What it is, how a draft actually works, why there is no real money in it, and who operates the site.",
};

function Section({ heading, children }: { heading: string; children: React.ReactNode }) {
  return (
    <section className="border-t pt-4 rule">
      <h2 className="type-display text-[1rem]">{heading}</h2>
      <div className="mt-2 flex flex-col gap-3 text-[0.9375rem] leading-relaxed text-muted">
        {children}
      </div>
    </section>
  );
}

export default function AboutPage() {
  return (
    <>
      <Header thin />
      <main className="mx-auto w-full max-w-2xl px-4 py-10">
        <h1 className="type-display text-[1.75rem]">About DraftFor20</h1>
        <p className="mt-4 text-[0.9375rem] leading-relaxed text-muted">
          DraftFor20 is a free head-to-head drafting game that runs in a web browser. Two people
          split an identical play-money bankroll across a fixed number of roster slots, bidding
          against each other over names dealt one at a time from a shuffled deck. It takes about
          ten minutes and needs nothing installed.
        </p>

        <div className="mt-8 flex flex-col gap-7">
          <Section heading="Where the format came from">
            <p>
              The &ldquo;$20 draft&rdquo; spread as a short-video format: someone reads out a
              category, two people argue over what each name is worth, and the fun is in watching
              somebody blow their whole budget on the first good pick. It is a great thing to
              watch and an awkward thing to actually play, because somebody has to keep the
              books, remember what is left, and stop the person who has run out of money from
              bidding anyway.
            </p>
            <p>
              This site is that job, done by a server. It shuffles the deck so neither player can
              see what is coming, holds the clock, and refuses any bid that the person cannot
              afford. What is left is the argument, which is the part worth having.
            </p>
          </Section>

          <Section heading="How a draft works">
            <p>
              Both players start with the same bankroll and the same number of slots to fill. A
              card is dealt face-up and opens at the minimum bid. The player who opens it either
              takes it at a dollar or gives it away to their opponent for free — and gives are
              limited, so they cannot simply dump everything they do not want.
            </p>
            <p>
              If they take it, the other player can raise or pass, and it goes back and forth
              until somebody passes. You can never bid more than you have, and you can never bid
              so much that you could not afford the minimum on every slot you still owe. When
              both rosters are full the draft ends. Nothing calculates a winner: the leftover cash
              is the scoreboard, and anyone watching can vote on who did better.
            </p>
            <p>
              There is a longer walkthrough of the rules, with examples, on the{" "}
              <Link href="/20-dollar-draft" className="text-ink underline">
                $20 draft
              </Link>{" "}
              page.
            </p>
          </Section>

          <Section heading="There is no real money in this">
            <p>
              The dollar amounts in a draft are scoring units and nothing else. There is no way to
              deposit money, no way to withdraw it, no prize, no payout and no wagering of any
              kind. A bankroll exists only inside a single game room, it cannot be bought, topped
              up or transferred, and it ceases to mean anything the moment the draft ends.
            </p>
            <p>
              The game is not a game of chance and nothing about it is a betting product. It is
              closer to a pub quiz with a spending limit than to anything you could lose money on.
            </p>
          </Section>

          <Section heading="How the site pays for itself">
            <p>
              Playing is free and stays free: every premade category, unlimited drafts, the
              shareable results card and the audience vote all work without an account. There is
              an optional paid tier for people filming their drafts, which unlocks a vertical
              board built for phone video, an OBS browser source and a fuller history of your past
              drafts. Details are on the{" "}
              <Link href="/pricing" className="text-ink underline">
                pricing
              </Link>{" "}
              page.
            </p>
          </Section>

          <Section heading="Who operates this">
            <p>
              {OPERATOR} operates this site. Questions, bug reports, deletion requests and
              anything else go to{" "}
              <a href={`mailto:${CONTACT_EMAIL}`} className="text-ink underline">
                {CONTACT_EMAIL}
              </a>
              , or through the{" "}
              <Link href="/contact" className="text-ink underline">
                contact
              </Link>{" "}
              page. What the site stores and for how long is set out in the{" "}
              <Link href="/privacy" className="text-ink underline">
                privacy policy
              </Link>
              .
            </p>
          </Section>
        </div>
      </main>
      <Footer />
    </>
  );
}
