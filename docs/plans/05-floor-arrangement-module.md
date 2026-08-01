# Pure floor_arrangement module extracted from DollhouseView.build

Extract the Dollhouse's floor-drift arrangement math — on-stage selection, per-Floor scale/top/drift/role, height budgeting, projection sizing, off-stage parking — out of `_DollhouseViewState.build` into a pure, directly unit-tested `floor_arrangement.dart` module beside `iso.dart` and `plan_geometry.dart`, so the view shrinks to a thin animator and the tests stop hand-deriving the magic tap fraction `0.16`.

Status: proposed · Strength: Strong · Written against commit 105610c (2026-08-01) — re-verify line numbers before editing.

---

## 1. Why this refactor

### The friction

The entire floor-drift arrangement — which Floors are on stage, each Floor's scale, top, drift and opacity, the height budget that sizes the isometric projection, and off-stage parking — is **implementation with no interface**: closures and inline arithmetic inside `_DollhouseViewState.build`, governed by four coupled private constants whose caveats (negative gap vs sizing gap, drift clamped to slack) are documented only in prose. The only way tests can reach the math's consequences is to pump the whole Panel, so both the widget test and the golden test hand-derive the neighbour tap point as `rect.height * 0.16` from the private `_neighbourScale`. Invariants like clamp-to-slack and off-stage parking are exercised by the shipped three-Floor House Plan but verifiable only as golden pixels.

### Evidence, file by file (all verified against 105610c)

**`panel/lib/ui/dollhouse/dollhouse_view.dart:36-50`** — four interacting private constants, each with paragraph-length caveat prose:

```dart
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
```

**`dollhouse_view.dart:73-126`** — everything the constants govern lives inside `build`: the `onStage` list (at most three Floors, lines 73–76), the `scaleOf` closure (77–78), the height-budget → `isoWidth` feedback (83–89, note the budget depends on the scale totals, so **the projection choice IS arrangement**):

```dart
      final scaleTotal = onStage.fold(0.0, (sum, f) => sum + scaleOf(f));
      final heightBudget = constraints.maxHeight /
          (scaleTotal + (onStage.length - 1) * _sizingGapFactor);
      final isoWidth = math.min(
        constraints.maxWidth * 0.78,
        math.max(200.0, (heightBudget - FloorView.wallDepth) * 2),
      );
```

…the `tops` accumulation and vertical centring (97–105), `topOf` with off-stage parking (107–117: "Off-stage Floors are parked beyond the near edge (and faded out) so selecting a neighbour slides the next one into view rather than popping it in"), and `driftOf` with the clamp-to-slack invariant (122–126):

```dart
      double driftOf(Floor floor) {
        final slack = planW * (1 - scaleOf(floor)) / 2 + left;
        return ((floor.level - expandedLevel) * _driftFactor * planW)
            .clamp(-slack, slack);
      }
```

The `_unionPlanSize` helper (174–183) computes the union extent of all Floors' Rooms and also belongs to this math.

**`panel/test/dollhouse_test.dart:32-38`** — the tap fraction hand-derived from the private constant:

```dart
    // The rect is the unscaled box; a neighbour is drawn at 0.32 about its
    // top centre, so the box centre maps to 0.16 of the height. Only the
    // slab itself takes taps — the rest of the box belongs to whichever
    // Floor is behind it.
    final rect =
        tester.getRect(find.byKey(const ValueKey('floor-upstairs')));
    await tester.tapAt(rect.topCenter + Offset(0, rect.height * 0.16));
```

**`panel/test/golden/dollhouse_golden_test.dart:43-47`** — the same derivation duplicated:

```dart
    // The neighbour's box is drawn unscaled; the slab itself sits at ~0.16
    // of its height (0.32 scale about the top centre), and only the slab
    // takes taps — see dollhouse_test.dart.
    final rect = tester.getRect(find.byKey(const ValueKey('floor-upstairs')));
    await tester.tapAt(rect.topCenter + Offset(0, rect.height * 0.16));
```

**Git history proves the injury is real, not hypothetical.** Commit `221797a` ("update dioganal neighbour floors placements", 2026-07-31) changed 135 lines of `dollhouse_view.dart` and, in the same commit, manually re-derived the tap fraction in `dollhouse_test.dart` from `0.2` to `0.16` in lockstep with the constants. The verification pass added a correction that strengthens the case: **`dollhouse_golden_test.dart` was created AFTER 221797a (in commit `70f415b`) already carrying `0.16` — it wasn't re-derived in that commit, it copied the magic number**, which shows the leak propagating rather than weakening the case. The arrangement rules currently exist in three places — `build`, a unit-test comment, a golden-test comment — with poor locality.

### The verifier's extra findings (load-bearing, keep them in mind)

