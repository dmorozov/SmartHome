import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/fake_hub.dart';
import 'package:panel/data/ha_hub.dart';
import 'package:panel/domain/device_state.dart';

import 'support/fake_channel.dart';
import 'test_house.dart';

final order = <String>[];

void main() {
  // ── 1. Does addTearDown run BEFORE or AFTER the group tearDown? ──
  group('ordering', () {
    tearDown(() => order.add('group tearDown'));

    test('a', () {
      addTearDown(() => order.add('addTearDown #1'));
      addTearDown(() => order.add('addTearDown #2'));
      order.add('body');
    });

    test('report', () {
      // ignore: avoid_print
      print('ORDER => $order');
    });
  });

  // ── 2. FakeHub post-dispose behaviour ──
  test('FakeHub pushState after dispose', () {
    final hub = FakeHub(loadTestHouse(), driftEvery: Duration.zero);
    hub.dispose();
    Object? err;
    try {
      hub.pushState(const SwitchState('light-hall', on: true));
    } on Object catch (e) {
      err = e;
    }
    // ignore: avoid_print
    print('FAKE pushState post-dispose => $err');
  });

  test('FakeHub setReachable after dispose', () {
    final hub = FakeHub(loadTestHouse(), driftEvery: Duration.zero);
    hub.dispose();
    Object? err;
    try {
      hub.setReachable(false);
    } on Object catch (e) {
      err = e;
    }
    // ignore: avoid_print
    print('FAKE setReachable post-dispose => $err');
  });

  // ── 3. HaHubClient: same staging, post-dispose ──
  test('HaHub push/drop after dispose', () async {
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
    hub.dispose();

    Object? pushErr;
    try {
      channel.serverSays(
          stateChangedFrame(entityFrame('input_boolean.light_hall', 'on')));
      await pumpEventQueue();
    } on Object catch (e) {
      pushErr = e;
    }
    // ignore: avoid_print
    print('HA push post-dispose => $pushErr; '
        'state=${hub.states['light-hall']}');

    Object? dropErr;
    try {
      channel.serverDrops();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    } on Object catch (e) {
      dropErr = e;
    }
    // ignore: avoid_print
    print('HA dropHub post-dispose => $dropErr');

    // And what happens if a frame DOES reach _applyEntity post-dispose?
    // Force it by re-running the handshake on the live channel.
    Object? handshakeErr;
    try {
      channel.serverSays({'type': 'auth_required'});
      await pumpEventQueue();
    } on Object catch (e) {
      handshakeErr = e;
    }
    // ignore: avoid_print
    print('HA handshake post-dispose => $handshakeErr');
  });
}
