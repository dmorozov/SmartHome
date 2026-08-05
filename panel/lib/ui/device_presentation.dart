import 'package:flutter/widgets.dart' show IconData;

import '../domain/device_state.dart';
import '../domain/device_traits.dart';
import '../domain/house.dart';
import 'theme.dart';

/// What a tap on a Device pin does. Keyed on the Device's kind — the same
/// Device always answers the same — never on the live state's shape.
enum DeviceTapBehaviour { toggle, showPopup }

/// How one Device, given its kind and live state, looks and behaves on the
/// Panel: the pin's face, the tap's meaning, and the Popup's body and
/// wording — the whole kind-by-state matrix in one place.
///
/// Pure values in, pure answers out: no Hub, no BuildContext, no side
/// effects. The views render these answers; DollhouseView executes
/// [tapBehaviour]; HubController mints instances from live state.
class DevicePresentation {
  const DevicePresentation(this.device, this.state);

  final Device device;

  /// Live state from the Hub, or null when unknown (pre-snapshot,
  /// unavailable entity, or no entityId bound yet — ADR-0004 says an unbound
  /// Device still renders).
  final DeviceState? state;

  /// The pin glows: a switched Device that is on, or the garage door open
  /// (an open door is the attention-worthy state).
  bool get glows => switch (state) {
        SwitchState s => s.on,
        GarageDoorState g => g.open,
        _ => false,
      };

  /// Compact text face for the pin, or null for the icon face.
  String? get reading => switch (state) {
        // No unit on purpose, even when the Hub has stated one: at pin size
        // the letter is noise, and a bare `°` asserts nothing that could be
        // wrong. The Popup is where the unit gets said out loud.
        ThermostatState t => _degrees(t.current, null),
        PowerState p => _watts(p.watts, compact: true),
        _ => null,
      };

  IconData get icon => deviceIcon(device.kind);

  DeviceTapBehaviour get tapBehaviour => device.kind.toggles
      ? DeviceTapBehaviour.toggle
      : DeviceTapBehaviour.showPopup;

  /// Cameras and the doorbell get the live-view Popup body (the go2rtc
  /// stream lands there in phase 1); everything else gets [statusText].
  ///
  /// The list moved into the Device vocabulary because the House Plan
  /// loader now needs the same answer — a `stream:` on a light is refused
  /// at boot — and a kind fact spelled out in the UI *and* in the loader is
  /// a kind fact that drifts, which is the whole reason that table exists.
  bool get isVideo => specOf(device.kind).video;

  /// Full status wording for the Popup body.
  String get statusText => switch (state) {
        SwitchState s => s.on ? 'On' : 'Off',
        GarageDoorState g => g.open ? 'Open' : 'Closed',
        ThermostatState t =>
          '${_degrees(t.current, t.unit)} now · target ${_degrees(t.target, t.unit)}',
        PowerState p => _watts(p.watts, compact: false),
        StatusState s => s.status,
        null => 'Unknown',
      };

  /// The one power-formatting rule. Compact (pin) and full (Popup) variants
  /// differ only in spacing; precision is shared, so the pin and the Popup
  /// can never disagree about the number again.
  static String _watts(double watts, {required bool compact}) => watts >= 1000
      ? '${(watts / 1000).toStringAsFixed(1)}${compact ? 'kW' : ' kW'}'
      : '${watts.round()}${compact ? 'W' : ' W'}';

  /// The one temperature-formatting rule, and the only place the Panel is
  /// allowed to write a degree symbol.
  ///
  /// A null [unit] renders `21.4°` — not an abbreviated `°C`, but the
  /// reading of a temperature nobody has stated the unit of. That is the
  /// whole safety property: a suffix appears only when it came from the
  /// Hub, so the wall can be uninformative but never wrong.
  static String _degrees(double value, TemperatureUnit? unit) =>
      '${value.toStringAsFixed(1)}${unit == null ? '°' : ' ${unit.symbol}'}';
}
