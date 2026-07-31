# Panel — the dollhouse UI

The custom Flutter application for the wall touchscreen: 2.5D isometric stacked
Floors, neumorphic styling, tap-to-expand, Device pins with live state (see
`../CONTEXT.md` for the domain language).

**Status: dollhouse prototype, fake hub.** Scaffolded ahead of the cage spike —
safe because the spike risk lives in the Linux embedder/compositor layer, not in
Dart code, and even the worst-case fallback (web kiosk, ADR-0001) reuses this
codebase via the Flutter Web build. What exists:

- Stacked isometric Floors with full-height translucent "glass" walls
  (winner of the walls prototype — variants preserved on the
  `prototype/dollhouse-walls` branch)
- At most three Floors on stage: the selected one at full size, its
  immediate neighbours shrunk and tucked into the empty isometric corners
  (the Floor above up and to the right, the one below down and to the
  left). Tap a neighbour to select it and the next Floor along slides in;
  only the slab takes taps, so the overlapping boxes don't steal from each
  other. Winner of the floor-drift prototype
- Rooms are rectilinear polygons tiling each Floor; a Floor's slab is the
  union of its Rooms (partial upper floors and the protruding garage just
  work); Walls are data — an undrawn boundary renders as an open passage
- Rooms glow with light state; tapping a Room toggles its lights
- Device pins with live readings (thermostat °C, Emporia watts); tapping a
  binary Device toggles it, cameras/doorbell open the Popup (go2rtc live view
  placeholder), everything else shows its state
- Two Hubs behind one interface: `FakeHub` (in-memory, seeded from the real
  fleet, drifts readings so the UI visibly lives) and `HaHubClient` (the real
  Home Assistant WebSocket API). Pick with `--dart-define=HUB=fake|ha`; the
  header badge names the Hub and shows whether it is reachable

Still to come: the real house drawing (the pipeline below is built; the
shipped House Plan is a placeholder resembling it), the actual design system,
Popup controls beyond toggling (thermostat setpoint, camera streams), and the
spike-app migrations (multi-touch debug screen, fullscreen/cursor runner
patches) once the spike passes.

## Talking to the Hub

`HubClient` has two implementations; `lib/main.dart` picks one at build time.

```sh
flutter run -d chrome                       # FakeHub (default)
flutter run -d chrome --dart-define=HUB=ha \
  --dart-define=HA_URL=http://localhost:8123 \
  --dart-define=HA_TOKEN="$(cat ../hub/dev/token)"
```

`HaHubClient` authenticates with a long-lived token, seeds from `get_states`,
follows `state_changed`, and commands through `homeassistant.toggle` (which
spans domains, so the Panel needs no per-domain knowledge). It reconnects
forever with backoff — a wall display has to recover from a Hub restart with
nobody there to press anything.

Each Device names its Hub entity in `devices.yaml` (`entity:`); how that
entity is read depends on the **Device's kind**, not the entity's domain, so a
washer behind a `sensor.*` and one behind a vendor integration both fold into
a `StatusState`. Devices without an `entity:` render with unknown state.

Run a Home Assistant to develop against — on this Mac, no appliance needed:
[`../hub/dev/README.md`](../hub/dev/README.md).

## House Plan pipeline (ADR-0004)

**Full step-by-step runbook: [HOUSE-PLAN.md](HOUSE-PLAN.md)** — drawing
rules, converter errors and fixes, and how to add/move Devices.

Short version: draw the house in [Sweet Home 3D](https://www.sweethome3d.com)
— one level per Floor, name every room in-tool, right angles only (square
45° corners off), don't draw walls across open passages. Then:

```sh
python3 tool/sh3d_to_yaml.py MyHouse.sh3d -o assets/house/house.yaml
```

- `assets/house/house.yaml` — **generated geometry, never hand-edit**. The
  converter errors on diagonals, overlapping rooms and duplicate room names,
  and warns on unwalled boundaries and non-tiling floors.
- `assets/house/devices.yaml` — **hand-maintained**: each Device references a
  room id (slugified room name) with a position in meters. The converter
  never touches it; renaming a room in the drawing makes the loader point at
  the missing slug by name.
- Current placeholder: `tool/fixtures/placeholder-house.Home.xml` (crafted
  two-storey approximation of the real house) run through the converter.
  `tool/fixtures/AlpsHotel.Home.xml` is a real Sweet Home 3D export used to
  smoke-test the parser.

## Layout

- `lib/domain/` — `House`/`Floor`/`Room`/`Wall`/`Device` + `DeviceState`
  (CONTEXT.md language; geometry is Panel-side config, the Hub never sees it)
- `lib/data/` — `HubClient` interface, `FakeHub`, `house_loader.dart` (parses
  the two House Plan YAML assets)
- `lib/ui/` — theme, `HubController` (ChangeNotifier over `HubClient`),
  `dollhouse/` (iso projection, plan geometry, floor slab painter, stacking
  view), Popup
- `tool/` — the Sweet Home 3D converter + fixtures

## Run

| Target | Command | Works on |
|---|---|---|
| Web | `flutter run -d chrome` | this Mac, today |
| macOS desktop | `flutter run -d macos` | Mac — needs full Xcode (App Store) + CocoaPods, not just Command Line Tools |
| Linux desktop | `flutter run -d linux` | the dev laptop (Ubuntu) — also the kiosk/cage path |

Tests: `flutter test` (FakeHub semantics + widget interaction tests).
`FakeHub(house, driftEvery: Duration.zero)` disables the drift timer for
deterministic tests.
