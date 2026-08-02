import 'device_vocabulary.dart';

/// Kind-keyed Device affordances, declared once for the whole Panel.
///
/// The declaration itself now lives in the Device vocabulary table, keyed
/// by state family — this is the kind-shaped view of it that callers had
/// already been written against. Keeping the spelling means the views, both
/// Hub adapters and `HubClient.togglable` did not have to change when the
/// table absorbed the rule.
extension DeviceKindTraits on DeviceKind {
  /// Mirrors HubClient.toggle's contract: light, outlet, TV and garage door
  /// toggle; every other kind is observe-only from a tap.
  ///
  /// Derived from the state family rather than re-listed, so a new kind
  /// declares its togglability by declaring what shape of state it
  /// reports — one decision, not two that can disagree.
  bool get toggles => specOf(this).family.togglable;
}
