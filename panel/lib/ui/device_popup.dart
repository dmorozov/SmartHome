import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../diagnostics/log.dart';
import '../domain/house.dart';
import 'audio/talk.dart';
import 'close_button.dart';
import 'device_presentation.dart';
import 'hub_controller.dart';
import 'idle_return.dart';
import 'popup_claim.dart';
import 'still_watching.dart';
import 'theme.dart';
import 'thermostat_controls.dart';
import 'video/camera_face.dart';
import 'video/snapshot.dart';
import 'video/stream_director.dart';
import 'video/timed_feed.dart';

/// Popup — a transient overlay on the Panel (CONTEXT.md). Cameras and the
/// doorbell show a live view from go2rtc; other Devices show their current
/// state. Which body and what wording are the presentation module's call,
/// not this file's.
///
/// [dismissAfter] is null for a Popup a person opened: a countdown would
/// yank the camera away from whoever deliberately went and tapped it. Only
/// the Popup that opened *unprompted* gets a deadline, and [PopupClaim] is
/// how a second reason to open it restarts that deadline instead of tearing
/// the stream down and paying the 2-5 s Ring spin-up again. [dismissCeiling] is how long that extending may go on for,
/// counted from when this Popup opened rather than from the last extension —
/// without it a reason arriving more often than [dismissAfter] keeps one
/// session alive forever.
///
/// [onGone] fires from the Popup's `dispose`, so by the time it runs the live
/// session really is closed. Rejected: the returned Future, which completes
/// when the pop is *requested*, ~150 ms earlier — long enough for a caller to
/// open a second consumer on a stream the first Popup still holds. It says
/// only "the Popup *I* pushed has gone"; [PopupClaim.acquire] is the one to
/// ask about a Device, whoever pushed what is showing it.
///
/// [controller] is the Popup's hands and its live feed, and it is optional
/// because only one body needs hands so far: with it, a thermostat gets its
/// setpoint controls (ThermostatControls); without it, every body renders
/// exactly what it rendered before the controls existed, from the one
/// [presentation] snapshot. Who omits it is not only tests: the doorbell
/// host holds a controller and deliberately passes none, because the only
/// Popups it pushes are video bodies, which never grow hands.
/// [snapshots] is the still face this Popup falls back to while live video has
/// not produced a picture — issue #1's third fix direction, and the only one
/// of the three that does not depend on winning a race the Panel cannot see.
/// Optional for the same reason [controller] is: a Device with no
/// `snapshot:` binding, and every hermetic test that stages a video body,
/// simply has none, and the Popup then says what it said before — see
/// [_LiveVideoBox].
///
/// [director] is the Stream Director this Popup's live view attaches to:
/// since 2026-08-28 that view is a MANAGED feed ([FeedRole.popup]) rather
/// than a hand-rolled copy of the dial dance beside it. Required, for every
/// body — a thermostat's never attaches, but the seam is one seam. On the
/// wall it is `main()`'s process-wide one; in a hermetic scene the fixture
/// builds it (`test/support/hermetic_director.dart`). There is no
/// Popup-built fallback: one would dial the same go2rtc and play the same
/// picture while Camera Health and the census silently stopped hearing
/// from it (measured by the 2026-09-02 review — every Popup test ran that
/// path).
Future<void> showDevicePopup(
  BuildContext context, {
  required DevicePresentation presentation,
  required StreamDirector director,
  HubController? controller,
  SnapshotConfig? snapshots,
  TalkConfig talk = const TalkConfig(),
  Duration? dismissAfter,
  Duration? dismissCeiling,
  VoidCallback? onGone,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black26,
    builder: (context) => _DevicePopupBody(
      presentation: presentation,
      director: director,
      talk: talk,
      controller: controller,
      snapshots: snapshots,
      dismissAfter: dismissAfter,
      dismissCeiling: dismissCeiling,
      onGone: onGone,
    ),
  );
}

/// How long a Popup **a person opened** stays up with nobody touching it
/// before it returns to the Dollhouse, releasing its go2rtc session.
///
/// D14 says a Popup somebody tapped a pin for gets no countdown, and that
/// stands: a countdown yanks the camera away from whoever went and asked for
/// it. This is not that. It bounds the *forgotten* case, and it was measured
/// happening — on 2026-08-10 a doorbell Popup left open in a browser tab held
/// a live Ring session while it pulled **357 MB**, unnoticed, until an
/// `/api/streams` dump found it. That is the leaked-`curl` incident
/// (`hub/talk-watchdog/README.md`) reached through the product rather than
/// through a debugging session, and nothing else in the stack closes it:
/// the watchdog watches `ring` and `mic`, not `ring_doorbell`, and go2rtc has
/// no consumer-kill endpoint at all.
///
/// Deliberately the same five minutes the Cameras view uses
/// (`kCamerasIdleReturn`), because it is the same trade for the same reason —
/// an open Ring session suppresses dings (#177014), and one tap per five
/// minutes is the price of holding one open on purpose. Not shared as a
/// single constant: the two surfaces have different lifetimes and a future
/// reason to diverge, and importing the Cameras view's vocabulary into the
/// Popup to save one `Duration` would be the wrong dependency.
const kDevicePopupIdleReturn = Duration(minutes: 5);

/// How long "Still watching?" is on screen before an unanswered prompt
/// returns the Popup. **Part of [kDevicePopupIdleReturn], not added to it.**
const kDevicePopupIdleWarning = Duration(seconds: 30);

/// The push-to-talk button's diameter, and the two numbers that decide where
/// it sits in the doorbell's video — the whole of the 2026-08-14 redesign,
/// drawn by the owner and settled in issue #2, which holds the sketch and the
/// A/B/C/D comparison the numbers came out of. Cited by issue rather than by
/// path: the sketch was a photo in the working tree and was never committed.
///
/// Public because they are a *contract between two widgets*, not a style: the
/// notch is carved by [_NotchClipper] out of the video box, the button is laid
/// out by [_DockedTalk] on top of it, and the two only read as one shape while
/// their numbers agree. A test that could not name them could only assert the
/// look through a golden, which anybody can re-bake to make green.
const kTalkButtonDiameter = 96.0;

/// The gap between the carved arc and the button's outer ring, so the card's
/// surface colour shows as an even collar around it.
const kTalkButtonMoat = 8.0;

/// How far **below** the video's bottom edge the button's centre sits.
///
/// Zero would be the sketch read literally — half the button over the picture.
/// This is variant D of the A/B/C/D prototype behind issue #2: 16 px lower, so
/// only a third of the button overlaps. A doorbell's frame is 1:1 and the
/// bottom of it is the ground at the door, which is where a parcel sits — the
/// one thing on that step somebody opens this Popup to look for. D removed the
/// least of it while keeping the full-size button and the sketch's centred
/// composition.
///
/// Its cost is height: D lands on exactly the 752 px a Dialog gets on the
/// 1280×800 wall, which is why [_kPopupGap] is 6 rather than the 12 and 8 the
/// gaps around the video used to be.
const kTalkButtonDrop = 16.0;

/// How far the button hangs below the video box, and therefore how much taller
/// than its picture the doorbell's video area is.
const _kTalkOverhang = kTalkButtonDiameter / 2 + kTalkButtonDrop;

/// The reserved line under the video — see [_DevicePopupBodyState._captionSlot].
const _kCaptionSlot = 22.0;

/// The gaps above and below the doorbell's video. Six, not twelve — see
/// [kTalkButtonDrop].
const _kPopupGap = 6.0;

