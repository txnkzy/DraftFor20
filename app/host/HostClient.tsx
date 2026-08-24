"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Field, TextInput } from "@/components/ui/Field";
import { Footer, Header, SetupNotice } from "@/components/site/Chrome";
import { passwordProblem } from "@/lib/auth";
import { uploadBrandLogo } from "@/lib/brand";
import { centsToInput, parseDollarsToCents } from "@/lib/money";
import { supabaseBrowser, supabaseConfigured } from "@/lib/supabase/client";

interface Pending {
  setup_token: string;
  expires_at: string;
}

interface Template {
  id: string;
  name: string;
  default_roster_size: number;
  default_bankroll_cents: number;
  default_min_bid_cents: number;
  default_timer_seconds: number;
  default_gives_per_player: number;
}

export function HostClient() {
  if (!supabaseConfigured()) return <SetupNotice />;
  return <Host />;
}

function Host() {
  const sb = supabaseBrowser();
  const router = useRouter();
  const [userId, setUserId] = useState<string | null>(null);
  const [email, setEmail] = useState<string | null>(null);
  const [ready, setReady] = useState(false);

  const [displayName, setDisplayName] = useState("");
  const [uploading, setUploading] = useState(false);
  const [newPassword, setNewPassword] = useState("");
  const [pwMsg, setPwMsg] = useState<string | null>(null);
  const [accent, setAccent] = useState("");
  const [logo, setLogo] = useState("");
  const [savedProfile, setSavedProfile] = useState(false);

  const [templates, setTemplates] = useState<Template[]>([]);
  const [pending, setPending] = useState<Pending[]>([]);
  const [tName, setTName] = useState("");
  const [tRoster, setTRoster] = useState("5");
  const [tBankroll, setTBankroll] = useState("20");
  const [tMinBid, setTMinBid] = useState("1");
  const [tTimer, setTTimer] = useState(15);
  const [error, setError] = useState<string | null>(null);

  const loadTemplates = useCallback(async () => {
    const { data } = await sb
      .from("templates")
      .select("id,name,default_roster_size,default_bankroll_cents,default_min_bid_cents,default_timer_seconds,default_gives_per_player")
      .order("created_at", { ascending: false });
    setTemplates((data as Template[]) ?? []);
  }, [sb]);

  useEffect(() => {
    void (async () => {
      const { data } = await sb.auth.getUser();
      if (!data.user) {
        setReady(true);
        return;
      }
      setUserId(data.user.id);
      setEmail(data.user.email ?? null);
      const { data: p } = await sb
        .from("profiles")
        .select("display_name,brand_accent,brand_logo_url")
        .eq("id", data.user.id)
        .maybeSingle();
      if (p) {
        setDisplayName(p.display_name ?? "");
        setAccent(p.brand_accent ?? "");
        setLogo(p.brand_logo_url ?? "");
      }
      await loadTemplates();
      const { data: pend } = await sb.rpc("my_pending_setups");
      setPending((pend as Pending[]) ?? []);
      setReady(true);
    })();
  }, [sb, loadTemplates]);

  async function uploadLogo(file?: File) {
    if (!file || !userId) return;
    setError(null);
    setUploading(true);
    const { url, error: upErr } = await uploadBrandLogo(sb, userId, file);
    setUploading(false);
    if (upErr) {
      setError(upErr);
      return;
    }
    if (url) setLogo(url);
  }

  /**
   * Accounts made through the old magic-link-only flow have no password at
   * all, so without this they could never use the new sign-in. Also serves as
   * an ordinary password change. The value goes straight to Supabase Auth.
   */
  async function setPassword() {
    setPwMsg(null);
    const problem = passwordProblem(newPassword, email ?? "");
    if (problem) {
      setPwMsg(problem);
      return;
    }
    const { error: e } = await sb.auth.updateUser({ password: newPassword });
    setNewPassword("");
    setPwMsg(e ? e.message : "Password set. You can sign in with it from now on.");
  }

  async function saveProfile() {
    if (!userId) return;
    setError(null);
    // Through save_profile() rather than a direct upsert: `authenticated`
    // holds no write grant on profiles at all any more, because that table
    // also carries premium_until and stripe_customer_id and a blanket grant
    // on it was a self-serve premium button (0041/0042). The RPC writes the
    // three branding columns and nothing else, and takes the email from
    // auth.users rather than from us.
    const { error: e } = await sb.rpc("save_profile", {
      p_display_name: displayName.trim() || null,
      p_brand_accent: accent.trim() || null,
      p_brand_logo_url: logo.trim() || null,
    });
    if (e) setError(e.message);
    else {
      setSavedProfile(true);
      setTimeout(() => setSavedProfile(false), 1800);
    }
  }

  async function addTemplate() {
    if (!userId || !tName.trim()) return;
    setError(null);
    const { error: e } = await sb.from("templates").insert({
      owner_id: userId,
      name: tName.trim(),
      default_roster_size: Math.min(Math.max(Number(tRoster) || 5, 1), 30),
      default_bankroll_cents: parseDollarsToCents(tBankroll) ?? 2000,
      default_min_bid_cents: parseDollarsToCents(tMinBid) ?? 100,
      default_timer_seconds: tTimer,
      default_gives_per_player: 2,
    });
    if (e) {
      setError(e.message);
      return;
    }
    setTName("");
    await loadTemplates();
  }

  async function removeTemplate(id: string) {
    await sb.from("templates").delete().eq("id", id);
    await loadTemplates();
  }

  if (!ready) {
    return (
      <>
        <Header thin />
        <main className="mx-auto w-full max-w-xl px-4 py-14">
          <h1 className="type-display text-[1.75rem]">Host settings</h1>
          <p className="type-label mt-2 text-muted">loading</p>
        </main>
      </>
    );
  }

  if (!userId) {
    return (
      <>
        <Header thin />
        <main className="mx-auto w-full max-w-xl px-4 py-14">
          <h1 className="type-display text-[1.75rem]">Host settings</h1>
          <p className="mt-2 text-[0.9375rem] text-muted">
            You need to be signed in to save templates and branding.
          </p>
          <Link href="/login" className="btn btn-primary mt-5 h-12 px-5 text-[0.875rem]">
            Sign in
          </Link>
        </main>
        <Footer />
      </>
    );
  }

  return (
    <>
      <Header thin />
      <main className="mx-auto w-full max-w-xl px-4 py-10">
        <h1 className="type-display text-[1.75rem]">Host settings</h1>
        <p className="type-num mt-1 text-[0.8125rem] text-muted">{email}</p>

        {pending.length > 0 ? (
          <section className="mt-9">
            <h2 className="type-display text-[1rem]">Setup links waiting</h2>
            <p className="mt-1 text-[0.875rem] text-muted">
              Send one of these to whoever is building the list. Each works once and expires 24
              hours after it was made.
            </p>
            <ul className="mt-3 flex flex-col">
              {pending.map((p) => (
                <li key={p.setup_token} className="flex items-center gap-3 border-b py-3 rule">
                  <span className="min-w-0 flex-1 truncate font-mono text-[0.75rem] text-muted">
                    /setup/{p.setup_token}
                  </span>
                  <Button
                    variant="quiet"
                    size="sm"
                    onClick={() =>
                      void navigator.clipboard
                        .writeText(`${window.location.origin}/setup/${p.setup_token}`)
                        .catch(() => undefined)
                    }
                  >
                    Copy
                  </Button>
                </li>
              ))}
            </ul>
          </section>
        ) : null}

        <section className="mt-9">
          <h2 className="type-display text-[1rem]">Password</h2>
          <p className="mt-1 text-[0.875rem] leading-relaxed text-muted">
            Set one and you can sign in without waiting for an email. If you first signed up
            through an email link, you don&apos;t have a password yet.
          </p>
          <div className="mt-3 flex flex-col gap-2 sm:flex-row">
            <TextInput
              type="password"
              value={newPassword}
              autoComplete="new-password"
              placeholder="At least 10 characters"
              onChange={(e) => setNewPassword(e.target.value)}
            />
            <Button
              variant="ghost"
              className="shrink-0"
              disabled={newPassword.length === 0}
              onClick={() => void setPassword()}
            >
              Set password
            </Button>
          </div>
          {pwMsg ? <p className="mt-2 text-[0.8125rem] text-teal">{pwMsg}</p> : null}
        </section>

        <section className="mt-9">
          <h2 className="type-display text-[1rem]">Card branding</h2>
          <p className="mt-1 text-[0.875rem] text-muted">
            Applied to every room you create while signed in.
          </p>
          <div className="mt-4 flex flex-col gap-4">
            <Field label="default host name" htmlFor="dn">
              <TextInput
                id="dn"
                value={displayName}
                maxLength={24}
                onChange={(e) => setDisplayName(e.target.value)}
              />
            </Field>
            <div className="grid gap-4 sm:grid-cols-2">
              <Field label="accent colour" hint="Hex, e.g. #F5B942">
                <TextInput
                  value={accent}
                  className="type-num"
                  placeholder="#F5B942"
                  onChange={(e) => setAccent(e.target.value)}
                />
              </Field>
              <Field
                label="logo"
                hint="PNG, JPEG or WebP. 512KB max. SVG is not accepted because it can carry script and this file gets rendered onto other people's cards."
              >
                <div className="flex items-center gap-3">
                  {logo ? (
                    // eslint-disable-next-line @next/next/no-img-element
                    <img
                      src={logo}
                      alt="Your current card logo"
                      className="h-10 w-auto max-w-[7rem] object-contain"
                    />
                  ) : null}
                  <input
                    type="file"
                    accept="image/png,image/jpeg,image/webp"
                    disabled={uploading}
                    onChange={(e) => void uploadLogo(e.target.files?.[0])}
                    className="text-[0.8125rem] text-muted file:mr-3 file:cursor-pointer file:rounded-[3px] file:border file:border-solid file:border-[color-mix(in_oklab,var(--color-muted)_45%,transparent)] file:bg-transparent file:px-3 file:py-1.5 file:text-ink"
                  />
                  {logo ? (
                    <Button variant="quiet" size="sm" onClick={() => setLogo("")}>
                      Clear
                    </Button>
                  ) : null}
                </div>
              </Field>
            </div>
            <div className="flex items-center gap-3">
              <Button variant="primary" onClick={() => void saveProfile()}>
                Save branding
              </Button>
              {savedProfile ? <span className="type-label text-gold">saved</span> : null}
            </div>
          </div>
        </section>

        <section className="mt-11">
          <h2 className="type-display text-[1rem]">Category templates</h2>
          <ul className="mt-3 flex flex-col">
            {templates.length === 0 ? (
              <li className="type-label border-b py-3 text-muted rule">nothing saved yet</li>
            ) : null}
            {templates.map((t) => (
              <li key={t.id} className="flex items-baseline gap-3 border-b py-3 rule">
                <span className="type-display text-[0.875rem]">{t.name}</span>
                <span className="min-w-0 flex-1 truncate text-[0.8125rem] text-muted">
                  {t.default_roster_size} players
                </span>
                <span className="type-num shrink-0 text-[0.75rem] text-muted">
                  ${centsToInput(t.default_bankroll_cents)} / {t.default_timer_seconds}s
                </span>
                <Button
                  variant="quiet"
                  size="sm"
                  aria-label={`Delete ${t.name}`}
                  onClick={() => void removeTemplate(t.id)}
                >
                  &times;
                </Button>
              </li>
            ))}
          </ul>

          <div className="mt-5 flex flex-col gap-4">
            <Field label="template name" htmlFor="tn">
              <TextInput
                id="tn"
                value={tName}
                maxLength={40}
                placeholder="Sunday league"
                onChange={(e) => setTName(e.target.value)}
              />
            </Field>
            <Field label="players per team" hint="1 to 30">
              <TextInput value={tRoster} inputMode="numeric" className="type-num"
                onChange={(e) => setTRoster(e.target.value)} />
            </Field>
            <div className="grid grid-cols-3 gap-3">
              <Field label="bankroll">
                <TextInput
                  value={tBankroll}
                  inputMode="decimal"
                  className="type-num"
                  onChange={(e) => setTBankroll(e.target.value)}
                />
              </Field>
              <Field label="min bid">
                <TextInput
                  value={tMinBid}
                  inputMode="decimal"
                  className="type-num"
                  onChange={(e) => setTMinBid(e.target.value)}
                />
              </Field>
              <Field label="clock">
                <TextInput
                  value={String(tTimer)}
                  inputMode="numeric"
                  className="type-num"
                  onChange={(e) => setTTimer(Number(e.target.value) || 15)}
                />
              </Field>
            </div>
            <Button variant="ghost" disabled={!tName.trim()} onClick={() => void addTemplate()}>
              Save template
            </Button>
          </div>
        </section>

        {error ? <p className="mt-5 text-[0.875rem] text-coral">{error}</p> : null}

        <div className="mt-10 flex gap-2">
          <Link href="/new" className="btn btn-primary h-12 px-5 text-[0.875rem]">
            Start a room
          </Link>
          <Button
            variant="quiet"
            className="h-12 px-5 text-[0.875rem]"
            onClick={() =>
              void sb.auth.signOut().then(() => {
                router.push("/");
                router.refresh();
              })
            }
          >
            Sign out
          </Button>
        </div>
      </main>
      <Footer />
    </>
  );
}
