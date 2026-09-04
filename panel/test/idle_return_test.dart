import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/ui/idle_return.dart';

/// The idle bound's clockwork, driven by a fake clock.
///
/// Both surfaces used to pin this by pumping five real minutes through a
/// widget tree — twelve cases between them, each one a route, a Navigator
/// and a stream. What is pinned HERE is the choreography every one of those
/// shares; what stays there is the half that is that surface's own (which
/// route it pops, what it logs, what its gate says), which is why this file
/// has no widget in it at all.
void main() {
  ({IdleReturn idle, List<String> events}) rig({
    Duration returnAfter = const Duration(minutes: 5),
    Duration warnFor = const Duration(seconds: 30),
  }) {
    final events = <String>[];
    final idle = IdleReturn(
      returnAfter: returnAfter,
      warnFor: warnFor,
      onFire: () => events.add('fire'),
    );
    idle.prompting.addListener(() => events.add('prompting=${idle.prompting.value}'));
    return (idle: idle, events: events);
  }

  test('the warning is the last slice of the bound, not an extension of it',
      () {
    fakeAsync((async) {
      final (:idle, :events) = rig();
      addTearDown(idle.dispose);
      idle.rearm();

      async.elapse(const Duration(minutes: 4, seconds: 29));
      expect(events, isEmpty, reason: 'nothing until the warning window');

      async.elapse(const Duration(seconds: 1));
      expect(events, ['prompting=true'], reason: 'asked at 4m30s');
      expect(idle.prompting.value, isTrue);

      async.elapse(const Duration(seconds: 29));
      expect(events, ['prompting=true'], reason: 'not yet — 30 s of grace');

      async.elapse(const Duration(seconds: 1));
      expect(events, ['prompting=true', 'fire'],
          reason: 'fired at 5m00s, the bound itself — the warning was part '
              'of it, so a surface that asks does not thereby stay longer');
    });
  });

  test('a touch during the prompt takes it down and starts the whole bound '
      'again — the tap that answers needs no special case', () {
    fakeAsync((async) {
      final (:idle, :events) = rig();
      addTearDown(idle.dispose);
      idle.rearm();
      async.elapse(const Duration(minutes: 4, seconds: 40));
      expect(idle.prompting.value, isTrue);

      idle.rearm();
      expect(idle.prompting.value, isFalse, reason: 'the prompt goes at once');

      // The old fire would have landed here; it must not.
      async.elapse(const Duration(seconds: 30));
      expect(events, ['prompting=true', 'prompting=false']);

      // And the new bound is a WHOLE one, counted from the touch — its own
      // warning included, so somebody who answered once is asked again
      // rather than dropped without a prompt.
      async.elapse(const Duration(minutes: 4));
      expect(events, ['prompting=true', 'prompting=false', 'prompting=true'],
          reason: 'asked again at 4m30s of the second bound');
      async.elapse(const Duration(seconds: 30));
      expect(
          events, ['prompting=true', 'prompting=false', 'prompting=true', 'fire'],
          reason: 'the second bound ran its full five minutes from the touch');
    });
  });

  test('a touch before the warning simply moves the bound', () {
    fakeAsync((async) {
      final (:idle, :events) = rig();
      addTearDown(idle.dispose);
      idle.rearm();
      async.elapse(const Duration(minutes: 4));
      idle.rearm();
      async.elapse(const Duration(minutes: 4, seconds: 29));
      expect(events, isEmpty, reason: 'the first bound was abandoned whole');
      async.elapse(const Duration(seconds: 31));
      expect(events, ['prompting=true', 'fire']);
    });
  });

  test('cancel stops the bound and takes the prompt down, without firing',
      () {
    fakeAsync((async) {
      final (:idle, :events) = rig();
      addTearDown(idle.dispose);
      idle.rearm();
      async.elapse(const Duration(minutes: 4, seconds: 40));
      expect(idle.prompting.value, isTrue);

      idle.cancel();
      expect(idle.prompting.value, isFalse);
      async.elapse(const Duration(hours: 1));
      expect(events, ['prompting=true', 'prompting=false'],
          reason: 'a cancelled bound never fires, however long nobody looks');
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('dispose leaves no timer and never fires — a pending Timer outliving '
      'the tree fails a widget test by itself', () {
    fakeAsync((async) {
      final (:idle, :events) = rig();
      idle.rearm();
      async.elapse(const Duration(minutes: 4, seconds: 40));

      idle.dispose();
      expect(idle.cancel, returnsNormally,
          reason: 'cancel after dispose is inert even with the prompt up — '
              'without the guard it writes to a disposed notifier');
      expect(async.pendingTimers, isEmpty);
      async.elapse(const Duration(hours: 1));
      expect(events, ['prompting=true'],
          reason: 'disposing notifies nobody: a surface tearing down has '
              'already stopped listening');
    });
  });

  test('dispose is idempotent, and a rearm after it is inert', () {
    fakeAsync((async) {
      final (:idle, :events) = rig();
      idle.rearm();
      idle.dispose();
      expect(idle.dispose, returnsNormally);
      expect(idle.rearm, returnsNormally);
      expect(idle.cancel, returnsNormally);
      async.elapse(const Duration(hours: 1));
      expect(events, isEmpty);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('a surface that disposes the moment it is asked is not fired at — '
      'the prompt notifies synchronously, so the fire must already be '
      'cancellable when it does', () {
    fakeAsync((async) {
      final events = <String>[];
      late final IdleReturn idle;
      idle = IdleReturn(
        returnAfter: const Duration(minutes: 5),
        warnFor: const Duration(seconds: 30),
        onFire: () => events.add('fire'),
      );
      // The surface's own teardown, reached from inside the notification —
      // a route popped by something else while the prompt was going up.
      idle.prompting.addListener(() {
        events.add('prompting');
        idle.dispose();
      });
      idle.rearm();

      async.elapse(const Duration(minutes: 4, seconds: 30));
      expect(events, ['prompting']);
      expect(async.pendingTimers, isEmpty,
          reason: 'the fire timer was armed before the flag flipped, so the '
              'dispose inside the notification could see it');

      async.elapse(const Duration(hours: 1));
      expect(events, ['prompting'], reason: 'and it never fired');
    });
  });

  test('the durations are the surface\'s own — the module holds no constant '
      'of its own', () {
    fakeAsync((async) {
      // A surface with a different bound entirely: the module is
      // parameterised because the two shipped surfaces have different
      // lifetimes and a stated reason to diverge.
      final (:idle, :events) = rig(
          returnAfter: const Duration(seconds: 10),
          warnFor: const Duration(seconds: 2));
      addTearDown(idle.dispose);
      idle.rearm();
      async.elapse(const Duration(seconds: 8));
      expect(events, ['prompting=true']);
      async.elapse(const Duration(seconds: 2));
      expect(events, ['prompting=true', 'fire']);
    });
  });
}
