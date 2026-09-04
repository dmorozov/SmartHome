import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/ui/video/stream_director.dart';
import 'package:panel/ui/video/timed_feed.dart';

import 'support/fake_feed.dart';

/// The Popup's clocks, tested through their own interface — the widget
/// suites drive them end to end (`device_popup_test.dart`, the deadline and
/// ceiling groups); what is pinned HERE is the decorator's contract, which
/// any [CameraFeed] must be able to wear.
///
/// The `linger < deadline` inequality is deliberately NOT here: it is a
/// relation between the pool's constant and the host's, and it stays with
/// them (`live_video_keepalive_test.dart`).

void main() {
  test('no deadline means no clocks at all — D14\'s person-opened Popup, '
      'and extend has nothing to restart', () {
    fakeAsync((async) {
      final inner = FakeFeed();
      var fired = 0;
      final timed = TimedFeed(inner,
          // A ceiling without a deadline caps nothing and arms nothing.
          ceiling: const Duration(minutes: 2),
          onDeadline: () => fired++,
          onCeiling: () => fired++);
      timed.extend();
      async.elapse(const Duration(hours: 1));
      expect(fired, 0);
      expect(async.pendingTimers, isEmpty);
      timed.release();
    });
  });

  test('the deadline arms at construction, fires once per armed stretch, '
      'and extend restarts it from zero', () {
    fakeAsync((async) {
      final inner = FakeFeed();
      var deadlines = 0;
      final timed = TimedFeed(inner,
          deadline: const Duration(seconds: 30),
          onDeadline: () => deadlines++,
          onCeiling: () => fail('no ceiling was given'));
      async.elapse(const Duration(seconds: 29));
      timed.extend();
      async.elapse(const Duration(seconds: 29));
      expect(deadlines, 0, reason: 'restarted from zero, not resumed');
      async.elapse(const Duration(seconds: 1));
      expect(deadlines, 1);
      timed.release();
    });
  });

  test('the ceiling fires once, counted from construction however many '
      'extensions land, stops the deadline for good and refuses extend', () {
    fakeAsync((async) {
      final inner = FakeFeed();
      var deadlines = 0;
      var ceilings = 0;
      final timed = TimedFeed(inner,
          deadline: const Duration(seconds: 30),
          ceiling: const Duration(minutes: 2),
          onDeadline: () => deadlines++,
          onCeiling: () => ceilings++);
      // Extended more often than the deadline for the whole ceiling — the
      // visitor leaning on the button.
      for (var i = 0; i < 8; i++) {
        async.elapse(const Duration(seconds: 15));
        timed.extend();
      }
      expect(deadlines, 0);
      expect(ceilings, 1);
      expect(timed.ceilingReached, isTrue);
      timed.extend();
      async.elapse(const Duration(hours: 1));
      expect(deadlines, 0, reason: 'past the ceiling nothing re-arms');
      expect(ceilings, 1, reason: 'armed once, for the whole life — the point');
      timed.release();
    });
  });

  test('release cancels both clocks — no Timer outlives the surface — and '
      'releases the feed under it, idempotently', () {
    fakeAsync((async) {
      final inner = FakeFeed();
      final timed = TimedFeed(inner,
          deadline: const Duration(seconds: 30),
          ceiling: const Duration(minutes: 2),
          onDeadline: () => fail('released before the deadline'),
          onCeiling: () => fail('released before the ceiling'));
      timed.release();
      timed.release();
      expect(async.pendingTimers, isEmpty);
      expect(inner.released, isTrue);
      timed.extend();
      expect(async.pendingTimers, isEmpty,
          reason: 'extend after release arms nothing — the doc\'s third '
              'clause, pinned like its siblings');
      async.elapse(const Duration(hours: 1));
    });
  });

  test('the feed passes through untimed — the decorator adds clocks, '
      'never opinions', () {
    final inner = FakeFeed();
    final timed = TimedFeed(inner,
        onDeadline: () {}, onCeiling: () {});
    expect(timed.phase, same(inner.phase));
    expect(timed.retryAttempt, same(inner.retryAttempt));
    expect(timed.stillGrabAllowed, isTrue);
    inner.stillGrabAllowed = false;
    expect(timed.stillGrabAllowed, isFalse, reason: 'read through, not cached');
    timed.setMuted(false);
    timed.start();
    timed.visible = false;
    timed.release();
    expect(inner.calls, ['setMuted=false', 'start', 'visible=false', 'release']);
  });
}
