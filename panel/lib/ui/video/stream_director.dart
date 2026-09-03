import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../diagnostics/log.dart';
import '../../domain/house.dart';
import 'live_video.dart';

/// The Stream Director: the one Panel module that decides which camera
/// streams play (phase-8, CONTEXT.md). Which stream a surface gets, when a
/// dial may start (admission spacing, visibility, Camera Health), when it
/// stops (debounced scroll-out, overlay, release), and the ONE copy of the
/// session lifecycle — the dance CameraTile, ZoomedCamera and the Popup's
/// `_openVideo` each hand-rolled until 2026-08-25: dial, listen, check the
/// born phase yourself (a [SettledLiveVideoSession] never fires a listener),
/// log the failure exactly once, close by every route out.
///
/// Where it sits: above the player seam, exactly where the keep-alive pool
/// sits — it dials through [VideoConfig.open] and hands back listenables, so
/// neither player knows it exists and the pool below stays invisible.
/// `main()` composes raw opener → keep-alive → Director; a hermetic test
/// composes FakeGo2rtc → Director. Since 2026-08-28 the Popup is the third
/// managed surface ([FeedRole.popup]) — the hand-rolled copy of this dance
/// it carried until then is gone. What stays the Popup's own is everything
/// that is true of Popups rather than of streams: the ding arbitration and
/// deferral (#177014, `doorbell_popup_host.dart`), the route mechanics, and
/// the deadline/ceiling clocks (`timed_feed.dart` — they time a ROUTE, so
/// the Director never learns the Navigator exists). [open], the counted
/// pass-through, remains for any unmanaged caller, so "how many streams is
/// this wall playing" keeps one answer either way.
///
/// [LiveVideoPhase] is deliberately NOT extended. queued/retrying/offline
/// are facts about *policy and the world* — an admission slot not reached, a
/// backoff ladder mid-climb, a Camera Health verdict — which a player
/// holding one socket cannot know. The Director maps the player's five
/// values up into [FeedPhase]; a managed surface never reads a
/// [LiveVideoPhase] again.
enum FeedPhase {
  /// Policy says not now, and nothing is wrong: an `autoLive: false` tile
  /// (the doorbell, HA #177014), a stills-first policy, or a tile debounced
  /// out of view. Nothing is dialled; the want stays registered. This phase
  /// (with [queued], whose picture is equally deliverable) earns the "Tap
  /// for live" badge — the states where a tap can actually deliver, which
  /// retires the widget-side `urlFor(...) != null` probe.
  idle,

  /// Wanted and admitted, waiting its admission slot (dial spacing, or the
  /// cap when [DirectorPolicy.maxConcurrent] is ever set). Wears no LIVE
  /// badge: nothing is flowing or about to until the dial goes out.
  queued,

  /// Dialled; no frames yet. Maps the player's `connecting` — honest, not
  /// cosmetic: go2rtc's on-demand transcode puts the first byte seconds out.
  connecting,

  /// Frames are arriving; [CameraFeed.view] is worth rendering.
  playing,

  /// A CAMERA dial failed — policy- or person-started alike since
  /// 2026-08-26, on a role whose [FeedRole.laddered] trait is on — and the
  /// backoff ladder ([DirectorPolicy.retrySchedule]) has the next rung
  /// armed. The next dial goes through the same admission discipline as any
  /// other; [CameraFeed.retryAttempt] counts the climb for the faces.
  retrying,

  /// Camera Health says unreachable, so nothing is dialled at all — not
  /// [failed], because nothing was tried and the fix is at the camera, not
  /// at go2rtc. Leaves this state only when Health stops saying so.
  offline,

  /// A dial failed and no automatic retry is coming: a NON-camera, on any
  /// role — in practice the doorbell, whose Ring stream must never be
  /// re-dialled on a timer (#177014); the wall is kind-structural,
  /// origin-blind (2026-08-26) — or any Device on a role whose
  /// [FeedRole.laddered] trait is off, which no shipped role is today.
  /// [CameraFeed.start] asks again. Every camera failure on every surface
  /// goes to [retrying] instead, which is why "Live view failed" is the
  /// doorbell's word in practice.
  failed,

  /// Nothing to dial and nothing to wait for: no stream name for this role,
  /// or nobody told the Panel where go2rtc is. Settled at attach, forever.
  /// Widgets that want the finer "Not wired up yet" vs "Live view
  /// unavailable" copy read the Device fields they already hold.
  unconfigured,

  /// This build cannot play video — the player said so on the first dial.
  /// Settled forever after: no amount of fixing the Hub changes a browser.
  unsupported,
}

/// The two derived facts every surface needs, defined once so the tile, the
/// zoom, and any future surface cannot drift apart on them.
extension FeedPhaseFacts on FeedPhase {
  /// The LIVE badge rule — frames are flowing or about to. The pinned
  /// invariant "LIVE = connecting|playing only", stated exactly once.
  bool get isLive => this == FeedPhase.connecting || this == FeedPhase.playing;

  /// Whether the Director is holding or pursuing a session for this feed —
  /// the tile's `wantKeepAlive` (a pursued tile may not be unmounted by the
  /// grid's lazy viewport). The tile's frame-grab gate is deliberately NOT
  /// this getter: grabbing has its own allow-list (`_grabAllowed` in
  /// `cameras_view.dart`), which excludes more than pursuit does.
  bool get isActive =>
      this == FeedPhase.queued ||
      this == FeedPhase.connecting ||
      this == FeedPhase.playing ||
      this == FeedPhase.retrying;
}

