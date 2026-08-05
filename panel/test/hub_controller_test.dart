import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/fake_hub.dart';
import 'package:panel/data/hub_client.dart';
import 'package:panel/diagnostics/log.dart';
import 'package:panel/domain/device_state.dart';
import 'package:panel/domain/house.dart';
import 'package:panel/ui/hub_controller.dart';

import 'test_house.dart';

/// The controller's own policy — Room lighting, the Listenable fold, and the
/// doorbell memory the ding rule needs but deliberately does not keep —
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

  /// Collects every line emitted from here to the end of the test. Local
  /// rather than in [setUp] because most of this file has no opinion about
  /// the log, and a suite-wide sink would silence the output of the tests
  /// that do not.
  List<LogRecord> captureLogs() {
    final records = <LogRecord>[];
    final was = Log.level;
    Log.sink = records.add;
    Log.level = LogLevel.debug;
    addTearDown(() {
      Log.sink = Log.printRecord;
      Log.level = was;
    });
    return records;
  }

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

  test('a Room id prints raw on the debug line, which is an accepted residual '
      'and not an oversight', () {
    // Measured: `D ui.room_lights room=rtsp://admin:hunter2@192.168.68.44/live`
    // — a Room id is hand-typed in house.yaml, so a URL can be one, and
    // `house_loader.dart` withholds exactly this shape from `house.invalid`.
    //
    // Accepted here, on the terms `hub_controller.dart` states at the call
    // site and `bindings_parser.dart` states for `_streamName`: an id that
    // reaches the UI **survived the load**, and a mis-paste never does (it
    // throws), so this needs the URL to have been typed as an id on purpose.
    // The id is also the entire content of the line, and `D` is off in the
    // release build the appliance runs.
    //
    // Pinned as an expectation so that changing the decision means changing a
    // test, rather than discovering the residual a sixth time.
    final records = captureLogs();
    const pasted = 'rtsp://admin:hunter2@192.168.68.44/live';

    controller.toggleRoomLights(
        const Room(id: pasted, name: 'Den', footprint: []));

    expect(records.singleWhere((r) => r.event == 'room_lights').toString(),
        '[panel] D ui.room_lights room=$pasted was_lit=false lights=0');
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

  // ── The doorbell ────────────────────────────────────────────────────────
  //
  // The rule itself lives in `doorbell_test.dart`; what is tested here is
  // the memory around it, which is where every false-fire actually comes
  // from. Each of these scenes ends with a Ring cloud session opened for
  // nobody if the controller gets it wrong (#177014).

  /// Every ring the controller has announced since this was called.
  List<Device> ringsFrom(HubController from) {
    final rings = <Device>[];
    final sub = from.doorbellRings.listen(rings.add);
    addTearDown(sub.cancel);
    return rings;
  }

  /// The Hub reports a doorbell state, and the stream delivery it triggers
  /// is flushed. Not two pushes in a row without this: the change stream
  /// carries ids and the value is read back out of `states`, so two reports
  /// inside one microtask would read as one.
  Future<void> reports(FakeHub from, String state) async {
    from.pushState(StatusState('doorbell', state));
    await pumpEventQueue();
  }

  test('a scripted press announces exactly one ring', () async {
    final rings = ringsFrom(controller);
    final records = captureLogs();

    await reports(hub, 'off');
    await reports(hub, 'on');

    expect(rings.map((d) => d.id), ['doorbell']);
    expect(
        records
            .where((r) => r.area == 'ui' && r.event == 'ding')
            .single
            .fields,
        {'device': 'doorbell', 'entity_state': 'on'});
  });

  test('a reconnect that re-states the same ding does not ring the house',
      () async {
    // The regression this whole classifier exists for. `_applyEntity` emits
    // a change for every usable message with no equality check, and a
    // reconnect replays the entire snapshot — so before the rule, every
    // router reboot rang the house.
    final rings = ringsFrom(controller);
    await reports(hub, 'off');
    await reports(hub, 'on');
    expect(rings, hasLength(1));

    hub.setStatus(HubStatus.retrying);
    hub.setStatus(HubStatus.up);
    await reports(hub, 'on');

    expect(rings, hasLength(1));
  });

  test('a doorbell that drops to unavailable and comes back has not rung, '
      'whatever it says on the way back', () async {
    // The memory is forgotten with the state, not kept. Kept, the value after
    // the gap is an edge against a belief the Panel no longer holds — so
    // `off` → unavailable → `on` rings the house with nobody at the door.
    // Forgotten, it is a first sight, and a first sight of a word is silence.
    final rings = ringsFrom(controller);
    await reports(hub, 'off');
    await reports(hub, 'on');
    expect(rings, hasLength(1));

    // Back with the same value — the only case the old sticky memory covered.
    hub.dropDevice('doorbell');
    await pumpEventQueue();
    await reports(hub, 'on');
    expect(rings, hasLength(1));

    // Back with a *different* value, which is the one that used to fire. An
    // integration reload, an MQTT broker blip or a Ring cloud hiccup
    // round-trips the entity through `unavailable` without the Panel's socket
    // ever dropping, so `HubStatus` never leaves `up` and the link-drop clear
    // never runs.
    await reports(hub, 'off');
    hub.dropDevice('doorbell');
    await pumpEventQueue();
    await reports(hub, 'on');

    expect(rings, hasLength(1), reason: 'nobody pressed anything');
  });

  test('a state this rule cannot read does not deafen the next real press',
      () async {
    // `ringing` is remembered like any other value — the memory is only
    // dropped when the Hub stops reporting the entity at all — so the `on`
    // after it is still an edge.
    final rings = ringsFrom(controller);
    await reports(hub, 'off');
    await reports(hub, 'ringing');
    await reports(hub, 'on');

    expect(rings, hasLength(1));
  });

  test('the first change after boot rings: the controller adopts the state '
      'the Hub was already holding', () async {
    // `FakeHub` seeds every Device in its own constructor and emits on a
    // broadcast stream before the controller exists, so a memory filled only
    // from `stateChanges` starts empty and swallows the first real edge as a
    // first sight. `Live` is the seed; `on` after it is an edge.
    expect((hub.states['doorbell'] as StatusState).status, 'Live');
    final rings = ringsFrom(controller);

    await reports(hub, 'on');

    expect(rings.map((d) => d.id), ['doorbell']);
  });

  test('a press that lands before the integration has ever reported is not '
      'lost: the press time answers for itself', () async {
    // After an HA restart the Ring integration can be a minute behind the
    // Hub, so the reconnect snapshot has no doorbell in it at all and the
    // Panel's first sight of the entity is the press. With the
    // `event.*_ding` shape that costs nothing — the state *is* the time.
    final now = DateTime.utc(2026, 8, 4, 19, 30);
    final ownHub = FakeHub(house, driftEvery: Duration.zero);
    final loading = HubController(house: house, hub: ownHub, clock: () => now);
    addTearDown(loading.dispose);
    final rings = ringsFrom(loading);

    ownHub.setStatus(HubStatus.retrying);
    ownHub.setStatus(HubStatus.up);
    ownHub.dropDevice('doorbell');
    await pumpEventQueue();
    await reports(
        ownHub, now.subtract(const Duration(seconds: 2)).toIso8601String());

    expect(rings, hasLength(1));
  });

  test('an entity that drops out and re-reports the same press time rings '
      'once, not twice', () async {
    // Where the two earlier fixes meet: the memory is dropped when the entity
    // goes away, and a timestamp is judged on its age rather than vetoed on
    // first sight. Together they made a re-reported *identical* press time a
    // second ding — two Ring sessions for one press, which #177014 says
    // suppresses the next real one. The press time is an identity as well as
    // an age, and the press already answered is remembered separately: that
    // memory can only silence, never ring, so unlike the belief beside it, it
    // is safe to keep across the gap.
    final now = DateTime.utc(2026, 8, 4, 19, 30);
    final press = now.subtract(const Duration(seconds: 5)).toIso8601String();
    final ownHub = FakeHub(house, driftEvery: Duration.zero);
    final ringing = HubController(house: house, hub: ownHub, clock: () => now);
    addTearDown(ringing.dispose);
    final rings = ringsFrom(ringing);
    final records = captureLogs();

    await reports(ownHub, 'off');
    await reports(ownHub, press);
    expect(rings, hasLength(1));

    // No socket ever drops here: an HA integration reload or an MQTT blip
    // round-trips the entity through `unavailable` with the link still `up`.
    ownHub.dropDevice('doorbell');
    await pumpEventQueue();
    await reports(ownHub, press);
    expect(rings, hasLength(1), reason: 'the same press, reported twice');

    // A reconnect replays the whole snapshot, which is the same replay by
    // another route — and it must not ring either.
    ownHub.setStatus(HubStatus.retrying);
    ownHub.setStatus(HubStatus.up);
    await reports(ownHub, press);
    expect(rings, hasLength(1));

    // Debug and named, so "it rang once for three reports" can be read back
    // rather than inferred. Before this it claimed `ding_stale`, sending
    // whoever held the log to check NTP over a Panel behaving exactly right.
    expect(records.where((r) => r.event == 'ding_stale'), isEmpty);
    final suppressed = records.where((r) =>
        r.event == 'ding_suppressed' && r.fields?['reason'] == 'already_rung');
    expect(suppressed, hasLength(2));

    // The next press is a different press, and it rings.
    await reports(
        ownHub, now.subtract(const Duration(seconds: 1)).toIso8601String());
    expect(rings, hasLength(2));
  });

  test('a press time already in the snapshot at boot is never rung for, and '
      'an entity blip does not turn it into a ding', () async {
    // The controller adopts what the Hub already holds, so the boot value is
    // `unchanged` and stays silent — a press from before the Panel existed is
    // not this Panel's to announce. Without recording it as answered, the
    // first `unavailable` round-trip afterwards would ring the house for it,
    // which is the same press showing up late having never shown up at all.
    final now = DateTime.utc(2026, 8, 4, 19, 30);
    final press = now.subtract(const Duration(seconds: 5)).toIso8601String();
    final ownHub = FakeHub(house, driftEvery: Duration.zero);
    ownHub.pushState(StatusState('doorbell', press));
    final booted = HubController(house: house, hub: ownHub, clock: () => now);
    addTearDown(booted.dispose);
    final rings = ringsFrom(booted);

    ownHub.dropDevice('doorbell');
    await pumpEventQueue();
    await reports(ownHub, press);

    expect(rings, isEmpty);
  });

  test('a doorbell state in neither shape rings nothing and leaves the string '
      'it could not read', () async {
    final rings = ringsFrom(controller);
    final records = captureLogs();

    await reports(hub, 'off');
    await reports(hub, 'ringing');
    // Once per *entry* into the unreadable state, not once per message —
    // an entity that says `ringing` forever must not fill journald.
    await reports(hub, 'ringing');

    expect(rings, isEmpty);
    final unreadable =
        records.where((r) => r.event == 'ding_unreadable').single;
    expect(unreadable.level, LogLevel.warn);
    expect(unreadable.fields, {
      'device': 'doorbell',
      'state': 'ringing',
      'expected': 'on|off|<iso8601>',
    });
  });

  test('a ding stamped before the Panel\'s patience is a ding that is over, '
      'and the log says how old — a drifting appliance clock is otherwise '
      'indistinguishable from a doorbell nobody presses', () async {
    final now = DateTime.utc(2026, 8, 4, 19, 30);
    // Its own Hub as well as its own controller: HubController.dispose
    // disposes the Hub it was given, and disposing FakeHub twice would take
    // the shared one down mid-suite.
    final ownHub = FakeHub(house, driftEvery: Duration.zero);
    final aged = HubController(house: house, hub: ownHub, clock: () => now);
    addTearDown(aged.dispose);
    final rings = ringsFrom(aged);
    final records = captureLogs();

    await reports(ownHub, 'off');
    await reports(
        ownHub, now.subtract(const Duration(seconds: 5)).toIso8601String());
    expect(rings, hasLength(1), reason: 'a press five seconds ago is a press');

    await reports(
        ownHub, now.subtract(const Duration(minutes: 10)).toIso8601String());

    expect(rings, hasLength(1));
    final stale = records.where((r) => r.event == 'ding_stale').single;
    expect(stale.level, LogLevel.warn);
    expect(stale.fields, {'device': 'doorbell', 'age_s': 600});
  });
}
