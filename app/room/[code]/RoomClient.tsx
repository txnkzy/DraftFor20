"use client";

import Link from "next/link";
import { useCallback, useEffect, useRef, useState } from "react";
import { ActionBar } from "@/components/board/ActionBar";
import { BidBoard } from "@/components/board/BidBoard";
import { LotHistory } from "@/components/board/LotHistory";
import { OfferCard } from "@/components/board/OfferCard";
import { PlayerStrip } from "@/components/board/PlayerStrip";
import { RosterColumn } from "@/components/board/RosterColumn";
import { LeaveRoom } from "@/components/board/LeaveRoom";
import { ResultsBoard } from "@/components/results/ResultsBoard";
import { ContentPanel } from "@/components/content/ContentPanel";
import { CreatorBoard } from "@/components/content/CreatorBoard";
import { HotSeatBar } from "@/components/content/HotSeatBar";
import { RecordSurface } from "@/components/content/RecordSurface";
import { Button } from "@/components/ui/Button";
import { TextInput } from "@/components/ui/Field";
import { SetupNotice } from "@/components/site/Chrome";
import { isMoneyWall, readableError } from "@/lib/game/errors";
import { saveSeat, setActiveSeat, useSeat, useSeats, type Seat } from "@/lib/game/session";
import { rosterOf, type RoomState } from "@/lib/game/types";
import { givesAreUnlimited } from "@/lib/game/rules";
import { useCountdown, useRoom } from "@/lib/game/useRoom";
import { buildBoardView, seatAccent } from "@/lib/game/view";
import { formatCents } from "@/lib/money";
import { armAudio, cueLock, cueRaise, setMuted, useAudioReady, useMuted } from "@/lib/sound";
import { usePremium } from "@/lib/premium";
import { supabaseBrowser, supabaseConfigured } from "@/lib/supabase/client";

/** how long the resolve beat holds before the next card is shown */
const LOCK_BEAT_MS = 2200;

export function RoomClient({ code }: { code: string }) {
  if (!supabaseConfigured()) return <SetupNotice />;
  return <RoomLive code={code} />;
}

