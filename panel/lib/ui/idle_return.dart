import 'dart:async';

import 'package:flutter/foundation.dart';

/// The idle bound's clockwork: ask before acting, then act.
///
/// A surface holding a live stream with nobody watching it costs bandwidth,
/// and on this house it costs more than that — an open Ring session
/// suppresses the next real ding (#177014), so a forgotten Popup does not
/// merely waste airtime, it deafens the doorbell. Both surfaces that can
/// hold one therefore bound the forgotten case: after [returnAfter] with no
/// touch, they leave. The last [warnFor] of that bound is the softening —
/// the surface asks first, and one tap per five minutes is the price of
/// holding a stream open on purpose.
///
/// The choreography was written twice before 2026-09-03 (the Cameras view
/// and the Popup) and had drifted in six measurable ways. What is shared
/// here is only the clockwork; what each surface keeps is everything that
/// is true of THAT surface:
///
/// * **its constants.** [returnAfter] and [warnFor] are parameters, not
///   constants of this module, because the two surfaces have different
///   lifetimes and a future reason to diverge — importing the Cameras
///   view's vocabulary into the Popup to save one `Duration` would be the
///   wrong dependency (`device_popup.dart` argues it at its own constant).
/// * **its gate.** Most Popups are not idle-bounded at all; that question
///   is the Popup's (`_boundsIdle`), asked before it rearms.
/// * **its fire.** [onFire] pops a route, and how a surface may pop — which
///   route, whether something is stacked on top, how often to retry, at
///   what log level — is route mechanics, deliberately NOT shared. Both
///   surfaces retry a pop blocked by something stacked on top, and they do
///   it differently on purpose: the Cameras view every 30 s, logging
///   `idle_blocked` at debug on each retry; the Popup every 1 s, warning
///   `dismiss_blocked` once, on the path it shares with its deadline. A
///   shared retry would have to pick one cadence and one log level for two
///   surfaces that measured different ones.
/// * **its pointer `Listener`,** including the hit-test behaviour, which
///   each surface reasons about separately.
///
/// Pure Dart: no widget, no `BuildContext`, no `Navigator` — which is what
/// lets the choreography be tested in milliseconds with a fake clock instead
/// of by pumping five real minutes through a widget tree.
class IdleReturn {
  IdleReturn({
    required this.returnAfter,
    required this.warnFor,
    required this.onFire,
  }) : assert(warnFor < returnAfter,
            'the warning is PART of the bound, not added to it');

  /// How long a surface stays up untouched before [onFire].
  final Duration returnAfter;

  /// How long [prompting] is true before [onFire] — the last slice of
  /// [returnAfter], never an extension of it.
  final Duration warnFor;

  /// What an unanswered prompt does. Called once per armed cycle, on the
  /// main isolate, never after [dispose].
  final VoidCallback onFire;

  final _prompting = ValueNotifier(false);

  /// Whether the surface should be showing its "Still watching?" prompt.
  /// False again the moment anything [rearm]s.
  ValueListenable<bool> get prompting => _prompting;

  Timer? _warn;
  Timer? _fire;
  var _disposed = false;

  /// Restarts the bound: any touch, and the first arm at open.
  ///
  /// The tap that answers the prompt needs no special case — it rearms like
  /// any other, and clearing [prompting] here is what takes the prompt away.
  void rearm() {
    if (_disposed) return;
    cancel();
    _warn = Timer(returnAfter - warnFor, () {
      // Armed BEFORE the flag is flipped, and the order is load-bearing:
      // [prompting] notifies synchronously, so a listener that cancels,
      // rearms or disposes inside that notification has to be able to see
      // this timer in order to cancel it. Flipping first would arm it
      // afterwards, behind the back of a surface that has already torn
      // down, and [onFire] would land on a dead State.
      _fire = Timer(warnFor, onFire);
      _prompting.value = true;
    });
  }

  /// Stops the bound and takes the prompt down, without firing.
  void cancel() {
    if (_disposed) return;
    _cancelTimers();
    _prompting.value = false;
  }

  /// Idempotent, and owed by the surface's own `dispose`: a pending Timer
  /// outliving the tree fails a widget test by itself, and on the wall it is
  /// a kiosk shutdown holding a clock for a route that is gone.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Timers only — a value change here would notify a surface that is
    // already tearing down.
    _cancelTimers();
    _prompting.dispose();
  }

  void _cancelTimers() {
    _warn?.cancel();
    _warn = null;
    _fire?.cancel();
    _fire = null;
  }
}
