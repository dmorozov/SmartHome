import 'dart:async';

import 'package:flutter/material.dart';

import '../diagnostics/log.dart';
import '../domain/device_state.dart';
import '../domain/house.dart';
import 'device_presentation.dart';
import 'hub_controller.dart';
import 'theme.dart';

/// The thermostat Popup's body: the live reading, and −/+ setpoint controls.
///
/// The number on display is one of exactly two things, and the colour says
/// which: the Hub's own word (ink), or a value somebody just dialled that
/// the Hub has not yet confirmed (accent). Taps step the dialled value
/// immediately — so five quick taps read as five steps, not five races
/// against the echo — and one debounced command carries the final absolute
/// value to the Hub. When the Hub answers, its word replaces the dialled
/// one; when it does not answer at all, the dialled value *reverts* after
/// [_confirmWithin], because a wall that keeps showing a setpoint the
/// thermostat never adopted is showing a lie. The revert is also what makes
/// a rejected command visible where it happened: the number snaps back on
/// the glass, `hub.command_failed` names the reason in the journal.
///
/// Stepping is relative and unit-blind on purpose. The Panel never converts
/// temperatures (see ThermostatState); a step is added to a number the Hub
/// itself denominated and sent back in the same currency, so the command is
/// correct even while the unit is still unknown. The unit decides only the
/// step size (1 °F is the coarsest granule anyone sets a Fahrenheit
/// thermostat in; 0.5 elsewhere, dev-Hub-sized) and the suffix.
///
/// No min/max clamp here — hub_client.dart states why the Hub owns the
/// range. And no controls at all on an unknown state: stepping from a
/// number nobody reported would be the Panel inventing a setpoint, and
/// heat_cool mode arrives here as exactly that case (the entity carries no
/// single `temperature`, so the fold reports it unusable).
class ThermostatControls extends StatefulWidget {
  const ThermostatControls({
    super.key,
    required this.controller,
    required this.device,
  });

  final HubController controller;
  final Device device;

  @override
  State<ThermostatControls> createState() => _ThermostatControlsState();
}

class _ThermostatControlsState extends State<ThermostatControls> {
  /// One command per dialling gesture, not one per tap. Somebody stepping
  /// 68 → 72 is four taps in two seconds; four `climate.set_temperature`
  /// calls would write four holds to the real HVAC (a cloud round-trip
  /// each, on the grandfathered path) to express one decision.
  static const _sendAfter = Duration(milliseconds: 800);

  /// How long a sent value may stay on display without the Hub adopting
  /// it. Generous against real echo latency (HomeKit accessory round-trip,
  /// HA state machine, the socket back), short enough that a person still
  /// standing there sees the revert.
  static const _confirmWithin = Duration(seconds: 5);

  /// Two temperatures closer than this are the same temperature: readings
  /// arrive through JSON doubles and integrations quantise, so `==` would
  /// be a coin toss. Same tolerance the phase-2 plan uses for the live
  /// test's reading assertions.
  static const _epsilon = 0.05;

  /// The value somebody dialled, on display instead of the Hub's word.
  /// Null whenever the wall is showing live state — which is the resting
  /// answer this widget always returns to, by confirmation or by revert.
  double? _pending;

  /// Armed by a tap, fires the one command for the gesture.
  Timer? _sendTimer;

  /// Armed by the send, fires the revert. Cancelled by the echo.
  Timer? _confirmTimer;

  /// Whether a command is out with no answer yet, and what the live target
  /// was when it left — "the target moved off [_sentAgainst]" is what an
  /// echo *is*. Null target-at-send means the state was unknown at send
  /// time; any live value that then appears is the Hub's answer.
  var _awaitingEcho = false;
  double? _sentAgainst;

  /// What the in-flight command actually said. While [_awaitingEcho] this —
  /// not the live target, which is exactly the number the echo has not
  /// updated yet — is what a new dial must be compared against, and it is
  /// the value `setpoint_unconfirmed` owes the journal: the live target and
  /// even [_pending] can both have moved on by the time the revert fires.
  double? _lastSent;

  ThermostatState? get _live {
    final state = widget.controller.presentationOf(widget.device).state;
    return state is ThermostatState ? state : null;
  }

