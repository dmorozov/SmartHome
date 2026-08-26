import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../diagnostics/log.dart';
import 'live_video.dart';

/// How long a go2rtc session stays up after its last consumer let go.
///
/// The number this whole file is sized on. Issue #1 measured the losing gaps
/// directly: a reopen **1.0-1.1 s** after teardown produced a picture that
/// never healed, ~40 s produced half a frame, minutes produced a good one. So
/// the window has to cover the Popup's own open→close→reopen cadence, which is
/// seconds, not the idle case, which is minutes.
///
/// 20 s, and the ceiling on it is not bandwidth. A kept session is a Ring
/// session with **nobody watching it**, and HA #177014 says an open Ring
/// session can suppress the next real ding — so it may not be allowed to live
/// longer than one somebody *is* watching, which `kDoorbellPopupDeadline` in
/// `ui/doorbell_popup_host.dart` puts at 30 s. A test asserts that inequality
/// rather than trusting two constants in two files to stay in the right order.
///
/// **What it costs, stated as a sum rather than a comparison:** an unprompted
/// doorbell Popup that runs its full 30 s deadline and is not reopened now
/// holds its Ring session for **50 s**, not 30. That is a real increase over
/// the behaviour before this file existed, it is the price of the fix, and it
/// is bounded — see [kLiveVideoMaxHeld] for the part that is *not* as tight as
/// it first looks.
///
/// What 20 s does not cover is the issue's ~40 s reopen, which came back half
/// corrupt. That case is left on the table on purpose: buying it would mean
/// holding a doorbell's stream longer than the Panel is willing to show it,
/// which trades a green half-frame for a missed ding.
const kLiveVideoLinger = Duration(seconds: 20);

/// The oldest a session may be and still be kept or re-attached to, counted
/// from the moment it was dialled.
///
/// Two minutes, the same figure as `kDoorbellPopupCeiling` and for its
/// argument: #177014 is about how *old* a Ring session is, and without a cap
/// one session could serve an unbounded chain of reopens. Past this the chain
/// is broken and the next reopen dials fresh, paying the 2-5 s Ring spin-up
/// once every two minutes, which is exactly the price that file already
/// decided was worth paying.
///
/// Deliberately **not** a cap on a session somebody is watching. The Cameras
/// view holds a tile live for up to `kCamerasIdleReturn` — five minutes — on
/// purpose, and blanking a camera a person chose to watch would be a worse lie
/// than the one this file is fixing: closing the player under a live consumer
/// leaves the phase reading `playing` over an empty box, which is the stale
/// picture ADR-0007 is about. Giving the lease its own phase so it could say
/// `failed` was rejected too — it would yank a picture off the wall from
/// somebody standing in front of it, on a schedule they cannot see.
///
/// **So state the bound honestly, because it is not the one it looks like.**
/// What is guaranteed:
///
/// 1. nothing is held with **nobody watching** for more than
///    [kLiveVideoLinger];
/// 2. no **chain of reopens** is served by a session older than this;
/// 3. a consumer is never interrupted.
///
/// Those three cannot be combined into "no Ring session is ever older than two
/// minutes", and an earlier draft of this file claimed exactly that. They
/// cannot: a reopen arriving at 1:59 re-attaches, and that consumer then runs
/// its own full lifetime. The real worst case is `maxHeld` **plus one
/// consumer's own bound** — 2 + 2 = **4 min** through a doorbell Popup's
/// ceiling, 2 + 5 = **7 min** through a Cameras tile's idle return. Against a
/// Cameras tile that could already hold a Ring session for 5 minutes before
/// this file existed, and a test pins both numbers so the trade cannot drift
/// without somebody noticing.
///
/// The alternative — refusing reuse near the cap — buys nothing: whatever the
/// cutoff, the last consumer through it still runs its own lifetime, so the
/// sum only shrinks by the cutoff. The only way to a hard 2 min is to stop
/// re-attaching entirely, i.e. not to fix issue #1.
///
/// Not imported from `ui/doorbell_popup_host.dart` — a value in the video
/// layer must not make it depend on the Popup's — so the two are equal by
/// argument rather than by reference.
const kLiveVideoMaxHeld = Duration(minutes: 2);

