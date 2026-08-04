import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/domain/device_state.dart';
import 'package:panel/domain/device_traits.dart';
import 'package:panel/domain/house.dart';
import 'package:panel/ui/device_presentation.dart';

/// The kind-by-state matrix, pinned without pumping a single widget: the
/// presentation module answers from pure values, so its tests are pure too.
void main() {
  Device device(DeviceKind kind) => Device(
        id: 'd1',
        name: 'Device',
        kind: kind,
        connectivity: Connectivity.local,
        position: Offset.zero,
      );

  DevicePresentation present(DeviceKind kind, DeviceState? state) =>
      DevicePresentation(device(kind), state);


  group('glows', () {
    test('switch on glows; switch off does not', () {
      expect(
          present(DeviceKind.light, const SwitchState('d1', on: true)).glows,
          isTrue);
      expect(
          present(DeviceKind.light, const SwitchState('d1', on: false)).glows,
          isFalse);
    });

    test('open garage door glows; closed does not', () {
      expect(
        present(DeviceKind.garageDoor,
                const GarageDoorState('d1', open: true))
            .glows,
        isTrue,
      );
      expect(
        present(DeviceKind.garageDoor,
                const GarageDoorState('d1', open: false))
            .glows,
        isFalse,
      );
    });

    test('thermostat, power, status and unknown states never glow', () {
      expect(
        present(DeviceKind.thermostat, _celsius(21.4, 21)).glows,
        isFalse,
      );
      expect(
        present(DeviceKind.energyMonitor, const PowerState('d1', watts: 812))
            .glows,
        isFalse,
      );
      expect(
        present(DeviceKind.washer, const StatusState('d1', 'Idle')).glows,
        isFalse,
      );
      expect(present(DeviceKind.light, null).glows, isFalse);
    });
  });

  group('reading', () {
    test('thermostat reads one-decimal degrees, unit-free whatever the Hub '
        'speaks', () {
      // The pin says the number and nothing more. At pin size the unit
      // letter is noise, and a bare `°` cannot contradict the Hub — so all
      // three of these render identically on the Dollhouse and only the
      // Popup distinguishes them.
      for (final state in [
        _celsius(21.4, 21),
        const ThermostatState('d1',
            current: 21.4, target: 21, unit: TemperatureUnit.fahrenheit),
        const ThermostatState('d1', current: 21.4, target: 21, unit: null),
      ]) {
        expect(present(DeviceKind.thermostat, state).reading, '21.4°');
      }
    });

    test('power under 1 kW reads whole watts', () {
      expect(
        present(DeviceKind.energyMonitor, const PowerState('d1', watts: 812))
            .reading,
        '812W',
      );
    });

    test('power at or above 1 kW reads one-decimal compact kW', () {
      expect(
        present(DeviceKind.energyMonitor, const PowerState('d1', watts: 1234))
            .reading,
        '1.2kW',
      );
    });

    test('switch, garage door, status and unknown states show the icon face',
        () {
      expect(present(DeviceKind.light, const SwitchState('d1', on: true)).reading,
          isNull);
      expect(
        present(DeviceKind.garageDoor, const GarageDoorState('d1', open: true))
            .reading,
        isNull,
      );
      expect(present(DeviceKind.washer, const StatusState('d1', 'Idle')).reading,
          isNull);
      expect(present(DeviceKind.light, null).reading, isNull);
    });

    test('icon comes from the one kind-keyed lookup', () {
      expect(present(DeviceKind.light, null).icon, Icons.lightbulb);
      expect(present(DeviceKind.doorbell, null).icon, Icons.doorbell);
    });
  });

  group('tapBehaviour', () {
    test('togglable kinds toggle even with unknown state', () {
      for (final kind in [
        DeviceKind.light,
        DeviceKind.outlet,
        DeviceKind.tv,
        DeviceKind.garageDoor,
      ]) {
        expect(present(kind, null).tapBehaviour, DeviceTapBehaviour.toggle,
            reason: '$kind with unknown state must still offer the toggle');
      }
    });

    test('video kinds pop up even if the Hub reports a switch-like state', () {
      expect(
        present(DeviceKind.camera, const SwitchState('d1', on: true))
            .tapBehaviour,
        DeviceTapBehaviour.showPopup,
      );
      expect(
        present(DeviceKind.doorbell, const SwitchState('d1', on: true))
            .tapBehaviour,
        DeviceTapBehaviour.showPopup,
      );
    });

    test('every kind answers the matrix', () {
      for (final kind in DeviceKind.values) {
        expect(
          present(kind, null).tapBehaviour,
          kind.toggles
              ? DeviceTapBehaviour.toggle
              : DeviceTapBehaviour.showPopup,
          reason: '$kind',
        );
      }
    });

    test('only cameras and the doorbell take the video Popup body', () {
      expect(
        DeviceKind.values.where((k) => present(k, null).isVideo).toSet(),
        {DeviceKind.camera, DeviceKind.doorbell},
      );
    });
  });

  group('statusText', () {
    test('switch wording: On/Off', () {
      expect(
          present(DeviceKind.light, const SwitchState('d1', on: true))
              .statusText,
          'On');
      expect(
          present(DeviceKind.light, const SwitchState('d1', on: false))
              .statusText,
          'Off');
    });

    test('garage door wording: Open/Closed', () {
      expect(
        present(DeviceKind.garageDoor, const GarageDoorState('d1', open: true))
            .statusText,
        'Open',
      );
      expect(
        present(DeviceKind.garageDoor,
                const GarageDoorState('d1', open: false))
            .statusText,
        'Closed',
      );
    });

    test('thermostat wording: now and target, in the Hub\'s own unit', () {
      expect(
        present(DeviceKind.thermostat, _celsius(21.4, 21)).statusText,
        '21.4 °C now · target 21.0 °C',
      );
    });

    test('a °F Hub reads °F on the wall — the number is never re-labelled',
        () {
      // The defect this pins: the house Hub is `us_customary`, so
      // climate.main_floor reports 83 and the Panel used to render
      // "83.0 °C now". Same numbers, honest suffix.
      expect(
        present(
                DeviceKind.thermostat,
                const ThermostatState('d1',
                    current: 83.0, target: 72.0, unit: TemperatureUnit.fahrenheit))
            .statusText,
        '83.0 °F now · target 72.0 °F',
      );
    });

    test('an unstated unit is rendered as no unit, never as a guess', () {
      // The Hub has not said (yet). A bare `°` is uninformative; a `°C`
      // here would be a claim the Panel has no basis for, and half the time
      // it would be wrong by 30 degrees.
      final text = present(
              DeviceKind.thermostat,
              const ThermostatState('d1', current: 83.0, target: 72.0, unit: null))
          .statusText;

      expect(text, '83.0° now · target 72.0°');
      expect(text, isNot(contains('C')));
      expect(text, isNot(contains('F')));
    });

    test('no thermostat wording can ever carry a unit the state did not name',
        () {
      // The property, over the whole matrix rather than three examples: a
      // unit letter appears in the Popup only when it came from the Hub.
      for (final unit in [...TemperatureUnit.values, null]) {
        final text = present(DeviceKind.thermostat,
                ThermostatState('d1', current: 83.0, target: 72.0, unit: unit))
            .statusText;
        for (final other in TemperatureUnit.values) {
          expect(text.contains(other.symbol), other == unit,
              reason: 'state in ${unit?.symbol ?? 'no unit'} rendered "$text"');
        }
      }
    });

    test("power full variant shares the pin's precision", () {
      final kilowatts =
          present(DeviceKind.energyMonitor, const PowerState('d1', watts: 1234));
      expect(kilowatts.reading, '1.2kW');
      expect(kilowatts.statusText, '1.2 kW');

      final watts =
          present(DeviceKind.energyMonitor, const PowerState('d1', watts: 812));
      expect(watts.reading, '812W');
      expect(watts.statusText, '812 W');
    });

    test('status state passes through; unknown reads Unknown', () {
      expect(
        present(DeviceKind.washer, const StatusState('d1', 'Cycle · 32 min'))
            .statusText,
        'Cycle · 32 min',
      );
      expect(present(DeviceKind.washer, null).statusText, 'Unknown');
    });
  });
}

/// A thermostat on a metric Hub — the ordinary case, spelled once so the
/// cases that are *about* the unit stand out.
ThermostatState _celsius(double current, double target) => ThermostatState('d1',
    current: current, target: target, unit: TemperatureUnit.celsius);
