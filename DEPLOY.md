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

Set the three constants in `lib/site.ts` — operator name, contact email and
governing-law jurisdiction. The privacy policy and terms reference them and
currently say `hello@draftfor20.app`, which is not a real inbox.

## Sharing a room

Two players, two devices. The host creates a room and sends the six-character
code or the `/room/CODE` link. No account needed to play.
