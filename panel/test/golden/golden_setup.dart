import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/main.dart';
import 'package:panel/ui/hub_controller.dart';
import 'package:panel/ui/audio/talk.dart';
import 'package:panel/ui/video/live_video.dart';
import 'package:panel/ui/video/snapshot.dart';

/// The size the goldens render at: a real 16:10 panel resolution, and big
/// enough that every pin and room label is legible. Costs ~100-200 KB per
/// scene in the repo. `tool/shot.sh` covers other resolutions against a
/// real build, without committing anything.
const kPanelSize = Size(1280, 800);

/// Everything a golden test needs, in the right order. Call from `main()`
/// before the [goldenTest]s.
void setUpPanelGoldens({double tolerance = 0}) {
  setUpAll(() async {
    await _loadPanelFonts();
    _useTolerantComparator(tolerance);
  });
}

/// A [testWidgets] that renders with real shadows.
///
/// flutter_test disables them by default, which erases the entire
/// neumorphic look: the soft dual shadows become flat blocks and the slab
/// loses its drop shadow. It also checks, immediately after each test body
/// and before any teardown, that the flag was put back — so the flip has to
/// live inside the body rather than in `setUpAll`.
void goldenTest(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    debugDisableShadows = false;
    try {
      await body(tester);
    } finally {
      debugDisableShadows = true;
    }
  });
}

/// Pumps the whole app at [kPanelSize] and settles the entry animations.
/// [hubLabel] defaults to the fake hub's, which is what a dev build shows;
/// a scene about the production Panel passes `'HUB'`.
///
/// [video] defaults to unconfigured, and every committed golden depends on
/// it staying that way: an unconfigured Popup draws the same box, icon and
/// sentence it drew before go2rtc existed, so `goldens/device_popup.png`
/// stays the picture it already is. Pointing a golden at a live view means
/// deliberately baking a new one — in the devcontainer only, the canonical
/// golden host (ADR-0009; phase-0 item 13 closed with the 2026-08-06
/// in-container bake, which already includes the phase-7 Cameras tab).
Future<void> pumpPanel(
  WidgetTester tester,
  HubController controller, {
  Size size = kPanelSize,
  String hubLabel = 'FAKE HUB',
  VideoConfig video = const VideoConfig(),
  SnapshotConfig snapshots = const SnapshotConfig(),
  TalkConfig talk = const TalkConfig(),
}) async {
  tester.view
    ..physicalSize = size
    // 1.0 keeps logical pixels equal to image pixels: the golden is exactly
    // `size`, and it stays comparable to a `tool/shot.sh` capture.
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(PanelApp(
      controller: controller,
      hubLabel: hubLabel,
      video: video,
      snapshots: snapshots,
      stills: const Go2rtcStillsConfig(),
      talk: talk));
  await tester.pumpAndSettle();
}

/// Real glyphs instead of flutter_test's default font, which draws every
/// character as an identical box — useless for telling `812 W` from `21.4°`,
/// which is most of what a Panel golden is for.
///
/// The fonts come from the Flutter SDK's own cache rather than the repo, so
/// no font binaries land in git and any machine on the same Flutter version
/// gets identical metrics.
Future<void> _loadPanelFonts() async {
  // Loud, never silent. Skipping this quietly would make
  // `--update-goldens` rewrite every scene in placeholder boxes and commit
  // it, which is worse than not having goldens at all.
  final cache = _materialFontsDir() ??
      (throw StateError('material_fonts not found under FLUTTER_ROOT '
          '(${Platform.environment['FLUTTER_ROOT'] ?? 'unset'}). Golden '
          'images would render as placeholder boxes. Run `flutter precache` '
          'or set FLUTTER_ROOT, then re-run.'));
  const families = <String, List<String>>{
    'Roboto': [
      'Roboto-Regular.ttf',
      'Roboto-Medium.ttf',
      'Roboto-Bold.ttf',
      'Roboto-Black.ttf',
    ],
    'MaterialIcons': ['MaterialIcons-Regular.otf'],
  };
  // Without these two nothing legible renders at all; the other weights are
  // a nicety, and the SDK is free to stop shipping them.
  const essential = {'Roboto-Regular.ttf', 'MaterialIcons-Regular.otf'};
  for (final family in families.entries) {
    final loader = FontLoader(family.key);
    for (final name in family.value) {
      final file = File('${cache.path}/$name');
      if (!file.existsSync()) {
        if (essential.contains(name)) {
          throw StateError('${file.path} is missing — golden images would '
              'render ${family.key} as placeholder boxes.');
        }
        continue;
      }
      loader.addFont(
          Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await loader.load();
  }
}

/// `$FLUTTER_ROOT/bin/cache/artifacts/material_fonts`, found via the
/// environment the `flutter` tool sets, or by walking up from the test
/// runner binary (which lives under the same `bin/cache`).
Directory? _materialFontsDir() {
  const suffix = 'bin/cache/artifacts/material_fonts';
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final dir = Directory('$root/$suffix');
    if (dir.existsSync()) return dir;
  }
  for (var dir = File(Platform.resolvedExecutable).parent;
      dir.path != dir.parent.path;
      dir = dir.parent) {
    final candidate = Directory('${dir.path}/$suffix');
    if (candidate.existsSync()) return candidate;
  }
  return null;
}

/// Exact by default, and it should stay that way: at [kPanelSize] even a
/// 1% tolerance is ~10,000 pixels, while a whole 34px Device pin is only
/// ~1,150 — so a loose tolerance would let an entire pin change without
/// anyone noticing, which is most of what these goldens are guarding.
///
/// The goldens are baked and verified in the devcontainer, the canonical
/// golden host (ADR-0009); red on any other machine is the expected
/// out-of-container state and safe to ignore. The knob exists only for
/// genuine cross-rebuild drift *inside* the container — an SDK or
/// base-image bump shifting Skia's anti-aliasing. Raise it as little as
/// possible, and keep it well under the size of the smallest thing you
/// want to catch.
void _useTolerantComparator(double tolerance) {
  final current = goldenFileComparator as LocalFileComparator;
  goldenFileComparator =
      _TolerantComparator(current.basedir.resolve('_'), tolerance: tolerance);
}

class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(super.testFile, {required this.tolerance});

  /// Fraction of differing pixels tolerated, 0..1.
  final double tolerance;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    if (result.passed || result.diffPercent <= tolerance) {
      result.dispose();
      return true;
    }
    // Writes masterImage/testImage/isolatedDiff PNGs next to the goldens —
    // the actual point of the exercise when something changes.
    final failure = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(failure);
  }
}
