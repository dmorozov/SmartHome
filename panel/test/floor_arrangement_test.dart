import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:panel/domain/house.dart';
import 'package:panel/ui/dollhouse/floor_arrangement.dart';
import 'package:panel/ui/dollhouse/floor_view.dart';

import 'test_house.dart';

/// A House of [floorCount] identical square-ish Floors, levels 0..n-1 — the
/// stage without the scenery. What the arrangement cares about is how many
/// Floors there are and which one is selected.
House _house(int floorCount) => House(
  name: 'Test House',
  floors: [
    for (var level = 0; level < floorCount; level++)
      Floor(
        id: 'f$level',
        name: 'Floor $level',
        level: level,
        rooms: [
          Room(
            id: 'r$level',
            name: 'Room $level',
            footprint: const [
              Offset(0, 0),
              Offset(10, 0),
              Offset(10, 8),
              Offset(0, 8),
            ],
          ),
        ],
      ),
  ],
);

/// The viewport the Panel actually hands the Dollhouse at [kPanelSize]:
/// 1280 wide minus padding, 800 tall minus the header.
const _viewport = Size(1232, 700);

FloorArrangement _fit(
  House house,
  String selectedFloorId, {
  Size viewport = _viewport,
}) => FloorArrangement.fit(
  house: house,
  selectedFloorId: selectedFloorId,
  viewport: viewport,
  wallDepth: FloorView.wallDepth,
);

/// Two Floors of deliberately different size on one shared plan origin: a
/// full 10×8 ground floor, and an upper Floor over the far quarter of it.
/// The case `slabBounds` exists for — `Floor.planExtent` measures from the
/// shared origin, so the small Floor still reports a 10×8 extent and gets a
/// full-width box with its slab tucked inside one corner.
House _unevenHouse() => House(
  name: 'Uneven House',
  floors: [
    Floor(
      id: 'ground',
      name: 'Ground',
      level: 0,
      rooms: [
        Room(
          id: 'big',
          name: 'Big',
          footprint: const [
            Offset(0, 0),
            Offset(10, 0),
            Offset(10, 8),
            Offset(0, 8),
          ],
        ),
      ],
    ),
    Floor(
      id: 'attic',
      name: 'Attic',
      level: 1,
      rooms: [
        Room(
          id: 'small',
          name: 'Small',
          footprint: const [
            Offset(6, 5),
            Offset(10, 5),
            Offset(10, 8),
            Offset(6, 8),
          ],
        ),
      ],
    ),
  ],
);