/// The Dialog itself, stateful so that the live stream and the deadline have
/// somewhere to die.
///
/// Rejected: `showDevicePopup(...).then((_) => tearDown())`. `Route.popped`
/// completes when the pop is *requested*, ~150 ms before the subtree
/// unmounts, and it pairs a network resource's lifetime with a *call site* —
/// and there will be two call sites (a tap, and a doorbell ding). [dispose]
/// is the only hook that also runs when the route leaves without a pop:
/// `Navigator.removeRoute`, kiosk shutdown, the end of a widget test. All
/// three ways out — the Close button, the barrier (showDialog's
/// `barrierDismissible` defaults true and nothing here overrides it), and
/// the deadline's own `pop` — converge on the same unmount.
class _DevicePopupBody extends StatefulWidget {
  const _DevicePopupBody({
    required this.presentation,
    required this.director,
    required this.talk,
    required this.controller,
    required this.snapshots,
    required this.dismissAfter,
    required this.dismissCeiling,
    required this.onGone,
  });

  final DevicePresentation presentation;
  final StreamDirector director;
  final TalkConfig talk;
  final HubController? controller;
  final SnapshotConfig? snapshots;
  final Duration? dismissAfter;
  final Duration? dismissCeiling;
  final VoidCallback? onGone;

  @override
  State<_DevicePopupBody> createState() => _DevicePopupBodyState();
}