/// Which surface is asking — which decides which stream it gets and how it
/// starts.
///
/// A role is a ROW OF TRAITS the lifecycle reads, not a value the lifecycle
/// switches on: adding a surface is adding a row, where a third arm on every
/// role ternary is the shape that kept the Popup unmanaged for a month.
/// Which *stream* a role plays stays policy data ([DirectorPolicy]), because
/// streams are the owner's tuning; these traits are the lifecycle's shape.
enum FeedRole {
  /// A grid tile: plays [DirectorPolicy.tileStream] (the substream where the
  /// camera offers one — five 1080p tiles knocked cameras off the air,
  /// measured 2026-08-15). Starts by policy, so it is visibility-debounced
  /// and overlay-pausable — unless a person [CameraFeed.start]ed it, which
  /// makes it theirs.
  tile(
    prefix: 'tile',
    personFromBirth: false,
    autoLiveGoverned: true,
    viewportGoverned: true,
    healthGated: true,
    laddered: true,
  ),

  /// The one camera filling the screen: plays [DirectorPolicy.zoomStream],
  /// the full-size stream. Person-origin by definition: it exists because
  /// somebody tapped, so it is never visibility-stopped and never
  /// overlay-paused.
  zoom(
    prefix: 'zoom',
    personFromBirth: true,
    autoLiveGoverned: false,
    viewportGoverned: false,
    healthGated: true,
    laddered: true,
  ),

  /// The Popup's live view — a ding's or a person's, and the Panel's one
  /// AUDIBLE surface (ADR-0011). Plays [DirectorPolicy.popupStream], the
  /// full-size stream like the zoom. Person-origin from birth even when a
  /// ding opened it: the want is singular, urgent and watched, which is
  /// everything that trait means — no admission wait, no viewport stop,
  /// and never paused by the very overlay it constitutes.
  ///
  /// Health-BLIND for gating, by owner decision (2026-08-28): the person is
  /// standing there asking, so the dial goes out whatever the probe says,
  /// and a playing Popup is never parked by a probe flip — anything else is
  /// the gate sneaking back in. Outcomes still report ([CameraHealthSource
  /// .dialOutcome]), so the probe hears what the dial learned.
  ///
  /// Laddered since 2026-08-28's second policy step: a camera that hiccups
  /// mid-watch comes back without the person re-tapping, which is the zoom's
  /// stance on the same gesture at a different size. The two health
  /// decisions compound here and the bound is worth naming: a health-blind
  /// feed never parks at [FeedPhase.offline], so on a camera that is simply
  /// dead the ladder is stopped by the ROUTE rather than by the probe — the
  /// ding Popup's deadline, the person Popup's idle return — which is why
  /// those clocks are not decoration. The doorbell is untouched: the kind
  /// wall in `_onDialFailed` outranks this trait (#177014).
  popup(
    prefix: 'popup',
    personFromBirth: true,
    autoLiveGoverned: false,
    viewportGoverned: false,
    healthGated: false,
    laddered: true,
  );

  const FeedRole({
    required this.prefix,
    required this.personFromBirth,
    required this.autoLiveGoverned,
    required this.viewportGoverned,
    required this.healthGated,
    required this.laddered,
  });

  /// The journal vocabulary's word for this surface — `cameras.<prefix>_open`,
  /// `_failed`, `_closed`, `_skipped`, `_retry`, `_offline`, `_unsupported`.
  final String prefix;

  /// Person-origin before anything is dialled, rather than only after
  /// [CameraFeed.start].
  final bool personFromBirth;

  /// Whether [DirectorPolicy.autoLive] decides if this feed starts on its
  /// own — the tile's trait alone; the other roles exist because somebody
  /// (or a ding) asked, so they dial at attach.
  final bool autoLiveGoverned;

  /// Whether [CameraFeed.visible] means anything: only a grid tile has a
  /// viewport to scroll out of.
  final bool viewportGoverned;

  /// Whether an explicit [Reachability.unreachable] gates this feed's dials
  /// and parks it at [FeedPhase.offline]. Off for the popup role — see its
  /// own doc; outcomes report either way.
  final bool healthGated;

  /// Whether a failed CAMERA dial climbs [DirectorPolicy.retrySchedule].
  /// The kind wall is separate and absolute: a non-camera never rides a
  /// timer whatever this says (#177014).
  ///
  /// Every shipped role sets this true since 2026-08-28 — it is deliberately
  /// still a trait rather than folded away, because it is the axis ADR-0013
  /// staged the Popup's ladder decision on and reverting that decision is
  /// this one word. A role that wants a picture without a pursuit (a
  /// preview, a wall of thumbnails) is what would make it vary again.
  final bool laddered;
}

/// Camera Health's answer, three-valued on purpose: a probe entity that is
/// missing or itself unavailable is [unknown], and unknown must not cost a
/// picture — the Director gates dials only on an explicit [unreachable].
enum Reachability { unknown, reachable, unreachable }

/// The per-camera reachability fact, consulted before every dial.
///
/// The production adapter is Camera Health's business (the Hub's
/// `binary_sensor.wyze_*_rtsp` port probes, phase-8 A2); this is only the
/// shape the Director assumes. A null source at construction is the null
/// object: every camera [Reachability.unknown], outcomes dropped — the
/// Director ships before the adapter lands.
abstract interface class CameraHealthSource {
  /// Reachability for [deviceId]. Must return the SAME listenable instance
  /// per id across calls — the Director add/removes listeners against it by
  /// identity (the `watchWhileKept` tear-off discipline, one seam down).
  ValueListenable<Reachability> reachableOf(String deviceId);

  /// Session outcomes the Director reports after every dial it makes — one
  /// of Camera Health's inputs. `connected` means the dial reached
  /// [LiveVideoPhase.playing]. May no-op; must not throw — a health sink
  /// that throws would cost the dial that fed it.
  void dialOutcome(String deviceId, {required bool connected});
}

