import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

/// Every `entity:` in `bindings.yaml` must name something the dev Hub
/// actually serves — a hermetic check for a failure that is otherwise
/// completely silent.
///
/// The hazard is real and one-directional: `gen_dev_entities.dart` derives
/// stand-in entity ids from each Device's *name*, so renaming "Reading
/// Lamp" to "Reading Light" in the drawing regenerates
/// `input_boolean.reading_light` while `bindings.yaml` still points at
/// `input_boolean.reading_lamp`. Nothing throws. The Panel boots, the pin
/// renders with unknown state forever, and the only evidence is one
/// `hub.missing_entities` line in a log nobody is reading — on a wall
/// display with nobody standing in front of it (ADR-0001).
///
/// [_integrated] is the ledger of Devices whose bindings have moved to real
/// hardware and are therefore *expected* not to resolve against the dev
/// Hub. Adding a Device to it is the deliberate act of saying "this one is
/// real now".
const _integrated = <String>{
  // Phase 2, 2026-08-04 — real hardware on the laptop Hub.
  'outlet-outdoor-a', // Kasa EP40 outdoor socket A -> switch.outdoor_outlet_a
  'outlet-outdoor-b', // Kasa EP40 outdoor socket B -> switch.outdoor_outlet_b
  'thermostat', // ecobee "Main Floor" -> climate.main_floor (HomeKit, local)
  // 2026-08-05 — two Kasa HS103s repurposed from a fridge and an aquarium to
  // house lights, which is what made them bindable at all (Ch. 4 §4.1.1,
  // ADR-0006). The Key names are placeholder-house fictions: the entry light
  // is NOT in the living room and the stairs light is NOT on the landing.
  // `light-hall` would have been right for the entry and is deliberately not
  // used — it is this suite's own togglable fixture; see bindings.yaml.
  'light-living', // -> switch.entry_light  (was switch.old_fridge)
  'light-landing', // -> switch.stairs_light (was switch.aquarium)
  // 2026-08-05 — ring-mqtt authenticated; the doorbell is real hardware now.
  'doorbell', // -> binary_sensor.front_door_ding (+ stream: ring_doorbell)
};

void main() {
  test('every binding resolves against the dev Hub stand-ins', () {
    final bindings =
        loadYaml(File('assets/house/bindings.yaml').readAsStringSync())
            as YamlMap;
    final standIns = _entityIds(
        File('../hub/dev/ha-config/packages/panel_dev.yaml')
            .readAsStringSync());

    expect(standIns, isNotEmpty, reason: 'dev Hub package looks empty');

    final unresolved = <String, String>{};
    for (final entry in (bindings['bindings'] as YamlMap).entries) {
      final key = entry.key as String;
      final entity = entry.value?['entity'] as String?;
      if (entity == null || _integrated.contains(key)) continue;
      if (!standIns.contains(entity)) unresolved[key] = entity;
    }

    expect(unresolved, isEmpty,
        reason: 'binding(s) point at entities the dev Hub does not serve — '
            'renamed a Device in the drawing without re-running '
            'tool/gen_dev_entities.dart and updating bindings.yaml? Or move '
            'the key into _integrated if it now binds real hardware.');
  });

  test('every Placement has exactly one binding', () {
    // The loader enforces this at boot, but only for the House Plan it is
    // handed. Asserting it here means a mismatch fails in `flutter test`
    // rather than on the wall.
    final house =
        loadYaml(File('assets/house/house.yaml').readAsStringSync()) as YamlMap;
    final bindings =
        loadYaml(File('assets/house/bindings.yaml').readAsStringSync())
            as YamlMap;

    final keys = [
      for (final p in house['devices'] as YamlList) p['key'] as String
    ];
    final bound = (bindings['bindings'] as YamlMap).keys.cast<String>().toSet();

    expect(keys.toSet(), hasLength(keys.length), reason: 'duplicate Key');
    expect(keys.toSet().difference(bound), isEmpty,
        reason: 'Placement(s) with no bindings.yaml entry');
    expect(bound.difference(keys.toSet()), isEmpty,
        reason: 'binding(s) whose marker is gone from the drawing');
  });
}

/// The entity ids a Home Assistant package declares. Helper domains key
/// their entities by object id under `input_boolean:` and friends;
/// `template:` sensors and `climate:` declare a name instead, which the
/// generator slugifies the same way Home Assistant does.
Set<String> _entityIds(String packageYaml) {
  final doc = loadYaml(packageYaml) as YamlMap;
  final out = <String>{};
  for (final domain in ['input_boolean', 'input_number', 'input_text']) {
    final block = doc[domain];
    if (block is YamlMap) {
      out.addAll(block.keys.map((k) => '$domain.$k'));
    }
  }
  for (final block in (doc['template'] as YamlList?) ?? YamlList()) {
    for (final sensor in (block['sensor'] as YamlList?) ?? YamlList()) {
      out.add('sensor.${_slugify(sensor['name'] as String)}');
    }
  }
  for (final entry in (doc['climate'] as YamlList?) ?? YamlList()) {
    out.add('climate.${_slugify(entry['name'] as String)}');
  }
  return out;
}

/// Home Assistant's own entity-id rule, mirroring the generator's.
String _slugify(String name) => name
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
    .replaceAll(RegExp(r'^_+|_+$'), '');
