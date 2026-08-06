import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/hub_client.dart';
import '../diagnostics/log.dart';
import '../domain/device_state.dart';
import '../domain/doorbell.dart';
import '../domain/house.dart';
import 'device_presentation.dart';

/// Presentation state: the House structure plus live Device state from the
/// Hub, folded into one Listenable for the widget tree — and the one place
/// that watches the stream of changes closely enough to tell a doorbell
/// press from a doorbell merely being re-reported.
class HubController extends ChangeNotifier {
  HubController({
    required this.house,
    required HubClient hub,
    DateTime Function() clock = DateTime.now,
  })  : _hub = hub,
        _now = clock {
    // Adopt what the Hub already holds, so `previous` really is "what this
    // Panel believes the Device says" rather than "what it has heard since
    // this object existed". The Panel is built after its Hub: `FakeHub`
    // seeds every Device in its own constructor and emits on a broadcast
    // stream nobody is listening to yet, so without this the seed is lost
    // and the first real change after every dev boot reads as a first sight
    // and is swallowed. Rejected: feeding `states` through [_readDoorbell]
    // instead, which treats the snapshot as a report and would ring the
    // house for whatever the entity happened to be saying at boot.
    for (final id in _doorbells.keys) {
      final state = hub.states[id];
      if (state is! StatusState) continue;
      _lastSeen[id] = state.status;
      // A press time already in the snapshot is a press this Panel will never
      // ring for — the seed above is what makes it `unchanged` — so it is
      // recorded as rung for, and stays that way if the entity later
      // round-trips through `unavailable`. Without this, a value the Panel
      // deliberately stayed silent about at boot could ring the house
      // minutes later on a re-report, which is the same press twice with the
      // first one never shown.
      final at = DateTime.tryParse(state.status);
      if (at != null) _rungFor[id] = at;
    }
    _sub = hub.stateChanges.listen(_onDeviceChanged);
    hub.status.addListener(_onStatusChanged);
  }

  /// How the Panel's link to the Hub stands, for the badge.
  HubStatus get status => _hub.status.value;

  final House house;
  final HubClient _hub;

  /// What time it is, injected so the ding rule's "recently" can be staged
  /// in a test. A function, not a `DateTime`: the answer has to be different
  /// on every message.
  final DateTime Function() _now;

  /// Live subscription to the Hub's changed-Device ids.
  ///
  /// The id used to be discarded — "any change repaints the whole Dollhouse"
  /// — and that stopped being true when the doorbell arrived. Repainting is
  /// still all-or-nothing, but *which* Device moved is the difference
  /// between someone at the door and a thermostat wobbling a tenth of a
  /// degree, and nothing else in the Panel is told.
  late final StreamSubscription<String> _sub;

  /// Somebody is at the door: one event per press, carrying the Device whose
  /// Popup should open.
  ///
  /// A [Stream], not a [ValueListenable]. A ring is an *event*; a listenable
  /// would hold "currently ringing" forever and re-deliver it to every late
  /// subscriber, which is the same bug class as the reconnect false-fire the
  /// classifier exists to prevent. Broadcast and asynchronous on purpose too:
  /// a `sync:` controller would run the subscriber's `showDialog` inside the
  /// Hub adapter's own call stack, and pushing a route from there is pushing
  /// it from somebody else's build.
  Stream<Device> get doorbellRings => _rings.stream;
  final _rings = StreamController<Device>.broadcast();

  /// What each doorbell currently says, as far as this Panel knows — the
  /// memory [classifyDing] deliberately does not keep. Seeded at
  /// construction from the Hub's own snapshot, cleared when the link leaves
  /// `up`, and dropped per Device when that Device's state goes away: an
  /// entry here is a *current* belief, never a souvenir.
  final _lastSeen = <String, String>{};

  /// The press time each doorbell has already rung for, by Device id — the
  /// `event.*_ding` shape only, since it is the only one that names a press.
  ///
  /// Deliberately the opposite lifetime to [_lastSeen]: never cleared, by a
  /// link drop or an entity drop or anything else. It is not a belief about
  /// what the Device says, it is a record of what this Panel has already
  /// done, and re-reporting a press does not un-ring it. Keeping it stale is
  /// safe in the one direction that matters — it can only turn a `pressed`
  /// into a `quiet`, never the reverse — which is precisely why the memory
  /// beside it may *not* be kept: a stale [_lastSeen] invented rings.
  ///
  /// One entry per doorbell for the life of the Panel, so nothing grows.
  final _rungFor = <String, DateTime>{};

