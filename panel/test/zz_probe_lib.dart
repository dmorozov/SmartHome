import 'dart:async';

import 'package:flutter/widgets.dart';

/// What one already-showing Popup said when it was asked to stay up.
///
/// About a *Popup*, not about a Device: a Device can have a stack of them,
/// and what the wall as a whole says is [ClaimAnswer]. There is deliberately
/// no `none` here — "nothing is showing this Device" is not something a
/// Popup can say about itself, and the one caller that used to need it
/// ([PopupClaim.acquire]) answers it from the registry instead.
enum StayVerdict {
  /// Its deadline was restarted from zero.
  extended,

  /// A Popup a person opened. It stays up — and deliberately does **not**
  /// gain a deadline it never had (D14): a countdown smuggled in by somebody
  /// else's event would yank the camera away from whoever went and tapped it.
  held,

  /// It is already on its way out: popped and playing its exit animation, or
  /// past its ceiling. Nothing can extend it, and pushing a replacement *now*
  /// would put a second consumer on the same go2rtc stream while the first is
  /// still open.
  leaving,
}

/// A Popup the claim can ask to stay up. Implemented by the Popup's State,
/// which is where the Navigator and the deadline live.
abstract interface class PopupStayer {
  /// Restart this Popup's deadline if it has one, and say what that meant.
  /// Must answer rather than throw, whatever state it finds: the caller is
  /// inside a Hub stream callback, where an exception has nowhere to go and
  /// takes the doorbell with it.
  StayVerdict stayUp();
}

/// What the claim tells a caller that asked to open an unprompted Popup.
///
/// Sealed, so a caller handles every outcome or does not compile — the shape
/// that replaced a four-value enum crossing a file seam plus a deferral map,
/// an expiry Timer, a gone-waiter, a post-frame redemption and a drop line,
/// all of which the caller used to own.
sealed class ClaimAnswer {
  const ClaimAnswer();
}

/// Nothing is showing this Device. Push now.
final class Claim extends ClaimAnswer {
  const Claim();
}

/// A Popup with a deadline is already showing it, and its deadline has been
/// restarted. Nothing to push: tearing it down and opening a new one would
/// black the wall out for the 2-5 s of a Ring spin-up at the exact moment
/// somebody is at the door.
final class Extended extends ClaimAnswer {
  const Extended();
}

/// A Popup a *person* opened is already showing it. It stays as it is,
/// deadline-less; the caller has nothing to do.
final class Held extends ClaimAnswer {
  const Held();
}

/// Every Popup for this Device is on its way out, so the stream is not free
/// yet. The claim holds the request and answers again — with a fresh verdict
/// when the Device goes free, or [Dropped] if that takes too long. The
/// caller does nothing now.
final class Wait extends ClaimAnswer {
  const Wait();
}

/// The held request went stale before the Device came free.
///
/// A request is a claim that something is happening NOW; redeemed minutes
/// later it opens a live session and a picture of an empty porch, on top of
/// whatever is on the wall by then. The caller gets this so it can say so —
/// this is the one path where somebody pressed the bell and the wall never
/// answered, which is the failure with no symptom of its own.
final class Dropped extends ClaimAnswer {
  const Dropped(this.waited);

  /// How long the request waited before being dropped. Carried rather than
  /// left for the caller to read off [kPopupClaimWindow], because the window
  /// is constructor-injectable and a caller that reported the default would
  /// be reporting a number that was not the one this claim used.
  final Duration waited;
}

/// How long a request deferred behind a closing Popup may wait for its turn
/// before it is dropped instead.
///
/// Deliberately `kDoorbellPopupDeadline`'s own 30 s: a Popup pushed now would
/// close 30 s from now, so a request older than that would already have come
/// and gone had it been shown the moment it arrived. Written as a literal
/// rather than as a reference to that constant because this file must not
/// import `doorbell_popup_host.dart` — the doorbell host is a *caller* of the
/// claim, and one asker of many by design. The ordinary wait is the ~150 ms
/// of a Dialog exit animation.
const kPopupClaimWindow = Duration(seconds: 30);

