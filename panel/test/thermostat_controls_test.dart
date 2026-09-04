import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/fake_hub.dart';
import 'package:panel/diagnostics/log.dart';
import 'package:panel/domain/device_state.dart';
import 'package:panel/domain/house.dart';
import 'package:panel/ui/device_popup.dart';
import 'package:panel/ui/hub_controller.dart';
import 'package:panel/ui/theme.dart';

import 'support/hermetic_director.dart';
import 'test_house.dart';

/// The setpoint controls' whole promise, stated as scenes: the number on
/// display is the Hub's word or a dialled value visibly awaiting the Hub's
/// word — never a third thing — and every dialling gesture becomes exactly
/// one absolute command that either lands (the echo confirms it) or is
/// taken back off the glass (the revert). device_popup_test owns the Popup
/// chrome; this file owns the body a thermostat gets.
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

  Device thermostatOf(House house) => house.floors
      .expand((f) => f.devices)
      .firstWhere((d) => d.kind == DeviceKind.thermostat);

  /// Opens the thermostat's Popup the way the Dollhouse does — through
  /// `showDevicePopup` and a real route — with or without hands.
  Future<Device> openPopup(
    WidgetTester tester, {
    required HubController controller,
    bool handsOn = true,
  }) async {
    final device = thermostatOf(controller.house);
    // A thermostat body attaches no feed, but the seam is one seam: every
    // Popup takes the Director, and the fixture's unconfigured one is the
    // honest thing for a scene with no video in it.
    await tester.pumpWidget(HermeticDirector(
      key: UniqueKey(),
      builder: (_, director) => MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDevicePopup(
              context,
              presentation: controller.presentationOf(device),
              director: director,
              controller: handsOn ? controller : null,
            ),
            child: const Text('tap the pin'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('tap the pin'));
    await tester.pumpAndSettle();
    return device;
  }

  /// The standard scene: the shipped House on a drift-frozen fake Hub, the
  /// thermostat pinned to the fixture the contract suite also uses.
  (HubController, FakeHub, String) rig({FakeHub Function(House)? hub}) {
    final house = loadTestHouse();
    final fake = hub?.call(house) ?? FakeHub(house, driftEvery: Duration.zero);
    final controller = HubController(house: house, hub: fake);
    final id = thermostatOf(house).id;
    fake.pushState(ThermostatState(id,
        current: 21.4, target: 21.0, unit: TemperatureUnit.celsius));
    return (controller, fake, id);
  }

  Text valueText(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const ValueKey('setpoint-value')));

  ThermostatState stateOf(FakeHub hub, String id) =>
      hub.states[id] as ThermostatState;

  testWidgets('shows the live reading, and the target between − and +',
      (tester) async {
    final (controller, _, _) = rig();
    await openPopup(tester, controller: controller);

    expect(find.text('21.4 °C now'), findsOneWidget);
    expect(valueText(tester).data, '21.0 °C');
    expect(find.text('target'), findsOneWidget);
    // The Hub's own word, in ink — nothing is pending.
    expect(valueText(tester).style!.color, PanelTheme.ink);
  });

  testWidgets('a tap steps the display at once but commands only when the '
      'gesture settles', (tester) async {
    final (controller, hub, id) = rig();
    await openPopup(tester, controller: controller);

    await tester.tap(find.byKey(const ValueKey('setpoint-plus')));
    await tester.pump();

    // Dialled, visibly a promise (accent), and NOT yet commanded: the
    // debounce is still open for the next tap of the same gesture.
    expect(valueText(tester).data, '21.5 °C');
    expect(valueText(tester).style!.color, PanelTheme.accent);
    expect(stateOf(hub, id).target, 21.0);

    await tester.pump(const Duration(milliseconds: 800));
    expect(stateOf(hub, id).target, 21.5);

    // The fake's echo is immediate; the wall adopts the Hub's word and the
    // number stops being a promise.
    await tester.pump();
    expect(valueText(tester).data, '21.5 °C');
    expect(valueText(tester).style!.color, PanelTheme.ink);
  });

  testWidgets('quick taps are one gesture: one command carries the sum',
      (tester) async {
    final (controller, hub, id) = rig();
    final device = await openPopup(tester, controller: controller);

    var commands = 0;
    final sub = hub.stateChanges.listen((changed) {
      if (changed == device.id) commands += 1;
    });
    addTearDown(sub.cancel);

    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const ValueKey('setpoint-plus')));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(valueText(tester).data, '22.5 °C');
    expect(stateOf(hub, id).target, 21.0); // still one open gesture

    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();

    expect(stateOf(hub, id).target, 22.5);
    // Three taps, one write to the HVAC — the debounce's whole reason.
    expect(commands, 1);
  });

  testWidgets('a Fahrenheit reading steps by the Fahrenheit granule',
      (tester) async {
    final (controller, hub, id) = rig();
    hub.pushState(ThermostatState(id,
        current: 71.2, target: 70.0, unit: TemperatureUnit.fahrenheit));
    await openPopup(tester, controller: controller);

    await tester.tap(find.byKey(const ValueKey('setpoint-plus')));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();

    expect(valueText(tester).data, '71.0 °F');
    expect(stateOf(hub, id).target, 71.0);
  });

  testWidgets('an off-grid target steps onto the grid, and the number sent '
      'is the number shown', (tester) async {
    final (controller, hub, id) = rig();
    // What a HomeKit thermostat's quantised word can look like after HA's
    // unit conversion: nowhere near a half-degree boundary.
    hub.pushState(ThermostatState(id,
        current: 21.4, target: 21.7, unit: TemperatureUnit.celsius));
    await openPopup(tester, controller: controller);

    await tester.tap(find.byKey(const ValueKey('setpoint-plus')));
    await tester.pump();

    expect(valueText(tester).data, '22.0 °C');
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();
    expect(stateOf(hub, id).target, 22.0);
  });

  testWidgets('no reading, no controls: an unknown thermostat offers '
      'nothing to step from', (tester) async {
    final (controller, hub, id) = rig();
    hub.dropDevice(id);
    await openPopup(tester, controller: controller);

    expect(find.text('Unknown'), findsOneWidget);
    expect(valueText(tester).data, '—');

    // A tap on the disabled button dials nothing and commands nothing —
    // stepping from a number nobody reported would be inventing a setpoint.
    await tester.tap(find.byKey(const ValueKey('setpoint-plus')));
    await tester.pump(const Duration(milliseconds: 800));
    expect(hub.states.containsKey(id), isFalse);
    expect(valueText(tester).data, '—');
  });

  testWidgets('closing the Popup mid-gesture still lands the dial',
      (tester) async {
    final (controller, hub, id) = rig();
    await openPopup(tester, controller: controller);

    await tester.tap(find.byKey(const ValueKey('setpoint-plus')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('popup-close')));
    await tester.pumpAndSettle();

    // The glass said 21.5 when the thumb left it; the command must not die
    // with the widget, or the wall lied.
    expect(stateOf(hub, id).target, 21.5);
  });

  testWidgets('a command the Hub never answers is taken back off the glass',
      (tester) async {
    final (controller, hub, id) =
        rig(hub: (house) => _DeafFakeHub(house));
    final deaf = hub as _DeafFakeHub;
    await openPopup(tester, controller: controller);

    await tester.tap(find.byKey(const ValueKey('setpoint-plus')));
    await tester.pump(const Duration(milliseconds: 800));
    expect(deaf.commanded, [21.5]);
    expect(valueText(tester).data, '21.5 °C');
    expect(valueText(tester).style!.color, PanelTheme.accent);

    await tester.pump(const Duration(seconds: 5));

    // The revert: the thermostat never adopted 21.5, so the wall may not
    // keep saying it. The Hub's word comes back, and the journal says what
    // it cost.
    expect(valueText(tester).data, '21.0 °C');
    expect(valueText(tester).style!.color, PanelTheme.ink);
    final warned =
        records.singleWhere((r) => r.event == 'setpoint_unconfirmed');
    expect(warned.level, LogLevel.warn);
    expect(warned.fields, {'device': id, 'target': 21.5});
  });

  testWidgets('the Hub answering with its own idea of the value wins',
      (tester) async {
    final (controller, _, id) =
        rig(hub: (house) => _QuantisingFakeHub(house));
    await openPopup(tester, controller: controller);

    await tester.tap(find.byKey(const ValueKey('setpoint-plus')));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();

    // Commanded 21.5; the thermostat adopted 21.7. The Hub's word is the
    // honest thing to show — immediately, not after a revert timeout.
    expect(valueText(tester).data, '21.7 °C');
    expect(valueText(tester).style!.color, PanelTheme.ink);
    expect(records.where((r) => r.event == 'setpoint_unconfirmed'), isEmpty);
  });

  testWidgets('dialling back to where the thermostat stands commands '
      'nothing', (tester) async {
    final (controller, hub, id) = rig();
    final device = await openPopup(tester, controller: controller);

    var commands = 0;
    final sub = hub.stateChanges.listen((changed) {
      if (changed == device.id) commands += 1;
    });
    addTearDown(sub.cancel);

    await tester.tap(find.byKey(const ValueKey('setpoint-plus')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('setpoint-minus')));
    await tester.pump(const Duration(milliseconds: 800));

    // +0.5 then −0.5 is a change of mind, not a command — and nothing is
    // left pending, because there is nothing to await an echo for.
    expect(commands, 0);
    expect(stateOf(hub, id).target, 21.0);
    expect(valueText(tester).data, '21.0 °C');
    expect(valueText(tester).style!.color, PanelTheme.ink);
  });

  testWidgets('a countermand dialled while the first command is in flight '
      'is still a command', (tester) async {
    final (controller, hub, _) = rig(hub: (house) => _DeafFakeHub(house));
    final deaf = hub as _DeafFakeHub;
    await openPopup(tester, controller: controller);

    // +0.5, delivered; then −0.5 back to 21.0 *while the echo is still
    // out*. The live target also says 21.0 — but that number is exactly
    // what the un-echoed command is about to move, so treating the dial as
    // "already there" would silently lose the user's last action while the
    // HVAC settles at 21.5.
    await tester.tap(find.byKey(const ValueKey('setpoint-plus')));
    await tester.pump(const Duration(milliseconds: 800));
    expect(deaf.commanded, [21.5]);
    await tester.tap(find.byKey(const ValueKey('setpoint-minus')));
    await tester.pump(const Duration(milliseconds: 800));

    expect(deaf.commanded, [21.5, 21.0]);

    // Nothing answers on this Hub; let the confirm window close so no
    // timer outlives the test.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a countermand mid-flight survives the Popup closing too',
      (tester) async {
    final (controller, hub, _) = rig(hub: (house) => _DeafFakeHub(house));
    final deaf = hub as _DeafFakeHub;
    await openPopup(tester, controller: controller);

    await tester.tap(find.byKey(const ValueKey('setpoint-plus')));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.tap(find.byKey(const ValueKey('setpoint-minus')));
    await tester.tap(find.byKey(const ValueKey('popup-close')));
    await tester.pumpAndSettle();

    // The flush must make the same in-flight-aware comparison the debounce
    // does: the glass said 21.0 when it went dark, and 21.5 is on its way
    // to the thermostat.
    expect(deaf.commanded, [21.5, 21.0]);
  });

  testWidgets('the revert answers the old command, not a dial still being '
      'made', (tester) async {
    final (controller, hub, id) = rig(hub: (house) => _DeafFakeHub(house));
    final deaf = hub as _DeafFakeHub;
    await openPopup(tester, controller: controller);

    // Send at t≈0.8s; the confirm window closes at t≈5.8s. A new tap lands
    // at t≈5.3s — inside the window, its own debounce open until t≈6.1s.
    await tester.tap(find.byKey(const ValueKey('setpoint-plus')));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 4500));
    await tester.tap(find.byKey(const ValueKey('setpoint-plus')));
    await tester.pump(const Duration(milliseconds: 500));

    // t≈5.8s: the revert fired. It answers the 21.5 that went unconfirmed
    // — naming *that* value, not the 22.0 mid-gesture — and it may not
    // touch the newer dial, which is still a promise being made.
    final warned =
        records.singleWhere((r) => r.event == 'setpoint_unconfirmed');
    expect(warned.fields, {'device': id, 'target': 21.5});
    expect(valueText(tester).data, '22.0 °C');
    expect(valueText(tester).style!.color, PanelTheme.accent);

    // t≈6.1s: the new gesture settles and commands like any other.
    await tester.pump(const Duration(milliseconds: 300));
    expect(deaf.commanded, [21.5, 22.0]);

    // And with the Hub still deaf, that command reverts in its own turn.
    await tester.pump(const Duration(seconds: 5));
    expect(valueText(tester).data, '21.0 °C');
    expect(
        records.where((r) => r.event == 'setpoint_unconfirmed').length, 2);
  });

  testWidgets('a report restating the unmoved target is not an echo',
      (tester) async {
    final (controller, hub, id) = rig(hub: (house) => _DeafFakeHub(house));
    await openPopup(tester, controller: controller);

    await tester.tap(find.byKey(const ValueKey('setpoint-plus')));
    await tester.pump(const Duration(milliseconds: 800));

    // The room warms a tenth while the command is out: current moves,
    // target does not. The dialled 21.5 is still unanswered and must stay
    // on display — clearing it on any report at all would let an ordinary
    // reading wipe a pending promise.
    hub.pushState(ThermostatState(id,
        current: 21.9, target: 21.0, unit: TemperatureUnit.celsius));
    await tester.pumpAndSettle();

    expect(find.text('21.9 °C now'), findsOneWidget);
    expect(valueText(tester).data, '21.5 °C');
    expect(valueText(tester).style!.color, PanelTheme.accent);

    await tester.pump(const Duration(seconds: 5)); // let the revert land
  });

  testWidgets('each tap restarts the debounce — the gesture ends 800 ms '
      'after the last tap, not the first', (tester) async {
    final (controller, hub, id) = rig();
    await openPopup(tester, controller: controller);

    await tester.tap(find.byKey(const ValueKey('setpoint-plus')));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.byKey(const ValueKey('setpoint-plus')));
    await tester.pump(const Duration(milliseconds: 600));

    // 1.2 s after the first tap and 0.6 s after the second: a debounce
    // counted from the first tap would have fired at 0.8 s.
    expect(stateOf(hub, id).target, 21.0);

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(stateOf(hub, id).target, 22.0);
  });

  testWidgets('an echo landing while a newer dial is open does not eat the '
      'dial', (tester) async {
    final (controller, hub, _) = rig(hub: (house) => _SlowEchoFakeHub(house));
    final slow = hub as _SlowEchoFakeHub;
    await openPopup(tester, controller: controller);

    // Send 21.5 at t≈0.8s; its echo lands at t≈1.8s. A second tap at
    // t≈1.2s opens a debounce until t≈2.0s — so the echo arrives mid-
    // gesture, and it answers the *old* command, not the 22.0 being made.
    await tester.tap(find.byKey(const ValueKey('setpoint-plus')));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('setpoint-plus')));
    await tester.pump(const Duration(milliseconds: 700)); // t≈1.9s

    expect(valueText(tester).data, '22.0 °C');
    expect(valueText(tester).style!.color, PanelTheme.accent);

    // t≈2.0s: the gesture settles and 22.0 goes out; its own echo at
    // t≈3.0s is the one that confirms it.
    await tester.pump(const Duration(milliseconds: 100));
    expect(slow.commanded, [21.5, 22.0]);
    await tester.pump(const Duration(milliseconds: 1100));
    expect(valueText(tester).data, '22.0 °C');
    expect(valueText(tester).style!.color, PanelTheme.ink);
  });

  testWidgets('another surface moving the target moves this one',
      (tester) async {
    final (controller, hub, id) = rig();
    await openPopup(tester, controller: controller);

    hub.pushState(ThermostatState(id,
        current: 21.4, target: 23.0, unit: TemperatureUnit.celsius));
    // Settle, not a single pump: the report crosses a broadcast stream
    // (delivered in a microtask the first pump only schedules a frame from).
    await tester.pumpAndSettle();

    // Nobody dialled here, so there is no promise to protect: the wall
    // follows the Hub, whoever moved it.
    expect(valueText(tester).data, '23.0 °C');
  });

  testWidgets('without a controller the Popup keeps its old static '
      'sentence', (tester) async {
    final (controller, _, _) = rig();
    await openPopup(tester, controller: controller, handsOn: false);

    // The pre-controls body, byte for byte: callers with no hands to give
    // (today: tests) must keep getting what they always got.
    expect(find.text('21.4 °C now · target 21.0 °C'), findsOneWidget);
    expect(find.byKey(const ValueKey('setpoint-plus')), findsNothing);
    expect(find.byKey(const ValueKey('setpoint-value')), findsNothing);
  });
}

