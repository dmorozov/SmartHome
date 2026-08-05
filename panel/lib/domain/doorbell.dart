/// What a doorbell's newly-reported state means.
///
/// Three values, not a bool. "I cannot read this string" is a different fact
/// from "nobody is at the door", and only one of the two deserves a warn
/// line and a human: a Panel that has been silently blind since somebody
/// swapped the integration out would otherwise be indistinguishable from a
/// quiet house, and both look like a feature that works.
enum Ding {
  /// Somebody pressed it, recently enough to be worth interrupting the wall
  /// for. The only answer that opens a Popup.
  pressed,

  /// Nothing happened — or nothing recent enough, or nothing new enough, to
  /// be an event.
  quiet,

  /// Neither shape this Panel knows. Pop nothing, and name the string in the
  /// log so whoever wired the entity can see what it actually says.
  unreadable,
}

/// Reads one doorbell state report: [previous] is the value this Panel
/// currently believes the Device holds, [next] is what the Hub has just
/// said. [previous] is null when the Panel has no current belief at all —
/// the entity has never reported, or its last report has since gone away.
/// [rungFor] is the press time this Panel has already rung for, if any; it
/// outlives [previous] on purpose, and rule 2a says why.
///
/// Pure, with [now] injected, because the rule *is* the feature: a rule that
/// can only be exercised by standing beside a real Ring doorbell for a
/// minute is a rule nobody runs (ADR-0007's argument about recovery
/// guarantees, applied to a classifier). The memory belongs to the caller
/// for the same reason it is not a field here — "forgotten when the entity
/// drops out of `states`" and "cleared when the link drops" are facts about
/// the *Hub link*, not about a string, and they live in [HubController]
/// where the link is.
///
/// Rejected: "the doorbell's `stateChanges` fired". `HaHubClient._applyEntity`
/// emits a change for **every** usable message, with no equality check, and a
/// reconnect replays the whole snapshot — so "fired" means "the router
/// rebooted" as often as it means "someone is at the door". That matters more
/// than a spurious rectangle: a wrong pop opens a real Ring cloud session,
/// and HA issue #177014 says a live session can then suppress a real ding.
/// The Panel would jam the doorbell it exists to answer.
Ding classifyDing({
  required String? previous,
  required String next,
  required DateTime now,
  DateTime? rungFor,
  Duration freshness = const Duration(seconds: 60),
}) {
  // 1. An unchanged value is not an event. This is the rule the whole
  // classifier is built around: see the `_applyEntity` note above. Without
  // it every reconnect rings the house. First, and before the timestamp
  // rule below: a reconnect that replays a press time from ten seconds ago
  // must not ring for it a second time.
  if (next == previous) return Ding.quiet;
  // 2. The `event.<name>_ding` shape, where the state *is* the press time.
  // A timestamp that parses is unambiguous — no other doorbell state looks
  // like one — so it is checked before the on/off words. It is also checked
  // before the first-sight rule, which is the ordering that matters:
  // first sight exists to *guess* whether a value is old, and a timestamp
  // does not need guessing, it says so, and [freshness] is exactly the
  // judgement rule 3 was invented to fake. Rejected: first sight vetoing
  // everything, which cost a genuine press for however long the Ring
  // integration took to load after an HA restart, with a debug
  // `ding_suppressed reason=first_sight` as the only trace.
  final at = DateTime.tryParse(next);
  if (at != null) {
    // 2a. A press time is an identity, not only an age. Rule 1 catches a
    // replay while the Panel still believes the old value; nothing caught one
    // that arrived after that belief was dropped — an entity round-tripping
    // through `unavailable` re-reporting the *same* press then rang a second
    // time inside [freshness], and #177014 says the second Ring session can
    // suppress the next real ding. So the press this Panel has already rung
    // for is remembered separately, and outlives both the belief and the Hub
    // link. Safe to keep where [previous] is not, and this is the whole
    // argument: [rungFor] can only ever turn a `pressed` into a `quiet`, so
    // no staleness in it can invent a ring — which is exactly what a stale
    // [previous] did.
    //
    // Identity, not "at or before": a press time that went *backwards* is a
    // clock or a replay, and treating it as already answered would let a Ring
    // cloud clock stepping back suppress every real press after it, with no
    // symptom anywhere. Duplicates are bounded; deafness is not.
    if (rungFor != null && at.isAtSameMomentAs(rungFor)) return Ding.quiet;
    // 2b. And otherwise on its age: a press stamped inside [freshness] is
    // somebody at the door now, whether or not this Panel was watching when
    // it happened.
    return now.difference(at).abs() <= freshness ? Ding.pressed : Ding.quiet;
  }
  // 3. First sight of a *word* is never a press. `on` carries no time, so
  // the Hub's snapshot states what the entity already said with no way to
  // tell an `on` from hours ago from one a second old — and on a dev boot
  // it states FakeHub's `Live` seed, which would otherwise warn
  // `unreadable` every single time somebody runs the app.
  //
  // Known cost, stated because it is real and not because it is fixable: a
  // press that is the first thing the Panel hears about a doorbell — after a
  // reconnect whose snapshot reported the entity `unavailable`, so nothing
  // survived the gap — is lost, and only the next one rings. Rule 2a bought
  // the timestamp shape out of this; the word shape cannot be bought out,
  // because the two strings are *identical*. `on` restored from before the
  // gap and `on` from a finger on the button one second ago differ in
  // nothing this function is given, or that exists anywhere on the wire. The
  // honest answer to a question with no evidence in it is silence, and the
  // alternative — ringing on first sight — rings the house on every HA
  // restart, which #177014 turns into a doorbell that then misses the real
  // press. Whoever wants that press wants the `event.<name>_ding` entity,
  // which carries the one fact that would settle it.
  if (previous == null) return Ding.quiet;
  // 4. The `binary_sensor.<name>_ding` shape. Exact strings: Home Assistant
  // writes these states lower-case, and a case-insensitive match here would
  // quietly accept a `Ringing` that this Panel should be complaining about.
  return switch (next) {
    'on' => Ding.pressed,
    'off' => Ding.quiet,
    _ => Ding.unreadable,
  };
}

/// How long ago [state] says the press happened, or null when [state] is not
/// a timestamp at all (`on`, `off`, or something unreadable).
///
/// Signed, and deliberately not clamped at zero: the timestamp originates in
/// Ring's cloud, not on the Hub box, so ADR-0008's one-box property does not
/// make skew zero, and a negative age is the only way the log can say the
/// appliance clock is *behind*. [classifyDing] compares the same quantity by
/// magnitude, for that reason — rejected: `age >= Duration.zero && age <=
/// freshness`, which would let a Hub clock a single second behind Ring's
/// suppress every real press, with no symptom anywhere.
///
/// Kept separate from rule 2 rather than shared with it: that rule needs the
/// instant itself, to tell one press from another, and this needs the age, to
/// say in a log line how old the thing it declined was.
Duration? dingAge(String state, DateTime now) {
  final at = DateTime.tryParse(state);
  return at == null ? null : now.difference(at);
}