class _DevicePopupBodyState extends State<_DevicePopupBody>
    with SingleTickerProviderStateMixin
    implements PopupStayer {
  /// How often a Popup that could not pop itself tries again.
  ///
  /// A short fixed interval rather than a fresh [_DevicePopupBody.dismissAfter]:
  /// by the time this is used the deadline has already expired, so the
  /// question is no longer "how long may this stay up" but "how soon can we
  /// be rid of it", and the answer is "the moment whatever is stacked on top
  /// of us goes away".
  static const _retryDismiss = Duration(seconds: 1);

  /// This Popup's live view — a managed feed ([FeedRole.popup]) wearing the
  /// Popup's own clocks ([TimedFeed]). Null only on a body that shows no
  /// video; a video body whose stream cannot be dialled (no stream name, no
  /// go2rtc, a bad address) holds a feed settled at
  /// [FeedPhase.unconfigured], and the three are told apart in the log
  /// (`cameras.popup_skipped`), not on the wall.
  TimedFeed? _feed;

  /// The retry that replaces the deadline once it has expired against a
  /// route it may not pop — see [_dismiss]. Widget-owned, not [TimedFeed]'s:
  /// it times the ROUTE being obstructed, and an extension arriving while it
  /// pends must cancel it ([stayUp]).
  Timer? _dismissRetry;

  /// The idle bound's clockwork — see [kDevicePopupIdleReturn]. Shared with
  /// the Cameras view since 2026-09-03 (`ui/idle_return.dart`); what stays
  /// here is this Popup's own: its constants, its gate ([_boundsIdle], which
  /// most Popups fail), its pointer `Listener`, and its fire, which writes
  /// the line and hands over to [_dismiss] — how a route may pop is route
  /// mechanics and is deliberately not shared.
  ///
  /// Armed only where [_boundsIdle] says so, so on most Popups no timer of
  /// this module's ever runs.
  late final IdleReturn _idle;

  var _loggedBlockedDismiss = false;

  /// The last still this Popup managed to fetch, or null if it never did.
  ///
  /// One fetch, at open, and deliberately **no refresh timer**. A Popup lives
  /// for seconds — `kDoorbellPopupDeadline` puts an unprompted one at 30 s —
  /// so a second still would be a second picture of the same moment; and a
  /// periodic Timer inside a Dialog is the thing that hangs `pumpAndSettle` in
  /// every widget test that opens a camera, which is the same argument
  /// [_VideoNotice] makes about spinners. The Cameras view refreshes on a
  /// timer because its tiles sit there for minutes; this does not.
  Uint8List? _still;

  /// Whether this Popup is the one kind Ring actually offers two-way audio
  /// on. `deviceIcon` (theme.dart) has exactly one `DeviceKind.doorbell`, so
  /// this is the whole gate — a thermostat or a plain camera Popup never
  /// sees the bigger card or the button below.
  bool get _isDoorbell =>
      widget.presentation.device.kind == DeviceKind.doorbell;

  /// What the button and its caption may claim. Set once in [initState] to
  /// [TalkPhase.unconfigured] or [TalkPhase.idle] — whether this build was
  /// told where go2rtc is, and whether this Device has a `talk:` binding, are
  /// both knowable before anyone touches the glass.
  var _talk = TalkPhase.idle;

  /// The talk calls, chained so they reach go2rtc in the order the thumb made
  /// them.
  ///
  /// A press and a quick release are two calls a few milliseconds apart, and
  /// `POST src=` racing ahead of the `POST src=rtsp://…` it is meant to undo
  /// would leave the microphone open with nothing left to close it — the
  /// exact wedged-mic state `hub/talk-watchdog/` exists to catch, arrived at
  /// by the Panel's own hand. Chaining is cheaper than reasoning about the
  /// race, and stop is idempotent so a redundant link costs one 200.
  Future<void> _talkOps = Future.value();

  /// Which press a completing call belongs to. A START that returns after its
  /// own release must not light the button back up, and this is how a late
  /// answer knows it is stale.
  var _talkPress = 0;

  /// The clock behind the button's sweeping segment — the one phase that is a
  /// thing *in progress* rather than a settled state. Declared for every
  /// Popup (a mixin is per-class, not per-condition) but only ever started
  /// while go2rtc is being dialled, so a thermostat Popup pays nothing for it
  /// beyond one idle controller. See [_startTalking].
  ///
  /// Built in [initState], not as a `late final` field initializer: a field
  /// initializer runs lazily on first read, and for every non-doorbell
  /// Popup that first read used to be [dispose] itself — by which point the
  /// element is deactivated and `vsync: this` has nothing to look up.
  /// `initState` is the one place guaranteed to run exactly once, while the
  /// widget is still mounted.
  late final AnimationController _pulse;

  /// Opens the microphone at the door: one POST, per ADR-0011.
  ///
  /// The phase moves to [TalkPhase.opening] on the frame the thumb lands and
  /// only to [TalkPhase.open] when go2rtc has said 200. That gap is real —
  /// go2rtc has to dial Ring's backchannel — and the button spends it looking
  /// pressed rather than looking live. ADR-0007's rule that a reading which is
  /// not live may not be dressed as one applies to a control just as it does
  /// to the still photo below the video: nobody at the wall may be told their
  /// voice is reaching the porch until something has said so.
  ///
  /// Even [TalkPhase.open] claims no more than the status code backs — see
  /// [_TalkCaption], which says the microphone is open and stops there.
  void _startTalking() {
    final device = widget.presentation.device;
    final url = widget.talk.startUrl(device.talkStream);
    // Reachable, and the only thing standing in the way: the button is drawn
    // on every doorbell Popup, including the ones with no `talk:` binding and
    // no `GO2RTC_URL` — the layout is the doorbell's, and hiding the control
    // would leave nothing on screen to carry the caption that explains why it
    // cannot work. So a press on an unconfigured door lands here and stops
    // here, posting nothing.
    if (url == null) return;
    final press = ++_talkPress;
    // Half-duplex, ADR-0011's own mechanism: inbound playback is ducked
    // for as long as the button is held — intercoms want 30–40 dB of
    // separation before the far end stops hearing itself, and the wall's
    // speaker feeding the wall's microphone is exactly that loop.
    _feed?.setMuted(true);
    setState(() => _talk = TalkPhase.opening);
    // Started here rather than on success: the sweeping segment *is* the
    // opening phase, and that phase begins the moment the thumb lands. It is
    // stopped again below, whichever way go2rtc answers — `open` and `failed`
    // are both settled states and neither of them moves.
    _pulse.repeat();
    Log.debug('popup', 'talk_start', {'device': device.id});
    _talkOps = _talkOps
        .then((_) async {
          final result = await widget.talk.post(url);
          if (!result.ok) {
            // The status, never the URL: `talk.dart` keeps this to an HTTP code
            // or an exception's bare type name, because a fat-fingered
            // `GO2RTC_URL` can carry a password (log.dart: **Never log a
            // secret**).
            Log.warn('popup', 'talk_failed', {
              'device': device.id,
              'phase': 'start',
              'status': result.status,
            });
          }
          // A release that landed while this was in flight already queued its own
          // stop behind this link, so there is nothing to undo here — only a
          // stale answer to decline to render.
          if (!mounted || press != _talkPress) return;
          setState(() => _talk = result.ok ? TalkPhase.open : TalkPhase.failed);
          _pulse.stop();
          // Each link swallows its own faults rather than passing them down. A
          // `.then` chain propagates an error past every later link, so one
          // throw here — a poster breaking its no-throw contract, a `setState`
          // on a torn-down tree — would silently cancel the STOP queued behind
          // it and leave the microphone open. That is the one failure this
          // design exists to prevent, so it may not be reachable through a bug
          // in the link before it.
        })
        .catchError((Object error) {
          Log.warn('popup', 'talk_failed', {
            'device': device.id,
            'phase': 'start',
            'status': error.runtimeType.toString(),
          });
        });
  }

  /// Closes it again. Fired on release, on a cancelled gesture, and once more
  /// from [dispose] — liberally rather than carefully, because stop is
  /// idempotent (ADR-0011: 40/40 returning 200) and the thing it prevents is
  /// a doorbell left in live view. Not a battery cost — the Front Door is
  /// hardwired (`appliance/commissioning/05-devices-cloud.md`: no battery
  /// entity) — but HA core #177014 still stands: an open session can
  /// suppress a real ding, which is the failure nobody notices.
  void _stopTalking() {
    final device = widget.presentation.device;
    if (_talk == TalkPhase.unconfigured || _talk == TalkPhase.idle) return;
    ++_talkPress;
    // The other half of the duck: the button is up, listening resumes.
    _feed?.setMuted(false);
    _pulse.stop();
    // A failure stays on screen past the release that follows it. A press is
    // over in a moment, and a caption nobody has time to read reports the
    // fault to no one; the next press is what clears it.
    if (_talk != TalkPhase.failed) setState(() => _talk = TalkPhase.idle);
    Log.debug('popup', 'talk_stop', {'device': device.id});
    _queueStop(device.id);
  }

  /// The stop half, shared with [dispose] — which cannot `setState`, cannot
  /// await, and must still get the call out.
  void _queueStop(String deviceId) {
    final url = widget.talk.stopUrl(widget.presentation.device.talkStream);
    if (url == null) return;
    _talkOps = _talkOps
        .then((_) async {
          final result = await widget.talk.post(url);
          if (result.ok) return;
          // Worth a line even though nothing here can retry: the watchdog is the
          // backstop, and this is the log entry that explains why it had to be.
          Log.warn('popup', 'talk_failed', {
            'device': deviceId,
            'phase': 'stop',
            'status': result.status,
          });
          // Swallowed here for the reason the START link gives: a poisoned chain
          // is a stop that never fires.
        })
        .catchError((Object error) {
          Log.warn('popup', 'talk_failed', {
            'device': deviceId,
            'phase': 'stop',
            'status': error.runtimeType.toString(),
          });
        });
  }

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    // Decided here rather than on the first press: "nobody told the Panel
    // where go2rtc is" and "this door has no `talk:` binding" are both facts
    // knowable at open, and the caption is more use before the press than
    // after it. Same argument [LiveVideoPhase.unconfigured] makes one field
    // up.
    if (widget.talk.startUrl(widget.presentation.device.talkStream) == null) {
      _talk = TalkPhase.unconfigured;
    }
    _attachVideo();
    // The Popup is the person-opened surface, so it is the audible one —
    // the doorbell's LISTEN leg (ADR-0011) and every camera's, through
    // whichever transport carries sound (the web and MJPEG branches answer
    // with a no-op). Nothing to undo on the way out: the keep-alive pool
    // re-mutes every session it lingers, so the sound cannot outlive this
    // Popup whichever of its routes closes it.
    _feed?.setMuted(false);
    _fetchStill();
    // After [_attachVideo], because [_boundsIdle] asks whether a dial was
    // wanted at all.
    _idle = IdleReturn(
      returnAfter: kDevicePopupIdleReturn,
      warnFor: kDevicePopupIdleWarning,
      onFire: _fireIdle,
    )..prompting.addListener(_onPrompting);
    _rearmIdle();
    // Registered last, once nothing left in this method can throw. The claim
    // outlives every route and `dispose` never runs for a State whose
    // `initState` threw, so an entry claimed before the risky part outlives
    // the widget tree — the whole route stack with it — and nothing can ever
    // remove it. That Device's doorbell is then permanently deaf: every later
    // ding finds a defunct State where its Popup should be.
    popupClaim.register(widget.presentation.device.id, this);
  }

  /// The route this Popup rides on, taken while the element is healthy.
  ///
  /// Looked up here rather than from [stayUp] and the deadline's callbacks:
  /// `ModalRoute.of` is an inherited-widget lookup, and an element that has
  /// been deactivated answers it by throwing "Looking up a deactivated
  /// widget's ancestor is unsafe" rather than by returning null. That throw
  /// came out of `PopupClaim.acquire`, i.e. out of a Hub stream callback,
  /// where nothing catches it. Null means this Popup never got as far as
  /// riding a route, which is [_leaving] as far as anyone asking is
  /// concerned.
  ModalRoute<Object?>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    final id = widget.presentation.device.id;
    // First, where an entry left behind by a throw further down would leave
    // this Device permanently deaf. Anything the claim releases by this is
    // answered on the *next frame*, so the ordering that matters — nobody is
    // told the stream is free until it really is — is kept by the frame
    // boundary rather than by this statement's position.
    popupClaim.deregister(id, this);
    _dismissRetry?.cancel();
    _idle.prompting.removeListener(_onPrompting);
    _idle.dispose();
    // The one route out the gesture cannot cover. `onTapUp` and `onTapCancel`
    // between them catch a thumb that lifts or slides off, but a Popup can
    // also be dismissed *while held* — the barrier, the deadline's own pop,
    // kiosk shutdown — and every one of those unmounts this State with the
    // microphone open and no release ever coming. Fire-and-forget, chained
    // behind whatever is still in flight so it cannot overtake the START it
    // is undoing; `dispose` may not await, and the watchdog is the backstop
    // if the process dies before this lands.
    // Also from `failed`, and that is not belt-and-braces: a refused START is
    // not proof the producer never opened. go2rtc may have accepted the
    // microphone and had its answer lost to a timeout or a dropped socket,
    // which looks identical from here. Stop is idempotent, so the redundant
    // call this costs on a genuinely-failed press is one 200.
    if (_talk != TalkPhase.idle && _talk != TalkPhase.unconfigured) {
      ++_talkPress;
      _queueStop(id);
    }
    _pulse.dispose();
    // The one release, owed by every route out — [CameraFeed]'s contract.
    // The clocks die inside the [TimedFeed], the Director closes the
    // session and writes the one closed line (`cameras.popup_closed`, only
    // for a stream it said it opened), and the keep-alive below may linger
    // the socket.
    _feed?.release();
    // Last, so that whoever is waiting on it learns this Popup is gone only
    // once its go2rtc session really is closed. About the Popup *this* caller
    // pushed; a request waiting on the Device is the claim's to redeem, and
    // it knows a Popup still underneath this one means the stream is not free
    // yet.
    widget.onGone?.call();
    super.dispose();
  }

  /// Attaches this Popup's managed feed, when the body is a video one — the
  /// kind gate is the caller's ([CameraFeed]'s `attach` is the seam, not a
  /// policy engine for Devices that show no video).
  ///
  /// Everything `_openVideo` used to hand-roll here — the dial, the born
  /// verdict, the skip-with-reason line, the log-once failure, the
  /// close-by-every-route-out — is the Director's one copy of the dance now
  /// ([FeedRole.popup]), under the `cameras.popup_*` vocabulary. The
  /// clocks ride the feed as a [TimedFeed]: the deadline times the ROUTE,
  /// so it wraps the feed rather than widening the Director.
  ///
  /// `attach` never throws (its own contract, defending the same failure
  /// this widget's opener try/catch used to: a throw out of `initState`
  /// costs the whole Dialog and leaves this State registered-but-deaf), and
  /// on return `phase.value` is already the born truth — a settled verdict
  /// never fires a listener, so [_boundsIdle] may read it synchronously.
  void _attachVideo() {
    // A deadline on a body with no stream would have nothing to release and
    // no [TimedFeed] to live in; nothing pushes one today (the host's
    // Popups are all doorbells). Loud here so whoever first does knows
    // where the clocks live.
    assert(widget.dismissAfter == null || widget.presentation.isVideo,
        'a dismissAfter deadline rides the video feed (TimedFeed)');
    if (!widget.presentation.isVideo) return;
    _feed = TimedFeed(
      widget.director.attach(widget.presentation.device, role: FeedRole.popup),
      deadline: widget.dismissAfter,
      ceiling: widget.dismissCeiling,
      onDeadline: _dismiss,
      onCeiling: _onCeiling,
    );
  }

  /// Fetches the Device's still, if it has one and anybody said where the Hub
  /// is.
  ///
  /// **Costs no Ring session**, which is the whole reason this is allowed to
  /// exist beside a doorbell that HA #177014 says must not be kept open: it is
  /// an HA `camera_proxy` GET for the JPEG the Hub already holds, never a
  /// frame-grab through go2rtc — [SnapshotConfig.urlFor] states that property
  /// and the Cameras view's off state is built on it.
  ///
  /// Fired from `initState` regardless of the live session's phase, and not
  /// only once the stream has failed. A still that starts loading when the
  /// picture is already known to be broken arrives after the moment somebody
  /// wanted it; the point is to have it in hand *before* the 6 s decode
  /// deadline is up.
  Future<void> _fetchStill() async {
    final snapshots = widget.snapshots;
    final entity = widget.presentation.device.snapshotEntityId;
    if (snapshots == null || entity == null) return;
    final url = snapshots.urlFor(entity);
    if (url == null) return;
    final result = await snapshots.fetch(url, token: snapshots.token);
    // A Popup can be dismissed by three routes and the deadline can fire
    // during the fourth, and this await outlives all of them.
    if (!mounted) return;
    if (result.bytes == null) {
      // `status` is an HTTP code or an exception's bare type name — never
      // exception text, which embeds the request URL, and this request carries
      // the Hub token in its headers (`snapshot.dart`).
      Log.warn('popup', 'snapshot_failed', {
        'entity': entity,
        'status': result.status,
      });
      return;
    }
    setState(() => _still = result.bytes);
  }

  /// Answers [PopupClaim] for this Popup.
  @override
  StayVerdict stayUp() {
    if (_leaving) return StayVerdict.leaving;
    if (widget.dismissAfter == null) return StayVerdict.held;
    final feed = _feed;
    // Past the ceiling this Popup is on its way out and no longer extendable,
    // which is the same thing to a caller as one already popping. No feed at
    // all with a deadline set is the configuration [_attachVideo] asserts
    // against; answered as leaving rather than lied about as extended.
    if (feed == null || feed.ceilingReached) return StayVerdict.leaving;
    // An extension resets the whole dismissal state: a blocked-dismiss retry
    // still pending must not fire against the deadline this just restarted —
    // the old single-field arrangement cancelled it implicitly, and that was
    // a behaviour, not an accident.
    _dismissRetry?.cancel();
    _dismissRetry = null;
    feed.extend();
    return StayVerdict.extended;
  }

  /// Whether this Popup's route has left the Navigator's history — a pop
  /// somebody has already requested, ours or a hand on the glass — even
  /// though the subtree is still up for the ~150 ms of the exit animation.
  ///
  /// `isActive`, not `isCurrent`: a route stacked *on top of* us leaves us
  /// active but not current, and that is a Popup still very much on the wall
  /// with a live session behind it.
  ///
  /// Reads the route captured in [didChangeDependencies] rather than looking
  /// one up: see [_route] for why a lookup from here can throw instead of
  /// answering.
  bool get _leaving {
    if (!mounted) return true;
    final route = _route;
    return route == null || !route.isActive;
  }

  /// Whether this Popup owes anyone an idle bound.
  ///
  /// Two conditions, and both are the point:
  ///
  /// - **`dismissAfter == null`** — a Popup opened by a ding already has a
  ///   deadline and a ceiling. Adding a second clock would give it two
  ///   answers to one question.
  /// - **a dial was wanted** — the bound exists to release a go2rtc session,
  ///   so a Popup that never dialled has nothing to release. A thermostat
  ///   Popup left open costs nothing and is closed by the person who opened
  ///   it; timing it out would be tidiness dressed as safety.
  ///
  /// Keyed on the feed's born verdict rather than on the Device's kind, for
  /// the reason the old `_session != null` was: "did this Popup dial
  /// something" is the question that matters, and it stays correct on its
  /// own if a future kind grows or loses a live view.
  /// [FeedPhase.unconfigured] is exactly the old null session — no stream
  /// name, no go2rtc, a bad address — and it is a settled verdict: a feed
  /// never crosses that boundary in either direction after birth, so this
  /// getter cannot change its answer mid-life.
  bool get _boundsIdle =>
      widget.dismissAfter == null &&
      _feed != null &&
      _feed!.phase.value != FeedPhase.unconfigured;

  /// Restarts the idle bound. Called once at open and on every touch.
  void _rearmIdle() {
    if (!_boundsIdle) return;
    // A touch resets the WHOLE dismissal state, a pending blocked-dismiss
    // retry included: an idle return that fired against an obstructed route
    // must not outlive the answer to its own prompt — the person tapped
    // "still watching" and then lost the Popup a second later to a timer
    // from before they answered (found in review, 2026-08-28). [stayUp]
    // keeps the same rule for extensions.
    _dismissRetry?.cancel();
    _dismissRetry = null;
    // The tap that answers the prompt needs no special case: it re-arms like
    // any other, and the module clearing its own flag is what takes the
    // prompt away.
    _idle.rearm();
  }

  void _onPrompting() {
    if (mounted) setState(() {});
  }

  /// The unanswered prompt's verdict.
  ///
  /// Logged before the attempt, not after: [_dismiss] may find the route
  /// obstructed and retry, and a line written only on success would make a
  /// Popup that took three tries look like one that never fired.
  void _fireIdle() {
    if (!mounted) return;
    Log.info('popup', 'idle_return', {
      'device': widget.presentation.device.id,
      'reason': 'unanswered',
    });
    _dismiss();
  }

  /// The ceiling fired inside the [TimedFeed] — it has already stopped the
  /// deadline; what is left is the route's business.
  void _onCeiling() {
    // Its own line, and at info: this is the only evidence that something
    // kept re-arming the deadline for the entire ceiling — a visitor leaning
    // on the button, or an entity chattering — and it is the one dismissal
    // the Panel *can* name a reason for, unlike `popup.doorbell_dismissed`.
    Log.info('popup', 'deadline_ceiling', {
      'device': widget.presentation.device.id,
      // Non-null by [TimedFeed]'s own arming rule: no ceiling timer without
      // both durations.
      'open_s': widget.dismissCeiling!.inSeconds,
    });
    _dismiss();
  }

  void _dismiss() {
    // The timer outlives nothing and nobody, so every assumption gets
    // checked. `mounted` alone is not enough: it stays true through the
    // ~150 ms a route takes to exit.
    if (!mounted) return;
    final route = _route;
    // Already on its way out — a hand on the glass beat the deadline to it by
    // a frame. Nothing left to do, and nothing left to re-arm for.
    if (route == null || !route.isActive) return;
    if (!route.isCurrent) {
      // Something is stacked on top of us, so popping would pop *that*: this
      // Popup only ever pops itself. But the deadline is a one-shot Timer,
      // and simply returning leaves it spent — the Popup then has no deadline
      // at all and holds its go2rtc session until a human intervenes, the one
      // failure here with no symptom anywhere. So re-arm, say so once, and
      // keep trying until the way out is clear. The ceiling is still running
      // underneath and no extension can reach past it.
      if (!_loggedBlockedDismiss) {
        _loggedBlockedDismiss = true;
        Log.warn('popup', 'dismiss_blocked', {
          'device': widget.presentation.device.id,
          'retry_s': _retryDismiss.inSeconds,
        });
      }
      _dismissRetry?.cancel();
      _dismissRetry = Timer(_retryDismiss, _dismiss);
      return;
    }
    // Through the route rather than `Navigator.of(context)`, for the reason
    // in [_route]: this runs from a Timer, and an inherited lookup is the one
    // thing here that can throw instead of answering. `isCurrent` above is
    // what makes this pop *this* Popup.
    route.navigator?.pop();
  }

  /// The body under the name row: live video for the video kinds, setpoint
  /// controls for a thermostat that came with hands, one status sentence for
  /// everything else. The kind decides — never the live state's shape, which
  /// lapses routinely and must not reshape a Popup somebody is looking at.
  Widget _body() {
    final presentation = widget.presentation;
    if (presentation.isVideo) {
      return _LiveVideoBox(
        // Non-null for every video body — [_attachVideo] attaches
        // unconditionally behind the same [DevicePresentation.isVideo] gate
        // this branch reads.
        feed: _feed!,
        still: _still,
        // A doorbell is the only kind with a microphone to dock, so it is the
        // only kind whose box is carved for one — and the only one whose 4:3
        // is right, its frame being natively 1:1.
        docked: _isDoorbell,
      );
    }
    final controller = widget.controller;
    if (controller != null &&
        specOf(presentation.device.kind).family == StateFamily.thermostat) {
      return ThermostatControls(
        controller: controller,
        device: presentation.device,
      );
    }
    return Text(
      presentation.statusText,
      style: const TextStyle(fontSize: 15, color: PanelTheme.ink),
    );
  }

  /// The one line under the video, and the fixed space it lives in.
  ///
  /// **Reserved even when empty**, and that is the point: the talk caption
  /// comes and goes with the phase (see [_TalkCaption]) and the idle prompt
  /// appears 30 s before the Popup would close itself, so a slot that hugged
  /// its contents would resize the card under a thumb — growing on the frame
  /// the microphone opens, shrinking on release, moving the button somebody is
  /// still pressing. 22 px of white space is the cheaper of the two.
  ///
  /// One slot for both, because only one of them ever has anything to say at
  /// once: the idle prompt belongs to a Popup a person opened and left alone,
  /// and nobody who is holding the microphone down is idle. The prompt wins if
  /// they ever do collide — it is the one with a consequence attached.
  ///
  /// Present on any Popup that opened a stream rather than on the doorbell
  /// alone: a plain camera has no caption but it does get the idle prompt, and
  /// its card must not jump either.
  Widget _captionSlot() {
    final Widget child;
    if (_idle.prompting.value) {
      child = const StillWatching.caption(
          key: ValueKey('popup-idle-prompt'));
    } else if (_isDoorbell && _TalkCaption.wordingFor(_talk) != null) {
      child = _TalkCaption(_talk);
    } else {
      child = const SizedBox.shrink();
    }
    return SizedBox(
      height: _kCaptionSlot,
      child: Center(child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    final presentation = widget.presentation;
    final device = presentation.device;
    final isLocal = device.connectivity == Connectivity.local;
    // The doorbell is the one Popup with somewhere to grow into: it is the
    // only kind Ring offers two-way audio on, so it is the only one that
    // gains a button — and the bigger card below is sized for that button,
    // not decoration for its own sake. Every other kind renders exactly the
    // numbers it always has.
    final isDoorbell = _isDoorbell;
    final avatarSize = isDoorbell ? 64.0 : 44.0;
    final nameSize = isDoorbell ? 24.0 : 17.0;
    final subtitleSize = isDoorbell ? 14.0 : 12.0;
    final header = Row(
      children: [
        Container(
          width: avatarSize,
          height: avatarSize,
          decoration: BoxDecoration(
            color: PanelTheme.surfaceRaised,
            shape: BoxShape.circle,
            boxShadow: PanelTheme.raised(8),
          ),
          child: Center(
            child: Icon(
              deviceIcon(device.kind),
              color: PanelTheme.ink,
              size: isDoorbell ? 30 : null,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                device.name,
                style: TextStyle(
                  fontSize: nameSize,
                  fontWeight: FontWeight.w700,
                  color: PanelTheme.ink,
                ),
              ),
              Text(
                isLocal ? 'Local Device' : 'Cloud Device',
                style: TextStyle(
                  fontSize: subtitleSize,
                  color: isLocal
                      ? const Color(0xFF4CAF7D)
                      : PanelTheme.inkFaint,
                ),
              ),
            ],
          ),
        ),
        // Top-right of the header row, which never scrolls — that is what
        // makes "the way out is always reachable" true by construction rather
        // than guarded, after a `Close` text button at the bottom of the card
        // spent years being the thing that scrolled out of reach.
        PanelCloseButton(
          key: const ValueKey('popup-close'),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
    // The one thing that can grow tall: the picture, plus — on a doorbell —
    // the button docked into its bottom edge. The caption slot is deliberately
    // *not* in here; see [content].
    final Widget middle = isDoorbell
        ? _DockedTalk(
            video: _body(),
            phase: _talk,
            pulse: _pulse,
            onStart: _startTalking,
            onStop: _stopTalking,
          )
        : _body();
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        SizedBox(height: isDoorbell ? _kPopupGap : 18),
        // Doorbell only: the bigger card is tall enough to outgrow a short
        // window (a resized dev browser, a widget test's default surface),
        // and — measured — it now lands within 8 px of the Panel's real
        // 1280×800 once the header, the two gaps around the video, the
        // button's overhang and the caption slot are all accounted for. That
        // margin is what [kTalkButtonDrop] spent and [_kPopupGap] bought
        // back. `Flexible` + a scroll view makes the remainder harmless: the
        // last few px of the picture scroll under the fold on the tightest
        // windows rather than throwing a render overflow. Every other kind is
        // unchanged — its card has never come close to overflowing, so it
        // keeps hugging its content exactly as before.
        if (isDoorbell)
          Flexible(child: SingleChildScrollView(child: middle))
        else
          middle,
        // Outside the scrollable region on purpose, and it is the last thing
        // left that needs to be: a prompt scrolled under the fold is a prompt
        // nobody can answer, and the answer is the difference between the
        // view staying and going. Close no longer needs the same protection —
        // it lives in [header] now, which never scrolls at all.
        if (presentation.isVideo) ...[
          const SizedBox(height: _kPopupGap),
          _captionSlot(),
        ],
      ],
    );
    return Dialog(
      backgroundColor: PanelTheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isDoorbell ? 760 : 420),
        child: Listener(
          // A stable handle for the card itself. `find.byType(Dialog)` is not
          // one: Material's `insetPadding` puts the Dialog's rect outside the
          // visible surface, so a test aiming at "just inside the card" by
          // that rect lands on the barrier instead.
          key: const ValueKey('popup-card'),
          // Any touch anywhere is "still watching". A [Listener], not a
          // [GestureDetector]: listeners never enter the gesture arena, so
          // this cannot compete with — or steal a press from — the
          // push-to-talk button inside it.
          // `opaque`, not `deferToChild`, because the prompt says "tap
          // anywhere" and that has to be true: the padding around the card's
          // contents and the gaps between rows are the easiest places for a
          // thumb to land, and none of them hold a child that hit-tests.
          // Opaque still hit-tests children first, so nothing inside loses
          // its events — see the push-to-talk case in the suite.
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => _rearmIdle(),
          child: Padding(padding: const EdgeInsets.all(24), child: content),
        ),
      ),
    );
  }
}

