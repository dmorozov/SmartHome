# Panel — the dollhouse UI

The custom Flutter application for the wall touchscreen: 2.5D isometric stacked
Floors, neumorphic styling, tap-to-expand, Device pins with live state (see
`../CONTEXT.md` for the domain language).

**Status: dollhouse prototype, fake hub.** Scaffolded ahead of the cage spike —
safe because the spike risk lives in the Linux embedder/compositor layer, not in
Dart code, and even the worst-case fallback (web kiosk, ADR-0001) reuses this
codebase via the Flutter Web build. What exists:

- Stacked isometric Floors, tap a collapsed Floor to expand it
- Rooms glow with light state; tapping a Room toggles its lights
- Device pins with live readings (thermostat °C, Emporia watts); tapping a
  binary Device toggles it, cameras/doorbell open the Popup (go2rtc live view
  placeholder), everything else shows its state
- `FakeHub` drives it all — seeded from the real device fleet, drifts readings
  so the UI visibly lives

Still to come: the real Home Assistant WebSocket `HubClient` (developed against
the `../hub/` stack once it runs on the laptop), the real house layout, the
actual design system, and the spike-app migrations (multi-touch debug screen,
fullscreen/cursor runner patches) once the spike passes.

## Layout

- `lib/domain/` — `House`/`Floor`/`Room`/`Device` structure + `DeviceState`
  (CONTEXT.md language; geometry is Panel-side config, the Hub never sees it)
- `lib/data/` — `HubClient` interface, `FakeHub`, `demo_house.dart`
  (**placeholder layout** — edit footprints/positions to match the real house)
- `lib/ui/` — theme, `HubController` (ChangeNotifier over `HubClient`),
  `dollhouse/` (iso projection, floor slab painter, stacking view), Popup

## Run

| Target | Command | Works on |
|---|---|---|
| Web | `flutter run -d chrome` | this Mac, today |
| macOS desktop | `flutter run -d macos` | Mac — needs full Xcode (App Store) + CocoaPods, not just Command Line Tools |
| Linux desktop | `flutter run -d linux` | the dev laptop (Ubuntu) — also the kiosk/cage path |

Tests: `flutter test` (FakeHub semantics + widget interaction tests).
`FakeHub(house, driftEvery: Duration.zero)` disables the drift timer for
deterministic tests.
