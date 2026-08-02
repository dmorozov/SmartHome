import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/fake_hub.dart';
import 'package:panel/data/ha_hub.dart';
import 'package:panel/domain/device_state.dart';

import 'support/fake_channel.dart';
import 'test_house.dart';

final order = <String>[];

void main() {
  // ── Q1. Does addTearDown run BEFORE or AFTER the group tearDown? ──
  group('ordering', () {
    setUp(() => order.add('-- setUp'));
    tearDown(() => order.add('group tearDown (dispose lives here)'));

    test('case', () {
      addTearDown(() => order.add('addTearDown #1'));
      addTearDown(() => order.add('addTearDown #2'));
      order.add('test body');
    });
  });

  test('ZZZ report ordering', () {
    // ignore: avoid_print
    print('ORDERING => ${order.join(" | ")}');
  });

  // ── Q2. FakeHub post-dispose ──
  test('FakeHub post-dispose behaviour', () {
    final a = FakeHub(loadTestHouse(), driftEvery: Duration.zero);
    a.dispose();
    Object? pushErr;
    try {
      a.pushState(const SwitchState('light-hall', on: true));
    } on Object catch (e) {
      pushErr = e;
    }

    final b = FakeHub(loadTestHouse(), driftEvery: Duration.zero);
    b.dispose();
    Object? reachErr;
    try {
      b.setReachable(false);
    } on Object catch (e) {
      reachErr = e;
    }
    // ignore: avoid_print
    print('FAKE pushState post-dispose => ${pushErr.runtimeType}: $pushErr');
    // ignore: avoid_print
    print('FAKE setReachable post-dispose => ${reachErr.runtimeType}');
  });

  // ── Q3. HaHubClient: is the *same* staging really silent post-dispose? ──
  test('HaHubClient post-dispose behaviour', () async {
    late FakeChannel channel;
    final hub = HaHubClient(
      house: loadTestHouse(),
      url: Uri.parse('ws://test/api/websocket'),
      token: 't',
      connect: (_) => channel = FakeChannel(),
      retryFloor: const Duration(milliseconds: 1),
      retryCeiling: const Duration(milliseconds: 2),
    );
    await connectAndSeed(channel, [
      entityFrame('input_boolean.light_hall', 'off'),
    ]);
    expect(hub.connected.value, isTrue);
    hub.dispose();

    // (a) "push a state" — the HaHub analogue of pushState.
    Object? pushErr;
    try {
      channel.serverSays(
          stateChangedFrame(entityFrame('input_boolean.light_hall', 'on')));
      await pumpEventQueue();
    } on Object catch (e) {
      pushErr = e;
    }
    // ignore: avoid_print
    print('HA push post-dispose => err=$pushErr '
        'state=${hub.states['light-hall']} '
        '(did the frame even reach _applyEntity? state stays off if not)');

    // (b) "drop the Hub" — the HaHub analogue of setReachable(false).
    Object? dropErr;
    try {
      channel.serverDrops();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    } on Object catch (e) {
      dropErr = e;
    }
    // ignore: avoid_print
    print('HA dropHub post-dispose => err=$dropErr');

    // (c) "the Hub returns" — the HaHub analogue of setReachable(true).
    //     auth_ok sets connected.value with NO _disposed guard.
    Object? returnErr;
    try {
      await connectAndSeed(channel, const []);
    } on Object catch (e) {
      returnErr = e;
    }
    // ignore: avoid_print
    print('HA returnHub post-dispose => ${returnErr.runtimeType}: $returnErr');
  });

  // ── Q4. Does a post-dispose stage from addTearDown actually break? ──
  group('the finding\'s claimed scenario, run for real', () {
    late FakeHub hub;
    setUp(() => hub = FakeHub(loadTestHouse(), driftEvery: Duration.zero));
    tearDown(() => hub.dispose());

    test('stages state from an addTearDown', () {
      addTearDown(() {
        try {
          hub.pushState(const SwitchState('light-hall', on: true));
          // ignore: avoid_print
          print('SCENARIO addTearDown push => OK (no throw)');
        } on Object catch (e) {
          // ignore: avoid_print
          print('SCENARIO addTearDown push => THREW $e');
        }
      });
      expect(hub.togglable('light-hall'), isTrue);
    });
  });
}