  /// The doorbells, by Device id, resolved once. Rejected: walking the House
  /// on each change, which walks every Floor and Room once per Hub message
  /// to answer a question whose answer was fixed at boot.
  late final Map<String, Device> _doorbells = {
    for (final device in house.floors.expand((f) => f.devices))
      if (device.kind == DeviceKind.doorbell) device.id: device,
  };

  /// Everything the Dollhouse and the Popup need to render and act on
  /// [device], derived from its kind and current live state.
  DevicePresentation presentationOf(Device device) =>
      DevicePresentation(device, _hub.states[device.id]);

  /// A Room is lit when any light in it is on.
  bool isRoomLit(Room room) => room.devices
      .any((d) => d.kind == DeviceKind.light && presentationOf(d).glows);

  Future<void> toggle(String deviceId) => _hub.toggle(deviceId);

  /// Command a thermostat's target — the adapters own the refusal rules and
  /// the wire; see [HubClient.setThermostatTarget].
  Future<void> setThermostatTarget(String deviceId, double target) =>
      _hub.setThermostatTarget(deviceId, target);

  /// Tapping a Room acts on it: all lights on if none is lit, all off
  /// otherwise.
  Future<void> toggleRoomLights(Room room) async {
    final lit = isRoomLit(room);
    final lights =
        room.devices.where((d) => d.kind == DeviceKind.light).toList();
    // The Room id raw, and that is a stated decision rather than an oversight.
    // Measured: `D ui.room_lights room=rtsp://admin:hunter2@192.168.68.44/live`
    // — an id is hand-typed in house.yaml, so a URL can be one. It is accepted
    // on the same terms as `bindings_parser.dart`'s `_streamName` residual: an
    // id that reaches here **survived the load**, and a mis-paste never does
    // (`house_loader.dart` refuses it and withholds it from `house.invalid`),
    // so this needs the URL to have been typed as an id on purpose. The id is
    // also the entire content of the line — "which Room did somebody tap" has
    // no other spelling — and these are `D` lines, off in the release build
    // the appliance runs. Rejected: withholding the id, which costs every
    // honest line its meaning to contain a value that could not have got here
    // by accident. The same decision covers `ui.floor` and `ui.device` in
    // `dollhouse_view.dart`.
    Log.debug('ui', 'room_lights',
        {'room': room.id, 'was_lit': lit, 'lights': lights.length});
    for (final light in lights) {
      if (presentationOf(light).glows == lit) await _hub.toggle(light.id);
    }
  }

  @override
  void dispose() {
    _sub.cancel();
    _rings.close();
    _hub.status.removeListener(_onStatusChanged);
    _hub.dispose();
    super.dispose();
  }

  // ── The doorbell rule ──────────────────────────────────────────────────

  void _onDeviceChanged(String deviceId) {
    final doorbell = _doorbells[deviceId];
    if (doorbell != null) _readDoorbell(doorbell);
    notifyListeners();
  }

  void _onStatusChanged() {
    // The memory is cleared whenever the link leaves `up` — [_lastSeen] only;
    // [_rungFor] is not a belief and survives. That is what makes the
    // `binary_sensor` shape survivable: after an outage the Hub replays its
    // whole snapshot, so an `on` learned across the gap is a re-introduction,
    // not an edge — and a first sight of a word is silence. A replayed
    // *timestamp* is answered on its own age, and on whether this Panel has
    // already rung for that exact press, so a reconnect can neither invent a
    // ring nor repeat one.
    //
    // The deliberate cost is a press that lands inside the gap and reaches
    // the Panel only as a word with nothing before it: no evidence exists
    // anywhere that separates it from the snapshot restating an old `on`, so
    // it is lost and the next press rings. `doorbell.dart` rule 3 states the
    // whole of that argument. The alternative is firing on every reconnect,
    // and a wrong pop opens a real Ring session (#177014).
    if (_hub.status.value != HubStatus.up) _lastSeen.clear();
    notifyListeners();
  }