/// Policy is data (phase-8 §C). The shipped default is auto-live substream
/// tiles; stills-first is `DirectorPolicy(autoLive: DirectorPolicy.never)` —
/// a one-value swap in `main()`, not a rewrite. Every duration is
/// constructor data, the pool's stated precedent: a deadline that cannot be
/// moved can be reasoned about but not interrogated, and the fakeAsync
/// suites drive minute-scale clocks through these.
@immutable
class DirectorPolicy {
  const DirectorPolicy({
    this.autoLive = kindAutoLive,
    this.tileStream = substreamFirst,
    this.zoomStream = mainStream,
    this.popupStream = mainStream,
    this.dialSpacing = const Duration(milliseconds: 400),
    this.maxConcurrent,
    this.retrySchedule = const [
      Duration(seconds: 5),
      Duration(seconds: 15),
      Duration(seconds: 60),
    ],
    this.offscreenLinger = const Duration(seconds: 45),
    this.overlayLinger = const Duration(seconds: 45),
  });

  /// Shipped default for [autoLive]: the vocabulary row's word.
  /// `KindSpec.autoLive` is false for the doorbell (#177014), so entering
  /// the Cameras view opens NOTHING for it — the safety half survives as
  /// data, not as an `if` in a widget.
  static bool kindAutoLive(Device d) => specOf(d.kind).autoLive;

  /// The stills-first swap: no tile starts on its own; every live picture
  /// is a person's tap.
  static bool never(Device _) => false;

  /// Shipped default for [tileStream]: the substream where the camera
  /// offers one, its only stream where it does not — the old `tileStreamOf`
  /// rule, now policy data.
  static String? substreamFirst(Device d) => d.substream ?? d.streamName;

  /// Shipped default for [zoomStream] and [popupStream]: the full-size
  /// stream, because each is the one camera somebody asked about, filling
  /// its surface with no grid running beside it.
  static String? mainStream(Device d) => d.streamName;

  /// Whether a [FeedRole.tile] feed starts without being asked.
  final bool Function(Device) autoLive;

  /// Which stream a tile plays; null means nothing to dial
  /// ([FeedPhase.unconfigured]).
  final String? Function(Device) tileStream;

  /// Which stream a zoom plays; null likewise.
  final String? Function(Device) zoomStream;

  /// Which stream a Popup plays; null likewise.
  final String? Function(Device) popupStream;

  /// Minimum gap between POLICY dials. go2rtc spins a producer per dial and
  /// every frame crosses the 2.4 GHz air twice, so auto-starts and retries
  /// are spaced, never a burst. Hygiene, not the fix — the 2026-08-25 probe
  /// found the real failures upstream (dead camera daemons) — and
  /// deliberately not applied to person dials: a human tap is one dial, and
  /// somebody is standing there.
  final Duration dialSpacing;

  /// Cap on concurrent sessions, counting managed feeds and counted
  /// pass-throughs alike. Null — the v1 shipped value, decided against the
  /// 2026-08-25 probe (capacity was not the failure) — means uncapped; the
  /// slot exists so capping is a policy edit, not a redesign. When set and
  /// reached, policy wants hold at [FeedPhase.queued]; person dials and
  /// pass-throughs are never made to wait (a doorbell ding dials now).
  final int? maxConcurrent;

  /// Backoff for failed policy dials; the last entry repeats forever
  /// (5 s → 15 s → 60 s → every 60 s). Wyze firmware drops off the network
  /// for seconds routinely — "changes on refresh" is what a no-retry policy
  /// looks like. The ladder resets when a dial reaches playing. Must be
  /// non-empty (a const constructor cannot assert it; an empty list costs a
  /// StateError on the first failed policy dial).
  final List<Duration> retrySchedule;

  /// How long a policy-started tile keeps playing after its surface reports
  /// `visible = false` before the Director stops it. Generous on purpose:
  /// the floodlight units cost 17-18 s to restart cold, so a scroll-flick
  /// must not tear a producer down.
  final Duration offscreenLinger;

  /// The overlay pause: how long after [StreamDirector.overlaid] flips true
  /// before policy-started feeds are stopped. 45 s, deliberately LONGER
  /// than the doorbell Popup's 30 s deadline: a routine ding must never
  /// churn producers (the pool holds a released stream only 20 s, so a stop
  /// under a 30 s Popup would mean a fresh 5-17 s dial per camera after
  /// every ding). What this pause is for is the Popup somebody HOLDS open —
  /// past 45 s the grid's airtime goes to the thing being watched.
  final Duration overlayLinger;
}

/// One surface's standing want, from [StreamDirector.attach] to [release].
/// The caller states the want and renders the verdict; everything between —
/// when to dial, when to give up, when to try again, when to let go — is
/// the Director's.
///
/// Main isolate only. [phase] never fires during attach (the born state is
/// the initial value — read `phase.value` on return; any born failure has
/// already been logged by the Director exactly once, so callers never log).
/// It may fire synchronously from [start] and from external events (timers,
/// health flips, player phase changes). It never fires after [release].
abstract interface class CameraFeed {
  /// The tile-state vocabulary, one transition per change. Listeners are
  /// the surface's `setState` and nothing more — logging is not the
  /// caller's job anywhere near this module.
  ValueListenable<FeedPhase> get phase;

  /// The most recent dial's failure sentence, for rendering never for
  /// branching; non-null only in [FeedPhase.failed] and [FeedPhase.retrying].
  /// Passes through the players' redaction contract unchanged: it may name
  /// a stream, never a URL.
  String? get failure;

  /// What to render while [phase] is [FeedPhase.playing], and only then.
  /// Stable within one dial (the player's contract passes through); changes
  /// identity across re-dials, so read it fresh each build.
  Widget get view;

  /// The surface's viewport fact, pushed not polled; `true` at attach.
  /// `false` starts [DirectorPolicy.offscreenLinger] on a policy-started
  /// feed (stop → [FeedPhase.idle], want retained); `true` cancels the
  /// debounce and re-queues an idle want through admission. Ignored for
  /// person-origin feeds and for [FeedRole.zoom]. No-op after [release].
  set visible(bool value);