/// Keeps a go2rtc session alive for a moment after its consumer lets go, so
/// that a consumer coming straight back re-attaches to a producer that is
/// still running instead of racing a new one into existence.
///
/// **What was measured** (issue #1, observed by hand on 2026-08-06). Tapping
/// the doorbell pin three times gave a good picture, then half a green frame,
/// then nothing at all — and a session left open 2 m 22 s never healed. Three
/// plain `ffmpeg -frames:v 1` pulls a second apart, with no Panel in the loop,
/// **all three decoded corrupt frames** (one ~90 % smear, two half-frame) with
/// `error while decoding MB 45 45` and `mmco: unref short failure`. So the
/// corruption is in the elementary stream and not in either player; the Panel
/// painted what arrived, and painted nothing rather than something invented.
/// The correlation is with the gap between teardown and relaunch: minutes gave
/// a good picture, ~40 s half a frame, 1.0-1.1 s nothing.
///
/// **What is inferred**, and the issue files it under "Mechanism hypothesis":
/// ring-mqtt transcodes Ring's *WebRTC* stream, where keyframes are not
/// periodic — an IDR at session start, and afterwards only on a PLI request,
/// which nothing in this chain can send. A consumer attaching a hair late
/// would join mid-GOP with no later keyframe to heal with, which is a story
/// that fits every row of the table. Nobody has read the bytes to confirm it.
/// The distinction matters here as it does in `live_video_mjpeg.dart` —
/// "attribution is inference; the timing is not" — because the fix is sized on
/// the timings, which are solid, and not on the story, which is not.
///
/// Either way the remedy is the same and needs no story to justify it: stop
/// relaunching. Nothing here inspects a picture — the Panel cannot tell a
/// corrupt frame from a good one, and a corrupt frame *is* a delivered frame.
/// All it does is stop the producer dying between two consumers who wanted the
/// same stream seconds apart. If the mechanism turns out to be something else
/// that is also cured by not restarting the producer, this is still the fix;
/// if it turns out not to be, the timings say the fix will simply not work,
/// and `video.stream_reused` is the line that will say so.
///
/// **Where it sits.** Above the seam, wrapping a [LiveVideoOpener] and handing
/// out [LiveVideoSession]s, so neither player knows it exists and neither
/// call site changed: `device_popup.dart` and `cameras/cameras_view.dart` both
/// already open through `VideoConfig.open` and close through
/// `LiveVideoSession.close`, which is the entire contract this needs. Rejected:
/// a linger inside each player, which would be the same logic written twice
/// and untestable on the branch that needs a browser; and rejected: a go2rtc
/// setting, because 1.9.10 has no such knob — `streams` stop on their last
/// consumer.
///
/// **Owned by `main()`**, one per process, and never disposed there: it holds
/// pooled sessions for as long as the Panel runs. `VideoConfig(open: …)`
/// defaults to the raw opener, so every hermetic widget test is unaffected —
/// a suite that closed a Popup would otherwise leave this class's Timer
/// pending and fail on it.
class LiveVideoKeepAlive {
  LiveVideoKeepAlive({
    this.opener = openLiveVideo,
    this.linger = kLiveVideoLinger,
    this.maxHeld = kLiveVideoMaxHeld,
  });

  /// The real opener this wraps — one of the two players behind the seam, or
  /// a fake. Named `opener` rather than `open` because [open] is what this
  /// class *offers*, and the two must not be confusable at a call site.
  ///
  /// Public, like `VideoConfig.open` one file over and for the same reason:
  /// it is the injection point, and a private one could not be handed a fake.
  final LiveVideoOpener opener;

