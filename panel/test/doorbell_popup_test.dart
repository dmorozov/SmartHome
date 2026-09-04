import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/diagnostics/log.dart';
import 'package:panel/domain/device_state.dart';
import 'package:panel/ui/doorbell_popup_host.dart';
import 'package:panel/ui/popup_claim.dart';
import 'package:panel/ui/video/live_video.dart';

import 'fixtures.dart';
import 'support/fake_go2rtc.dart';
import 'test_house.dart';

/// A Popup on the wall that is always on its way out, so nothing can ever
/// free the Device it shows. Stands in for the one state a deferred ding can
/// wait in indefinitely, without needing a route stuck under another route to
/// produce it.
class _NeverLeaves implements PopupStayer {
  @override
  StayVerdict stayUp() => StayVerdict.leaving;
}

/// The Popup nobody asked for: the whole path from a Hub message to a live
/// view on the wall, staged through FakeHub's driving surface — the same
/// adapter a dev build runs — rather than by calling the host by hand.
///
/// Whether the *rule* is right is `doorbell_test.dart`'s question and
/// `hub_controller_test.dart`'s. What is asked here is the part only a real
/// tree can answer: that a route gets pushed at all, that it carries the
/// Panel's own go2rtc address, and that it goes away again on its own.
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

  testWidgets('a ding opens the Popup nobody asked for, and it closes itself',
      (tester) async {
    // The shipped bindings name no stream (no go2rtc feed exists for the
    // placeholder cameras yet), so the scene states the wiring itself.
    final (controller, hub) = fakeHubRig(
        house: houseWithStream(loadTestHouse(), 'doorbell', 'ring_doorbell'));
    final go2rtc = FakeGo2rtc();
    await tester.pumpWidget(panelApp(controller,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open)));

    // First sight is never a press, so the doorbell has to have been at rest
    // before it can ring — exactly as on the wall after a Panel restart.
    hub.pushState(const StatusState('doorbell', 'off'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);

    hub.pushState(const StatusState('doorbell', 'on'));
    await tester.pumpAndSettle();

    expect(find.text('Ring Doorbell'), findsOneWidget);
    // The Panel's own go2rtc, not one the host invented for itself.
    expect(go2rtc.only.url.toString(), 'ws://hub:1984/api/ws?src=ring_doorbell');
    expect(popupLines('doorbell').single.fields,
        {'device': 'doorbell', 'reason': 'ding'});

    await tester.pump(kDoorbellPopupDeadline + const Duration(seconds: 1));
    await tester.pumpAndSettle();

    // Nobody came to the wall, so nothing dismissed it — and a Ring session
    // left running can suppress the next real ding (#177014), which is what
    // makes this a correctness property rather than tidiness.
    expect(find.byType(Dialog), findsNothing);
    expect(go2rtc.only.closes, 1);
    expect(popupLines('doorbell_dismissed').single.fields,
        {'device': 'doorbell'});
  });

  testWidgets('a second ding keeps the video up instead of tearing the stream '
      'down and paying for it again', (tester) async {
    final (controller, hub) = fakeHubRig(
        house: houseWithStream(loadTestHouse(), 'doorbell', 'ring_doorbell'));
    final go2rtc = FakeGo2rtc();
    await tester.pumpWidget(panelApp(controller,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open)));

    hub.pushState(const StatusState('doorbell', 'off'));
    await tester.pump();
    hub.pushState(const StatusState('doorbell', 'on'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);

    await tester.pump(const Duration(seconds: 20));
    hub.pushState(const StatusState('doorbell', 'off'));
    await tester.pump();
    hub.pushState(const StatusState('doorbell', 'on'));
    await tester.pump(const Duration(seconds: 20));

    // Past the first deadline, still the same session: a re-push would black
    // the wall out for the 2-5 s a Ring stream takes to spin up, at the exact
    // moment somebody is standing at the door.
    expect(find.byType(Dialog), findsOneWidget);
    expect(go2rtc.opened, hasLength(1));
    expect(go2rtc.only.closes, 0);
    expect(popupLines('doorbell'), hasLength(1));
    expect(popupLines('doorbell_extended').single.fields,
        {'device': 'doorbell'});

    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();

    // The deadline was extended, not cancelled: a visitor who leaves still
    // leaves the wall alone.
    expect(find.byType(Dialog), findsNothing);
    expect(go2rtc.only.closes, 1);
  });

  testWidgets('a doorbell that never stops ringing still gives the stream up '
      'at the ceiling instead of holding one session for the whole hour',
      (tester) async {
    final (controller, hub) = fakeHubRig(
        house: houseWithStream(loadTestHouse(), 'doorbell', 'ring_doorbell'));
    final go2rtc = FakeGo2rtc();
    await tester.pumpWidget(panelApp(controller,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open)));

    hub.pushState(const StatusState('doorbell', 'off'));
    await tester.pump();

    // A ding every 25 s for a simulated hour — faster than the 30 s deadline,
    // which before the ceiling meant one session opened once and never
    // closed, with the wall lit and nobody in the room (#177014's own hazard).
    for (var i = 0; i < 144; i++) {
      hub.pushState(const StatusState('doorbell', 'on'));
      await tester.pump(const Duration(seconds: 25));
      hub.pushState(const StatusState('doorbell', 'off'));
      await tester.pump();
      // No session may outlive the ceiling, so at no point in the hour is
      // more than one consumer live on `ring_doorbell`.
      expect(go2rtc.opened.where((s) => s.closes == 0), hasLength(lessThan(2)),
          reason: 'ring $i');
    }
    await tester.pump(kDoorbellPopupCeiling);
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(go2rtc.opened.where((s) => s.closes == 0), isEmpty);
    // Recycled rather than held: each Popup lived at most the ceiling, and the
    // ding after it opened a fresh one, which is what makes the ceiling a
    // bound on the *session's* age rather than a way to lose the doorbell.
    expect(go2rtc.opened.length, greaterThan(1));
    expect(popupLines('deadline_ceiling').first.fields,
        {'device': 'doorbell', 'open_s': kDoorbellPopupCeiling.inSeconds});
  });

  testWidgets('a ding while a person already has that doorbell up extends '
      'their Popup instead of opening a second session on the same stream',
      (tester) async {
    final (controller, hub) = fakeHubRig(
        house: houseWithStream(loadTestHouse(), 'doorbell', 'ring_doorbell'));
    final go2rtc = FakeGo2rtc();
    await tester.pumpWidget(panelApp(controller,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open)));

    // Somebody at the wall taps the doorbell pin: a Popup this host did not
    // push, on the same go2rtc stream a ding would want.
    await tester.tap(find.byKey(const ValueKey('pin-doorbell')));
    await tester.pumpAndSettle();
    expect(go2rtc.opened, hasLength(1));

    hub.pushState(const StatusState('doorbell', 'off'));
    await tester.pump();
    hub.pushState(const StatusState('doorbell', 'on'));
    await tester.pumpAndSettle();

    // One Dialog, one session. The host used to know only about Popups it had
    // pushed itself, so this stacked a second Popup and a second live
    // consumer on `ring_doorbell` — and the tapped one, having no deadline,
    // then held its session indefinitely.
    expect(find.byType(Dialog), findsOneWidget);
    expect(go2rtc.opened, hasLength(1));
    expect(go2rtc.only.closes, 0);
    expect(popupLines('doorbell_held').single.fields,
        {'device': 'doorbell', 'reason': 'person_opened'});
    expect(popupLines('doorbell'), isEmpty);

    await tester.pump(const Duration(minutes: 5));

    // And it is still deadline-less: the ding did not smuggle a countdown
    // into a Popup a person opened (D14).
    expect(find.byType(Dialog), findsOneWidget);
    expect(go2rtc.only.closes, 0);
  });

  testWidgets('a ding landing during the exit animation waits for the old '
      'stream to close instead of opening a second one on it', (tester) async {
    final (controller, hub) = fakeHubRig(
        house: houseWithStream(loadTestHouse(), 'doorbell', 'ring_doorbell'));
    final go2rtc = FakeGo2rtc();
    await tester.pumpWidget(panelApp(controller,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open)));

    hub.pushState(const StatusState('doorbell', 'off'));
    await tester.pump();
    hub.pushState(const StatusState('doorbell', 'on'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('popup-close')));
    // ~150 ms of exit animation follow the pop, and for all of it the old
    // Popup is still mounted with its session open. The host used to clear
    // its bookkeeping from `showDialog`'s future, which completes at the
    // start of that window rather than the end.
    await tester.pump(const Duration(milliseconds: 20));
    hub.pushState(const StatusState('doorbell', 'off'));
    await tester.pump();
    hub.pushState(const StatusState('doorbell', 'on'));
    await tester.pump();

    expect(go2rtc.opened.where((s) => s.closes == 0), hasLength(1));
    expect(popupLines('doorbell_deferred').single.fields,
        {'device': 'doorbell', 'reason': 'stream_closing'});

    await tester.pumpAndSettle();

    // Deferred, not dropped — somebody is at the door. The second session
    // only ever exists after the first is closed.
    expect(find.text('Ring Doorbell'), findsOneWidget);
    expect(go2rtc.opened, hasLength(2));
    expect(go2rtc.opened.first.closes, 1);
    expect(go2rtc.opened.last.closes, 0);

    await tester.pump(kDoorbellPopupDeadline + const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(go2rtc.opened.last.closes, 1);
  });

  testWidgets('a ding during the exit of a Popup a person opened is answered '
      'too, not swallowed and then resurrected minutes later', (tester) async {
    // The Popup a person opens by tapping a pin is pushed by
    // `dollhouse_view`, which passes no `onGone` and has no reason to know
    // the doorbell exists. A ding deferred behind it was therefore never
    // offered again by the Popup that deferred it: nobody was shown who was
    // at the door, and the entry then sat in the host's bookkeeping until the
    // *next* Popup's teardown redeemed it — a Ring session opening minutes
    // later with no ding behind it, on top of something unrelated.
    final (controller, hub) = fakeHubRig(
        house: houseWithStream(loadTestHouse(), 'doorbell', 'ring_doorbell'));
    final go2rtc = FakeGo2rtc();
    await tester.pumpWidget(panelApp(controller,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open)));

    await tester.tap(find.byKey(const ValueKey('pin-doorbell')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('popup-close')));
    // Inside the ~150 ms exit animation, where the old Popup is still mounted
    // with its session open and a second one would be a second consumer.
    await tester.pump(const Duration(milliseconds: 20));

    hub.pushState(const StatusState('doorbell', 'off'));
    await tester.pump();
    hub.pushState(const StatusState('doorbell', 'on'));
    await tester.pump();

    expect(popupLines('doorbell_deferred').single.fields,
        {'device': 'doorbell', 'reason': 'stream_closing'});

    await tester.pumpAndSettle();

    // Somebody is at the door and the wall says so, once the stream is free.
    expect(find.text('Ring Doorbell'), findsOneWidget);
    expect(go2rtc.opened, hasLength(2));
    expect(go2rtc.opened.first.closes, 1);

    await tester.pump(kDoorbellPopupDeadline + const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 5));
    await tester.pumpAndSettle();

    // And nothing comes back from the dead five minutes later: the ding was
    // spent when it was answered.
    expect(find.byType(Dialog), findsNothing);
    expect(go2rtc.opened, hasLength(2));
    expect(go2rtc.opened.last.closes, 1);
  });

  testWidgets('a deferred ding that waits longer than a Popup would have '
      'stayed up is dropped with a warn, not shown late', (tester) async {
    // A ding is a real-time event. The one way to wait a long time is a Popup
    // past its ceiling that cannot pop itself because another route is
    // stacked on top of it — every ding in that window answers `leaving`.
    // Redeeming one of those when the way out finally clears would open a
    // Ring session for a visitor who left minutes ago, and #177014 says that
    // session then suppresses the next real ding.
    final (controller, hub) = fakeHubRig(
        house: houseWithStream(loadTestHouse(), 'doorbell', 'ring_doorbell'));
    final go2rtc = FakeGo2rtc();
    await tester.pumpWidget(panelApp(controller,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: go2rtc.open)));

    hub.pushState(const StatusState('doorbell', 'off'));
    await tester.pump();
    hub.pushState(const StatusState('doorbell', 'on'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);

    final navigator =
        tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('something else'))));
    await tester.pumpAndSettle();
    await tester.pump(kDoorbellPopupCeiling + const Duration(seconds: 1));
    expect(popupLines('deadline_ceiling'), hasLength(1));

    hub.pushState(const StatusState('doorbell', 'off'));
    await tester.pump();
    hub.pushState(const StatusState('doorbell', 'on'));
    await tester.pump();
    expect(popupLines('doorbell_deferred'), hasLength(1));

    await tester.pump(kPopupClaimWindow + const Duration(seconds: 1));

    // Warn, because this is the one path where somebody pressed the bell and
    // the wall never says so — the failure with no symptom of its own.
    final dropped = popupLines('doorbell_dropped').single;
    expect(dropped.level, LogLevel.warn);
    expect(dropped.fields, {
      'device': 'doorbell',
      'reason': 'popup_never_closed',
      'waited_s': kPopupClaimWindow.inSeconds,
    });

    navigator.pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    // The stuck Popup leaves as soon as it may, and takes nothing with it:
    // no second Ring session for a ding that expired.
    expect(find.byType(Dialog), findsNothing);
    expect(go2rtc.opened, hasLength(1));
    expect(go2rtc.only.closes, 1);
    expect(popupLines('doorbell'), hasLength(1));
  });

  testWidgets('a ding still waiting for its turn when the Panel goes down '
      'takes its clock with it', (tester) async {
    // The claim is one object for the whole wall and outlives every route, so
    // a request this host leaves waiting in it is not collected with the
    // tree — the host has to hand it back.
    final (controller, hub) = fakeHubRig(
        house: houseWithStream(loadTestHouse(), 'doorbell', 'ring_doorbell'));
    await tester.pumpWidget(panelApp(controller,
        video: VideoConfig(go2rtcUrl: 'http://hub:1984', open: FakeGo2rtc().open)));

    // A Popup for this doorbell that is on its way out and stays that way, so
    // the Device never comes free and the claim's own redemption — the thing
    // that takes the clock off on every ordinary path — never gets its turn.
    // That is the shape of a kiosk shutdown: the frame that would have
    // redeemed the ding is the frame that never comes.
    final stuck = _NeverLeaves();
    popupClaim.register('doorbell', stuck);

    hub.pushState(const StatusState('doorbell', 'off'));
    await tester.pump();
    hub.pushState(const StatusState('doorbell', 'on'));
    await tester.pump();
    expect(popupLines('doorbell_deferred'), hasLength(1));

    // Down goes the Panel, with the ding still waiting.
    //
    // The stand-in has to be taken off the shared claim from a `tearDown` and
    // not from here: the harness checks for pending Timers before it runs
    // those, and deregistering inside the case would redeem the ding on the
    // next frame and take the clock off — cancelling the very leak this is
    // here to catch.
    addTearDown(() => popupClaim.deregister('doorbell', stuck));
    await tester.pumpWidget(const SizedBox.shrink());

    // Nothing more to assert than the harness's own verdict: a Timer still
    // pending once the tree is gone fails this case by itself, and that is
    // precisely what a request nobody handed back would leave behind.
  });
}
