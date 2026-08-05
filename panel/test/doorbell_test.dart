import 'package:flutter_test/flutter_test.dart';
import 'package:panel/domain/doorbell.dart';

/// The doorbell rule, with nothing else in the room: no Hub, no clock, no
/// widget tree. Every case here is a false-fire that would have opened a
/// real Ring cloud session for a visitor who does not exist — which HA
/// #177014 says can then suppress a real ding — or a real press the Panel
/// would have slept through.
void main() {
  final now = DateTime.utc(2026, 8, 4, 19, 30);

  /// The `event.*_ding` shape: the state *is* the press time.
  String pressedAt(Duration ago) => now.subtract(ago).toIso8601String();

  test('first sight of a *word* is not a press: the snapshot states what the '
      'entity already said and `on` carries no clock', () {
    // A Panel that restarts at midnight and finds `on` waiting for it has
    // found a ding from hours ago, not a visitor, and nothing in the string
    // could tell the two apart. `Live` is FakeHub's doorbell seed: quiet on
    // first sight rather than an `unreadable` warn on every dev boot.
    expect(classifyDing(previous: null, next: 'on', now: now), Ding.quiet);
    expect(classifyDing(previous: null, next: 'Live', now: now), Ding.quiet);
  });

  test('first sight of a fresh press time rings: an integration that loads '
      'after the Panel must not cost a real press', () {
    // The regression the rule order prevents. After an HA restart the Ring
    // integration can take a minute to come up, so the Panel's very first
    // sight of the entity is the press itself. A word has to be guessed at,
    // and is guessed quiet; a timestamp says when, so it is answered.
    expect(
        classifyDing(
            previous: null,
            next: pressedAt(const Duration(seconds: 2)),
            now: now),
        Ding.pressed);
    // The window does the whole job the first-sight veto was doing: an old
    // press time on first sight is still the snapshot handing over a ding
    // that is over.
    expect(
        classifyDing(
            previous: null,
            next: pressedAt(const Duration(minutes: 10)),
            now: now),
        Ding.quiet);
  });

  test('the same value reported twice is one press, not two', () {
    // The rule the whole classifier is built around: `_applyEntity` emits a
    // change for every usable message with no equality check, and a
    // reconnect replays the entire snapshot. It is checked before the
    // timestamp rule, or a replayed press time from five seconds ago would
    // ring the house a second time for the same visitor.
    expect(classifyDing(previous: 'on', next: 'on', now: now), Ding.quiet);
    final at = pressedAt(const Duration(seconds: 5));
    expect(classifyDing(previous: at, next: at, now: now), Ding.quiet);
  });

  test('a press this Panel has already rung for is the same press, however '
      'many times the entity re-reports it', () {
    // Rule 1 catches a replay while the Panel still believes the old value.
    // This is the replay that arrives *after* that belief was dropped — an
    // entity round-tripping through `unavailable` over an integration reload
    // re-states the identical press time, `previous` is null, and the age
    // still says five seconds ago. Ringing again is two Ring sessions for one
    // press, and #177014 says the second suppresses the next real ding.
    final at = pressedAt(const Duration(seconds: 5));
    final rung = DateTime.parse(at);
    expect(classifyDing(previous: null, next: at, now: now, rungFor: rung),
        Ding.quiet);
    // And the *next* press still rings, which is what stops this being a
    // doorbell that answers once and then never again.
    expect(
        classifyDing(
            previous: null,
            next: pressedAt(const Duration(seconds: 1)),
            now: now,
            rungFor: rung),
        Ding.pressed);
  });

  test('a press time that goes backwards still rings: a cloud clock stepping '
      'back must not be able to deafen the doorbell', () {
    // Identity, not "at or before". Suppressing everything up to the last
    // press answered would look tidier and would silence every press after a
    // backwards step, with no symptom anywhere — duplicates are bounded,
    // deafness is not.
    final rung = DateTime.parse(pressedAt(const Duration(seconds: 5)));
    expect(
        classifyDing(
            previous: 'off',
            next: pressedAt(const Duration(seconds: 20)),
            now: now,
            rungFor: rung),
        Ding.pressed);
  });

  test('a fresh timestamp is a press; a ten-minute-old one is a ding that is '
      'over', () {
    expect(
        classifyDing(
            previous: pressedAt(const Duration(hours: 3)),
            next: pressedAt(const Duration(seconds: 5)),
            now: now),
        Ding.pressed);
    expect(
        classifyDing(
            previous: 'off',
            next: pressedAt(const Duration(minutes: 10)),
            now: now),
        Ding.quiet);
  });

  test('a clock a little behind Ring\'s still answers the door', () {
    // The timestamp comes from Ring's cloud, so the appliance clock trailing
    // it by a second is ordinary; refusing a press stamped in the near
    // future would be a doorbell that works until NTP wobbles.
    expect(
        classifyDing(
            previous: 'off',
            next: now.add(const Duration(seconds: 2)).toIso8601String(),
            now: now),
        Ding.pressed);
    // Skew large enough to be skew rather than jitter is not a visitor.
    expect(
        classifyDing(
            previous: 'off',
            next: now.add(const Duration(hours: 2)).toIso8601String(),
            now: now),
        Ding.quiet);
  });

  test('off to on is a press; on to off is not', () {
    expect(classifyDing(previous: 'off', next: 'on', now: now), Ding.pressed);
    expect(classifyDing(previous: 'on', next: 'off', now: now), Ding.quiet);
  });

  test('a state neither shape can read pops nothing and names the string it '
      'could not read', () {
    // Neither `on`/`off` nor a timestamp. An honest unknown beats a
    // confident wrong answer: the caller warns with the string itself, so
    // whoever wired the entity can see what it actually says.
    expect(classifyDing(previous: 'off', next: 'ringing', now: now),
        Ding.unreadable);
    expect(classifyDing(previous: 'off', next: '', now: now), Ding.unreadable);
    // Not a date: a bare number would be a plausible thing to mistake for
    // one, and `pressed` on a fat-fingered state is the pop nobody asked
    // for.
    expect(classifyDing(previous: 'off', next: '007', now: now),
        Ding.unreadable);
  });

  test('freshness is the caller\'s to widen, and it bounds the answer both '
      'ways', () {
    final tenMinutes = pressedAt(const Duration(minutes: 10));
    expect(
        classifyDing(
            previous: 'off',
            next: tenMinutes,
            now: now,
            freshness: const Duration(minutes: 15)),
        Ding.pressed);
  });
}