/// The floor-drift arrangement through its own interface: Floors and a
/// viewport in, placements out, no frame pumped. Until this module existed
/// every rule below was reachable only as golden pixels — or not at all.
void main() {
  /// What anything drawn *beside* a Floor has to hang off, and the reason it
  /// is not [FloorPlacement.scaledBounds]: the box is shared, the slab is
  /// not. The Floor labels were pinned to the box until 2026-08-15, which is
  /// why every one of them lined up at the same x however big its Floor was.
  group('slabBounds', () {
    test('a Floor that fills the footprint has a slab as wide as its box; one '
        'that does not sits strictly inside it', () {
      final arrangement = _fit(_unevenHouse(), 'ground');
      final ground = arrangement.placementOf('ground');
      final attic = arrangement.placementOf('attic');

      // The full-footprint Floor: slab and box agree, to within the rounding
      // of a projected diamond.
      expect(ground.slabBounds.left, closeTo(ground.scaledBounds.left, 1));
      expect(ground.slabBounds.right, closeTo(ground.scaledBounds.right, 1));

      // The quarter-footprint Floor: its own outline is well inside the box
      // it shares with the Floor below.
      expect(attic.slabBounds.left, greaterThan(attic.scaledBounds.left + 1));
      expect(attic.slabBounds.right, lessThan(attic.scaledBounds.right + 1));
      expect(attic.slabBounds.width, lessThan(attic.scaledBounds.width));
    });

    test('the slab scales with its Floor, so a neighbour\'s is smaller than '
        'the same Floor\'s when selected', () {
      final house = _unevenHouse();
      final selected = _fit(house, 'attic').placementOf('attic');
      final neighbour = _fit(house, 'ground').placementOf('attic');

      expect(neighbour.slabBounds.width, lessThan(selected.slabBounds.width));
    });
  });

  group('on stage', () {
    test('at most three Floors are on stage, the selected one plus its '
        'immediate neighbours', () {
      final house = _house(5);
      for (final selected in house.floors) {
        final arrangement = _fit(house, selected.id);
        final onStage = arrangement.placements
            .where((p) => p.role != FloorRole.offStage)
            .toList();

        expect(onStage.length, lessThanOrEqualTo(3), reason: selected.id);
        expect(
          onStage.every((p) => (p.floor.level - selected.level).abs() <= 1),
          isTrue,
          reason: selected.id,
        );
        expect(arrangement.placementOf(selected.id).role, FloorRole.selected);
      }
    });

    test('placements cover every Floor, ordered level-descending', () {
      // Off-stage Floors must be placed on every build, not omitted: the
      // Stack's children are keyed, and a Floor that vanishes between builds
      // slides back in from nowhere instead of from where it was parked.
      final arrangement = _fit(_house(5), 'f2');

      expect(arrangement.placements.map((p) => p.floor.id), [
        'f4',
        'f3',
        'f2',
        'f1',
        'f0',
      ]);
    });

    test('the selected Floor is full size, its neighbours share one smaller '
        'scale', () {
      final arrangement = _fit(_house(3), 'f1');

      expect(arrangement.placementOf('f1').scale, 1.0);
      final above = arrangement.placementOf('f2').scale;
      final below = arrangement.placementOf('f0').scale;
      expect(above, below);
      expect(above, lessThan(1.0));
    });
  });

  group('drift', () {
    test('the neighbour above drifts right, the one below drifts left', () {
      // The selected Floor's empty isometric corners: up-and-right for the
      // Floor above, down-and-left for the one below.
      final arrangement = _fit(_house(3), 'f1');
      final selected = arrangement.placementOf('f1').scaledBounds.center.dx;

      expect(
        arrangement.placementOf('f2').scaledBounds.center.dx,
        greaterThan(selected),
      );
      expect(
        arrangement.placementOf('f0').scaledBounds.center.dx,
        lessThan(selected),
      );
    });

    test(
      'drift never pushes a Floor outside the viewport, even when narrow',
      () {
        // Drift is clamped to the slack a top-centre scale leaves plus the
        // outer margin. Narrow viewports are where that clamp actually bites —
        // and where the drifted neighbour would otherwise be half off-screen.
        for (final width in [320.0, 480.0, 700.0, 1000.0, 1232.0]) {
          final arrangement = _fit(_house(5), 'f2', viewport: Size(width, 700));
          for (final placement in arrangement.placements) {
            expect(
              placement.scaledBounds.left,
              greaterThanOrEqualTo(-_eps),
              reason: '${placement.floor.id} at width $width',
            );
            expect(
              placement.scaledBounds.right,
              lessThanOrEqualTo(width + _eps),
              reason: '${placement.floor.id} at width $width',
            );
          }
        }
      },
    );
  });

  group('the stack', () {
    test('off-stage Floors park beyond the near edge, clear of the stack', () {
      final arrangement = _fit(_house(5), 'f2');
      final onStage = arrangement.placements
          .where((p) => p.role != FloorRole.offStage)
          .map((p) => p.scaledBounds);
      final stackTop = onStage
          .map((r) => r.top)
          .reduce((a, b) => a < b ? a : b);
      final stackBottom = onStage
          .map((r) => r.bottom)
          .reduce((a, b) => a > b ? a : b);

      // Two levels above the selection: parked above the stack…
      expect(arrangement.placementOf('f4').role, FloorRole.offStage);
      expect(
        arrangement.placementOf('f4').scaledBounds.bottom,
        lessThanOrEqualTo(stackTop + _eps),
      );
      // …and two below: parked under it, ready to slide up.
      expect(arrangement.placementOf('f0').role, FloorRole.offStage);
      expect(
        arrangement.placementOf('f0').scaledBounds.top,
        greaterThanOrEqualTo(stackBottom - _eps),
      );
    });

    test('the on-stage stack centres vertically in the viewport', () {
      final arrangement = _fit(_house(5), 'f2');
      final onStage = arrangement.placements
          .where((p) => p.role != FloorRole.offStage)
          .map((p) => p.scaledBounds);
      final top = onStage.map((r) => r.top).reduce((a, b) => a < b ? a : b);
      final bottom = onStage
          .map((r) => r.bottom)
          .reduce((a, b) => a > b ? a : b);

      expect(top, closeTo(_viewport.height - bottom, _eps));
    });

    test('the projection never exceeds 78% of the viewport width', () {
      for (final viewport in const [
        Size(1232, 700),
        Size(1232, 2000), // height to spare: the width cap is what binds
        Size(400, 700),
        Size(2560, 1440),
      ]) {
        expect(
          _fit(_house(3), 'f1', viewport: viewport).projection.size.width,
          lessThanOrEqualTo(viewport.width * 0.78 + _eps),
          reason: '$viewport',
        );
      }
    });

    test("a Floor's scaled box keeps the unscaled box's top centre", () {
      // The identity `AnimatedScale(alignment: Alignment.topCenter)` applies,
      // and the reason scaledBounds.center is a usable tap point: the box
      // pivots about its top centre, so the centre stays put horizontally.
      final arrangement = _fit(_house(3), 'f1');
      final planW = arrangement.projection.size.width;

      for (final placement in arrangement.placements) {
        expect(
          placement.scaledBounds.center.dx,
          closeTo(placement.boxTopLeft.dx + planW / 2, _eps),
          reason: placement.floor.id,
        );
        expect(
          placement.scaledBounds.top,
          placement.boxTopLeft.dy,
          reason: placement.floor.id,
        );
        expect(
          placement.scaledBounds.width,
          closeTo(planW * placement.scale, _eps),
          reason: placement.floor.id,
        );
      }
    });
  });

  test('the shipped House Plan: with the ground floor selected the attic '
      'waits off-stage', () {
    // The live three-Floor behaviour, guarded until now only by the pixels
    // of upstairs_selected.png.
    final arrangement = _fit(loadTestHouse(), 'ground-floor');

    expect(arrangement.placementOf('ground-floor').role, FloorRole.selected);
    expect(arrangement.placementOf('upstairs').role, FloorRole.neighbour);
    expect(arrangement.placementOf('attic').role, FloorRole.offStage);
  });
}

/// Float slop in pixels: the assertions below are exact arithmetic that
/// merely reassociates the module's own, so nothing bigger is needed.
const _eps = 1e-9;