  void _readDoorbell(Device doorbell) {
    // Forgotten when the state goes away, not kept. `HaHubClient` removes the
    // entry entirely when the entity reports `unavailable`, and a memory that
    // outlives the value it describes turns the *next* good value into an
    // edge: `off` → unavailable → `on` then rings the house with nobody at
    // the door, over an integration reload or an MQTT blip that never drops
    // the Panel's own socket. The rejected argument, which used to sit here,
    // was that stickiness stops a recovery ringing — it is backwards.
    // Stickiness only helps when the value happens to come back *unchanged*;
    // forgotten, the value after the gap is a first sight, which for a word
    // is silence and for a timestamp is judged on its age and against
    // [_rungFor]. Forgetting is the safer direction for a *belief*; the press
    // this Panel already answered is a different kind of fact and is kept.
    //
    // The Hub only ever hands `StatusState` for a doorbell (it is
    // `StateFamily.status`); anything else is a shape this rule cannot read,
    // and is left to `hub.state_unusable` to complain about once. The memory
    // goes for that too, and for the same reason: the Panel no longer knows
    // what the entity says.
    final state = _hub.states[doorbell.id];
    if (state is! StatusState) {
      _lastSeen.remove(doorbell.id);
      return;
    }
    final previous = _lastSeen[doorbell.id];
    final next = state.status;
    final now = _now();
    final rungFor = _rungFor[doorbell.id];
    final verdict = classifyDing(
        previous: previous, next: next, now: now, rungFor: rungFor);
    // Remembered whatever the verdict, `unreadable` included: that is what
    // makes the warn line below one line per *entry* into an unreadable
    // string rather than one per message, exactly as `hub.state_unusable`
    // does it for the same reason — a permanently-odd entity must not fill
    // journald forever.
    _lastSeen[doorbell.id] = next;
    switch (verdict) {
      case Ding.pressed:
        // Recorded before the ring goes out, and only for a state that names
        // a press: `on` says nothing about *which* press it was, so there is
        // nothing to remember and nothing a later `on` could be compared to.
        final at = DateTime.tryParse(next);
        if (at != null) _rungFor[doorbell.id] = at;
        Log.info('ui', 'ding', {'device': doorbell.id, 'entity_state': next});
        _rings.add(doorbell);
      case Ding.unreadable:
        Log.warn('ui', 'ding_unreadable', {
          'device': doorbell.id,
          'state': next,
          'expected': 'on|off|<iso8601>',
        });
      case Ding.quiet:
        _explainSilence(doorbell,
            previous: previous, next: next, now: now, rungFor: rungFor);
    }
  }

  /// Why a report that reached the rule did not ring.
  ///
  /// The Popup that never opens is the failure mode with no symptom — the
  /// house is quiet either way — so silence is the case that most needs a
  /// line to grep for. Debug for the ordinary reasons, warn for the one that
  /// says the feature is dead.
  void _explainSilence(
    Device doorbell, {
    required String? previous,
    required String next,
    required DateTime now,
    required DateTime? rungFor,
  }) {
    // In the classifier's own order, so the reason named is the rule that
    // actually did the silencing. A line that says `first_sight` about a
    // press time the freshness window rejected would send whoever is holding
    // the log looking in the wrong place.
    if (previous == next) {
      Log.debug('ui', 'ding_suppressed',
          {'device': doorbell.id, 'reason': 'unchanged'});
      return;
    }
    final age = dingAge(next, now);
    if (age != null) {
      // The same press again, from an entity that dropped out and came back
      // saying what it said before. Debug, not warn: nothing is wrong, and
      // the line exists so that "the doorbell rang once for two reports" can
      // be read back rather than inferred. Before this branch the report
      // below claimed the clocks disagreed, which sent whoever was holding
      // the log to check NTP over a Panel behaving exactly right.
      if (rungFor != null && DateTime.parse(next).isAtSameMomentAs(rungFor)) {
        Log.debug('ui', 'ding_suppressed', {
          'device': doorbell.id,
          'reason': 'already_rung',
          'age_s': age.inSeconds,
        });
        return;
      }
      // A press time with nothing to compare it to is the snapshot handing
      // over a ding from before this Panel was watching — ordinary, so debug,
      // with the age so it can be told from a clock problem.
      if (previous == null) {
        Log.debug('ui', 'ding_suppressed',
            {'device': doorbell.id, 'reason': 'stale', 'age_s': age.inSeconds});
        return;
      }
      // A press time that *changed* and still did not ring means the clocks
      // disagree — the timestamp comes from Ring's cloud, not from the Hub
      // box. Without this line the whole feature dies with no symptom
      // whatsoever: every ding classifies `quiet` and the wall simply never
      // lights up. Precedent: `hub.temperature_unit_unknown`, which exists
      // for the same "the reading is honest but useless and nothing else
      // would say so".
      Log.warn(
          'ui', 'ding_stale', {'device': doorbell.id, 'age_s': age.inSeconds});
      return;
    }
    if (previous == null) {
      Log.debug('ui', 'ding_suppressed',
          {'device': doorbell.id, 'reason': 'first_sight'});
      return;
    }
    // Nothing to say about `off`: the doorbell going back to rest is exactly
    // as eventful as it sounds.
  }
}
