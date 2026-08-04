/// The dev-Hub stand-in generator's pure core: House Plan text in, package
/// text out. No files, no argv, no exits — so the thing worth testing is
/// reachable from a test, and the seeds come from the same table FakeHub
/// reads instead of a third hand-typed copy.
///
/// Pure Dart, no Flutter, so `dart run` works without the SDK's UI half.
library;

import 'package:yaml/yaml.dart';

import 'package:panel/domain/device_state.dart';
import 'package:panel/domain/device_vocabulary.dart';

/// A Device as the House Plan describes it — the three fields the dev Hub
/// needs to invent a stand-in for it.
class DevDevice {
  const DevDevice(this.key, this.name, this.kind);
  final String key;
  final String name;
  final DeviceKind kind;
}

/// The generated package plus the two things a caller wants to know about
/// it: which entity each Key should bind to, and what was produced.
class DevPackage {
  const DevPackage({
    required this.text,
    required this.binding,
    required this.counts,
  });

  /// The Home Assistant package YAML.
  final String text;

  /// Key -> the entity id the Panel should bind to. This is what gets
  /// hand-copied into `bindings.yaml`, and what `bindings_drift_test.dart`
  /// checks has not silently moved.
  final Map<String, String> binding;

  /// domain -> how many entities of it were emitted; for the CLI summary.
  final Map<String, int> counts;
}

/// Reads the Placements out of a generated `house.yaml`.
List<DevDevice> readPlacements(String houseYaml, {String source = 'house.yaml'}) {
  final doc = loadYaml(houseYaml);
  final list = doc is YamlMap ? doc['devices'] : null;
  if (list is! YamlList) {
    throw FormatException('$source: no top-level "devices:" list — regenerate '
        'it with tool/sh3d_to_yaml.py from a drawing that has Device markers');
  }
  return [
    for (final entry in list)
      if (entry is! YamlMap)
        throw FormatException('$source: device entries must be maps')
      else
        DevDevice(
          _require(entry, 'key', source),
          _require(entry, 'name', source),
          kindFromSlug(_require(entry, 'kind', source)) ??
              (throw FormatException(
                  '$source: device ${entry['key']} has unknown kind '
                  '"${entry['kind']}" (one of: ${deviceKindSlugs.join(", ")})')),
        ),
  ];
}

String _require(YamlMap entry, String key, String source) {
  final value = entry[key];
  if (value is! String || value.isEmpty) {
    throw FormatException(
        '$source: device ${entry['key'] ?? entry} is missing "$key"');
  }
  return value;
}