function RoomLive({ code }: { code: string }) {
  const seat = useSeat(code);
  /* Two seats on one device is pass-and-play. Everything below keys off the
     count, so a normal two-device room takes none of these branches. */
  const seats = useSeats(code);
  const hotSeat = seats.length > 1;
  const {
    state, error, rawError, errorNonce, clearError,
    pending, loaded, serverNow, actions, refresh,
  } = useRoom(code, seat);
  const cd = useCountdown(state?.lot?.turn_expires_at, serverNow, state?.room.timer_seconds ?? 15);
  const premium = usePremium();
  const [recording, setRecording] = useState(false);

  useEffect(() => {
    if (!error) return;
    const t = setTimeout(clearError, 4200);
    return () => clearTimeout(t);
  }, [error, clearError]);

  const wallKey = isMoneyWall(rawError) ? errorNonce : 0;

  /* raise cue: fires when the standing bid actually moves */
  const bid = state?.lot?.current_bid_cents ?? 0;
  const lotId = state?.lot?.id ?? null;
  const [raiseKey, setRaiseKey] = useState(0);
  const lastBid = useRef<{ lot: string | null; cents: number }>({ lot: null, cents: 0 });
  useEffect(() => {
    const prev = lastBid.current;
    if (prev.lot === lotId && bid > prev.cents) {
      setRaiseKey((n) => n + 1);
      cueRaise();
    }
    lastBid.current = { lot: lotId, cents: bid };
  }, [bid, lotId]);

  /* THE LOCK beat, derived from the resolve timestamp */
  const resolvedAt = state?.lot?.status === "resolved" ? state.lot.resolved_at : null;
  const [, endBeat] = useState(0);
  useEffect(() => {
    if (!resolvedAt) return;
    cueLock();
    const remaining = LOCK_BEAT_MS - (serverNow() - Date.parse(resolvedAt));
    if (remaining <= 0) return;
    const t = setTimeout(() => endBeat((n) => n + 1), remaining);
    return () => clearTimeout(t);
  }, [resolvedAt, serverNow]);
  const lockActive = Boolean(resolvedAt) && serverNow() - Date.parse(resolvedAt!) < LOCK_BEAT_MS;

  /* the roster row the won card belongs to, so it can be seen to LAND there
     rather than simply being present on the next repaint. Derived from the
     same resolve beat the board already runs on rather than held in state:
     one clock, one truth, and nothing to leave behind. */
  const landed =
    lockActive && state
      ? ([...state.roster].sort((a, b) => b.won_at.localeCompare(a.won_at))[0]?.id ?? null)
      : null;

  /* record mode is a layout state; fullscreen is requested alongside it and
     leaving fullscreen by any route (esc, the browser chrome) leaves the mode */
  useEffect(() => {
    if (!recording) return;
    void document.documentElement.requestFullscreen?.().catch(() => undefined);
    const sync = () => {
      if (!document.fullscreenElement) setRecording(false);
    };
    document.addEventListener("fullscreenchange", sync);
    return () => {
      document.removeEventListener("fullscreenchange", sync);
      if (document.fullscreenElement) void document.exitFullscreen?.().catch(() => undefined);
    };
  }, [recording]);

  /* PASS AND PLAY. Whoever the server says has to act next gets the controls,
     the instant the clock moves, without anyone tapping anything. Two people
     filming on one camera should not also be administering a handoff.

     This only ever selects between tokens this device already holds, and only
     ever a player the server itself has put on the clock — so it changes which
     of our own tokens is sent, and nothing about what the server will accept. */
  const controllerId =
    state?.room.status === "lobby"
      ? /* the host is the one who can start it, and seating the second player
           on this device would otherwise leave the Start button belonging to
           a token we are no longer holding */
        (state.players.find((p) => p.is_host)?.id ?? null)
      : state?.room.phase === "offering"
        ? (state.lot?.opener_player_id ?? null)
        : state?.room.phase === "bidding"
          ? (state.lot?.on_the_clock_player_id ?? null)
          : null;
  /* Hand over ONCE per turn, not on every render. Re-asserting continuously
     would silently undo the switcher below a frame after it was tapped, which
     is worse than not having it: the button would look live and do nothing.
     Keyed on the turn, so an override holds for as long as that turn lasts and
     the next one still hands off on its own. */
  const handoffKey = `${state?.lot?.id ?? "lobby"}:${state?.lot?.turn_seq ?? 0}:${controllerId ?? ""}`;
  const handedOff = useRef<string | null>(null);
  useEffect(() => {
    if (!hotSeat || !controllerId) return;
    if (handedOff.current === handoffKey) return;
    handedOff.current = handoffKey;
    if (!seats.some((s) => s.playerId === controllerId)) return;
    setActiveSeat(code, controllerId);
  }, [hotSeat, controllerId, handoffKey, seats, code]);

  const muted = useMuted();
  const audioReady = useAudioReady();
  // cues fire from network events, which are not user gestures, so the
  // context has to be unlocked by the first real interaction on the page
  useEffect(() => armAudio(), []);

  const onSeated = useCallback((s: Seat) => saveSeat(s), []);

  if (!loaded) {
    return (
      <main className="grid min-h-dvh place-items-center px-4">
        <h1 className="type-label text-muted">Loading the board</h1>
      </main>
    );
  }

  if (!state) {
    return (
      <main className="mx-auto grid min-h-dvh w-full max-w-md place-items-center px-4 text-center">
        <div>
          <h1 className="type-display text-[1.75rem]">No room {code}</h1>
          <p className="mt-2 text-[0.9375rem] text-muted">
            That code doesn&apos;t match a room. Check it and try again.
          </p>
          <Link href="/join" className="btn btn-primary mt-5 h-11 px-4 text-[0.8125rem]">
            Enter a code
          </Link>
        </div>
      </main>
    );
  }

  const me = state.players.find((p) => p.id === seat?.playerId) ?? null;

  /* Host-ness follows the DEVICE, not the seat currently holding the controls.
     In pass-and-play the controls move to the other player every turn, and
     tying the content tools to the active seat took record mode and the OBS
     link off the screen mid-draft — on the one setup where somebody is
     certainly filming. The host's own token is what those calls are made with,
     whoever happens to be bidding. */
  const hostSeat =
    seats.find((s) => state.players.find((p) => p.id === s.playerId)?.is_host) ?? null;
  const isHost = Boolean(hostSeat) || Boolean(me?.is_host);
  const hostToken = hostSeat?.sessionToken ?? (me?.is_host ? (seat?.sessionToken ?? null) : null);
  const creator = state.room.content_mode === "creator";

  const opponentName =
    (me ? state.players.find((p) => p.id !== me.id) : null)?.display_name ?? null;

  /* The OFFER of a second seat is a Content Creator thing. The bar itself is
     shown whenever this device actually holds two, creator room or not — a
     device that has them and cannot see them is a device stuck on one. */
  const hotSeatBar = hotSeat ? (
    <HotSeatBar
      state={state}
      seats={seats}
      activePlayerId={seat?.playerId ?? null}
      autoSwitching={Boolean(controllerId)}
      onSwitch={(id) => setActiveSeat(code, id)}
    />
  ) : null;

  /** one <LeaveRoom>, wired the same way wherever it is rendered */
  const leaveButton = (
    <LeaveRoom
      seated={Boolean(me)}
      live={state.room.status === "lobby" || state.room.status === "live"}
      opponent={opponentName}
      onLeave={actions.leave}
    />
  );

  if (state.room.status === "abandoned") {
    const who = state.players.find((p) => p.id === state.room.abandoned_by);
    const iLeft = Boolean(me && who && me.id === who.id);
    return (
      <main className="mx-auto w-full max-w-3xl px-4 py-10">
        <div className="border p-5 rule" style={{ borderColor: "var(--color-teal)" }}>
          <p className="type-label text-teal">room closed</p>
          <h1 className="type-display mt-1 text-[1.75rem]">
            {iLeft
              ? "You left this draft"
              : who
                ? `${who.display_name} left the draft`
                : "This draft was abandoned"}
          </h1>
          <p className="mt-2 text-[0.9375rem] leading-relaxed text-muted">
            Nobody is on the clock any more and this code has stopped working. There is no
            winner — a draft that did not finish is not a result.
          </p>
          <div className="mt-5 flex flex-wrap gap-2">
            <Link href="/new" className="btn btn-primary h-12 px-5 text-[0.875rem]">
              Start another room
            </Link>
            <Link href="/" className="btn btn-ghost h-12 px-5 text-[0.875rem]">
              Home
            </Link>
          </div>
        </div>

        {/* where it got to, because people want to see the picks they paid for */}
        <p className="type-label mt-8 text-muted">where it stood</p>
        <div className="mt-2 grid grid-cols-2 gap-4 sm:gap-8">
          {state.players.map((p) => (
            <RosterColumn
              key={p.id}
              seat={p.seat}
              name={p.display_name}
              rosterSize={state.room.roster_size}
              roster={rosterOf(state, p.id)}
            />
          ))}
        </div>
      </main>
    );
  }

  if (state.room.status === "lobby") {
    return (
      <Lobby state={state} me={me} code={code} onSeated={onSeated}
             start={actions.start} pending={pending} error={error} refresh={refresh}
             leaveButton={leaveButton} offerHotSeat={creator} hotSeatBar={hotSeatBar}>
        {/* The old Content tab only existed once a draft had started, which
            is the one moment a streamer does not need it. Waiting for the
            second player is exactly when you set up the scene. */}
        {creator && isHost ? (
          <div className="border-t pt-6 rule">
            <ContentPanel
              code={code}
              state={state}
              sessionToken={hostToken}
              premium={premium}
              onRecordMode={() => setRecording(true)}
            />
          </div>
        ) : null}
      </Lobby>
    );
  }

  if (state.room.status === "complete") {
    // record mode still works on a finished board: the final rosters with
    // nothing else on screen is the shot most people actually want
    if (recording) {
      return (
        <RecordSurface
          state={state}
          view={buildBoardView(state, cd)}
          landedEntryId={null}
          onExit={() => setRecording(false)}
        />
      );
    }

    // The content tools survive the final whistle on purpose: the minutes
    // right after a draft ends are exactly when the host is watching the
    // audience vote come in.
    return (
      <main className="mx-auto w-full max-w-3xl px-4 py-6">
        {/* no hot-seat switcher here any more: with the players' vote gone,
            nothing on this screen belongs to one seat rather than the device */}
        <ResultsBoard state={state} sessionToken={seat?.sessionToken ?? null} />
        {creator && isHost ? (
          <div className="mt-10 border-t pt-6 rule">
            <ContentPanel
              code={code}
              state={state}
              sessionToken={hostToken}
              premium={premium}
              onRecordMode={() => setRecording(true)}
            />
          </div>
        ) : null}
      </main>
    );
  }

  const view = buildBoardView(state, cd);
  const p1 = view.players.find((p) => p.seat === 1)!;
  const p2 = view.players.find((p) => p.seat === 2)!;
  const unlimitedGives = givesAreUnlimited(
    state.room.gives_per_player,
    state.room.roster_size,
  );
  const offering = state.room.phase === "offering";
  const bidding = state.room.phase === "bidding";
  const lock = lockActive ? view.lastLock : null;

  const opponent = me ? state.players.find((p) => p.id !== me.id) ?? null : null;
  const opener = state.players.find((p) => p.id === state.lot?.opener_player_id) ?? null;
  const onClock = state.players.find((p) => p.id === state.lot?.on_the_clock_player_id) ?? null;

  const iAmOpener = Boolean(me && state.lot?.opener_player_id === me.id);
  const iAmOnClock = Boolean(me && state.lot?.on_the_clock_player_id === me.id);
  const canTake =
    Boolean(me) && me!.open_slots > 0 && me!.max_legal_bid_cents >= state.room.min_bid_cents;
  const canGive = Boolean(opponent) && opponent!.open_slots > 0 && (me?.gives_left ?? 0) > 0;
  /* Short of the minimum with slots still owed. Mirrors offer_decide's own
     v_can_force exactly: it is the complement of canTake, never an extra
     door. Without it a broke opener out of gives had nothing to press but
     "Let it go", every card, until the deck emptied and the results card
     called them disqualified. */
  const canForce = Boolean(me) && me!.open_slots > 0 && !canTake;

  function actionArea() {
    if (lock) return null;
    if (!me) return <p className="type-label text-center text-muted">you&apos;re watching this room</p>;

    if (offering && iAmOpener)
      return (
        <OfferCard
          minBidCents={state!.room.min_bid_cents}
          canTake={canTake}
          canGive={canGive}
          canForce={canForce}
          givesLeft={me.gives_left}
          givesUnlimited={unlimitedGives}
          opponentName={opponent?.display_name ?? "them"}
          pending={pending}
          onDecide={(choice) => void actions.offerDecide(choice)}
        />
      );

    if (offering)
      return (
        <p className="type-label text-center text-muted">
          {opener?.display_name} decides whether to take them
        </p>
      );

    if (bidding && iAmOnClock)
      return (
        <ActionBar
          key={`${state!.lot!.id}:${state!.lot!.turn_seq}`}
          currentBidCents={state!.lot!.current_bid_cents}
          minBidCents={state!.room.min_bid_cents}
          maxLegalBidCents={me.max_legal_bid_cents}
          pending={pending}
          onRaise={(c) => void actions.placeBid(c)}
          onPass={() => void actions.pass()}
        />
      );

    if (bidding)
      return (
        <p className="type-label text-center text-muted">
          {state!.lot?.high_bidder_player_id === me.id
            ? `you're high at ${formatCents(state!.lot!.current_bid_cents)} · ${onClock?.display_name} is up`
            : `${onClock?.display_name} is up`}
        </p>
      );

    return null;
  }

  if (recording) {
    return (
      <RecordSurface
        state={state}
        view={view}
        landedEntryId={landed}
        onExit={() => setRecording(false)}
      >
        {actionArea()}
      </RecordSurface>
    );
  }

  if (creator) {
    return (
      <CreatorBoard
        state={state}
        view={view}
        landedEntryId={landed}
        code={code}
        sessionToken={hostToken}
        isHost={isHost}
        premium={premium}
        onRecordMode={() => setRecording(true)}
        leaveButton={leaveButton}
      >
        {error ? (
          <p className="anim-reject mb-3 border border-coral bg-coral/15 px-3 py-2 text-center text-[0.8125rem] text-ink">
            {error}
          </p>
        ) : null}
        {actionArea()}
        {hotSeatBar ? <div className="mt-3">{hotSeatBar}</div> : null}
      </CreatorBoard>
    );
  }

  return (
    <main className="mx-auto flex min-h-dvh w-full max-w-lg flex-col lg:max-w-6xl">
      <div className="sticky top-0 z-20 border-b bg-board px-4 rule">
        <div className="flex items-baseline justify-between gap-3 pt-3">
          <div className="flex min-w-0 items-baseline gap-3">
            {leaveButton}
            <h1 className="type-display truncate text-[0.875rem]">{state.room.title}</h1>
          </div>
          <div className="flex shrink-0 items-baseline gap-3">
            <button
              className="type-label text-muted hover:text-ink"
              aria-pressed={muted}
              onClick={() => setMuted(!muted)}
            >
              {/* if the browser still has audio locked, say so rather than
                  claiming "sound on" and playing nothing */}
              {muted ? "sound off" : audioReady ? "sound on" : "tap to enable sound"}
            </button>
            <CopyCode code={code} />
          </div>
        </div>
        <PlayerStrip
          p={p1} startingCents={state.room.starting_bankroll_cents}
          markerCents={bidding || offering ? state.lot!.current_bid_cents : null}
          isYou={me?.seat === 1} onClock={view.onClockSeat === 1 || view.openerSeat === 1}
          isHigh={bidding && view.highBidderSeat === 1}
          flashKey={me?.seat === 1 ? wallKey : 0} givesLeft={p1.givesLeft}
          givesUnlimited={unlimitedGives}
        />
        <div className="h-px w-full border-t rule" />
        <PlayerStrip
          p={p2} startingCents={state.room.starting_bankroll_cents}
          markerCents={bidding || offering ? state.lot!.current_bid_cents : null}
          isYou={me?.seat === 2} onClock={view.onClockSeat === 2 || view.openerSeat === 2}
          isHigh={bidding && view.highBidderSeat === 2}
          flashKey={me?.seat === 2 ? wallKey : 0} givesLeft={p2.givesLeft}
          givesUnlimited={unlimitedGives}
        />

      </div>

      {error ? (
        <p className="anim-reject border-b border-coral bg-coral/15 px-4 py-2 text-center text-[0.8125rem] text-ink">
          {error}
        </p>
      ) : null}

      <div className="flex flex-1 flex-col gap-5 px-4 py-4 lg:grid lg:grid-cols-[minmax(0,1fr)_minmax(0,1.5fr)_minmax(0,1fr)] lg:items-start lg:gap-6">
        <section className="order-1 flex flex-col gap-3 lg:order-2">
          <BidBoard view={view} lock={lock} raiseKey={raiseKey}>
            {actionArea()}
          </BidBoard>
          {hotSeatBar}
          <LotHistory events={state.events} players={state.players} lotId={state.lot?.id ?? null} />
        </section>

        <section className="order-2 grid grid-cols-2 gap-4 lg:hidden">
          <RosterColumn seat={1} name={p1.name} rosterSize={state.room.roster_size}
                        roster={rosterOf(state, p1.id)} lockedEntryId={landed} />
          <RosterColumn seat={2} name={p2.name} rosterSize={state.room.roster_size}
                        roster={rosterOf(state, p2.id)} lockedEntryId={landed} />
        </section>
        <section className="hidden lg:order-1 lg:block">
          <RosterColumn seat={1} name={p1.name} rosterSize={state.room.roster_size}
                        roster={rosterOf(state, p1.id)} lockedEntryId={landed} />
        </section>
        <section className="hidden lg:order-3 lg:block">
          <RosterColumn seat={2} name={p2.name} rosterSize={state.room.roster_size}
                        roster={rosterOf(state, p2.id)} lockedEntryId={landed} />
        </section>
      </div>
    </main>
  );
}

