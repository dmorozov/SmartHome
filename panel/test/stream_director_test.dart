import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/diagnostics/log.dart';
import 'package:panel/domain/house.dart';
import 'package:panel/ui/video/live_video.dart';
import 'package:panel/ui/video/stream_director.dart';

import 'support/fake_go2rtc.dart';
import 'support/fake_health.dart';

/// The Stream Director (phase-8): the decision layer no widget test could
/// reach — admission spacing, the retry ladder, the health gate, the
/// viewport and overlay debounces — driven in plain fakeAsync over
/// [FakeGo2rtc], with no widget tree and no real clock.
///
/// The widget-level halves (which face a phase renders, wantKeepAlive, that
/// the closing line reads the census at `deactivate()`) stay pinned in
/// `cameras_view_test.dart`; what is pinned HERE is the policy machine those
/// widgets render — the closing-census count included, since 2026-09-03.
void main() {
  late FakeGo2rtc go2rtc;
  late List<LogRecord> records;

  setUp(() {
    go2rtc = FakeGo2rtc();
    records = <LogRecord>[];
    Log.sink = records.add;
    Log.level = LogLevel.debug;
  });

  tearDown(() {
    Log.sink = Log.printRecord;
  });

  Device cam(
    String id, {
    String? stream,
    String? sub,
    DeviceKind kind = DeviceKind.camera,
  }) =>
      Device(
        id: id,
        name: id,
        kind: kind,
        connectivity: Connectivity.local,
        position: Offset.zero,
        streamName: stream,
        substream: sub,
      );

  StreamDirector director({
    LiveVideoOpener? open,
    String go2rtcUrl = 'http://hub:1984',
    DirectorPolicy policy = const DirectorPolicy(),
    CameraHealthSource? health,
  }) =>
      StreamDirector(
        video: VideoConfig(go2rtcUrl: go2rtcUrl, open: open ?? go2rtc.open),
        policy: policy,
        health: health,
      );

  group('which stream, and whether it starts at all', () {
    test('a tile dials the substream where the camera offers one', () {
      final d = director();
      addTearDown(d.dispose);
      final feed =
          d.attach(cam('c1', stream: 'main', sub: 'small'), role: FeedRole.tile);
      expect(feed.phase.value, FeedPhase.connecting);
      expect(go2rtc.only.name, 'small');
      feed.release();
    });

    test('a zoom dials the full-size stream — the one surface that asks', () {
      final d = director();
      addTearDown(d.dispose);
      final feed =
          d.attach(cam('c1', stream: 'main', sub: 'small'), role: FeedRole.zoom);
      expect(go2rtc.only.name, 'main');
      feed.release();
    });

    test('the doorbell tile is idle at attach: nothing dialled (#177014), '
        'and idle is the one badge-worthy phase', () {
      final d = director();
      addTearDown(d.dispose);
      final feed = d.attach(cam('door', stream: 'ring', kind: DeviceKind.doorbell),
          role: FeedRole.tile);
      expect(feed.phase.value, FeedPhase.idle);
      expect(go2rtc.opened, isEmpty);
      feed.release();
    });

    test('no go2rtc address settles a wired tile at unconfigured — no badge, '
        'no dial, nothing wrong', () {
      final d = director(go2rtcUrl: '');
      addTearDown(d.dispose);
      final feed = d.attach(cam('c1', stream: 'main'), role: FeedRole.tile);
      expect(feed.phase.value, FeedPhase.unconfigured);
      expect(go2rtc.opened, isEmpty);
      feed.release();
    });

    test('playing follows the player, and LIVE means connecting|playing only',
        () {
      final d = director();
      addTearDown(d.dispose);
      final feed = d.attach(cam('c1', stream: 'main'), role: FeedRole.tile);
      expect(feed.phase.value.isLive, isTrue, reason: 'connecting is live');
      go2rtc.only.plays();
      expect(feed.phase.value, FeedPhase.playing);
      expect(FeedPhase.retrying.isLive, isFalse);
      expect(FeedPhase.queued.isLive, isFalse);
      expect(FeedPhase.offline.isLive, isFalse);
      feed.release();
    });
  });

  group('admission', () {
    test('policy dials space out at dialSpacing; the first goes now', () {
      fakeAsync((async) {
        final d = director();
        final f1 = d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
        final f2 = d.attach(cam('c2', stream: 's2'), role: FeedRole.tile);
        final f3 = d.attach(cam('c3', stream: 's3'), role: FeedRole.tile);
        expect(go2rtc.opened.map((s) => s.name), ['s1']);
        expect(f1.phase.value, FeedPhase.connecting);
        expect(f2.phase.value, FeedPhase.queued);
        expect(f3.phase.value, FeedPhase.queued);

        async.elapse(const Duration(milliseconds: 400));
        expect(go2rtc.opened.map((s) => s.name), ['s1', 's2']);
        async.elapse(const Duration(milliseconds: 400));
        expect(go2rtc.opened.map((s) => s.name), ['s1', 's2', 's3']);
        d.dispose();
      });
    });

    test('a person start jumps the queue and pays no spacing', () {
      fakeAsync((async) {
        final d = director();
        d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
        final f2 = d.attach(cam('c2', stream: 's2'), role: FeedRole.tile);
        expect(f2.phase.value, FeedPhase.queued);
        f2.start();
        expect(go2rtc.opened.map((s) => s.name), ['s1', 's2'],
            reason: 'somebody is standing there — the gate is for storms');
        d.dispose();
      });
    });

    test('a zoom dials immediately even while the gate is armed', () {
      fakeAsync((async) {
        final d = director();
        d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
        d.attach(cam('c2', stream: 'main2'), role: FeedRole.zoom);
        expect(go2rtc.opened.map((s) => s.name), ['s1', 'main2']);
        d.dispose();
      });
    });

    test('zero spacing is legal and makes every dial immediate', () {
      final d = director(
          policy: const DirectorPolicy(dialSpacing: Duration.zero));
      addTearDown(d.dispose);
      d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
      d.attach(cam('c2', stream: 's2'), role: FeedRole.tile);
      expect(go2rtc.opened, hasLength(2));
    });
  });

  group('the retry ladder', () {
    LiveVideoOpener alwaysFails() => (url, {required name}) =>
        SettledLiveVideoSession(LiveVideoPhase.failed, failure: 'nope');

    test('a failed policy dial climbs 5 → 15 → 60 → every 60, through the '
        'same admission', () {
      fakeAsync((async) {
        var dials = 0;
        final d = director(open: (url, {required name}) {
          dials++;
          return SettledLiveVideoSession(LiveVideoPhase.failed,
              failure: 'nope');
        });
        final feed = d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
        expect(feed.phase.value, FeedPhase.retrying);
        expect(dials, 1);
        async.elapse(const Duration(seconds: 5));
        expect(dials, 2);
        async.elapse(const Duration(seconds: 15));
        expect(dials, 3);
        async.elapse(const Duration(seconds: 60));
        expect(dials, 4);
        async.elapse(const Duration(seconds: 60));
        expect(dials, 5, reason: 'the last rung repeats forever');
        expect(feed.failure, 'nope');
        d.dispose();
      });
    });

    test('reaching playing resets the ladder', () {
      fakeAsync((async) {
        var fail = true;
        final sessions = <FakeLiveVideoSession>[];
        final d = director(open: (url, {required name}) {
          if (fail) {
            return SettledLiveVideoSession(LiveVideoPhase.failed,
                failure: 'nope');
          }
          final s = FakeLiveVideoSession(url, name);
          sessions.add(s);
          return s;
        });
        final feed = d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
        async.elapse(const Duration(seconds: 5)); // second dial fails too
        expect(feed.phase.value, FeedPhase.retrying);
        fail = false;
        async.elapse(const Duration(seconds: 15));
        sessions.single.plays();
        expect(feed.phase.value, FeedPhase.playing);
        // The player dies later: the ladder starts from the bottom again.
        fail = true;
        sessions.single.fails('died');
        expect(feed.phase.value, FeedPhase.retrying);
        async.elapse(const Duration(seconds: 5));
        expect(feed.phase.value, FeedPhase.retrying,
            reason: 'first rung again, not the 60 s tail');
        d.dispose();
      });
    });

    test('a person-origin CAMERA failure climbs the ladder — a person '
        'standing at a dead zoom wants it back, not a re-tap', () {
      // Superseded 2026-08-26 (owner request): this case used to pin the
      // opposite — person-origin rests at failed. That property now belongs
      // to the doorbell alone (next case).
      fakeAsync((async) {
        final d = director(open: alwaysFails());
        final feed = d.attach(cam('c1', stream: 'main'), role: FeedRole.zoom);
        expect(feed.phase.value, FeedPhase.retrying);
        expect(feed.retryAttempt.value, 1);
        // First rung (5 s): the re-dial happens and fails again.
        async.elapse(const Duration(seconds: 6));
        expect(feed.retryAttempt.value, 2);
        expect(feed.phase.value, FeedPhase.retrying);
        d.dispose();
      });
    });

    test('the count notifies on its own — a synchronous re-dial failure is '
        'retrying→retrying and phase alone stays silent', () {
      fakeAsync((async) {
        final d = director(open: alwaysFails());
        final feed = d.attach(cam('c1', stream: 'main'), role: FeedRole.zoom);
        var phaseFired = 0;
        var countFired = 0;
        feed.phase.addListener(() => phaseFired++);
        feed.retryAttempt.addListener(() => countFired++);
        async.elapse(const Duration(seconds: 6));
        expect(feed.retryAttempt.value, 2);
        expect(countFired, greaterThan(0),
            reason: 'a counted face rebuilds from THIS notifier');
        expect(phaseFired, 0,
            reason: 'the ValueNotifier == short-circuit: retrying→retrying '
                'never fires — which is why the count must');
        d.dispose();
      });
    });

    test('a stop to idle is a clean slate: the count resets and a resume '
        'starts the ladder at rung zero', () {
      fakeAsync((async) {
        final go = FakeGo2rtc();
        final d = director(open: go.open);
        final feed =
            d.attach(cam('c1', stream: 'main', sub: 'small'), role: FeedRole.tile);
        go.opened.last.plays();
        go.opened.last.fails('died mid-watch');
        expect(feed.retryAttempt.value, 1);
        feed.visible = false;
        async.elapse(d.policy.offscreenLinger + const Duration(seconds: 1));
        expect(feed.phase.value, FeedPhase.idle);
        expect(feed.retryAttempt.value, 0,
            reason: 'the getter\'s contract: 0 while none is pending — a '
                'scroll-back must not wear "Reconnecting…" for a fresh '
                'start, nor inherit a mid-ladder backoff');
        d.dispose();
      });
    });

    test('ladder re-dials take admission: two cameras that died together '
        'come back spaced, never as a burst', () {
      fakeAsync((async) {
        var opens = 0;
        LiveVideoSession failing(Uri url, {required String name}) {
          opens++;
          return SettledLiveVideoSession(LiveVideoPhase.failed,
              failure: 'refused');
        }

        final d = director(open: failing);
        d.attach(cam('c1', stream: 'm1'), role: FeedRole.zoom);
        d.attach(cam('c2', stream: 'm2'), role: FeedRole.zoom);
        // The taps themselves are unspaced by design — spacing is for
        // storms, and a human tap is one dial.
        expect(opens, 2);
        // Both retry timers fire in the same tick five seconds later; the
        // re-dials are timer-born, so the second waits out the gate.
        async.elapse(const Duration(seconds: 5, milliseconds: 50));
        expect(opens, 3, reason: 'first re-dial out, second held at the gate');
        async.elapse(const Duration(milliseconds: 450));
        expect(opens, 4);
        d.dispose();
      });
    });

    test('a person-origin DOORBELL failure rests at failed — the Ring '
        'stream is never re-dialled on a timer (#177014)', () {
      fakeAsync((async) {
        final d = director(open: alwaysFails());
        final feed = d.attach(
            cam('door', stream: 'ring', kind: DeviceKind.doorbell),
            role: FeedRole.zoom);
        expect(feed.phase.value, FeedPhase.failed);
        async.elapse(const Duration(minutes: 5));
        expect(feed.phase.value, FeedPhase.failed);
        d.dispose();
      });
    });

    test('the count resets when a picture lands — the next outage is a '
        'fresh "try 2", not "try 9"', () {
      fakeAsync((async) {
        final go = FakeGo2rtc();
        final d = director(open: go.open);
        final feed = d.attach(cam('c1', stream: 'main'), role: FeedRole.zoom);
        go.opened.last.fails('mid-watch death');
        expect(feed.phase.value, FeedPhase.retrying);
        expect(feed.retryAttempt.value, 1);
        async.elapse(const Duration(seconds: 5, milliseconds: 450));
        // The scheduled re-dial keeps the count through its connecting
        // phase — that is what lets a face say "Reconnecting…" instead of
        // the first-dial's "Connecting…".
        expect(feed.retryAttempt.value, 1);
        go.opened.last.plays();
        expect(feed.phase.value, FeedPhase.playing);
        expect(feed.retryAttempt.value, 0);
        d.dispose();
      });
    });

    test('a born-failed dial logs its failure exactly once', () {
      final d = director(open: alwaysFails());
      addTearDown(d.dispose);
      d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
      expect(records.where((r) => r.event == 'tile_failed'), hasLength(1));
    });

    test('one bad camera does not cascade the queue out unspaced — a '
        'synchronous failure re-enters the drain and must find the gate up',
        () {
      fakeAsync((async) {
        var dials = 0;
        final d = director(open: (url, {required name}) {
          dials++;
          return SettledLiveVideoSession(LiveVideoPhase.failed,
              failure: 'nope');
        });
        d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
        d.attach(cam('c2', stream: 's2'), role: FeedRole.tile);
        d.attach(cam('c3', stream: 's3'), role: FeedRole.tile);
        expect(dials, 1);
        async.elapse(const Duration(milliseconds: 400));
        expect(dials, 2, reason: 'the second failure must not drag the '
            'third out in the same tick');
        async.elapse(const Duration(milliseconds: 400));
        expect(dials, 3);
        d.dispose();
      });
    });
  });

  group('Camera Health', () {
    test('unreachable gates the dial: offline, nothing tried', () {
      final health = FakeHealth();
      health.of('c1').value = Reachability.unreachable;
      final d = director(health: health);
      addTearDown(d.dispose);
      final feed = d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
      expect(feed.phase.value, FeedPhase.offline);
      expect(go2rtc.opened, isEmpty);
    });

    test('unknown must not cost a picture — only unreachable gates', () {
      final health = FakeHealth();
      final d = director(health: health);
      addTearDown(d.dispose);
      final feed = d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
      expect(feed.phase.value, FeedPhase.connecting);
      feed.release();
    });

    test('recovery re-dials an offline policy feed on the flip, not a timer',
        () {
      fakeAsync((async) {
        final health = FakeHealth();
        health.of('c1').value = Reachability.unreachable;
        final d = director(health: health);
        final feed = d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
        expect(feed.phase.value, FeedPhase.offline);
        async.elapse(const Duration(minutes: 10));
        expect(go2rtc.opened, isEmpty,
            reason: 'no ladder hammers a dead daemon — each failed open '
                'costs the camera two connections (measured 2026-08-25)');
        health.of('c1').value = Reachability.reachable;
        expect(go2rtc.opened.map((s) => s.name), ['s1']);
        d.dispose();
      });
    });

    test('a flip to unreachable stops the ladder and parks the feed offline',
        () {
      fakeAsync((async) {
        final health = FakeHealth();
        final d = director(
          health: health,
          open: (url, {required name}) => SettledLiveVideoSession(
              LiveVideoPhase.failed,
              failure: 'nope'),
        );
        final feed = d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
        expect(feed.phase.value, FeedPhase.retrying);
        health.of('c1').value = Reachability.unreachable;
        expect(feed.phase.value, FeedPhase.offline);
        async.elapse(const Duration(minutes: 5));
        expect(go2rtc.opened, isEmpty, reason: 'the retry timer was cancelled');
        d.dispose();
      });
    });

    test('recovery respects the viewport: a hidden tile parks at idle and '
        'dials only on scroll-in', () {
      fakeAsync((async) {
        final health = FakeHealth();
        health.of('c1').value = Reachability.unreachable;
        final d = director(health: health);
        final feed = d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
        expect(feed.phase.value, FeedPhase.offline);
        feed.visible = false;
        health.of('c1').value = Reachability.reachable;
        expect(go2rtc.opened, isEmpty,
            reason: 'offline is not active, so no stop timer exists — a '
                'blind recovery dial would stream unwatched forever');
        expect(feed.phase.value, FeedPhase.idle, reason: 'want retained');
        feed.visible = true;
        expect(go2rtc.opened.map((s) => s.name), ['s1']);
        d.dispose();
      });
    });

    test('recovery respects the overlay: parked until the Popup goes', () {
      fakeAsync((async) {
        final health = FakeHealth();
        health.of('c1').value = Reachability.unreachable;
        final d = director(health: health);
        final feed = d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
        d.overlaid = true;
        health.of('c1').value = Reachability.reachable;
        expect(go2rtc.opened, isEmpty);
        expect(feed.phase.value, FeedPhase.idle);
        d.overlaid = false;
        expect(go2rtc.opened, hasLength(1));
        d.dispose();
      });
    });

    test('a stale stop timer must not rewrite offline to idle — the one '
        'badge-wearing phase over a dead camera', () {
      fakeAsync((async) {
        final health = FakeHealth();
        final d = director(health: health);
        final feed = d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
        go2rtc.only.plays();
        feed.visible = false; // linger armed over a playing feed
        go2rtc.only.fails('died');
        health.of('c1').value = Reachability.unreachable;
        expect(feed.phase.value, FeedPhase.offline);
        async.elapse(const Duration(seconds: 45)); // the stale linger fires
        expect(feed.phase.value, FeedPhase.offline,
            reason: 'the verdict outranks a timer armed in another life');
        d.dispose();
      });
    });

    test('a live picture is never yanked on a probe — watchdogs decide', () {
      final health = FakeHealth();
      final d = director(health: health);
      addTearDown(d.dispose);
      final feed = d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
      go2rtc.only.plays();
      health.of('c1').value = Reachability.unreachable;
      expect(feed.phase.value, FeedPhase.playing);
      expect(go2rtc.only.closes, 0);
      feed.release();
    });

    test('dial outcomes feed back: playing reports connected, failure not',
        () {
      final health = FakeHealth();
      final d = director(health: health);
      addTearDown(d.dispose);
      final feed = d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
      go2rtc.only.plays();
      expect(health.outcomes, [('c1', true)]);
      go2rtc.only.fails('died');
      expect(health.outcomes, [('c1', true), ('c1', false)]);
      feed.release();
    });

    test('health listeners come off with the last feed — a process-lifetime '
        'notifier must not accumulate one closure per Cameras-view visit', () {
      final health = FakeHealth();
      final d = director(health: health);
      addTearDown(d.dispose);
      final first = d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
      expect(health.of('c1').listened, isTrue);
      first.release();
      expect(health.of('c1').listened, isFalse);
      // The next visit adds exactly one fresh listener, not a second copy.
      final second = d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
      expect(health.of('c1').listened, isTrue);
      second.release();
      expect(health.of('c1').listened, isFalse);
    });
  });

  group('viewport and overlay', () {
    test('scroll-out stops a policy feed only after the debounce, and '
        'scroll-back cancels it', () {
      fakeAsync((async) {
        final d = director();
        final feed = d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
        go2rtc.only.plays();
        feed.visible = false;
        async.elapse(const Duration(seconds: 44));
        expect(go2rtc.only.closes, 0, reason: 'a flick is not a departure');
        feed.visible = true;
        async.elapse(const Duration(minutes: 2));
        expect(go2rtc.only.closes, 0);
        d.dispose();
      });
    });

    test('a departed tile is stopped at the debounce and comes back on '
        'scroll-in through admission', () {
      fakeAsync((async) {
        final d = director();
        final feed = d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
        go2rtc.only.plays();
        feed.visible = false;
        async.elapse(const Duration(seconds: 45));
        expect(go2rtc.only.closes, 1);
        expect(feed.phase.value, FeedPhase.idle, reason: 'want retained');
        feed.visible = true;
        async.flushMicrotasks();
        expect(go2rtc.opened, hasLength(2), reason: 're-admitted on return');
        d.dispose();
      });
    });

    test('a person-started tile is never viewport-stopped', () {
      fakeAsync((async) {
        final d = director();
        final feed = d.attach(
            cam('door', stream: 'ring', kind: DeviceKind.doorbell),
            role: FeedRole.tile);
        feed.start();
        go2rtc.only.plays();
        feed.visible = false;
        async.elapse(const Duration(minutes: 5));
        expect(go2rtc.only.closes, 0, reason: 'theirs until they leave');
        d.dispose();
      });
    });

    test('an overlay pauses policy feeds only past overlayLinger — a 30 s '
        'ding Popup never churns producers', () {
      fakeAsync((async) {
        final d = director();
        d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
        go2rtc.only.plays();
        d.overlaid = true;
        async.elapse(const Duration(seconds: 30));
        expect(go2rtc.only.closes, 0,
            reason: 'the debounce outlasts the doorbell deadline on purpose');
        d.overlaid = false;
        async.elapse(const Duration(minutes: 2));
        expect(go2rtc.only.closes, 0);
        d.overlaid = true;
        async.elapse(const Duration(seconds: 45));
        expect(go2rtc.only.closes, 1,
            reason: 'a Popup somebody holds open takes the airtime');
        d.dispose();
      });
    });
  });

  group('release and dispose', () {
    test('release closes the session exactly once, by every route out', () {
      final d = director();
      addTearDown(d.dispose);
      final feed = d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
      feed.release();
      feed.release();
      expect(go2rtc.only.closes, 1);
    });

    test('release cancels a pending retry — no timer outlives the surface',
        () {
      fakeAsync((async) {
        final d = director(
            open: (url, {required name}) => SettledLiveVideoSession(
                LiveVideoPhase.failed,
                failure: 'nope'));
        final feed = d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
        expect(feed.phase.value, FeedPhase.retrying);
        feed.release();
        async.elapse(const Duration(minutes: 5));
        expect(records.where((r) => r.event == 'tile_failed'), hasLength(1),
            reason: 'no dial happened after release');
        d.dispose();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('dispose closes every feed and settles the machine', () {
      fakeAsync((async) {
        final d = director();
        d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
        d.attach(cam('c2', stream: 's2'), role: FeedRole.tile);
        d.dispose();
        expect(go2rtc.opened.first.closes, 1);
        expect(async.pendingTimers, isEmpty,
            reason: 'a pending Timer outliving the tree fails a widget test '
                'by itself');
        final late = d.attach(cam('c3', stream: 's3'), role: FeedRole.tile);
        expect(late.phase.value, FeedPhase.idle);
        expect(go2rtc.opened, hasLength(1));
      });
    });
  });

  group('the popup role', () {
    // The third managed surface (2026-08-28): person-origin from birth even
    // when a ding opened it, main stream, health-blind for gating, one dial
    // per lifetime. The route clocks (deadline, ceiling) are deliberately
    // NOT here — they time a route, and they live in `timed_feed.dart`.

    test('a popup dials the full-size stream immediately, even while the '
        'gate is armed', () {
      fakeAsync((async) {
        final d = director();
        d.attach(cam('c1', stream: 'm1', sub: 'sub1'), role: FeedRole.tile);
        final popup = d.attach(cam('c2', stream: 'main2', sub: 'small2'),
            role: FeedRole.popup);
        expect(go2rtc.opened.map((s) => s.name), ['sub1', 'main2']);
        expect(popup.phase.value, FeedPhase.connecting);
        d.dispose();
      });
    });

    test('a popup dial arms no gate — a ding must not hold the next policy '
        'dial to the spacing a tap never pays', () {
      final d = director();
      addTearDown(d.dispose);
      d.attach(cam('c1', stream: 'main1'), role: FeedRole.popup);
      d.attach(cam('c2', stream: 's2'), role: FeedRole.tile);
      expect(go2rtc.opened, hasLength(2),
          reason: 'the tile found no gate up and dialled now');
    });

    test('a popup dials an unreachable camera anyway — person intent '
        'outranks the probe (owner decision, 2026-08-28) — and the outcome '
        'still reports', () {
      final health = FakeHealth();
      health.of('c1').value = Reachability.unreachable;
      final d = director(health: health);
      addTearDown(d.dispose);
      final feed = d.attach(cam('c1', stream: 's1'), role: FeedRole.popup);
      expect(feed.phase.value, FeedPhase.connecting,
          reason: 'health never gates the popup role');
      expect(health.of('c1').listened, isFalse,
          reason: 'a health-blind role is not even subscribed');
      go2rtc.only.plays();
      expect(health.outcomes, [('c1', true)],
          reason: 'blind for gating, never for reporting');
      feed.release();
    });

    test('a popup failure never parks offline — health cannot park what it '
        'does not gate, so the ladder is what carries it', () {
      final health = FakeHealth();
      health.of('c1').value = Reachability.unreachable;
      final d = director(
        health: health,
        open: (url, {required name}) => SettledLiveVideoSession(
            LiveVideoPhase.failed,
            failure: 'nope'),
      );
      addTearDown(d.dispose);
      final feed = d.attach(cam('c1', stream: 's1'), role: FeedRole.popup);
      expect(feed.phase.value, FeedPhase.retrying,
          reason: 'the gated roles park here; this one keeps trying');
      expect(health.outcomes, [('c1', false)]);
    });

    test('a popup CAMERA failure climbs the ladder like the zoom — the same '
        'gesture at a different size (2026-08-28)', () {
      fakeAsync((async) {
        var dials = 0;
        final d = director(open: (url, {required name}) {
          dials++;
          return SettledLiveVideoSession(LiveVideoPhase.failed,
              failure: 'nope');
        });
        final feed = d.attach(cam('c1', stream: 's1'), role: FeedRole.popup);
        expect(feed.phase.value, FeedPhase.retrying);
        expect(feed.retryAttempt.value, 1);
        async.elapse(const Duration(seconds: 6));
        expect(dials, 2);
        async.elapse(const Duration(seconds: 15));
        expect(dials, 3, reason: '5 → 15 → 60, the one schedule');
        d.dispose();
      });
    });

    test('a health-blind ladder is bounded by the ROUTE, not the probe: '
        'releasing the Popup is what stops it', () {
      fakeAsync((async) {
        // The two decisions compound here — no `offline` park is coming, so
        // the clocks the Popup wears (deadline, ceiling, idle return) are
        // the only thing between a dead camera and a permanent 60 s knock.
        var dials = 0;
        final health = FakeHealth();
        health.of('c1').value = Reachability.unreachable;
        final d = director(health: health, open: (url, {required name}) {
          dials++;
          return SettledLiveVideoSession(LiveVideoPhase.failed,
              failure: 'nope');
        });
        final feed = d.attach(cam('c1', stream: 's1'), role: FeedRole.popup);
        async.elapse(const Duration(minutes: 5));
        expect(dials, greaterThan(3), reason: 'nothing parks it, so it climbs');
        // The claim is UNBOUNDEDNESS, and a count alone cannot carry it: a
        // ladder that gave up after five rungs would satisfy any
        // `greaterThan`. `retrying` with a rung still armed is the state a
        // ladder that stopped could not be in.
        expect(feed.phase.value, FeedPhase.retrying);
        final climbed = dials;
        async.elapse(const Duration(minutes: 5));
        expect(dials, greaterThan(climbed),
            reason: 'the last rung repeats forever — nothing in the Director '
                'ends this, which is what makes the route clocks the bound');
        final stillClimbing = dials;
        feed.release();
        async.elapse(const Duration(minutes: 30));
        expect(dials, stillClimbing,
            reason: 'the route closed, so the ladder ends');
        expect(async.pendingTimers, isEmpty);
        d.dispose();
      });
    });

    test('a popup DOORBELL failure rests at failed — the kind wall holds at '
        'the third role (#177014)', () {
      fakeAsync((async) {
        final d = director(
            open: (url, {required name}) => SettledLiveVideoSession(
                LiveVideoPhase.failed,
                failure: 'nope'));
        final feed = d.attach(
            cam('door', stream: 'ring', kind: DeviceKind.doorbell),
            role: FeedRole.popup);
        expect(feed.phase.value, FeedPhase.failed);
        async.elapse(const Duration(minutes: 5));
        expect(feed.phase.value, FeedPhase.failed);
        d.dispose();
      });
    });

    test('a popup feed is never viewport-stopped and never paused by the '
        'overlay it constitutes', () {
      fakeAsync((async) {
        final d = director();
        final feed = d.attach(cam('c1', stream: 's1'), role: FeedRole.popup);
        go2rtc.only.plays();
        feed.visible = false;
        d.overlaid = true;
        async.elapse(const Duration(minutes: 5));
        expect(go2rtc.only.closes, 0,
            reason: 'person-origin from birth — theirs until they leave');
        d.dispose();
      });
    });

    test('a standing unmute outlives the ladder — the one audible surface '
        'does not come back silent when the picture does', () {
      fakeAsync((async) {
        final d = director();
        final feed = d.attach(cam('c1', stream: 's1'), role: FeedRole.popup);
        feed.setMuted(false);
        go2rtc.only.plays();
        go2rtc.only.fails('died mid-watch');
        async.elapse(const Duration(seconds: 5, milliseconds: 100));
        expect(go2rtc.opened, hasLength(2), reason: 'the ladder re-dialled');
        expect(go2rtc.opened.last.muted, isFalse,
            reason: 'the surface unmuted the FEED, not one socket — a caller '
                'that had to re-assert would need to know re-dials happen');
        d.dispose();
      });
    });

    test('a feed nobody unmuted stays born-muted through its re-dials — no '
        'tile ever touches the flag', () {
      fakeAsync((async) {
        final d = director();
        final feed = d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
        go2rtc.only.plays();
        go2rtc.only.fails('died');
        async.elapse(const Duration(seconds: 5, milliseconds: 100));
        expect(go2rtc.opened, hasLength(2));
        expect(go2rtc.opened.last.muted, isTrue);
        expect(go2rtc.opened.last.mutedChanges, isEmpty,
            reason: 'six camera audio tracks over each other is the measured '
                'alternative; the dial may not go near the flag');
        feed.release();
        d.dispose();
      });
    });

    test('setMuted passes through to the session — the LISTEN leg — and a '
        'released feed\'s mute calls are inert', () {
      final d = director();
      addTearDown(d.dispose);
      final feed = d.attach(cam('c1', stream: 's1'), role: FeedRole.popup);
      expect(go2rtc.only.muted, isTrue, reason: 'every session is born muted');
      feed.setMuted(false);
      feed.setMuted(true);
      expect(go2rtc.only.mutedChanges, [false, true]);
      feed.release();
      feed.setMuted(false);
      expect(go2rtc.only.mutedChanges, [false, true],
          reason: 'after release the surface is gone; sound may not follow');
    });

    test('a tile and a popup on one camera are two independent feeds, both '
        'counted — stream0 and stream1 pull simultaneously (measured)', () {
      fakeAsync((async) {
        final d = director(policy: const DirectorPolicy(maxConcurrent: 2));
        final tile = d.attach(cam('c1', stream: 'main', sub: 'small'),
            role: FeedRole.tile);
        final popup = d.attach(cam('c1', stream: 'main', sub: 'small'),
            role: FeedRole.popup);
        expect(go2rtc.opened.map((s) => s.name), ['small', 'main']);
        // The cap reads both: a third, policy want holds at queued even
        // once the spacing gate has opened.
        final other = d.attach(cam('c2', stream: 's2'), role: FeedRole.tile);
        expect(other.phase.value, FeedPhase.queued);
        async.elapse(const Duration(milliseconds: 400));
        expect(go2rtc.opened, hasLength(2),
            reason: 'held by the cap, not the gate');
        // Each owes its own release; letting the popup go frees the slot.
        popup.release();
        expect(go2rtc.opened.map((s) => s.name), ['small', 'main', 's2']);
        tile.release();
        d.dispose();
      });
    });

    test('a popup that cannot dial says why, by name — the three skip '
        'reasons are fixed by different people', () {
      final noName = director();
      addTearDown(noName.dispose);
      noName.attach(cam('c1'), role: FeedRole.popup);
      final noUrl = director(go2rtcUrl: '');
      addTearDown(noUrl.dispose);
      noUrl.attach(cam('c2', stream: 's2'), role: FeedRole.popup);
      final badUrl = director(go2rtcUrl: 'localhost:1984');
      addTearDown(badUrl.dispose);
      badUrl.attach(cam('c3', stream: 's3'), role: FeedRole.popup);
      expect(
        records
            .where((r) => r.area == 'cameras' && r.event == 'popup_skipped')
            .map((r) => r.fields?['reason']),
        ['no_stream_name', 'no_go2rtc_url', 'bad_go2rtc_url'],
      );
    });
  });

  group('the closing census', () {
    // How many streams a closing surface is about to release — one answer,
    // the Director's, since 2026-09-03; the Cameras view used to keep it by
    // hand in a set the tiles reported into, and got it wrong once (D6).
    // Not `_activeSessions`, which counts held sessions for the cap.
    test('activeFeeds counts pursued and playing feeds of the asked roles — '
        'idle and settled ones are not streams, and a Popup is not the '
        'grid\'s', () {
      fakeAsync((async) {
        final d = director();
        const grid = {FeedRole.tile, FeedRole.zoom};
        final first = d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
        final second = d.attach(cam('c2', stream: 's2'), role: FeedRole.tile);
        expect(first.phase.value, FeedPhase.connecting);
        expect(second.phase.value, FeedPhase.queued,
            reason: 'behind the gate, and still a stream about to be');
        expect(d.activeFeeds(roles: grid), 2);

        // A doorbell tile is idle at attach: wanted, not pursued.
        final door = d.attach(
            cam('door', stream: 'ring', kind: DeviceKind.doorbell),
            role: FeedRole.tile);
        expect(d.activeFeeds(roles: grid), 2);

        // A tile with nothing to dial settles at unconfigured on attach:
        // in the set, not a stream.
        final bare = d.attach(cam('c4'), role: FeedRole.tile);
        expect(bare.phase.value, FeedPhase.unconfigured);
        expect(d.activeFeeds(roles: grid), 2,
            reason: 'settled is not a stream');

        // The Popup rides the same Director on the wall; the grid's closing
        // line must not count a ding riding over it.
        final popup = d.attach(cam('c3', stream: 's3'), role: FeedRole.popup);
        expect(popup.phase.value, FeedPhase.connecting);
        expect(d.activeFeeds(roles: grid), 2);
        expect(d.activeFeeds(roles: const {FeedRole.popup}), 1);

        go2rtc.opened.first.plays();
        expect(d.activeFeeds(roles: grid), 2, reason: 'playing is pursued too');
        go2rtc.opened.first.fails('gone');
        expect(first.phase.value, FeedPhase.retrying);
        expect(d.activeFeeds(roles: grid), 2, reason: 'a climbing ladder is');

        // A released feed has left the set — the zoom-in and zoom-out
        // pruning the view used to do by hand.
        first.release();
        expect(d.activeFeeds(roles: grid), 1);
        second.release();
        door.release();
        bare.release();
        popup.release();
        expect(d.activeFeeds(roles: grid), 0);
        expect(d.activeFeeds(roles: const {FeedRole.popup}), 0);
        d.dispose();
      });
    });

    test('a zoom counts under the grid roles beside the tiles', () {
      final d = director();
      addTearDown(d.dispose);
      final zoom = d.attach(cam('c1', stream: 'main'), role: FeedRole.zoom);
      expect(d.activeFeeds(roles: const {FeedRole.tile, FeedRole.zoom}), 1);
      expect(d.activeFeeds(roles: const {FeedRole.tile}), 0);
      zoom.release();
      expect(d.activeFeeds(roles: const {FeedRole.tile, FeedRole.zoom}), 0);
    });
  });

  group('the still-grab gate', () {
    // The tile's still loop asks the feed whether a go2rtc frame grab is
    // worth its keyframe dial. Four facts, every one the Director's own,
    // answered as one verdict since 2026-09-02 — pinned here, where the
    // verdict lives, instead of through FakeSnapshots request counts in the
    // view suite (which keeps its cases as the loop-meets-verdict pins).
    test('a pursued feed never grabs — connecting, playing, retrying, and '
        'queued behind the gate all decline', () {
      fakeAsync((async) {
        final d = director();
        final first = d.attach(cam('c1', stream: 's1'), role: FeedRole.tile);
        expect(first.phase.value, FeedPhase.connecting);
        expect(first.stillGrabAllowed, isFalse);
        // Behind the 400 ms gate: a live dial is milliseconds away, and at
        // view-open every tile past the first sits here — a grab now would
        // be the burst admission exists to space.
        final second = d.attach(cam('c2', stream: 's2'), role: FeedRole.tile);
        expect(second.phase.value, FeedPhase.queued);
        expect(second.stillGrabAllowed, isFalse);
        go2rtc.opened.first.plays();
        expect(first.stillGrabAllowed, isFalse,
            reason: 'the video is on screen — a grab buys nobody anything');
        go2rtc.opened.first.fails('gone');
        expect(first.phase.value, FeedPhase.retrying);
        expect(first.stillGrabAllowed, isFalse,
            reason: 'the retry ladder owns this camera\'s dial budget');
        first.release();
        second.release();
        d.dispose();
      });
    });

    test('the faces that can show a still may grab — idle, unconfigured, '
        'unsupported', () {
      // Stills-first is where this verdict becomes load-bearing: no tile
      // starts on its own, so every tile is idle and every tick asks.
      final stillsFirst = director(
          policy: const DirectorPolicy(autoLive: DirectorPolicy.never));
      addTearDown(stillsFirst.dispose);
      final idle = stillsFirst.attach(cam('c1', stream: 'main'),
          role: FeedRole.tile);
      expect(idle.phase.value, FeedPhase.idle);
      expect(idle.stillGrabAllowed, isTrue);

      final noAddress = director(go2rtcUrl: '');
      addTearDown(noAddress.dispose);
      final unconfigured =
          noAddress.attach(cam('c2', stream: 'main'), role: FeedRole.tile);
      expect(unconfigured.phase.value, FeedPhase.unconfigured);
      expect(unconfigured.stillGrabAllowed, isTrue,
          reason: 'the still is the whole face where nothing can be dialled');

      final noPlayer = director(
          open: (url, {required name}) =>
              SettledLiveVideoSession(LiveVideoPhase.unsupported));
      addTearDown(noPlayer.dispose);
      final unsupported =
          noPlayer.attach(cam('c3', stream: 'main'), role: FeedRole.tile);
      expect(unsupported.phase.value, FeedPhase.unsupported);
      expect(unsupported.stillGrabAllowed, isTrue);

      idle.release();
      unconfigured.release();
      unsupported.release();
    });

    test('Camera Health is read live — only unreachable gates, and the next '
        'tick sees the flip with no listener', () {
      final health = FakeHealth();
      final d = director(
          policy: const DirectorPolicy(autoLive: DirectorPolicy.never),
          health: health);
      addTearDown(d.dispose);
      final feed = d.attach(cam('c1', stream: 'main'), role: FeedRole.tile);
      expect(feed.phase.value, FeedPhase.idle);
      expect(feed.stillGrabAllowed, isTrue,
          reason: 'unknown is absence of evidence, not a verdict');

      // The daemon dies. An idle feed never transitions on a probe — the
      // hole a phase-only gate had — so the verdict must read it itself.
      health.of('c1').value = Reachability.unreachable;
      expect(feed.phase.value, FeedPhase.idle);
      expect(feed.stillGrabAllowed, isFalse,
          reason: 'a frame grab IS a dial — health-gated like every dial');

      health.of('c1').value = Reachability.reachable;
      expect(feed.stillGrabAllowed, isTrue,
          reason: 'recovery needs no listener');
      feed.release();
    });

    test('a tile nobody can see does not grab — the viewport fact, pushed '
        'through the seam and read back as the verdict', () {
      final d = director(
          policy: const DirectorPolicy(autoLive: DirectorPolicy.never));
      addTearDown(d.dispose);
      final feed = d.attach(cam('c1', stream: 'main'), role: FeedRole.tile);
      expect(feed.stillGrabAllowed, isTrue, reason: 'born visible');
      feed.visible = false;
      expect(feed.stillGrabAllowed, isFalse,
          reason: 'airtime for a face nobody can see');
      feed.visible = true;
      expect(feed.stillGrabAllowed, isTrue);
      feed.release();
    });

    test('a covering overlay pauses the grabs — the same didPushNext fact '
        'that pauses the streams', () {
      final d = director(
          policy: const DirectorPolicy(autoLive: DirectorPolicy.never));
      addTearDown(d.dispose);
      final feed = d.attach(cam('c1', stream: 'main'), role: FeedRole.tile);
      expect(feed.stillGrabAllowed, isTrue);
      d.overlaid = true;
      expect(feed.stillGrabAllowed, isFalse,
          reason: 'invisible by route, which no visibility callback sees');
      d.overlaid = false;
      expect(feed.stillGrabAllowed, isTrue);
      feed.release();
    });
  });
}

// FakeHealth and ProbeNotifier moved to `support/fake_health.dart` — the
// Cameras view's suite stages health now too (the tile's still loop declines
// through `CameraFeed.stillGrabAllowed`, which reads the verdict live).
