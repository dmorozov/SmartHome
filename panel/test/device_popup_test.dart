import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/diagnostics/log.dart';
import 'package:panel/diagnostics/url_redaction.dart';
import 'package:panel/domain/house.dart';
import 'package:panel/ui/device_popup.dart';
import 'package:panel/ui/audio/talk.dart';
import 'package:panel/ui/device_presentation.dart';
import 'package:panel/ui/video/live_video.dart';
import 'package:panel/ui/video/live_video_keepalive.dart';
import 'package:panel/ui/video/snapshot.dart';

import 'support/fake_go2rtc.dart';
import 'support/fake_snapshots.dart';
import 'support/fake_talk.dart';

/// The Popup's three honest bodies, and the promise that goes with the one
/// that plays: a live session opened when the Popup opens and closed when it
/// closes — once — by every route out. #177014 says a Ring live session left
/// running can suppress a real ding, so "the stream dies with the Popup" is
/// a correctness property, not tidiness.
///
/// Nothing past the conditional import is asserted here: that a `<video>`
/// element exists, that MediaSource accepted go2rtc's bytes, that a frame
/// appeared. That code is not compiled into this binary, so an assertion
/// about it would be a lie. The opener is injected instead.
/// An opener for a build with no player in it.
///
/// This was the *default* opener until 2026-08-04, when everything that was
/// not web answered [LiveVideoPhase.unsupported] without touching the
/// network — which is why the two cases below used to pass `VideoConfig` with
/// no `open:`. Both branches of the seam now carry a real player (MJPEG on
/// the appliance, MSE on web), so the default one dials a socket and these
/// cases would be asserting the wrong build entirely.
///
/// The phase is still reachable and still has to read right on the wall: the
/// web branch answers it when the browser has no `MediaSource` at all, which
/// is a fault in the browser and not in go2rtc. Named here rather than driven
/// through the seam because no VM build can produce it.
LiveVideoSession noPlayer(Uri url, {required String name}) =>
    SettledLiveVideoSession(LiveVideoPhase.unsupported);