- **The deletion test passes.** The math cannot be deleted — it is the feature. Deleting the proposed arrangement module would re-inline ~60 lines of coupled math into `build` and force both test files back to hand-derived fractions: complexity reappears at three sites (one production caller plus two test suites; the design skill counts tests as seam-crossers). The current shape is that failure mode already realized.
- **Not a hypothetical-adapter seam.** The repo's own pattern is pure, directly unit-tested geometry modules beside the views (`iso.dart`; `plan_geometry.dart` with `plan_geometry_test.dart`), and this extraction follows it with one implementation, no speculative variation.
- **YAGNI check passed.** The repo is days old yet this file already took a full 135-line arrangement rework with lockstep test edits; the `DollhouseView` docstring records a floor-drift prototype bake-off (a tuning culture); the shipped House Plan has three Floors (`ground-floor` level 0, `upstairs` level 1, `attic` level 2 in `panel/assets/house/house.yaml`), so off-stage parking is live behaviour covered only by golden PNGs; and ADR-0004 explicitly defers multi-floor zoom/scroll Dollhouse navigation — future work that lands exactly in this math.
- **Real new test surface, not code motion.** Clamp-to-slack only bites at narrow viewports and is untested at its edges today — no test varies viewport size. At-most-three-on-stage, parking beyond the near edge, and vertical centring become pure unit tests.
- **A cheaper fix was probed and rejected.** Tapping a `FloorView` descendant (whose `localToGlobal` applies the scale transform) would kill the `0.16` without extraction — but it fixes only the tap-point leak, not the untestable invariants or the constants' locality, so the extraction remains the right shape.
- **Two refinements the design must honour:** (1) the interface must emit the chosen `IsoProjection` — `isoWidth` depends on the height budget which depends on the scales, so projection choice is part of the arrangement's output, not something the view computes; (2) opacity ships as a per-Floor **role** that the thin view maps to `1.0 / 0.55 / 0.0`.

---

## 2. Context a fresh session needs

### Domain terms (CONTEXT.md — use these words, never the "avoid" list)

- **Panel**: "The wall-mounted touchscreen running the custom dollhouse UI." (_Avoid_: kiosk, dashboard, screen.)
- **Hub**: "The headless smart-home broker (Home Assistant) that owns device state, integrations, and automations. The Panel is its client, never its replacement."
- **Dollhouse**: "The Panel's main view — the house as stacked 2.5D isometric Floors with tappable Rooms." (_Avoid_: floor plan, map, 3D view.)
- **House Plan**: "The Panel-side description of the house's geometry — Floors with their Rooms and Walls, authored by the family. The Dollhouse renders it; the Hub never sees it."
- **Floor**: "One level of the house in the Dollhouse (e.g. basement, first floor). Floors stack; tapping one expands it. A Floor need not span the whole house footprint."
- **Room**: "A named area on a Floor. Rooms tile their Floor completely — every point belongs to exactly one Room… Tapping a Room acts on it (e.g. toggles its lights)."
- **Wall**: "A boundary segment drawn on the House Plan. Only drawn Walls exist: where none is drawn, the boundary is an open passage."
- **Device**: "A controllable or observable thing in the house (light, camera, thermostat, feeder…), pinned to a Room in the Dollhouse."
- **Popup**: "A transient full-or-partial-screen overlay on the Panel, e.g. live doorbell video on ring."

### Design vocabulary (.claude/skills/codebase-design/SKILL.md — use these words, never component/service/API/boundary)

A **module** is anything with an interface and an implementation; it is **deep** when a lot of behaviour sits behind a small interface. The **interface** is everything a caller must know — invariants and constraints included, not just signatures. A **seam** is where a module's interface lives; an **adapter** is a concrete thing satisfying an interface at a seam. Depth produces **leverage** for callers (capability per unit of interface learned) and **locality** for maintainers (change and verification concentrate in one place). The **deletion test**: delete the module — if complexity reappears across N callers, it was earning its keep. "The interface is the test surface. Callers and tests cross the same seam." And: "One adapter means a hypothetical seam. Two adapters means a real one" — this plan introduces one implementation at a seam that view + two test suites already cross, not a variation point.

### ADR constraints that bind here

- **ADR-0004** (House Plan pipeline): "Rooms tile each Floor completely — every point in exactly one Room; stairs, halls and the attached garage are Rooms. A Floor's slab renders as the union of its rooms, so partial upper floors and the protruding garage need no perimeter concept." And the deferral this plan's seam is aimed at: "Deferred, enabled by this choice: … multi-floor zoom/scroll Dollhouse navigation (any floor count already fits the schema)." The arrangement module must therefore work for any Floor count, not just three.
- **ADR-0002** (Home Assistant Hub): "Automations live in the Hub's native engine; the Panel is a pure view/command layer." This refactor is Panel-internal geometry; nothing crosses toward the Hub.
- **ADR-0001** (plain Linux kiosk): irrelevant to the code shape; only note the Panel targets a Wayland kiosk, and this Mac verifies via web build (see §8).
- The verifier recorded **no ADR conflict** for this refactor.