/// The doorbell's picture with its microphone docked into the notch cut out
/// of the bottom edge.
///
/// Two separately positioned widgets that have to read as one shape: the hole
/// is carved by [_NotchClipper] inside [_VideoFrame], the button is laid out
/// here, and neither knows about the other except through [kTalkButtonDrop]
/// and [kTalkButtonMoat]. `device_popup_test.dart`'s `the docked microphone`
/// group is what keeps them agreeing.
///
/// The [Stack] takes its height from the padded video, so the picture's own
/// aspect ratio still decides how tall this is; [_kTalkOverhang] is the strip
/// below it the button hangs into. `Positioned.fill` + [Align] rather than a
/// [Positioned] with a bottom offset, because a Positioned with no height
/// gives its child unbounded vertical constraints — which a [Center] answers
/// by throwing.
class _DockedTalk extends StatelessWidget {
  const _DockedTalk({
    required this.video,
    required this.phase,
    required this.pulse,
    required this.onStart,
    required this.onStop,
  });

  final Widget video;
  final TalkPhase phase;
  final AnimationController pulse;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Stack(
      // The button's face fits its own box, but [PanelTheme.raised]'s soft
      // shadows reach past it — see [_PushToTalkButton].
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: _kTalkOverhang),
          child: video,
        ),
        Positioned.fill(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: _PushToTalkButton(
              phase: phase,
              pulse: pulse,
              onStart: onStart,
              onStop: onStop,
            ),
          ),
        ),
      ],
    );
  }
}