  @override
  void initState() {
    super.initState();
    // Listened to directly rather than through an outer ListenableBuilder:
    // the echo rule below *mutates* state (clears the dialled value when the
    // Hub answers), and a listener is a legal place to do that where a build
    // method is not.
    widget.controller.addListener(_onHubChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onHubChanged);
    _confirmTimer?.cancel();
    if (_sendTimer != null) {
      _sendTimer!.cancel();
      // A dialled value whose debounce never fired still lands: whoever
      // tapped + and closed the Popup was told, by the number on the glass,
      // that they set it. No state to update — the widget is leaving — and
      // no echo to wait for, for the same reason.
      _flush();
    }
    super.dispose();
  }

  void _onHubChanged() {
    if (_awaitingEcho && _sendTimer == null) {
      final live = _live;
      // The echo: the Hub's target moved off where it stood when the
      // command left. Adopted whatever the new value is — ours confirmed,
      // ours quantised to the thermostat's grid, or another surface winning
      // the race — because the Hub's word is the honest thing to show in
      // all three. Skipped while a newer dial is still undelivered
      // (_sendTimer armed): that echo answers the previous command, and
      // clearing the newer dial on it would lose a tap.
      final sentAgainst = _sentAgainst;
      if (live != null &&
          (sentAgainst == null || (live.target - sentAgainst).abs() > _epsilon)) {
        _confirmTimer?.cancel();
        _confirmTimer = null;
        _pending = null;
        _awaitingEcho = false;
        _sentAgainst = null;
        _lastSent = null;
      }
    }
    if (mounted) setState(() {});
  }

  /// The step a tap means, decided by the unit the reading came in.
  static double _stepFor(TemperatureUnit? unit) =>
      unit == TemperatureUnit.fahrenheit ? 1.0 : 0.5;

  /// [value] snapped to the step grid — so a live target of 21.666 steps to
  /// 22.0, not 22.166, and the number sent is exactly the number shown.
  static double _snap(double value, double step) =>
      (value / step).roundToDouble() * step;

  void _dial(int direction) {
    final shown = _pending ?? _live?.target;
    if (shown == null) return; // buttons are disabled; belt and braces
    final step = _stepFor(_live?.unit);
    setState(() => _pending = _snap(shown + direction * step, step));
    _sendTimer?.cancel();
    _sendTimer = Timer(_sendAfter, _send);
  }

  /// Whether commanding [pending] now would command nothing new.
  ///
  /// Two different questions wearing one guard. With no command in flight,
  /// "already there" means the *live* target — +0.5 then −0.5 is a change
  /// of mind, not a command. With one in flight, the live target is exactly
  /// the number the echo has not updated yet, so comparing against it
  /// mis-reads a countermand as a no-op and silently loses the user's last
  /// action while the in-flight command goes on to move the real HVAC; the
  /// honest comparison there is against what that command *said*
  /// ([_lastSent]) — same value again is a duplicate, anything else must go
  /// out.
  bool _nothingToCommand(double pending) {
    if (_awaitingEcho) {
      final lastSent = _lastSent;
      return lastSent != null && (pending - lastSent).abs() < _epsilon;
    }
    final live = _live;
    return live != null && (pending - live.target).abs() < _epsilon;
  }

  void _send() {
    _sendTimer = null;
    final pending = _pending;
    if (pending == null || !mounted) return;
    if (_nothingToCommand(pending)) {
      if (_awaitingEcho) {
        // Re-dialled to the value already in flight: the command out there
        // says this already, and its echo/revert machinery is still armed —
        // the dialled value stays on display, a promise like any other,
        // until the Hub answers or the confirm window closes.
        return;
      }
      // Dialled back to where the thermostat already stands. Nothing to
      // command, and nothing to await: an echo for a no-op set may never
      // come, and waiting for it would end in a gratuitous
      // `setpoint_unconfirmed`.
      setState(() => _pending = null);
      return;
    }
    // ui-side line beside hub.set_target's: this one says what the wall
    // promised, that one says what reached the wire — refusals live between.
    Log.debug('ui', 'setpoint',
        {'device': widget.device.id, 'target': pending});
    // The whole awaiting-echo state is armed BEFORE the command goes out.
    // An in-process Hub applies the command synchronously: "where the
    // target stood when it left" read afterwards is already the commanded
    // value — which makes the echo invisible and every confirmed send
    // revert — and an echo delivered synchronously would find the await
    // not yet armed and slip past unconsumed.
    _sentAgainst = _live?.target;
    _lastSent = pending;
    _awaitingEcho = true;
    _confirmTimer?.cancel();
    _confirmTimer = Timer(_confirmWithin, _revert);
    widget.controller.setThermostatTarget(widget.device.id, pending);
  }

