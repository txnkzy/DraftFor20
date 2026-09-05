import type { Metadata } from "next";
import Link from "next/link";
import { Footer, Header } from "@/components/site/Chrome";
import { CONTACT_EMAIL, JURISDICTION, OPERATOR, RETENTION_DAYS } from "@/lib/site";

export const metadata: Metadata = {
  alternates: { canonical: "/contact" },
  title: "Contact DraftFor20",
  description:
    "How to reach DraftFor20: support, bug reports, data deletion requests, billing questions and category corrections.",
};

const REASONS: { label: string; body: React.ReactNode }[] = [
  {
    label: "Something is broken",
    body: (
      <>
        Tell us what you were doing and what happened instead. The single most useful thing you
        can include is the six-character room code from the address bar — it lets us find the
        exact draft rather than guessing.
      </>
    ),
  },
  {
    label: "Delete my data",
    body: (
      <>
        Email from the address on the account and say what you want removed. Rooms and everything
        in them are deleted automatically after {RETENTION_DAYS} days regardless; this is for
        anything you want gone sooner, or for an account itself. What is stored in the first place
        is listed in the{" "}
        <Link href="/privacy" className="text-ink underline">
          privacy policy
        </Link>
        .
      </>
    ),
  },
  {
    label: "Billing",
    body: (
      <>
        Subscriptions can be cancelled at any time from your own profile without emailing anyone.
        For refunds, duplicate charges, or anything the profile page will not do, write to us and
        include the date and the last four digits of the card.
      </>
    ),
  },
  {
    label: "A category is wrong",
    body: (
      <>
        The premade categories are hand-checked but not infallible. If something in one is
        misspelled, out of date or does not belong, name the category and the entry and it will be
        fixed.
      </>
    ),
  },
];

export default function ContactPage() {
  return (
    <>
      <Header thin />
      <main className="mx-auto w-full max-w-2xl px-4 py-10">
        <h1 className="type-display text-[1.75rem]">Contact</h1>
        <p className="mt-4 text-[0.9375rem] leading-relaxed text-muted">
          Support is by email. There is no ticket system to log into and no chat widget — a
          message to the address below reaches a person.
        </p>

        <div className="mt-6 border p-4 rule">
          <p className="type-label text-muted">email</p>
          <a
            href={`mailto:${CONTACT_EMAIL}`}
            className="type-display mt-1 block text-[1.125rem] text-ink underline"
          >
            {CONTACT_EMAIL}
          </a>
          <p className="mt-3 text-[0.875rem] leading-relaxed text-muted">
            Expect a reply within a few working days. {OPERATOR} operates this service from the{" "}
            {JURISDICTION}.
          </p>
        </div>

        <section className="mt-10">
          <h2 className="type-display text-[1rem]">What to include</h2>
          <div className="mt-3 flex flex-col">
            {REASONS.map((r) => (
              <div key={r.label} className="border-t py-4 rule">
                <p className="type-label text-gold">{r.label}</p>
                <p className="mt-1.5 text-[0.9375rem] leading-relaxed text-muted">{r.body}</p>
              </div>
            ))}
          </div>
        </section>

        <p className="mt-10 text-[0.875rem] leading-relaxed text-muted">
          More about the game and who runs it is on the{" "}
          <Link href="/about" className="text-ink underline">
            about
          </Link>{" "}
          page. The rules are on the{" "}
          <Link href="/20-dollar-draft" className="text-ink underline">
            $20 draft
          </Link>{" "}
          page.
        </p>
      </main>
      <Footer />
    </>
  );
}
