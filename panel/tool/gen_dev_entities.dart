// Generates the development Hub's stand-in fleet from the Panel's own
// devices.yaml, so every Device pin has a real Home Assistant entity behind
// it while the actual hardware is still in boxes.
//
//   dart run tool/gen_dev_entities.dart
//
// Writes a Home Assistant *package* (a self-contained slice of config) to
// ../hub/dev/ha-config/packages/. Restart the dev Hub to pick it up.
//
// The generated entities are helpers you can poke by hand in the HA UI —
// but the Panel binds to the domains production will actually use
// (`sensor.*` for readings, `climate.*` for the thermostat), so the
// HubClient learns the right mapping, not a helper-shaped one.
//
// Pure Dart on purpose (no dart:ui), so `dart run` works without Flutter.

import 'dart:io';

import 'package:yaml/yaml.dart';

const _defaultDevices = 'assets/house/devices.yaml';
const _defaultOut = '../hub/dev/ha-config/packages/panel_dev.yaml';

/// Kinds that are simply on or off (Panel: `SwitchState`/`GarageDoorState`).
const _toggleSeed = <String, bool>{
  'light': false,
  'outlet': true,
  'tv': false,
  'garage-door': false,
};

/// Kinds that report watts (Panel: `PowerState`).
const _powerSeed = <String, double>{
  'energy-monitor': 812,
  'ev-charger': 0,
};

/// Kinds that report free text (Panel: `StatusState`). Seeds match FakeHub
/// so the dev Hub looks like the fake one you have been developing against.
const _statusSeed = <String, String>{
  'washer': 'Idle',
  'dryer': 'Cycle · 32 min left',
  'oven': 'Off',
  'litter-robot': 'Clean · cycled 2 h ago',
  'feeder': 'Next meal 5:00 pm',
  'camera': 'Live',
  'doorbell': 'Live',
};

/// The one kind that becomes a real `climate` entity.
const _thermostatKind = 'thermostat';
const _thermostatCurrentC = 21.4;
const _thermostatTargetC = 21.0;

void main(List<String> args) {
  var devicesPath = _defaultDevices;
  var outPath = _defaultOut;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '-o' || '--out':
        outPath = args[++i];
      case '--devices':
        devicesPath = args[++i];
      case '-h' || '--help':
        stdout.writeln('usage: dart run tool/gen_dev_entities.dart '
            '[--devices $_defaultDevices] [-o $_defaultOut]');
        return;
      default:
        _fail('unknown argument "${args[i]}"');
    }
  }

  final source = File(devicesPath);
  if (!source.existsSync()) {
    _fail('$devicesPath not found — run this from the panel/ directory');
  }
  final devices = _readDevices(source);

  final booleans = <String>[];
  final numbers = <String>[];
  final texts = <String>[];
  final sensors = <String>[];
  final climates = <String>[];
  // device id -> the entity the Panel should bind to.
  final binding = <String, String>{};
  final slugs = <String, String>{};

  for (final device in devices) {
    final id = device.id;
    final obj = id.replaceAll('-', '_');
    final slug = _slugify(device.name);
    final clash = slugs[slug];
    if (clash != null) {
      _fail('devices "$clash" and "${device.id}" share the name '
          '"${device.name}" — Home Assistant would derive one entity id for '
          'both. Rename one in $devicesPath.');
    }
    slugs[slug] = id;

    if (_toggleSeed.containsKey(device.kind)) {
      booleans.add('  $obj:\n'
          '    name: ${_q(device.name)}\n'
          '    initial: ${_toggleSeed[device.kind]}');
      binding[id] = 'input_boolean.$obj';
    } else if (_powerSeed.containsKey(device.kind)) {
      numbers.add('  ${obj}_watts:\n'
          '    name: ${_q('${device.name} — watts')}\n'
          '    initial: ${_powerSeed[device.kind]}\n'
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
      binding[id] = 'sensor.$slug';
    } else if (_statusSeed.containsKey(device.kind)) {
      texts.add('  ${obj}_status:\n'
          '    name: ${_q('${device.name} — status')}\n'
          '    initial: ${_q(_statusSeed[device.kind]!)}\n'
          '    max: 255');
      sensors.add('      - name: ${_q(device.name)}\n'
          '        unique_id: dev_$obj\n'
          '        state: "{{ states(\'input_text.${obj}_status\') }}"');
      binding[id] = 'sensor.$slug';
    } else if (device.kind == _thermostatKind) {
      // A real climate entity, built the only way that needs no hardware:
      // generic_thermostat over a helper "room temperature" sensor and a
      // dummy heater switch. It reports current_temperature + temperature
      // exactly as the Ecobee will.
      numbers.add('  ${obj}_current:\n'
          '    name: ${_q('${device.name} — measured °C')}\n'
          '    initial: $_thermostatCurrentC\n'
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
          '    target_sensor: sensor.${_slugify(currentName)}\n'
          '    min_temp: 10\n'
          '    max_temp: 30\n'
          // Without this, generic_thermostat rounds current_temperature to
          // whole degrees and the Panel shows 21° for a 21.4° room.
          '    precision: 0.1\n'
          '    target_temp_step: 0.5\n'
          '    target_temp: $_thermostatTargetC');
      binding[id] = 'climate.$slug';
    } else {
      _fail('device "$id" has kind "${device.kind}", which this generator '
          'does not know. Add it to one of the seed maps in '
          'tool/gen_dev_entities.dart.');
    }
  }

  final out = StringBuffer()
    ..writeln('# GENERATED by panel/tool/gen_dev_entities.dart — do not edit.')
    ..writeln('# Source: panel/$devicesPath. Regenerate after changing it:')
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

  final target = File(outPath)..parent.createSync(recursive: true);
  target.writeAsStringSync(out.toString());
  stdout.writeln('wrote $outPath: ${devices.length} device(s) -> '
      '${booleans.length} input_boolean, ${numbers.length} input_number, '
      '${texts.length} input_text, ${sensors.length} template sensor(s), '
      '${climates.length} climate');
  stdout.writeln('restart the dev Hub to load it: '
      'cd ../hub/dev && docker compose restart');
}

void _section(StringBuffer out, String key, List<String> entries) {
  if (entries.isEmpty) return;
  out
    ..writeln()
    ..writeln('$key:')
    ..writeln(entries.join('\n'));
}

class _Device {
  _Device(this.id, this.name, this.kind);
  final String id;
  final String name;
  final String kind;
}

List<_Device> _readDevices(File source) {
  final doc = loadYaml(source.readAsStringSync());
  final list = doc is YamlMap ? doc['devices'] : null;
  if (list is! YamlList) _fail('${source.path}: no top-level "devices:" list');
  return [
    for (final entry in list)
      if (entry is! YamlMap)
        _fail('${source.path}: device entries must be maps')
      else
        _Device(
          _require(entry, 'id', source.path),
          _require(entry, 'name', source.path),
          _require(entry, 'kind', source.path),
        ),
  ];
}

String _require(YamlMap entry, String key, String path) {
  final value = entry[key];
  if (value is! String || value.isEmpty) {
    _fail('$path: device ${entry['id'] ?? entry} is missing "$key"');
  }
  return value;
}

/// Home Assistant's own entity-id rule: lowercase, runs of anything else
/// collapse to a single underscore.
String _slugify(String name) => name
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
    .replaceAll(RegExp(r'^_+|_+$'), '');

String _q(String value) =>
    '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

Never _fail(String message) {
  stderr.writeln('error: $message');
  exit(1);
}