  /// See [kLiveVideoLinger] and [kLiveVideoMaxHeld]. Constructor parameters
  /// rather than the constants read directly, exactly as
  /// `MjpegLiveVideoSession` does with its two timeouts and for its stated
  /// reason: this is the part of the change with real risk in it, and a class
  /// whose deadlines cannot be moved can be reasoned about but not
  /// interrogated. A test drives a two-minute cap without waiting two minutes.
  final Duration linger;
  final Duration maxHeld;

  /// What is up right now, held and kept alike — the set [dispose] walks.
  final _all = <_Kept>{};

  /// The kept sessions nobody is holding, by endpoint.
  ///
  /// Keyed by the whole URL rather than by the stream name: the name is what
  /// is safe to log, and the URL is what identifies an endpoint. Two go2rtc
  /// addresses serving a stream of the same name is not a configuration this
  /// Panel has, but handing one's producer to the other's consumer would be a
  /// silent wrong picture rather than a visible failure.
  ///
  /// At most one per endpoint, which is the invariant #177014 needs: a stream
  /// can never accumulate held Ring sessions.
  final _kept = <String, _Kept>{};

  /// Opens [url], or re-attaches to the session already running against it.
  ///
  /// The tear-off to hand to `VideoConfig(open: …)`, and it keeps
  /// [LiveVideoOpener]'s contract whole: **it may not throw**. Both real
  /// players already answer a settled `failed` session rather than raising,
  /// and this wrapper has to do the same — `device_popup.dart` catches a
  /// throw, but `cameras/cameras_view.dart` does not, so an exception let out
  /// of here would take the whole Cameras view down for one tile that could
  /// not dial.
  LiveVideoSession open(Uri url, {required String name}) {
    final key = url.toString();
    final kept = _kept.remove(key);
    if (kept != null) {
      kept.lingerTimer?.cancel();
      kept.lingerTimer = null;
      kept.inner.phase.removeListener(kept.watchWhileKept);
      kept.reuses++;
      // The line issue #1 had to be inferred from timings. `reuse=` is what
      // separates "the picture was good because it was the first of the day"
      // from "the picture was good because the producer never stopped".
      Log.info('video', 'stream_reused',
          {'name': name, 'reuse': kept.reuses, 'phase': kept.inner.phase.value.name});
      return kept.lease();
    }
    final LiveVideoSession inner;
    try {
      inner = opener(url, name: name);
      // Dialled but not pooled. Unreachable on the wall, where `dispose` is
      // never called — but a pool that is shutting down must not arm a
      // two-minute Timer nothing will ever cancel, which in a widget test is
      // a Timer outliving the tree and on any other host is a leak.
      if (_disposed) return inner;
    } catch (error) {
      // The type, never the message: the URL is the one string here that a
      // fat-fingered `GO2RTC_URL` can have put a password into, and a
      // `SyntaxError` quotes what it refused (`diagnostics/log.dart`:
      // **Never log a secret**). Returned unpooled — there is no producer to
      // keep and no `_Kept` to age out.
      return SettledLiveVideoSession(LiveVideoPhase.failed,
          failure: 'the opener threw ${error.runtimeType}');
    }
    final fresh = _Kept(this, key, name, inner);
    // Armed at the dial and never re-armed — that is the whole point of it,
    // in the same words `kDoorbellPopupCeiling` uses about its own.
    fresh.ageTimer = Timer(maxHeld, () => _ageOut(fresh));
    _all.add(fresh);
    return fresh.lease();
  }

  /// Whether [dispose] has run. After it, this pool keeps nothing: a consumer
  /// that lets go from here on has its session closed outright.
  ///
  /// Load-bearing rather than defensive. Consumers outlive this call by a
  /// frame or two — widgets are unmounted after the thing that owns them is
  /// torn down — and a release arriving in that gap would start a fresh
  /// linger Timer over a pool nobody will ever ask again, which is a held Ring
  /// session with no way back and, in a widget test, a Timer outliving the
  /// tree.
  var _disposed = false;

