import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/diagnostics/log.dart';
import 'package:panel/diagnostics/url_redaction.dart';
import 'package:panel/domain/house.dart';
import 'package:panel/ui/device_popup.dart';
import 'package:panel/ui/device_presentation.dart';
import 'package:panel/ui/video/live_video.dart';
import 'package:panel/ui/video/live_video_keepalive.dart';

import 'support/fake_go2rtc.dart';

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
    Duration? dismissAfter,
    Duration? dismissCeiling,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDevicePopup(
            context,
            presentation: DevicePresentation(device, null),
            video: video,
            dismissAfter: dismissAfter,
            dismissCeiling: dismissCeiling,
          ),
          child: const Text('tap the pin'),
        ),
      ),
    ));
    await tester.tap(find.text('tap the pin'));
    await tester.pumpAndSettle();
  }

  testWidgets('opening a camera Popup asks go2rtc for exactly that Device\'s '
      'stream', (tester) async {
    final go2rtc = FakeGo2rtc();

    await openPopup(tester,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open));

    expect(go2rtc.only.url.toString(), 'ws://hub:1984/api/ws?src=porch');
    expect(go2rtc.only.name, 'porch');
    // The name, never the URL: `log.dart` forbids a line that might carry
    // credentials, and a full MSE URL would render quoted besides.
    expect(popupLines('stream_open').single.fields, {'name': 'porch'});
  });

  testWidgets('closing the Popup closes the stream — once, and by every '
      'route out', (tester) async {
    final routesOut = <String, Future<void> Function(WidgetTester)>{
      'the Close button': (t) => t.tap(find.text('Close')),
      // showDialog's barrierDismissible defaults true and nothing overrides
      // it, so the wall's most likely dismissal is a stray tap beside the
      // Dialog.
      'the barrier': (t) => t.tapAt(const Offset(5, 5)),
      'Navigator.pop': (t) async =>
          t.state<NavigatorState>(find.byType(Navigator).first).pop(),
    };

    for (final route in routesOut.entries) {
      final go2rtc = FakeGo2rtc();
      await openPopup(tester,
          video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open));

      await route.value(tester);
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing, reason: route.key);
      expect(go2rtc.only.closes, 1, reason: route.key);
      expect(popupLines('stream_closed').last.fields,
          {'name': 'porch', 'reason': 'popup_closed'}, reason: route.key);
    }
  });

  testWidgets('a Popup with no go2rtc configured shows the placeholder it '
      'always showed, and says why in the log, not on the wall',
      (tester) async {
    final go2rtc = FakeGo2rtc();

    await openPopup(tester, video: VideoConfig(open: go2rtc.open));

    expect(go2rtc.opened, isEmpty);
    expect(find.text('Live view placeholder — go2rtc stream'), findsOneWidget);
    expect(popupLines('stream_skipped').single.fields,
        {'device': 'cam-porch', 'reason': 'no_go2rtc_url'});
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

    await openPopup(tester,
        device: unwired,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open));

    expect(go2rtc.opened, isEmpty);
    expect(popupLines('stream_skipped').single.fields,
        {'device': 'cam-garage', 'reason': 'no_stream_name'});
  });

  testWidgets('a go2rtc address that will not parse costs the picture and '
      'nothing else', (tester) async {
    final go2rtc = FakeGo2rtc();

    await openPopup(tester,
        video: VideoConfig(go2rtcUrl: 'localhost:1984', open: go2rtc.open));

    // The Dialog still has the Device's name and a way out of itself — the
    // whole reason urlFor returns null instead of throwing.
    expect(find.text('Porch Camera'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    expect(popupLines('stream_skipped').single.fields,
        {'device': 'cam-porch', 'reason': 'bad_go2rtc_url'});
  });

  testWidgets('a stream go2rtc refuses reads as unavailable, never as a '
      'black rectangle', (tester) async {
    final go2rtc = FakeGo2rtc();
    await openPopup(tester,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open));

    go2rtc.only.fails('mse: stream not found');
    await tester.pump();

    expect(find.text('Live view unavailable'), findsOneWidget);
    // go2rtc's own words, verbatim and only in the log: it is a human
    // sentence go2rtc is free to reword, so nothing branches on it and the
    // wall never shows it.
    expect(popupLines('stream_failed').single.fields,
        {'name': 'porch', 'reason': 'mse: stream not found'});
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
    const stderr = 'mse: streams: exec/pipe: EOF\n'
        '[tcp @ 0x769] Connection to tcp://127.0.0.1:9 failed: Connection '
        'refused\n'
        'Error opening input file http://127.0.0.1:9/cgi-bin/CGIProxy.fcgi'
        '?loginuse=admin&loginpas=$password.\n'
        'Error opening input files: Connection refused\n';
    final go2rtc = FakeGo2rtc();
    await openPopup(tester,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open));

    go2rtc.only.fails('go2rtc refused: ${redactCredentials(stderr)}');
    await tester.pump();

    final line = popupLines('stream_failed').single.toString();
    expect(line, isNot(contains(password)));
    expect(line, isNot(contains('admin')));
    // The stream name is this line's own field, which is why the redaction can
    // afford to drop the URL whole — and the reason an operator came for is
    // still legible through log.dart's escaping.
    expect(line, contains('name=porch'));
    expect(line, contains(r'Error opening input file http://127.0.0.1:9 '
        r'<redacted>.\n'));
    expect(line, contains('Connection refused'));
    // And never on the wall: it is a sentence go2rtc is free to reword.
    expect(find.textContaining('ffmpeg'), findsNothing);
    expect(find.textContaining('127.0.0.1'), findsNothing);
  });

  testWidgets('a build that cannot play video says so too, without inventing '
      'a go2rtc problem', (tester) async {
    await openPopup(tester,
        video: const VideoConfig(go2rtcUrl: 'http://hub:1984', open: noPlayer));

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
    await openPopup(tester,
        video: const VideoConfig(go2rtcUrl: 'http://hub:1984', open: noPlayer));

    expect(popupLines('stream_open'), isEmpty);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(popupLines('stream_closed'), isEmpty);
  });

  testWidgets('the deadline is cancelled with the widget — a Timer outliving '
      'the tree fails this test by itself', (tester) async {
    final go2rtc = FakeGo2rtc();
    await openPopup(tester,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        dismissAfter: const Duration(seconds: 30));

    await tester.tap(find.text('Close'));
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
    await openPopup(tester,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: unprompted.open),
        dismissAfter: const Duration(seconds: 30));

    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    // The point of the deadline: a wall panel is never left showing a Ring
    // live session nobody is watching (#177014).
    expect(unprompted.only.closes, 1);

    final tapped = FakeGo2rtc();
    await openPopup(tester,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: tapped.open));

    await tester.pump(const Duration(minutes: 5));

    expect(find.byType(Dialog), findsOneWidget);
    expect(tapped.only.closes, 0);
  });

  testWidgets('a second reason to open the Popup extends it instead of '
      'tearing the stream down and paying for it again', (tester) async {
    final go2rtc = FakeGo2rtc();
    await openPopup(tester,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        dismissAfter: const Duration(seconds: 30),
        dismissCeiling: const Duration(minutes: 2));

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
    await openPopup(tester,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        dismissAfter: const Duration(seconds: 30),
        dismissCeiling: const Duration(minutes: 2));

    // A doorbell dinging every 25 s for a simulated hour. Before the ceiling
    // existed this ran to the end with one session open and never closed.
    var extensions = 0;
    for (var elapsed = Duration.zero;
        elapsed < const Duration(hours: 1);
        elapsed += const Duration(seconds: 25)) {
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
    expect(popupLines('deadline_ceiling').single.fields,
        {'device': 'cam-porch', 'open_s': 120});
    // And once it is closed it is closed: the Popup is gone, so a later
    // reason finds nothing to extend and its caller has to push a fresh one.
    expect(extendDevicePopup('cam-porch'), DevicePopupExtension.none);
  });

  testWidgets('a route stacked on top does not leave the Popup with no '
      'deadline at all', (tester) async {
    final go2rtc = FakeGo2rtc();
    await openPopup(tester,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        dismissAfter: const Duration(seconds: 30),
        dismissCeiling: const Duration(minutes: 2));

    final navigator =
        tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('something else'))));
    await tester.pumpAndSettle();

    // The deadline fires against a route this Popup may not pop. It must not
    // pop somebody else's route — and it must not quietly give up either,
    // which is what used to happen: a spent one-shot Timer, no deadline left,
    // and a go2rtc session held until a human intervened.
    await tester.pump(const Duration(seconds: 45));
    expect(go2rtc.only.closes, 0);
    expect(popupLines('dismiss_blocked').single.fields,
        {'device': 'cam-porch', 'retry_s': 1});

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
    await openPopup(tester,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        dismissAfter: const Duration(seconds: 30),
        dismissCeiling: const Duration(minutes: 2));

    final navigator =
        tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('something else'))));
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
    await openPopup(tester,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open));

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

    await openPopup(tester,
        video: VideoConfig(
            go2rtcUrl: 'http://admin:hunter2@hub:1984', open: refuses));

    expect(attempts, 1);
    // Still a Dialog: the Device's name and a way out of it, which is the
    // whole reason `urlFor` returns null rather than throwing one layer up.
    expect(find.text('Porch Camera'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    expect(find.text('Live view unavailable'), findsOneWidget);
    // The type, never the message: a SyntaxError quotes the URL it refused,
    // and that URL is the one string here that can carry a password.
    expect(popupLines('stream_failed').single.fields,
        {'name': 'porch', 'reason': 'the opener threw StateError'});
    expect(records.map((r) => r.toString()).join('\n'),
        isNot(contains('hunter2')));
    // Nothing was ever opened, so nothing may claim to have been.
    expect(popupLines('stream_open'), isEmpty);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(popupLines('stream_closed'), isEmpty);
    // Answered, not thrown — and answered `none`, so the next ding pushes.
    expect(extendDevicePopup('cam-porch'), DevicePopupExtension.none);

    final healthy = FakeGo2rtc();
    await openPopup(tester,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: healthy.open));

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
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        wall = context;
        return const SizedBox.shrink();
      }),
    ));

    // The older one is a person's: no deadline, so it stays until somebody
    // closes it (D14).
    showDevicePopup(wall,
        presentation: DevicePresentation(camera, null), video: video);
    await tester.pumpAndSettle();
    showDevicePopup(wall,
        presentation: DevicePresentation(camera, null),
        video: video,
        dismissAfter: const Duration(seconds: 30),
        dismissCeiling: const Duration(minutes: 2));
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

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(go2rtc.opened.first.closes, 1);
    expect(extendDevicePopup('cam-porch'), DevicePopupExtension.none);
  });

  testWidgets('a Popup already popping cannot be extended, so nobody opens a '
      'second session on a stream that still has one', (tester) async {
    final go2rtc = FakeGo2rtc();
    await openPopup(tester,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open),
        dismissAfter: const Duration(seconds: 30),
        dismissCeiling: const Duration(minutes: 2));

    await tester.tap(find.text('Close'));
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
      final video =
          VideoConfig(go2rtcUrl: 'http://hub:1984', open: keepAlive.open);

      await openPopup(tester, video: video);
      // The keep-alive is invisible to the three honest bodies: with a
      // go2rtc address and a stream name it dials, exactly as the bare
      // opener did. Asserted because "Live view placeholder — go2rtc stream"
      // is the `unconfigured` body, decided in `_openVideo` *before* any
      // opener is called — so if it ever shows up on a configured Panel, the
      // cause is the address or the binding and never this pool.
      expect(find.textContaining('Live view placeholder'), findsNothing);
      expect(go2rtc.only.url.toString(), 'ws://hub:1984/api/ws?src=porch');

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      // The Popup still closes its own session — its half of the contract is
      // unchanged, and `popup.stream_closed` is still honest about it.
      expect(go2rtc.only.closes, 0, reason: 'kept, not killed');

      await tester.tap(find.text('tap the pin'));
      await tester.pumpAndSettle();

      expect(go2rtc.opened, hasLength(1),
          reason: 'a second dial is the relaunch that loses the IDR race');
      expect(find.text('Close'), findsOneWidget);

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

      await openPopup(tester,
          video:
              VideoConfig(go2rtcUrl: 'http://hub:1984', open: keepAlive.open),
          dismissAfter: const Duration(seconds: 30),
          dismissCeiling: kLiveVideoMaxHeld);

      // Held open past its deadline by a stream of dings, all the way to the
      // ceiling — the `kDoorbellPopupCeiling` scenario.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(seconds: 15));
        extendDevicePopup('cam-porch');
      }
      await tester.pumpAndSettle();

      expect(find.text('Close'), findsNothing, reason: 'the ceiling popped it');
      expect(go2rtc.only.closes, 1,
          reason: 'retired at the cap, not kept for another 20 s');
      keepAlive.dispose();
    });

    testWidgets('a Popup nobody reopens still lets the stream go', (tester) async {
      final go2rtc = FakeGo2rtc();
      final keepAlive = LiveVideoKeepAlive(opener: go2rtc.open);

      await openPopup(tester,
          video:
              VideoConfig(go2rtcUrl: 'http://hub:1984', open: keepAlive.open));
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.pump(kLiveVideoLinger + const Duration(seconds: 1));

      // The #177014 half: a Ring session held for nobody has to end without
      // anyone asking it to.
      expect(go2rtc.only.closes, 1);
      keepAlive.dispose();
    });
  });
}
