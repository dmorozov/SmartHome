import 'package:flutter_test/flutter_test.dart';
import 'package:panel/domain/house.dart';
import 'package:panel/ui/dollhouse/dollhouse_view.dart';
import 'package:panel/ui/dollhouse/floor_arrangement.dart';
import 'package:panel/ui/dollhouse/floor_view.dart';

/// Where to tap to select a Floor: the centre of its slab box on screen,
/// asked of the same [FloorArrangement] the [DollhouseView] built — never
/// hand-derived. Only the slab takes taps (the rest of a Floor's box belongs
/// to whichever Floor is behind it), so a corner of the widget rect will not
/// do, and the arithmetic that turns the rect into the slab is exactly what
/// the arrangement module now owns.
Offset floorSlabCentre(
  WidgetTester tester, {
  required House house,
  required String selectedFloorId,
  required String floorId,
}) {
  final arrangement = FloorArrangement.fit(
    house: house,
    selectedFloorId: selectedFloorId,
    viewport: tester.getSize(find.byType(DollhouseView)),
    wallDepth: FloorView.wallDepth,
  );
  return tester.getTopLeft(find.byType(DollhouseView)) +
      arrangement.placementOf(floorId).scaledBounds.center;
}