  /// How many automatic re-dials the ladder has scheduled since the last
  /// picture — 0 while none is pending, reset the moment a dial reaches
  /// playing, on a health-flip recovery, and on a stop to idle (an idle
  /// park is a clean slate: the resume dial is a fresh start at rung
  /// zero, not a resumption of somebody else's backoff). For faces: the
  /// human count is one ahead ("try #2" is the FIRST re-dial —
  /// `value + 1` — because the person watched attempt #1 fail). Stays put
  /// through the re-dial's own connecting phase, which is what lets a
  /// face keep counting instead of resetting to the first-dial words.
  ///
  /// A listenable, not a getter, and the reason is the one climb phase
  /// cannot report: a re-dial that fails synchronously goes
  /// retrying→retrying, no phase notification fires, and a face that
  /// rebuilt only on phase would freeze its count. Listen to this beside
  /// [phase]; remove the listener in `dispose` like any other.
  ValueListenable<int> get retryAttempt;

  /// Camera Health's current verdict for this feed's Device — [Reachability
  /// .unknown] where no health source is wired. Exposed because phase is
  /// not a health proxy: a feed parked at [FeedPhase.idle] (or settled at
  /// unconfigured/unsupported) never transitions when the probe flips, so
  /// a caller that must not touch a dead camera — the tile's frame-grab
  /// loop — has to read the verdict itself, live, not infer it from phase.
  /// Three-valued on purpose: only [Reachability.unreachable] may gate;
  /// unknown is absence of evidence, not a verdict (the health module's own
  /// rule).
  Reachability get reachability;

  /// A person asked. Marks the feed person-origin (never viewport-stopped,
  /// never overlay-paused; cameras keep the retry ladder — a person
  /// standing at a dead zoom wants it back, not a re-tap — while the
  /// doorbell stays manual-only, #177014), and: from [FeedPhase.idle]
  /// dials now — spacing is for storms, not for a standing human; from
  /// [FeedPhase.failed] or [FeedPhase.retrying] re-dials; from
  /// [FeedPhase.offline] does NOT dial — Health is absolute — but the
  /// recovery dial, when Health flips, is theirs. No-op while live, on the
  /// settled phases, and after [release]. Never throws.
  void start();

  /// Whether this feed's sound — where the transport carries any — reaches
  /// the speakers. Set on the FEED, not on a socket: the intent is
  /// remembered and re-applied to whatever session the feed is holding, so
  /// a ladder re-dial under a watching person does not come back silent
  /// and no caller has to know a re-dial happened. Every session is born
  /// muted (the seam-wide invariant, `live_video.dart`);
  /// unmuting is a SURFACE decision, and the pass-through exists on every
  /// role while exactly one uses it — the Popup, the Panel's one AUDIBLE
  /// surface (the doorbell's LISTEN leg, ADR-0011, ducked back to muted
  /// while push-to-talk is held). Never throws, callable in any phase,
  /// inert with no session up and after [release]; the keep-alive pool
  /// re-mutes every session it lingers, so sound cannot outlive the
  /// surface that asked (the pool's guarantee, not the caller's diligence).
  void setMuted(bool muted);

  /// The one way out, owed by every route out — the surface's `dispose()`
  /// calls it and nothing else does. Cancels this feed's timers, removes
  /// its listeners, closes its session if one is up (through the opener
  /// seam, so the keep-alive below may linger it — a zoom-and-back
  /// re-attaches instead of re-dialling), writes the one closed line.
  /// Idempotent: a route can leave four ways and a timer can fire during
  /// the fifth. After it, [phase] is quiet forever.
  void release();
}

/// The Director. One per process on the wall (composed in `main()` beside
/// the keep-alive pool, never disposed there); a view that was not handed
/// one builds its own over its [VideoConfig], which is what keeps every
/// hermetic fixture working unchanged. Disposed by whoever built it.
class StreamDirector {
  StreamDirector({
    required this.video,
    this.policy = const DirectorPolicy(),
    this.health,
  });

  /// Where go2rtc is and how to dial it — the same one value the surfaces
  /// used to hold themselves. The Director consults [VideoConfig.urlFor]
  /// so no widget ever builds a go2rtc URL again.
  final VideoConfig video;

  final DirectorPolicy policy;

  final CameraHealthSource? health;

  final _feeds = <_Feed>{};

  /// Health listenables this Director is subscribed to, by device id, with
  /// the registered callback (so removal can name what addition gave — the
  /// `watchWhileKept` tear-off discipline, one seam down) and a refcount so
  /// the listener is removed when the last feed for that Device releases.
  final _healthWatch =
      <String, (ValueListenable<Reachability>, VoidCallback, int)>{};

  /// Admission gate: while armed, policy dials queue instead of going out.
  /// Timer-driven rather than clock-compared, so fakeAsync suites can walk
  /// it without a clock abstraction.
  Timer? _gate;
  final _queue = <_Feed>[];

  /// Sessions currently open: managed feeds' plus counted pass-throughs'.
  /// What [DirectorPolicy.maxConcurrent] reads, when it is ever set.
  var _activeSessions = 0;

  var _overlaid = false;
  var _disposed = false;

  /// The overlay fact, pushed by the one surface that can know it (the
  /// Cameras route hears `didPushNext`/`didPopNext`; a visibility callback
  /// is blind to routes — google/flutter.widgets #29). True starts
  /// [DirectorPolicy.overlayLinger] on every policy-origin feed; false
  /// cancels the pending stops and re-admits what already stopped.
  set overlaid(bool value) {
    if (_disposed || _overlaid == value) return;
    _overlaid = value;
    for (final feed in _feeds) {
      feed.onOverlaid(value);
    }
  }

  /// The overlay fact, readable: the tile's frame-grab gate declines to
  /// bill a camera for a face nobody can see — the same doctrine the
  /// overlay stop itself enforces one layer down.
  bool get overlaid => _overlaid;