void main() {
  late List<LogRecord> records;

  setUp(() {
    records = <LogRecord>[];
    Log.sink = records.add;
    Log.level = LogLevel.debug;
  });

  tearDown(() {
    Log.sink = Log.printRecord;
    Log.level = LogLevel.warn;
  });

  Iterable<LogRecord> popupLines(String event) =>
      records.where((r) => r.area == 'popup' && r.event == event);

  const camera = Device(
    id: 'cam-porch',
    name: 'Porch Camera',
    kind: DeviceKind.camera,
    connectivity: Connectivity.local,
    position: Offset.zero,
    streamName: 'porch',
  );

  /// Pumps a screen with one button that opens the Popup, and taps it — so
  /// the Popup is reached through `showDialog` and a real route, which is
  /// what makes the barrier and the deadline behave as they do on the wall.
  Future<void> openPopup(
    WidgetTester tester, {
    Device device = camera,
    required VideoConfig video,
    SnapshotConfig? snapshots,
    TalkConfig talk = const TalkConfig(),
    Duration? dismissAfter,
    Duration? dismissCeiling,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDevicePopup(
              context,
              presentation: DevicePresentation(device, null),
              video: video,
              snapshots: snapshots,
              talk: talk,
              dismissAfter: dismissAfter,
              dismissCeiling: dismissCeiling,
            ),
            child: const Text('tap the pin'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('tap the pin'));
    await tester.pumpAndSettle();
  }

  testWidgets('opening a camera Popup asks go2rtc for exactly that Device\'s '
      'stream', (tester) async {
    final go2rtc = FakeGo2rtc();

    await openPopup(
      tester,
      video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
    );

    expect(go2rtc.only.url.toString(), 'ws://hub:1984/api/ws?src=porch');
    expect(go2rtc.only.name, 'porch');
    // The name, never the URL: `log.dart` forbids a line that might carry
    // credentials, and a full MSE URL would render quoted besides.
    expect(popupLines('stream_open').single.fields, {'name': 'porch'});
  });

  testWidgets('closing the Popup closes the stream — once, and by every '
      'route out', (tester) async {
    final routesOut = <String, Future<void> Function(WidgetTester)>{
      'the Close button': (t) => t.tap(find.byKey(const ValueKey('popup-close'))),
      // showDialog's barrierDismissible defaults true and nothing overrides
      // it, so the wall's most likely dismissal is a stray tap beside the
      // Dialog.
      'the barrier': (t) => t.tapAt(const Offset(5, 5)),
      'Navigator.pop': (t) async =>
          t.state<NavigatorState>(find.byType(Navigator).first).pop(),
    };

    for (final route in routesOut.entries) {
      final go2rtc = FakeGo2rtc();
      await openPopup(
        tester,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
      );

      await route.value(tester);
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing, reason: route.key);
      expect(go2rtc.only.closes, 1, reason: route.key);
      expect(popupLines('stream_closed').last.fields, {
        'name': 'porch',
        'reason': 'popup_closed',
      }, reason: route.key);
    }
  });

  testWidgets('a Popup with no go2rtc configured shows the placeholder it '
      'always showed, and says why in the log, not on the wall', (
    tester,
  ) async {
    final go2rtc = FakeGo2rtc();

    await openPopup(tester, video: VideoConfig(open: go2rtc.open));

    expect(go2rtc.opened, isEmpty);
    expect(find.text('Live view placeholder — go2rtc stream'), findsOneWidget);
    expect(popupLines('stream_skipped').single.fields, {
      'device': 'cam-porch',
      'reason': 'no_go2rtc_url',
    });
    // The reason is a thing to grep for, not a thing to read across a room.
    expect(find.textContaining('no_go2rtc_url'), findsNothing);
  });

  testWidgets('a camera with no stream named yet is skipped by name, not by '
      'address — the two are fixed by different people', (tester) async {
    const unwired = Device(
      id: 'cam-garage',
      name: 'Garage Camera',
      kind: DeviceKind.camera,
      connectivity: Connectivity.local,
      position: Offset.zero,
    );
    final go2rtc = FakeGo2rtc();

    await openPopup(
      tester,
      device: unwired,
      video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
    );

    expect(go2rtc.opened, isEmpty);
    expect(popupLines('stream_skipped').single.fields, {
      'device': 'cam-garage',
      'reason': 'no_stream_name',
    });
  });

  testWidgets('a go2rtc address that will not parse costs the picture and '
      'nothing else', (tester) async {
    final go2rtc = FakeGo2rtc();

    await openPopup(
      tester,
      video: VideoConfig(go2rtcUrl: 'localhost:1984', open: go2rtc.open),
    );

    // The Dialog still has the Device's name and a way out of itself — the
    // whole reason urlFor returns null instead of throwing.
    expect(find.text('Porch Camera'), findsOneWidget);
    expect(find.byKey(const ValueKey('popup-close')), findsOneWidget);
    expect(popupLines('stream_skipped').single.fields, {
      'device': 'cam-porch',
      'reason': 'bad_go2rtc_url',
    });
  });

  testWidgets('a stream go2rtc refuses reads as unavailable, never as a '
      'black rectangle', (tester) async {
    final go2rtc = FakeGo2rtc();
    await openPopup(
      tester,
      video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
    );

    go2rtc.only.fails('mse: stream not found');
    await tester.pump();

    expect(find.text('Live view unavailable'), findsOneWidget);
    // go2rtc's own words, verbatim and only in the log: it is a human
    // sentence go2rtc is free to reword, so nothing branches on it and the
    // wall never shows it.
    expect(popupLines('stream_failed').single.fields, {
      'name': 'porch',
      'reason': 'mse: stream not found',
    });
    expect(find.textContaining('mse:'), findsNothing);
  });

  testWidgets('an ffmpeg: producer\'s stderr reaches this line with its camera '
      'password already gone', (tester) async {
    // The composition the MSE player performs, driven through the real Popup:
    // `_reportFailure` puts `session.failure` on the line verbatim, so
    // whatever the player did not take out is what journald gets.
    //
    // One link is web-only and is not asserted here: that
    // `live_video_mse.dart` calls `redactCredentials` on go2rtc's error frame
    // at all. That file is not compiled into this binary, and an assertion
    // about it would be a lie. `url_redaction_test.dart` proves the rule; this
    // proves the Popup publishes exactly what it is handed and the rendered
    // line survives the trip.
    const password = 'hunter2';
    const stderr =
        'mse: streams: exec/pipe: EOF\n'
        '[tcp @ 0x769] Connection to tcp://127.0.0.1:9 failed: Connection '
        'refused\n'
        'Error opening input file http://127.0.0.1:9/cgi-bin/CGIProxy.fcgi'
        '?loginuse=admin&loginpas=$password.\n'
        'Error opening input files: Connection refused\n';
    final go2rtc = FakeGo2rtc();
    await openPopup(
      tester,
      video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
    );

    go2rtc.only.fails('go2rtc refused: ${redactCredentials(stderr)}');
    await tester.pump();

    final line = popupLines('stream_failed').single.toString();
    expect(line, isNot(contains(password)));
    expect(line, isNot(contains('admin')));
    // The stream name is this line's own field, which is why the redaction can
    // afford to drop the URL whole — and the reason an operator came for is
    // still legible through log.dart's escaping.
    expect(line, contains('name=porch'));
    expect(
      line,
      contains(
        r'Error opening input file http://127.0.0.1:9 '
        r'<redacted>.\n',
      ),
    );
    expect(line, contains('Connection refused'));
    // And never on the wall: it is a sentence go2rtc is free to reword.
    expect(find.textContaining('ffmpeg'), findsNothing);
    expect(find.textContaining('127.0.0.1'), findsNothing);
  });

  testWidgets('a build that cannot play video says so too, without inventing '
      'a go2rtc problem', (tester) async {
    await openPopup(
      tester,
      video: const VideoConfig(go2rtcUrl: 'http://hub:1984', open: noPlayer),
    );

    expect(find.text('Live view unavailable'), findsOneWidget);
    // No `stream_failed`: nothing failed, and no operator can fix a build
    // that has no MSE in it.
    expect(popupLines('stream_failed'), isEmpty);
    expect(popupLines('stream_unsupported').single.fields, {'name': 'porch'});
  });

  testWidgets('a build that cannot play video never claims it opened a stream, '
      'nor that it closed one', (tester) async {
    // The regression this pins: `popup.stream_open` used to be logged before
    // the opener was consulted, so the kiosk — where journald is the only
    // channel there is — logged an open and a close for a socket that never
    // existed. `panel.start platform=…` scrolled past hours ago, so the line
    // that has to tell "this build cannot play video" from "go2rtc is
    // healthy" is this one.
    await openPopup(
      tester,
      video: const VideoConfig(go2rtcUrl: 'http://hub:1984', open: noPlayer),
    );

    expect(popupLines('stream_open'), isEmpty);

    await tester.tap(find.byKey(const ValueKey('popup-close')));
    await tester.pumpAndSettle();

    expect(popupLines('stream_closed'), isEmpty);
  });

  testWidgets('the deadline is cancelled with the widget — a Timer outliving '
      'the tree fails this test by itself', (tester) async {
    final go2rtc = FakeGo2rtc();
    await openPopup(
      tester,
      video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
      dismissAfter: const Duration(seconds: 30),
    );

    await tester.tap(find.byKey(const ValueKey('popup-close')));
    await tester.pumpAndSettle();

    // flutter_test fails the test itself if a Timer is still pending when
    // the tree goes; the assertion below is only here so the test says what
    // it is about.
    expect(find.byType(Dialog), findsNothing);
    expect(go2rtc.only.closes, 1);
  });

  testWidgets('an auto-opened Popup closes itself; a tapped one waits for a '
      'person', (tester) async {
    final unprompted = FakeGo2rtc();
    await openPopup(
      tester,
      video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: unprompted.open),
      dismissAfter: const Duration(seconds: 30),
    );

    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    // The point of the deadline: a wall panel is never left showing a Ring
    // live session nobody is watching (#177014).
    expect(unprompted.only.closes, 1);

    final tapped = FakeGo2rtc();
    await openPopup(
      tester,
      video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: tapped.open),
    );

    await tester.pump(const Duration(minutes: 5));

    expect(find.byType(Dialog), findsOneWidget);
    expect(tapped.only.closes, 0);
  });

  testWidgets('a second reason to open the Popup extends it instead of '
      'tearing the stream down and paying for it again', (tester) async {
    final go2rtc = FakeGo2rtc();
    await openPopup(
      tester,
      video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
      dismissAfter: const Duration(seconds: 30),
      dismissCeiling: const Duration(minutes: 2),
    );

    await tester.pump(const Duration(seconds: 20));
    expect(extendDevicePopup('cam-porch'), DevicePopupExtension.extended);
    await tester.pump(const Duration(seconds: 20));

    // Past the first deadline, and still the same session: a repush would
    // black the wall out for the 2-5 s a Ring stream takes to spin up, at
    // the exact moment somebody is at the door.
    expect(find.byType(Dialog), findsOneWidget);
    expect(go2rtc.opened, hasLength(1));
    expect(go2rtc.only.closes, 0);

    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('a reason arriving faster than the deadline cannot hold the '
      'session open forever — the ceiling ends it', (tester) async {
    final go2rtc = FakeGo2rtc();
    await openPopup(
      tester,
      video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
      dismissAfter: const Duration(seconds: 30),
      dismissCeiling: const Duration(minutes: 2),
    );

    // A doorbell dinging every 25 s for a simulated hour. Before the ceiling
    // existed this ran to the end with one session open and never closed.
    var extensions = 0;
    for (
      var elapsed = Duration.zero;
      elapsed < const Duration(hours: 1);
      elapsed += const Duration(seconds: 25)
    ) {
      await tester.pump(const Duration(seconds: 25));
      if (extendDevicePopup('cam-porch') == DevicePopupExtension.extended) {
        extensions++;
      }
    }
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(go2rtc.only.closes, 1);
    // Four extensions get inside two minutes; the fifth falls past the
    // ceiling and is refused, which is what closed the session.
    expect(extensions, 4);
    expect(popupLines('deadline_ceiling').single.fields, {
      'device': 'cam-porch',
      'open_s': 120,
    });
    // And once it is closed it is closed: the Popup is gone, so a later
    // reason finds nothing to extend and its caller has to push a fresh one.
    expect(extendDevicePopup('cam-porch'), DevicePopupExtension.none);
  });

  testWidgets('a route stacked on top does not leave the Popup with no '
      'deadline at all', (tester) async {
    final go2rtc = FakeGo2rtc();
    await openPopup(
      tester,
      video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
      dismissAfter: const Duration(seconds: 30),
      dismissCeiling: const Duration(minutes: 2),
    );

    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('something else')),
      ),
    );
    await tester.pumpAndSettle();

    // The deadline fires against a route this Popup may not pop. It must not
    // pop somebody else's route — and it must not quietly give up either,
    // which is what used to happen: a spent one-shot Timer, no deadline left,
    // and a go2rtc session held until a human intervened.
    await tester.pump(const Duration(seconds: 45));
    expect(go2rtc.only.closes, 0);
    expect(popupLines('dismiss_blocked').single.fields, {
      'device': 'cam-porch',
      'retry_s': 1,
    });

    navigator.pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(go2rtc.only.closes, 1);
  });

  testWidgets('the ceiling still applies while a Popup is stuck under another '
      'route, so a blocked Popup is not an unbounded one', (tester) async {
    final go2rtc = FakeGo2rtc();
    await openPopup(
      tester,
      video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
      dismissAfter: const Duration(seconds: 30),
      dismissCeiling: const Duration(minutes: 2),
    );

    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('something else')),
      ),
    );
    await tester.pumpAndSettle();

    // Extensions keep arriving at a rate that would re-arm the deadline
    // forever. Once past the ceiling they are refused, so the Popup is a
    // Popup waiting to leave rather than one that has been given a new lease.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(seconds: 25));
      extendDevicePopup('cam-porch');
    }

    expect(extendDevicePopup('cam-porch'), DevicePopupExtension.leaving);
    expect(popupLines('deadline_ceiling'), hasLength(1));

    navigator.pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(go2rtc.only.closes, 1);
  });

  testWidgets('extending a Popup a person opened does not hand it a deadline '
      'it never had', (tester) async {
    final go2rtc = FakeGo2rtc();
    // No `dismissAfter`: a person tapped this pin, so a person closes it
    // (D14).
    await openPopup(
      tester,
      video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
    );

    expect(extendDevicePopup('cam-porch'), DevicePopupExtension.held);

    await tester.pump(const Duration(minutes: 10));

    expect(find.byType(Dialog), findsOneWidget);
    expect(go2rtc.only.closes, 0);
  });

  testWidgets('an opener that throws costs the picture and nothing else, and '
      'does not leave that Device deaf to every ding after it', (tester) async {
    // The landmine this defuses: the registry entry used to be claimed
    // *before* the opener was called and never given back, because `dispose`
    // does not run for a State whose `initState` threw and `_showing` is
    // module-level — it outlives the route stack and the whole tree. Every
    // later ding for the Device then found a defunct State and threw
    // "Looking up a deactivated widget's ancestor is unsafe" out of a Hub
    // stream callback, where nothing catches it.
    var attempts = 0;
    LiveVideoSession refuses(Uri url, {required String name}) {
      attempts++;
      // What a browser's WebSocket constructor does with a URL it will not
      // have — and it quotes the URL, credential and all, in the message.
      throw StateError('SyntaxError: cannot construct a WebSocket from $url');
    }

    await openPopup(
      tester,
      video: VideoConfig(
        go2rtcUrl: 'http://admin:hunter2@hub:1984',
        open: refuses,
      ),
    );

    expect(attempts, 1);
    // Still a Dialog: the Device's name and a way out of it, which is the
    // whole reason `urlFor` returns null rather than throwing one layer up.
    expect(find.text('Porch Camera'), findsOneWidget);
    expect(find.byKey(const ValueKey('popup-close')), findsOneWidget);
    expect(find.text('Live view unavailable'), findsOneWidget);
    // The type, never the message: a SyntaxError quotes the URL it refused,
    // and that URL is the one string here that can carry a password.
    expect(popupLines('stream_failed').single.fields, {
      'name': 'porch',
      'reason': 'the opener threw StateError',
    });
    expect(
      records.map((r) => r.toString()).join('\n'),
      isNot(contains('hunter2')),
    );
    // Nothing was ever opened, so nothing may claim to have been.
    expect(popupLines('stream_open'), isEmpty);

    await tester.tap(find.byKey(const ValueKey('popup-close')));
    await tester.pumpAndSettle();

    expect(popupLines('stream_closed'), isEmpty);
    // Answered, not thrown — and answered `none`, so the next ding pushes.
    expect(extendDevicePopup('cam-porch'), DevicePopupExtension.none);

    final healthy = FakeGo2rtc();
    await openPopup(
      tester,
      video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: healthy.open),
    );

    expect(find.byType(Dialog), findsOneWidget);
    expect(healthy.opened, hasLength(1));
  });

  testWidgets('the newer of two Popups for one Device leaving does not '
      'deregister the older one still on the wall', (tester) async {
    // Nothing pushes two today — the barrier absorbs pin taps and the
    // doorbell host consults the registry first — so this is what keeps that
    // a fact about the wall rather than a requirement on every future caller.
    // With one slot per Device the newer registration overwrote the older and
    // the newer teardown cleared the slot, so `extendDevicePopup` answered
    // `none` about a Device with a Dialog up and a live session behind it,
    // and a caller acting on that answer opened a second consumer on the one
    // stream.
    final go2rtc = FakeGo2rtc();
    final video = VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open);
    late BuildContext wall;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            wall = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    // The older one is a person's: no deadline, so it stays until somebody
    // closes it (D14).
    showDevicePopup(
      wall,
      presentation: DevicePresentation(camera, null),
      video: video,
    );
    await tester.pumpAndSettle();
    showDevicePopup(
      wall,
      presentation: DevicePresentation(camera, null),
      video: video,
      dismissAfter: const Duration(seconds: 30),
      dismissCeiling: const Duration(minutes: 2),
    );
    await tester.pumpAndSettle();
    expect(go2rtc.opened, hasLength(2));

    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();

    expect(go2rtc.opened.last.closes, 1);
    expect(go2rtc.opened.first.closes, 0, reason: 'the older one is still up');
    expect(find.byType(Dialog), findsOneWidget);
    // The answer a caller acts on: there is a Popup, a person opened it, do
    // not open a second session on the stream it is already playing.
    expect(extendDevicePopup('cam-porch'), DevicePopupExtension.held);

    await tester.tap(find.byKey(const ValueKey('popup-close')));
    await tester.pumpAndSettle();

    expect(go2rtc.opened.first.closes, 1);
    expect(extendDevicePopup('cam-porch'), DevicePopupExtension.none);
  });

  testWidgets('a Popup already popping cannot be extended, so nobody opens a '
      'second session on a stream that still has one', (tester) async {
    final go2rtc = FakeGo2rtc();
    await openPopup(
      tester,
      video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
      dismissAfter: const Duration(seconds: 30),
      dismissCeiling: const Duration(minutes: 2),
    );

    await tester.tap(find.byKey(const ValueKey('popup-close')));
    // One frame in: the pop has been requested, the exit animation is
    // running, and the old body is still mounted with its session open.
    await tester.pump(const Duration(milliseconds: 20));

    expect(go2rtc.only.closes, 0);
    expect(extendDevicePopup('cam-porch'), DevicePopupExtension.leaving);

    await tester.pumpAndSettle();

    expect(go2rtc.only.closes, 1);
    expect(extendDevicePopup('cam-porch'), DevicePopupExtension.none);
  });

  group('through the keep-alive', () {
    // Issue #1: the Popup's open→teardown→reopen lifecycle is deliberately
    // aggressive (it protects the doorbell — #177014), and that is exactly
    // the cadence that relaunches ring-mqtt's producer 1.1 s after killing
    // it and joins the new stream mid-GOP, with no later keyframe to heal
    // with. The keep-alive is what `main()` puts between this Popup and the
    // player; these two cases are the proof that this Popup's lifecycle
    // actually reaches it, which the pool's own suite cannot show.
    //
    // Not the default `VideoConfig`: every other case in this file asserts
    // one session per Popup, which is still the contract the *Popup* keeps.
    // What changes is what the opener behind it does with the session after
    // the Popup has let go.
    testWidgets('reopening a Popup within the grace window re-attaches to the '
        'stream that is still running', (tester) async {
      final go2rtc = FakeGo2rtc();
      final keepAlive = LiveVideoKeepAlive(opener: go2rtc.open);
      final video = VideoConfig(
        go2rtcUrl: 'http://hub:1984',
        open: keepAlive.open,
      );

      await openPopup(tester, video: video);
      // The keep-alive is invisible to the three honest bodies: with a
      // go2rtc address and a stream name it dials, exactly as the bare
      // opener did. Asserted because "Live view placeholder — go2rtc stream"
      // is the `unconfigured` body, decided in `_openVideo` *before* any
      // opener is called — so if it ever shows up on a configured Panel, the
      // cause is the address or the binding and never this pool.
      expect(find.textContaining('Live view placeholder'), findsNothing);
      expect(go2rtc.only.url.toString(), 'ws://hub:1984/api/ws?src=porch');

      await tester.tap(find.byKey(const ValueKey('popup-close')));
      await tester.pumpAndSettle();
      // The Popup still closes its own session — its half of the contract is
      // unchanged, and `popup.stream_closed` is still honest about it.
      expect(go2rtc.only.closes, 0, reason: 'kept, not killed');

      await tester.tap(find.text('tap the pin'));
      await tester.pumpAndSettle();

      expect(
        go2rtc.opened,
        hasLength(1),
        reason: 'a second dial is the relaunch that loses the IDR race',
      );
      expect(find.byKey(const ValueKey('popup-close')), findsOneWidget);

      // Inside the body, not `addTearDown`: the tree is disposed — and its
      // "no Timer left pending" invariant checked — before tear-downs run,
      // and this pool is still counting a two-minute age cap over the
      // session the Popup on screen is holding. `main()` never calls it,
      // because there the pool is meant to outlive everything.
      keepAlive.dispose();
    });

    testWidgets('a Popup that dies at its ceiling does not buy the stream a '
        'further grace window', (tester) async {
      // The one place the pool's age cap and the Popup's ceiling are the same
      // two minutes, and the order they fire in decides whether #177014's
      // "no session outlives the ceiling" survives. It holds because
      // `initState` opens the video (arming the pool's cap) *before* it arms
      // the ceiling, so the cap fires first and the session is retired rather
      // than kept. That is a real dependency on statement order in another
      // file — asserted here so reordering those two lines fails a test
      // instead of silently granting every ceiling-closed Ring session
      // another 20 s.
      final go2rtc = FakeGo2rtc();
      final keepAlive = LiveVideoKeepAlive(opener: go2rtc.open);

      await openPopup(
        tester,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: keepAlive.open),
        dismissAfter: const Duration(seconds: 30),
        dismissCeiling: kLiveVideoMaxHeld,
      );

      // Held open past its deadline by a stream of dings, all the way to the
      // ceiling — the `kDoorbellPopupCeiling` scenario.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(seconds: 15));
        extendDevicePopup('cam-porch');
      }
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('popup-close')), findsNothing, reason: 'the ceiling popped it');
      expect(
        go2rtc.only.closes,
        1,
        reason: 'retired at the cap, not kept for another 20 s',
      );
      keepAlive.dispose();
    });

    testWidgets('a Popup nobody reopens still lets the stream go', (
      tester,
    ) async {
      final go2rtc = FakeGo2rtc();
      final keepAlive = LiveVideoKeepAlive(opener: go2rtc.open);

      await openPopup(
        tester,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: keepAlive.open),
      );
      await tester.tap(find.byKey(const ValueKey('popup-close')));
      await tester.pumpAndSettle();
      await tester.pump(kLiveVideoLinger + const Duration(seconds: 1));

      // The #177014 half: a Ring session held for nobody has to end without
      // anyone asking it to.
      expect(go2rtc.only.closes, 1);
      keepAlive.dispose();
    });
  });

  /// Issue #1's third fix direction, and the only one that does not depend on
  /// winning a race the Panel cannot see.
  ///
  /// The other two were tried and are recorded as rejected in
  /// `live_video_keepalive.dart` and `live_video_mse.dart`: keeping the
  /// producer alive (`kLiveVideoLinger`) cures the reopens it covers and leaves
  /// a window it does not, and no timing rule can cure the rest — measured
  /// 2026-08-06, a producer gap of 2.8 s decoded 2 frames and 4.8 s decoded
  /// none, while 25 s was clean six times out of six, so the settle a fresh
  /// dial would have to wait out is longer than the Popup is allowed to live.
  ///
  /// What is testable, and tested here, is the promise the fallback makes:
  /// when there is no live picture, show the real one the Hub is already
  /// holding — and never let it pass for live.
  group('the still the Popup falls back to', () {
    /// A 1×1 red PNG. Real bytes rather than a sentinel: `Image.memory` runs
    /// them through the codec, and garbage would fail the test as a decode
    /// error rather than as the assertion it is standing in for.
    final onePixelPng = Uint8List.fromList(const [
      137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, //
      0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0, 144, 119, 83, 222, //
      0, 0, 0, 12, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 0, 0, //
      3, 1, 1, 0, 201, 254, 146, 239, 0, 0, 0, 0, 73, 69, 78, 68, //
      174, 66, 96, 130,
    ]);

    const doorbell = Device(
      id: 'doorbell',
      name: 'Ring Doorbell',
      kind: DeviceKind.doorbell,
      connectivity: Connectivity.cloud,
      position: Offset.zero,
      streamName: 'ring_doorbell',
      snapshotEntityId: 'camera.front_door_snapshot',
    );

    /// Records what was asked for, so the token-in-a-header rule and the
    /// costs-no-Ring-session rule are both checkable.
    final asked = <Uri>[];

    SnapshotConfig snapshotsThat(SnapshotResult Function() answer) =>
        SnapshotConfig(
          haUrl: 'http://hub:8123',
          token: 'shhh',
          fetch: (url, {required token}) async {
            asked.add(url);
            return answer();
          },
        );

    setUp(asked.clear);

    testWidgets('while the live view has no picture, the Popup shows the '
        'Hub\'s still — captioned, so it cannot pass for live', (tester) async {
      final go2rtc = FakeGo2rtc();

      await openPopup(
        tester,
        device: doorbell,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        snapshots: snapshotsThat(() => SnapshotResult.ok(onePixelPng)),
      );

      // Fetched from HA's camera-proxy, which serves the JPEG the Hub already
      // holds — no go2rtc frame-grab, so no Ring session (#177014).
      expect(
        asked.single.toString(),
        'http://hub:8123/api/camera_proxy/camera.front_door_snapshot',
      );
      expect(find.byType(Image), findsOneWidget);
      // ADR-0007: a picture that is not live may not be dressed as one. The
      // phase's own sentence stays on screen, over the still.
      expect(find.textContaining('Still'), findsOneWidget);
      expect(find.textContaining('Connecting to the camera'), findsOneWidget);
    });

    testWidgets('a stream that failed keeps the still up rather than trading '
        'a real picture of the porch for a sentence', (tester) async {
      final go2rtc = FakeGo2rtc();

      await openPopup(
        tester,
        device: doorbell,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        snapshots: snapshotsThat(() => SnapshotResult.ok(onePixelPng)),
      );
      go2rtc.only.fails('go2rtc sent 6s of video the browser could not decode');
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget);
      expect(find.textContaining('Live view unavailable'), findsOneWidget);
      expect(find.textContaining('Still'), findsOneWidget);
    });

    testWidgets('the moment live video really is playing, the still gets out '
        'of the way', (tester) async {
      final go2rtc = FakeGo2rtc();

      await openPopup(
        tester,
        device: doorbell,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        snapshots: snapshotsThat(() => SnapshotResult.ok(onePixelPng)),
      );
      go2rtc.only.plays();
      await tester.pumpAndSettle();

      expect(find.text('a moving picture'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('Still'), findsNothing);
    });

    testWidgets('a Hub that will not serve the still leaves the Popup saying '
        'exactly what it said before, and logs a status, never a message', (
      tester,
    ) async {
      final go2rtc = FakeGo2rtc();

      await openPopup(
        tester,
        device: doorbell,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        snapshots: snapshotsThat(() => const SnapshotResult.refused('404')),
      );

      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('Still'), findsNothing);
      expect(find.textContaining('Connecting to the camera'), findsOneWidget);
      // An HTTP code or a bare exception type — never exception text, which
      // embeds the request URL, and this request carries the Hub token.
      expect(popupLines('snapshot_failed').single.fields, {
        'entity': 'camera.front_door_snapshot',
        'status': '404',
      });
    });

    testWidgets('a Device with no snapshot bound never asks, and a Popup given '
        'no Hub never asks either', (tester) async {
      for (final scene in {
        'no snapshot binding': (Device d, SnapshotConfig? s) => (camera, s),
        'no snapshots config': (Device d, SnapshotConfig? s) =>
            (doorbell, null),
      }.entries) {
        final go2rtc = FakeGo2rtc();
        final (device, snapshots) = scene.value(
          doorbell,
          snapshotsThat(() => SnapshotResult.ok(onePixelPng)),
        );
        asked.clear();

        await openPopup(
          tester,
          device: device,
          video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
          snapshots: snapshots,
        );

        expect(asked, isEmpty, reason: scene.key);
        expect(find.byType(Image), findsNothing, reason: scene.key);
        expect(
          find.textContaining('Connecting to the camera'),
          findsOneWidget,
          reason: scene.key,
        );

        await tester.tap(find.byKey(const ValueKey('popup-close')));
        await tester.pumpAndSettle();
      }
    });
  });


  /// The idle bound on a Popup a person opened — [kDevicePopupIdleReturn].
  ///
  /// Not the D14 countdown, and the difference is the prompt: a deliberate
  /// long watch costs one tap, a forgotten one costs nothing because nobody
  /// is there to pay it. Measured 2026-08-10: a doorbell Popup left open in a
  /// browser tab held a live Ring session while it pulled 357 MB, and nothing
  /// in the stack closed it — the watchdog watches `ring`/`mic`, not
  /// `ring_doorbell`, and go2rtc has no consumer-kill endpoint.
  group('the idle bound', () {
    testWidgets('a forgotten Popup warns, then returns and closes the stream',
        (tester) async {
      final go2rtc = FakeGo2rtc();
      await openPopup(
        tester,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
      );

      // Right up to the warning it says nothing — silence is the whole point
      // of a bound nobody is meant to notice.
      await tester.pump(kDevicePopupIdleReturn - kDevicePopupIdleWarning -
          const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('popup-idle-prompt')), findsNothing);
      expect(find.byType(Dialog), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.byKey(const ValueKey('popup-idle-prompt')), findsOneWidget);
      // Warned, not gone: the prompt is a question, not a countdown display.
      expect(find.byType(Dialog), findsOneWidget);
      expect(go2rtc.only.closes, 0);

      await tester.pump(kDevicePopupIdleWarning);
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing);
      // The whole reason the bound exists: the go2rtc session goes with it.
      expect(go2rtc.only.closes, 1);
      expect(popupLines('idle_return').single.fields, {
        'device': 'cam-porch',
        'reason': 'unanswered',
      });
    });

    testWidgets('a touch re-arms it, and the prompt goes away', (tester) async {
      final go2rtc = FakeGo2rtc();
      await openPopup(
        tester,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
      );

      await tester.pump(kDevicePopupIdleReturn - kDevicePopupIdleWarning);
      await tester.pump();
      expect(find.byKey(const ValueKey('popup-idle-prompt')), findsOneWidget);

      // "Tap anywhere" — so the Device's own name is a legitimate target,
      // and answering needs no aim.
      await tester.tap(find.text('Porch Camera'));
      await tester.pump();
      expect(find.byKey(const ValueKey('popup-idle-prompt')), findsNothing);

      // And the clock really restarted: the original deadline passes with the
      // Popup still up.
      await tester.pump(kDevicePopupIdleWarning + const Duration(seconds: 1));
      expect(find.byType(Dialog), findsOneWidget);
      expect(go2rtc.only.closes, 0);

      await tester.pump(kDevicePopupIdleReturn);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('a Popup a ding opened is left alone — it already has a '
        'deadline, and two clocks would be two answers', (tester) async {
      final go2rtc = FakeGo2rtc();
      await openPopup(
        tester,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        dismissAfter: const Duration(seconds: 30),
        dismissCeiling: const Duration(minutes: 2),
      );

      // Its own deadline takes it long before the idle bound would have.
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      // Never warned: the idle bound never armed at all.
      expect(popupLines('idle_return'), isEmpty);
      expect(find.byKey(const ValueKey('popup-idle-prompt')), findsNothing);
    });

    testWidgets('a Popup that dialled nothing is never timed out — there is '
        'no session to release', (tester) async {
      // A thermostat: no video body, no go2rtc session. Closing it on a timer
      // would be tidiness dressed as safety, and it would take a card
      // somebody opened deliberately.
      final go2rtc = FakeGo2rtc();
      await openPopup(
        tester,
        device: const Device(
          id: 'thermostat',
          name: 'Hallway Thermostat',
          kind: DeviceKind.thermostat,
          connectivity: Connectivity.local,
          position: Offset.zero,
        ),
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
      );

      await tester.pump(kDevicePopupIdleReturn + kDevicePopupIdleWarning);
      await tester.pump();

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byKey(const ValueKey('popup-idle-prompt')), findsNothing);
      expect(popupLines('idle_return'), isEmpty);
    });

    testWidgets('"tap anywhere" means anywhere — including the card\'s empty '
        'padding, where a thumb most easily lands', (tester) async {
      final go2rtc = FakeGo2rtc();
      await openPopup(
        tester,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
      );

      await tester.pump(kDevicePopupIdleReturn - kDevicePopupIdleWarning);
      await tester.pump();
      expect(find.byKey(const ValueKey('popup-idle-prompt')), findsOneWidget);

      // Inside the card's own padding, where no child widget lives: this
      // only reaches the listener when it is `opaque`. With `deferToChild`
      // the prompt would sit there unanswerable and the caption would be a
      // lie.
      //
      // The left edge at mid-height, deliberately not a corner. The card is
      // a 24 px `RoundedRectangleBorder`, so a point 6 px in from the corner
      // is outside the painted shape and falls through to the modal barrier
      // — which dismisses the whole Popup. Measured while writing this test,
      // and it is worth knowing: "tap anywhere" has four small dead zones,
      // and tapping one of them closes the Popup rather than keeping it.
      final card = tester.getRect(find.byKey(const ValueKey('popup-card')));
      await tester.tapAt(Offset(card.left + 6, card.center.dy));
      await tester.pump();

      expect(find.byKey(const ValueKey('popup-idle-prompt')), findsNothing);
      expect(find.byType(Dialog), findsOneWidget);
    });

    testWidgets('holding push-to-talk still reaches the button — the idle '
        'listener never enters the gesture arena', (tester) async {
      tester.view
        ..physicalSize = const Size(1280, 800)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final go2rtc = FakeGo2rtc();
      final talk = FakeTalk();
      await openPopup(
        tester,
        device: const Device(
          id: 'doorbell',
          name: 'Ring Doorbell',
          kind: DeviceKind.doorbell,
          connectivity: Connectivity.cloud,
          position: Offset.zero,
          streamName: 'ring_doorbell',
          talkStream: 'ring',
        ),
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        talk: TalkConfig(go2rtcUrl: 'http://hub:1984', post: talk.post),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('push-to-talk'))),
      );
      await tester.pump();
      await tester.pump();
      // The press was not swallowed by the ancestor Listener.
      expect(talk.sources, ['rtsp://127.0.0.1:8554/mic']);
      await gesture.up();
      await tester.pumpAndSettle();
    });
  });

  /// Variant D's pick, folded in: A's bigger card kept, B's circular
  /// call-style mic standing in for A's full-width pill. The A/B/C/D
  /// prototype it was chosen from was never committed and is gone —
  /// `device_popup.dart`'s `_PushToTalkButton` doc is the only record of
  /// the comparison left.
  group('push-to-talk', () {
    const doorbell = Device(
      id: 'doorbell',
      name: 'Ring Doorbell',
      kind: DeviceKind.doorbell,
      connectivity: Connectivity.cloud,
      position: Offset.zero,
      streamName: 'ring_doorbell',
      // Not a variant spelling of the line above it. `ring_doorbell` is what
      // the Popup plays (ring-mqtt's RTSP restream, no backchannel); `ring`
      // is what it talks into (go2rtc's native source). ADR-0011.
      talkStream: 'ring',
    );

    const thermostat = Device(
      id: 'thermostat',
      name: 'Hallway Thermostat',
      kind: DeviceKind.thermostat,
      connectivity: Connectivity.local,
      position: Offset.zero,
    );

    /// A `TalkConfig` pointed at [talk], with the doorbell's own mic source.
    TalkConfig talkVia(FakeTalk talk) =>
        TalkConfig(go2rtcUrl: 'http://hub:1984', post: talk.post);

    testWidgets('the doorbell Popup grows the button, and the line under it '
        'stays empty until there is something to report', (tester) async {
      final go2rtc = FakeGo2rtc();
      await openPopup(
        tester,
        device: doorbell,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        talk: talkVia(FakeTalk()),
      );

      expect(find.byKey(const ValueKey('push-to-talk')), findsOneWidget);
      // The resting hint went with the 2026-08-14 redesign (issue #2): a mic
      // docked under a live picture says "hold this to speak" without help,
      // and at rest there is nothing yet to be honest or dishonest about.
      // Every phase that reports a *fault* or a live state still speaks —
      // three tests below this one, and the `docked microphone` group.
      expect(find.textContaining('Hold to speak'), findsNothing);
    });

    testWidgets(
      'a Panel that was never told where go2rtc is says exactly that, and '
      'does not offer a button that could only fail',
      (tester) async {
        // The real Panel's size: at the 800x600 default the button is below
        // the fold of the scrollable middle, and a tap there lands on the
        // scroll region instead — which would make the assertion below pass
        // for the wrong reason.
        tester.view
          ..physicalSize = const Size(1280, 800)
          ..devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final go2rtc = FakeGo2rtc();
        final talk = FakeTalk();
        await openPopup(
          tester,
          device: doorbell,
          video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
          // Video configured, talk not: the two are separate settings and
          // this is the scene that proves the caption tells them apart.
          talk: TalkConfig(post: talk.post),
        );

        expect(
          find.text('Two-way audio isn\'t configured for this door'),
          findsOneWidget,
        );

        // The button is still drawn — the layout is the doorbell's — but
        // pressing it must not post to an address nobody named.
        await tester.tap(find.byKey(const ValueKey('push-to-talk')));
        await tester.pump();
        expect(talk.posts, isEmpty);
      },
    );

    testWidgets(
      'a doorbell with no talk: binding is unconfigured too — a stream: is '
      'not a talkback, and nothing may guess one from the other',
      (tester) async {
        tester.view
          ..physicalSize = const Size(1280, 800)
          ..devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final go2rtc = FakeGo2rtc();
        final talk = FakeTalk();
        await openPopup(
          tester,
          // `stream:` present, `talk:` absent — the state every doorbell is
          // in until somebody wires ADR-0011 up.
          device: const Device(
            id: 'doorbell',
            name: 'Ring Doorbell',
            kind: DeviceKind.doorbell,
            connectivity: Connectivity.cloud,
            position: Offset.zero,
            streamName: 'ring_doorbell',
          ),
          video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
          talk: talkVia(talk),
        );

        expect(
          find.text('Two-way audio isn\'t configured for this door'),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('push-to-talk')));
        await tester.pump();
        expect(talk.posts, isEmpty);
      },
    );

    testWidgets(
      'a camera Popup renders exactly what it always has — Ring is the '
      'only kind with two-way audio to put a button on',
      (tester) async {
        final go2rtc = FakeGo2rtc();
        await openPopup(
          tester,
          device: camera,
          video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        );

        expect(find.byKey(const ValueKey('push-to-talk')), findsNothing);
        expect(find.textContaining('Push to talk'), findsNothing);
      },
    );

    testWidgets(
      'a thermostat Popup — no video body at all — never grows one either',
      (tester) async {
        final go2rtc = FakeGo2rtc();
        await openPopup(
          tester,
          device: thermostat,
          video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        );

        expect(find.byKey(const ValueKey('push-to-talk')), findsNothing);
        expect(find.textContaining('Push to talk'), findsNothing);
      },
    );

    testWidgets(
      'holding the button posts ADR-0011\'s two calls — a START into the '
      'talk: stream on press, an empty src on release',
      (tester) async {
        // The real Panel's size, not the 800×600 test default: at 800×600
        // the button sits below the fold of the scrollable middle (the very
        // case the next test is about), so a coordinate-driven press would
        // be landing on a clipped, non-hit-testable spot rather than on the
        // button — a fact about the window, not about the gesture this test
        // means to drive.
        tester.view
          ..physicalSize = const Size(1280, 800)
          ..devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final go2rtc = FakeGo2rtc();
        final talk = FakeTalk();
        await openPopup(
          tester,
          device: doorbell,
          video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
          talk: talkVia(talk),
        );

        expect(find.byIcon(Icons.mic_none), findsOneWidget);
        expect(find.byIcon(Icons.mic), findsNothing);

        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('push-to-talk'))),
        );
        await tester.pump();

        expect(find.byIcon(Icons.mic), findsOneWidget);
        expect(find.byIcon(Icons.mic_none), findsNothing);
        // ADR-0007's rule, applied to a control instead of a reading: a thing
        // that is not happening yet may not look like it is. "Talking" would
        // be a claim about a person at the door hearing something, which no
        // status code here backs — the caption tops out at "microphone open".
        expect(find.textContaining('Talking'), findsNothing);
        expect(popupLines('talk_start').single.fields, {'device': 'doorbell'});

        // The whole of ADR-0011's START, spelled out once: the `talk:`
        // stream as `dst`, the RTSP passthrough as `src`. `dst=ring` and not
        // `dst=ring_doorbell` is the assertion that matters most — the
        // Device carries both names and only one of them has a backchannel.
        expect(
          talk.posts.single.toString(),
          'http://hub:1984/api/streams'
          '?dst=ring&src=rtsp%3A%2F%2F127.0.0.1%3A8554%2Fmic',
        );

        // Only once the post has answered may the button go live. Until
        // then it is pressed-looking, not live-looking.
        await tester.pump();
        expect(find.text('Microphone open — speak now'), findsOneWidget);

        await gesture.up();
        await tester.pump();

        expect(find.byIcon(Icons.mic_none), findsOneWidget);
        expect(find.byIcon(Icons.mic), findsNothing);
        expect(popupLines('talk_stop').single.fields, {'device': 'doorbell'});
        expect(talk.sources, ['rtsp://127.0.0.1:8554/mic', '']);
        expect(talk.destinations, ['ring', 'ring']);
      },
    );

    testWidgets(
      'the button looks pressed but not live while the START is in flight — '
      'go2rtc has to dial Ring, and that gap may not be dressed as open',
      (tester) async {
        tester.view
          ..physicalSize = const Size(1280, 800)
          ..devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final go2rtc = FakeGo2rtc();
        final talk = FakeTalk()..holdNext = true;
        await openPopup(
          tester,
          device: doorbell,
          video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
          talk: talkVia(talk),
        );

        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('push-to-talk'))),
        );
        await tester.pump();

        expect(find.text('Opening the microphone…'), findsOneWidget);
        // Pressed, so the icon has swapped; not open, so nothing claims it is.
        expect(find.byIcon(Icons.mic), findsOneWidget);
        expect(find.text('Microphone open — speak now'), findsNothing);

        talk.releaseHeld();
        // Twice, and never `pumpAndSettle`: the answer lands in a microtask,
        // and settling would wait on a pulse ring that repeats forever by
        // design.
        await tester.pump();
        await tester.pump();
        expect(find.text('Microphone open — speak now'), findsOneWidget);

        await gesture.up();
        await tester.pump();
      },
    );

    testWidgets(
      'a release during an in-flight START still stops, and stops after it: '
      'a stop that overtakes its start leaves the microphone open forever',
      (tester) async {
        tester.view
          ..physicalSize = const Size(1280, 800)
          ..devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final go2rtc = FakeGo2rtc();
        final talk = FakeTalk()..holdNext = true;
        await openPopup(
          tester,
          device: doorbell,
          video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
          talk: talkVia(talk),
        );

        // A tap: down and up inside one frame, which is what a nervous thumb
        // on a wall panel actually does.
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('push-to-talk'))),
        );
        await tester.pump();
        await gesture.up();
        await tester.pump();

        // The STOP has not been posted yet — it is queued behind the START,
        // which is the entire point. Posting it now would race.
        expect(talk.sources, ['rtsp://127.0.0.1:8554/mic']);

        talk.releaseHeld();
        await tester.pumpAndSettle();

        expect(talk.sources, ['rtsp://127.0.0.1:8554/mic', '']);
        // And the late START answer does not light a button whose press is
        // already over.
        expect(find.text('Microphone open — speak now'), findsNothing);
        expect(find.byIcon(Icons.mic_none), findsOneWidget);
      },
    );

    testWidgets(
      'a refused START says so and says nothing was sent — and the message '
      'survives the release, which is over before anyone could read it',
      (tester) async {
        tester.view
          ..physicalSize = const Size(1280, 800)
          ..devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final go2rtc = FakeGo2rtc();
        final talk = FakeTalk()..answer = const TalkResult.refused('500');
        await openPopup(
          tester,
          device: doorbell,
          video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
          talk: talkVia(talk),
        );

        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('push-to-talk'))),
        );
        await tester.pump();
        await tester.pump();

        expect(
          find.text('Couldn\'t open the microphone — nothing was sent'),
          findsOneWidget,
        );
        // Struck through, not merely un-held. A refused microphone wears a red
        // ring exactly like an open one does, so the glyph is the whole of
        // what tells the two apart on the glass — and ADR-0007's rule is that
        // a thing which is not happening may not look like it is.
        expect(find.byIcon(Icons.mic_off), findsOneWidget);
        expect(find.byIcon(Icons.mic), findsNothing);

        await gesture.up();
        await tester.pumpAndSettle();

        // Still on screen: a press is over in a moment, and a fault the
        // person at the wall never gets to read is reported to nobody.
        expect(
          find.text('Couldn\'t open the microphone — nothing was sent'),
          findsOneWidget,
        );
        // The status, never a URL — a fat-fingered GO2RTC_URL can carry a
        // password (log.dart: Never log a secret).
        expect(popupLines('talk_failed').first.fields, {
          'device': 'doorbell',
          'phase': 'start',
          'status': '500',
        });
        for (final line in popupLines('talk_failed')) {
          expect(line.fields?.values.join(' ') ?? '', isNot(contains('http')));
        }
      },
    );

    testWidgets(
      'a START that throws still lets the STOP through — a poisoned chain '
      'is a microphone nothing closes',
      (tester) async {
        tester.view
          ..physicalSize = const Size(1280, 800)
          ..devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        // A poster that breaks its own no-throw contract. `talk.dart` says an
        // implementation may not throw, but "the contract says so" is not a
        // mechanism — and a `.then` chain propagates one error past every
        // later link, so a throwing START would cancel the STOP behind it and
        // leave the door live with nothing left to close it.
        final posted = <String>[];
        var first = true;
        Future<TalkResult> brittle(Uri url) async {
          posted.add(url.queryParameters['src'] ?? '');
          if (first) {
            first = false;
            throw StateError('the poster misbehaved');
          }
          return const TalkResult.ok();
        }

        final go2rtc = FakeGo2rtc();
        await openPopup(
          tester,
          device: doorbell,
          video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
          talk: TalkConfig(go2rtcUrl: 'http://hub:1984', post: brittle),
        );

        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('push-to-talk'))),
        );
        await tester.pump();
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();

        expect(posted, ['rtsp://127.0.0.1:8554/mic', '']);
        // And the throw is reported rather than swallowed silently.
        expect(
          popupLines('talk_failed').map((l) => l.fields?['status']),
          contains('StateError'),
        );
      },
    );

    testWidgets(
      'a Popup dismissed mid-press still closes the microphone — the one '
      'route out no gesture callback can cover',
      (tester) async {
        tester.view
          ..physicalSize = const Size(1280, 800)
          ..devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final go2rtc = FakeGo2rtc();
        final talk = FakeTalk();
        await openPopup(
          tester,
          device: doorbell,
          video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
          talk: talkVia(talk),
        );

        await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('push-to-talk'))),
        );
        await tester.pump();
        await tester.pump();
        expect(talk.sources, ['rtsp://127.0.0.1:8554/mic']);

        // Dismissed with the thumb still down: no onTapUp, no onTapCancel,
        // and the State unmounts holding an open microphone. #177014 — a Ring
        // session left running can suppress a real ding.
        tester
            .state<NavigatorState>(find.byType(Navigator).first)
            .pop();
        await tester.pumpAndSettle();

        expect(talk.sources, ['rtsp://127.0.0.1:8554/mic', '']);
      },
    );

    testWidgets(
      'the way out stays reachable even at a window short enough to make the '
      'card scroll — it never lives inside the region that scrolls',
      (tester) async {
        // The default test surface (800×600) is exactly the case that first
        // exposed this as a real bug: with the old `Close` text button inside
        // the scrollable middle, a tap at its on-screen position missed — the
        // Dialog stayed up, silently, on any window shorter than the real
        // Panel's 1280×800.
        //
        // Kept after the redesign moved the control into the header, where it
        // cannot scroll by construction. That makes this test cheap to pass
        // and expensive to lose: it is what would catch somebody putting the
        // way out back inside the scroll view, and it is the reason to notice
        // if the header ever becomes scrollable itself.
        final go2rtc = FakeGo2rtc();
        await openPopup(
          tester,
          device: doorbell,
          video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        );

        await tester.tap(find.byKey(const ValueKey('popup-close')));
        await tester.pumpAndSettle();

        expect(find.byType(Dialog), findsNothing);
      },
    );
  });

  /// The redesign of 2026-08-14, drawn by the owner and settled in issue #2 —
  /// the microphone docked into a notch carved out of the video's bottom edge,
  /// and the Close button moved into the header as an X.
  ///
  /// These are *geometry* assertions, which this suite otherwise avoids. They
  /// earn their place because the notch and the button are two separately
  /// positioned widgets that only read as one shape while their numbers agree:
  /// nothing about a button drawn 20 px too low would fail a behavioural test,
  /// or a golden anybody re-bakes to make green.
  ///
  /// **Variant D**, from an A/B/C/D throwaway prototype that was never
  /// committed and is gone — issue #2 holds the comparison table. Against a
  /// synthetic 1:1 porch, D removed the least picture of the centred options
  /// while keeping the full-size button; its cost is that it lands on exactly
  /// the height a Dialog gets on the 1280×800 wall, which is why the two gaps
  /// around the video are 6 px rather than 12 and 8.
  group('the docked microphone', () {
    const doorbell = Device(
      id: 'doorbell',
      name: 'Ring Doorbell',
      kind: DeviceKind.doorbell,
      connectivity: Connectivity.cloud,
      position: Offset.zero,
      streamName: 'ring_doorbell',
      talkStream: 'ring',
    );

    const thermostat = Device(
      id: 'thermostat',
      name: 'Hallway Thermostat',
      kind: DeviceKind.thermostat,
      connectivity: Connectivity.local,
      position: Offset.zero,
    );

    /// The wall's own size. Geometry read at the 800×600 default would be
    /// geometry read through the scroll view the short-window fallback puts
    /// in the way.
    void onTheWall(WidgetTester tester) {
      tester.view
        ..physicalSize = const Size(1280, 800)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    Rect videoRect(WidgetTester tester) =>
        tester.getRect(find.byKey(const ValueKey('popup-video')));

    testWidgets('the button docks two-thirds out of the video\'s bottom edge, '
        'centred — a third of it over the picture, the rest below it',
        (tester) async {
      onTheWall(tester);
      final go2rtc = FakeGo2rtc();
      await openPopup(
        tester,
        device: doorbell,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        talk: const TalkConfig(go2rtcUrl: 'http://hub:1984'),
      );

      final video = videoRect(tester);
      final button = tester.getRect(find.byKey(const ValueKey('push-to-talk')));

      expect(button.width, kTalkButtonDiameter);
      expect(button.height, kTalkButtonDiameter);
      expect(button.center.dx, closeTo(video.center.dx, 0.5),
          reason: 'centred on the picture, as drawn');
      expect(button.center.dy, closeTo(video.bottom + kTalkButtonDrop, 0.5),
          reason: 'variant D: the centre sits below the edge, not on it');
      // The whole of D in one number: 32 of the button's 96 overlap.
      expect(video.bottom - button.top, closeTo(32, 0.5));
    });

    testWidgets('a doorbell\'s video box is 4:3 — its frame is natively 1:1 — '
        'and every other camera keeps 16:9', (tester) async {
      onTheWall(tester);
      final go2rtc = FakeGo2rtc();
      await openPopup(
        tester,
        device: doorbell,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
      );
      final door = videoRect(tester);
      expect(door.width / door.height, closeTo(4 / 3, 0.01));

      await tester.tap(find.byKey(const ValueKey('popup-close')));
      await tester.pumpAndSettle();

      await openPopup(
        tester,
        device: camera,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
      );
      final porch = videoRect(tester);
      expect(porch.width / porch.height, closeTo(16 / 9, 0.01));
    });

    testWidgets('the still\'s caption band sits at the top of the video — the '
        'bottom edge is where the notch is', (tester) async {
      onTheWall(tester);
      final go2rtc = FakeGo2rtc();
      await openPopup(
        tester,
        device: const Device(
          id: 'doorbell',
          name: 'Ring Doorbell',
          kind: DeviceKind.doorbell,
          connectivity: Connectivity.cloud,
          position: Offset.zero,
          streamName: 'ring_doorbell',
          snapshotEntityId: 'camera.front_door_snapshot',
        ),
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        snapshots: SnapshotConfig(
          haUrl: 'http://hub:8123',
          token: 'shhh',
          fetch: (url, {required token}) async =>
              SnapshotResult.ok(kOnePixelImage),
        ),
      );

      final video = videoRect(tester);
      final band = tester.getRect(find.textContaining('Still'));
      expect(band.center.dy, lessThan(video.center.dy),
          reason: 'above the middle of the picture, not below it');
      expect(band.top - video.top, lessThan(24),
          reason: 'flush against the top edge');
    });

    testWidgets('every Popup closes by an X in the header — one idiom on a '
        'wall with no keyboard, and no Close button left anywhere',
        (tester) async {
      onTheWall(tester);
      for (final device in [doorbell, camera, thermostat]) {
        final go2rtc = FakeGo2rtc();
        await openPopup(
          tester,
          device: device,
          video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        );

        expect(find.byKey(const ValueKey('popup-close')), findsOneWidget,
            reason: '${device.kind} has no way out');
        expect(find.text('Close'), findsNothing,
            reason: 'the old text button survived somewhere');

        // In the header, above the body — never a row that can scroll away.
        final close = tester.getRect(find.byKey(const ValueKey('popup-close')));
        final name = tester.getRect(find.text(device.name));
        expect(close.center.dy, closeTo(name.center.dy, 40));
        expect(close.center.dx, greaterThan(name.center.dx));

        await tester.tap(find.byKey(const ValueKey('popup-close')));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
      }
    });

    testWidgets('the card is the same height at rest and with the microphone '
        'open — a card that resizes under a thumb moves the target',
        (tester) async {
      onTheWall(tester);
      final go2rtc = FakeGo2rtc();
      final talk = FakeTalk();
      await openPopup(
        tester,
        device: doorbell,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        talk: TalkConfig(go2rtcUrl: 'http://hub:1984', post: talk.post),
      );

      final resting =
          tester.getRect(find.byKey(const ValueKey('popup-card'))).height;

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('push-to-talk'))),
      );
      await tester.pump();
      await tester.pump();

      expect(tester.getRect(find.byKey(const ValueKey('popup-card'))).height,
          resting);
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('at rest a working door says nothing — the caption speaks only '
        'when it has something to report', (tester) async {
      onTheWall(tester);
      final go2rtc = FakeGo2rtc();
      final talk = FakeTalk();
      await openPopup(
        tester,
        device: doorbell,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        talk: TalkConfig(go2rtcUrl: 'http://hub:1984', post: talk.post),
      );

      // The resting hint is gone: the button is legibly a microphone, and the
      // slot below it is reserved rather than filled.
      expect(find.textContaining('Hold to speak'), findsNothing);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('push-to-talk'))),
      );
      await tester.pump();
      await tester.pump();
      // But every phase that reports something still does. ADR-0007 is
      // untouched by the redesign: what is not happening may not look like
      // it is.
      expect(find.text('Microphone open — speak now'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a door nobody wired talkback to still says so at rest — that '
        'is a fault, not a hint', (tester) async {
      onTheWall(tester);
      final go2rtc = FakeGo2rtc();
      await openPopup(
        tester,
        device: doorbell,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        talk: const TalkConfig(),
      );

      expect(find.text('Two-way audio isn\'t configured for this door'),
          findsOneWidget);
    });
  });
}
