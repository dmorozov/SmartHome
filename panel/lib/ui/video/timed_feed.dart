import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'stream_director.dart';

/// The Popup's clocks, wrapped around any [CameraFeed]: the extendable
/// deadline and the absolute ceiling that bound the unprompted doorbell
/// Popup (`doorbell_popup_host.dart` owns the constants and the why —
/// #177014 in one sentence: an open Ring session can deafen the doorbell).
///
/// A decorator rather than knobs on [DirectorPolicy], by owner decision
/// (2026-08-28): the deadline times a ROUTE — how long a Popup nobody asked
/// for may stay on the wall — not a stream. The stream-side age bound
/// already exists one seam down (`kLiveVideoMaxHeld`, the keep-alive
/// pool's), and the deadline's fire is a Navigator pop, an act the Director
/// cannot perform. Whatever owns the route owns the clock; the Director's
/// interface stays deep instead of one role wide. The `linger < deadline`
/// inequality the pool's suite pins is about the constants this class is
/// handed, not about this class — that test lives with the constants.
///
/// [deadline] null is D14's person-opened Popup: no countdown, no ceiling
/// (a cap on extensions is meaningless with nothing to extend), and
/// [extend] no-ops — a deadline smuggled in by somebody else's event would
/// yank the camera away from whoever went and tapped for it. [ceiling] is
/// counted from construction and never re-armed; past it [ceilingReached]
/// answers true and [extend] is refused, which is `leaving` to whoever asks.
///
/// [onDeadline] fires when the deadline expires unextended — once per armed
/// stretch, since [extend] starts a fresh one. [onCeiling] fires at most
/// once, cancels the deadline with it, and leaves the dismissal to the
/// caller (the route logic — blocked-dismiss retries included — is the
/// widget's, not a clock's). Neither fires after [release].
class TimedFeed implements CameraFeed {
  TimedFeed(
    this._inner, {
    this.deadline,
    Duration? ceiling,
    required this.onDeadline,
    required this.onCeiling,
  }) {
    extend();
    if (deadline != null && ceiling != null) {
      _ceilingTimer = Timer(ceiling, _reachCeiling);
    }
  }

  final CameraFeed _inner;

  /// How long the Popup stays up after the last reason to stay — null on
  /// D14's person-opened Popup, which gets no countdown at all.
  final Duration? deadline;

  /// The deadline expired unextended. The route's business from here.
  final VoidCallback onDeadline;

  /// The ceiling fired — the deadline is already stopped for good.
  final VoidCallback onCeiling;

  Timer? _deadlineTimer;
  Timer? _ceilingTimer;
  var _ceilingReached = false;
  var _released = false;

  /// Whether the absolute ceiling has fired. One-way: nothing can extend
  /// past it, which is what stops a doorbell dinging every 25 s from
  /// holding one go2rtc session open forever.
  bool get ceilingReached => _ceilingReached;

  /// Restarts the deadline from zero — a fresh reason to stay up arrived.
  /// Nothing to restart on a Popup with no deadline (D14), past the
  /// ceiling, or after [release].
  void extend() {
    final deadline = this.deadline;
    if (deadline == null || _ceilingReached || _released) return;
    _deadlineTimer?.cancel();
    _deadlineTimer = Timer(deadline, onDeadline);
  }

  void _reachCeiling() {
    _ceilingReached = true;
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
    onCeiling();
  }

  // ---- the feed, passed through ------------------------------------------

  @override
  ValueListenable<FeedPhase> get phase => _inner.phase;

  @override
  String? get failure => _inner.failure;

  @override
  Widget get view => _inner.view;

  @override
  set visible(bool value) => _inner.visible = value;

  @override
  ValueListenable<int> get retryAttempt => _inner.retryAttempt;

  @override
  bool get stillGrabAllowed => _inner.stillGrabAllowed;

  @override
  void start() => _inner.start();

  @override
  void setMuted(bool muted) => _inner.setMuted(muted);

  /// The clocks die with the feed: both timers cancelled (a pending Timer
  /// outliving the tree fails a widget test by itself), then the inner
  /// feed's own [CameraFeed.release]. Idempotent like it.
  @override
  void release() {
    _released = true;
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
    _ceilingTimer?.cancel();
    _ceilingTimer = null;
    _inner.release();
  }
}