/// Who may open a Popup for a Device right now — the arbitration that used
/// to be a registry and two functions in `device_popup.dart`, a deferral map
/// and three methods in `doorbell_popup_host.dart`, and two caller-side
/// invariants nobody could see from the call site.
///
/// **Why it is one object and not per-caller.** "Is this Device's Popup
/// already up?" has to be answerable about a Popup *somebody else* pushed:
/// `dollhouse_view` opens one when a person taps a pin, and the doorbell
/// host must not open a second go2rtc consumer on the same stream on top of
/// it. A claim each would only ever see its own Popups, which is precisely
/// the blind spot this replaces.
///
/// **What the caller no longer has to know.** Two invariants used to live in
/// prose at the call site and nowhere in the types: "arm the gone-waiter
/// only after being told `leaving`, or it is redeemed by the *next* Popup
/// minutes later", and "redeem on the next frame, not now, because you are
/// inside a Popup's `dispose` and pushing a route mid-teardown is a
/// framework error". Both are inside [acquire] now. The caller switches on
/// a sealed answer.
///
/// **What stays outside.** Journal vocabulary: the claim writes no log line,
/// because whose ding it was and what to call it are the caller's. The route
/// itself: pushing, popping and the Navigator are the caller's too.
class PopupClaim {
  PopupClaim({
    this.window = kPopupClaimWindow,
    this.nextFrame = _postFrame,
  });

  /// How long a deferred request may wait — see [Dropped].
  final Duration window;

  /// Injected so the unit suite can run without a widget binding, and so it
  /// can hold a redemption open and change the wall underneath it; production
  /// takes the real post-frame callback.
  final void Function(VoidCallback) nextFrame;

  static void _postFrame(VoidCallback fn) =>
      WidgetsBinding.instance.addPostFrameCallback((_) => fn());

  /// Every Popup currently on the wall for a Device, oldest first.
  ///
  /// A *list* per Device, because one slot cannot say "the newer one left,
  /// the older one is still on the wall": the newer registration overwrote
  /// the older and the newer teardown then cleared the slot, so the claim
  /// answered [Claim] about a Device whose Dialog was up with a live session
  /// behind it — and a caller believing that opens a second consumer on the
  /// one stream. Nothing pushes two Popups for one Device today; this keeps
  /// that a fact about the wall rather than a requirement on every future
  /// call site.
  final _showing = <String, List<PopupStayer>>{};

  /// Requests waiting for a Device to come free, by Device id. At most one
  /// per Device — see [acquire].
  final _waiting = <String, _Waiting>{};

  /// Register a Popup that is now on the wall. From the State's `initState`,
  /// last, once nothing left in it can throw: an entry claimed before the
  /// risky part outlives the widget tree and nothing can ever remove it, and
  /// that Device is then permanently deaf.
  void register(String deviceId, PopupStayer popup) =>
      _showing.putIfAbsent(deviceId, () => []).add(popup);

  /// Deregister it, by identity and only this one entry: two Popups for one
  /// Device are a stack, and the newer one leaving must not deregister the
  /// older, which is still on the wall holding the stream.
  ///
  /// From the State's `dispose`, first, where an entry left behind by a throw
  /// further down would leave that Device permanently deaf. Ordering against
  /// the rest of the teardown is not this call's problem: any request this
  /// releases is answered on the next frame, which is after every statement
  /// of every `dispose` in the frame that removed the route — so a waiting
  /// request still meets a stream that really is closed.
  void deregister(String deviceId, PopupStayer popup) {
    final showing = _showing[deviceId];
    showing?.remove(popup);
    if (showing != null && showing.isNotEmpty) return;
    // Nothing is left on the wall for this Device, so its stream is free.
    _showing.remove(deviceId);
    _redeem(deviceId);
  }

