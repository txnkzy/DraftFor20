"use client";

import { useCallback, useEffect, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Field, TextInput } from "@/components/ui/Field";
import { Padlock } from "@/components/premium/Padlock";
import { UpgradeCard } from "@/components/premium/UpgradeCard";
import { ShareCard } from "./ShareCard";
import { uploadBrandLogo } from "@/lib/brand";
import { useHost } from "@/lib/auth";
import { usePremium, type ExportStyle } from "@/lib/premium";
import type { CardModel } from "@/lib/results/cardModel";
import { supabaseBrowser } from "@/lib/supabase/client";

const WATERMARKED: ExportStyle = { watermark: true, logo_url: null, accent: null, handle: null };

/**
 * The export card, its download, and the customisation behind it.
 *
 * THE WATERMARK IS OPT-OUT, NOT OPT-IN. `style` here is not what the signed-in
 * user would like — it is what df20_export_style() says this specific room's
 * card looks like, which is the same answer the PNG route gets. A premium
 * account that has never touched these controls sees, and downloads, exactly
 * the card a free account does.
 */
export function ExportPanel({
  code,
  model,
  hostProfileId,
}: {
  code: string;
  model: CardModel;
  hostProfileId: string | null;
}) {
  const premium = usePremium();
  const { user } = useHost();
  const [style, setStyle] = useState<ExportStyle>(WATERMARKED);
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState<string | null>(null);

  /* Draft values for the form. Null until the host touches something, so the
     saved preference can arrive late without an effect fighting it — and so
     the form never briefly claims the watermark is off before the server has
     said anything. */
  const [draft, setDraft] = useState<Partial<ExportStyle> | null>(null);
  const saved0 = premium.exportStyle;
  const watermark = draft?.watermark ?? saved0.watermark;
  const accent = draft?.accent ?? saved0.accent ?? "";
  const handle = draft?.handle ?? saved0.handle ?? "";
  const logo = draft?.logo_url ?? saved0.logo_url ?? "";
  const edit = (patch: Partial<ExportStyle>) =>
    setDraft((d) => ({ watermark, accent, handle, logo_url: logo, ...d, ...patch }));

  const readStyle = useCallback(async (): Promise<ExportStyle> => {
    const { data } = await supabaseBrowser().rpc("df20_export_style", { p_code: code });
    const d = (data ?? {}) as Partial<ExportStyle>;
    return {
      // absent, null, an error, anything at all: the card is watermarked
      watermark: d.watermark !== false,
      logo_url: d.logo_url ?? null,
      accent: d.accent ?? null,
      handle: d.handle ?? null,
    };
  }, [code]);

  const loadStyle = useCallback(async () => {
    setStyle(await readStyle());
  }, [readStyle]);

  useEffect(() => {
    let off = false;
    void (async () => {
      const s = await readStyle();
      if (!off) setStyle(s);
    })();
    return () => {
      off = true;
    };
  }, [readStyle]);

  const isRoomHost = Boolean(user && hostProfileId && user.id === hostProfileId);

  async function save() {
    setBusy(true);
    setError(null);
    const { error: e } = await supabaseBrowser().rpc("save_export_style", {
      p_watermark: watermark,
      p_logo_url: logo || null,
      p_accent: accent || null,
      p_handle: handle || null,
    });
    setBusy(false);
    if (e) {
      setError(e.message);
      return;
    }
    setSaved(true);
    setTimeout(() => setSaved(false), 1800);
    await Promise.all([loadStyle(), premium.refresh()]);
  }

  async function pickLogo(file?: File) {
    if (!file || !user) return;
    setError(null);
    setBusy(true);
    const { url, error: e } = await uploadBrandLogo(supabaseBrowser(), user.id, file);
    setBusy(false);
    if (e) {
      setError(e);
      return;
    }
    if (url) edit({ logo_url: url });
  }

  const locked = !premium.active;

  return (
    <section className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center gap-2">
        {/* a real file, not a right-click-and-hope: the route answers with
            image/png bytes and Content-Disposition: attachment */}
        <a
          className="btn btn-primary h-11 px-4 text-[0.8125rem]"
          href={`/api/share-card/${code}?dl=1`}
          download={`draftfor20-${code}.png`}
        >
          Download the PNG
        </a>
        <a
          className="btn btn-ghost h-11 px-4 text-[0.8125rem]"
          href={`/api/share-card/${code}`}
          target="_blank"
          rel="noreferrer"
        >
          Open full size
        </a>
        <Button variant="quiet" onClick={() => setOpen((v) => !v)}>
          <Padlock size={12} open={premium.active} />
          {open ? "Hide card options" : "Card options"}
        </Button>
      </div>

      <p className="type-label text-muted">
        1080 &times; 1920 png &middot;{" "}
        {style.watermark ? "watermarked" : "your branding"}
      </p>

      {open ? (
        <div className="border p-4 rule">
          <h3 className="type-display flex items-center gap-2 text-[1rem]">
            {locked ? <Padlock size={13} /> : null}
            Card branding
          </h3>
          <p className="mt-1.5 text-[0.875rem] leading-relaxed text-muted">
            The DraftFor20 watermark is on by default on every card, premium included. Turning it
            off is a choice you make here; nothing does it for you.
          </p>
          {locked && (saved0.watermark === false || saved0.handle || saved0.logo_url) ? (
            // they had premium once and set these. Say plainly that the
            // settings are kept and simply not in force, rather than letting
            // a switch that reads "off" sit above a card that is watermarked.
            <p className="mt-2 text-[0.875rem] leading-relaxed text-teal">
              These are still your settings. They apply again the moment premium is active;
              until then every card you export is the standard watermarked one.
            </p>
          ) : null}

          <div
            className="mt-4 flex flex-col gap-4"
            style={locked ? { opacity: 0.5, pointerEvents: "none" } : undefined}
            aria-disabled={locked}
          >
            <label className="flex items-start gap-3">
              <input
                type="checkbox"
                checked={watermark}
                onChange={(e) => edit({ watermark: e.target.checked })}
                className="mt-1"
              />
              <span>
                <span className="type-label">show the DraftFor20 watermark</span>
                <span className="mt-1 block text-[0.8125rem] leading-snug text-muted">
                  Leave this on and your card is identical to everyone else&apos;s. Every card
                  that gets posted is how the next two people find this.
                </span>
              </span>
            </label>

            <div className="grid gap-4 sm:grid-cols-2">
              <Field label="accent colour" hint="Hex, e.g. #F5B942">
                <TextInput
                  value={accent}
                  className="type-num"
                  placeholder="#F5B942"
                  onChange={(e) => edit({ accent: e.target.value })}
                />
              </Field>
              <Field label="social handle" hint="Printed on the card, e.g. @yourshow">
                <TextInput
                  value={handle}
                  maxLength={32}
                  placeholder="@yourshow"
                  onChange={(e) => edit({ handle: e.target.value })}
                />
              </Field>
            </div>

            <Field
              label="your logo"
              hint="PNG, JPEG or WebP. 512KB max. Same upload as your host branding."
            >
              <div className="flex items-center gap-3">
                {logo ? (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img src={logo} alt="Your card logo" className="h-10 w-auto max-w-[7rem] object-contain" />
                ) : null}
                <input
                  type="file"
                  accept="image/png,image/jpeg,image/webp"
                  disabled={busy}
                  onChange={(e) => void pickLogo(e.target.files?.[0])}
                  className="text-[0.8125rem] text-muted file:mr-3 file:cursor-pointer file:rounded-[3px] file:border file:border-solid file:border-[color-mix(in_oklab,var(--color-muted)_45%,transparent)] file:bg-transparent file:px-3 file:py-1.5 file:text-ink"
                />
                {logo ? (
                  <Button variant="quiet" size="sm" onClick={() => edit({ logo_url: "" })}>
                    Clear
                  </Button>
                ) : null}
              </div>
            </Field>

            <div className="flex items-center gap-3">
              <Button variant="primary" disabled={busy} onClick={() => void save()}>
                Save card branding
              </Button>
              {saved ? <span className="type-label text-teal">saved</span> : null}
            </div>
          </div>

          {locked ? (
            <UpgradeCard feature="card branding" signedIn={premium.signedIn} />
          ) : null}

          {error ? <p className="mt-3 text-[0.8125rem] text-coral">{error}</p> : null}
        </div>
      ) : null}

      {isRoomHost ? <SaveDeck code={code} name={model.title} /> : null}

      <div>
        <p className="type-label mb-2 text-muted">
          9:16 &middot; this is exactly what the download looks like
        </p>
        <div className="mx-auto max-w-[420px]">
          <ShareCard model={model} style={style} />
        </div>
      </div>
    </section>
  );
}

