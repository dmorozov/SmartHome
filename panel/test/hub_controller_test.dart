import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/fake_hub.dart';
import 'package:panel/data/hub_client.dart';
import 'package:panel/domain/device_state.dart';
import 'package:panel/domain/house.dart';
import 'package:panel/ui/hub_controller.dart';

import 'test_house.dart';

/// The controller's own policy — Room lighting and the Listenable fold —
/// exercised through its interface, with no widget pumping: FakeHub is the
/// Hub adapter, the real House Plan assets are the fixture.
void main() {
  late House house;
  late FakeHub hub;
  late HubController controller;

  setUp(() {
    house = loadTestHouse();
    // driftEvery: zero — no timer, so state only moves when a test moves it.
    hub = FakeHub(house, driftEvery: Duration.zero);
    controller = HubController(house: house, hub: hub);
  });

  tearDown(() => controller.dispose());

  Room roomOf(String id) =>
      house.floors.expand((f) => f.rooms).firstWhere((r) => r.id == id);

  Device deviceOf(String id) =>
      house.floors.expand((f) => f.devices).firstWhere((d) => d.id == id);

  Iterable<Device> lightsOf(Room room) =>
      room.devices.where((d) => d.kind == DeviceKind.light);

  /// FakeHub seeds lights randomly, so tests state the lighting they mean.
  Future<void> setLights(Room room, {required bool on}) async {
    for (final light in lightsOf(room)) {
      if ((hub.states[light.id] as SwitchState).on != on) {
        await hub.toggle(light.id);
      }
    }
  }

  test('presentationOf folds live Hub state into the answer', () async {
    final light = deviceOf('light-hall');
    final before = controller.presentationOf(light).glows;

    await hub.toggle(light.id);

    expect(controller.presentationOf(light).glows, !before);
  });

  test('presentationOf answers unknown for a Device the Hub never mentions',
      () {
    const stranger = Device(
      id: 'not-in-the-hub',
      name: 'Stranger',
      kind: DeviceKind.light,
      connectivity: Connectivity.local,
      position: Offset.zero,
    );

    expect(controller.presentationOf(stranger).state, isNull);
    expect(controller.presentationOf(stranger).statusText, 'Unknown');
  });

  test('isRoomLit is true when any light in the room is on; ignores non-lights',
      () async {
    final room = roomOf('family-room');
    await setLights(room, on: false);

    // The room also holds an outlet the fake Hub seeds on — a non-light
    // switch must not make the Room read as lit.
    expect((hub.states['outlet-outdoor-a'] as SwitchState).on, isTrue);
    expect(controller.isRoomLit(room), isFalse);

    await hub.toggle('light-reading');

    expect(controller.isRoomLit(room), isTrue);
  });

  test('toggleRoomLights turns every light on when none is lit', () async {
    final room = roomOf('family-room');
    await setLights(room, on: false);

    await controller.toggleRoomLights(room);

    expect(lightsOf(room).every((d) => controller.presentationOf(d).glows),
        isTrue);
  });

  test('toggleRoomLights turns every light off when any is lit', () async {
    final room = roomOf('family-room');
    await setLights(room, on: false);
    await hub.toggle('light-family'); // one lit is enough — all-or-nothing

    await controller.toggleRoomLights(room);

    expect(
        lightsOf(room).any((d) => controller.presentationOf(d).glows), isFalse);
  });

  test('notifies listeners on a Hub state change', () async {
    var notifications = 0;
    controller.addListener(() => notifications++);

    await hub.toggle('light-hall');
    await Future<void>.delayed(Duration.zero); // stream delivery is async

    expect(notifications, 1);
  });

  test('notifies listeners when the Hub link changes status', () {
    var notifications = 0;
    controller.addListener(() => notifications++);

    hub.setStatus(HubStatus.retrying);

    expect(notifications, 1);
    expect(controller.status, HubStatus.retrying);
  });
}