  /// Closes every session nobody is holding and cancels every Timer.
  ///
  /// A session a consumer still holds is left alone: that consumer closes its
  /// own, and closing it from here would blank a camera that is on screen.
  /// Its Timer is cancelled anyway — a pending Timer outliving the tree fails
  /// a widget test by itself, and on the wall it is a Panel shutting down still
  /// counting down over a Ring session.
  void dispose() {
    _disposed = true;
    for (final kept in _all.toList()) {
      kept.ageTimer?.cancel();
      kept.ageTimer = null;
      kept.lingerTimer?.cancel();
      kept.lingerTimer = null;
      if (kept.holder == null) _retire(kept, 'panel_stopped');
    }
    _kept.clear();
  }

  /// One consumer let go. Keep the session if it is worth keeping, close it
  /// if it is not.
  ///
  /// [holder] is checked by identity: a consumer that already let go can call
  /// `close` again — the Popup can be dismissed by three routes and its
  /// deadline can fire during the fourth — and a stale one must not evict
  /// whoever is holding the stream now.
  void _release(_Kept kept, _Lease holder) {
    if (kept.retired || kept.holder != holder) return;
    kept.holder = null;
    final phase = kept.inner.phase.value;
    // Nothing to keep. A `failed` session is a stream that is already dead,
    // and re-attaching to it would hand the next Popup the dead one instead
    // of the fresh one it would otherwise have dialled. An `unsupported` one
    // never touched the network at all, so there is no producer to hold —
    // and keeping it would turn `popup.stream_unsupported` into a line that
    // appears for the first Popup and never again.
    //
    // `unconfigured` is here for completeness rather than because a player
    // produces it: it means nothing was dialled at all, which is the same
    // "there is no producer to hold" as `unsupported`. Keeping the branch
    // costs a comparison and closes the gap a future third phase would open.
    //
    // `connecting` *is* kept, and that is the case issue #1 is mostly about:
    // go2rtc's on-demand transcode is itself a consumer and finishes spinning
    // up regardless (see `LiveVideoSession.close`), so a Popup dismissed after
    // a second has already paid for a producer nobody is now waiting for.
    if (_disposed ||
        kept.expired ||
        phase == LiveVideoPhase.failed ||
        phase == LiveVideoPhase.unsupported ||
        phase == LiveVideoPhase.unconfigured) {
      _retire(kept,
          _disposed ? 'panel_stopped' : (kept.expired ? 'too_old' : phase.name));
      return;
    }
    // One kept session per endpoint. Reachable: `device_popup.dart` keeps a
    // *list* of Popups per Device because two of them are a stack, so two
    // consumers can hold one stream at once and both let go. The newcomer
    // wins — it was in use more recently, so it is the likelier of the two to
    // still be healthy, and its age cap is the later one.
    final incumbent = _kept.remove(kept.key);
    if (incumbent != null) _retire(incumbent, 'superseded');
    // The pool's own guarantee, not the surface's diligence: a lingered
    // session is SILENT. The Popup that unmuted this stream is gone; the
    // next consumer starts from the seam's born-muted default and decides
    // for itself.
    kept.inner.setMuted(true);
    kept.lingerTimer = Timer(linger, () => _retire(kept, 'linger_expired'));
    // Both real players can fail with nobody listening — the MJPEG one on
    // `onDone`, the MSE one on a close frame — and their watchdogs keep
    // running while a session is kept. A kept session that died has to be
    // dropped rather than handed to the next opener.
    kept.inner.phase.addListener(kept.watchWhileKept);
    _kept[kept.key] = kept;
    Log.info('video', 'stream_kept',
        {'name': kept.name, 'phase': phase.name, 'for_s': linger.inSeconds});
  }

  /// The age cap came up. Drop it now if nobody is holding it; otherwise mark
  /// it so it is closed rather than kept the moment its consumer lets go.
  void _ageOut(_Kept kept) {
    kept.expired = true;
    if (kept.holder == null) _retire(kept, 'too_old');
  }

