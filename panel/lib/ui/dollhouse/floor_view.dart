import 'package:flutter/material.dart';

import '../../domain/house.dart';
import '../device_presentation.dart';
import '../hub_controller.dart';
import '../theme.dart';
import 'floor_scene.dart';
import 'iso.dart';

/// One Floor as an isometric slab: rooms behind full-height translucent
/// "glass" walls, warm glow on lit Rooms, and — when [expanded] — room
/// labels plus tappable Device pins.
///
/// Shape is [FloorScene]'s call, style is this file's: the scene decides
/// what is drawn and what a tap hits, the painter decides what colour it is.
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
  static const wallDepth = FloorScene.wallDepth;

  static const _pinSize = 34.0;

  @override
  Widget build(BuildContext context) {
    final size = projection.size;
    final scene = FloorScene(
      floor: floor,
      projection: projection,
      litRooms: {
        for (final room in floor.rooms)
          if (controller.isRoomLit(room)) room.id,
      },
    );
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
            onTapUp:
                expanded ? (d) => _handleTap(scene, d.localPosition) : null,
            child: CustomPaint(
              size: Size(size.width, size.height + wallDepth),
              painter: _FloorPainter(
                scene: scene,
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

  /// The same answer the painter claimed the tap with — a point the Floor
  /// takes out of the gesture arena always acts on a Room.
  void _handleTap(FloorScene scene, Offset local) {
    final room = scene.roomAtLocal(local);
    if (room != null) onRoomTap?.call(room);
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

/// Strokes and fills a decided [FloorScene]. Every geometric choice was made
/// before this class saw it; what is left is the palette and the order.
class _FloorPainter extends CustomPainter {
  _FloorPainter({
    required this.scene,
    required this.showLabels,
    required this.labelStyle,
  });

  final FloorScene scene;
  final bool showLabels;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    if (scene.roomShapes.isEmpty) return;
    const depth = Offset(0, FloorScene.wallDepth);

    canvas.drawShadow(
        scene.slab.shift(depth), const Color(0xFF7A849C), 6, false);

    // Plinth: the viewer-facing outline edges, extruded.
    for (final face in scene.plinthFaces) {
      canvas.drawPath(
        face.quad,
        Paint()
          ..color = face.facing == WallFacing.facing
              ? const Color(0xFFCBD2E0)
              : const Color(0xFFBFC7D8),
      );
    }

    canvas.drawPath(scene.slab, Paint()..color = PanelTheme.surfaceRaised);

    final wallPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = PanelTheme.inkFaint.withValues(alpha: .55);

    for (final shape in scene.roomShapes) {
      final glow = shape.glow;
      if (glow != null) {
        canvas.save();
        canvas.clipPath(shape.outline);
        canvas.drawPath(
          shape.outline,
          Paint()
            ..shader = RadialGradient(colors: [
              PanelTheme.glow.withValues(alpha: .5),
              PanelTheme.glow.withValues(alpha: .05),
            ]).createShader(Rect.fromCircle(
                center: glow.center, radius: glow.radius)),
        );
        canvas.restore();
      }
      canvas.drawPath(shape.outline, wallPaint);
    }

    canvas.drawPath(
      scene.slab,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..color = PanelTheme.inkFaint.withValues(alpha: .8),
    );

    _paintGlassWalls(canvas);

    if (showLabels) {
      for (final shape in scene.roomShapes) {
        _label(canvas, shape.room.name, shape.labelAnchor);
      }
    }
  }

  /// Full-height translucent "glass" walls (walls-prototype verdict; other
  /// candidates live on the prototype/dollhouse-walls branch). Drawn from
  /// the Floor's Wall data as-is: an undrawn boundary is an open passage
  /// (ADR-0004).
  void _paintGlassWalls(Canvas canvas) {
    for (final wall in scene.wallQuads) {
      // x-running walls face the viewer, y-running walls sit in shade; the
      // viewer-far exterior walls (outside to the north/west) are more
      // opaque so the shell reads.
      final face = wall.facing == WallFacing.facing
          ? const Color(0xFFE2E7F0)
          : const Color(0xFFC7CFE0);
      final alpha = wall.viewerFarExterior ? .5 : .26;
      canvas.drawPath(wall.quad, Paint()..color = face.withValues(alpha: alpha));
      canvas.drawPath(
        wall.quad,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          ..color = PanelTheme.inkFaint.withValues(alpha: .45),
      );
      // Bright top cap catches the light.
      canvas.drawLine(
        wall.capA,
        wall.capB,
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

  /// Only the slab (and the plinth extruded below it) belongs to this Floor;
  /// a tap anywhere else in the box falls through to whatever sits behind —
  /// normally the neighbouring Floor tucked into the corner. This is the
  /// same answer [FloorView] acts on, so the Floor cannot claim a tap it
  /// would then swallow.
  @override
  bool hitTest(Offset position) => scene.roomAtLocal(position) != null;

  @override
  bool shouldRepaint(_FloorPainter oldDelegate) =>
      oldDelegate.scene.floor != scene.floor ||
      oldDelegate.scene.litRooms.length != scene.litRooms.length ||
      !oldDelegate.scene.litRooms.containsAll(scene.litRooms) ||
      oldDelegate.showLabels != showLabels ||
      oldDelegate.labelStyle != labelStyle ||
      oldDelegate.scene.projection.scale != scene.projection.scale;
}