/// A Hub that accepts setpoint commands and never answers them — the
/// offline HVAC, the rejected value, the cloud that timed out. What the
/// controls owe the wall in that case is the revert.
class _DeafFakeHub extends FakeHub {
  _DeafFakeHub(super.house) : super(driftEvery: Duration.zero);

  final commanded = <double>[];

  @override
  Future<void> setThermostatTarget(String deviceId, double target) async {
    commanded.add(target);
  }
}

/// A Hub whose echo takes a second to come home — the HomeKit accessory
/// round-trip the widget's confirm window exists for. Every interleaving
/// where a person acts *between* the send and the echo needs this Hub.
class _SlowEchoFakeHub extends FakeHub {
  _SlowEchoFakeHub(super.house) : super(driftEvery: Duration.zero);

  final commanded = <double>[];

  @override
  Future<void> setThermostatTarget(String deviceId, double target) async {
    commanded.add(target);
    Timer(const Duration(seconds: 1), () {
      pushState(ThermostatState(deviceId,
          current: 21.4, target: target, unit: TemperatureUnit.celsius));
    });
  }
}

/// A Hub whose thermostat adopts its own quantised idea of every commanded
/// value — the HomeKit half-degree grid seen through HA's unit conversion.
class _QuantisingFakeHub extends FakeHub {
  _QuantisingFakeHub(super.house) : super(driftEvery: Duration.zero);

  @override
  Future<void> setThermostatTarget(String deviceId, double target) async {
    pushState(ThermostatState(deviceId,
        current: 21.4, target: target + 0.2, unit: TemperatureUnit.celsius));
  }
}
