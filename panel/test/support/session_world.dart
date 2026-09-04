import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/ui/video/live_video.dart';

/// The hands that move one [LiveVideoSession] adapter's world, so the seam's
/// invariants can be stated once and executed against every adapter —
/// `test/hub_contract_test.dart`'s shape, one seam down.
///
/// Every assertion in [runSessionContract] is about `LiveVideoSession`, and
/// most cross it directly; two cannot. "Born muted" and "drops the
/// connection" have no expression on the interface at all — nothing there
/// reports either — so those two read the [muted] and [connectionOpen]
/// witnesses below. Every other closure only stages the scenario, each in
/// whatever way its adapter's world actually works (a real socket for MJPEG,
/// a hand-driven controller for RTSP, a notifier for the fake).
///
/// A null closure means the invariant cannot be staged for that adapter. Two
/// of them retire a whole case, and those are declared at the call site
/// ([runSessionContract]'s `noFailureText` and `noOpener`) so the runner
/// prints the reason: a green line that exercised nothing is how "every
/// adapter is covered" stops being true.
typedef SessionWorld = ({
  /// Opens through the adapter's own opener where it has one, and records
  /// the session so the closures below can drive it.
  Future<LiveVideoSession> Function() open,

  /// Stage a first picture. Null where the adapter cannot reach playing —
  /// the settled session, which is over before it begins.
  Future<void> Function()? reachPlaying,

  /// Stage a refusal or a silence, after [open] (and [reachPlaying] where the
  /// case ran it). Null only where the adapter cannot be made to fail at all
  /// — the settled session, which is born that way. Whether the words it
  /// then composes are its OWN is a separate question, and the answer to
  /// that one is `noFailureText` at the call site.
  Future<void> Function()? fail,

  /// Whether the transport still holds its connection. Null where the
  /// adapter has no connection of its own to drop: the settled session, and
  /// the pool's lease, which by design hands the running session back rather
  /// than closing it (`live_video.dart` says the drop is a *player's* half of
  /// the contract, and names the pool as the caller-visible exception).
  bool Function()? connectionOpen,

  /// Whether the transport's audio is muted right now. Null where the
  /// adapter carries no audio to witness (MJPEG) or has no player at all.
  bool Function()? muted,

  /// An open through the adapter's real opener that cannot possibly work.
  /// Synchronous on purpose: what invariant 5 is about is that the opener
  /// does not THROW at the call site, and an async wrapper would turn a
  /// throw into a rejected future and pass. Null where the adapter has no
  /// opener of its own — say so in [runSessionContract]'s `noOpener`.
  LiveVideoSession Function()? openBroken,

  /// Strings the adapter's own failure text may never contain — the host,
  /// port and password of the URL it was handed. Empty where the adapter
  /// composes no failure text of its own.
  List<String> forbiddenInFailure,

  Future<void> Function() dispose,
});

