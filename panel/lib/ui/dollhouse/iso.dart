import 'dart:ui';

/// 2:1 isometric projection between Floor plan space (meters) and the Floor
/// widget's local pixels:
///
///     sx = (x - y) * scale + originX
///     sy = (x + y) * scale / 2
///
/// with originX chosen so the projected plan's bounding box starts at local
/// (0, 0).
class IsoProjection {
  IsoProjection({required this.planSize, required this.scale});

  /// Fit the projection of a [planSize]-metre plan into [maxWidth] pixels.
  factory IsoProjection.fitWidth(Size planSize, double maxWidth) =>
      IsoProjection(
        planSize: planSize,
        scale: maxWidth / (planSize.width + planSize.height),
      );

  final Size planSize;
  final double scale;

  /// Pixel size of the projected plan parallelogram (excluding wall depth).
  Size get size => Size(
        (planSize.width + planSize.height) * scale,
        (planSize.width + planSize.height) * scale / 2,
      );

  double get _originX => planSize.height * scale;

  Offset project(Offset plan) => Offset(
        (plan.dx - plan.dy) * scale + _originX,
        (plan.dx + plan.dy) * scale / 2,
      );

  Offset unproject(Offset local) {
    final sx = local.dx - _originX;
    final sy = local.dy;
    return Offset((sx + 2 * sy) / (2 * scale), (2 * sy - sx) / (2 * scale));
  }

  Path projectPolygon(List<Offset> plan) =>
      Path()..addPolygon([for (final p in plan) project(p)], true);
}
