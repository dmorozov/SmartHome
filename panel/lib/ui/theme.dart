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
