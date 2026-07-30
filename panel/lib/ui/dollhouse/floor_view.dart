import 'package:flutter/material.dart';

import '../../domain/device_state.dart';
import '../../domain/house.dart';
import '../hub_controller.dart';
import '../theme.dart';
import 'iso.dart';

/// One Floor as an isometric slab: rooms behind full-height translucent
/// "glass" walls, warm glow on lit Rooms, and — when [expanded] — room
/// labels plus tappable Device pins.
class FloorView extends StatelessWidget {
  const FloorView({
    super.key,
    required this.floor,
    required this.controller,
    required this.projection,
    required this.expanded,
    this.onRoomTap,
    this.onDeviceTap,
  });

  final Floor floor;
  final HubController controller;
  final IsoProjection projection;
  final bool expanded;
  final ValueChanged<Room>? onRoomTap;
  final ValueChanged<Device>? onDeviceTap;

  /// Pixel extrusion below the slab (the visible "walls").
  static const wallDepth = 22.0;

  static const _pinSize = 34.0;

  @override
  Widget build(BuildContext context) {
    final size = projection.size;
    return SizedBox(
      width: size.width,
      height: size.height + wallDepth,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: expanded ? (d) => _handleTap(d.localPosition) : null,
            child: CustomPaint(
              size: Size(size.width, size.height + wallDepth),
              painter: _FloorPainter(
                floor: floor,
                projection: projection,
                litRooms: {
                  for (final r in floor.rooms)
                    if (controller.isRoomLit(r)) r.id,
                },
                showLabels: expanded,
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            child: Text(
              floor.name,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: PanelTheme.inkFaint,
              ),
            ),
          ),
          if (expanded)
            for (final room in floor.rooms)
              for (final device in room.devices) _pin(device),
        ],
      ),
    );
  }

  Widget _pin(Device device) {
    final p = projection.project(device.position);
    return Positioned(
      left: p.dx - _pinSize / 2,
      top: p.dy - _pinSize / 2,
      width: _pinSize,
      height: _pinSize,
      child: GestureDetector(
        key: ValueKey('pin-${device.id}'),
        onTap: () => onDeviceTap?.call(device),
        child: _DevicePin(device: device, state: controller.stateOf(device.id)),
      ),
    );
  }

  void _handleTap(Offset local) {
    final plan = projection.unproject(local);
    for (final room in floor.rooms) {
      if (room.footprint.contains(plan)) {
        onRoomTap?.call(room);
        return;
      }
    }
  }
}

class _DevicePin extends StatelessWidget {
  const _DevicePin({required this.device, required this.state});

  final Device device;
  final DeviceState? state;

