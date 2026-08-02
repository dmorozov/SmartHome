// Generates the development Hub's stand-in fleet from the Panel's own
// House Plan, so every Device pin has a real Home Assistant entity behind
// it while the actual hardware is still in boxes.
//
//   dart run tool/gen_dev_entities.dart
//
// Writes a Home Assistant *package* (a self-contained slice of config) to
// ../hub/dev/ha-config/packages/. Restart the dev Hub to pick it up.
//
// The source is house.yaml's `devices:` section — the Placements read out
// of the Sweet Home 3D drawing (ADR-0005). The bindings it derives are
// hand-copied into bindings.yaml, and bindings_drift_test.dart is what
// keeps the two honest.
//
// The generated entities are helpers you can poke by hand in the HA UI —
// but the Panel binds to the domains production will actually use
// (`sensor.*` for readings, `climate.*` for the thermostat), so the
// HubClient learns the right mapping, not a helper-shaped one.
//
// This file is the adapter: argv in, files and exit codes out. Everything
// worth testing lives in dev_entities_core.dart, and its seeds come from
// the Device vocabulary — the same table FakeHub reads.
//
// Pure Dart on purpose (no dart:ui), so `dart run` works without Flutter.

import 'dart:io';

import 'dev_entities_core.dart';

const _defaultHouse = 'assets/house/house.yaml';
const _defaultOut = '../hub/dev/ha-config/packages/panel_dev.yaml';

void main(List<String> args) {
  var housePath = _defaultHouse;
  var outPath = _defaultOut;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '-o' || '--out':
        outPath = args[++i];
      case '--house' || '--devices':
        housePath = args[++i];
      case '-h' || '--help':
        stdout.writeln('usage: dart run tool/gen_dev_entities.dart '
            '[--house $_defaultHouse] [-o $_defaultOut]');
        return;
      default:
        _fail('unknown argument "${args[i]}"');
    }
  }

  final source = File(housePath);
  if (!source.existsSync()) {
    _fail('$housePath not found — run this from the panel/ directory');
  }

  final DevPackage package;
  final int count;
  try {
    final devices =
        readPlacements(source.readAsStringSync(), source: housePath);
    count = devices.length;
    package = generateDevPackage(devices, sourceLabel: 'panel/$housePath');
  } on FormatException catch (e) {
    _fail(e.message);
  }

  File(outPath)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(package.text);
  stdout.writeln('wrote $outPath: $count device(s) -> '
      '${package.counts.entries.map((e) => '${e.value} ${e.key}').join(', ')}');
  stdout.writeln('restart the dev Hub to load it: '
      'cd ../hub/dev && docker compose restart');
}

Never _fail(String message) {
  stderr.writeln('error: $message');
  exit(1);
}