  /// May [owner] open a Popup for [deviceId] right now?
  ///
  /// Answers immediately. On [Wait] — and only then — [onVerdict] is called
  /// later with a fresh answer: the Device coming free is re-judged against
  /// whatever is on the wall by then, on the next frame, or the request is
  /// [Dropped] once it has waited [window].
  ///
  /// One waiting request per Device: two dings inside one ~150 ms exit
  /// animation are one visitor leaning on the button, and they would have
  /// opened one Popup between them. The newer replaces the older, clock and
  /// all, because the wait that matters is the wait since the last press.
  ///
  /// [owner] is who to drop it for in [abandon], and is compared by identity.
  /// A caller that acquires must abandon from its own teardown, or a clock it
  /// no longer has any use for outlives it.
  ClaimAnswer acquire(
    String deviceId, {
    required Object owner,
    required void Function(ClaimAnswer) onVerdict,
  }) {
    final answer = _judge(deviceId);
    if (answer is! Wait) return answer;
    _waiting.remove(deviceId)?.expiry.cancel();
    _waiting[deviceId] = _Waiting(
      owner: owner,
      onVerdict: onVerdict,
      expiry: Timer(window, () {
        final waiting = _waiting.remove(deviceId);
        if (waiting != null) waiting.onVerdict(Dropped(window));
      }),
    );
    return answer;
  }

  /// Drop every request [owner] is waiting on — from its `dispose`. A
  /// pending Timer outliving the tree fails a widget test by itself, and on
  /// the wall it is a kiosk shutdown holding a clock for a caller that is
  /// gone. By owner, not wholesale, so one caller leaving cannot silently
  /// drop another's.
  void abandon(Object owner) {
    _waiting.removeWhere((_, waiting) {
      if (!identical(waiting.owner, owner)) return false;
      waiting.expiry.cancel();
      return true;
    });
  }

  /// What asking the showing Popups to stay up says about this Device.
  ///
  /// Newest first: the one on top is the one somebody would be looking at,
  /// and the one whose deadline a fresh reason should restart. One
  /// underneath still counts, though — it holds a go2rtc session just the
  /// same — so [StayVerdict.leaving] from the top is not an answer about the
  /// *Device* until everything below it has said the same.
  ClaimAnswer _judge(String deviceId) {
    final showing = _showing[deviceId];
    if (showing == null || showing.isEmpty) return const Claim();
    for (final popup in showing.reversed) {
      switch (popup.stayUp()) {
        case StayVerdict.extended:
          return const Extended();
        case StayVerdict.held:
          return const Held();
        case StayVerdict.leaving:
          continue;
      }
    }
    return const Wait();
  }

  /// The Device has no Popup at all any more, so the stream is free.
  void _redeem(String deviceId) {
    final waiting = _waiting[deviceId];
    if (waiting == null) return;
    // Next frame, not now: this runs inside a Popup's `dispose`, and pushing
    // a route mid-teardown is a framework error rather than a race.
    nextFrame(() {
      // Still the same request? Its clock running out, its owner abandoning
      // it, and a newer request replacing it are all `_waiting` no longer
      // holding this entry — one check covers the three, and each of them
      // has already told the caller whatever it was owed.
      if (!identical(_waiting[deviceId], waiting)) return;
      // Judged again rather than answered [Claim] blind, so the request meets
      // whatever is on the wall by the time it is offered — including a Popup
      // that opened while it waited.
      final answer = _judge(deviceId);
      // Including one that is on its way out too. The request keeps its place
      // and its ORIGINAL clock: it has been waiting since the press, and
      // re-arming here would let a chain of closing Popups hold a request
      // well past the window that exists to say when it went stale. That
      // Popup's own deregistration brings us back here.
      if (answer is Wait) return;
      _waiting.remove(deviceId);
      // MUTATED: waiting.expiry.cancel();
      waiting.onVerdict(answer);
    });
  }
}

class _Waiting {
  _Waiting({
    required this.owner,
    required this.onVerdict,
    required this.expiry,
  });

  final Object owner;
  final void Function(ClaimAnswer) onVerdict;
  final Timer expiry;
}

/// The one claim the wall shares, for the reason [PopupClaim]'s own doc
/// gives: a Popup pushed by `dollhouse_view` and a ding raised by
/// `doorbell_popup_host` must be answerable about each other, and neither
/// knows the other exists.
///
/// A library-level instance rather than a threaded parameter, which is the
/// deeper fix and deliberately not this change: threading it would touch
/// `showDevicePopup` and every caller of it, which is the composition-root
/// work Phase J of the deepening plan holds. What this replaces is two
/// module-level maps and two module-level functions with one object a test
/// can construct its own of — which the unit suite does, so the seam is real
/// rather than a promise.
final popupClaim = PopupClaim();
