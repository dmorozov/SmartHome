import 'dart:math' as math;
import 'dart:ui';

import '../../domain/house.dart';
import 'iso.dart';

/// Where one Floor stands on the Dollhouse stage.
enum FloorRole {
  /// Full size, Device pins live, not itself a selection target.
  selected,

  /// Shrunk and drifted into one of the selected Floor's empty isometric
  /// corners. Tapping its slab selects it.
  neighbour,

  /// Parked beyond the near edge of the stack: faded out and untappable,
  /// but still placed, so selecting a neighbour slides the next Floor into
  /// view rather than popping it in.
  offStage,
}

/// One Floor's place on the stage: where its unscaled box goes, how it is
/// scaled (about the box's top centre), and where the scaled box actually
/// lands on screen.
class FloorPlacement {
  const FloorPlacement({
    required this.floor,
    required this.role,
    required this.boxTopLeft,
    required this.scale,
    required this.scaledBounds,
  });

  final Floor floor;
  final FloorRole role;

  /// Top-left of the *unscaled* Floor box in viewport coordinates — what
  /// `AnimatedPositioned(left:, top:)` wants, because the scale is applied
  /// below it and does not move the box.
  final Offset boxTopLeft;

  /// What `AnimatedScale(scale:, alignment: Alignment.topCenter)` wants.
  final double scale;

  /// The Floor box after that top-centre scale, in viewport coordinates:
  /// where the slab visually sits. Its centre is the Floor's canonical tap
  /// point — the one thing a caller cannot recover from [boxTopLeft] and
  /// [scale] without re-deriving the arrangement's own arithmetic.
  final Rect scaledBounds;
}

/// The Dollhouse floor-drift arrangement, decided in one pass: the
/// projection that fits the height budget, which Floors are on stage, and
/// where every Floor's box goes — off-stage Floors included.
///
/// The arrangement is the winner of the floor-drift prototype: at most
/// three Floors on stage, the neighbours shrunk and drifted into the
/// selected Floor's empty isometric corners — the one above up and to the
/// right, the one below down and to the left.
///
/// What a caller may rely on: [placements] covers every Floor of the House
/// exactly once, ordered level-descending (upper Floors paint over lower
/// ones, and every Floor keeps its animation state across selections); at
/// most three of them are not [FloorRole.offStage]; no placement's
/// [FloorPlacement.scaledBounds] leaves the viewport horizontally; and one
/// [projection] serves all of them, so Floors share a plan origin on screen
/// the way they share one in the House Plan (ADR-0004).
///
/// Pure — meters and pixels in, pixels out, no widgets — so the whole
/// arrangement is answerable without pumping a frame.
class FloorArrangement {
  const FloorArrangement._({required this.projection, required this.placements});

