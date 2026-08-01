import 'house.dart';

/// Kind-keyed Device affordances, declared once for the whole Panel.
///
/// This is the single source for "does tapping this kind of Device flip a
/// binary state through the Hub" — the rule previously re-derived from state
/// shapes in the views, re-implemented in FakeHub.toggle, and stated as an
/// unowned comment on HubClient.toggle.
extension DeviceKindTraits on DeviceKind {
  /// Mirrors HubClient.toggle's contract: light, outlet, TV and garage door
  /// toggle; every other kind is observe-only from a tap.
  ///
  /// Exhaustive on purpose: adding a DeviceKind must force the author to
  /// declare its togglability, at compile time.
  bool get toggles => switch (this) {
        DeviceKind.light ||
        DeviceKind.outlet ||
        DeviceKind.tv ||
        DeviceKind.garageDoor =>
          true,
        DeviceKind.thermostat ||
        DeviceKind.camera ||
        DeviceKind.doorbell ||
        DeviceKind.oven ||
        DeviceKind.washer ||
        DeviceKind.dryer ||
        DeviceKind.litterRobot ||
        DeviceKind.feeder ||
        DeviceKind.evCharger ||
        DeviceKind.energyMonitor =>
          false,
      };
}