  /// Register a surface's want. Never throws. Synchronous contract: gates
  /// are evaluated during the call, and if the admission slot is free the
  /// dial happens inside it — on return `phase.value` is already the truth,
  /// and any born failure is already logged.
  ///
  /// One feed per surface; two attaches for one Device are two independent
  /// feeds each owing its own [release] (a tile and a Popup on one camera
  /// are legal — stream0 and stream1 pull simultaneously, measured).
  CameraFeed attach(Device device, {required FeedRole role}) {
    final feed = _Feed(this, device, role);
    if (_disposed) {
      feed.released = true;
      return feed;
    }
    _feeds.add(feed);
    _watchHealth(feed);
    feed.born();
    return feed;
  }

  /// The counted pass-through, shaped exactly as [LiveVideoOpener] so
  /// `main()` hands `VideoConfig(open: director.open)` to the Popup path
  /// unchanged. Sessions opened here are COUNTED — they occupy the cap and
  /// the census — but never MANAGED: no waiting, no health gate, no retry;
  /// a doorbell ding dials now. Keeps the opener contract whole: may not
  /// throw. After [dispose], delegates straight through, uncounted.
  LiveVideoSession open(Uri url, {required String name}) {
    final LiveVideoSession inner;
    try {
      inner = video.open(url, name: name);
    } catch (error) {
      // The pool's own discipline, kept here too: the type, never the
      // message — the URL is the one string that can carry a password.
      return SettledLiveVideoSession(LiveVideoPhase.failed,
          failure: 'the opener threw ${error.runtimeType}');
    }
    if (_disposed) return inner;
    _activeSessions++;
    return _CountedSession(inner, () {
      _activeSessions--;
      _drainQueue();
    });
  }

  /// Test lifecycle, the pool's precedent: cancels every timer (a pending
  /// Timer outliving the tree fails a widget test by itself), closes any
  /// session a feed still holds, detaches from health. Idempotent. Never
  /// called on the wall.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _gate?.cancel();
    _gate = null;
    _queue.clear();
    for (final feed in _feeds.toList()) {
      feed.releaseInternal('panel_stopped');
    }
    _feeds.clear();
    // releaseInternal unwatches per feed; anything still here is a refcount
    // that never reached zero, and its listener goes with the map.
    for (final entry in _healthWatch.values) {
      entry.$1.removeListener(entry.$2);
    }
    _healthWatch.clear();
  }

  // ---- admission ----------------------------------------------------------

  /// A policy dial asks to go out. Person dials skip this entirely and do
  /// not arm the gate either — see [_Feed._requestDial] for why a tap must
  /// not make the grid's own re-attaches wait behind it.
  void _admit(_Feed feed) {
    if (_gate != null || !_underCap) {
      feed.setPhase(FeedPhase.queued);
      if (!_queue.contains(feed)) _queue.add(feed);
      return;
    }
    // Gate armed BEFORE the dial, deliberately: a dial that fails
    // synchronously (a born-failed settled session) closes its session
    // inside `dial()`, and that close re-enters [_drainQueue] — which must
    // find the gate up, or one bad camera would cascade the whole queue out
    // in a single tick, unspaced (found in review, 2026-08-25).
    _armGate();
    feed.dial();
  }

  bool get _underCap {
    final cap = policy.maxConcurrent;
    return cap == null || _activeSessions < cap;
  }

  void _armGate() {
    if (policy.dialSpacing == Duration.zero) return;
    _gate?.cancel();
    _gate = Timer(policy.dialSpacing, () {
      _gate = null;
      _drainQueue();
    });
  }

  void _drainQueue() {
    if (_disposed || _gate != null) return;
    while (_queue.isNotEmpty && _underCap) {
      final feed = _queue.removeAt(0);
      if (feed.released || feed.phase.value != FeedPhase.queued) continue;
      // Same order as [_admit], same reason: the dial can re-enter here.
      _armGate();
      feed.dial();
      return; // one per gate window; the gate's own fire drains the next.
    }
  }

  void _unqueue(_Feed feed) => _queue.remove(feed);

  // ---- health -------------------------------------------------------------

  void _watchHealth(_Feed feed) {
    final health = this.health;
    // A health-blind role is not subscribed at all: it would only ever
    // no-op the callbacks, and its refcount churn is bookkeeping for
    // nothing. Its `reachability` getter still reads the source directly.
    if (health == null || !feed.role.healthGated) return;
    final id = feed.device.id;
    final existing = _healthWatch[id];
    if (existing != null) {
      _healthWatch[id] = (existing.$1, existing.$2, existing.$3 + 1);
      return;
    }
    final listenable = health.reachableOf(id);
    // A named closure, stored, so the unwatch can remove exactly what this
    // added. A fresh lambda per epoch was the review's first leak: the
    // health source's notifiers live as long as the process, and every
    // Cameras-view visit would have orphaned one listener per camera on
    // them, forever (found 2026-08-25).
    void onChange() => _onHealth(id);
    listenable.addListener(onChange);
    _healthWatch[id] = (listenable, onChange, 1);
  }

  void _unwatchHealth(_Feed feed) {
    // Mirror of [_watchHealth]'s guard: never subscribed, nothing to drop —
    // and without this, releasing a popup feed would eat a refcount a
    // health-gated sibling on the same Device is still standing on.
    if (!feed.role.healthGated) return;
    final id = feed.device.id;
    final existing = _healthWatch[id];
    if (existing == null) return;
    if (existing.$3 > 1) {
      _healthWatch[id] = (existing.$1, existing.$2, existing.$3 - 1);
      return;
    }
    existing.$1.removeListener(existing.$2);
    _healthWatch.remove(id);
  }

  Reachability _reachability(String deviceId) =>
      health?.reachableOf(deviceId).value ?? Reachability.unknown;

  void _onHealth(String deviceId) {
    if (_disposed || !_healthWatch.containsKey(deviceId)) return;
    final verdict = _reachability(deviceId);
    for (final feed in _feeds.toList()) {
      if (feed.device.id == deviceId) feed.onHealth(verdict);
    }
  }

  void _reportOutcome(String deviceId, {required bool connected}) {
    try {
      health?.dialOutcome(deviceId, connected: connected);
    } catch (_) {
      // A health sink that throws may not cost the dial that fed it.
    }
  }
}