  void _retire(_Kept kept, String reason) {
    if (kept.retired) return;
    kept.retired = true;
    kept.ageTimer?.cancel();
    kept.ageTimer = null;
    kept.lingerTimer?.cancel();
    kept.lingerTimer = null;
    kept.inner.phase.removeListener(kept.watchWhileKept);
    if (identical(_kept[kept.key], kept)) _kept.remove(kept.key);
    _all.remove(kept);
    kept.inner.close();
    // Debug, not info: the ordinary case is a stream nobody came back for,
    // which is a Popup that was closed and stayed closed. `reason=` is what
    // makes it worth reading — `too_old` is the #177014 guarantee firing,
    // `failed` is a producer that died while it was being held for someone.
    Log.debug('video', 'stream_dropped',
        {'name': kept.name, 'reason': reason, 'reuses': kept.reuses});
  }
}

/// One go2rtc session and the pool's bookkeeping over it.
///
/// Distinct from the [_Lease] handed to a consumer because the two have
/// different lifetimes: a session outlives the consumer that opened it, by
/// [LiveVideoKeepAlive.linger] at least and by a whole chain of reopens at
/// most, and the identity of "who is holding this right now" is what makes a
/// stale `close` harmless.
class _Kept {
  _Kept(this.pool, this.key, this.name, this.inner);

  final LiveVideoKeepAlive pool;

  /// The endpoint, whole, and never logged: it is the value `GO2RTC_URL` was
  /// pasted into and it is allowed to carry credentials
  /// (`diagnostics/log.dart`: **Never log a secret**).
  final String key;

  /// The stream, which is the safe half and the half worth grepping for.
  final String name;

  final LiveVideoSession inner;

  /// The consumer holding it, or null while it is kept for whoever comes next.
  _Lease? holder;

  Timer? lingerTimer;
  Timer? ageTimer;

  /// Whether [LiveVideoKeepAlive.maxHeld] has passed since this was dialled.
  /// Set even while a consumer is holding it, because what it decides is
  /// whether the session may be kept *after* that consumer lets go.
  var expired = false;

  var retired = false;

  /// How many consumers re-attached to this one session. Logged, because
  /// "the producer never stopped" is otherwise indistinguishable from "the
  /// first open of the day was lucky" — which is exactly the ambiguity issue
  /// #1 had to resolve by hand.
  var reuses = 0;

  /// A method rather than a stored closure, and that is deliberate: an
  /// instance-method tear-off is identical across calls on the same object
  /// (Dart 2.15), so `removeListener` names the closure `addListener` was
  /// given. A fresh `() => …` per call would leave the listener attached
  /// forever and the pool holding a session it thinks it dropped.
  void watchWhileKept() {
    if (inner.phase.value == LiveVideoPhase.failed) {
      pool._retire(this, 'failed_while_kept');
    }
  }

  _Lease lease() => holder = _Lease(this);
}

/// What a consumer is handed: the running session's own phase, failure and
/// view, and a [close] that returns the session to the pool instead of
/// killing it.
///
/// A handle per consumer rather than the session itself, so that `close` is
/// idempotent *per consumer* — the contract [LiveVideoSession.close] states
/// and both real players keep — while the session underneath goes on serving
/// whoever comes next.
class _Lease implements LiveVideoSession {
  _Lease(this._kept);

  final _Kept _kept;
  var _closed = false;

  @override
  ValueListenable<LiveVideoPhase> get phase => _kept.inner.phase;

  @override
  String? get failure => _kept.inner.failure;

  /// The running session's own view, not a wrapper around it.
  ///
  /// Load-bearing for the fix rather than a shortcut: both players build this
  /// once and hand over something long-lived — a detached `<video>` element
  /// the MSE session owns and re-parents into each platform view, a painter
  /// bound to the MJPEG session's frame notifier. Handing a re-attaching
  /// consumer a fresh widget would tear the picture down and put it back,
  /// which is the cost this whole class exists to avoid.
  @override
  Widget get view => _kept.inner.view;

  @override
  void setMuted(bool muted) {
    if (_closed) return;
    _kept.inner.setMuted(muted);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _kept.pool._release(_kept, this);
  }
}
