# Floor/House own plan-space geometry + a floor_scene module

Give plan-space geometry an owning module (deepen `Floor` and `House`), sink the stranded `plan_geometry.dart` beneath that interface, and put a `FloorScene` module above it that hands the painter a fully decided scene and gives hit-testing one authoritative answer — fixing a live plinth-tap defect in the process.

Status: proposed · Strength: Strong · Written against commit 105610c (2026-08-01) — re-verify line numbers before editing.

---

## 1. Why this refactor

`Room` carries behaviour — `bounds` and `contains` at `panel/lib/domain/house.dart:71-95` — but `Floor` and `House` are data bags, so every question about House Plan geometry gets answered somewhere above the domain, scattered across two Dollhouse widgets. Concretely:

**plan_geometry.dart sits at a hypothetical seam, below the real decisions.** `panel/lib/ui/dollhouse/plan_geometry.dart` is a pure plan-space (meters) module filed under `ui/dollhouse/`. Each of its two functions has exactly one production caller (verified by grep): `outlineSegments` at `floor_view.dart:205`, `wallOutsideSide` at `floor_view.dart:288`. One adapter means a hypothetical seam. Worse, its interface pushes the real decisions back to the caller:

```dart
// floor_view.dart:205-206 — caller decodes the bool to pick plinth faces
for (final seg in outlineSegments(floor.rooms)) {
  if (!seg.outwardPositive) continue;
```

```dart
// floor_view.dart:287-288 — caller decodes the int convention
final backExterior =
    wallOutsideSide(floor.rooms, wall.a, wall.b) == -1;
```

**The rendering decisions live interleaved with Canvas calls.** Plinth-face selection (`floor_view.dart:205-215`), the painter's-algorithm wall sort (`:273-275`), face/shade classification (`:285-286`), exterior-alpha choice (`:287-289`), glow clipping (`:227-241`), and label placement (`:256-261`) all sit inside `_FloorPainter`, testable only through golden PNGs. The four goldens in `panel/test/golden/goldens/` are the sole net under every one of those decisions. Even the widget tests hand-roll projection knowledge — `dollhouse_test.dart:36-38` taps at `rect.topCenter + Offset(0, rect.height * 0.16)` with a comment explaining the 0.32-scale-about-top-centre arithmetic.

**"Which Room is at this point" is hand-rolled twice and has already diverged — a live defect.** `_FloorPainter.hitTest` claims slab AND plinth via two offsets:

```dart
// floor_view.dart:321-329
bool hitTest(Offset position) {
  for (final offset in const [Offset.zero, Offset(0, -FloorView.wallDepth)]) {
    final plan = projection.unproject(position + offset);
    for (final room in floor.rooms) {
      if (room.contains(plan)) return true;
    }
  }
  return false;
}
```

while `_handleTap` checks the slab only:

```dart
// floor_view.dart:109-117
void _handleTap(Offset local) {
  final plan = projection.unproject(local);
  for (final room in floor.rooms) {
    if (room.contains(plan)) {
      onRoomTap?.call(room);
      return;
    }
  }
}
```

The `GestureDetector` at `floor_view.dart:58` uses `HitTestBehavior.deferToChild`, so the painter's `hitTest` decides what the Floor claims in the gesture arena. A tap on the expanded Floor's plinth (the 22px extruded band below the slab) is therefore *claimed* by `hitTest` — it does not fall through to the neighbouring Floor tucked behind — and then *silently swallowed* by `_handleTap`, which finds no Room at the unshifted point. Three places must agree on the hit answer (paint, hitTest, tap) and two already disagree.

**The house's plan extent is private to a widget State.** `_unionPlanSize` at `dollhouse_view.dart:174-183` computes the union extent over all Floors' rooms and feeds the one shared `IsoProjection.fitWidth(...)` at `:91`. This is a House fact trapped in `_DollhouseViewState`.

**The domain module documents the single most important geometric fact wrong.** `house.dart:7-8` says:

```dart
/// isometric projection), y grows south (screen down-left). Each Floor has
/// its own plan origin at its north-west corner.
```

This contradicts ADR-0004 ("one origin (house NW corner) shared by all Floors"), the converter (`panel/tool/sh3d_to_yaml.py:21-22`: "Output units are meters, origin at the house's NW corner (minimum x/y over all floors — every floor shares this one origin)"), the pass-through loader, and the Dollhouse's single shared `IsoProjection` over the union extent — all of which embody one shared NW origin. The shipped `house.yaml` proves it: the upstairs Floor's rooms start at x=6, not x=0, because they share the ground floor's origin. The wrong sentence sits in the one place an agent would read first.

**Two horizontal-edge conventions on the same Wall.** `Wall.horizontal` (`house.dart:50`) uses exact double equality (`a.dy == b.dy`); `plan_geometry.dart` uses `_eps = 0.005` ("m — converter emits mm-rounded coords", `:34`, applied at `:46` and `:105`). `floor_view.dart` uses BOTH on the same Wall in consecutive lines: `wall.horizontal` for face colour at `:286`, the epsilon test (inside `wallOutsideSide`) for exterior classification at `:288`. A near-horizontal wall would get the "shaded" colour but the "horizontal" classification.

**plan_geometry's header states a precondition nothing at that seam enforces.** `plan_geometry.dart:5-7`: "Rooms tile the Floor (ADR-0004), so the Floor's outer outline is exactly the set of room-edge intervals that no other room touches from the far side." Per ADR-0004 the *converter* enforces tiling (it "warns on … non-tiling floors" and rejects overlaps); the domain interface should document that contract, not silently assume it in a ui/ helper.

