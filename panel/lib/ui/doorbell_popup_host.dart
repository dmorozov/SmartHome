import 'dart:async';

import 'package:flutter/material.dart';

import '../diagnostics/log.dart';
import '../domain/house.dart';
import 'device_popup.dart';
import 'hub_controller.dart';
import 'popup_claim.dart';
import 'audio/talk.dart';
import 'video/snapshot.dart';
import 'video/stream_director.dart';

/// How long an unprompted doorbell Popup stays up after the last ding.
///
/// 30 s: long enough to see who it is and decide whether to go to the door,
/// short enough that a wall panel is never left showing a live Ring session
/// nobody is watching. That second half is not tidiness — HA issue #177014
/// says a session left running can suppress the *next* real ding, so an
/// abandoned Popup does not merely waste bandwidth, it deafens the doorbell.
const kDoorbellPopupDeadline = Duration(seconds: 30);

/// The longest one unprompted Popup may live, counted from when it opened,
/// however many dings extend it.
///
/// [kDoorbellPopupDeadline] measures time since the *last* ding, so on its own
/// a doorbell that dings more often than every 30 s re-arms it from scratch
/// forever: over a simulated hour that is one Popup, one go2rtc session,
/// opened once and never closed. That is exactly the state the deadline exists
/// to prevent, and #177014 makes it worse than a lit wall — a held session can
/// suppress the next real ding. What that issue cares about is time since the
/// stream was *opened*, and this is the only thing here that measures it.
///
/// 2 minutes: four ordinary deadlines, and longer than a doorway exchange the
/// Panel is expected to survive with nobody touching it. Reaching it does not
/// lose the doorbell — the Popup closes, the session is torn down, and the
/// next ding opens a fresh one. Worst case that pays the 2-5 s Ring spin-up
/// once every two minutes, which is the price of the guarantee that no session
/// is ever older than this.
///
/// Rejected: capping the *number* of extensions. A count says nothing about
/// how long the session has been open, which is the only quantity #177014 is
/// about.
const kDoorbellPopupCeiling = Duration(minutes: 2);

/// Opens the Popup nobody asked for: the one widget in the Panel allowed to
/// push a route on the Hub's say-so.
///
/// It exists because [HubController] must not be able to. That file imports
/// `flutter/foundation.dart` and nothing else — `BuildContext` and
/// `Navigator` are not even nameable in it — and that is load-bearing:
/// `bootPanel` builds the controller before any widget exists. Rejected:
/// `MaterialApp(navigatorKey:)` pushed from `main()`, which is a global
/// handle to the Navigator reachable from anywhere, i.e. exactly the coupling
/// the controller's import list is there to prevent; and rejected: listening
/// from inside a `ListenableBuilder`, because pushing a route during `build`
/// is a framework error rather than a style opinion.
///
/// Renders [child] unchanged — a wrapper, not a layer. It belongs *inside*
/// `MaterialApp` so `Navigator.of` resolves, and *outside* the
/// `ListenableBuilder`s so a thermostat drifting a tenth of a degree does not
/// rebuild it.
class DoorbellPopupHost extends StatefulWidget {
  const DoorbellPopupHost({
    super.key,
    required this.controller,
    required this.director,
    this.snapshots,
    required this.child,
    this.talk = const TalkConfig(),
    this.dismissAfter = kDoorbellPopupDeadline,
    this.dismissCeiling = kDoorbellPopupCeiling,
  });

  final HubController controller;

  /// The Stream Director, forwarded so the Popups this host pushes attach
  /// their feed to it ([FeedRole.popup]) — one census, one lifecycle, and
  /// where go2rtc is inside it. The doorbell's live view is the whole reason
  /// the Popup opens unprompted, so a host that minted its own would open a
  /// Popup guaranteed to show the unconfigured placeholder — and one Camera
  /// Health and the census never heard from. Required; the fixture builds
  /// one for hermetic scenes.
  final StreamDirector director;