  /// Arranges [house] with [selectedFloorId] expanded inside a [viewport],
  /// where each Floor's box is its projected plan plus [wallDepth] pixels of
  /// extrusion below (`FloorView.wallDepth` — the extrusion is the view's
  /// fact, the box height is this module's).
  factory FloorArrangement.fit({
    required House house,
    required String selectedFloorId,
    required Size viewport,
    required double wallDepth,
  }) {
    // Highest level first: upper Floors render above lower ones.
    final ordered = [...house.floors]
      ..sort((a, b) => b.level.compareTo(a.level));

    final selectedLevel =
        house.floors.firstWhere((f) => f.id == selectedFloorId).level;
    // At most three Floors are on stage: the selected one plus its immediate
    // neighbours. Anything further away waits off-stage until one of those
    // neighbours is selected and becomes the new centre.
    final onStage = [
      for (final floor in ordered)
        if ((floor.level - selectedLevel).abs() <= 1) floor
    ];
    double scaleOf(Floor floor) =>
        floor.id == selectedFloorId ? 1.0 : _neighbourScale;

    // Fit to width, but never let the on-stage Floors (one selected + up to
    // two neighbours + spacing) overflow the height.
    final scaleTotal = onStage.fold(0.0, (sum, f) => sum + scaleOf(f));
    final heightBudget =
        viewport.height / (scaleTotal + (onStage.length - 1) * _sizingGapFactor);
    final isoWidth = math.min(
      viewport.width * _widthFraction,
      math.max(_minIsoWidth, (heightBudget - wallDepth) * 2),
    );
    final projection = IsoProjection.fitWidth(house.planExtent, isoWidth);
    final floorH = projection.size.height + wallDepth;
    final planW = projection.size.width;
    final left = (viewport.width - planW) / 2;
    final gap = floorH * _gapFactor;

    final tops = <String, double>{};
    var y = 0.0;
    for (final floor in onStage) {
      tops[floor.id] = y;
      y += floorH * scaleOf(floor) + gap;
    }
    final stackH = y - gap;
    final topPad = ((viewport.height - stackH) / 2).clamp(0.0, double.infinity);

    // Off-stage Floors are parked beyond the near edge so selecting a
    // neighbour slides the next one into view rather than popping it in.
    double topOf(Floor floor) {
      final onStageTop = tops[floor.id];
      if (onStageTop != null) return topPad + onStageTop;
      final parked = floorH * _neighbourScale;
      return floor.level > selectedLevel ? topPad - parked : topPad + stackH;
    }

    // A Floor scaled about its top centre leaves (1 - scale)/2 of the plan
    // width free on each side; drift into that slack (plus the outer margin)
    // and nothing can leave the viewport.
    double driftOf(Floor floor) {
      final slack = planW * (1 - scaleOf(floor)) / 2 + left;
      return ((floor.level - selectedLevel) * _driftFactor * planW)
          .clamp(-slack, slack);
    }

    return FloorArrangement._(
      projection: projection,
      placements: [
        for (final floor in ordered)
          () {
            final scale = scaleOf(floor);
            final boxTopLeft = Offset(left + driftOf(floor), topOf(floor));
            return FloorPlacement(
              floor: floor,
              role: floor.id == selectedFloorId
                  ? FloorRole.selected
                  : tops.containsKey(floor.id)
                      ? FloorRole.neighbour
                      : FloorRole.offStage,
              boxTopLeft: boxTopLeft,
              scale: scale,
              // The top-centre scale, reproduced: the box keeps its top edge
              // and loses (1 - scale)/2 of the plan width on each side.
              scaledBounds: Rect.fromLTWH(
                boxTopLeft.dx + planW * (1 - scale) / 2,
                boxTopLeft.dy,
                planW * scale,
                floorH * scale,
              ),
            );
          }(),
      ],
    );
  }

  /// Sized against the height budget, which depends on the on-stage scales —
  /// so choosing the projection is part of arranging the Floors, not a
  /// separate decision the caller makes first.
  final IsoProjection projection;

  /// Every Floor of the House, level-descending.
  final List<FloorPlacement> placements;

  /// The placement of the Floor with [floorId]. Throws if the House has no
  /// such Floor — the id came from that House to begin with.
  FloorPlacement placementOf(String floorId) =>
      placements.firstWhere((p) => p.floor.id == floorId);

  /// Scale of the neighbouring Floors.
  static const _neighbourScale = 0.32;

  /// Horizontal drift of a neighbour, as a fraction of the projected plan
  /// width: the Floor above goes right, the one below goes left.
  static const _driftFactor = 0.26;

  /// Vertical spacing between Floors as a fraction of the selected Floor's
  /// height. Negative: the neighbours overlap into its empty corners.
  static const _gapFactor = -0.225;

  /// The selected Floor is sized against this spacing rather than the real
  /// (negative) [_gapFactor] — otherwise pulling the neighbours in just
  /// frees up height that the selected Floor grows into, leaving them
  /// exactly as far away as they started.
  static const _sizingGapFactor = 0.03;

  /// Fraction of the viewport width the projected plan may occupy, leaving
  /// the neighbours room to drift outward without touching the edges.
  static const _widthFraction = 0.78;

  /// Below this the Dollhouse is unreadable anyway; a floor on the height
  /// budget stops the projection collapsing to nothing in a short viewport.
  static const _minIsoWidth = 200.0;
}