### Verifier corrections and extra findings (these win where they disagree with the above)

The adversarial verification pass (which read all five named files plus `iso.dart`, the loader, `test_house.dart`, `dollhouse_test.dart`, the golden test, the converter docstring, and all four ADRs) confirmed every evidence claim and added:

- **Correction 1 — tiling enforcement stays in the converter, per ADR-0004.** The deepened Floor interface *documents* the Rooms-tile-the-Floor invariant; it does not enforce it. Loader-side validation is plan 04's job.
- **Correction 2 — the authoritative hit answer is Room-at-local-point, not a boolean.** The painter's hit region must be *defined as* that answer being non-null, making hit-region/act-region divergence structurally impossible rather than merely tested-for.
- **Bonus inconsistency confirmed:** the exact-equality vs epsilon split on `Wall.horizontal` described above (face colour at `:286` vs exterior classification at `:288` on the same Wall).
- **Deletion test re-run:** deleting `plan_geometry.dart` relocates its ~80 lines into its single caller — complexity moves, nothing concentrates — confirming a hypothetical seam, though not a pass-through: its problem is *placement below the decisions*, not existence. Deleting the proposed FloorScene would re-scatter geometry across `paint()`, `hitTest()`, and `_handleTap` — three places that must agree, two of which already disagree. Deleting the deepened Floor would re-strand extent/outline/roomAt in two widget States and a ui/ helper. Both proposed modules pass; the current shape is the failure mode already live.
- **Churn:** 16 commits total in the repo; `floor_view.dart` appears in 5, `dollhouse_view.dart` in 4 — the highest-churn area, fed by the `prototype/dollhouse-walls` branch, with ADR-0004 explicitly deferring 45° shading, furniture, and multi-floor navigation into this exact seam. Not YAGNI; and the plinth-tap divergence is a live defect regardless.
- **Test surface:** today plinth selection, painter sort, and exterior classification sit only under 4 golden PNGs; a "hit region equals act region" test would have caught the plinth-tap divergence mechanically.

## 2. Context a fresh session needs

### Domain terms (CONTEXT.md — quote-level definitions this plan relies on)

- **Panel**: "The wall-mounted touchscreen running the custom dollhouse UI."
- **Hub**: "The headless smart-home broker (Home Assistant) that owns device state … The Panel is its client, never its replacement."
- **Dollhouse**: "The Panel's main view — the house as stacked 2.5D isometric Floors with tappable Rooms."
- **House Plan**: "The Panel-side description of the house's geometry — Floors with their Rooms and Walls, authored by the family. The Dollhouse renders it; the Hub never sees it."
- **Floor**: "One level of the house in the Dollhouse … Floors stack; tapping one expands it. A Floor need not span the whole house footprint (e.g. an upper floor over half the house)."
- **Room**: "A named area on a Floor. Rooms tile their Floor completely — every point belongs to exactly one Room (halls, stairs and the garage are Rooms too; there is no 'outside the perimeter') … Tapping a Room acts on it (e.g. toggles its lights)."
- **Wall**: "A boundary segment drawn on the House Plan. Only drawn Walls exist: where none is drawn, the boundary is an open passage."
- **Device**: "A controllable or observable thing in the house … pinned to a Room in the Dollhouse."

### Design vocabulary (.claude/skills/codebase-design/SKILL.md)

Use these words exactly — never "component", "service", "API", or "boundary". A **module** is anything with an **interface** (everything a caller must know: signatures plus invariants, conventions, error modes) and an **implementation**. A module is **deep** when a lot of behaviour sits behind a small interface; depth gives callers **leverage** (capability per unit of interface learned) and maintainers **locality** (change and bugs concentrate in one place). A **seam** is where an interface lives; an **adapter** satisfies an interface at a seam; one adapter means a hypothetical seam. The **deletion test**: imagine deleting the module — if complexity vanishes it was a pass-through; if it reappears across N callers it was earning its keep. The interface is the test surface; a module may keep **internal seams** used by its own tests.

### ADR constraints (binding sentences)

ADR-0004 (`docs/adr/0004-house-plan-sweet-home-3d-yaml-pipeline.md`), the geometry contract:

> "Geometry rules (grilled 2026-07-30): meters, one origin (house NW corner) shared by all Floors, x east, y south."

> "Rooms tile each Floor completely — every point in exactly one Room; stairs, halls and the attached garage are Rooms. A Floor's slab renders as the union of its rooms, so partial upper floors and the protruding garage need no perimeter concept."

> "Walls are first-class data taken from what is drawn: no wall drawn = open passage = no glass rendered."

> "The converter rejects diagonals and overlaps, and warns on unwalled room boundaries and non-tiling floors — it never invents geometry."

> "upgrading to true 45° edges later costs only converter validation plus one renderer shading case" and "Deferred, enabled by this choice: furniture on the Plan … and multi-floor zoom/scroll Dollhouse navigation."

ADR-0002: "the Panel is a pure view/command layer" — geometry is Panel-side; the Hub never sees it. ADR-0001/0003 do not constrain this plan.

### Current architecture tour

All paths relative to `panel/`. Line numbers are against commit 105610c.

