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

Each Device names its Hub entity in `bindings.yaml` (`entity:`); how that
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
45° corners off), don't draw walls across open passages. Open it with
`tool/sh3d.sh`, not the Dock icon, and drop a marker from the SmartHome
library wherever a Device goes (`tool/sh3d_marker_library.py` builds that
library; ADR-0005). Then:

```sh
python3 tool/sh3d_to_yaml.py MyHouse.sh3d -o assets/house/house.yaml
```

- `assets/house/house.yaml` — **generated geometry, never hand-edit**. The
  converter errors on diagonals, overlapping rooms and duplicate room names,
  and warns on unwalled boundaries and non-tiling floors.
  Its `devices:` section is the Placements read out of the drawing — Key,
  kind, name, and the Room and position the converter computed.
- `assets/house/bindings.yaml` — **hand-maintained, and the only file you
  type into**: two lines per Device, keyed by the Key you typed in Sweet
  Home 3D. `entity:` is which Hub entity it is (omit it and the pin renders
  with unknown state); `connectivity:` is `local` or `cloud`. The converter
  never touches it. Delete a marker without deleting its binding and the
  loader refuses to start, naming the leftover.
- Current placeholder: `tool/fixtures/placeholder-house.Home.xml` (crafted
  approximation of the real house — ground floor, upstairs, and an unwalled
  attic) run through the converter; the shipped `house.yaml` is exactly what
  it emits, and `tool/test_sh3d_to_yaml.py` keeps it that way.
  `tool/fixtures/AlpsHotel.Home.xml` is a real Sweet Home 3D export that
  breaks the rules on purpose — it must be rejected, nothing written.

## Layout

- `lib/domain/` — `House`/`Floor`/`Room`/`Wall`/`Device` + `DeviceState`
  (CONTEXT.md language; geometry is Panel-side config, the Hub never sees it)
- `lib/data/` — `HubClient` interface, `FakeHub`, `house_loader.dart` (parses
  the two House Plan YAML assets)
- `lib/ui/` — theme, `HubController` (ChangeNotifier over `HubClient`),
  `dollhouse/` (iso projection, floor arrangement, floor scene, slab
  painter, stacking view), Popup
- `lib/diagnostics/` — structured logging (below)
- `tool/` — the Sweet Home 3D converter + fixtures

## Run

| Target | Command | Works on |
|---|---|---|
| Web | `flutter run -d chrome` | this Mac, today |
| macOS desktop | `flutter run -d macos` | Mac — needs full Xcode (App Store) + CocoaPods, not just Command Line Tools |
| Linux desktop | `flutter run -d linux` | the dev laptop (Ubuntu) — also the kiosk/cage path |

Screenshot the web build without a visible browser (handy for checking the
kiosk's real resolution, and for agents/CI):

```sh
flutter build web --profile && (cd build/web && python3 -m http.server 8100 &)
tool/shot.sh http://localhost:8100/ /tmp/panel.png 1920 1080
```

## Diagnostics

The Panel ends up on a wall with no keyboard and nobody watching a console,
so it explains itself in one greppable line per event:

A healthy start against the development Hub — verbatim from the browser
console, from the `flutter build web` command above plus `--dart-define=LOG=info`:

```
[panel] I panel.start hub=ha mode=profile platform=web log=info
[panel] I house.loaded name="Demo House" floors=3 rooms=15 devices=33 bound=33
[panel] I hub.configured url=http://localhost:8123 token=set
[panel] I hub.connecting url=ws://localhost:8123/api/websocket
[panel] I hub.connected url=ws://localhost:8123/api/websocket devices=33
[panel] I hub.snapshot entities=66 bound=33 missing=0
```

and the same run when it is not healthy:

```
[panel] W hub.missing_entities ids=sensor.oven,climate.ecobee
[panel] W hub.state_unusable device=washer entity=sensor.lg_washer state=unavailable
[panel] I hub.state_recovered device=washer entity=sensor.lg_washer
[panel] W hub.reconnecting in_ms=4000 was_connected=true
[panel] E hub.auth_invalid reason="Invalid access token or password"
```

Same lines everywhere the Panel runs: `flutter run`, the browser console
(filter on the `[panel]` prefix), `journalctl -u panel` on the appliance.
`hub.snapshot` / `hub.missing_entities` are the ones that earn their keep —
a Device pin that never fills in is otherwise completely silent, and the
cause is always an `entity:` the Hub has never heard of.

Level is `debug` in debug builds and `info` in release; override with
`--dart-define=LOG=debug|info|warn|error|off`. Debug adds every state
change and every tap. `Log.installErrorHandlers()` routes framework and
uncaught errors through the same channel, so a crash leaves a `[panel] E`
line rather than only a red screen nobody is standing in front of.

**Never log a secret** — the Hub token in particular. `main.dart` logs
`token=set`, not the token. (Home Assistant's own websocket debug logging
does not observe this; see `../hub/dev/README.md`.)

## Tests

`flutter test` — FakeHub semantics, the House Plan loader, the HA
WebSocket protocol, widget interaction, and the goldens below.
`test/house_pipeline_contract_test.dart` runs the converter and feeds its
output straight into the loader, so the two ends of the ADR-0004 seam
cannot drift apart; it skips where `python3` is absent.
`FakeHub(house, driftEvery: Duration.zero)` disables the drift timer for
deterministic tests. `test/flutter_test_config.dart` quiets logging to
warnings for the whole suite.

`test/golden/` renders the whole Panel to PNGs — headlessly, no browser and
no server — for four scenes: ground floor, upstairs selected, a Device
Popup, and an unreachable Hub. They catch unintended changes to the
dollhouse's shape, and on failure write `failures/*_isolatedDiff.png`
showing exactly what moved.

```sh
flutter test test/golden                    # check
flutter test --update-goldens test/golden   # regenerate, then look at them
python3 tool/test_sh3d_to_yaml.py           # the converter's own suite
```

Regenerating is also the fastest way to just *see* the Panel while working
on it. Two things make the images faithful that flutter_test does not do by
default: real fonts (loaded from the Flutter SDK's cache, so no font
binaries in the repo) and real shadows (`debugDisableShadows`, without
which the neumorphic look disappears).

Matching is exact, and should stay close to it: at 1280×800 even a 1%
tolerance is ~10,000 pixels while a whole 34px Device pin is only ~1,150,
so a loose tolerance would let an entire pin change unnoticed. The images
are host-rendered, so if they ever go permanently red on the Linux laptop
rather than here, raise `tolerance` on `setUpPanelGoldens` as little as
possible. Either way: regenerate and eyeball the diff, don't rubber-stamp
a failure.
