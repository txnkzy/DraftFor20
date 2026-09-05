import type { Metadata } from "next";
import Link from "next/link";
import { Footer, Header } from "@/components/site/Chrome";

export const metadata: Metadata = {
  alternates: { canonical: "/draft-categories" },
  title: "Draft Category Ideas — What Makes a Category Play Well",
  description:
    "Every premade category on DraftFor20, grouped and explained, plus the four properties that separate a category that starts arguments from one that falls flat — and how to build your own.",
};

/**
 * Grouped editorially rather than dumped from the database.
 *
 * A raw list of names with counts would be the same page the app already
 * shows in the room builder, and a page that only restates a UI list is the
 * definition of thin. What is worth writing down is WHY each group drafts the
 * way it does, which is not in the database and cannot be generated.
 */
const GROUPS = [
  {
    name: "Sports",
    lead: "The original format, and still the easiest sell if both players follow the sport. The risk is knowledge asymmetry: a lopsided draft is boring, and the fix is teams rather than players.",
    items: [
      ["Football Draft", 268, "The deepest deck on the shelf. Big enough that two drafts from it barely overlap."],
      ["NFL All-Time Greats", 59, "Names everyone recognises, so the argument is about value rather than trivia."],
      ["NBA All-Time Greats", 59, "Generational splits make this one loud. Expect disagreement about eras."],
      ["NFL Teams", 32, "Teams beat players when one of you follows the sport more closely — the value is in the badge, not the roster."],
      ["NBA Teams", 30, ""],
      ["MLB Teams", 30, ""],
    ],
  },
  {
    name: "Food and drink",
    lead: "The most reliable category type for a first draft with someone who does not follow sport. Everybody has a position, nobody needs any knowledge, and the disagreements are immediate and unserious.",
    items: [
      ["Candy and Sweets", 43, "The best starter category on the shelf. Strong opinions, no expertise required."],
      ["Fast Food Chains", 42, "Regional loyalties do a lot of the work here."],
      ["Halloween Candy", 36, "Seasonal, and narrower than Candy and Sweets, so the good picks run out faster."],
      ["Soft Drinks", 35, ""],
      ["Breakfast Cereals", 34, ""],
      ["Chip Flavors", 30, ""],
      ["Pizza Toppings", 29, "Small and deliberately divisive — a short, fast draft."],
      ["Ice Cream Flavors", 28, ""],
    ],
  },
  {
    name: "Anime",
    lead: "The most contested categories on the site, because power-scaling arguments are already a hobby for the people drafting them. Best played by two people who watch the same show.",
    items: [
      ["One Piece Characters", 80, "The largest anime deck. Deep enough that the back half is genuinely obscure."],
      ["My Hero Academia Characters", 66, ""],
      ["Dragon Ball Z Characters", 65, ""],
      ["Naruto Characters", 60, ""],
      ["Demon Slayer Characters", 45, ""],
      ["Jujutsu Kaisen Characters", 28, "The tightest deck here — most names are ones both players will have a view on."],
    ],
  },
  {
    name: "Screen and music",
    lead: "Nostalgia categories. They tend to produce the most even drafts, because value is personal rather than objective and neither player can be straightforwardly wrong.",
    items: [
      ["Movie Villains", 40, ""],
      ["Disney Animated Movies", 40, ""],
      ["TV Sitcoms", 40, ""],
      ["Superheroes", 40, "Cross-universe, so expect at least one argument about whether the comparison is fair."],
      ["90s Songs", 40, ""],
      ["2000s Songs", 39, ""],
      ["Video Game Franchises", 40, ""],
      ["Board Games", 36, ""],
    ],
  },
  {
    name: "Everything else",
    lead: "Categories that work because nobody arrives with a ranking already formed.",
    items: [
      ["US States", 50, "Surprisingly good. Everyone has been to some of them and nobody has a defensible ranking."],
      ["Dog Breeds", 40, "The least confrontational category on the shelf, which is sometimes exactly what you want."],
    ],
  },
];

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

export default function DraftCategoriesPage() {
  return (
    <>
      <Header thin />
      <main className="mx-auto w-full max-w-2xl px-4 py-10">
        <h1 className="type-display text-[1.75rem]">Draft categories</h1>
        <p className="mt-4 text-[0.9375rem] leading-relaxed text-muted">
          A draft is only as good as what it is drafting. Below is every premade category on the
          shelf, grouped by what they are actually like to play, followed by the four things that
          separate a category which starts arguments from one that dies after four cards.
        </p>

        <div className="mt-8 flex flex-col gap-7">
          <Rule heading="What makes a category play well">
            <p>
              <strong className="text-ink">A spread of value, not a ranking.</strong> The best
              categories have five or six genuinely great entries, a long middle where reasonable
              people disagree, and some obvious junk. A category where everyone agrees on the
              order is not a draft, it is a queue — the cards go in sequence at the minimum bid
              and nobody has a decision to make.
            </p>
            <p>
              <strong className="text-ink">Recognition, not expertise.</strong> If one player has
              to ask who a name is, that card is dead. It does not matter how deep the category is
              if half of it means nothing to one of you. This is the single most common reason a
              custom category disappoints.
            </p>
            <p>
              <strong className="text-ink">At least four times your roster size.</strong> A
              five-slot draft needs ten cards dealt, and if the deck is only twelve deep then
              almost everything gets seen and scarcity stops mattering. Aim for thirty or more.
              The premade decks are sized well past this on purpose.
            </p>
            <p>
              <strong className="text-ink">Something to argue about.</strong> The game does not
              calculate a winner. If a category has no basis for a fight — no eras, no regional
              loyalties, no guilty pleasures — then the end of the draft is just two lists.
            </p>
          </Rule>

          {GROUPS.map((g) => (
            <section key={g.name} className="border-t pt-4 rule">
              <h2 className="type-display text-[1rem]">{g.name}</h2>
              <p className="mt-2 text-[0.9375rem] leading-relaxed text-muted">{g.lead}</p>
              <div className="mt-3 flex flex-col">
                {g.items.map(([name, count, note]) => (
                  <div key={String(name)} className="flex flex-col border-t py-2.5 rule">
                    <div className="flex items-baseline gap-3">
                      <span className="text-[0.9375rem] text-ink">{name}</span>
                      <span className="type-label ml-auto text-gold">{count} cards</span>
                    </div>
                    {note ? (
                      <p className="mt-1 text-[0.875rem] leading-relaxed text-muted">{note}</p>
                    ) : null}
                  </div>
                ))}
              </div>
            </section>
          ))}

          <Rule heading="Building your own">
            <p>
              With an account you can type any category name and have the list built for you from
              Wikipedia, or hand the job to a third person entirely — they build the list from a
              setup link and neither player sees it before it is dealt. That last option is the
              best version of the game, because the host is drafting blind alongside their
              opponent rather than half-remembering a list they typed.
            </p>
            <p>
              If you are writing a list by hand, the failure mode to avoid is stacking it with
              your own favourites. A deck of forty things you like has no junk in it, and a draft
              with no junk has nothing to give away.
            </p>
            <p>
              <Link href="/new" className="text-ink underline">
                Start a room
              </Link>{" "}
              to see the full shelf, or read the{" "}
              <Link href="/how-to-play" className="text-ink underline">
                strategy guide
              </Link>{" "}
              first.
            </p>
          </Rule>
        </div>
      </main>
      <Footer />
    </>
  );
}
