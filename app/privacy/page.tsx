import type { Metadata } from "next";
import Link from "next/link";
import { Clause, LegalShell } from "@/components/site/LegalShell";
import { CONTACT_EMAIL, OPERATOR, RETENTION_DAYS } from "@/lib/site";

export const metadata: Metadata = {
  title: "Privacy Policy — DraftFor20",
  description: "What DraftFor20 collects, why, how long it is kept and how to have it deleted.",
};

export default function PrivacyPage() {
  return (
    <LegalShell title="Privacy Policy">
      <p className="text-[0.9375rem] leading-relaxed text-muted">
        DraftFor20 is a two-player auction draft game. This page describes exactly what it
        stores, why it stores it, who else can see it and how to get rid of it. It covers the
        website and the game rooms. Nothing here is boilerplate: if something is not listed below,
        the service does not collect it.
      </p>

      <Clause heading="What you give us by playing">
        <p>
          <strong className="text-ink">A display name.</strong> You type it when you create or
          join a room. It is shown to the other player, to anyone who opens the room link, and it
          is printed on the shareable results card. Use a nickname. There is no requirement that it
          be your real name and we never ask you to verify it.
        </p>
        <p>
          <strong className="text-ink">Whatever you type into the draft.</strong> Room titles,
          category names, and the name of every item you nominate. Bids, passes and timeouts are
          recorded as a history so the board can be replayed and the results card can be built.
        </p>
        <p>
          <strong className="text-ink">A session token.</strong> When you take a seat, the server
          issues a random identifier and your browser keeps it in <code>localStorage</code> under a
          key starting <code>df20:seat:</code>. It is how the server knows a bid came from you
          without making you sign up. It works only in the one room it was issued for, and it is
          never sent to anyone but the game database. Clearing your browser storage gives up your
          seat.
        </p>
        <p>
          If two of you play on one computer, that browser holds a token for <em>both</em> seats
          and hands the controls to whoever is up. Both tokens sit under the same key. Anyone using
          that browser can act as either player, which is the point of the mode, so only use it
          with someone sitting next to you.
        </p>
      </Clause>

      <Clause heading="What you give us only if you choose to host with an account">
        <p>
          <strong className="text-ink">An email address.</strong> An account is optional and exists
          so that saved category templates, card branding and anything you have paid for survive
          between sessions. Sign-in is a magic link, so there is no password to store. The address
          is used to send that link and receipts for anything you buy. There is no marketing list.
        </p>
        <p>
          <strong className="text-ink">What the account holds.</strong> A handle if you set one, a
          counter of drafts hosted and played and the badges derived from it, your export-card
          settings (watermark, accent, logo, social handle), and — if you have bought premium —
          whether it is active, when it expires, and the customer and subscription identifiers
          Stripe issued. We never see or store a card number.
        </p>
        <p>
          If you host without signing in, which is the default, we never learn your email.
        </p>
        <p>
          A small number of accounts are marked as administrators. They can see the list of
          accounts and premium status in order to run the service, and can grant premium by hand.
          They cannot read the contents of a room that has not been shared with them.
        </p>
      </Clause>

      <Clause heading="What gets collected automatically">
        <p>
          Our hosting and database providers keep ordinary server logs, which include IP addresses,
          timestamps and user-agent strings, for security and abuse handling. We do not run
          advertising trackers, we do not build behavioural profiles, and we do not sell or share
          anything with data brokers.
        </p>
        <p>
          <strong className="text-ink">We also record IP addresses ourselves, briefly.</strong>{" "}
          Actions that can be abused — asking for a sign-in link, creating an account, voting on a
          draft — are rate limited by counting requests against the requesting IP address in our
          own database. Those rows are deleted after one day by a scheduled job. They are used to
          stop flooding and for nothing else.
        </p>
        <p>
          <strong className="text-ink">One cookie, and only if you vote.</strong> Voting on a draft
          you are watching sets <code>df20_av</code>, a cookie holding a random identifier so the
          same browser cannot vote twice in the same room. It is set by the server, unreadable by
          scripts, lasts a year and is tied to nothing else about you. There are no analytics or
          advertising cookies anywhere on the site.
        </p>
        <p>
          Fonts are served from our own domain rather than a font CDN. Generating the downloadable
          results-card image fetches a font file from Google Fonts on the <em>server</em>, not from
          your browser, so your address is not exposed by it.
        </p>
        <p>
          <strong className="text-ink">Two places your browser does contact someone else.</strong>{" "}
          Picture cards on some categories are loaded straight from Wikimedia Commons, so your
          browser asks Wikimedia for that image and Wikimedia can see your IP address, as it can
          for anyone loading an image from it. And the sign-up page runs a Cloudflare Turnstile
          check to keep automated sign-ups out, which means Cloudflare sees that request. Neither
          is used to profile you, and neither is present on a room you are simply playing in
          without images.
        </p>
      </Clause>

      <Clause heading="Custom categories">
        <p>
          <strong className="text-ink">A list you type is private by default.</strong> When
          someone builds a category through a setup link, that list belongs to that one room. It
          is never shown to either player, never returned by any part of the site, and never
          copied anywhere else unless the person who wrote it explicitly asks us to.
        </p>
        <p>
          <strong className="text-ink">Lists involving real people are never shareable.</strong>{" "}
          Before we even offer to add a category to the shared library, we check the category name
          and the items for signs of real people, including obviously person-oriented names like
          &ldquo;friend group&rdquo; or &ldquo;tier list&rdquo;. If anything trips that check the
          option never appears, and there is no way to override it. The check is deliberately
          cautious and will sometimes withhold a list that would have been fine.
        </p>
        <p>
          <strong className="text-ink">Everything else is opt-in.</strong> After a draft finishes,
          whoever built the list may be asked once whether to add it to the shared library.
          It is unticked by default and declining is remembered. If a category is added, we store
          only its name and its items. Not who played, not when, not which room.
        </p>
        <p>
          <strong className="text-ink">Wikipedia lists are cached automatically.</strong> When you
          ask for a category we do not already have, we look for a matching Wikipedia article and
          parse it. Successful results are saved so the next person asking for the same thing does
          not trigger another lookup. This content is already public encyclopedia material, it
          contains nothing you typed beyond the category name, and so it is cached without asking.
        </p>
      </Clause>

      <Clause heading="Who else can see a room">
        <p>
          Rooms are unlisted, not secret. Anyone holding the six-character code or the room link can
          open it and watch the draft, including the names, picks and bids in it. There is no
          directory and rooms are never indexed by search engines, but treat a room link the way you
          would treat any link you paste into a group chat.
        </p>
        <p>
          The results card is generated on request from the room code. If you post it, you are
          publishing both players&apos; display names and picks. That is the intended use, and it
          is worth saying out loud.
        </p>
      </Clause>

      <Clause heading="Voting on somebody else's draft">
        <p>
          A finished draft can be shared with a link that lets whoever opens it say which roster
          they think won. No account is needed and none is offered. All that is stored is which
          player you picked, the room it was for, the time, and the random identifier from the{" "}
          <code>df20_av</code> cookie described above, which exists only to stop the same browser
          voting twice. Your IP address is counted against a rate limit, as described above, and is
          not stored alongside your vote.
        </p>
        <p>
          Votes are counted and shown as a running tally to the players and to other voters. They
          are never shown individually and there is nothing in one that identifies you. They are
          deleted with the room.
        </p>
      </Clause>

      <Clause heading="Paying for premium">
        <p>
          Payments are taken by <strong className="text-ink">Stripe</strong>. Card details are
          entered on Stripe&apos;s own checkout page and never touch our servers — we cannot see a
          card number, and we do not store one. What comes back to us is the customer and
          subscription identifiers, whether the payment succeeded, and how long your access should
          last.
        </p>
        <p>
          Stripe is an independent controller for the payment itself and keeps its own records for
          as long as financial law requires it to, which is longer than our retention schedule and
          is not ours to shorten. Their privacy policy governs that part.
        </p>
      </Clause>

      <Clause heading="Processors we use">
        <p>
          <strong className="text-ink">Supabase</strong> hosts the Postgres database, the realtime
          connection and the optional host authentication. All game data lives there.
        </p>
        <p>
          <strong className="text-ink">Vercel</strong> hosts and serves the application and keeps
          short-lived request logs.
        </p>
        <p>
          <strong className="text-ink">Stripe</strong> takes payments and holds the billing
          relationship, as described above.
        </p>
        <p>
          <strong className="text-ink">Cloudflare</strong> sits in front of the domain and runs the
          anti-automation check on the sign-up page.
        </p>
        <p>
          Both act as processors on our instructions. Neither is permitted to use your data for
          their own purposes.
        </p>
      </Clause>

      <Clause heading="How long it is kept">
        <p>
          Rooms, players, rosters and bid histories are deleted automatically{" "}
          {RETENTION_DAYS} days after the room was created. That deletion is a scheduled database
          job, not a promise we remember to keep by hand. Once it runs, the room link and its
          results card stop working permanently.
        </p>
        <p>
          Accounts, saved templates, handles and branding persist until you ask us to delete the
          account. Rate-limit counters are deleted after a day. Provider log retention is governed
          by the providers above and is measured in days, not years.
        </p>
        <p>
          Deleting your account removes your side of the billing record, but not Stripe&apos;s.
          They are required to keep transaction records regardless of what we do, and we cannot
          delete them on your behalf.
        </p>
      </Clause>

      <Clause heading="Who is responsible">
        <p>
          {OPERATOR} is the controller of the data described here and decides how it is used. Reach
          us at <a className="text-gold" href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a>.
        </p>
      </Clause>

      <Clause heading="Deleting something sooner">
        <p>
          Email <a className="text-gold" href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a> with
          the room code and we will delete that room. If you have a host account, say so and we
          will delete the account, its templates and its branding. Depending on where you live you
          may also have the right to a copy of your data, to correct it, to object to processing or
          to complain to a data protection authority. Ask and we will help rather than make you
          quote statutes at us.
        </p>
      </Clause>

      <Clause heading="Children">
        <p>
          DraftFor20 is not directed at children. Do not use it if you are under 13, or under 16 in
          the EEA and UK. If you believe a child has entered personal information, email us and we
          will remove the room.
        </p>
      </Clause>

      <Clause heading="Security">
        <p>
          Traffic is encrypted in transit. Database row-level security is on for every table and no
          client can read or write tables directly; all access goes through server-side functions
          that authenticate the caller. Bids are validated inside the database against your live
          balance, so a modified browser cannot spend money it does not have. No system is perfect,
          and this is a game rather than a bank, so please do not put anything sensitive in a pick
          name.
        </p>
      </Clause>

      <Clause heading="Changes">
        <p>
          If this policy changes in a way that affects what is collected or how long it is kept, the
          date at the top changes and the previous behaviour stops applying only going forward. See
          also the <Link className="text-gold" href="/terms">Terms of Service</Link>.
        </p>
      </Clause>
    </LegalShell>
  );
}