/* ── lobby ─────────────────────────────────────────────────────────────── */

function Lobby({
  state, me, code, onSeated, start, pending, error, refresh, children, leaveButton,
  offerHotSeat = false, hotSeatBar,
}: {
  state: RoomState;
  me: { id: string; is_host: boolean } | null;
  code: string;
  onSeated: (s: Seat) => void;
  start: () => void;
  pending: boolean;
  error: string | null;
  refresh: () => void;
  children?: React.ReactNode;
  leaveButton?: React.ReactNode;
  /** Content Creator rooms let the second player sit down on this computer */
  offerHotSeat?: boolean;
  hotSeatBar?: React.ReactNode;
}) {
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [joinError, setJoinError] = useState<string | null>(null);
  const full = state.players.length >= 2;

  async function join() {
    if (!name.trim()) return;
    setBusy(true);
    setJoinError(null);
    const { data, error: e } = await supabaseBrowser().rpc("join_room", {
      p_code: code, p_display_name: name.trim(),
    });
    setBusy(false);
    if (e) { setJoinError(readableError(e.message)); return; }
    const d = data as { room_id: string; code: string; player_id: string; session_token: string; seat: number };
    onSeated({ roomId: d.room_id, code: d.code, playerId: d.player_id, sessionToken: d.session_token, seat: d.seat });
    setName("");
    refresh();
  }

  return (
    <main className="mx-auto flex min-h-dvh w-full max-w-md flex-col justify-center gap-6 px-4 py-10">
      <div>
        {leaveButton ? <div className="mb-4">{leaveButton}</div> : null}
        <p className="type-label text-muted">room code</p>
        <div className="mt-1 flex items-center gap-3">
          <span className="type-num text-[2.5rem] leading-none tracking-[0.1em] text-coral">{code}</span>
          <CopyCode code={code} label="copy link" />
        </div>
        <h1 className="type-display mt-4 text-[1.375rem]">{state.room.title}</h1>
      </div>

      <ul className="flex flex-col">
        {[1, 2].map((s) => {
          const p = state.players.find((x) => x.seat === s);
          return (
            <li key={s} className="flex items-baseline gap-2 border-b py-3 rule">
              <span style={{ width: 8, height: 8, background: seatAccent(s) }} aria-hidden />
              <span className="type-display text-[0.9375rem]">
                {p ? p.display_name : "waiting for a second player"}
              </span>
              {p?.is_host ? <span className="type-label text-muted">host</span> : null}
              {p && me && p.id === me.id ? <span className="type-label text-muted">you</span> : null}
            </li>
          );
        })}
      </ul>

      <dl className="grid grid-cols-2 gap-x-4 gap-y-2 border-b pb-4 rule">
        <Stat label="bankroll" value={formatCents(state.room.starting_bankroll_cents)} />
        <Stat label="minimum bid" value={formatCents(state.room.min_bid_cents)} />
        <Stat label="roster" value={`${state.room.roster_size} players`} />
        <Stat
          label="clock"
          value={state.room.timer_seconds === 0 ? "no limit" : `${state.room.timer_seconds}s`}
        />
        <Stat
          label="gives each"
          value={
            givesAreUnlimited(state.room.gives_per_player, state.room.roster_size)
              ? "\u221E"
              : String(state.room.gives_per_player)
          }
        />
      </dl>

      <p className="text-[0.8125rem] leading-relaxed text-muted">
        The deck deals one name at a time. Whoever is up either takes them for the minimum, and
        the other can bid it up, or hands them over for free and burns a spot on the other roster.
      </p>

      {/* The same form, for two different people. A spectator uses it to take
          the free seat on their own device. In a Content Creator room the host
          uses it to seat the person sitting next to them, on this one — the
          call is identical either way, and the only difference is that this
          device then keeps both tokens. */}
      {!full && (!me || offerHotSeat) ? (
        <div className="flex flex-col gap-2">
          {me ? (
            <p className="type-label text-muted">second player, same computer</p>
          ) : null}
          <TextInput value={name} maxLength={24}
            placeholder={me ? "Their name" : "Your name"}
            onChange={(e) => setName(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter") void join(); }} />
          <Button variant="primary" size="lg" disabled={busy || !name.trim()} onClick={() => void join()}>
            {me ? "Sit them down here" : "Take the second seat"}
          </Button>
          {me ? (
            <p className="text-[0.8125rem] leading-relaxed text-muted">
              For playing on one screen. The controls hand over to whoever is up,
              on their own, every time the clock moves. If they have their own
              device, send them the code instead.
            </p>
          ) : null}
          {joinError ? <p className="text-[0.8125rem] text-coral">{joinError}</p> : null}
        </div>
      ) : null}

      {!me && full ? (
        <p className="type-label text-center text-muted">both seats taken &middot; you&apos;re watching</p>
      ) : null}

      {hotSeatBar}

      {me?.is_host ? (
        <div className="flex flex-col gap-2">
          <Button variant="primary" size="lg" disabled={pending || !full} onClick={start}>
            {full ? "Start the draft" : "Waiting for a second player"}
          </Button>
          {error ? <p className="text-[0.8125rem] text-coral">{error}</p> : null}
        </div>
      ) : me ? (
        <p className="type-label text-center text-muted">waiting for the host to start</p>
      ) : null}

      {children}
    </main>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <dt className="type-label text-muted">{label}</dt>
      <dd className="type-num text-[1.0625rem]">{value}</dd>
    </div>
  );
}

function CopyCode({ code, label }: { code: string; label?: string }) {
  const [done, setDone] = useState(false);
  return (
    <button
      className="type-label text-muted hover:text-ink"
      onClick={() => {
        void navigator.clipboard
          .writeText(`${window.location.origin}/room/${code}`)
          .then(() => { setDone(true); setTimeout(() => setDone(false), 1600); })
          .catch(() => undefined);
      }}
    >
      {done ? "link copied" : (label ?? code)}
    </button>
  );
}
