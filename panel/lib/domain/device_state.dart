/// Live state of a Device, as reported by the Hub. One Device carries one
/// primary state here; the Hub's several-entities-per-device reality is the
/// HubClient implementation's concern to fold down.
sealed class DeviceState {
  const DeviceState(this.deviceId);

  final String deviceId;
}

/// Lights, outlets, TVs — anything that is simply on or off.
class SwitchState extends DeviceState {
  const SwitchState(super.deviceId, {required this.on});

  final bool on;
}

/// The unit a temperature reading is stated in.
///
/// It is an enum rather than a `bool isFahrenheit` because "the Hub has not
/// said yet" is a third answer the Panel has to be able to render, and
/// nullable-bool is how that gets guessed wrong.
enum TemperatureUnit {
  celsius('°C'),
  fahrenheit('°F');

  const TemperatureUnit(this.symbol);

  /// How the unit is written — on the wall, and by Home Assistant in
  /// `unit_system.temperature`. The same spelling both ways, which is what
  /// lets [fromSymbol] be its exact inverse instead of a second table.
  final String symbol;

  /// The unit a symbol names, or null for anything this Panel was not
  /// compiled against. Null is an answer, not a failure: a reading whose
  /// unit nobody has stated still renders, just without a suffix.
  static TemperatureUnit? fromSymbol(Object? symbol) {
    for (final unit in values) {
      if (unit.symbol == symbol) return unit;
    }
    return null;
  }
}

/// A thermostat's two numbers **and the unit they are in** — one value, not
/// a number plus a suffix somebody remembers to add downstream.
///
/// The fields were `currentC`/`targetC` and held whatever the Hub happened
/// to send. Home Assistant converts climate temperatures into the Hub's
/// configured unit system before they reach the API, and a `climate.*`
/// entity's attributes say nothing about which one that was (measured on
/// the house Hub: `current_temperature: 83`, no unit anywhere in the
/// payload) — so on a `us_customary` Hub the name asserted Celsius over a
/// Fahrenheit number and the wall read `83.0 °C`. A name that can be wrong
/// about its own contents is the defect; this pair cannot come apart.
class ThermostatState extends DeviceState {
  const ThermostatState(
    super.deviceId, {
    required this.current,
    required this.target,
    required this.unit,
  });

  final double current;
  final double target;

  /// Null until the Hub has said which unit it speaks — before the first
  /// `get_config` answer, or on a Hub whose unit this Panel cannot name.
  /// Renders unitless rather than assuming; see [TemperatureUnit].
  final TemperatureUnit? unit;
}

class GarageDoorState extends DeviceState {
  const GarageDoorState(super.deviceId, {required this.open});

  final bool open;
}

/// Instantaneous power reading (energy monitor, EV charger).
class PowerState extends DeviceState {
  const PowerState(super.deviceId, {required this.watts});

  final double watts;
}

/// Free-text status for appliances (washer, oven, feeders, litter robot…).
class StatusState extends DeviceState {
  const StatusState(super.deviceId, this.status);

  final String status;
}