/// Builds the package. [sourceLabel] only appears in the header comment.
DevPackage generateDevPackage(
  List<DevDevice> devices, {
  required String sourceLabel,
}) {
  final booleans = <String>[];
  final numbers = <String>[];
  final texts = <String>[];
  final sensors = <String>[];
  final climates = <String>[];
  final binding = <String, String>{};
  final slugs = <String, String>{};

  for (final device in devices) {
    final key = device.key;
    final obj = key.replaceAll('-', '_');
    final slug = slugifyEntity(device.name);
    final clash = slugs[slug];
    if (clash != null) {
      throw FormatException(
          'devices "$clash" and "$key" share the name "${device.name}" — '
          'Home Assistant would derive one entity id for both. Rename one in '
          'the drawing.');
    }
    slugs[slug] = key;

    // The seed comes from the Device vocabulary, so the dev Hub starts in
    // exactly the state FakeHub would have shown. Switching on the seed's
    // shape rather than the kind is what keeps this loop five arms wide
    // however many kinds exist.
    final seed = specOf(device.kind).seed(key);
    switch (seed) {
      case SwitchState(:final on):
        booleans.add('  $obj:\n'
            '    name: ${_q(device.name)}\n'
            '    initial: $on');
        binding[key] = 'input_boolean.$obj';
      case GarageDoorState(:final open):
        booleans.add('  $obj:\n'
            '    name: ${_q(device.name)}\n'
            '    initial: $open');
        binding[key] = 'input_boolean.$obj';
      case PowerState(:final watts):
        numbers.add('  ${obj}_watts:\n'
            '    name: ${_q('${device.name} — watts')}\n'
            '    initial: $watts\n'
            '    min: 0\n'
            '    max: 20000\n'
            '    step: 1\n'
            '    unit_of_measurement: W\n'
            '    mode: box');
        sensors.add('      - name: ${_q(device.name)}\n'
            '        unique_id: dev_$obj\n'
            '        unit_of_measurement: W\n'
            '        device_class: power\n'
            '        state_class: measurement\n'
            '        state: '
            '"{{ states(\'input_number.${obj}_watts\') | float(0) }}"');
        binding[key] = 'sensor.$slug';
      case StatusState(:final status):
        texts.add('  ${obj}_status:\n'
            '    name: ${_q('${device.name} — status')}\n'
            '    initial: ${_q(status)}\n'
            '    max: 255');
        sensors.add('      - name: ${_q(device.name)}\n'
            '        unique_id: dev_$obj\n'
            '        state: "{{ states(\'input_text.${obj}_status\') }}"');
        binding[key] = 'sensor.$slug';
      case ThermostatState(:final current, :final target):
        // A real climate entity, built the only way that needs no hardware:
        // generic_thermostat over a helper "room temperature" sensor and a
        // dummy heater switch. It reports current_temperature + temperature
        // exactly as the Ecobee will.
        numbers.add('  ${obj}_current:\n'
            '    name: ${_q('${device.name} — measured °C')}\n'
            '    initial: $current\n'
            '    min: 0\n'
            '    max: 40\n'
            '    step: 0.1\n'
            '    unit_of_measurement: "°C"\n'
            '    mode: box');
        booleans.add('  ${obj}_call_for_heat:\n'
            '    name: ${_q('${device.name} — calling for heat')}\n'
            '    initial: false');
        final currentName = '${device.name} measured';
        sensors.add('      - name: ${_q(currentName)}\n'
            '        unique_id: dev_${obj}_current\n'
            '        unit_of_measurement: "°C"\n'
            '        device_class: temperature\n'
            '        state_class: measurement\n'
            '        state: '
            '"{{ states(\'input_number.${obj}_current\') | float(0) }}"');
        climates.add('  - platform: generic_thermostat\n'
            '    name: ${_q(device.name)}\n'
            '    unique_id: dev_$obj\n'
            '    heater: input_boolean.${obj}_call_for_heat\n'
            '    target_sensor: sensor.${slugifyEntity(currentName)}\n'
            '    min_temp: 10\n'
            '    max_temp: 30\n'
            // Without this, generic_thermostat rounds current_temperature to
            // whole degrees and the Panel shows 21° for a 21.4° room.
            '    precision: 0.1\n'
            '    target_temp_step: 0.5\n'
            '    target_temp: $target');
        binding[key] = 'climate.$slug';
    }
  }

  final out = StringBuffer()
    ..writeln('# GENERATED by panel/tool/gen_dev_entities.dart — do not edit.')
    ..writeln('# Source: $sourceLabel. Regenerate after changing it:')
    ..writeln('#   cd panel && dart run tool/gen_dev_entities.dart')
    ..writeln('#')
    ..writeln('# Stand-in entities for the development Hub only. The real')
    ..writeln('# fleet arrives through Zigbee2MQTT/HomeKit/cloud integrations')
    ..writeln('# on the appliance; nothing here ships to it.')
    ..writeln('#')
    ..writeln('# Device -> entity the Panel binds to:');
  for (final entry in binding.entries) {
    out.writeln('#   ${entry.key.padRight(16)} ${entry.value}');
  }
  _section(out, 'input_boolean', booleans);
  _section(out, 'input_number', numbers);
  _section(out, 'input_text', texts);
  if (sensors.isNotEmpty) {
    out
      ..writeln()
      ..writeln('template:')
      ..writeln('  - sensor:')
      ..writeln(sensors.join('\n'));
  }
  _section(out, 'climate', climates);

  return DevPackage(text: out.toString(), binding: binding, counts: {
    'input_boolean': booleans.length,
    'input_number': numbers.length,
    'input_text': texts.length,
    'template sensor': sensors.length,
    'climate': climates.length,
  });
}

void _section(StringBuffer out, String key, List<String> entries) {
  if (entries.isEmpty) return;
  out
    ..writeln()
    ..writeln('$key:')
    ..writeln(entries.join('\n'));
}

/// Home Assistant's own entity-id rule: lowercase, runs of anything else
/// collapse to a single underscore.
String slugifyEntity(String name) => name
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
    .replaceAll(RegExp(r'^_+|_+$'), '');

String _q(String s) => '"${s.replaceAll('"', r'\"')}"';
