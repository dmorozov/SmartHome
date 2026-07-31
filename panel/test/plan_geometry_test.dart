import 'package:flutter_test/flutter_test.dart';
import 'package:panel/domain/house.dart';
import 'package:panel/ui/dollhouse/plan_geometry.dart';

Room _room(String id, List<Offset> pts) =>
    Room(id: id, name: id, footprint: pts);

void main() {
  test('outline of two adjacent rooms excludes their shared boundary', () {
    final rooms = [
      _room('a', const [Offset(0, 0), Offset(4, 0), Offset(4, 3), Offset(0, 3)]),
      _room('b', const [Offset(4, 0), Offset(7, 0), Offset(7, 3), Offset(4, 3)]),
    ];
    final segs = outlineSegments(rooms);
    // 7×3 union: 4 outline sides, the x=4 shared edge subtracted away.
    expect(segs.where((s) => !s.horizontal && s.c == 4), isEmpty);
    final south = segs.where((s) => s.horizontal && s.c == 3).toList();
    expect(south.every((s) => s.outwardPositive), isTrue);
    expect(south.fold(0.0, (sum, s) => sum + (s.hi - s.lo)), 7.0);
    final north = segs.where((s) => s.horizontal && s.c == 0).toList();
    expect(north.every((s) => s.outwardPositive), isFalse);
  });

  test('partial adjacency leaves the uncovered part on the outline', () {
    // b touches only the lower half of a's east side — the upper half of
    // that side stays exterior (the protruding-garage shape).
    final rooms = [
      _room('a', const [Offset(0, 0), Offset(4, 0), Offset(4, 4), Offset(0, 4)]),
      _room('b', const [Offset(4, 2), Offset(6, 2), Offset(6, 4), Offset(4, 4)]),
    ];
    final segs = outlineSegments(rooms);
    final eastOfA =
        segs.where((s) => !s.horizontal && s.c == 4 && s.outwardPositive);
    expect(eastOfA.single.lo, 0);
    expect(eastOfA.single.hi, 2);
  });

  test('wallOutsideSide classifies exterior vs interior walls', () {
    final rooms = [
      _room('a', const [Offset(0, 0), Offset(4, 0), Offset(4, 3), Offset(0, 3)]),
      _room('b', const [Offset(4, 0), Offset(7, 0), Offset(7, 3), Offset(4, 3)]),
    ];
    // North exterior wall: outside is the −y side.
    expect(wallOutsideSide(rooms, const Offset(0, 0), const Offset(4, 0)), -1);
    // South exterior wall: outside is the +y side.
    expect(wallOutsideSide(rooms, const Offset(0, 3), const Offset(4, 3)), 1);
    // Shared interior wall: rooms on both sides.
    expect(wallOutsideSide(rooms, const Offset(4, 0), const Offset(4, 3)), 0);
  });
}
