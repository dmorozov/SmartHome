import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/ui/popup_claim.dart';

/// Who may open a Popup for a Device right now, driven by a fake clock and a
/// fake frame.
///
/// This arbitration used to be spread across two files with no seam between
/// them: a registry and two module-level functions in `device_popup.dart`, a
/// deferral map and three methods in `doorbell_popup_host.dart`. Everything
/// it does was therefore pinned end-to-end, by widget cases that build a
/// House, a Hub, a Navigator and a go2rtc fake in order to ask what a map
/// says — and the two rules that matter most (a request meets the wall it is
/// finally offered to, and its clock measures the wait since the press) had
/// no case at all, because setting them up through a widget tree was more
/// than they were worth.
///
/// What stays end-to-end is `doorbell_popup_test.dart`'s four cases: that a
/// ding really does reach this, and what the journal says when it does.
void main() {
  ({PopupClaim claim, void Function() frame}) rig({
    Duration window = kPopupClaimWindow,
  }) {
    final pending = <VoidCallback>[];
    return (
      claim: PopupClaim(window: window, nextFrame: pending.add),
      // Held rather than run inline so a case can change the wall between a
      // Popup's teardown and the frame that answers on it — which is the
      // whole reason production redeems a frame late.
      frame: () {
        final due = List.of(pending);
        pending.clear();
        for (final callback in due) {
          callback();
        }
      },
    );
  }

  test('nothing showing the Device is a claim, and costs no clock', () {
    fakeAsync((async) {
      final (:claim, :frame) = rig();

      expect(claim.acquire('doorbell', owner: 'host', onVerdict: (_) => fail('answered twice')),
          isA<Claim>());
      expect(async.pendingTimers, isEmpty,
          reason: 'only a deferred request waits, and nothing deferred');
    });
  });

  test('a Popup with a deadline takes the request as an extension', () {
    final (:claim, :frame) = rig();
    final popup = _Stayer(StayVerdict.extended);
    claim.register('doorbell', popup);

    expect(claim.acquire('doorbell', owner: 'host', onVerdict: (_) {}),
        isA<Extended>());
    expect(popup.asked, 1, reason: 'the Popup itself restarts its deadline');
  });

  test('a Popup a person opened holds, and is not handed a deadline', () {
    final (:claim, :frame) = rig();
    claim.register('doorbell', _Stayer(StayVerdict.held));

    expect(claim.acquire('doorbell', owner: 'host', onVerdict: (_) {}),
        isA<Held>());
  });

  test('the Popup on top answers for the Device — the ones under it are not '
      'even asked', () {
    final (:claim, :frame) = rig();
    final under = _Stayer(StayVerdict.held);
    final top = _Stayer(StayVerdict.extended);
    claim.register('doorbell', under);
    claim.register('doorbell', top);

    expect(claim.acquire('doorbell', owner: 'host', onVerdict: (_) {}),
        isA<Extended>());
    expect(top.asked, 1);
    expect(under.asked, 0,
        reason: 'the one on top is the one somebody is looking at');
  });

  test('a Popup underneath one that is leaving still holds the stream, so the '
      'Device is not free', () {
    final (:claim, :frame) = rig();
    final under = _Stayer(StayVerdict.held);
    claim.register('doorbell', under);
    claim.register('doorbell', _Stayer(StayVerdict.leaving));

    // `leaving` from the top is not an answer about the DEVICE: the one
    // underneath is on the wall with a live session behind it, and a caller
    // told to push would open a second consumer on the one stream.
    expect(claim.acquire('doorbell', owner: 'host', onVerdict: (_) {}),
        isA<Held>());
    expect(under.asked, 1);
  });

  test('every Popup leaving is a wait, answered when the last one goes', () {
    fakeAsync((async) {
      final (:claim, :frame) = rig();
      final popup = _Stayer(StayVerdict.leaving);
      claim.register('doorbell', popup);
      final verdicts = <ClaimAnswer>[];

      expect(claim.acquire('doorbell', owner: 'host', onVerdict: verdicts.add),
          isA<Wait>());
      expect(verdicts, isEmpty, reason: 'the caller does nothing now');

      claim.deregister('doorbell', popup);
      expect(verdicts, isEmpty,
          reason: 'not from inside a Popup dispose — pushing a route there is '
              'a framework error');

      frame();
      expect(verdicts, [isA<Claim>()]);
      expect(async.pendingTimers, isEmpty, reason: 'the clock came off with it');
    });
  });

  test('the newer of two Popups for one Device leaving does not free it', () {
    fakeAsync((async) {
      final (:claim, :frame) = rig();
      final older = _Stayer(StayVerdict.leaving);
      final newer = _Stayer(StayVerdict.leaving);
      claim.register('doorbell', older);
      claim.register('doorbell', newer);
      final verdicts = <ClaimAnswer>[];
      claim.acquire('doorbell', owner: 'host', onVerdict: verdicts.add);

      // Deregistered by identity: with one slot per Device the newer entry
      // overwrote the older and this teardown then cleared the slot, so the
      // claim answered `Claim` about a Device whose Dialog was up with a live
      // session behind it.
      claim.deregister('doorbell', newer);
      frame();
      expect(verdicts, isEmpty, reason: 'the older one still holds the stream');

      claim.deregister('doorbell', older);
      frame();
      expect(verdicts, [isA<Claim>()]);
      claim.abandon('host');
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('a request is judged against the wall it is finally offered to, not '
      'the one it left', () {
    fakeAsync((async) {
      final (:claim, :frame) = rig();
      final leaving = _Stayer(StayVerdict.leaving);
      claim.register('doorbell', leaving);
      final verdicts = <ClaimAnswer>[];
      claim.acquire('doorbell', owner: 'host', onVerdict: verdicts.add);

      claim.deregister('doorbell', leaving);
      // Somebody taps the pin in the frame between the old Popup's teardown
      // and the request being offered again. Answered `Claim` blind, this is
      // a second go2rtc consumer on a stream a person is already watching.
      claim.register('doorbell', _Stayer(StayVerdict.held));
      frame();

      expect(verdicts, [isA<Held>()]);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('a request that waits out the window is dropped, and says how long it '
      'waited', () {
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

  test('a dropped request is spent — the Device coming free later brings '
      'nothing back from the dead', () {
    fakeAsync((async) {
      final (:claim, :frame) = rig();
      final stuck = _Stayer(StayVerdict.leaving);
      claim.register('doorbell', stuck);
      final verdicts = <ClaimAnswer>[];
      claim.acquire('doorbell', owner: 'host', onVerdict: verdicts.add);

      async.elapse(kPopupClaimWindow + const Duration(seconds: 1));
      expect(verdicts, [isA<Dropped>()]);

      // The Popup past its ceiling finally gets its way out.
      claim.deregister('doorbell', stuck);
      frame();
      expect(verdicts, hasLength(1),
          reason: 'a live session for a visitor who left minutes ago is the '
              'resurrection dropping exists to prevent');
    });
  });

  test('a newer request replaces the older, clock and all', () {
    fakeAsync((async) {
      final (:claim, :frame) = rig();
      claim.register('doorbell', _Stayer(StayVerdict.leaving));
      final verdicts = <ClaimAnswer>[];
      claim.acquire('doorbell', owner: 'host', onVerdict: verdicts.add);

      async.elapse(const Duration(seconds: 20));
      // One visitor leaning on the button. They would have opened one Popup
      // between them, and the wait that matters is the wait since the last
      // press.
      claim.acquire('doorbell', owner: 'host', onVerdict: verdicts.add);

      async.elapse(const Duration(seconds: 20));
      expect(verdicts, isEmpty,
          reason: '40 s since the first press, 20 s since the last');
      expect(async.pendingTimers, hasLength(1),
          reason: 'the older clock came off when the newer went on');

      async.elapse(const Duration(seconds: 11));
      expect(verdicts, [isA<Dropped>()], reason: 'one request, one answer');
    });
  });

  test('a request offered to a wall that is still leaving keeps its original '
      'clock rather than starting a new one', () {
    fakeAsync((async) {
      final (:claim, :frame) = rig();
      final first = _Stayer(StayVerdict.leaving);
      claim.register('doorbell', first);
      final verdicts = <ClaimAnswer>[];
      claim.acquire('doorbell', owner: 'host', onVerdict: verdicts.add);

      async.elapse(const Duration(seconds: 25));
      claim.deregister('doorbell', first);
      // And another Popup for the same Device is already on its way out in
      // the same frame. Re-arming here would let a chain of closing Popups
      // hold a request well past the window that exists to say when it went
      // stale.
      final second = _Stayer(StayVerdict.leaving);
      claim.register('doorbell', second);
      frame();
      expect(verdicts, isEmpty);

      async.elapse(const Duration(seconds: 5));
      expect(verdicts, [isA<Dropped>()],
          reason: '30 s after the press, not 30 s after the re-offer');
    });
  });

  test('a request still waiting when its Device comes free inside the window '
      'is answered, not dropped', () {
    fakeAsync((async) {
      final (:claim, :frame) = rig();
      final first = _Stayer(StayVerdict.leaving);
      claim.register('doorbell', first);
      final verdicts = <ClaimAnswer>[];
      claim.acquire('doorbell', owner: 'host', onVerdict: verdicts.add);

      async.elapse(const Duration(seconds: 25));
      claim.deregister('doorbell', first);
      final second = _Stayer(StayVerdict.leaving);
      claim.register('doorbell', second);
      frame();

      async.elapse(const Duration(seconds: 2));
      claim.deregister('doorbell', second);
      frame();

      expect(verdicts, [isA<Claim>()]);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('abandon drops the owner\'s requests and their clocks, and nobody '
      'else\'s', () {
    fakeAsync((async) {
      final (:claim, :frame) = rig();
      final doorbell = _Stayer(StayVerdict.leaving);
      final porch = _Stayer(StayVerdict.leaving);
      claim.register('doorbell', doorbell);
      claim.register('cam-porch', porch);
      final theirs = <ClaimAnswer>[];
      final ours = <ClaimAnswer>[];
      claim.acquire('doorbell', owner: 'host', onVerdict: ours.add);
      claim.acquire('cam-porch', owner: 'other', onVerdict: theirs.add);

      claim.abandon('host');
      expect(async.pendingTimers, hasLength(1),
          reason: 'one caller leaving may not silently drop another\'s');

      claim.deregister('doorbell', doorbell);
      frame();
      expect(ours, isEmpty, reason: 'a caller that is gone is not told');

      claim.deregister('cam-porch', porch);
      frame();
      expect(theirs, [isA<Claim>()]);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('the claim is keyed by Device — a Popup showing one is no answer about '
      'another', () {
    fakeAsync((async) {
      final (:claim, :frame) = rig();
      claim.register('cam-porch', _Stayer(StayVerdict.held));

      expect(claim.acquire('doorbell', owner: 'host', onVerdict: (_) {}),
          isA<Claim>(),
          reason: 'two doorbells are two streams');
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('deregistering a Device nothing is waiting on costs nothing', () {
    fakeAsync((async) {
      final (:claim, :frame) = rig();
      final popup = _Stayer(StayVerdict.held);
      claim.register('doorbell', popup);

      claim.deregister('doorbell', popup);
      frame();
      // And the Device is free afterwards, which is what a Popup closing
      // normally means.
      expect(claim.acquire('doorbell', owner: 'host', onVerdict: (_) {}),
          isA<Claim>());
      expect(async.pendingTimers, isEmpty);
    });
  });
}

/// A Popup on the wall that answers however the case tells it to — the seam's
/// second adapter, and why [PopupStayer] is an interface rather than the
/// Popup's own State.
class _Stayer implements PopupStayer {
  _Stayer(this.verdict);

  StayVerdict verdict;

  /// How many times the claim asked. The rule that the Popup on top answers
  /// for the Device is only half about the answer; the other half is that the
  /// ones underneath are not asked, and so do not restart deadlines nobody
  /// looked at.
  int asked = 0;

  @override
  StayVerdict stayUp() {
    asked++;
    return verdict;
  }
}