/// The bite taken out of the video's bottom edge for the microphone.
///
/// The circle is centred [kTalkButtonDrop] *below* the box, so what it removes
/// is a shallow arc rather than a half-moon — variant D of issue #2's
/// comparison. Its radius clears the button by [kTalkButtonMoat] on every
/// side, which is what makes the card's surface colour read as a collar around
/// the button instead of the picture running up against its ring.
///
/// Carved on every doorbell Popup, including the ones showing the unconfigured
/// or failed placeholder: the button is drawn there too (see [_startTalking]),
/// and a notch that came and went with go2rtc's health would make the card's
/// shape a status display.
class _NotchClipper extends CustomClipper<Path> {
  const _NotchClipper();

  @override
  Path getClip(Size size) {
    final frame = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(16)),
      );
    final bite = Path()
      ..addOval(
        Rect.fromCircle(
          center: Offset(size.width / 2, size.height + kTalkButtonDrop),
          radius: kTalkButtonDiameter / 2 + kTalkButtonMoat,
        ),
      );
    return Path.combine(ui.PathOperation.difference, frame, bite);
  }

  @override
  bool shouldReclip(_NotchClipper oldClipper) => false;
}

/// The Popup's video body: a picture, or the honest reason there isn't one.
///
/// Reads the feed's [FeedPhase] — the managed vocabulary — never a
/// [LiveVideoPhase]: the Director's own rule since the Popup became its
/// third surface. [FeedPhase.unconfigured] means nothing was dialled, which
/// renders exactly what this Popup rendered before go2rtc existed — same
/// box, same icon, same sentence. That is not nostalgia:
/// `test/golden/goldens/device_popup.png` pins those pixels, and changing
/// this body means re-baking that golden on purpose — in the devcontainer
/// only, the canonical golden host (ADR-0009) — not as a side effect of a
/// video change.
class _LiveVideoBox extends StatefulWidget {
  const _LiveVideoBox({
    required this.feed,
    required this.docked,
    this.still,
  });

