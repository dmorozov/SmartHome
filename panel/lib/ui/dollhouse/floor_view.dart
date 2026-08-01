import 'package:flutter/material.dart';

import '../../domain/house.dart';
import '../device_presentation.dart';
import '../hub_controller.dart';
import '../theme.dart';
import 'iso.dart';
import 'plan_geometry.dart';

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
    // Room labels go straight onto the canvas, so they do not inherit the
    // app's text style the way a Text widget does. Without this they render
    // in whatever font the engine happens to default to — a different one
    // from the rest of the Panel, and on a bare Linux kiosk possibly none.
    final labelStyle = DefaultTextStyle.of(context).style.copyWith(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: PanelTheme.inkFaint,
        );
    return SizedBox(
      width: size.width,
      height: size.height + wallDepth,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          GestureDetector(
            // Defer to the painter's hit test: Floors overlap each other's
            // bounding boxes (a neighbour sits in the selected Floor's empty
            // isometric corner), so only the slab itself may take a tap.
            behavior: HitTestBehavior.deferToChild,
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
                labelStyle: labelStyle,
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
        child: _DevicePin(presentation: controller.presentationOf(device)),
      ),
    );
  }

  void _handleTap(Offset local) {
    final plan = projection.unproject(local);
    for (final room in floor.rooms) {
      if (room.contains(plan)) {
        onRoomTap?.call(room);
        return;
      }
    }
  }
}

class _DevicePin extends StatelessWidget {
  const _DevicePin({required this.presentation});

  final DevicePresentation presentation;

  @override
  Widget build(BuildContext context) {
    final on = presentation.glows;
    final reading = presentation.reading;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: on ? PanelTheme.glow : PanelTheme.surfaceRaised,
        shape: BoxShape.circle,
        boxShadow: PanelTheme.raised(8),
      ),
      child: reading == null
          ? Center(
              child: Icon(
                presentation.icon,
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
    required this.labelStyle,
  });

  final Floor floor;
  final IsoProjection projection;
  final Set<String> litRooms;
  final bool showLabels;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    const depth = Offset(0, FloorView.wallDepth);

    // Rooms tile the Floor, so the slab is the union of their footprints —
    // there is no house-perimeter concept (partial upper floors and the
    // protruding garage just work).
    Path? slab;
    for (final room in floor.rooms) {
      final path = projection.projectPolygon(room.footprint);
      slab = slab == null ? path : Path.combine(PathOperation.union, slab, path);
    }
    if (slab == null) return;

    canvas.drawShadow(
        slab.shift(depth), const Color(0xFF7A849C), 6, false);

    // Plinth: extrude the viewer-facing outline edges (south + east).
    for (final seg in outlineSegments(floor.rooms)) {
      if (!seg.outwardPositive) continue;
      final a = projection.project(seg.a);
      final b = projection.project(seg.b);
      canvas.drawPath(
        Path()..addPolygon([a, b, b + depth, a + depth], true),
        Paint()
          ..color = seg.horizontal
              ? const Color(0xFFCBD2E0)
              : const Color(0xFFBFC7D8),
      );
    }

    canvas.drawPath(slab, Paint()..color = PanelTheme.surfaceRaised);

    final wallPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = PanelTheme.inkFaint.withValues(alpha: .55);

    for (final room in floor.rooms) {
      final path = projection.projectPolygon(room.footprint);
      if (litRooms.contains(room.id)) {
        final center = projection.project(room.bounds.center);
        final radius = room.bounds.longestSide * projection.scale;
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
            projection.project(room.bounds.center) - const Offset(0, 24));
      }
    }
  }

  /// Full-height translucent "glass" walls (walls-prototype verdict; other
  /// candidates live on the prototype/dollhouse-walls branch). Drawn from
  /// the Floor's Wall data as-is: an undrawn boundary is an open passage
  /// (ADR-0004).
  static const _wallHeightM = 1.5;

  void _paintGlassWalls(Canvas canvas) {
    // Painter's algorithm: back-to-front by plan depth.
    final walls = [...floor.walls]..sort((w1, w2) =>
        (w1.a.dx + w1.a.dy + w1.b.dx + w1.b.dy)
            .compareTo(w2.a.dx + w2.a.dy + w2.b.dx + w2.b.dy));
    for (final wall in walls) {
      final pa = projection.project(wall.a);
      final pb = projection.project(wall.b);
      final up = Offset(0, -_wallHeightM * projection.scale);
      final quad = Path()
        ..addPolygon([pa, pb, pb + up, pa + up], true);
      // x-running walls face the viewer, y-running walls sit in shade; the
      // viewer-far exterior walls (outside to the north/west) are more
      // opaque so the shell reads.
      final face =
          wall.horizontal ? const Color(0xFFE2E7F0) : const Color(0xFFC7CFE0);
      final backExterior =
          wallOutsideSide(floor.rooms, wall.a, wall.b) == -1;
      final alpha = backExterior ? .5 : .26;
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
      text: TextSpan(text: text, style: labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  /// Only the slab (and the plinth extruded below it) belongs to this
  /// Floor; a tap anywhere else in the box falls through to whatever sits
  /// behind — normally the neighbouring Floor tucked into the corner.
  @override
  bool hitTest(Offset position) {
    for (final offset in const [Offset.zero, Offset(0, -FloorView.wallDepth)]) {
      final plan = projection.unproject(position + offset);
      for (final room in floor.rooms) {
        if (room.contains(plan)) return true;
      }
    }
    return false;
  }

  @override
  bool shouldRepaint(_FloorPainter oldDelegate) =>
      oldDelegate.floor != floor ||
      oldDelegate.litRooms.length != litRooms.length ||
      !oldDelegate.litRooms.containsAll(litRooms) ||
      oldDelegate.showLabels != showLabels ||
      oldDelegate.labelStyle != labelStyle ||
      oldDelegate.projection.scale != projection.scale;
}