### Current-architecture tour (line numbers valid at 105610c)

- **`panel/lib/ui/dollhouse/dollhouse_view.dart`** (209 lines) — the Dollhouse: stacked isometric Floors, one selected. Its docstring (lines 17–20) records the design's provenance: "The arrangement below is the winner of the floor-drift prototype: at most three Floors on stage, the neighbours shrunk and drifted into the selected Floor's empty isometric corners — the one above up and to the right, the one below down and to the left." State: `_expandedFloorId` (declared line 31), initialised to the lowest level in `initState` (lines 52–59). `build` (62–172) holds all the arrangement math (see §1) and renders a `Stack` of `AnimatedPositioned` → `IgnorePointer` → `GestureDetector` → `AnimatedScale(alignment: Alignment.topCenter)` → `AnimatedOpacity` → `FloorView`, keyed `ValueKey('floor-${floor.id}')`, iterating `ordered` (Floors sorted level-descending, lines 65–66). Opacity today: `0.0` off-stage, `1.0` selected, `0.55` neighbour (lines 148–154). `_unionPlanSize` (174–183). `_selectFloor` (185–188). `_onDeviceTap` (190–208) — **plan 01's territory, untouched here**.
- **`panel/lib/ui/dollhouse/floor_view.dart`** — one Floor as an isometric slab. `static const wallDepth = 22.0;` at line 32 ("Pixel extrusion below the slab (the visible 'walls')"). Its `SizedBox` is `projection.size.width` × `projection.size.height + wallDepth` (48–50). Hit-testing defers to the painter (54–59) and `_FloorPainter.hitTest` (320–329): "Only the slab (and the plinth extruded below it) belongs to this Floor; a tap anywhere else in the box falls through" — this is why the tests must tap the slab, not the box corner.
- **`panel/lib/ui/dollhouse/iso.dart`** — `IsoProjection`, the pure 2:1 isometric projection with the `fitWidth` factory. The pattern this plan follows: pure geometry, `dart:ui` only.
- **`panel/lib/ui/dollhouse/plan_geometry.dart`** + **`panel/test/plan_geometry_test.dart`** — the other precedent: pure plan-space geometry (`outlineSegments`, `wallOutsideSide`) directly unit-tested with synthetic Rooms, no widget pumping.
- **`panel/lib/domain/house.dart`** — `House { name, floors }`, `Floor { id, name, level, rooms, walls }` (level: "0 = ground, 1 = upstairs, -1 = basement"), `Room { id, name, footprint, devices }` with `bounds` and `contains`, `Device`. No union-extent member exists on `House` today (that is plan 03's job).
- **`panel/lib/main.dart:132-137`** — the only caller: `DollhouseView(controller: controller)` inside an `Expanded` in a padded `Column`, so the `LayoutBuilder` viewport is the screen minus header and padding.
- **`panel/test/dollhouse_test.dart`** — four widget tests pumping `PanelApp` with a `FakeHub` over the shipped House Plan (`test_house.dart` loads `assets/house/house.yaml` + `devices.yaml` from disk). Test 2, `'tapping a collapsed floor expands it'`, carries the `0.16` tap.
- **`panel/test/golden/dollhouse_golden_test.dart`** + **`golden_setup.dart`** — four golden scenes at `kPanelSize = Size(1280, 800)`, PNGs in `panel/test/golden/goldens/` (`ground_floor.png`, `upstairs_selected.png`, `device_popup.png`, `hub_offline.png`). Scene 2, `'upstairs selected'`, carries the copied `0.16` tap.

---

## 3. Target design

### The module

**`FloorArrangement`** — a new deep, pure module in **`panel/lib/ui/dollhouse/floor_arrangement.dart`**, beside `iso.dart` and `plan_geometry.dart`, following the repo's established pattern of directly unit-tested pure geometry under `lib/ui/dollhouse/`. Imports: `dart:math`, `dart:ui`, `../../domain/house.dart`, `iso.dart`. **No Flutter widget imports** — that is what makes it pure and unit-testable without pumping.

### Seam placement

Just below `DollhouseView`: House Plan Floors + selected Floor + viewport in; projection + per-Floor placement out. `DollhouseView` shrinks to a thin animator (shallow by design — animation is its whole remaining job) feeding placements into `AnimatedPositioned`/`AnimatedScale`/`AnimatedOpacity`. The view and both test suites cross this same seam, which is exactly the skill's "the interface is the test surface".

### The interface (concrete Dart)

```dart
/// Where one Floor stands on the Dollhouse stage.
enum FloorRole { selected, neighbour, offStage }

/// One Floor's placement: where its unscaled box goes, how it is scaled
/// (about the box's top centre), and where the scaled box actually sits
/// on screen.
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

  /// Top-left of the *unscaled* Floor box in viewport coordinates —
  /// feeds AnimatedPositioned(left:, top:).
  final Offset boxTopLeft;

  /// Feeds AnimatedScale(scale:, alignment: Alignment.topCenter).
  final double scale;

  /// The Floor box after the top-centre scale, in viewport coordinates:
  /// where the slab visually sits. Its centre is the canonical tap point
  /// for a neighbour (replaces the hand-derived `rect.height * 0.16`).
  final Rect scaledBounds;
}

/// The Dollhouse floor-drift arrangement, decided all at once: the
/// projection that fits the height budget, which Floors are on stage,
/// and every Floor's placement (off-stage Floors included — they park
/// beyond the near edge so selection slides rather than pops).
///
/// Winner of the floor-drift prototype: at most three Floors on stage,
/// the neighbours shrunk and drifted into the selected Floor's empty
/// isometric corners — the one above up-right, the one below down-left.
class FloorArrangement {
  factory FloorArrangement.fit({
    required House house,
    required String selectedFloorId,
    required Size viewport,
    required double wallDepth, // FloorView.wallDepth: box height is projection.size.height + wallDepth
  }) { /* all the math from build */ }

  /// Sized against the height budget — the isoWidth choice is entangled
  /// with the scale totals, so the projection IS part of the arrangement.
  final IsoProjection projection;

  /// Every Floor of the House, level-descending (the Stack's child order
  /// today). Off-stage Floors are present with parked positions so
  /// AnimatedPositioned state survives and slides stay smooth.
  final List<FloorPlacement> placements;

  FloorPlacement placementOf(String floorId);
}
```

`scaledBounds` math (must reproduce the top-centre scale exactly): with `planW = projection.size.width`, `floorH = projection.size.height + wallDepth`:

```dart
Rect.fromLTWH(boxTopLeft.dx + planW * (1 - scale) / 2, boxTopLeft.dy,
    planW * scale, floorH * scale)
```

Sanity identity: for a neighbour, `scaledBounds.center == unscaledRect.topCenter + Offset(0, floorH * scale / 2)`, i.e. exactly today's `rect.topCenter + Offset(0, rect.height * 0.16)` with `scale = 0.32`. The new tests must land on the identical pixel — that is the equivalence proof.

### What hides inside (implementation, invisible at the seam)

- The four constants, moved with their caveat doc comments **verbatim**: `_neighbourScale = 0.32`, `_driftFactor = 0.26`, `_gapFactor = -0.225`, `_sizingGapFactor = 0.03`.
- The at-most-three on-stage rule (`(floor.level - expandedLevel).abs() <= 1`).
- The height-budget → `isoWidth` feedback, including the `0.78 * maxWidth` cap and the `max(200.0, …)` floor.
- The tops accumulation with negative gap, `stackH`, and the `topPad` vertical centring clamp.
- Off-stage parking (`topPad - floorH * _neighbourScale` above; `topPad + stackH` below).
- Drift clamped to slack (`planW * (1 - scale) / 2 + left`), which guarantees nothing leaves the viewport horizontally.
- The union plan extent over all Floors' Rooms (private `_unionPlanSize`, moved from the view — see decision D3 / plan 03).

### Who calls it

1. `_DollhouseViewState.build` — computes one `FloorArrangement.fit(...)` per layout pass and maps each `FloorPlacement` onto the animated widget stack; maps `role` to opacity (`selected → 1.0`, `neighbour → 0.55`, `offStage → 0.0`), to `IgnorePointer(ignoring: role == FloorRole.offStage)`, to `onTap: role == FloorRole.selected ? null : () => _selectFloor(placement.floor)`, and to `expanded: role == FloorRole.selected`.
2. `panel/test/floor_arrangement_test.dart` (new) — invariants through the interface, no widget pumping.
3. `panel/test/dollhouse_test.dart` and `panel/test/golden/dollhouse_golden_test.dart` — derive the neighbour tap point from `placementOf('upstairs').scaledBounds.center` instead of hardcoding `0.16`.

### What gets deleted

From `dollhouse_view.dart`: the four constants (36–50), `ordered`/`expandedLevel`/`onStage`/`scaleOf` (64–78), the entire budget/projection/tops/parking/drift block (81–126, including the leading "Fit to width" comment at 81–82), `_unionPlanSize` (174–183), and the `dart:math` + `iso.dart` imports if the analyzer confirms they are now unused. From both test files: the `0.16` lines and their derivation comments.

### Before/after dependency sketch

```
BEFORE
  dollhouse_view.dart/_DollhouseViewState.build
      (deep implementation, NO interface: onStage set, scaleOf/topOf/driftOf
       closures, heightBudget→isoWidth feedback, 4 coupled constants,
       off-stage parking, opacity + IgnorePointer wiring)
      --constructs--> iso.dart/IsoProjection   (deep, pure, small interface)
      --renders via--> floor_view.dart
  dollhouse_test.dart          --re-derives--> 0.16 from private _neighbourScale
  golden/dollhouse_golden_test.dart --copies--> the same 0.16 derivation
  plan_geometry.dart (deep, pure, unit-tested) sits beside as the pattern
      build does not follow

AFTER
  floor_arrangement.dart  (NEW, deep, pure: hides 4 constants, height
      budgeting, parking, clamp-to-slack)
      interface: Floors + selected Floor + viewport in;
                 projection + per-Floor placement out
      --uses internally--> iso.dart
  dollhouse_view.dart (thin animator, shallow by design)
      --calls--> floor_arrangement, feeds AnimatedPositioned/Scale/Opacity
  floor_arrangement_test.dart --tests invariants through the interface-->
      floor_arrangement
  dollhouse_test.dart + golden test --ask for scaledBounds.center-->
      floor_arrangement          (magic 0.16 deleted)
```

---

## 4. Decision points

**D1 — Role vs opacity in the interface.**
Options: (a) `FloorPlacement` carries a `FloorRole` and the view maps role → opacity/interactivity/`expanded`; (b) the arrangement emits opacity (and an `interactive` flag) directly.
**Recommended: (a)**, per the verifier's explicit refinement. The `0.55` neighbour dimming is presentation, owned by the animator; role is arrangement truth and drives three view concerns (opacity, `IgnorePointer`, `expanded`) from one small enum. No behaviour change either way.

**D2 — Who owns `wallDepth` (22.0).**
Options: (a) pass `FloorView.wallDepth` into `FloorArrangement.fit` as a required parameter; (b) move the constant into `floor_arrangement.dart` and have `FloorView` read it from there.
**Recommended: (a)**. The extrusion is a fact about what `FloorView` paints; the arrangement only needs the number to know the box height. Passing it keeps the pure module free of widget imports and keeps ownership where the pixels are. Cost: one extra parameter at two call sites (view + test helper).

**D3 — Union plan extent, pending plan 03.**
Options: (a) move `_unionPlanSize` into `floor_arrangement.dart` as a private helper now, with a comment naming the plan-03 swap; (b) block this plan on plan 03; (c) call a domain member if plan 03 already landed.
**Recommended: (a), switching to (c) if at execution time `House` already exposes a union-extent member** (check `panel/lib/domain/house.dart` and `docs/plans/03-*.md` status first). Per the coordination notes: if 03 landed, call it; otherwise compute the extent privately inside floor_arrangement and note the later swap. Either way the extent stays out of this module's interface.

**D4 — How the widget/golden tests derive the tap point.**
Options: (a) tests construct the same `FloorArrangement` the view builds (viewport from `tester.getSize(find.byType(DollhouseView))`) and tap `getTopLeft(DollhouseView) + placementOf(id).scaledBounds.center`, via a small shared helper; (b) tap a `FloorView` descendant and let `localToGlobal` apply the scale transform (the verifier's probed "cheaper fix"); (c) expose a test-only getter on `_DollhouseViewState`.
**Recommended: (a)**. (b) was explicitly rejected by the verifier — it fixes only the tap-point leak, not the untestable invariants or the constants' locality — and once the module exists, (a) crosses the same seam the view does. (c) tests past the interface, which the skill forbids ("if you want to test *past* the interface, the module is probably the wrong shape").

**D5 — Input shape: `House` vs `List<Floor>`.**
Options: (a) `required House house`; (b) `required List<Floor> floors` + selected id.
**Recommended: (a)**. The union extent spans *all* Floors of the House (that is why a partial attic doesn't shrink the projection), and plan 03 will hang the extent off `House` — taking `House` makes that swap a one-liner. `List<Floor>` is marginally more minimal but severs the object the extent belongs to.

**D6 — Zero-pixel-change contract (ratify explicitly).**
This is a pure extraction: the four constants keep their exact values (0.32, 0.26, −0.225, 0.03), the opacity map stays 1.0/0.55/0.0, durations and curves stay `300ms` `easeInOutCubic`. **All four goldens in `panel/test/golden/goldens/` must pass unmodified — never run `--update-goldens` for this plan.** A golden diff means the extraction has a bug, not that the golden is stale. (Contrast with plan 01, where a kind-keyed affordance deliberately CHANGES current behaviour and records it; here the analogous record is: nothing changes.)

---

## 5. Step-by-step implementation

Each step leaves `cd panel && flutter analyze && flutter test` green.

**Step 0 — Re-verify the ground.**
`git log --oneline -5` (this plan was written at 105610c). Re-locate the line numbers cited in §1–§2 if the file has moved. Check whether plan 03 landed: does `panel/lib/domain/house.dart` have a union-extent member? Re-list `docs/plans/` and check the states of plans 01, 02, 03, 07 and 08 (at fact-check time only 01, 05, 07 and 08 existed on disk — see §9). Resolve D3 accordingly.

**Step 1 — Create the module (no callers yet).**
New file `panel/lib/ui/dollhouse/floor_arrangement.dart` containing `FloorRole`, `FloorPlacement`, `FloorArrangement` exactly as specified in §3. Move the math from `build` **verbatim** — the four constants with their full doc comments, the on-stage rule, `scaleTotal`/`heightBudget`/`isoWidth`, `IsoProjection.fitWidth(_unionPlanSize(house), isoWidth)`, `floorH`/`planW`/`left`/`gap`, the tops loop, `stackH`/`topPad`, parking, drift-clamp — renaming locals only where they become fields. Move `_unionPlanSize` in as a private function (D3). Move the "winner of the floor-drift prototype" paragraph from `DollhouseView`'s docstring onto `FloorArrangement`'s, leaving a one-line pointer behind. Placements: every Floor, level-descending (`b.level.compareTo(a.level)`), each with `role` (`selected` if id matches; `neighbour` if `(level - selectedLevel).abs() <= 1`; else `offStage`), `boxTopLeft = Offset(left + drift, top)`, `scale`, and `scaledBounds` per the §3 formula. Tree stays green: nothing imports the new file yet.

**Step 2 — Unit-test the module.**
New file `panel/test/floor_arrangement_test.dart` (cases named in §6). Pure `test()` bodies — no `testWidgets`, no pumping. Use synthetic Houses (the `plan_geometry_test.dart` style: small helper builders) plus one case on the shipped plan via `test_house.dart`'s `loadTestHouse()`. Run `flutter test test/floor_arrangement_test.dart`.

**Step 3 — Rewire the view.**
In `dollhouse_view.dart`: `build` computes `final arrangement = FloorArrangement.fit(house: house, selectedFloorId: _expandedFloorId, viewport: Size(constraints.maxWidth, constraints.maxHeight), wallDepth: FloorView.wallDepth);` inside the existing `LayoutBuilder`, then renders `for (final placement in arrangement.placements)` with the same keyed `AnimatedPositioned` tree, mapping `placement.boxTopLeft`, `placement.scale`, `arrangement.projection`, and `placement.role` as in §3 "Who calls it". Delete everything listed in §3 "What gets deleted". Keep `_expandedFloorId`, `initState`, `_anim`, `_selectFloor`, and `_onDeviceTap` (lines 190–208) byte-identical — plan 01 owns `_onDeviceTap`. Run the **full** suite: every existing widget test and all four goldens must pass with zero golden updates. This is the equivalence gate (D6).

**Step 4 — Kill the 0.16.**
New file `panel/test/dollhouse_geometry.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/domain/house.dart';
import 'package:panel/ui/dollhouse/dollhouse_view.dart';
import 'package:panel/ui/dollhouse/floor_arrangement.dart';
import 'package:panel/ui/dollhouse/floor_view.dart';

/// The on-screen centre of a Floor's scaled slab box, derived from the
/// same FloorArrangement the DollhouseView builds — never hand-derived.
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
```

In `dollhouse_test.dart` `'tapping a collapsed floor expands it'` and in `dollhouse_golden_test.dart` `'upstairs selected'`, replace the `getRect`/`tapAt(rect.topCenter + Offset(0, rect.height * 0.16))` pair and its derivation comment with:

```dart
    await tester.tapAt(floorSlabCentre(tester,
        house: controller.house,
        selectedFloorId: 'ground-floor',
        floorId: 'upstairs'));
```

(the golden test currently discards `fakeHub()`'s return value inside `pumpPanel(tester, fakeHub())`; `HubController` exposes `house` as a public final field — `hub_controller.dart:21` — so the smallest change is `final controller = fakeHub(); await pumpPanel(tester, controller);` and then `house: controller.house`, no second `loadTestHouse()` needed). Run the full suite; the goldens must still pass unmodified because the tap lands on the identical pixel (§3 sanity identity).

**Step 5 — Final sweep.**
Confirm `dollhouse_view.dart` has no leftover arrangement remnants and no unused imports; confirm the string `0.16` and the phrase "0.32 scale about the top centre" are gone from `panel/test/` (`grep -rn "0.16" panel/test/`); run the §8 verification block.

---

## 6. Test plan

### New: `panel/test/floor_arrangement_test.dart`

Synthetic-House helper in the file (mirroring `plan_geometry_test.dart`'s `_room` helper): a `_house(int floorCount)` builder with one square Room per Floor. Cases:

1. `'at most three Floors are on stage'` — five-Floor synthetic House; for every selected Floor, count placements with `role != FloorRole.offStage`; expect ≤ 3, and exactly the selected Floor ± 1 level.
2. `'selected Floor is full size, neighbours share one smaller scale'` — selected `scale == 1.0`; both neighbours equal and `< 1.0` (pins the shape, not the private 0.32).
3. `'neighbour above drifts right, the one below drifts left'` — compare each neighbour's `scaledBounds.center.dx` against the selected Floor's (the up-right / down-left corners of the docstring).
4. `'drift never pushes a Floor outside the viewport, even when narrow'` — sweep viewport widths (e.g. 320, 480, 700, 1000, 1232) at fixed height; for every placement assert `scaledBounds.left >= 0 && scaledBounds.right <= viewport.width`. **This is the clamp-to-slack edge the verifier flagged as untested today — no existing test varies viewport size.**
5. `'off-stage Floors park beyond the near edge of the stack'` — five-Floor House, middle selected: the Floor two-above has `scaledBounds.bottom` at or above the topmost on-stage `scaledBounds.top`; two-below parks below the bottommost.
6. `'the on-stage stack centres vertically in the viewport'` — top slack ≈ bottom slack (within an epsilon) at a realistic viewport (1232 × ~700, the size the Panel actually gives the Dollhouse at `kPanelSize`).
7. `'placements cover every Floor, ordered level-descending'` — the Stack's child order and AnimatedPositioned-key stability depend on this: off-stage Floors must be present every build or the slide-in animation degrades to a pop.
8. `'the projection never exceeds 78% of the viewport width'` — pins the width cap.
9. `'shipped House Plan: ground selected parks the attic'` — `loadTestHouse()`; `placementOf('attic').role == FloorRole.offStage`, `'upstairs'` is a neighbour — ties the module to the live three-Floor behaviour currently guarded only by golden pixels.

### Changed tests

- `panel/test/dollhouse_test.dart` — `'tapping a collapsed floor expands it'` drops the `0.16` derivation for `floorSlabCentre` (step 4). The other three tests untouched.
- `panel/test/golden/dollhouse_golden_test.dart` — `'upstairs selected'` likewise. The other three scenes untouched.
- Nothing dies; no test file is deleted.

### Golden impact

**None.** Goldens live in `panel/test/golden/goldens/` (`ground_floor.png`, `upstairs_selected.png`, `device_popup.png`, `hub_offline.png`) and would be updated via `flutter test --update-goldens test/golden` — **do not run that for this plan** (D6). All four must pass as-is at steps 3, 4 and 5.

### Behaviours pinned for the first time

At-most-three-on-stage; neighbour drift directions; clamp-to-slack across viewport widths; off-stage parking side and position; vertical centring; full-coverage level-descending placement order; the 0.78 width cap. Today every one of these is reachable only through golden pixels or not at all.

---

## 7. Verification

```sh
cd panel && flutter analyze && flutter test
```

Both must be clean at the end of every step. For a live look at the Panel: **this Mac has Flutter via brew but NO Xcode — any live check is `cd panel && flutter run -d chrome` (web build), never `-d macos`.** The golden suite (`flutter test test/golden`) is the cheapest way to eyeball the Dollhouse without running anything (`goldens/*.png` regenerate in seconds — but for this plan they must not change; use `panel/test/golden/failures/*_isolatedDiff.png` to inspect any unexpected diff).

---

## 8. Non-goals

Discipline notes carried over from the verifier — each deferred item keeps its written-down trigger:

- **No change to tap-decision logic.** `_onDeviceTap` (dollhouse_view.dart:190–208) stays byte-identical; plan 01 rewrites it. This extraction is layout-only.
- **No visual or tuning change of any kind.** Constants, opacities, durations, curves all keep their exact values; goldens must not move (D6).
- **No domain move of the union extent.** The extent stays a private helper here; plan 03 owns lifting it onto `House`. Trigger to swap: plan 03 landing (a union-extent member appearing on `House`).
- **No second adapter, no variation point.** One implementation behind the seam. ADR-0004's deferred multi-floor zoom/scroll Dollhouse navigation is the *reason the seam is placed here* — it will land as arrangement-rule changes behind this interface instead of another 135-line rework of `build` — but nothing is pre-built for it. Trigger: that feature actually starting.
- **No FloorView or plan_geometry changes.** Slab painting, glass walls, hit-testing (`deferToChild` + painter `hitTest`) are untouched; only the tap-*point derivation* in tests changes, not what takes taps.
- **No golden-harness restructuring.** `golden_setup.dart` and the Hub faking in the golden suite belong to other plans — 02 per the coordination notes, plus 07 (`_OfflineHub`/offline scene) and 08 (shared fixture helper) per the on-disk plans (§9).

---

## 9. Cross-plan coordination

There are 8 plans in this review series, `docs/plans/01-*.md` … `docs/plans/08-*.md` (not all on disk yet — see the fact-check note below). Coordination notes given verbatim with this plan:

- **Plan 03** moves the House union extent into the domain (House interface). If 03 landed, call it; otherwise compute the extent privately inside floor_arrangement and note the later swap. (This plan: decision D3, step 0 check, non-goal trigger.)
- **Plan 01** rewrites dollhouse_view's `_onDeviceTap` — your extraction is layout-only; explicitly leave tap-decision logic untouched. (Both plans edit `dollhouse_view.dart`, but in disjoint regions — `build` here, `_onDeviceTap` there — so land order does not matter; merges are textual. Plan 01 also adds one test to `dollhouse_test.dart`, again disjoint from the tap line this plan edits.)
- **Plan 02** rewrites the golden suite's Hub faking; you change how the widget+golden tests derive the neighbour tap point (ask the arrangement instead of hardcoding 0.16) — same files, disjoint aspects. (This plan touches only the tap lines inside `'tapping a collapsed floor expands it'` and `'upstairs selected'`; plan 02 touches controller/fake construction. If plan 02 lands first and renames the local `fakeHub()`/controller plumbing, re-point the `house:` argument of `floorSlabCentre` at whatever plan 02 exposes.)

Additional discovery from writing this plan: plan 02's promise that goldens may be regenerated for *its* changes does not license golden updates *here* — if both plans are in flight, regenerate goldens only from plan 02's branch, never this one.

Fact-check against the plans on disk at 105610c: only `01-device-presentation-module.md`, `05-floor-arrangement-module.md` (this plan), `07-hub-status-three-state.md` and `08-panel-boot-module.md` exist yet; 02, 03, 04 and 06 may land later, so step 0 must re-list `docs/plans/`. Contrary to the original note that 06–08 had no contact, **plans 07 and 08 DO touch this plan's test files**:

- **Plan 07** edits `dollhouse_golden_test.dart`'s `_OfflineHub` stub and the `'hub unreachable'` scene, and generates a new `hub_gave_up.png` golden — disjoint from the `'upstairs selected'` tap lines this plan edits; merges are textual.
- **Plan 08** deletes the `makeController()` factory in `dollhouse_test.dart` and the `fakeHub()` factory in `dollhouse_golden_test.dart` in favour of a shared fixture helper, and regenerates `hub_offline.png`. If plan 08 lands first, re-point `floorSlabCentre`'s `house:` argument at whatever its shared fixture exposes (same rule as for plan 02). Its golden regeneration licenses `hub_offline.png` only — never the scenes this plan must keep pixel-identical.

Plans 04 and 06 are not on disk and have no known contact with the files this plan touches.

---

## 10. Sources

- `/Users/dmorozov/Work/ITConsulting/SmartHome/CONTEXT.md` — domain language (Panel, Hub, Dollhouse, House Plan, Floor, Room, Wall, Device, Popup).
- `/Users/dmorozov/Work/ITConsulting/SmartHome/.claude/skills/codebase-design/SKILL.md` — deep module, interface, seam, adapter, depth, leverage, locality, deletion test.
- `/Users/dmorozov/Work/ITConsulting/SmartHome/docs/adr/0001-plain-linux-kiosk-not-fuchsia-or-chromeos.md`, `0002-home-assistant-headless-hub.md`, `0003-zigbee-z2m-not-matter-thread.md`, `0004-house-plan-sweet-home-3d-yaml-pipeline.md` — binding constraints quoted in §2.
- Originating architecture review: candidate 5 ("Floor arrangement math trapped in DollhouseView's build closure, its constants re-derived by hand in two test files") plus its adversarial verification verdict (Strength: Strong, no ADR conflict). The review itself was a temp HTML artifact and is ephemeral; every load-bearing fact from it is reproduced in §1.
- Git evidence: `git show 221797a` (135-line `dollhouse_view.dart` rework, `tapAt` fraction 0.2 → 0.16 in the same commit); `git show 70f415b` (golden test created already carrying the copied 0.16).
