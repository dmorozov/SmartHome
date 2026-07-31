import 'dart:ui';

import '../../domain/house.dart';

/// Plan-space geometry over a Floor's Rooms. Rooms tile the Floor
/// (ADR-0004), so the Floor's outer outline is exactly the set of room-edge
/// intervals that no other room touches from the far side.

/// One axis-aligned interval of the Floor outline.
class OutlineSeg {
  const OutlineSeg({
    required this.horizontal,
    required this.c,
    required this.lo,
    required this.hi,
    required this.outwardPositive,
  });

  final bool horizontal;

  /// The fixed coordinate (y for horizontal segments, x for vertical).
  final double c;
  final double lo;
  final double hi;

  /// Whether the outside of the house lies on the +axis side (south for
  /// horizontal, east for vertical).
  final bool outwardPositive;

  Offset get a => horizontal ? Offset(lo, c) : Offset(c, lo);
  Offset get b => horizontal ? Offset(hi, c) : Offset(c, hi);
}

const _eps = 0.005; // m — converter emits mm-rounded coords

/// The Floor's outer outline as axis-aligned intervals: each room edge minus
/// every collinear edge of the other rooms.
List<OutlineSeg> outlineSegments(List<Room> rooms) {
  final edges = <({int room, bool horizontal, double c, double lo, double hi,
      bool interiorPositive})>[];
  for (var r = 0; r < rooms.length; r++) {
    final pts = rooms[r].footprint;
    for (var i = 0; i < pts.length; i++) {
      final a = pts[i];
      final b = pts[(i + 1) % pts.length];
      final horizontal = (a.dy - b.dy).abs() <= _eps;
      final c = horizontal ? a.dy : a.dx;
      final lo = horizontal
          ? (a.dx < b.dx ? a.dx : b.dx)
          : (a.dy < b.dy ? a.dy : b.dy);
      final hi = horizontal
          ? (a.dx > b.dx ? a.dx : b.dx)
          : (a.dy > b.dy ? a.dy : b.dy);
      if (hi - lo <= _eps) continue;
      final mid = horizontal
          ? Offset((lo + hi) / 2, c + 0.01)
          : Offset(c + 0.01, (lo + hi) / 2);
      edges.add((
        room: r,
        horizontal: horizontal,
        c: c,
        lo: lo,
        hi: hi,
        interiorPositive: rooms[r].contains(mid),
      ));
    }
  }
  final out = <OutlineSeg>[];
  for (final e in edges) {
    // Subtract every other room's collinear edges from this one.
    var intervals = [(e.lo, e.hi)];
    for (final o in edges) {
      if (o.room == e.room ||
          o.horizontal != e.horizontal ||
          (o.c - e.c).abs() > _eps) {
        continue;
      }
      intervals = [
        for (final (lo, hi) in intervals) ...[
          if (o.lo > lo + _eps) (lo, o.lo < hi ? o.lo : hi),
          if (o.hi < hi - _eps) (o.hi > lo ? o.hi : lo, hi),
        ]
      ];
    }
    for (final (lo, hi) in intervals) {
      if (hi - lo <= _eps) continue;
      out.add(OutlineSeg(
        horizontal: e.horizontal,
        c: e.c,
        lo: lo,
        hi: hi,
        outwardPositive: !e.interiorPositive,
      ));
    }
  }
  return out;
}

/// Which side of the axis-aligned wall [a]→[b] lies outside every Room:
/// -1 (the −axis side: north / west), 1 (the +axis side: south / east),
/// 0 (interior wall — rooms on both sides).
int wallOutsideSide(List<Room> rooms, Offset a, Offset b) {
  const off = 0.15; // m — clears the wall's own thickness
  final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
  final horizontal = (a.dy - b.dy).abs() <= _eps;
  final neg = horizontal
      ? Offset(mid.dx, mid.dy - off)
      : Offset(mid.dx - off, mid.dy);
  final pos = horizontal
      ? Offset(mid.dx, mid.dy + off)
      : Offset(mid.dx + off, mid.dy);
  final negInside = rooms.any((r) => r.contains(neg));
  final posInside = rooms.any((r) => r.contains(pos));
  if (negInside && !posInside) return 1;
  if (posInside && !negInside) return -1;
  return 0;
}
