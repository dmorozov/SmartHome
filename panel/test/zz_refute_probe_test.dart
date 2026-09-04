import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'zz_probe_lib.dart';

void main() {
  ({PopupClaim claim, void Function() frame}) rig({
    Duration window = kPopupClaimWindow,
  }) {
    final pending = <VoidCallback>[];
    return (
      claim: PopupClaim(window: window, nextFrame: pending.add),
      frame: () {
        final due = List.of(pending);
        pending.clear();
        for (final cb in due) {
          cb();
        }
      },
    );
  }

  // Mirrors the real drop case verbatim (bare rig, default window).
  test('PROBE default-window drop case (mirror of the real one)', () {
    fakeAsync((async) {
      final (:claim, :frame) = rig();
      claim.register('doorbell', _Stayer(StayVerdict.leaving));
      final verdicts = <ClaimAnswer>[];
      claim.acquire('doorbell', owner: 'host', onVerdict: verdicts.add);

      async.elapse(kPopupClaimWindow - const Duration(seconds: 1));
      expect(verdicts, isEmpty);
      async.elapse(const Duration(seconds: 1));
      expect(verdicts, [isA<Dropped>()]);
      expect((verdicts.single as Dropped).waited, kPopupClaimWindow);
      expect(async.pendingTimers, isEmpty);
    });
  });

  // The reviewer's proposed fix: an injected, non-default window.
  test('PROBE injected 5 s window is honoured by clock AND by waited', () {
    fakeAsync((async) {
      const window = Duration(seconds: 5);
      final (:claim, :frame) = rig(window: window);
      claim.register('doorbell', _Stayer(StayVerdict.leaving));
      final verdicts = <ClaimAnswer>[];
      claim.acquire('doorbell', owner: 'host', onVerdict: verdicts.add);

      async.elapse(window - const Duration(seconds: 1));
      expect(verdicts, isEmpty, reason: 'PROBE: timer must use the INJECTED window');
      async.elapse(const Duration(seconds: 1));
      expect(verdicts, [isA<Dropped>()]);
      expect((verdicts.single as Dropped).waited, window,
          reason: 'PROBE: waited must be the INJECTED window, not the default');
      expect(async.pendingTimers, isEmpty);
    });
  });
}

class _Stayer implements PopupStayer {
  _Stayer(this.verdict);
  StayVerdict verdict;
  int asked = 0;
  @override
  StayVerdict stayUp() {
    asked++;
    return verdict;
  }
}