  final CameraFeed feed;

  /// Whether this box is a doorbell's: 4:3 with a notch in the bottom edge,
  /// rather than a plain camera's 16:9 rounded rectangle.
  final bool docked;

  /// The Device's last still, or null when it has no `snapshot:` binding, no
  /// Hub address, or the fetch has not landed yet.
  final Uint8List? still;

  @override
  State<_LiveVideoBox> createState() => _LiveVideoBoxState();
}

class _LiveVideoBoxState extends State<_LiveVideoBox> {
  /// The shared core of the not-live face — whether a picture was ever up
  /// in this box's life, and whether the wait it is in is a restoration
  /// (**"re-" claims one**: ADR-0007's rule applied to a verb). One copy for
  /// the Popup, the tile and the zoom since 2026-09-02 (`camera_face.dart`);
  /// it reads the born phase and listens to both of the feed's notifiers,
  /// so this box no longer keeps a latch of its own. What stays here is the
  /// Popup's own phrase table, below.
  late final CameraFace _cameraFace = CameraFace(widget.feed);

  @override
  void initState() {
    super.initState();
    _cameraFace.addListener(_onFace);
  }

  @override
  void dispose() {
    // The feed outlives this box by a frame — the Popup releases it in its
    // own dispose — so the face's listeners come off the feed here.
    _cameraFace.dispose();
    super.dispose();
  }