/// One managed want and its whole lifecycle. Private: the interface is
/// [CameraFeed]; everything here is implementation the three old copies
/// spelled out in widgets.
class _Feed implements CameraFeed {
  _Feed(this.director, this.device, this.role);

  final StreamDirector director;
  final Device device;
  final FeedRole role;

  final _phase = ValueNotifier(FeedPhase.idle);
  @override
  ValueListenable<FeedPhase> get phase => _phase;

  @override
  String? failure;

  LiveVideoSession? _session;

  @override
  Widget get view => _session?.view ?? const SizedBox.shrink();

  @override
  Reachability get reachability =>
      director.health?.reachableOf(device.id).value ?? Reachability.unknown;

  @override
  ValueListenable<int> get retryAttempt => _retryAttempt;

  /// Person-origin: from birth where [FeedRole.personFromBirth] says so (the
  /// zoom, the Popup), a tile after [start]. Exempt from viewport stops,
  /// overlay pauses and admission spacing, because somebody is standing
  /// there. The retry ladder is NOT an exemption any more (2026-08-26): a
  /// person-origin camera on a laddered role reconnects like any tile —
  /// only a non-camera, or an unladdered role, rests at failed (#177014).
  var personOrigin = false;

  var _visible = true;
  var released = false;

  /// Whether this dial earned an open line — an `unsupported` or born-failed
  /// session dialled nothing worth a closed line (`_openLogged` discipline,
  /// now in one place).
  var _openLogged = false;
  var _failureLogged = false;

  /// The surface's standing audio intent, remembered across the sessions
  /// this feed churns. Muted is the seam's born state and every role's
  /// default; only the Popup ever asks otherwise (ADR-0011's LISTEN leg).
  /// Held here rather than re-applied by the caller because the caller is
  /// not supposed to know a re-dial happened at all — before the ladder
  /// reached the Popup nothing re-dialled under a listener, and a
  /// reconnect that came back silent is the bug that shape invites.
  var _muted = true;
  // A notifier, not an int: the ladder can climb WITHOUT a phase change —
  // a re-dial that fails synchronously goes retrying→retrying, which
  // `ValueNotifier`'s == short-circuit swallows — and a counted face that
  // only listens to phase freezes at "try 2" while the Director is on try
  // six (review, 2026-08-26).
  final _retryAttempt = ValueNotifier(0);

  Timer? _lingerTimer;
  Timer? _overlayTimer;
  Timer? _retryTimer;

  String get _eventPrefix => role.prefix;

  String? get _streamName => switch (role) {
        FeedRole.tile => director.policy.tileStream(device),
        FeedRole.zoom => director.policy.zoomStream(device),
        FeedRole.popup => director.policy.popupStream(device),
      };

  void setPhase(FeedPhase value) {
    if (released) return;
    _phase.value = value;
  }

  /// The born verdict, decided synchronously at attach.
  void born() {
    if (role.personFromBirth) personOrigin = true;
    final name = _streamName;
    final url = director.video.urlFor(name);
    if (name == null || url == null) {
      // Logged only where a dial was wanted: an idle doorbell logs nothing
      // (nothing is wrong and nothing was asked), but an auto tile or a
      // zoom that cannot dial is a fact the journal reader greps for.
      final wanted = personOrigin || director.policy.autoLive(device);
      if (wanted) {
        // Three reasons, not two — the Popup's finer vocabulary, adopted
        // seam-wide when its dance moved here (2026-08-28): "nobody named a
        // go2rtc" and "the named one is not an address" are different fixes.
        Log.debug('cameras', '${_eventPrefix}_skipped', {
          'device': device.id,
          'reason': name == null
              ? 'no_stream_name'
              : director.video.go2rtcUrl.isEmpty
                  ? 'no_go2rtc_url'
                  : 'bad_go2rtc_url',
        });
      }
      setPhase(FeedPhase.unconfigured);
      return;
    }
    if (role.autoLiveGoverned && !director.policy.autoLive(device)) {
      setPhase(FeedPhase.idle);
      return;
    }
    _requestDial();
  }

  void _requestDial({bool ladder = false}) {
    if (released) return;
    if (role.healthGated &&
        director._reachability(device.id) == Reachability.unreachable) {
      Log.debug('cameras', '${_eventPrefix}_offline', {'device': device.id});
      setPhase(FeedPhase.offline);
      return;
    }
    if (personOrigin && !ladder) {
      // No gate: spacing paces policy storms (a view opening five tiles),
      // and a human tap is one dial. Not arming it either — a zoom-and-back
      // would otherwise hold the returning grid's re-attaches at the gate,
      // turning the pool's free re-attach into a visible wait. A LADDER
      // re-dial is not a tap — it is timer-born and takes admission below.
      dial();
    } else {
      director._admit(this);
    }
  }

