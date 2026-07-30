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

class ThermostatState extends DeviceState {
  const ThermostatState(
    super.deviceId, {
    required this.currentC,
    required this.targetC,
  });

  final double currentC;
  final double targetC;
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
