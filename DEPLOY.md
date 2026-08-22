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

Set the constants in `lib/site.ts` — operator name, contact email, support
phone and governing-law jurisdiction. The privacy policy, terms and the footer
reference them.

`CONTACT_EMAIL` is `support@draftfor20.com`. **Create that mailbox before you
share the site**, or the legal pages point at an address that bounces. Two ways:

- **Forwarding only, free.** At your DNS host add an MX record for
  `draftfor20.com` pointing at a forwarder (Cloudflare Email Routing, or
  ImprovMX) and route `support@` to your personal inbox. You can read but
  replies come from your personal address.
- **A real mailbox, ~$6/user/month.** Google Workspace or Fastmail. Adds MX,
  SPF, DKIM and DMARC records, and you can reply as `support@`.

Either way add SPF and DMARC, otherwise anything you send lands in spam.

`SUPPORT_PHONE` is empty, and while it is empty no phone number renders
anywhere. Fill it in only once a number actually rings somewhere — see the
VOIP note below.

## A support phone number

Buy a VOIP line and put it in `SUPPORT_PHONE` as you want it displayed
(`+1 (555) 010-4477`); the `tel:` href is derived from it automatically.

| Option | Cost | Good for |
|---|---|---|
| Google Voice (personal) | free, US only | one number forwarded to your cell |
| Google Voice for Workspace | ~$10/user/mo | pairs with the Workspace mailbox |
| Twilio | ~$1.15/mo + usage | a number you route in code |
| OpenPhone / Grasshopper | ~$15–29/mo | shared inbox, hours, voicemail |

For a two-player side project, forwarding to your own cell is the honest
choice. Do not publish a number that goes to a voicemail nobody empties — no
number is better than a dead one, which is why the constant defaults to empty.

## Sharing a room

Two players, two devices. The host creates a room and sends the six-character
code or the `/room/CODE` link. No account needed to play.
