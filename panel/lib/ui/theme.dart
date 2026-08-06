import 'package:flutter/material.dart';

import '../domain/house.dart';

/// Neumorphic-lite palette and shadows for the Panel prototype. A soft
/// light surface with dual shadows; the real design system comes with the
/// full Panel UI work.
abstract final class PanelTheme {
  static const surface = Color(0xFFE8EBF2);
  static const surfaceRaised = Color(0xFFF2F4F9);
  static const ink = Color(0xFF3A4256);
  static const inkFaint = Color(0xFF8A93A8);

  /// Lit-room warmth.
  static const glow = Color(0xFFFFB74D);
  static const accent = Color(0xFF5B8DEF);

  static List<BoxShadow> raised([double blur = 14]) => [
        BoxShadow(
          color: Colors.white.withValues(alpha: .9),
          offset: Offset(-blur / 2, -blur / 2),
          blurRadius: blur,
        ),
        BoxShadow(
          color: const Color(0xFFB8C0D4).withValues(alpha: .8),
          offset: Offset(blur / 2, blur / 2),
          blurRadius: blur,
        ),
      ];

  static ThemeData data() => ThemeData(
        useMaterial3: true,
        // Named, not left to Material's default — and the reason is the
        // internet, not typography.
        //
        // Material's default typography picks its family from
        // `defaultTargetPlatform`, which on web comes from the *browser's*
        // platform: `Roboto` on Linux and Android, `.AppleSystemUIFont` on
        // macOS, `Segoe UI` on Windows. Only the first is bundled
        // (`pubspec.yaml`). The web engine's missing-glyph check asks whether
        // the *requested* family covers a rune, so under an unregistered
        // family every rune above ASCII counts as missing and the Noto
        // fallback downloader goes to fonts.gstatic.com — for text Roboto
        // covers perfectly well. `main.dart`'s subtitle alone is enough to
        // trigger it: it separates its three hints with `·` (U+00B7).
        //
        // Measured 2026-08-06, same build, only `navigator.platform` spoofed,
        // counting requests that left the LAN:
        //
        //     Linux x86_64   0        MacIntel   1        Win32   1
        //
        // and 0 on all three with this line. The wall is Chromium on Linux, so
        // today this costs nothing and prevents nothing — it is here because
        // "which OS is the browser on" is not a thing the house's ability to
        // draw its own UI should depend on, and a second screen or a tablet is
        // one decision away.
        //
        // Distinct from the engine's *own* Roboto fetch, which no Dart code can
        // influence — that one is stopped by the `fonts:` stanza naming the
        // family `Roboto`, and only by that. Two mechanisms, two fixes; see
        // panel/README.md.
        fontFamily: 'Roboto',
        colorSchemeSeed: accent,
        scaffoldBackgroundColor: surface,
      );
}

IconData deviceIcon(DeviceKind kind) => switch (kind) {
      DeviceKind.light => Icons.lightbulb,
      DeviceKind.outlet => Icons.power,
      DeviceKind.thermostat => Icons.thermostat,
      DeviceKind.camera => Icons.videocam,
      DeviceKind.doorbell => Icons.doorbell,
      DeviceKind.oven => Icons.microwave,
      DeviceKind.tv => Icons.tv,
      DeviceKind.washer => Icons.local_laundry_service,
      DeviceKind.dryer => Icons.dry_cleaning,
      DeviceKind.litterRobot => Icons.pets,
      DeviceKind.feeder => Icons.restaurant,
      DeviceKind.garageDoor => Icons.garage,
      DeviceKind.evCharger => Icons.ev_station,
      DeviceKind.energyMonitor => Icons.bolt,
    };