  @override
  Widget build(BuildContext context) {
    final on = switch (state) {
      SwitchState s => s.on,
      GarageDoorState g => g.open,
      _ => false,
    };
    final reading = switch (state) {
      ThermostatState t => '${t.currentC.toStringAsFixed(1)}°',
      PowerState p => p.watts >= 1000
          ? '${(p.watts / 1000).toStringAsFixed(1)}kW'
          : '${p.watts.round()}W',
      _ => null,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: on ? PanelTheme.glow : PanelTheme.surfaceRaised,
        shape: BoxShape.circle,
        boxShadow: PanelTheme.raised(8),
      ),
      child: reading == null
          ? Center(
              child: Icon(
                deviceIcon(device.kind),
                size: 17,
                color: on ? Colors.white : PanelTheme.ink,
              ),
            )
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: FittedBox(
                  child: Text(
                    reading,
                    style: const TextStyle(
                      color: PanelTheme.ink,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

class _FloorPainter extends CustomPainter {
  _FloorPainter({
    required this.floor,
    required this.projection,
    required this.litRooms,
    required this.showLabels,
  });

  final Floor floor;
  final IsoProjection projection;
  final Set<String> litRooms;
  final bool showLabels;

  @override
  void paint(Canvas canvas, Size size) {
    final plan = Offset.zero & projection.planSize;
    final slab = projection.projectRect(plan);
    const depth = Offset(0, FloorView.wallDepth);

    final left = projection.project(plan.bottomLeft);
    final bottom = projection.project(plan.bottomRight);
    final right = projection.project(plan.topRight);

    canvas.drawShadow(
        slab.shift(depth), const Color(0xFF7A849C), 6, false);

    Path face(Offset a, Offset b) =>
        Path()..addPolygon([a, b, b + depth, a + depth], true);
    canvas.drawPath(
        face(left, bottom), Paint()..color = const Color(0xFFCBD2E0));
    canvas.drawPath(
        face(bottom, right), Paint()..color = const Color(0xFFBFC7D8));

    canvas.drawPath(slab, Paint()..color = PanelTheme.surfaceRaised);

    final wallPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = PanelTheme.inkFaint.withValues(alpha: .55);

    for (final room in floor.rooms) {
      final path = projection.projectRect(room.footprint);
      if (litRooms.contains(room.id)) {
        final center = projection.project(room.footprint.center);
        final radius = room.footprint.longestSide * projection.scale;
        canvas.save();
        canvas.clipPath(path);
        canvas.drawPath(
          path,
          Paint()
            ..shader = RadialGradient(colors: [
              PanelTheme.glow.withValues(alpha: .5),
              PanelTheme.glow.withValues(alpha: .05),
            ]).createShader(
                Rect.fromCircle(center: center, radius: radius)),
        );
        canvas.restore();
      }
      canvas.drawPath(path, wallPaint);
    }

    canvas.drawPath(
      slab,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..color = PanelTheme.inkFaint.withValues(alpha: .8),
    );

    _paintGlassWalls(canvas);

    if (showLabels) {
      for (final room in floor.rooms) {
        // Above the room center — ceiling lights tend to sit exactly there.
        _label(canvas, room.name,
            projection.project(room.footprint.center) - const Offset(0, 24));
      }
    }
  }

  /// Full-height translucent walls on every room boundary — the "glass
  /// house" look (walls-prototype verdict; the other candidates live on the
  /// prototype/dollhouse-walls branch).
  static const _wallHeightM = 1.5;

  void _paintGlassWalls(Canvas canvas) {
    for (final seg in _wallSegments(floor, projection.planSize)) {
      final pa = projection.project(seg.a);
      final pb = projection.project(seg.b);
      final up = Offset(0, -_wallHeightM * projection.scale);
      final quad = Path()
        ..addPolygon([pa, pb, pb + up, pa + up], true);
      // x-running walls face the viewer, y-running walls sit in shade; the
      // two viewer-far exterior walls are more opaque so the shell reads.
      final face =
          seg.horizontal ? const Color(0xFFE2E7F0) : const Color(0xFFC7CFE0);
      final alpha = seg.backExterior ? .5 : .26;
      canvas.drawPath(quad, Paint()..color = face.withValues(alpha: alpha));
      canvas.drawPath(
        quad,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          ..color = PanelTheme.inkFaint.withValues(alpha: .45),
      );
      // Bright top cap catches the light.
      canvas.drawLine(
        pa + up,
        pb + up,
        Paint()
          ..color = Colors.white.withValues(alpha: alpha + .15)
          ..strokeWidth = 2,
      );
    }
  }

  void _label(Canvas canvas, String text, Offset center) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          fontSize: 10,
          color: PanelTheme.inkFaint,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_FloorPainter oldDelegate) =>
      oldDelegate.floor != floor ||
      oldDelegate.litRooms.length != litRooms.length ||
      !oldDelegate.litRooms.containsAll(litRooms) ||
      oldDelegate.showLabels != showLabels ||
      oldDelegate.projection.scale != projection.scale;
}

class _WallSeg {
  const _WallSeg(this.a, this.b,
      {required this.horizontal, required this.backExterior});

  final Offset a;
  final Offset b;
  final bool horizontal;

  /// One of the two viewer-far exterior walls (north y = 0, west x = 0).
  final bool backExterior;
}

/// Room-boundary segments, deduplicated (rooms tile, so shared boundaries
/// come out identical) and sorted back-to-front for the painter.
List<_WallSeg> _wallSegments(Floor floor, Size plan) {
  final seen = <String>{};
  final segs = <_WallSeg>[];
  for (final room in floor.rooms) {
    final r = room.footprint;
    void add(Offset a, Offset b) {
      if (!seen.add('${a.dx},${a.dy}-${b.dx},${b.dy}')) return;
      final horizontal = a.dy == b.dy;
      segs.add(_WallSeg(
        a,
        b,
        horizontal: horizontal,
        backExterior: horizontal ? a.dy == 0 : a.dx == 0,
      ));
    }

    add(r.topLeft, r.topRight);
    add(r.bottomLeft, r.bottomRight);
    add(r.topLeft, r.bottomLeft);
    add(r.topRight, r.bottomRight);
  }
  double depth(_WallSeg s) => s.a.dx + s.a.dy + s.b.dx + s.b.dy;
  segs.sort((s1, s2) => depth(s1).compareTo(depth(s2)));
  return segs;
}
