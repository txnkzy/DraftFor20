import type { Metadata } from "next";
import Link from "next/link";
import { Clause, LegalShell } from "@/components/site/LegalShell";
import { CONTACT_EMAIL, JURISDICTION, OPERATOR } from "@/lib/site";

export const metadata: Metadata = {
  title: "Terms of Service — DraftFor20",
  description: "The rules for using DraftFor20. It is a game with play money and no payouts.",
};

export default function TermsPage() {
  return (
    <LegalShell title="Terms of Service">
      <p className="text-[0.9375rem] leading-relaxed text-muted">
        These terms are the agreement between you and {OPERATOR} for the use of DraftFor20. By
        creating a room, taking a seat or watching a draft, you accept them. If you do not, do not
        use the service.
      </p>

      <Clause heading="What this is, and what it is not">
        <p>
          DraftFor20 is a game. The &ldquo;$20&rdquo; is a fixed number of play-money points that
          exists only inside a room. There is no deposit, no withdrawal, no purchase, no prize and
          no payout. Nothing on this service is gambling, and nothing on it has cash value.
        </p>
        <p>
          If you and your opponent choose to attach a real-world stake to the outcome, that is
          entirely between you. We are not a party to it, we do not hold or transfer anything, and
          we take no responsibility for it.
        </p>
      </Clause>

      <Clause heading="Who may use it">
        <p>
          You must be at least 13 years old, or 16 in the EEA and the UK. If you are using the
          service on behalf of an organisation, you confirm you are allowed to accept these terms
          for it.
        </p>
      </Clause>

      <Clause heading="Seats and accounts">
        <p>
          Playing needs no account. Your seat in a room is held by a token stored in your browser.
          Anyone using that browser can act as you in that room, so do not leave a draft open on a
          device you are handing to someone else.
        </p>
        <p>
          Two people may also share one computer on purpose. In that mode the browser holds both
          seats and passes the controls to whoever is up, which means whoever is at the keyboard
          can act as either player. That is the intended behaviour, not a flaw, and it is your
          choice to use it.
        </p>
        <p>
          A host account is optional and is secured by a link sent to your email. You are
          responsible for who can read that inbox. Tell us if you think an account has been taken
          over.
        </p>
      </Clause>

      <Clause heading="What you type">
        <p>
          You keep ownership of the room titles, category names and pick names you enter. You give
          us permission to store them, show them to the other player and to anyone with the room
          link, and render them onto the results card, because that is what the product does.
        </p>
        <p>
          You are responsible for what you type. Do not enter anything unlawful, anything that
          harasses or defames a real person, anything infringing, or anything you would not want
          screenshotted. Display names and pick names are visible to your opponent and appear on a
          card designed to be posted publicly.
        </p>
      </Clause>

      <Clause heading="Fair play">
        <p>Do not:</p>
        <p>
          Attempt to bypass, race or otherwise defeat the bid validation, whether by modifying the
          client, replaying requests or calling the database functions directly with forged
          arguments. Automate play, scrape rooms, or open rooms at volume. Interfere with the
          service, probe it for vulnerabilities without asking us first, or use it to store or
          distribute content unrelated to a draft.
        </p>
        <p>
          Found a genuine security flaw? Email{" "}
          <a className="text-gold" href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a> before
          publishing it and we will work with you.
        </p>
      </Clause>

      <Clause heading="Paying for premium">
        <p>
          The game is free to play and always will be: creating a room, taking a seat, drafting and
          the results card cost nothing and need no account. Premium is optional and unlocks
          presentation features rather than any advantage in a draft. Nothing you buy changes a
          rule, a bankroll or an outcome, and an unpaid player is never at a disadvantage against a
          paying one.
        </p>
        <p>
          There are two ways to buy it, and current prices are on the{" "}
          <Link className="text-gold" href="/pricing">pricing page</Link> rather than here, because
          they may change. A <strong className="text-ink">day pass</strong> is a one-off payment
          that adds 24 hours of access and then simply stops. It does not renew and there is
          nothing to cancel. A <strong className="text-ink">monthly subscription</strong> renews
          automatically each month, at the price shown when you subscribed, until you cancel it.
        </p>
        <p>
          <strong className="text-ink">Cancelling.</strong> Cancel any time from the billing page
          in your account, which opens Stripe&apos;s own portal. Cancelling stops the next renewal
          and leaves your access running to the end of the period you have already paid for. We do
          not ask why and there is no retention flow to click through.
        </p>
        <p>
          <strong className="text-ink">Refunds.</strong> If premium did not work, or you were
          charged twice, or you were charged after cancelling, email us and we will refund it. If
          you simply changed your mind, ask anyway — for sums this small we would rather refund you
          than argue. Where you have a statutory right to cancel or refund, that right applies on
          top of this and nothing here reduces it.
        </p>
        <p>
          <strong className="text-ink">Price changes.</strong> A change to the subscription price
          takes effect only from your next renewal, and you will be told before it is charged. A
          day pass is priced when you buy it.
        </p>
        <p>
          If a payment fails or is reversed, premium features stop until it is settled. Nothing you
          created while premium was active is deleted for that reason, though features that require
          premium stop working.
        </p>
      </Clause>

      <Clause heading="Rooms are unlisted, not private">
        <p>
          A room code is a key, not a password. Anyone who has it can watch. Do not treat a room as
          a confidential space, and do not put anything in one that you need to keep to yourself.
        </p>
      </Clause>

      <Clause heading="Availability and changes">
        <p>
          The service is provided as it stands. We may change, suspend or discontinue any part of
          it, including deleting rooms under the retention schedule described in the{" "}
          <Link className="text-gold" href="/privacy">Privacy Policy</Link>. There is no uptime
          commitment. A draft interrupted by an outage may not be recoverable. If we withdraw a
          premium feature you are currently paying a subscription for, you may cancel and we will
          refund the unused part of the period.
        </p>
      </Clause>

      <Clause heading="Ending access">
        <p>
          You can stop at any time and ask us to delete your rooms or account. We may suspend or
          remove access, or delete a room, if it breaches these terms or if keeping it up exposes
          us or another user to harm or legal risk.
        </p>
      </Clause>

      <Clause heading="Disclaimers">
        <p>
          To the fullest extent the law allows, the service is provided &ldquo;as is&rdquo; without
          warranties of any kind, express or implied, including fitness for a particular purpose
          and uninterrupted or error-free operation. We do not warrant that a draft will complete,
          that a results card will generate, or that data will survive a provider failure.
        </p>
      </Clause>

      <Clause heading="Liability">
        <p>
          To the fullest extent the law allows, {OPERATOR} is not liable for indirect, incidental,
          special or consequential loss, nor for lost data, lost drafts, or any real-world stake you
          arranged privately with another player. Where liability cannot be excluded, it is limited
          to the greater of the amount you paid us in the twelve months before the claim, which for
          a free account is nothing, and the minimum the law requires. Nothing here limits
          liability for death or personal injury caused by negligence, or for fraud.
        </p>
      </Clause>

      <Clause heading="Governing law">
        <p>
          These terms are governed by the laws of {JURISDICTION}, and its courts have exclusive
          jurisdiction, without affecting any mandatory consumer protections you have where you
          live.
        </p>
      </Clause>

      <Clause heading="Contact">
        <p>
          <a className="text-gold" href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a>
        </p>
      </Clause>
    </LegalShell>
  );
}
