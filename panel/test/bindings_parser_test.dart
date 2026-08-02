import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/bindings_parser.dart';
import 'package:panel/domain/device_vocabulary.dart';

/// The hand-maintained file's rules, tested where they live rather than
/// only through the loader — the generator reads the same parser, and a
/// rule enforced in one caller and not the other is the failure this
/// module exists to prevent.
void main() {
  test('parses a binding with an entity', () {
    final bindings = parseBindings('''
bindings:
  light-den:
    entity: input_boolean.light_den
    connectivity: local
''');
    final binding = bindings['light-den']!;
    expect(binding.key, 'light-den');
    expect(binding.entityId, 'input_boolean.light_den');
    expect(binding.connectivity, Connectivity.local);
  });

  test('an entity-less binding is legal — hardware still in its box', () {
    final binding = parseBindings('''
bindings:
  future-camera:
    connectivity: cloud
''')['future-camera']!;
    expect(binding.entityId, isNull);
    expect(binding.connectivity, Connectivity.cloud);
  });

  test('an empty file parses to nothing rather than throwing', () {
    expect(parseBindings('bindings:\n'), isEmpty);
  });

  test('keys are free-form — any spelling the author likes', () {
    // Sweet Home 3D constrains nothing about the Key, so neither do we.
    final bindings = parseBindings('''
bindings:
  light_kitchen_1:
    connectivity: local
  Light-Kitchen-2:
    connectivity: local
''');
    expect(bindings.keys, containsAll(['light_kitchen_1', 'Light-Kitchen-2']));
  });

  test('rejects an entity id that is not domain.object_id', () {
    expect(
      () => parseBindings('''
bindings:
  light-den:
    entity: LightDen
    connectivity: local
'''),
      _rejects('not a Home Assistant entity id'),
    );
  });

  test('rejects two Devices bound to one entity', () {
    // Two pins driving one entity would toggle each other.
    expect(
      () => parseBindings('''
bindings:
  light-den:
    entity: input_boolean.light_den
    connectivity: local
  light-den-again:
    entity: input_boolean.light_den
    connectivity: local
'''),
      _rejects('one entity, one Device'),
    );
  });

  test('demands connectivity, and rejects anything else', () {
    for (final body in ['    connectivity: wifi', '', '    entity: a.b']) {
      expect(
        () => parseBindings('bindings:\n  light-den:\n$body\n'),
        _rejects('(local | cloud)'),
        reason: body.isEmpty ? 'omitted' : body,
      );
    }
  });

  test('every message names the file and the culprit', () {
    // These are read by whoever hand-edited the file, so they have to say
    // which key is wrong, not just that something is.
    try {
      parseBindings('bindings:\n  oven-thing:\n    connectivity: wired\n');
      fail('expected a FormatException');
    } on FormatException catch (e) {
      expect(e.message, contains('bindings.yaml'));
      expect(e.message, contains('oven-thing'));
      expect(e.message, contains('wired'));
    }
  });
}

Matcher _rejects(String culprit) => throwsA(isA<FormatException>()
    .having((e) => e.message, 'message', contains(culprit)));