  /// Where the Hub is, for the still the Popup shows while the live view has
  /// no decodable picture. **This is the path that matters most for issue #1**:
  /// the Popups this host pushes are the unprompted ones, opened by a ding, so
  /// they are the ones where the Ring restream has just been relaunched and is
  /// likeliest to arrive mid-GOP — and the ones where somebody wants to see
  /// the porch right now rather than read why they cannot.
  final SnapshotConfig? snapshots;

  /// Where the doorbell's push-to-talk pushes. Forwarded for [director]'s
  /// reason and mattering here more than anywhere: the Popups this host
  /// pushes are the ones a visitor is standing in front of, so they are the
  /// ones whose talk button is actually going to be pressed.
  final TalkConfig talk;

  final Widget child;

  /// Never null, unlike `showDevicePopup`'s parameter: everything this host
  /// opens was opened by a doorbell rather than by a person, and the deadline
  /// is what keeps a Ring session from outliving the visitor.
  final Duration dismissAfter;

  /// The ceiling on extending [dismissAfter] — see [kDoorbellPopupCeiling].
  /// Never null here for the same reason [dismissAfter] never is.
  final Duration dismissCeiling;

  @override
  State<DoorbellPopupHost> createState() => _DoorbellPopupHostState();
}

class _DoorbellPopupHostState extends State<DoorbellPopupHost> {
  late StreamSubscription<Device> _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.controller.doorbellRings.listen(_onRing);
  }

  /// `PanelApp` builds this host once, with the controller `bootPanel`
  /// returned, so today nothing swaps it. Handled anyway because the failure
  /// if somebody ever does is *silent*: the host would keep listening to a
  /// controller nobody feeds, the wall would look perfectly healthy, and the
  /// doorbell would simply stop answering.
  @override
  void didUpdateWidget(DoorbellPopupHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller == oldWidget.controller) return;
    _sub.cancel();
    _sub = widget.controller.doorbellRings.listen(_onRing);
  }

  @override
  void dispose() {
    _sub.cancel();
    // The claim outlives this host — it outlives every route — so a ding of
    // ours still waiting for its turn would keep a clock running for a
    // listener that is gone, which fails a widget test by itself and on the
    // wall is a kiosk shutdown holding a Device the Panel no longer has
    // anything to do with.
    popupClaim.abandon(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;

  void _onRing(Device doorbell) {
    // The subscription is cancelled in `dispose`, so this should not be
    // reachable; it is here because the cost of being wrong is a `setState`
    // on a dead State during a kiosk shutdown, and the cost of the check is
    // a field read.
    if (!mounted) return;
    // One acquire per ding, and it asks about *this doorbell* rather than
    // "is a Popup up": a Popup showing some other Device is no reason to
    // swallow this ding; a Popup showing this one is, however it got there —
    // including one a person opened by tapping the pin, which this host did
    // not push and has no other way to hear about.
    //
    // Everything the host used to own to make that answer true — a deferral
    // map keyed by doorbell, its expiry Timers, the gone-waiter armed only
    // after a `leaving`, the post-frame redemption — is behind [acquire] now.
    // What is left here is what a ding *means*, which is this file's own.
    _answer(
      doorbell,
      popupClaim.acquire(
        doorbell.id,
        owner: this,
        onVerdict: (verdict) => _answer(doorbell, verdict),
      ),
    );
  }

  /// What the claim's answer means for a doorbell — the journal vocabulary
  /// and the push, neither of which the claim knows about.
  ///
  /// Called with the immediate answer, and again later on [Wait] alone.
  void _answer(Device doorbell, ClaimAnswer verdict) {
    // A verdict is the one thing here that can arrive after the ding that
    // asked for it has been dealt with — a frame later, or thirty seconds.
    // `dispose` abandons the wait, so today nothing can reach this with the
    // host gone; the check stays because what is behind it reaches for
    // `context`, and `Navigator.of` on an unmounted State is a framework
    // error rather than a no-op.
    if (!mounted) return;
    switch (verdict) {
      case Claim():
        _push(doorbell);
      case Extended():
        // Extend, never re-push. Phase-3 §3 measures Ring stream spin-up at
        // 2-5 s, so tearing the Popup down and opening a new one would black
        // the wall out for seconds at the exact moment somebody is at the
        // door — and a second stacked modal would leave two things to dismiss
        // on a screen with no keyboard.
        Log.debug('popup', 'doorbell_extended', {'device': doorbell.id});
      case Held():
        // A person already has this doorbell's camera up. They are looking at
        // the picture this ding would have opened, so opening a second
        // session on the same stream would buy nothing and cost the one thing
        // #177014 says not to spend. It stays deadline-less (D14): a
        // countdown this ding smuggled in would yank the camera away from
        // whoever went and tapped it.
        Log.debug('popup', 'doorbell_held',
            {'device': doorbell.id, 'reason': 'person_opened'});
      case Wait():
        // The Popup on the wall for this doorbell is already leaving, so its
        // go2rtc session is open for the ~150 ms of the exit animation and a
        // second Popup now would be a second consumer on the one stream. The
        // ding is not lost — the claim offers it again when the Device comes
        // free.
        Log.debug('popup', 'doorbell_deferred',
            {'device': doorbell.id, 'reason': 'stream_closing'});
      case Dropped(:final waited):
        // A ding is a real-time event: the Popup it opens is a claim that
        // somebody is at the door *now*. Redeemed minutes later it opens a
        // live Ring session and a picture of an empty porch, on top of
        // whatever is on the wall by then, with nothing behind it that anyone
        // can act on — and #177014 says that session can suppress the *next*
        // real ding, so a stale redemption does not merely mislead, it can
        // deafen the doorbell for the press that matters.
        //
        // Warn, not debug: this is the one path where somebody pressed the
        // bell and the wall never says so, which is the failure with no
        // symptom of its own. Reachable while a Popup past its ceiling cannot
        // pop itself because another route is stacked on top of it — see
        // `device_popup.dart`'s `dismiss_blocked`.
        Log.warn('popup', 'doorbell_dropped', {
          'device': doorbell.id,
          'reason': 'popup_never_closed',
          'waited_s': waited.inSeconds,
        });
    }
  }

  void _push(Device doorbell) {
    Log.info('popup', 'doorbell', {'device': doorbell.id, 'reason': 'ding'});
    // If a Popup a person opened for some *other* Device is up, this stacks on
    // top of it and says so in the line above. Deliberately left to the family
    // rather than defaulted: "a ring outranks a washer" is a house rule, not a
    // fact about software, and `ModalRoute.of(context)?.isCurrent == false` is
    // the detector to reach for if they ever want it.
    showDevicePopup(
      context,
      presentation: widget.controller.presentationOf(doorbell),
      director: widget.director,
      snapshots: widget.snapshots,
      talk: widget.talk,
      dismissAfter: widget.dismissAfter,
      dismissCeiling: widget.dismissCeiling,
      onGone: () => _onPopupGone(doorbell),
    );
  }

  /// Runs from the Popup's own `dispose`, so the go2rtc session behind it is
  /// already closed by the time anything here decides what to do next.
  ///
  /// Logging only. What a deferred ding waits on is the claim, which answers
  /// about the *Device* — this one answers about the Popup this host pushed,
  /// which is the right scope for a line that says the Popup this host pushed
  /// has gone and no scope at all for the other job.
  void _onPopupGone(Device doorbell) {
    // No `reason=`, though the plan's line list asked for `reason=timeout`.
    // This host cannot tell the deadline firing from a hand on the glass: all
    // three ways out of the Popup pop the same route with the same (absent)
    // result, and only `device_popup.dart` is in a position to know which
    // happened — `popup.deadline_ceiling` is the one case where it says so.
    Log.info('popup', 'doorbell_dismissed', {'device': doorbell.id});
  }
}

