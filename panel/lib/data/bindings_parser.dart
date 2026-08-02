/// Reads `bindings.yaml` — the one hand-maintained half of the House Plan
/// (ADR-0005) — into validated data, with every complaint naming the file,
/// the culprit and the fix.
///
/// Shared on purpose. The Panel parses this at boot and the dev-Hub
/// generator reasons about the same bindings; two parsers over one
/// hand-edited file is how a rule ends up enforced in one place and not the
/// other. Pure Dart, no Flutter: the generator runs under plain `dart run`.
library;

import 'package:yaml/yaml.dart';

import '../domain/device_vocabulary.dart';

/// One binding: what the Hub calls this Device, and whether it needs a
/// vendor cloud. Position, Room, name and kind are not here — those are
/// drawn, and the converter owns them.
class ParsedBinding {
  const ParsedBinding({
    required this.key,
    required this.entityId,
    required this.connectivity,
  });

  /// The author-controlled Key, typed once in Sweet Home 3D. Free-form:
  /// any spelling or separator, unique across the house.
  final String key;

  /// Null while the hardware is still in a box — the Device renders with
  /// unknown state rather than being dropped.
  final String? entityId;

  final Connectivity connectivity;
}

/// Home Assistant's entity id shape: `domain.object_id`.
final _entityId = RegExp(r'^[a-z_]+\.[a-z0-9_]+$');

/// Parses and validates the whole file. Throws [FormatException] on the
/// first problem; the caller decides what to do with it.
Map<String, ParsedBinding> parseBindings(String yaml) {
  final doc = loadYaml(yaml);
  final out = <String, ParsedBinding>{};
  // One entity may back only one Device: two pins driving one entity would
  // toggle each other, and neither could be reasoned about from the wall.
  final seenEntities = <String, String>{};

  for (final entry in ((doc?['bindings'] as YamlMap?) ?? YamlMap()).entries) {
    final key = entry.key as String;
    final binding = entry.value;
    final entityId = binding == null ? null : binding['entity'] as String?;

    if (entityId != null) {
      if (!_entityId.hasMatch(entityId)) {
        throw FormatException(
            'bindings.yaml: "$key" has entity "$entityId", which is not a '
            'Home Assistant entity id (domain.object_id)');
      }
      final clash = seenEntities[entityId];
      if (clash != null) {
        throw FormatException(
            'bindings.yaml: "$clash" and "$key" both bind to entity '
            '"$entityId" — one entity, one Device.');
      }
      seenEntities[entityId] = key;
    }

    out[key] = ParsedBinding(
      key: key,
      entityId: entityId,
      // Deliberately no default: a planned Ring camera is a Cloud Device
      // before it is ever bound, so guessing `local` would mislabel it.
      connectivity:
          switch (binding == null ? null : binding['connectivity'] as String?) {
        'local' => Connectivity.local,
        'cloud' => Connectivity.cloud,
        final c => throw FormatException(
            'bindings.yaml: "$key" has connectivity "$c" (local | cloud)'),
      },
    );
  }
  return out;
}