/// The `LiveVideoSession` contract, run against every adapter the VM can
/// host.
///
/// Six invariants, stated in prose on the interface (`live_video.dart`) and
/// executed here, less the one clause named in case 2 — before this suite
/// each was pinned adapter-by-adapter in five files, each in its own words
/// and each covering a different subset, and the fake that four widget
/// suites drive was held to none of them. An invariant the fake honours and
/// a player violates, or the reverse, now has somewhere to fail.
///
/// What is deliberately NOT here: anything one transport alone owes.
/// Multipart framing, the RTSP frame pulse, the `setMuted`-vs-initialize
/// race, the pool's grace window and the MSE reconnect stay in their own
/// suites, which is where a reader looking for them would go.
///
/// [noFailureText], [noOpener] and [settlesUnsupportedFromLive] are the
/// exemptions an adapter may claim, and they are spelled at the call site
/// rather than read off the world because a group's `skip:` is decided when
/// the group is declared, before any world is built. Each is the REASON,
/// printed by the runner, so an exemption is a sentence somebody had to
/// write rather than a case that quietly vanished. Omit one you needed and
/// the case does not pass — it fails on the null closure it was going to
/// drive. Claim one you did not need and nothing goes red: the case is
/// skipped, and a skip is green, so it is the reason above and not the
/// runner that has to catch you.
void runSessionContract(
  String adapter,
  Future<SessionWorld> Function() build, {
  String? noFailureText,
  String? noOpener,
  bool settlesUnsupportedFromLive = false,
}) {
  group('LiveVideoSession contract · $adapter', () {
    late SessionWorld world;

    setUp(() async => world = await build());
    tearDown(() async => world.dispose());

    /// Opens and records every phase the session ever wears, born value
    /// first — a listener never fires for the value it was born with.
    Future<(LiveVideoSession, List<LiveVideoPhase>)> opened() async {
      final session = await world.open();
      final seen = <LiveVideoPhase>[session.phase.value];
      void record() => seen.add(session.phase.value);
      session.phase.addListener(record);
      addTearDown(() => session.phase.removeListener(record));
      return (session, seen);
    }

    test('1 · the failure text names a type or go2rtc\'s own words, never '
        'the URL it dialled', () async {
      final (session, _) = await opened();
      await world.fail!();
      await _until(() => session.failure != null,
          because: 'a failed session owes the log a sentence');
      for (final secret in world.forbiddenInFailure) {
        expect(session.failure, isNot(contains(secret)),
            reason: 'a fat-fingered GO2RTC_URL can carry a password, and '
                '`dart:io`\'s own HttpException appends `uri = …`');
      }
    }, skip: noFailureText);

    test('2 · view is stable across calls, so a rebuild does not tear the '
        'picture down and put it back', () async {
      final (session, _) = await opened();
      final first = session.view;
      expect(identical(session.view, first), isTrue,
          reason: 'the Popup rebuilds this getter on every phase change, and '
              'the pool mounts one session\'s view more than once');
      if (world.reachPlaying != null) {
        await world.reachPlaying!();
        expect(identical(session.view, first), isTrue,
            reason: 'stable within one dial, across the phase change too');
      }
      // The second clause — never a spinner, because `pumpAndSettle` would
      // hang on one — is pinned by construction rather than here: every
      // Popup and Cameras case mounts these views and settles, and a
      // `CircularProgressIndicator` behind any of them would hang the suite
      // instead of failing one line.
      expect(session.view, isNot(isA<ProgressIndicator>()));
      // Identity is free for an adapter whose view is a const expression —
      // the settled session, the fake, and so the lease that forwards it —
      // because Dart canonicalises those. The pin bites where a player
      // caches: MJPEG's and RTSP's `late final Widget view`, and the lease's
      // pass-through, which goes red the day it wraps.
      //
      // The third clause — survives remount — is executed by no world and
      // cannot be. The appliance and RTSP views are builders over a notifier
      // and a controller and owe nothing on a second mount; the lease passes
      // the inner view through; and the one adapter that does owe a second
      // start (`MseLiveVideoSession._resume`) cannot be mounted under
      // `flutter test --platform chrome` at all — `onElementCreated` never
      // fires in that harness, measured 2026-08-07. It stays browser-driven.
    });

    test('3 · setMuted never throws, in any phase, and a session is born '
        'muted', () async {
      final (session, _) = await opened();
      // Read BEFORE anything mutes, or the case only says "muted after being
      // told to mute" — which the unmute half already covers from the other
      // side, and which no adapter can fail.
      if (world.muted != null) {
        expect(world.muted!(), isTrue, reason: 'born muted — the seam\'s rule');
      }
      if (world.reachPlaying != null) {
        // Also before any setMuted, so what the player is handed is the
        // BIRTH value: RTSP applies the volume only once initialize
        // completes, so this dial is the only moment that transport's own
        // silence is observable at all.
        await world.reachPlaying!();
        if (world.muted != null) {
          expect(world.muted!(), isTrue,
              reason: 'the birth value is what the dial hands the player');
        }
      }
      expect(() => session.setMuted(true), returnsNormally);
      expect(() => session.setMuted(true), returnsNormally,
          reason: 'idempotent');
      if (world.reachPlaying != null) {
        expect(() => session.setMuted(false), returnsNormally);
        if (world.muted != null) expect(world.muted!(), isFalse);
      }
      session.close();
      expect(() => session.setMuted(true), returnsNormally,
          reason: 'callable in any phase, and after close');
    });

    test('4 · close is idempotent — the Popup has four ways out — and drops '
        'the connection', () async {
      final (session, _) = await opened();
      if (world.reachPlaying != null) await world.reachPlaying!();
      if (world.connectionOpen != null) {
        expect(world.connectionOpen!(), isTrue,
            reason: 'nothing was connected to drop — without this the wait '
                'below is satisfied by a connection that never came up');
      }
      session.close();
      expect(session.close, returnsNormally);
      expect(session.close, returnsNormally);
      if (world.connectionOpen != null) {
        await _until(() => !world.connectionOpen!(),
            because: 'the far end never saw the connection go away — go2rtc '
                'would still be running ffmpeg for a surface that is gone');
      }
    });

    test('5 · an opener answers a settled failure rather than throwing — a '
        'throw out of initState costs the whole Dialog', () async {
      late final LiveVideoSession session;
      expect(() => session = world.openBroken!(), returnsNormally,
          reason: 'the caller is a `State.initState`, and a State whose '
              'initState threw is never disposed — so never deregistered '
              'either, and that Device\'s doorbell goes permanently deaf');
      addTearDown(session.close);
      expect(session.phase.value, LiveVideoPhase.failed,
          reason: 'the interface says the way to report a refusal is a '
              'session ALREADY failed — a session still dialling has not '
              'answered, and the caller has nothing to render');
      expect(session.close, returnsNormally);
    }, skip: noOpener);

    test('6 · a settled value never follows a live one — the Director reads '
        'the phase as a story, not a snapshot', () async {
      final (session, seen) = await opened();
      if (world.reachPlaying != null) await world.reachPlaying!();
      if (world.fail != null) {
        await world.fail!();
        await _until(() => session.phase.value == LiveVideoPhase.failed,
            because: 'a staged failure never reached the phase');
      }
      session.close();
      var wasLive = false;
      for (final phase in seen) {
        if (phase == LiveVideoPhase.connecting ||
            phase == LiveVideoPhase.playing) {
          wasLive = true;
          continue;
        }
        if (wasLive) {
          expect(phase, isNot(LiveVideoPhase.unconfigured), reason: '$seen');
          if (!settlesUnsupportedFromLive) {
            expect(phase, isNot(LiveVideoPhase.unsupported), reason: '$seen');
          }
        }
      }
    });
  });
}

/// Polls rather than listens, so one helper serves a notifier and a flag a
/// fake server sets — `live_video_mjpeg_test.dart`'s `_until`, shared now
/// that two suites drive real sockets.
Future<void> _until(bool Function() done,
    {String because = 'the condition never held',
    Duration within = const Duration(seconds: 15)}) async {
  final deadline = DateTime.now().add(within);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail(because);
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
