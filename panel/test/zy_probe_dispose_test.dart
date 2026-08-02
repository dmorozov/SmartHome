import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/fake_hub.dart';
import 'package:panel/data/ha_hub.dart';
import 'package:panel/domain/device_state.dart';

import 'support/fake_channel.dart';
import 'test_house.dart';

final probe = <String>[];

void main() {
  // Q1 — the finding's premise: "registered callbacks run AFTER the group
  // tearDown's dispose". Settle it.
  group('ordering', () {
    setUp(() => probe.add('setUp'));
    tearDown(() => probe.add('group tearDown  <-- world.dispose() lives here'));

    test('a case that registers addTearDown', () {
      addTearDown(() => probe.add('addTearDown #1'));
      addTearDown(() => probe.add('addTearDown #2'));
      probe.add('test body');
    });
  });

  test('zy report ordering', () {
    // ignore: avoid_print
    print('ZY-ORDER => ${probe.join("  >  ")}');
  });

  // Q2 — the finding's literal scenario, run for real: a case in a group
  // whose tearDown disposes, staging state from an addTearDown.
  group('finding scenario verbatim', () {
    late FakeHub hub;
    setUp(() => hub = FakeHub(loadTestHouse(), driftEvery: Duration.zero));
    tearDown(() => hub.dispose());

    test('stages state from an addTearDown', () {
      addTearDown(() {
        try {
          hub.pushState(const SwitchState('light-hall', on: true));
          hub.dropDevice('thermostat');
          hub.setReachable(false);
          // ignore: avoid_print
          print('ZY-SCENARIO => no throw; staging from addTearDown is fine');
        } on Object catch (e) {
          // ignore: avoid_print
          print('ZY-SCENARIO => THREW ${e.runtimeType}: $e');
        }
      });
      expect(hub.togglable('light-hall'), isTrue);
    });
  });

  // Q3 — FakeHub genuinely used after dispose.
  test('zy FakeHub post-dispose', () {
    final a = FakeHub(loadTestHouse(), driftEvery: Duration.zero);
    a.dispose();
    Object? push;
    try {
      a.pushState(const SwitchState('light-hall', on: true));
    } on Object catch (e) {
      push = e;
    }
    final b = FakeHub(loadTestHouse(), driftEvery: Duration.zero);
    b.dispose();
    Object? reach;
    try {
      b.setReachable(false);
    } on Object catch (e) {
      reach = e;
    }
    // ignore: avoid_print
    print('ZY-FAKE push=${push.runtimeType} reach=${reach.runtimeType}');
  });

  // Q4 — is HaHubClient really "silent" on the same sequence, and WHY?
  test('zy HaHubClient post-dispose', () async {
    late FakeChannel channel;
    final hub = HaHubClient(
      house: loadTestHouse(),
      url: Uri.parse('ws://test/api/websocket'),
      token: 't',
      connect: (_) => channel = FakeChannel(),
      retryFloor: const Duration(milliseconds: 1),
      retryCeiling: const Duration(milliseconds: 2),
    );
    await connectAndSeed(
        channel, [entityFrame('input_boolean.light_hall', 'off')]);
    expect(hub.connected.value, isTrue);
    hub.dispose();

    Object? push;
    try {
      channel.serverSays(
          stateChangedFrame(entityFrame('input_boolean.light_hall', 'on')));
      await pumpEventQueue();
    } on Object catch (e) {
      push = e;
    }
    // ignore: avoid_print
    print('ZY-HA push=${push.runtimeType} '
        'state=${hub.states['light-hall']} (still off => frame never reached '
        '_applyEntity, so the isClosed guard was not what saved it)');

    Object? drop;
    try {
      channel.serverDrops();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    } on Object catch (e) {
      drop = e;
    }
    // ignore: avoid_print
    print('ZY-HA drop=${drop.runtimeType}');

    Object? ret;
    try {
      await connectAndSeed(channel, const []);
    } on Object catch (e) {
      ret = e;
    }
    // ignore: avoid_print
    print('ZY-HA return=${ret.runtimeType} connected=?');
  });
}