/** Keep the pool this room used, so the next room can be dealt from it. */
function SaveDeck({ code, name }: { code: string; name: string }) {
  const [state, setState] = useState<"idle" | "busy" | "done" | "error">("idle");
  const [message, setMessage] = useState<string | null>(null);

  async function save() {
    setState("busy");
    const { data, error } = await supabaseBrowser().rpc("save_room_deck", {
      p_code: code,
      p_name: name,
    });
    if (error) {
      setState("error");
      setMessage(error.message);
      return;
    }
    const d = data as { item_count: number };
    setState("done");
    setMessage(`Saved. ${d.item_count} items, ready to deal again.`);
  }

  return (
    <div className="flex flex-wrap items-center gap-3 border-y py-3 rule">
      <span className="text-[0.875rem] text-muted">
        Keep this category on your profile and start another room from it any time.
      </span>
      <Button
        variant="ghost"
        size="sm"
        className="ml-auto"
        disabled={state === "busy" || state === "done"}
        onClick={() => void save()}
      >
        {state === "done" ? "Saved to your decks" : "Save this deck"}
      </Button>
      {message ? (
        <p className={`w-full text-[0.8125rem] ${state === "error" ? "text-coral" : "text-teal"}`}>
          {message}
        </p>
      ) : null}
    </div>
  );
}
