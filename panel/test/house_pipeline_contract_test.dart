import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/house_loader.dart';

/// The executable schema agreement across the Python/Dart seam (ADR-0004):
/// what the converter emits, [loadHouse] must accept — including every
/// geometry invariant the loader now enforces. The schema was written down
/// three times (the converter's emit strings, the loader's parse
/// expressions, the HOUSE-PLAN.md table) and had already drifted once; this
/// is the copy that runs.
///
/// It protects the path the runbook tells the family to take: redraw in
/// Sweet Home 3D, regenerate, restart the Panel. Skips where python3 is
/// absent — the agreement is then checked wherever python3 exists.
void main() {
  test(
    'converter output loads through loadHouse (cross-seam contract)',
    () async {
      final tmp = Directory.systemTemp.createTempSync('house-contract-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final out = '${tmp.path}/house.yaml';
      final run = await Process.run('python3', [
        'tool/sh3d_to_yaml.py',
        'tool/fixtures/placeholder-house.Home.xml',
        '-o',
        out,
        '--name',
        'Demo House',
      ]);
      expect(run.exitCode, 0, reason: 'converter failed:\n${run.stderr}');

      final house = loadHouse(
        houseYaml: File(out).readAsStringSync(),
        devicesYaml: File('assets/house/devices.yaml').readAsStringSync(),
      );

      expect(house.floors, hasLength(3)); // ground, upstairs, attic
      expect(house.floors.expand((f) => f.rooms).map((r) => r.id),
          containsAll(['hall', 'garage', 'attic-storage']));
      // Freshly converted geometry satisfies the gatekeeper's invariants —
      // loadHouse would have thrown otherwise — and the Devices the family
      // hand-maintains still land in the rooms the drawing describes.
      expect(house.floors.expand((f) => f.devices), hasLength(33));
    },
    skip: _python3Available()
        ? false
        : 'python3 not on PATH — contract not checked here',
  );
}

bool _python3Available() {
  try {
    return Process.runSync('python3', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}
