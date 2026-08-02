import 'package:flutter_test/flutter_test.dart';
import 'package:panel/domain/device_state.dart';
import 'package:panel/domain/device_traits.dart';
import 'package:panel/domain/device_vocabulary.dart';

/// The table's own guarantees. Two of them the compiler already keeps —
/// [specOf] is exhaustive, so a new kind without a row does not build —
/// but the ones it cannot see are exactly the ones that used to drift when
/// this knowledge lived in seven files.
void main() {
  test('every kind has a row', () {
    // Redundant against the compiler by design: if `specOf` is ever
    // loosened to a map or a default arm, this is what notices.
    for (final kind in DeviceKind.values) {
      expect(() => specOf(kind), returnsNormally, reason: kind.name);
    }
  });

  test('the seed shape agrees with the declared family', () {
    // Nothing in the type system ties `family` to what `seed` returns, and
    // the generator switches on the seed's shape while the Hub fold
    // switches on the family — so a row that disagrees with itself would
    // emit a stand-in the Panel then refuses to read.
    for (final kind in DeviceKind.values) {
      final spec = specOf(kind);
      final seed = spec.seed('x');
      final expected = switch (spec.family) {
        StateFamily.toggle => SwitchState,
        StateFamily.garageDoor => GarageDoorState,
        StateFamily.thermostat => ThermostatState,
        StateFamily.power => PowerState,
        StateFamily.status => StatusState,
      };
      expect(seed.runtimeType, expected, reason: '${kind.name} seed shape');
      expect(seed.deviceId, 'x', reason: '${kind.name} seed carries its id');
    }
  });

  test('slugs are unique and round-trip', () {
    final slugs = [for (final k in DeviceKind.values) specOf(k).slug];
    expect(slugs.toSet(), hasLength(slugs.length), reason: 'duplicate slug');
    for (final kind in DeviceKind.values) {
      expect(kindFromSlug(specOf(kind).slug), kind);
    }
    expect(kindFromSlug('flux-capacitor'), isNull);
    expect(deviceKindSlugs, slugs);
  });

  test('slugs are kebab-case, matching the House Plan spelling', () {
    for (final slug in deviceKindSlugs) {
      expect(slug, matches(r'^[a-z0-9]+(-[a-z0-9]+)*$'));
    }
  });

  group('togglability is a House-side fact', () {
    test('exactly the on/off families toggle', () {
      // The safety rule, stated once: a thermostat tap must never reach
      // `homeassistant.toggle`, which would flip the real HVAC.
      expect(StateFamily.toggle.togglable, isTrue);
      expect(StateFamily.garageDoor.togglable, isTrue);
      expect(StateFamily.thermostat.togglable, isFalse);
      expect(StateFamily.power.togglable, isFalse);
      expect(StateFamily.status.togglable, isFalse);
    });

    test('the kind-shaped view still answers what callers were told', () {
      // `DeviceKindTraits.toggles` is what the views and both Hub adapters
      // call; absorbing the rule into the table must not have moved it.
      const toggling = {
        DeviceKind.light,
        DeviceKind.outlet,
        DeviceKind.tv,
        DeviceKind.garageDoor,
      };
      for (final kind in DeviceKind.values) {
        expect(kind.toggles, toggling.contains(kind), reason: kind.name);
      }
    });
  });
}