  /// The dispose-path send: same rule as [_send] minus every touch of
  /// state, because the widget is already leaving the tree.
  void _flush() {
    final pending = _pending;
    if (pending == null || _nothingToCommand(pending)) return;
    Log.debug('ui', 'setpoint',
        {'device': widget.device.id, 'target': pending});
    widget.controller.setThermostatTarget(widget.device.id, pending);
  }

  void _revert() {
    _confirmTimer = null;
    if (!_awaitingEcho || !mounted) return;
    // Warn, not debug — `ding_stale`'s argument: a setpoint that never
    // lands is a feature dying with no symptom beyond this line and the
    // number snapping back on a wall somebody may have already walked away
    // from. The Hub's own `command_failed` (rejection) or `reconnecting`
    // (nothing listening) says why; this says what it cost.
    //
    // The target named is what the unanswered command *carried* — never
    // [_pending], which by now can be a newer dial the person is still
    // making.
    Log.warn('ui', 'setpoint_unconfirmed',
        {'device': widget.device.id, 'target': _lastSent});
    _awaitingEcho = false;
    _sentAgainst = null;
    _lastSent = null;
    // The same guard the echo path holds, for the same reason: a dial whose
    // debounce is still open is a promise this revert is not about. Only
    // the answered-for value comes off the glass; the new gesture keeps its
    // number and its own send — which now compares against live state
    // again, the await having just ended.
    if (_sendTimer != null) return;
    setState(() => _pending = null);
  }

  @override
  Widget build(BuildContext context) {
    final live = _live;
    final shown = _pending ?? live?.target;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          // The same wording the pinless states have always used: an
          // unknown thermostat reads 'Unknown', a known one names its
          // reading — the unit said out loud here, pin-style bare degrees
          // never (device_presentation.dart).
          live == null
              ? 'Unknown'
              : '${DevicePresentation.degrees(live.current, live.unit)} now',
          style: const TextStyle(fontSize: 15, color: PanelTheme.ink),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _StepButton(
              key: const ValueKey('setpoint-minus'),
              icon: Icons.remove,
              onPressed: shown == null ? null : () => _dial(-1),
            ),
            SizedBox(
              // Wide enough for `-10.0 °F` so the buttons do not shuffle
              // as the number's width changes under a thumb mid-gesture.
              width: 132,
              child: Column(
                children: [
                  Text(
                    shown == null
                        ? '—'
                        : DevicePresentation.degrees(shown, live?.unit),
                    key: const ValueKey('setpoint-value'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      // Accent while the number is a promise rather than
                      // the Hub's word — the honest difference, visible.
                      color: _pending != null
                          ? PanelTheme.accent
                          : PanelTheme.ink,
                    ),
                  ),
                  const Text(
                    'target',
                    style:
                        TextStyle(fontSize: 11, color: PanelTheme.inkFaint),
                  ),
                ],
              ),
            ),
            _StepButton(
              key: const ValueKey('setpoint-plus'),
              icon: Icons.add,
              onPressed: shown == null ? null : () => _dial(1),
            ),
          ],
        ),
      ],
    );
  }
}

/// A −/+ button drawn like the Popup's header circle, sized for a thumb on
/// a wall: 56 px is comfortably past the usual 48 px touch minimum, on the
/// one screen in the house nobody operates with a mouse.
class _StepButton extends StatelessWidget {
  const _StepButton({super.key, required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Material(
      color: PanelTheme.surfaceRaised,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: enabled ? PanelTheme.raised(8) : null,
          ),
          child: Icon(icon,
              color: enabled ? PanelTheme.ink : PanelTheme.inkFaint),
        ),
      ),
    );
  }
}
