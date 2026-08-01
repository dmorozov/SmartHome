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
        present(DeviceKind.thermostat,
                const ThermostatState('d1', currentC: 21.4, targetC: 21))
            .glows,
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
    test('thermostat reads one-decimal degrees', () {
      expect(
        present(DeviceKind.thermostat,
                const ThermostatState('d1', currentC: 21.4, targetC: 21))
            .reading,
        '21.4°',
      );
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

    test('thermostat wording: now and target', () {
      expect(
        present(DeviceKind.thermostat,
                const ThermostatState('d1', currentC: 21.4, targetC: 21))
            .statusText,
        '21.4 °C now · target 21.0 °C',
      );
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