  /// The one copy of the dance. Called only by the Director's admission (or
  /// directly for person dials) — never by a surface.
  void dial() {
    if (released) return;
    final name = _streamName;
    final url = director.video.urlFor(name);
    if (name == null || url == null) {
      setPhase(FeedPhase.unconfigured);
      return;
    }
    failure = null;
    _failureLogged = false;
    final LiveVideoSession session;
    try {
      session = director.video.open(url, name: name);
    } catch (error) {
      // Both real openers and the pool keep the may-not-throw contract; the
      // Director defends anyway, exactly as the pool does for the Cameras
      // view's bare call — one habit, every layer.
      _onDialFailed('the opener threw ${error.runtimeType}');
      return;
    }
    _session = session;
    director._activeSessions++;
    switch (session.phase.value) {
      case LiveVideoPhase.unsupported:
        // Dialled nothing: no open line, no census stay, settled forever.
        Log.info('cameras', '${_eventPrefix}_unsupported', {'name': name});
        _dropSession(countCensus: true);
        setPhase(FeedPhase.unsupported);
        return;
      case LiveVideoPhase.failed:
        // The born-failed trap ([SettledLiveVideoSession] never fires a
        // listener), closed here once instead of at three call sites.
        _dropSession(countCensus: true);
        _onDialFailed(session.failure ?? 'unknown');
        return;
      case LiveVideoPhase.connecting ||
            LiveVideoPhase.playing ||
            LiveVideoPhase.unconfigured:
        // Only where a surface actually asked: a born-muted session is
        // left exactly as it was born, so no tile's dial ever touches the
        // flag and the mute order a suite reads stays the surface's own.
        if (!_muted) session.setMuted(false);
        _openLogged = true;
        Log.info('cameras', '${_eventPrefix}_open', {'name': name});
        session.phase.addListener(_onPlayerPhase);
        setPhase(session.phase.value == LiveVideoPhase.playing
            ? FeedPhase.playing
            : FeedPhase.connecting);
        if (session.phase.value == LiveVideoPhase.playing) {
          // Born playing is the keep-alive pool handing back a lingered
          // picture — no dial went out, so nothing NEW is known about the
          // camera. The ladder still resets (a picture is on the wall),
          // but no outcome is reported: the pool's linger outlives the
          // MJPEG watchdog (20 s vs 15 s), so this picture can be a dead
          // camera's last frames, and a minted `connected` would overturn
          // a probe that is right (found in review, 2026-08-28). Evidence
          // is what [_onPlayerPhase] reports: a transition to playing,
          // which only fresh frames produce.
          _retryAttempt.value = 0;
        }
    }
  }

  void _onPlayerPhase() {
    final session = _session;
    if (session == null || released) return;
    switch (session.phase.value) {
      case LiveVideoPhase.playing:
        setPhase(FeedPhase.playing);
        _onReachedPlaying();
      case LiveVideoPhase.failed:
        final reason = session.failure ?? 'unknown';
        _closeSession('failed');
        _onDialFailed(reason);
      case LiveVideoPhase.connecting:
        // Not only the born state: the MSE player drops back to connecting
        // while it reconnects after a media-element error (up to three
        // times, keeping the same <video>). The face must say so rather
        // than hold `playing` over a picture that is being rebuilt.
        setPhase(FeedPhase.connecting);
      case LiveVideoPhase.unconfigured || LiveVideoPhase.unsupported:
        // Settled values cannot follow a live one in either player.
        break;
    }
  }

  void _onReachedPlaying() {
    _retryAttempt.value = 0;
    director._reportOutcome(device.id, connected: true);
  }

  void _onDialFailed(String reason) {
    failure = reason;
    if (!_failureLogged) {
      _failureLogged = true;
      Log.warn('cameras', '${_eventPrefix}_failed', {
        'name': _streamName,
        'reason': reason,
      });
    }
    director._reportOutcome(device.id, connected: false);
    if (released) return;
    if (role.healthGated &&
        director._reachability(device.id) == Reachability.unreachable) {
      // Health names the cause: stop the ladder — the recovery dial rides
      // the health flip, not a timer hammering a dead daemon (and each
      // failed dial costs TWO camera connections, measured 2026-08-25).
      setPhase(FeedPhase.offline);
      return;
    }
    // The ladder is a KIND wall, not an origin rule (owner request
    // 2026-08-26; sharpened by its review): cameras reconnect whoever
    // started them — a person standing at a zoom that died mid-watch wants
    // the picture back, not an instruction to re-tap — and a non-camera
    // NEVER rides a timer, whoever started it. The doorbell is the case
    // that matters: an automatic re-dial on the Ring stream re-opens cloud
    // sessions (#177014), which only a person's own tap may do. No policy
    // path dials a non-camera today (`autoLive` is a camera fact), so the
    // else arm is the doorbell's in practice — but the wall is structural,
    // same as the still loop's `_grabStream`. The role's own trait ANDs
    // in: a role that wants a picture without a pursuit would rest here
    // whatever the kind. Every shipped role climbs (2026-08-28).
    if (device.kind == DeviceKind.camera && role.laddered) {
      final schedule = director.policy.retrySchedule;
      final rung = _retryAttempt.value < schedule.length
          ? schedule[_retryAttempt.value]
          : schedule.last;
      _retryAttempt.value++;
      Log.debug('cameras', '${_eventPrefix}_retry', {
        'name': _streamName,
        'attempt': _retryAttempt.value,
        'in_s': rung.inSeconds,
      });
      setPhase(FeedPhase.retrying);
      _retryTimer?.cancel();
      _retryTimer = Timer(rung, () {
        if (released || _phase.value != FeedPhase.retrying) return;
        // A ladder re-dial is timer-born, not person-born: it takes the
        // admission gate like any policy dial, because N cameras whose
        // daemons died together must come back spaced — the person
        // exemption is for the tap itself, not for the storm the ladder
        // can synthesize five seconds after a Wi-Fi blip (review,
        // 2026-08-26).
        _requestDial(ladder: true);
      });
    } else {
      setPhase(FeedPhase.failed);
    }
  }

  // ---- inputs -------------------------------------------------------------

  @override
  set visible(bool value) {
    if (released || !role.viewportGoverned) return;
    if (_visible == value) return;
    _visible = value;
    if (personOrigin) return;
    if (!value) {
      _armStop(_lingerTimer, director.policy.offscreenLinger, 'viewport',
          (t) => _lingerTimer = t);
    } else {
      _lingerTimer?.cancel();
      _lingerTimer = null;
      _resume();
    }
  }