  void _onFace() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return _VideoFrame(
      docked: widget.docked,
      child: _body(_cameraFace.phase),
    );
  }

  Widget _body(FeedPhase phase) {
    if (phase == FeedPhase.playing) {
      // Read fresh inside the build, the feed's own contract: the view
      // changes identity across re-dials.
      return widget.feed.view;
    }
    // The ladder's own word, and it is only honest over a picture that was
    // up (2026-08-28, the phase-2 flip; the Cameras view says the same
    // thing about the same phases) — the face's verdict, not this box's. A
    // camera Popup climbs 5/15/60 like the zoom, so `retrying` is a wait
    // between dials, not a verdict — the verdict words below belong to the
    // phases nothing is coming back from.
    final reconnecting = _cameraFace.reconnecting;
    final text = switch (phase) {
      FeedPhase.unconfigured => 'Live view placeholder — go2rtc stream',
      // `idle` is a policy phase the popup role never wears: it is
      // person-origin from birth and dials at attach. `queued` it CAN wear —
      // its ladder re-dials take admission (`_requestDial(ladder: true)` in
      // the Director) and park there behind an armed gate or a full cap —
      // and the face's verdict keeps the ladder's own word through that
      // wait (2026-09-02; this table used to drop to "Connecting" for it).
      // Both arms are armed rather than left to throw, so the face stays
      // truthful on the day a trait flips before its copy lands.
      FeedPhase.idle ||
      FeedPhase.queued ||
      FeedPhase.retrying ||
      FeedPhase.connecting ||
      FeedPhase.playing => reconnecting
          ? 'Reconnecting to the camera…'
          : 'Connecting to the camera…',
      // `failed` and `unsupported` read the same on the wall on purpose.
      // What differs is who has to fix it — an operator with a go2rtc
      // problem, or nobody at all on a build that cannot play video — and
      // that person is reading journald, not standing in the hall. What the
      // wall owes them is that there is no picture, said plainly instead of
      // shown as a black rectangle they would stand there waiting on.
      // `offline` — Camera Health's verdict, which the health-blind popup
      // role never wears — joins them as the same plain fact.
      FeedPhase.offline ||
      FeedPhase.failed ||
      FeedPhase.unsupported => 'Live view unavailable',
    };
    final icon = switch (phase) {
      FeedPhase.offline ||
      FeedPhase.failed ||
      FeedPhase.unsupported => Icons.videocam_off,
      _ => Icons.videocam,
    };
    final still = widget.still;
    if (still == null) return _VideoNotice(icon: icon, text: text);
    // **The still is shown, and it is never shown silently.** This is issue
    // #1's honest fallback: when ring-mqtt's restream is relaunching, the
    // browser decodes no frame and there is nothing live to draw — but the Hub
    // is holding a real photograph of the front door from a minute ago, and on
    // a doorbell that is most of what somebody standing at the Panel wanted.
    //
    // The caption is not decoration. ADR-0007's rule is that a reading which
    // is not live may not be dressed as one, and a still of a porch is
    // indistinguishable from a live view of the same porch — that is exactly
    // what makes it useful and exactly what makes it a lie unlabelled. So the
    // phase's own sentence stays on screen, over the picture rather than
    // instead of it, and "Still" names what is being looked at.
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.memory(still, fit: BoxFit.contain, gaplessPlayback: true),
        Align(
          alignment: Alignment.topCenter,
          child: _StillCaption(text: text),
        ),
      ],
    );
  }
}

/// The band that says a picture is a still and why there is no live one.
///
/// Full width over a scrim: the Popup's box pillarboxes a 1:1 doorbell frame,
/// so a floating badge would sometimes land on the picture and sometimes on
/// the black, and the one thing this may not do is become hard to read over
/// the wrong porch.
///
/// **Top edge, not bottom** — moved there by the 2026-08-14 redesign (issue
/// #2), because the bottom edge is where the notch and the microphone are now.
/// A band the notch bit a hole through would be the least acceptable casualty
/// of the redesign: ADR-0007's rule is that a reading which is not live may
/// not be dressed as one, and a still of a porch is indistinguishable from a
/// live view of the same porch. This sentence is the only thing telling them
/// apart, so it is the one thing on the picture that may not be obscured.
class _StillCaption extends StatelessWidget {
  const _StillCaption({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Colors.black54,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.photo_camera_back, color: Colors.white70, size: 14),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'Still · $text',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// The rounded box every video body renders inside.
///
/// Two shapes. A plain camera keeps the 16:9 rectangle it has always had. A
/// doorbell gets **4:3 with a notch** — 4:3 because a Ring frame is natively
/// 1:1, so 16:9 spent a third of the box on black pillars, and the notch
/// because that is where the microphone docks (issue #2).
///
/// Keyed, because the redesign's invariants are relations *between* this box
/// and the button ([_DockedTalk]) and between this box and the still's caption
/// band ([_StillCaption]) — none of which can be asserted without a handle on
/// the picture's own rect.
class _VideoFrame extends StatelessWidget {
  const _VideoFrame({required this.child, required this.docked});

  final Widget child;
  final bool docked;

  @override
  Widget build(BuildContext context) {
    final box = AspectRatio(
      aspectRatio: docked ? 4 / 3 : 16 / 9,
      child: ColoredBox(color: const Color(0xFF2A2F3E), child: child),
    );
    return KeyedSubtree(
      key: const ValueKey('popup-video'),
      child: docked
          ? ClipPath(clipper: const _NotchClipper(), child: box)
          : ClipRRect(borderRadius: BorderRadius.circular(16), child: box),
    );
  }
}

/// An icon and one sentence, centred in the frame. Never a spinner: a
/// [CircularProgressIndicator] never settles, so `pumpAndSettle` would hang
/// every widget test that opens a camera — and a wall panel spinning
/// forever tells whoever walks past exactly as much as a blank one.
class _VideoNotice extends StatelessWidget {
  const _VideoNotice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white38, size: 40),
          const SizedBox(height: 8),
          Text(
            text,
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// The doorbell Popup's push-to-talk control: a call-style circular button
/// with a pulsing ring while held, docked into the video's bottom edge by
/// [_DockedTalk].
///
/// The pick from an A/B/C/D throwaway prototype comparison. The prototype
/// itself was never committed and was deleted once D won, so it left no
/// trace to point to — issue #2 holds the comparison table, and what is here
/// plus [kTalkButtonDrop] is the rest of the record. A's bigger card, kept,
/// with B's circular mic swapped in for A's full-width pill. [pulse] is owned
/// by the caller, not this widget: it lives beside [phase] in
/// [_DevicePopupBodyState] so a rebuild here (the ring's own
/// `AnimatedBuilder`) never restarts or re-creates the ticker driving it.
///
/// **Five looks, one per phase, and the border is what carries them.** The
/// body is the owner's neumorphic reference (`docs/button.png`, 2026-08-14):
/// a flat outer rim in the card's own grey with a raised inner disc, lit from
/// the top-left like everything else the Panel draws. The reference's thin
/// dark arc is promoted from decoration to the **state channel**, because
/// after the same redesign dropped the resting caption there is no text under
/// the button in the ordinary case, so the button owes the wall the whole
/// answer by itself:
///
/// | phase          | ring                        | glyph      |
/// |----------------|-----------------------------|------------|
/// | `unconfigured` | faint grey, thin            | `mic_none` |
/// | `idle`         | accent blue, thin           | `mic_none` |
/// | `opening`      | blue **segment, sweeping**  | `mic`      |
/// | `open`         | red, **thick**              | `mic`      |
/// | `failed`       | red, thin, **broken**       | `mic_off`  |
///
/// Only `opening` moves, and that is deliberate: it is the one phase that is
/// a thing *in progress* rather than a settled state, and it is exactly the
/// gap ADR-0007 says may not be dressed up — go2rtc has been asked and has
/// not answered, so the control may look busy but not live.
///
/// **`failed` is broken-and-`mic_off` rather than simply red**, which is the
/// one thing here the A/B/C/D comparison did not settle. A solid red ring in
/// both `open` and `failed` would put a refused microphone and a live one in
/// the same clothes — the most consequential confusion this control can
/// produce, and the exact shape ADR-0007 forbids. The gap and the struck-
/// through glyph cost nothing and cannot be misread.
///
/// The chosen face from a four-variant throwaway prototype (issue #3): A over
/// B (press-to-inset), C (recessed well) and D (rim-lit ring). B, C and D each
/// left `unconfigured`, `idle` and `failed` visually identical, which the
/// caption used to cover for and no longer does.
///
/// The whole face fits inside [kTalkButtonDiameter] — the ring is inset, not
/// overflowing — so the old expanding halo, and the ~14 px of red it used to
/// spill onto the picture, are both gone. `Clip.none` stays only because
/// [PanelTheme.raised]'s soft shadows still reach past the box.
class _PushToTalkButton extends StatelessWidget {
  const _PushToTalkButton({
    required this.phase,
    required this.pulse,
    required this.onStart,
    required this.onStop,
  });

  final TalkPhase phase;
  final AnimationController pulse;
  final VoidCallback onStart;
  final VoidCallback onStop;

  /// Whether a thumb is on the glass — press feedback, and nothing about
  /// whether a microphone is open.
  bool get _held => phase == TalkPhase.opening || phase == TalkPhase.open;

  /// The fault red, shared with [_TalkCaption]. Not a collision: the caption
  /// and the ring are saying the same thing about the same phase.
  static const _fault = Color(0xFFE05252);

  Color get _ringColour => switch (phase) {
    TalkPhase.open || TalkPhase.failed => _fault,
    TalkPhase.opening => PanelTheme.accent,
    TalkPhase.idle => PanelTheme.accent.withValues(alpha: .75),
    TalkPhase.unconfigured => PanelTheme.inkFaint.withValues(alpha: .3),
  };

  IconData get _glyph => switch (phase) {
    // Struck through, and only here: a microphone go2rtc refused is the
    // one phase where the control looks like the live one otherwise.
    TalkPhase.failed => Icons.mic_off,
    _ => _held ? Icons.mic : Icons.mic_none,
  };

  Color get _glyphColour => switch (phase) {
    TalkPhase.open => _fault,
    TalkPhase.unconfigured => PanelTheme.inkFaint.withValues(alpha: .5),
    _ => PanelTheme.ink,
  };

  @override
  Widget build(BuildContext context) {
    const d = kTalkButtonDiameter;
    final opening = phase == TalkPhase.opening;
    return GestureDetector(
      key: const ValueKey('push-to-talk'),
      onTapDown: (_) => onStart(),
      onTapUp: (_) => onStop(),
      onTapCancel: onStop,
      child: SizedBox(
        width: d,
        height: d,
        child: Stack(
          alignment: Alignment.center,
          // Only for [PanelTheme.raised]'s shadows, which reach past the box.
          clipBehavior: Clip.none,
          children: [
            // The outer rim: the card's own colour, raised off it. The
            // reference's flat collar, and what the ring is drawn on.
            Container(
              width: d,
              height: d,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: PanelTheme.surface,
                boxShadow: PanelTheme.raised(d * .14),
              ),
            ),
            AnimatedBuilder(
              animation: pulse,
              builder: (context, _) => CustomPaint(
                size: const Size.square(d),
                painter: _RimArc(
                  colour: _ringColour,
                  // `opening` is a segment chasing its own tail; `failed` is
                  // a ring with a gap at the top; everything else is closed.
                  start: opening ? pulse.value - .25 : -.25 + _gap / 2,
                  sweep: opening ? .3 : 1 - _gap,
                  width: d * (phase == TalkPhase.open ? .042 : .028),
                  inset: d * .014,
                ),
              ),
            ),
            // The raised inner disc, and the glyph on it.
            Container(
              width: d * .78,
              height: d * .78,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: PanelTheme.surfaceRaised,
                boxShadow: PanelTheme.raised(d * .10),
              ),
              child: Icon(_glyph, color: _glyphColour, size: d * .34),
            ),
          ],
        ),
      ),
    );
  }

  /// How much of the ring is missing, in turns. Only [TalkPhase.failed] has a
  /// gap, and it is centred on the top so it cannot be mistaken for a segment
  /// that happens to have stopped there.
  double get _gap => phase == TalkPhase.failed ? .10 : 0;
}

/// One stroked arc around a circle's rim, in turns rather than radians
/// because every angle this button uses is a fraction of a full turn.
class _RimArc extends CustomPainter {
  const _RimArc({
    required this.colour,
    required this.start,
    required this.sweep,
    required this.width,
    required this.inset,
  });

