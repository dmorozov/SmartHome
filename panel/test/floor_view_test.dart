import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/fake_hub.dart';
import 'package:panel/domain/house.dart';
import 'package:panel/ui/dollhouse/floor_scene.dart';
import 'package:panel/ui/dollhouse/floor_view.dart';
import 'package:panel/ui/dollhouse/iso.dart';
import 'package:panel/ui/hub_controller.dart';

Room _room(String id, List<Offset> pts) =>
    Room(id: id, name: id, footprint: pts);

/// One Floor, pumped bare at a projection the test picked — so a tap lands
/// where the arithmetic says it does, with no Dollhouse arrangement in the
/// way.
void main() {
  final floor = Floor(id: 'ground', name: 'Ground', level: 0, rooms: [
    _room('a', const [Offset(0, 0), Offset(4, 0), Offset(4, 3), Offset(0, 3)]),
    _room('b', const [Offset(4, 0), Offset(7, 0), Offset(7, 3), Offset(4, 3)]),
  ]);
  final house = House(name: 'Test House', floors: [floor]);
  final projection = IsoProjection(planSize: const Size(7, 3), scale: 40);

  late List<String> tapped;
  late HubController controller;

  setUp(() {
    tapped = <String>[];
    controller = HubController(
        house: house, hub: FakeHub(house, driftEvery: Duration.zero));
  });

  tearDown(() => controller.dispose());

  Future<void> pumpFloor(WidgetTester tester) => tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          // topLeft, unconstrained: widget-local pixels are global pixels,
          // so a projected plan point is a tap coordinate.
          child: Align(
            alignment: Alignment.topLeft,
            child: FloorView(
              floor: floor,
              controller: controller,
              projection: projection,
              selected: true,
              onRoomTap: (room) => tapped.add(room.id),
            ),
          ),
        ),
      );

  testWidgets('tapping the slab reports the Room under it', (tester) async {
    await pumpFloor(tester);

    await tester.tapAt(projection.project(const Offset(5, 1.5)));
    await tester.pump();

    expect(tapped, ['b']);
  });

  testWidgets('tapping the plinth reports the Room owning that face',
      (tester) async {
    // The 22px band extruded below the slab's south and east edges used to
    // be claimed by the painter's hit test and then dropped by the tap
    // handler, which looked for a Room at the unshifted point and found
    // none. The tap died there — it did not even fall through to the Floor
    // behind.
    await pumpFloor(tester);

    final southEdge = projection.project(const Offset(2, 3));
    await tester.tapAt(southEdge + const Offset(0, FloorScene.wallDepth / 2));
    await tester.pump();

    expect(tapped, ['a']);
  });

  testWidgets('taps outside the slab and plinth are not claimed',
      (tester) async {
    await pumpFloor(tester);

    // The empty isometric corner, which belongs to whichever Floor is
    // tucked in behind this one.
    await tester.tapAt(const Offset(2, 2));
    await tester.pump();

    expect(tapped, isEmpty);
  });

  testWidgets('every point the Floor claims is a point it acts on',
      (tester) async {
    // The contract, swept over the whole box: hit region == act region.
    // Three places used to have to agree about what a point hits — paint,
    // hitTest, tap — and two of them had already drifted apart.
    await pumpFloor(tester);
    final painter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((paint) => paint.painter)
        .whereType<CustomPainter>()
        .single;
    final box = tester.getSize(find.byType(FloorView));

    var claimed = 0;
    for (var y = 1.0; y < box.height; y += 11) {
      for (var x = 1.0; x < box.width; x += 11) {
        final point = Offset(x, y);
        tapped.clear();
        await tester.tapAt(point);
        await tester.pump();
        final claims = painter.hitTest(point) ?? false;
        if (claims) claimed++;
        expect(tapped.isNotEmpty, claims, reason: 'at $point');
      }
    }
    // Guard against the whole sweep passing because nothing was claimed.
    expect(claimed, greaterThan(50));
  });
}