  void onOverlaid(bool value) {
    if (released || personOrigin) return;
    if (value) {
      _armStop(_overlayTimer, director.policy.overlayLinger, 'overlaid',
          (t) => _overlayTimer = t);
    } else {
      _overlayTimer?.cancel();
      _overlayTimer = null;
      _resume();
    }
  }

  void _armStop(
      Timer? current, Duration after, String reason, void Function(Timer) keep) {
    if (!_phase.value.isActive) return;
    current?.cancel();
    keep(Timer(after, () {
      // Re-checked at fire time, not only at arm time: the feed can settle
      // between the two — a linger armed over `playing` firing after Health
      // parked the feed `offline` would rewrite the verdict to `idle`, the
      // one badge-wearing phase, over a camera that is off the air (found
      // in review, 2026-08-25).
      if (released || personOrigin || !_phase.value.isActive) return;
      _stop(reason);
    }));
  }

  /// A gate reopened (scrolled back in, overlay gone): an idle want that
  /// still qualifies re-enters admission. The keep-alive below makes the
  /// quick round trip cheap — inside its 20 s linger this re-attaches
  /// rather than re-dialling.
  void _resume() {
    if (_phase.value != FeedPhase.idle) return;
    if (role.autoLiveGoverned && !director.policy.autoLive(device)) return;
    if (!_visible || director._overlaid) return;
    _requestDial();
  }

  void _stop(String reason) {
    director._unqueue(this);
    _retryTimer?.cancel();
    _retryTimer = null;
    // An idle park is a clean slate — the getter's own contract ("0 while
    // none is pending"): the resume dial after a scroll-in must neither
    // wear "Reconnecting…" for what a person experiences as a fresh start,
    // nor inherit a mid-ladder backoff rung (review, 2026-08-26).
    _retryAttempt.value = 0;
    _closeSession(reason);
    setPhase(FeedPhase.idle);
  }

  void onHealth(Reachability verdict) {
    // A health-blind role never parks and never rides the recovery flip —
    // it is not even subscribed ([StreamDirector._watchHealth]); this guard
    // covers the flip a sibling feed's subscription fans out.
    if (released || !role.healthGated) return;
    if (verdict == Reachability.unreachable) {
      // Gate future dials; never yank a picture that is up — the players'
      // own watchdogs decide about a live socket, and a probe may be wrong
      // about a stream that is visibly playing.
      if (_phase.value == FeedPhase.retrying ||
          _phase.value == FeedPhase.queued ||
          _phase.value == FeedPhase.failed) {
        director._unqueue(this);
        _retryTimer?.cancel();
        _retryTimer = null;
        Log.debug('cameras', '${_eventPrefix}_offline', {'device': device.id});
        setPhase(FeedPhase.offline);
      }
      return;
    }
    if (_phase.value == FeedPhase.offline) {
      _retryAttempt.value = 0;
      if (personOrigin) {
        // A person-origin feed's recovery dial is theirs — they asked while
        // the camera was down, and the answer arrives now, viewport or not.
        _requestDial();
      } else {
        // A policy feed's recovery goes through the same gates as any other
        // resume: a camera coming back must not start streaming behind an
        // overlay or below the fold — offline is not an active phase, so no
        // stop timer was ever armed for it, and a blind dial here would
        // stream unwatched until the idle return (found in review, 2026-08-25).
        // Parking at idle keeps the want; scroll-in or overlay-pop re-admits.
        setPhase(FeedPhase.idle);
        _resume();
      }
    }
  }

  @override
  void setMuted(bool muted) {
    if (released) return;
    _muted = muted;
    _session?.setMuted(muted);
  }

  @override
  void start() {
    if (released) return;
    switch (_phase.value) {
      case FeedPhase.idle:
        personOrigin = true;
        _requestDial();
      case FeedPhase.queued:
        // Jumping the queue is the point: the gate paces storms, and this
        // want just became a person standing there.
        personOrigin = true;
        director._unqueue(this);
        _requestDial();
      case FeedPhase.failed || FeedPhase.retrying:
        personOrigin = true;
        _retryTimer?.cancel();
        _retryTimer = null;
        _requestDial();
      case FeedPhase.offline:
        // Health is absolute; the want turns person-origin so the recovery
        // dial is immediate when the camera returns.
        personOrigin = true;
      case FeedPhase.connecting ||
            FeedPhase.playing ||
            FeedPhase.unconfigured ||
            FeedPhase.unsupported:
        break;
    }
  }

  @override
  void release() => releaseInternal('view_closed');

  void releaseInternal(String reason) {
    if (released) return;
    released = true;
    director._unqueue(this);
    _lingerTimer?.cancel();
    _overlayTimer?.cancel();
    _retryTimer?.cancel();
    _closeSession(reason);
    director._unwatchHealth(this);
    director._feeds.remove(this);
  }

  void _closeSession(String reason) {
    final session = _session;
    if (session == null) return;
    session.phase.removeListener(_onPlayerPhase);
    _session = null;
    session.close();
    director._activeSessions--;
    director._drainQueue();
    if (_openLogged) {
      Log.info('cameras', '${_eventPrefix}_closed', {
        'name': _streamName,
        'reason': reason,
      });
    }
    _openLogged = false;
  }

  void _dropSession({required bool countCensus}) {
    final session = _session;
    _session = null;
    session?.close();
    if (countCensus) {
      director._activeSessions--;
      director._drainQueue();
    }
  }
}

/// A pass-through session whose close tells the census, once.
class _CountedSession implements LiveVideoSession {
  _CountedSession(this._inner, this._onClose);

  final LiveVideoSession _inner;
  final VoidCallback _onClose;
  var _closed = false;

  @override
  ValueListenable<LiveVideoPhase> get phase => _inner.phase;

  @override
  String? get failure => _inner.failure;

  @override
  Widget get view => _inner.view;

  @override
  void setMuted(bool muted) => _inner.setMuted(muted);

  @override
  void close() {
    _inner.close();
    if (_closed) return;
    _closed = true;
    _onClose();
  }
}