  final Color colour;
  final double start;
  final double sweep;
  final double width;
  final double inset;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawArc(
      Rect.fromLTWH(
        inset,
        inset,
        size.width - inset * 2,
        size.height - inset * 2,
      ),
      start * 2 * math.pi,
      sweep * 2 * math.pi,
      false,
      Paint()
        ..color = colour
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = width,
    );
  }

  @override
  bool shouldRepaint(_RimArc old) =>
      old.colour != colour ||
      old.start != start ||
      old.sweep != sweep ||
      old.width != width;
}

/// The honest label under the button — the one place that says what is and
/// is not actually happening, in every phase.
///
/// Same rule ADR-0007 applies to the still photo below the video, applied to
/// a control instead of a reading: a thing that is not happening may not look
/// like it is. Three of these five sentences exist only because collapsing
/// them would put one caption under problems with different fixes — a missing
/// `GO2RTC_URL`, a missing `talk:` binding and a go2rtc that refused all read
/// as "it doesn't work" otherwise.
///
/// Two things it deliberately keeps saying:
///   - it never claims the door **heard** anyone. A 200 means go2rtc took the
///     microphone as a producer, and that is the strongest claim this API
///     affords ([TalkPhase.open]);
///   - it keeps saying that audio **from** the door is not wired up, because
///     it is not: the Panel plays MJPEG, which carries no audio by
///     construction, and whichever process ends up playing inbound audio is
///     still an open owner decision. Half a duplex working is not two-way
///     audio, and the wall should not imply it is.
///
/// **[TalkPhase.idle] has no sentence any more** — the one wording the
/// 2026-08-14 redesign dropped (issue #2). `Hold to speak — you won't hear the
/// door back yet` was a *hint*, and a mic icon docked under a live picture
/// already says "hold this to speak" without a caption's help; the half it
/// really carried, that the door cannot be heard back, is not a thing this
/// Popup can honestly announce at rest either, since nothing has been
/// attempted yet.
///
/// The other four stay, and the rule they answer to is untouched: every one of
/// them reports a **fault or a live state** — a missing `GO2RTC_URL`, a
/// missing `talk:` binding, a microphone opening, a microphone open, a go2rtc
/// that refused. ADR-0007 is about not dressing up what is not happening, and
/// removing a hint claims nothing. Removing any of these four would.
class _TalkCaption extends StatelessWidget {
  const _TalkCaption(this.phase);

  final TalkPhase phase;

  static const _wording = {
    TalkPhase.unconfigured: 'Two-way audio isn\'t configured for this door',
    TalkPhase.opening: 'Opening the microphone…',
    TalkPhase.open: 'Microphone open — speak now',
    TalkPhase.failed: 'Couldn\'t open the microphone — nothing was sent',
  };

  /// What this phase has to say, or null when it has nothing — which is only
  /// [TalkPhase.idle]. The caption slot asks before it builds one, so that an
  /// empty phase leaves reserved space rather than an empty [Text].
  static String? wordingFor(TalkPhase phase) => _wording[phase];

  @override
  Widget build(BuildContext context) {
    return Text(
      _wording[phase]!,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 11,
        // The one phase that is a fault rather than a state. Same red as the
        // live button, which is not a collision: nothing shows both.
        color: phase == TalkPhase.failed
            ? const Color(0xFFE05252)
            : PanelTheme.inkFaint,
      ),
    );
  }
}
