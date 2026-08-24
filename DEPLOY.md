# Getting DraftFor20 onto a real URL

Supabase hosts the **database**. It does not host the website. To give friends a
link you deploy the Next.js app to Vercel, which is free for this.

## 1. Deploy

From this folder in Terminal:

```bash
npx vercel
```

First run asks you to log in (it opens a browser, you click once), then asks a
few questions. Accept every default — it detects Next.js on its own. When it
finishes it prints a URL like `draftfor20-xyz.vercel.app`.

**That URL will not work yet.** It has no database credentials. Step 2 fixes it.

## 2. Add the three environment variables

Vercel dashboard → your project → **Settings** → **Environment Variables**.
Add all three to Production, Preview and Development:

| Name | Value |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | `https://jwnlmvjzeodfmngnhadq.supabase.co` |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | your `sb_publishable_…` key |
| `NEXT_PUBLIC_SITE_URL` | the Vercel URL, no trailing slash |

All three are safe to expose; they ship in the browser bundle by design. Never
add an `sb_secret_` key here — this app never needs one.

Then redeploy so they take effect:

```bash
npx vercel --prod
```

## 3. Point Supabase auth at the new domain

Only matters for host sign-in. Supabase → **Authentication** → **URL
Configuration**:

- **Site URL**: your Vercel URL
- **Redirect URLs**: add `https://YOUR-URL.vercel.app/auth/callback`

Skip this if you are not using host accounts yet. Playing never needs it.

## 4. Check it

Open the URL on your phone with wifi off. If the landing page loads and
`/new` creates a room, it is genuinely public.

---

## Before you share it widely

Set the constants in `lib/site.ts` — operator name, contact email and
governing-law jurisdiction. The privacy policy, terms and the footer reference
them.

`CONTACT_EMAIL` is `support@draftfor20.com`. **Create that mailbox before you
share the site**, or the legal pages point at an address that bounces. Two ways:

- **Forwarding only, free.** At your DNS host add an MX record for
  `draftfor20.com` pointing at a forwarder (Cloudflare Email Routing, or
  ImprovMX) and route `support@` to your personal inbox. You can read but
  replies come from your personal address.
- **A real mailbox, ~$6/user/month.** Google Workspace or Fastmail. Adds MX,
  SPF, DKIM and DMARC records, and you can reply as `support@`.

Either way add SPF and DMARC, otherwise anything you send lands in spam.

Support is **email-only**, deliberately. There is no phone number anywhere in
this app and no constant for one.

## The phone number Stripe asks for

Stripe's **public business profile** collects a support phone number, and it is
printed on card receipts and shown in the Checkout footer. That is a field in
Stripe's dashboard (Settings → Business → Public details), not anything this
codebase renders — putting it in `lib/site.ts` would only publish it a second
time, in a place customers would expect an answer.

The catch is that it has to be a number you keep, because it lands on receipts
that outlive the month you set it. Two ways that end well:

- **Twilio, ~$1.15/month.** Buy a number, point it at a TwiML voicemail
  greeting that says support is by email at `support@draftfor20.com`, and never
  look at it again. It is yours for as long as you pay for it.
- **Your own cell.** Free, works, and it is now on every receipt you issue.

**Do not use a free Google Voice number for this.** Google reclaims Voice
numbers that go unused, and a number you will never answer is by definition
unused — so the one printed on your receipts is exactly the one at risk of
being reassigned to a stranger.

At ~$14/year, Twilio with a voicemail greeting is the right call here: nobody
reaches you, the greeting redirects them to the inbox you actually read, and
the number does not evaporate.

Whichever you pick, set the same address as your Stripe **support email** so
the receipt and the site agree.

## Sharing a room

Two players, two devices. The host creates a room and sends the six-character
code or the `/room/CODE` link. No account needed to play.
