import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:panel/domain/house.dart';

import 'test_house.dart';

Room _room(String id, List<Offset> pts) =>
    Room(id: id, name: id, footprint: pts);

Floor _floor(List<Room> rooms) =>
    Floor(id: 'f', name: 'F', level: 0, rooms: rooms);

/// Plan-space geometry through the Floor and House interfaces — meters in,
/// meters out, no Canvas. These are the questions the Dollhouse asks before
/// it draws anything, and until now they were answered inside a painter.
void main() {
  final adjacent = _floor([
    _room('a', const [Offset(0, 0), Offset(4, 0), Offset(4, 3), Offset(0, 3)]),
    _room('b', const [Offset(4, 0), Offset(7, 0), Offset(7, 3), Offset(4, 3)]),
  ]);

  group('outline', () {
    test('two adjacent Rooms exclude their shared boundary', () {
      final segs = adjacent.outline();

      // 7×3 union: 4 outline sides, the x=4 shared edge subtracted away.
      expect(segs.where((s) => !s.horizontal && s.c == 4), isEmpty);
      final south = segs.where((s) => s.horizontal && s.c == 3);
      expect(south.every((s) => s.outward == PlanDirection.south), isTrue);
      expect(south.fold(0.0, (sum, s) => sum + (s.hi - s.lo)), 7.0);
      final north = segs.where((s) => s.horizontal && s.c == 0);
      expect(north.every((s) => s.outward == PlanDirection.north), isTrue);
    });

    test('partial adjacency leaves the uncovered part on the outline', () {
      // b touches only the lower half of a's east side — the upper half of
      // that side stays exterior (the protruding-garage shape).
      final floor = _floor([
        _room('a',
            const [Offset(0, 0), Offset(4, 0), Offset(4, 4), Offset(0, 4)]),
        _room('b',
            const [Offset(4, 2), Offset(6, 2), Offset(6, 4), Offset(4, 4)]),
      ]);

      final eastOfA = floor.outline().where(
          (s) => !s.horizontal && s.c == 4 && s.outward == PlanDirection.east);

      expect(eastOfA.single.lo, 0);
      expect(eastOfA.single.hi, 2);
    });
  });

  group('outsideOf', () {
    test('classifies exterior and interior Walls', () {
      expect(adjacent.outsideOf(const Wall(Offset(0, 0), Offset(4, 0))),
          PlanDirection.north);
      expect(adjacent.outsideOf(const Wall(Offset(0, 3), Offset(4, 3))),
          PlanDirection.south);
      expect(adjacent.outsideOf(const Wall(Offset(4, 0), Offset(4, 3))),
          isNull);
      expect(adjacent.outsideOf(const Wall(Offset(0, 0), Offset(0, 3))),
          PlanDirection.west);
      expect(adjacent.outsideOf(const Wall(Offset(7, 0), Offset(7, 3))),
          PlanDirection.east);
    });

    test('agrees with Wall.horizontal on mm-rounded near-axis coordinates',
        () {
      // The converter emits mm-rounded coords, so a drawn wall can miss
      // exact equality by a micron. One epsilon decides both the face
      // shading and the exterior classification, or the same Wall reads
      // horizontal for one and vertical for the other.
      const nearlyFlat = Wall(Offset(0, 0), Offset(4, 0.001));

      expect(nearlyFlat.horizontal, isTrue);
      expect(adjacent.outsideOf(nearlyFlat), PlanDirection.north);
    });
  });

  group('roomAt', () {
    test('returns the one Room containing the point', () {
      expect(adjacent.roomAt(const Offset(2, 1.5))?.id, 'a');
      expect(adjacent.roomAt(const Offset(5, 1.5))?.id, 'b');
    });

    test('returns null outside the Floor footprint', () {
      expect(adjacent.roomAt(const Offset(9, 1.5)), isNull);
      expect(adjacent.roomAt(const Offset(2, 5)), isNull);
      expect(adjacent.roomAt(const Offset(-1, 1.5)), isNull);
    });
  });

  group('planExtent', () {
    test('measures a partial Floor from the shared house origin', () {
      // The real upstairs shape: rooms start at x=6 because every Floor
      // shares the ground floor's NW origin (ADR-0004).
      final upstairs = _floor([
        _room('u',
            const [Offset(6, 0), Offset(14, 0), Offset(14, 6), Offset(6, 6)]),
      ]);

      expect(upstairs.planExtent, const Size(14, 6));
    });

    test('House unions componentwise across Floors', () {
      final wide = _floor([
        _room('w',
            const [Offset(0, 0), Offset(20, 0), Offset(20, 4), Offset(0, 4)]),
      ]);
      final deep = _floor([
        _room('d',
            const [Offset(6, 0), Offset(14, 0), Offset(14, 12), Offset(6, 12)]),
      ]);

      // Neither Floor alone gives this box.
      expect(House(name: 'H', floors: [wide, deep]).planExtent,
          const Size(20, 12));
    });

    test('the shipped House Plan reports the box the Dollhouse projects in',
        () {
      final house = loadTestHouse();
      var w = 0.0, d = 0.0;
      for (final floor in house.floors) {
        for (final room in floor.rooms) {
          w = math.max(w, room.bounds.right);
          d = math.max(d, room.bounds.bottom);
        }
      }

      expect(house.planExtent, Size(w, d));
    });
  });
}
