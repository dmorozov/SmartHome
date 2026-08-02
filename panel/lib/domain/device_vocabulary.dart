/// The Device vocabulary: every fact that follows from a Device's *kind*,
/// declared once.
///
/// Before this table the same knowledge was spelled out in seven places —
/// the loader's slug switch, FakeHub's seeds, HaHubClient's state fold, the
/// togglability extension, the dev-Hub generator's three seed maps, and the
/// live-Hub test's literals — so a new kind of hardware cost six or seven
/// coordinated edits, and the seed values had already been typed three
/// times. Now a kind is one row, and [specOf]'s exhaustive switch makes
/// omitting the row a compile error rather than a runtime surprise.
///
/// Deliberately pure Dart, importing only [DeviceState]: the dev-Hub
/// generator runs under plain `dart run` with no Flutter, and it must read
/// the same seeds FakeHub does or the two drift silently.
library;

import 'device_state.dart';

/// What kind of thing a Device is. Closed on purpose: the Panel renders
/// only kinds it was compiled against, so `deviceIcon`'s switch and this
/// table are both compiler-policed. Opening it would mean a total
/// string→icon mapping with a fallback arm — the trigger would be the Panel
/// rendering roles derived from the Hub, which is not this design.
enum DeviceKind {
  light,
  outlet,
  thermostat,
  camera,
  doorbell,
  oven,
  tv,
  washer,
  dryer,
  litterRobot,
  feeder,
  garageDoor,
  evCharger,
  energyMonitor,
}

/// Local Device: works with no vendor cloud. Cloud Device: grandfathered,
/// second-class — may lag or break (see CONTEXT.md).
enum Connectivity { local, cloud }

/// Which shape of [DeviceState] a kind reports. Mirrors the five sealed
/// subclasses 1:1 — these are the Panel's render archetypes, and a sixth
/// would mean a new way of drawing a Device, not just a new gadget.
enum StateFamily { toggle, garageDoor, thermostat, power, status }

extension StateFamilyTraits on StateFamily {
  /// Whether tapping a Device of this family flips it through the Hub.
  ///
  /// **Answered from the House, never from live state** — a light whose
  /// state is unknown still toggles. This is what stops a thermostat tap
  /// reaching `homeassistant.toggle`, which would flip the real HVAC, and
  /// it must stay availability-independent: a future capability-driven
  /// refinement may only ever *narrow* this using a resolved snapshot,
  /// never flicker with live state.
  bool get togglable => switch (this) {
        StateFamily.toggle || StateFamily.garageDoor => true,
        StateFamily.thermostat || StateFamily.power || StateFamily.status =>
          false,
      };
}

/// Everything that follows from one [DeviceKind].
class KindSpec {
  const KindSpec({
    required this.slug,
    required this.family,
    required this.seed,
  });

  /// How the kind is written in the House Plan, and in the converter's
  /// marker library. Kebab-case.
  final String slug;

  final StateFamily family;

  /// The state a kind starts in, for the two callers that must invent one:
  /// FakeHub's first paint, and the dev Hub's generated `initial:` values.
  /// Both read it here, so "the fake hub and the dev Hub agree" is true by
  /// construction rather than by three people typing 812 correctly.
  ///
  /// Its runtime type always matches [family] — pinned by a test, because
  /// nothing in the type system says so.
  final DeviceState Function(String deviceId) seed;
}

/// The table. Exhaustive: a new [DeviceKind] without a row here does not
/// compile, which is the whole point.
KindSpec specOf(DeviceKind kind) => switch (kind) {
      DeviceKind.light => KindSpec(
          slug: 'light',
          family: StateFamily.toggle,
          seed: (id) => SwitchState(id, on: false)),
      DeviceKind.outlet => KindSpec(
          slug: 'outlet',
          family: StateFamily.toggle,
          seed: (id) => SwitchState(id, on: true)),
      DeviceKind.tv => KindSpec(
          slug: 'tv',
          family: StateFamily.toggle,
          seed: (id) => SwitchState(id, on: false)),
      DeviceKind.garageDoor => KindSpec(
          slug: 'garage-door',
          family: StateFamily.garageDoor,
          seed: (id) => GarageDoorState(id, open: false)),
      DeviceKind.thermostat => KindSpec(
          slug: 'thermostat',
          family: StateFamily.thermostat,
          seed: (id) => ThermostatState(id, currentC: 21.4, targetC: 21.0)),
      DeviceKind.energyMonitor => KindSpec(
          slug: 'energy-monitor',
          family: StateFamily.power,
          seed: (id) => PowerState(id, watts: 812)),
      DeviceKind.evCharger => KindSpec(
          slug: 'ev-charger',
          family: StateFamily.power,
          seed: (id) => PowerState(id, watts: 0)),
      DeviceKind.washer => KindSpec(
          slug: 'washer',
          family: StateFamily.status,
          seed: (id) => StatusState(id, 'Idle')),
      DeviceKind.dryer => KindSpec(
          slug: 'dryer',
          family: StateFamily.status,
          seed: (id) => StatusState(id, 'Cycle · 32 min left')),
      DeviceKind.oven => KindSpec(
          slug: 'oven',
          family: StateFamily.status,
          seed: (id) => StatusState(id, 'Off')),
      DeviceKind.litterRobot => KindSpec(
          slug: 'litter-robot',
          family: StateFamily.status,
          seed: (id) => StatusState(id, 'Clean · cycled 2 h ago')),
      DeviceKind.feeder => KindSpec(
          slug: 'feeder',
          family: StateFamily.status,
          seed: (id) => StatusState(id, 'Next meal 5:00 pm')),
      DeviceKind.camera => KindSpec(
          slug: 'camera',
          family: StateFamily.status,
          seed: (id) => StatusState(id, 'Live')),
      DeviceKind.doorbell => KindSpec(
          slug: 'doorbell',
          family: StateFamily.status,
          seed: (id) => StatusState(id, 'Live')),
    };

/// The kind a House Plan slug names, or null if it names nothing. Callers
/// own the error, because they know which file the slug came from and what
/// the reader should do about it.
DeviceKind? kindFromSlug(String slug) {
  for (final kind in DeviceKind.values) {
    if (specOf(kind).slug == slug) return kind;
  }
  return null;
}

/// Every slug the House Plan may use, in enum order — for error messages
/// that tell the reader what *is* allowed.
Iterable<String> get deviceKindSlugs =>
    DeviceKind.values.map((k) => specOf(k).slug);