- **`lib/domain/house.dart`** (142 lines) — the domain model: `House` (name + `List<Floor> floors`, "Ordered lowest level first"), `Floor` (id, name, `int level`, rooms, walls, `Iterable<Device> get devices`), `Wall` (`Offset a, b`; `bool get horizontal => a.dy == b.dy;` at `:50`), `Room` (id, name, `List<Offset> footprint`, devices; `Rect get bounds` `:71-81`; even-odd `bool contains(Offset p)` `:84-95`), `Device`, `DeviceKind`, `Connectivity`. The header doc at `:6-8` carries the wrong per-Floor-origin sentence quoted above.
- **`lib/ui/dollhouse/plan_geometry.dart`** (117 lines) — `OutlineSeg` (horizontal, fixed coord `c`, `lo..hi`, `bool outwardPositive`, plan-space endpoint getters `a`/`b` — the caller projects them); `outlineSegments(List<Room>)` (each room edge minus every collinear edge of the other rooms — interval subtraction, `_eps = 0.005`); `wallOutsideSide(List<Room>, Offset a, Offset b)` returning `-1 | 1 | 0` by sampling 0.15m to each side of the wall midpoint ("clears the wall's own thickness").
- **`lib/ui/dollhouse/iso.dart`** (45 lines) — `IsoProjection`, the 2:1 isometric map between plan meters and widget-local pixels: `sx = (x - y) * scale + originX`, `sy = (x + y) * scale / 2`, with `_originX = planSize.height * scale`. `project`, `unproject`, `projectPolygon`, `IsoProjection.fitWidth(Size planSize, double maxWidth)`. Unchanged by this plan.
- **`lib/ui/dollhouse/floor_view.dart`** (340 lines) — `FloorView` (stateless; `static const wallDepth = 22.0` at `:32`; `GestureDetector` with `deferToChild` at `:54-59`; `_handleTap` at `:109-117`), `_DevicePin` (`:120-170`, plan 01 territory), `_FloorPainter` (`:172-339`): slab union of projected footprints (`:194-199` — "Rooms tile the Floor, so the slab is the union of their footprints"), drop shadow, plinth extrusion from `outlineSegments` (`:205-215`), slab fill, per-room glow-clip + stroke (`:225-244`), slab outline stroke, `_paintGlassWalls` (`:271-307`: `_wallHeightM = 1.5` at `:269`, painter's-algorithm sort at `:273-275` by `w.a.dx + w.a.dy + w.b.dx + w.b.dy`, face colour by `wall.horizontal` at `:286`, `backExterior` via `wallOutsideSide == -1` at `:287-288`, alpha `.5` vs `.26` at `:289`, stroke, bright top cap), labels (`:256-261`, anchor `project(room.bounds.center) - const Offset(0, 24)` — "Above the room center — ceiling lights tend to sit exactly there"), `hitTest` at `:320-329`, `shouldRepaint` at `:331-338`.
- **`lib/ui/dollhouse/dollhouse_view.dart`** (209 lines) — the Dollhouse arrangement (plan 05 territory): stacking, neighbour scale/drift constants, `IsoProjection.fitWidth(_unionPlanSize(house), isoWidth)` at `:91`, `_unionPlanSize` at `:174-183` (max over `room.bounds.right` / `.bottom` — implicitly assumes the shared min-(0,0) origin), `_onDeviceTap` (plan 01 territory). Uses `FloorView.wallDepth` at `:88` and `:92`.
- **`lib/data/house_loader.dart`** — pure pass-through YAML→domain loader; no geometry validation (plan 04 adds some). `lib/ui/hub_controller.dart` — `isRoomLit(Room)`, `toggleRoomLights(Room)`, `stateOf(String)`.
- **`assets/house/house.yaml`** — generated placeholder Demo House: 3 Floors (levels 0, 1, 2), ground floor of 8 Rooms including the protruding garage (`[[0,2],[6,2],[6,8],[0,8]]` west of the x=6 main mass), upstairs starting at x=6 (partial Floor sharing the house origin).
- **Tests** — `test/plan_geometry_test.dart` (3 tests over the two pure functions only: shared-boundary exclusion, partial adjacency / protruding-garage, wallOutsideSide classification); `test/dollhouse_test.dart` (4 widget tests, incl. the `rect.height * 0.16` magic-offset tap); `test/golden/dollhouse_golden_test.dart` (4 scenes → `test/golden/goldens/*.png`; regenerate with `flutter test --update-goldens test/golden`); `test/test_house.dart` loads the real shipped assets from disk.

## 3. Target design

Two coordinated moves at one seam.

### Below the seam: deepen `Floor` and `House` (domain)

`panel/lib/domain/house.dart` grows a small geometric interface; `plan_geometry.dart` sinks beneath it as implementation (moved to `panel/lib/domain/plan_geometry.dart`, a `part` of the house library, its functions private). The corrected shared-origin contract and the converter-enforced tiling invariant are documented at this interface — documented, not enforced (verifier correction 1; enforcement is the converter's per ADR-0004, and loader-side validation is plan 04's).

```dart
// domain/house.dart — new public vocabulary

/// Compass direction in plan space: x grows east, y grows south (ADR-0004).
enum PlanDirection { north, south, east, west }

/// One axis-aligned interval of a Floor's outer outline.
class OutlineSeg {
  const OutlineSeg({
    required this.horizontal,
    required this.c,      // fixed coord: y for horizontal segs, x for vertical
    required this.lo,
    required this.hi,
    required this.outward, // horizontal → north|south; vertical → west|east
  });
  final bool horizontal;
  final double c, lo, hi;
  /// Which side of this segment is outside the Floor.
  final PlanDirection outward;
  Offset get a; // (lo, c) or (c, lo)
  Offset get b; // (hi, c) or (c, hi)
}

class Floor {
  // ...existing fields...

  /// The Floor's outer outline as axis-aligned segments. Rooms tile the
  /// Floor (ADR-0004; the converter enforces this — the Panel trusts it),
  /// so the outline is each room edge minus every collinear edge of the
  /// other rooms.
  List<OutlineSeg> outline();

  /// The Room containing plan-space point [p], or null when [p] is outside
  /// the Floor's footprint. Rooms tile the Floor, so at most one matches.
  /// The single authority for "what is at this plan point".
  Room? roomAt(Offset p);

  /// Which side of [wall] lies outside every Room, or null for an interior
  /// Wall (Rooms on both sides).
  PlanDirection? outsideOf(Wall wall);

  /// This Floor's extent measured from the one plan origin shared by all
  /// Floors: the house's NW corner (ADR-0004). A partial upper Floor that
  /// starts at x=6 still reports its extent from x=0.
  Size get planExtent;
}

class House {
  /// Union plan extent across all Floors — the box every Floor projects
  /// within, so one IsoProjection serves the whole Dollhouse.
  Size get planExtent;
}
```

Also in the domain:

- `house.dart:7-8` doc fix — replace "Each Floor has its own plan origin at its north-west corner." with: "All Floors share one plan origin — the house's NW corner (ADR-0004) — which is what lets a single IsoProjection over House.planExtent project every Floor."
- One epsilon: `const _eps = 0.005; // m — the converter emits mm-rounded coords` lives once in the house library; `Wall.horizontal` becomes `(a.dy - b.dy).abs() <= _eps` so face colour and exterior classification can no longer disagree on the same Wall.
- `PlanDirection` replaces both leaked conventions: `outwardPositive` (bool, decoded with `!`) and `wallOutsideSide`'s `-1 | 1 | 0` (decoded with `== -1`).

What hides inside: the interval-subtraction outline algorithm, the two-sided midpoint sampling with its 0.15m offset, the epsilon convention, the tiling assumption. Callers learn four members and an enum.

### Above the seam: `FloorScene` (ui/dollhouse)

New module `panel/lib/ui/dollhouse/floor_scene.dart`. Interface: one constructor and one method plus decided-data fields. It takes a Floor, the projection, and the lit-Room set, and returns the *fully decided* drawable scene — every geometric and classification decision made, leaving `_FloorPainter` to stroke and fill — plus the one authoritative Room-at-a-local-point answer (verifier correction 2).

```dart
// ui/dollhouse/floor_scene.dart

/// Which way a vertical surface faces in the 2:1 isometric view:
/// x-running surfaces face the viewer, y-running surfaces sit in shade.
enum WallFacing { facing, shaded }

/// A plinth quad below a viewer-facing outline segment.
class PlinthFace {
  final Path quad;
  final WallFacing facing;
}

/// One glass Wall, projected, classified, in paint order.
class WallQuad {
  final Path quad;
  final Offset capA, capB;      // top edge, for the bright cap line
  final WallFacing facing;      // drives the face colour
  final bool viewerFarExterior; // exterior with the outside to the N/W → more opaque
}

/// A Room's projected shape plus its per-room decisions.
class RoomShape {
  final Room room;
  final Path outline;      // projected footprint (glow clip + stroke)
  final RoomGlow? glow;    // non-null iff the Room is lit
  final Offset labelAnchor;
}

class RoomGlow {
  final Offset center;     // projected Room centre
  final double radius;     // room.bounds.longestSide * projection.scale
}

/// The fully decided drawable scene for one Floor, and the one authority
/// for what a widget-local point hits.
class FloorScene {
  FloorScene({
    required this.floor,
    required this.projection,
    required this.litRooms,
  });

  /// Pixel extrusion below the slab (the visible plinth "walls").
  static const wallDepth = 22.0;
  /// Glass wall height, meters.
  static const wallHeightM = 1.5;

  final Floor floor;
  final IsoProjection projection;
  final Set<String> litRooms;

  /// Union of the projected Room footprints — Rooms tile the Floor, so
  /// there is no perimeter concept (ADR-0004).
  late final Path slab;
  /// Quads under the south- and east-outward outline segments only —
  /// the viewer-facing edges in the isometric view.
  late final List<PlinthFace> plinthFaces;
  /// Back-to-front by plan depth (painter's algorithm), classified.
  late final List<WallQuad> wallQuads;
  late final List<RoomShape> roomShapes;

  /// The Room at widget-local [local]: on the slab directly, or in the
  /// plinth band, resolved to the Room owning the extruded face (sampled
  /// one wallDepth up). Null anywhere else. The painter's hit region is
  /// exactly the non-null region, and the tap handler acts on the same
  /// call — hit and act cannot diverge.
  Room? roomAtLocal(Offset local);
}
```

Implementation notes (all current behaviour preserved verbatim):

- `plinthFaces`: `floor.outline()` filtered to `outward == PlanDirection.south || outward == PlanDirection.east` (exactly today's `outwardPositive` set); quad = `[a, b, b+depth, a+depth]` projected, `facing` from `seg.horizontal`.
- `wallQuads`: today's sort key `(w.a.dx + w.a.dy + w.b.dx + w.b.dy)`; `facing` from `wall.horizontal` (now epsilon-based); `viewerFarExterior` = `floor.outsideOf(wall) == PlanDirection.north || == PlanDirection.west` (exactly today's `== -1`); quad `[pa, pb, pb+up, pa+up]` with `up = Offset(0, -wallHeightM * projection.scale)`.
- `roomShapes`: outline via `projection.projectPolygon`, glow iff `litRooms.contains(room.id)` with today's centre/radius, `labelAnchor = projection.project(room.bounds.center) - const Offset(0, 24)`.
- `roomAtLocal`: `floor.roomAt(projection.unproject(local))`, else `floor.roomAt(projection.unproject(local - const Offset(0, wallDepth)))` — the same two offsets as today's `hitTest`, but returning the owning Room instead of a bare bool.

### Who calls what, what gets deleted

`FloorView.build` constructs one `FloorScene` per build (comparable cost to today's per-paint work; three Floors, 15 Rooms in the shipped house.yaml). `_FloorPainter` takes the scene plus `showLabels`/`labelStyle` and degenerates to a loop that strokes and fills in today's paint order; `hitTest(p) => scene.roomAtLocal(p) != null`; `_handleTap(local)` becomes `final room = scene.roomAtLocal(local); if (room != null) onRoomTap?.call(room);`. `DollhouseView` calls `house.planExtent`. Colour values, alphas, stroke widths, and `PanelTheme` stay in the painter — the scene decides *classification*, the painter maps classification to style.

Deleted: `panel/lib/ui/dollhouse/plan_geometry.dart` (sunk into the domain), `_unionPlanSize` (dollhouse_view.dart:174-183), the two hand-rolled unproject+contains loops, `_paintGlassWalls`'s decision code, the `outwardPositive` decoding and the `-1|0|1` convention. `FloorView.wallDepth` becomes a forwarding const so plan 05's dollhouse_view references keep compiling.

### Before/after dependency sketch

```
BEFORE
  dollhouse_view ── _unionPlanSize (private, :174) ──> IsoProjection.fitWidth (:91)
  floor_view ──> ui/dollhouse/plan_geometry  (1 caller per fn; filters !outwardPositive, decodes == -1)
  floor_view._handleTap (:109)  ──> unproject + Room.contains   [slab only]      ┐ diverged,
  _FloorPainter.hitTest (:321)  ──> unproject + Room.contains   [slab + plinth]  ┘ plinth taps swallowed
  _FloorPainter.paint           ──> plinth pick + wall sort + classify + glow + labels, interleaved with Canvas
  domain/house.dart             ──  Room deep-ish; Floor/House data bags; origin doc WRONG (:7-8)
  tests: plan_geometry_test (2 pure fns) + 4 golden PNGs under everything else

AFTER
  domain/house.dart (deep)      ──  Floor.outline / roomAt / outsideOf / planExtent · House.planExtent
      └ hides: interval subtraction, side sampling, _eps           (part: domain/plan_geometry.dart)
      └ documents: shared NW origin (fixed), Rooms-tile-Floor (converter-enforced)
  ui/dollhouse/floor_scene.dart (deep) ── FloorScene(floor, projection, litRooms)
      ├ slab · plinthFaces · wallQuads (ordered+classified) · roomShapes (glow, labelAnchor)
      └ roomAtLocal(local) → Room?                     [single authority]
  floor_view (shallow by design) ── painter strokes/fills the scene;
                                    hitTest := roomAtLocal != null; _handleTap := same call
  dollhouse_view ──> house.planExtent ──> IsoProjection.fitWidth
  tests: unit tests over meters data + hit-equals-act contract; goldens guard visual style only
```

## 4. Decision points

**D1 — Plinth taps now act on the owning Room (behaviour change).** Today a tap on the expanded Floor's plinth is claimed by `hitTest` and swallowed by `_handleTap`; after this plan it toggles the owning Room's lights, same as a slab tap. Options: (a) fix — `_handleTap` and `hitTest` share `roomAtLocal`, plinth resolves to the Room owning the extruded face; (b) preserve the swallow by keeping `_handleTap` slab-only. **Recommended: (a).** The verdict classifies the divergence as a live defect; (b) would perpetuate the two-answers shape this plan exists to kill. Record: this CHANGES current user-visible behaviour (a previously dead 22px band becomes tappable).

**D2 — Where the sunk geometry lives.** Options: (a) `panel/lib/domain/plan_geometry.dart` as `part of 'house.dart';` with private `_outlineSegments`/`_wallOutsideSide` (public `OutlineSeg`/`PlanDirection` may live there too — parts share one library); (b) inline everything into `house.dart` (~250 lines total); (c) keep a standalone public `domain/plan_geometry.dart` as a documented internal seam with direct tests. **Recommended: (a).** It keeps `house.dart` readable, makes the helpers genuinely private (callers *cannot* bypass Floor), and the pure tests survive intact through Floor's interface — thin delegates, same assertions, and "the interface is the test surface" (SKILL.md). (b) is acceptable; (c) leaves a public seam nothing but Floor should call.

**D3 — `Wall.horizontal` switches from exact `==` to the unified 5mm epsilon.** Options: (a) epsilon in the domain accessor; (b) keep exact equality and normalize only where the scene classifies. **Recommended: (a).** One convention at the source; for converter-generated (mm-rounded, axis-aligned) data the result is identical, and it removes the `:286`-vs-`:288` split permanently. Coordination: if plan 04's loader validation has landed, axis-alignment is already guaranteed at load — this normalization still applies at render level and costs nothing.

**D4 — `PlanDirection` enum replaces `outwardPositive` and the `-1|0|1` int.** Options: (a) compass enum as specified; (b) keep the bool/int conventions behind the new methods. **Recommended: (a).** The decoding (`!seg.outwardPositive`, `== -1`) is precisely the leak the candidate flagged; compass terms match the domain's documented axes (x east, y south) and read directly at the scene ("plinth = south+east outward", "viewer-far = north/west outside").

**D5 — Classification in the scene, colours in the painter.** Options: (a) scene exposes `WallFacing`/`viewerFarExterior`/glow parameters, painter maps them to `Color`s and alphas; (b) scene emits final `Paint`/`Color` values. **Recommended: (a).** Geometry tests stay free of theme; a future theme change touches only the painter; the goldens keep guarding style where style lives.

**D6 — `wallDepth` (and `wallHeightM`) move to `FloorScene`; `FloorView.wallDepth` forwards.** Options: (a) `static const wallDepth = FloorScene.wallDepth;` on FloorView, leaving `dollhouse_view.dart:88,:92` untouched (plan 05 territory — smallest cross-plan diff); (b) update all references to `FloorScene.wallDepth`. **Recommended: (a)** now; plan 05 may collapse the forward when it rearranges dollhouse_view.

## 5. Step-by-step implementation

Each step leaves `flutter analyze` and `flutter test` green. Paths relative to `panel/` unless rooted.

**Step 1 — Deepen the domain (additive).**
Modify `lib/domain/house.dart`:
- Fix the header doc (`:6-8`): replace the per-Floor-origin sentence with the shared-NW-origin sentence (Section 3 wording).
- Add `enum PlanDirection { north, south, east, west }` with the plan-axes doc comment.
- Add to `Floor`: `Size get planExtent` (max of `room.bounds.right`/`.bottom` over `rooms` — same arithmetic as `_unionPlanSize` restricted to one Floor) and `Room? roomAt(Offset p)` (first `rooms` entry whose `contains(p)` is true, else null), both with the ADR-0004 doc comments from Section 3.
- Add to `House`: `Size get planExtent` (componentwise max over `floors.map((f) => f.planExtent)`).
Create `test/house_geometry_test.dart` with the extent/roomAt cases named in Section 6. Run the suite.

**Step 2 — Dollhouse consumes `House.planExtent`.**
Modify `lib/ui/dollhouse/dollhouse_view.dart`: at `:91` replace `_unionPlanSize(house)` with `house.planExtent`; delete `_unionPlanSize` (`:174-183`); drop the now-unused `dart:math` import only if nothing else uses it (`math.min` at `:86` and `math.max` at `:88` still do — keep it). Goldens must pass unchanged.

**Step 3 — Sink plan_geometry beneath Floor.**
- Create `lib/domain/plan_geometry.dart` starting with `part of 'house.dart';` (a part cannot declare imports — drop the old file's two; `house.dart` already imports `dart:ui`, which is all it needs). Move into it: `OutlineSeg` (public, `outwardPositive` → `outward: PlanDirection`; keep `horizontal`, `c`, `lo`, `hi`, `a`, `b`), `_eps`, `_outlineSegments(List<Room>)` (was `outlineSegments`; sets `outward` from `horizontal` × `interiorPositive`: horizontal+interior-on-positive-side → `north`, etc.), `_wallOutsideSide(List<Room>, Wall)` (was `wallOutsideSide`; takes the `Wall`, returns `PlanDirection?`: `-1` becomes `north`/`west` by orientation, `1` becomes `south`/`east`, `0` becomes null).
- In `lib/domain/house.dart`: add `part 'plan_geometry.dart';`; change `Wall.horizontal` to `(a.dy - b.dy).abs() <= _eps` (D3); add `List<OutlineSeg> outline() => _outlineSegments(rooms);` and `PlanDirection? outsideOf(Wall wall) => _wallOutsideSide(rooms, wall);` to `Floor`, with the tiling-documented-not-enforced doc comment.
- Update `lib/ui/dollhouse/floor_view.dart` call sites minimally (this step only): drop the `plan_geometry.dart` import; `:205-206` becomes `for (final seg in floor.outline()) { if (seg.outward == PlanDirection.north || seg.outward == PlanDirection.west) continue;`; `:287-288` becomes `final side = floor.outsideOf(wall); final backExterior = side == PlanDirection.north || side == PlanDirection.west;` (the alpha line at `:289` is untouched).
- Delete `lib/ui/dollhouse/plan_geometry.dart`. Delete `test/plan_geometry_test.dart`, porting its three cases into `test/house_geometry_test.dart` through `Floor.outline()`/`Floor.outsideOf()` (Section 6). Goldens must pass unchanged.

**Step 4 — Create `FloorScene` (additive).**
Create `lib/ui/dollhouse/floor_scene.dart` with `FloorScene`, `RoomShape`, `RoomGlow`, `WallQuad`, `PlinthFace`, `WallFacing` exactly as specified in Section 3 (constants `wallDepth = 22.0`, `wallHeightM = 1.5`; `late final` fields; implementation notes verbatim). Create `test/floor_scene_test.dart` (Section 6). Nothing consumes the scene yet; suite green.

**Step 5 — Rewire `floor_view` through the scene.**
Modify `lib/ui/dollhouse/floor_view.dart`:
- `FloorView.build` constructs `final scene = FloorScene(floor: floor, projection: projection, litRooms: {for (final r in floor.rooms) if (controller.isRoomLit(r)) r.id});` and passes it to both the painter and the tap handler.
- `FloorView.wallDepth` becomes `static const wallDepth = FloorScene.wallDepth;` (D6). Remove `_wallHeightM` from the painter.
- `_handleTap` becomes the three-line `roomAtLocal` form (D1 — behaviour change lands here).
- `_FloorPainter` fields become `{scene, showLabels, labelStyle}`; `paint` keeps today's order — shadow on `scene.slab.shift(depth)`, plinth faces (facing → `0xFFCBD2E0`, shaded → `0xFFBFC7D8`), slab fill, per-`RoomShape` glow-clip + stroke, slab outline stroke, `WallQuad` loop (facing → `0xFFE2E7F0`, shaded → `0xFFC7CFE0`; alpha `.5` iff `viewerFarExterior` else `.26`; stroke; cap line at alpha `+.15`), labels at `roomShapes[i].labelAnchor` when `showLabels`.
- `hitTest` becomes `scene.roomAtLocal(position) != null`; `shouldRepaint` compares `scene.floor`, `scene.litRooms` (same length+containsAll form), `showLabels`, `labelStyle`, `scene.projection.scale` — identical semantics to today's.
Create `test/floor_view_test.dart` (Section 6). Goldens must pass unchanged — a golden diff here means a rendering decision was accidentally altered.

**Step 6 — Sweep.**
`grep -rn "plan_geometry\|outlineSegments\|wallOutsideSide\|_unionPlanSize\|outwardPositive" panel/lib panel/test` (run from the repo root) must hit nothing outside the house library — `lib/domain/house.dart` (its `part` directive and the delegating members) and `lib/domain/plan_geometry.dart` itself — plus at most ported-from comments in `test/house_geometry_test.dart`. In particular: zero hits under `lib/ui/`, and zero hits anywhere for `outwardPositive` or `_unionPlanSize`. Full verification (Section 7). No CONTEXT.md or ADR edits in this plan (plan 04 owns the ADR correction).

## 6. Test plan

**New: `test/house_geometry_test.dart`** (plain `flutter_test` over meters data, no Canvas):
- `outline of two adjacent rooms excludes their shared boundary` — ported from plan_geometry_test.dart:9-22, through `Floor.outline()`; asserts the x=4 shared edge is gone, south segments `outward == PlanDirection.south`, north segments `outward == PlanDirection.north`, total south length 7.0.
- `partial adjacency leaves the uncovered part on the outline` — ported from `:24-36`, the protruding-garage shape; the east-outward remainder of a's east side is `lo 0, hi 2`.
- `outsideOf classifies exterior and interior Walls` — ported from `:38-49`: north exterior → `PlanDirection.north`, south exterior → `PlanDirection.south`, shared wall → null.
- `outsideOf and outline agree on mm-rounded near-axis coordinates` — pins the unified epsilon (a wall at `dy` difference 0.001 is horizontal and classifies).
- `roomAt returns the one Room containing a point` and `roomAt returns null outside the Floor footprint` — tiling contract pinned for the first time.
- `planExtent measures from the shared NW origin` — a Floor whose rooms start at x=6 (the real upstairs shape) reports width from 0.
- `House.planExtent is the componentwise union across Floors`.

**New: `test/floor_scene_test.dart`** (synthetic Floor + `IsoProjection`, no goldens):
- `plinth faces extrude exactly the south- and east-outward outline segments` — protruding-garage shape; pins plinth selection for the first time.
- `wall quads are ordered back-to-front by plan depth` — pins the painter's-algorithm sort for the first time.
- `x-running walls face the viewer, y-running walls sit in shade` (`WallFacing`).
- `viewer-far exterior walls are flagged; viewer-near exterior and interior are not` — pins exterior classification for the first time.
- `glows exist only for lit Rooms` and `label anchors sit 24px above projected Room centres`.
- `roomAtLocal: slab point returns its Room; plinth-band point resolves to the Room owning the extruded face; empty isometric corner returns null`.
- `hit region equals act region` — the contract test: over a pixel grid spanning the scene box, `roomAtLocal(p) != null` exactly where a tap would act (they are the same call — this pins the property that would have caught the live divergence mechanically).

**New: `test/floor_view_test.dart`** (pumps a bare `FloorView` with a synthetic Floor, controller with `FakeHub`, known `IsoProjection` — no `rect.height * 0.16` magic):
- `tapping the slab reports the Room` (via `onRoomTap` capture).
- `tapping the plinth reports the Room owning that face` — the regression test for the fixed defect (D1).
- `taps outside slab and plinth are not claimed` (falls through / no callback).

**Existing tests:** `test/plan_geometry_test.dart` dies (all three cases ported above). `test/dollhouse_test.dart` unchanged — all four tests must stay green as-is. Loader/hub tests untouched.

**Golden impact:** none expected. The four PNGs under `test/golden/goldens/` (`ground_floor.png`, `upstairs_selected.png`, `device_popup.png`, `hub_offline.png`) must pass WITHOUT regeneration — identical draw calls in identical order is a success criterion of this refactor. Do not run `flutter test --update-goldens`; a golden failure means a decision drifted during the move (inspect `test/golden/failures/*_isolatedDiff.png`). Goldens shrink in role from "the only net under all Dollhouse geometry" to guarding visual style.

**Behaviours pinned for the first time:** outline correctness through the domain interface, Room-at-point/tiling, plan extent and its union, plinth-face selection, wall depth-sort order, exterior/interior and facing/shaded classification, hit-region == act-region, plinth-tap resolution to the owning Room.

## 7. Verification

```sh
cd panel && flutter analyze && flutter test
```

Golden subset when iterating on steps 2/3/5: `cd panel && flutter test test/golden`.

Live check, if wanted: this Mac has Flutter via brew but NO Xcode — run the app with `cd panel && flutter run -d chrome` (web build), never `-d macos`. Verify: floors render identically; tapping a room toggles its glow; tapping the 22px plinth band below the expanded floor's south/east edges now also toggles the owning room (D1); tapping the empty isometric corner still selects the neighbour behind.

## 8. Non-goals

- **No loader-side geometry validation.** Tiling, overlap, and axis-alignment enforcement stay in the converter per ADR-0004 (verifier correction 1); loader validation is plan 04's. Floor's interface documents the invariants only.
- **No 45° shading.** ADR-0004 defers it ("costs only converter validation plus one renderer shading case"); when it comes, the shading case lands as one more `WallFacing`/plinth classification inside `FloorScene` — that trigger is written down here deliberately.
- **No furniture on the Plan, no multi-floor zoom/scroll navigation.** Both ADR-0004-deferred; they land inside Floor/House and FloorScene when they come, which is the point of placing this seam now.
- **No arrangement changes.** `dollhouse_view`'s stacking/drift/scale math is plan 05's; this plan touches it only to swap `_unionPlanSize` for `House.planExtent`.
- **No Device pin or Popup changes.** `_DevicePin` and `device_popup` are plan 01's.
- **No visual changes.** Pixel-identical goldens are a success criterion; colour/alpha/stroke values move nowhere (they stay in the painter).
- **No `iso.dart` changes, no caching or performance work in `FloorScene`** (`late final` fields suffice at 3-Floors/15-Rooms scale; the scene is rebuilt per widget build exactly as the painter's decisions were re-made per paint).

## 9. Cross-plan coordination

There are 8 plans in this series: `docs/plans/01-device-presentation-module.md`, `02-hubclient-contract-and-scriptable-fakehub.md`, this one (03), `04-house-plan-gatekeeper.md`, `05-floor-arrangement-module.md`, `06-device-vocabulary-table.md`, `07-hub-status-three-state.md`, `08-panel-boot-module.md`. Coordination notes for this one, from the review's coordination input and verified against the sibling plan files at 105610c:

- **Plan 05 (`docs/plans/05-floor-arrangement-module.md`)** — you move `_unionPlanSize` from dollhouse_view into House. Plan 05 consumes the union extent (its decision D3 names exactly this: move `_unionPlanSize` in privately with a comment naming the plan-03 swap, or call the domain member if 03 already landed): if 05 lands first it keeps a private extent computation you then replace; if you land first, 05 calls your `House.planExtent`. Both paths are fine; in either order the end state is one owner in the domain.
- **Plan 01 (`docs/plans/01-device-presentation-module.md`)** — touches floor_view's `_DevicePin` and `device_popup`, and explicitly declares `_FloorPainter`/`hitTest`/`_handleTap` as this plan's territory — disjoint concerns within `floor_view.dart`; either order. (Merge note: both plans edit `floor_view.dart`, so expect a textual merge, not a semantic one.)
- **Plan 04 (`docs/plans/04-house-plan-gatekeeper.md`)** — corrects ADR-0004's stale sentence (the orphan-Room one: "the converter warns when `devices.yaml` references a missing room" — actually the loader errors) and adds loader-side geometry validation; this plan fixes `house.dart`'s wrong per-Floor-origin doc comment, which plan 04's tour explicitly leaves to this plan ("plan 03 fixes that, not this plan") — both corrections should land regardless of order. On `Wall.horizontal`: plan 04's non-goals leave it unchanged (its gatekeeper makes the exact `==` a legitimate assumption), so this plan's D3 is the only place the epsilon unification happens. No conflict in either order: epsilon-horizontal accepts a superset of exact-`==`-horizontal, and on gatekeeper-validated (axis-aligned) data the two are identical.

Discovered while planning:

- **Golden ordering with plan 01:** this plan requires goldens to pass *unchanged*; plan 01 also expects no golden impact under its recommended decisions (its golden section says "Expected impact: none"), but some of its decision options could legitimately alter pin pixels. If 01 lands first with regenerated goldens, re-verify this plan against those baselines — the "no regeneration" criterion still holds, just against 01's baselines.
- **Plan 05 and `FloorView.wallDepth`:** D6 keeps a forwarding const precisely so 05's dollhouse_view work does not conflict (05's step 4 passes `wallDepth: FloorView.wallDepth` into its arrangement, and its decision D2 owns where the constant ultimately lives); once 05 decides, the forward can collapse.
- **The `dollhouse_test.dart` magic offsets** (`rect.height * 0.16`) belong to the arrangement, not to this plan — if 05 wants to clean them up, `FloorScene.roomAtLocal` now exists as the honest way to find a tappable point.

## 10. Sources

- `CONTEXT.md` — domain language (Panel, Hub, Dollhouse, House Plan, Floor, Room, Wall, Device, Popup).
- `docs/adr/0004-house-plan-sweet-home-3d-yaml-pipeline.md` — the geometry contract this plan re-asserts at the domain interface; also `docs/adr/0001`–`0003` for the appliance/Hub context.
- `.claude/skills/codebase-design/SKILL.md` — deep module, interface, seam, adapter, depth, leverage, locality, deletion test, internal seams.
- `panel/tool/sh3d_to_yaml.py` (docstring, lines 10-25) — converter rules and the shared-origin statement.
- Originating architecture review: candidate "Floor-level plan-space geometry has no owner" plus its adversarial verification verdict (Strength: Strong; two corrections applied — converter-enforced tiling, Room-at-local-point as the authoritative hit answer). The review itself was a temp HTML artifact and is ephemeral; everything load-bearing from it is reproduced in Sections 1–4 above.
