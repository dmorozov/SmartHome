# Panel — the dollhouse UI

The custom Flutter application for the wall touchscreen: 2.5D isometric stacked
Floors, neumorphic styling, tap-to-expand, Device pins with live state (see
`../CONTEXT.md` for the domain language).

**Status: dollhouse prototype, fake hub.** Scaffolded ahead of the cage spike —
safe because the spike risk lives in the Linux embedder/compositor layer, not in
Dart code, and both targets reuse this codebase.

**Two targets, and neither is a dev loop** (owner decision, 2026-08-04). The
Flutter/cage **appliance is the primary target and must play video** — it is
the wall. The **web build is not merely ADR-0001's if-the-spike-fails
fallback** any more: it is that fallback *and* the shape a second, in-house
touchscreen is planned to take, so it is a shipping target in its own right
and is held to the same bar. Anything that reads "playback is web-only" or
"non-web keeps the placeholder" predates this and is wrong; see
[Live video in the Popup](#live-video-in-the-popup) for the two transports
that came out of it. What exists:

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
  binary Device toggles it, cameras/doorbell open the Popup, everything else
  shows its state — and the thermostat's Popup carries −/+ setpoint controls
  (dial, one debounced `climate.set_temperature`, the number confirmed by the
  Hub's echo or visibly taken back)
- The Popup asks go2rtc for that Device's `stream:` and drops it again on
  close; a doorbell press opens the same Popup unprompted and it closes
  itself after 30 s (and after 2 minutes however many dings extend it).
  Both targets have a real player behind that seam — MJPEG over HTTP on the
  appliance, MSE over a WebSocket in a browser — each verified against a live
  go2rtc, and the browser one against the **real Ring doorbell**
  ([Live video in the Popup](#live-video-in-the-popup))
- Two Hubs behind one interface: `FakeHub` (in-memory, seeded from the real
  fleet, drifts readings so the UI visibly lives) and `HaHubClient` (the real
  Home Assistant WebSocket API). Pick with `HUB=fake|ha` in the environment,
  or `--dart-define=HUB=fake|ha` (the only route on web); the header badge
  names the Hub and shows whether it is reachable

Still to come: the real house drawing (the pipeline below is built; the
shipped House Plan is a placeholder resembling it), the actual design system,
and the spike-app migrations (multi-touch debug screen, fullscreen/cursor
runner patches) once the spike passes.

## Talking to the Hub

`HubClient` has two implementations; `lib/main.dart` picks one at boot.

```sh
flutter run -d web-server --web-port 8080 --profile   # FakeHub (default)
flutter run -d web-server --web-port 8080 --profile --dart-define=HUB=ha \
  --dart-define=HA_URL=http://localhost:18123 \
  --dart-define=HA_TOKEN="$(cat ../hub/dev/token)"
```

No offline flag is needed on these, deliberately — `web/flutter_bootstrap.js`
carries it instead, so no command can forget it. See
[The web build must not need the internet](#the-web-build-must-not-need-the-internet).

Then open `localhost:8080` in the **host** browser. `localhost:18123` is
right *because* of that: the dart-defines are dialled by the browser, which
runs on the host, where the dev Hub's shifted ports live
([`.devcontainer/README.md`](../.devcontainer/README.md)'s addressing rule).

`--profile` is load-bearing (measured 2026-08-06): a **debug** web-server
build loads all 549 DDC modules and then waits for a debug connection
before running `main()` — and the web-server device only gets one from the
[Dart Debug Chrome extension](https://chromewebstore.google.com/detail/dart-debug-extension/eljbmlghnomdjgdjmbdekegdkbabckhm),
which flutter itself names when it starts. Without the extension the page
is blank and the console empty: nothing errors, because nothing runs.
Profile mode skips the gate — and gives up hot reload and breakpoints
with it; iterate by restarting the command. For a real debugging
session, install the extension and drop the flag.

`HUB`, `HA_URL`, `HA_TOKEN` and `GO2RTC_URL` are read from the **process
environment first**, falling back to the build's `--dart-define`, then to the
built-in defaults (`config/hub_config.dart`). `GO2RTC_URL` has no built-in
default at all — `HA_TOKEN` has none either, but a default *secret* is not a
thing that could exist, so `GO2RTC_URL` is the only **address** the Panel
refuses to guess. [Live video in the Popup](#live-video-in-the-popup) says why,
and is where that setting is documented.

**The environment form works on every target except web.** `-d web-server` is
a web build, and web has no process environment — a `HA_URL=…` prefix there is
silently discarded and you get FakeHub on the **built-in default**,
`localhost:8123` (`defaultHaUrl` — a property of the binary, so the dev
Hub's shifted host ports do not move it). So use
`--dart-define` with `-d web-server`, and the environment with `flutter
test` and with `-d linux` (the appliance/kiosk path, not a dev loop —
ADR-0009). In the devcontainer the environment form dials by service
name — this is the live end-to-end test, runnable as written:

```sh
PANEL_LIVE_HUB=1 HUB=ha HA_URL=http://homeassistant:8123 \
  HA_TOKEN="$(cat ../hub/dev/token)" flutter test test/ha_hub_live_test.dart
```

On the appliance the same mechanism carries the real Hub's address
(`127.0.0.1:8123` + `hub/token` — Ch. 6 §6.5); there is no documented
environment where `flutter run -d linux` pairs with the dev Hub's
`localhost:18123`.

The order matters on the appliance: the Hub's address is an operational
setting, not a property of the binary. A Hub that moves — or an unreserved
DHCP lease that drifts — should cost a restart, never a Flutter rebuild.
(The delivery half is **not wired yet**: `cage@.service` carries no `HA_*`
variables and `kiosk_app` still points at the spike app. See the phase-0
open items.)

Which origin won is logged at boot, values withheld — `env=` says whether a
process environment existed at all, so a discarded `HA_URL=…` on web is
visible rather than looking like a healthy default:

```
[panel] I hub.config HUB=build HA_URL=environment HA_TOKEN=environment GO2RTC_URL=absent env=available
```

If an ambient variable overrode a `--dart-define` you passed, that is called
out too — the one genuinely surprising consequence of environment-first:

```
[panel] W hub.config_override settings=HA_URL winner=environment
```

That line exists because with two possible origins, a Panel pointed at a
stale address and a Panel pointed at a dead Hub look identical on the badge.

`HaHubClient` authenticates with a long-lived token, seeds from `get_states`,
follows `state_changed`, and commands through `homeassistant.toggle` (which
spans domains, so the Panel needs no per-domain knowledge) plus
`climate.set_temperature` for the thermostat's setpoint — sent as an absolute
value in whatever unit the Hub speaks, never converted. It reconnects
forever with backoff — a wall display has to recover from a Hub restart with
nobody there to press anything.

Each Device names its Hub entity in `bindings.yaml` (`entity:`); how that
entity is read depends on the **Device's kind**, not the entity's domain, so a
washer behind a `sensor.*` and one behind a vendor integration both fold into
a `StatusState`. Devices without an `entity:` render with unknown state.

The Home Assistant to develop against comes up with the devcontainer
automatically, as sibling containers — no appliance needed:
[`../hub/dev/README.md`](../hub/dev/README.md).

## The web build must not need the internet

The house may have no internet, and the wall is not allowed to care. A stock
Flutter web build does: **measured 2026-08-06 in Chromium with every non-LAN
host blocked, the Panel rendered a blank white page.** Not degraded text —
nothing at all. Two runtime fetches to the public internet were the cause, and
each has its own fix:

| Fetched from | What | Fix, and where it lives |
|---|---|---|
| `www.gstatic.com/flutter-canvaskit/…` | `canvaskit.wasm`, `canvaskit.js` | `canvasKitBaseUrl` in `web/flutter_bootstrap.js` |
| `fonts.gstatic.com/s/roboto/…` | Roboto, the default Material face | the `fonts:` stanza in `pubspec.yaml` |
| `fonts.gstatic.com/s/notosans…/…` | a Noto *fallback*, for glyphs the requested family does not cover | `fontFamily: 'Roboto'` in `ui/theme.dart` |

**Both fixes are in the source, and neither is a command-line flag.** That is
the point of them. `--no-web-resources-cdn` fixes the CanvasKit half too and is
the officially-supported route — `flutter build web` and `flutter run -d
web-server` both accept it on Flutter 3.44.8 — but a flag holds only for as
long as every command anyone ever writes remembers it, and "the wall draws
nothing" is too quiet a failure to leave to that. `web/flutter_bootstrap.js`
sets `canvasKitBaseUrl` instead; it outranks both the flag and the
`FLUTTER_WEB_CANVASKIT_URL` dart-define, and it is honoured by `flutter run`
and `flutter build web` alike. Verified 2026-08-06 by running the dev loop with
**no** flag and confirming zero external requests. The CanvasKit files were
always in `build/web/canvaskit/`; only the base URL was ever wrong.

Do not reach for `--dart-define=FLUTTER_WEB_CANVASKIT_URL=…` — it is still read
in 3.44 but no longer chooses the base URL, and on its own it leaves
`useLocalCanvasKit` unset, so the loader goes to gstatic while looking
configured.

**The fonts are two mechanisms, not one, and each needs its own fix.** Missing
either leaves a request going out.

*The engine's own Roboto.* Nothing was registered under the family name
Flutter's default typography asks for, so the engine fetched it. The check is a
literal string compare against `Roboto` in the built
`assets/FontManifest.json`, so the family name in `pubspec.yaml` is
load-bearing — the same faces under any other name silently reinstate the
fetch, and no Dart code can influence this one. It pins what the appliance
draws too: a Flutter/cage build otherwise takes its default face from whatever
the kiosk image happens to have installed.

*Noto fallbacks.* When a rune is not covered by the **requested** family, the
engine downloads a Noto face at runtime. The trap is that the requested family
is platform-dependent: Material's default typography resolves to `Roboto` on
Linux and Android but `.AppleSystemUIFont` on macOS and `Segoe UI` on Windows,
neither of which is bundled — so on those platforms *every* rune above ASCII
counts as missing. The subtitle on the home screen is enough to trigger it; it
separates its hints with `·` (U+00B7). Measured 2026-08-06, one build, only
`navigator.platform` spoofed, counting requests that left the LAN:

| `navigator.platform` | before | after `fontFamily: 'Roboto'` |
|---|---|---|
| `Linux x86_64` | 0 | 0 |
| `MacIntel` | 1 | **0** |
| `Win32` | 1 | **0** |

The wall is Chromium on Linux, so today this prevents nothing — it is fixed
because "which OS is the browser on" is not something the house's ability to
draw its own UI should depend on, and a second screen or a tablet is one
decision away. **This is also why the offline check must be run per platform,
not once.** Testing only on the machine you happen to be on is how this was
missed the first time.

Corollary worth a lint if it ever recurs: a `TextStyle(fontFamily: …)` naming
anything not in `pubspec.yaml` re-opens the hole on *every* platform.

**What remains internet-dependent, honestly:** a glyph Roboto genuinely lacks —
CJK, emoji — would still reach for Noto. It cannot fire for the shipped House
Plan, which is Latin text plus Material Icons (Material Icons live in the
Private Use Area, which has no fallback mapped at all, so a missing icon is
tofu and *zero* requests). But the House Plan is family-authored: a room named
in Chinese would reach for a font that is not there. The fix if that day comes
is one more line beside `canvasKitBaseUrl` —
`fontFallbackBaseUrl: "assets/fallback-fonts/"` — plus the relevant Noto face
committed under that path. Not done now because shipping megabytes of Noto for
glyphs nobody has typed is the wrong trade; recorded here so the symptom (tofu
boxes in one room's name) is diagnosable.

The check that proves it, and the one worth re-running after any Flutter
upgrade, is a browser with every non-LAN host refused:

```js
// Playwright. Run the whole thing once per platform string — the fallback-font
// hole above is invisible on Linux.
for (const platform of ['Linux x86_64', 'MacIntel', 'Win32']) {
  const page = await context.newPage();
  await page.addInitScript((p) => {
    Object.defineProperty(navigator, 'platform', { get: () => p });
  }, platform);
  await page.route('**/*', (route) => {
    const url = route.request().url();
    const lan = /^https?:\/\/(localhost:8080|homeassistant:8123|go2rtc-dev:1984)\//;
    return (lan.test(url) || url.startsWith('data:') || url.startsWith('blob:'))
        ? route.continue()
        : route.abort();
  });
  await page.goto('http://localhost:8080/');
  // assert: zero aborted requests, and the Dollhouse drew.
}
```

Passing means zero aborted requests **and** a Dollhouse that still draws. The
first without the second is how a font quietly becomes a blank rectangle — and
it is not hypothetical: a build whose `HA_TOKEN` was missing passed the request
half of this check while rendering nothing at all.

## Live video in the Popup

Tap a camera or doorbell pin and the Popup asks go2rtc for that Device's
stream; close it and the stream goes away again. The teardown is the feature,
not tidiness: HA core #177014 says an open Ring live session can suppress the
*next* real ding, so a Popup left up does not merely waste bandwidth, it
deafens the doorbell.

Two settings feed it, deliberately at opposite ends of the House Plan:

| What | Where | Shape |
|---|---|---|
| Where go2rtc is | `GO2RTC_URL` — environment-first, like `HA_URL` | `http://192.168.68.81:1984` |
| Which stream a Device plays | `stream:` in `bindings.yaml`, per Device | `ring_doorbell` — a **name**, never a URL |

```sh
flutter run -d web-server --web-port 8080 --profile --dart-define=GO2RTC_URL=http://127.0.0.1:11984
```

`GO2RTC_URL` has **no built-in default**, and `HA_URL` does. That asymmetry is
deliberate: `HA_URL`'s default is earned because `HUB=fake` gates it — on a
bare `flutter run` nothing ever dials that address. Video has no such gate (a
camera is a camera under every Hub), so a `localhost:1984` default would open
a socket to nothing on every hermetic run; and unlike a wrong `HA_URL`, which
the Hub badge reports from across the room, a wrong go2rtc address is
invisible until somebody taps a camera. Unset reads `GO2RTC_URL=absent` at
boot, which says "nobody has told me where go2rtc is". `=fallback` could not.

`stream:` is a name because `?src=` is not a lookup — hand go2rtc a value that
looks like a source spec and it **creates** a stream and dials it. A
fat-fingered `rtsp://user:pass@…` pasted there would then carry the camera
password into the Panel's own log, so keeping it out of that log takes **four**
rules, not one. `boot.dart` hands a fatal House Plan `FormatException` to
`E house.invalid`, which is the one artefact a black-screen boot leaves in
journald, so *anything* a hand-edit of this file can reach that message with is
published:

- the parser refuses anything that is not a bare go2rtc stream name — letters,
  digits, dot, dash and underscore, in any position, and nothing else, so `:`,
  `/` and `@` cannot get through. There is deliberately no first-character
  rule: `_ring_doorbell` is a legal key in `go2rtc.yaml`, and refusing it
  refused nothing dangerous;
- the complaint it throws **does not repeat the value back**. That half is not
  belt-and-braces: refusing the paste was itself what published the password
  until the message stopped echoing it. It names the file, the binding and the
  field — enough to find the line in a file the reader has open — and says why
  the value is missing;
- **nor the binding's key**, unless the key is one nothing can hide in
  (`bindingLabel`: opens with a letter or digit, then letters, digits, space,
  dot, dash and underscore, 40 characters at most — the same exclusions as the
  stream-name rule, plus a length bound so nothing long enough to be a pasted
  sentence is quoted). A key is as hand-typed as a value, and a paste that lands one
  column to the left — no indent — makes the whole camera URL the key. That
  produced a line contradicting itself in its own second half, measured: *the
  `stream:` under "rtsp://admin:hunter2@cam/live" is not a go2rtc stream name …
  The value is not echoed here*. Anything else is placed by position instead —
  `the 3rd binding` — because YAML keeps entries in the order they were typed,
  so a position is a line in the file. Ordinary keys are still named: a name is
  what a reader greps for;
- and **the YAML parser's own exception never reaches that log line either**.
  This was the leak none of the three rules above was even in front of.
  `loadYaml` runs before any check in this file, and the `yaml` package's
  `YamlException` is a `SourceSpanFormatException` — its `toString()`
  reproduces the offending source line with a caret under it. So a duplicated
  `stream:` line, a stray tab, an undefined `*alias`, or a pasted URL
  containing `": "` each published the password, while the *cleaner* typo —
  the one that parses and is then refused above — did not. `readYaml` in
  `bindings_parser.dart` is now the only door to `loadYaml`, for `house.yaml`
  as well, and it reduces that exception to file, line and column. The parser's
  own sentence survives only when it matches a shape no source text can take;
  `Undefined tag: <tag>` interpolates author text, and it is withheld.

`entity:` and `connectivity:` are refused the same way and for the same
reason: they are the lines above and below `stream:`, and just as easy to paste
a URL into. The loader refuses a `stream:` on any kind that cannot play one,
and that message withholds the stream name as well — on a light the stream is
refused, so that message is the *only* place the name could ever be published,
where on a real camera it reaches `popup.stream_open` and has to.
[HOUSE-PLAN.md](HOUSE-PLAN.md) has the operator-facing version.

One credential channel is accepted rather than closed, stated here so it is not
rediscovered as a defect: a bare API token typed where a stream name goes
**parses** — a token has the shape of a legal name — and is then logged as
`popup.stream_open name=…`. Rejected: hashing or truncating the name in the
log, which costs every honest line its meaning; and a length cap, which refuses
the long descriptive names go2rtc allows while a short token sails through.

The two are joined by `VideoConfig.urlFor`: `http://host:1984` +
`ring_doorbell` → `ws://host:1984/api/ws?src=ring_doorbell`, with `https` →
`wss` — the same transform `HaHubClient` does for its own socket. It returns
null where that one throws: a bad `HA_URL` stops the Hub and the badge says
so, while a bad `GO2RTC_URL` must only ever cost the picture, never the Device
name and the Close button around it.

### Two transports, one stream name

`lib/ui/video/live_video.dart` is a pure interface plus a conditional export —
the same seam `config/runtime_env.dart` uses. Behind it are **two real
players**, not a player and a placeholder:

| Build | File | Transport | Measured against the live go2rtc, 2026-08-04 |
|---|---|---|---|
| appliance (`-d linux`, cage) | `live_video_mjpeg.dart` | multipart JPEG over HTTP, `GET /api/stream.mjpeg?src=…` | first byte at **2.10 s** warm / **4.10 s** cold; then **~186 kB/s**, 25 fps, ~7.4 kB a frame |
| web (`-d chrome`) | `live_video_mse.dart` | fMP4 over a WebSocket, `/api/ws?src=…`, fed to `MediaSource` | `playing` **101 ms** after open, in real Chrome; **~26 kB/s** |

The two rows were not timed the same way and it matters: the appliance row is
`curl` against `/api/stream.mjpeg`, the web row is the real player in real
Chrome, and the byte rate under it is `/api/stream.mp4` on the same H.264
producer (25.7 kB/s over 20 s) — the same bytes MSE carries, measured where
they could be measured without a browser in the loop.

The appliance pays roughly **seven times the bandwidth and twenty times the
time-to-picture**. The bandwidth is the price of a target with no browser in
it: go2rtc has to run an ffmpeg transcode to produce JPEG. The 2.1 s is *not*
the JPEG transcode — `/api/stream.mp4`, which is the untranscoded H.264
producer, takes the same 2.09–2.11 s to first byte over four runs, including
one taken while an MSE session was already `playing`. What both share is that
go2rtc starts a producer on demand, when the first viewer asks. The MSE player
does not pay it, at 101 ms in Chrome over the WebSocket; why the two HTTP pull
endpoints do and `/api/ws` does not has not been measured, so nothing here
claims it. On a LAN neither number is a problem — 186 kB/s is 1.5 Mbit — but
the 2.1 s is why `LiveVideoPhase.connecting` has to be an honest phase rather
than a cosmetic one. A wall that flashed "unavailable" for two seconds would
send whoever is standing there to debug a camera that is about to work.

*(Two figures from the first probe are retracted, and both were the same
mistake — a total divided by the whole request rather than by the time the
thing was happening. ~124 kB/s and 16.5 fps were bytes and frames over a
capture that included the idle spin-up; divided by the time frames were
actually arriving, the same capture gives **~186 kB/s at 25 fps**, which are
the numbers to size a network and a stall timeout against, re-measured
independently at 184.9 kB/s and 25.1 fps. "26 ms to first byte" on
`/api/stream.mp4` is retracted outright: four runs measured 2.095–2.106 s and
none came close to reproducing it.)*

Which player a build gets is decided by the conditional import, and
`liveVideoIsAvailable` is `true` on **both** sides — it is kept, and asserted
by a seam test, so that re-stubbing either file fails a test instead of
quietly costing a target its picture. It used to be `false` on the non-web
side, from when the appliance showed a grey box; that was the wrong half of
the seam to leave empty, because the appliance is the wall.

One `stream:` name serves both transports. That is a fact about how
`go2rtc.yaml` is written, not a coincidence — see
[the config shape](#the-go2rtc-config-shape-one-stream-two-producers) below,
and `hub/go2rtc/go2rtc.example.yaml` for the worked example. Rejected: a
`_mjpeg` suffix convention, which would put a transport detail into the
house's configuration and make every camera two entries that can drift apart.

**What is not proven.** The MJPEG player has been driven against the live
go2rtc and through the whole suite, but **never in the cage kiosk it ships
to** — no longer for want of a build: `flutter build linux --release` ran on
the Hub host 2026-08-04 (**G4**, done — [TODO.md](../TODO.md)) and in the devcontainer
2026-08-06, whose bundle's measured glibc ceiling (`GLIBC_2.34`) runs on the
24.04 mini PC; what is still missing is cage itself and a touchscreen
(**A7**/**G6**). The MSE player was driven in real Chrome against the live
server, but its `HtmlElementView` was never *mounted* in a widget tree. Both
gaps are stated again in the code, at the class that carries them.

### The grace window: a reopen must not relaunch the producer

`lib/ui/video/live_video_keepalive.dart` sits between both video surfaces and
whichever player this build has. It is the fix for **issue #1**, and the fault
it exists for was found by a finger on a real doorbell, not by a test.

Tapping the doorbell pin three times in a row gave a good picture, then a frame
whose bottom half was green, then nothing at all — and a fourth session left
open for 2 m 22 s never healed. Three plain `ffmpeg -frames:v 1` pulls a second
apart, with no Panel in the loop, **all decoded corrupt frames** (one ~90 %
smear, two half-frame), with `error while decoding MB 45 45` and `mmco: unref
short failure` in the output. So the corruption was in the elementary stream
ring-mqtt's restream delivers; the Panel painted what arrived, and painted
nothing rather than something invented.

**Measured** is the correlation with the gap between teardown and relaunch:
minutes gave a good picture, ~40 s gave half a frame, 1.0–1.1 s gave nothing —
and 1.1 s is exactly the cadence the Popup's deliberately aggressive
open→teardown→reopen lifecycle produces.

**Inferred** — the issue files it under "Mechanism hypothesis", and so does the
code — is *why*: ring-mqtt transcodes Ring's **WebRTC** stream, and over WebRTC
keyframes are not periodic. An IDR arrives at session start and afterwards only
on a PLI request, which nothing in this chain can send, so a consumer attaching
a hair late would join mid-GOP with no later keyframe to heal with. Nobody has
read the bytes to confirm it. The fix is sized on the timings, not on the story;
if the story is wrong but restarting the producer is still the trigger, the fix
holds, and if it is wrong altogether the fix simply will not work.

So the Panel stops relaunching. When a Popup or a camera tile lets go, its
go2rtc session is **kept** for `kLiveVideoLinger` (20 s) instead of closed; a
consumer asking for the same endpoint inside that window re-attaches to the
producer that is still running. Nothing inspects a picture — a corrupt frame is
a delivered frame and the Panel cannot tell the difference.

| Bound | Value | Why |
|---|---|---|
| `kLiveVideoLinger` | 20 s | Must cover the Popup's reopen cadence (seconds) without exceeding `kDoorbellPopupDeadline` (30 s) — a kept session is a Ring session with **nobody watching**, and #177014 says one of those can suppress the next real ding. A test asserts the inequality rather than trusting two files to stay in order. It does **not** cover the issue's ~40 s reopen, which came back half corrupt: buying that would mean holding a doorbell's stream longer than the Panel is willing to show it, trading a green half-frame for a missed ding. |
| `kLiveVideoMaxHeld` | 2 min | The same figure as `kDoorbellPopupCeiling` and for its argument: without a cap one session could serve an unbounded chain of reopens. It governs keeping and re-attaching only — a session somebody **is** watching is never closed under them, because the Cameras view holds a tile live for up to five minutes on purpose, and closing a player under a live consumer leaves the phase reading `playing` over an empty box (the stale picture ADR-0007 is about). |

**What that costs, stated as sums rather than comparisons.** A doorbell Popup
that runs its full 30 s deadline and is not reopened now holds its Ring session
**50 s**, not 30. And the cap is not the bound it looks like: a reopen arriving
just under it re-attaches, and that consumer then runs its own full lifetime, so
the real worst case is `maxHeld` **plus one consumer's own bound** — ~4 min
through a doorbell Popup's ceiling, ~7 min through a Cameras tile's five-minute
idle return. Refusing reuse near the cap buys nothing (the last consumer through
still runs its own lifetime); the only route to a hard 2 min is not to
re-attach at all, i.e. not to fix issue #1. Tests pin both numbers.

A session is not kept if it failed, if it is `unsupported` (nothing was dialled,
so there is no producer to hold), or if it is already past the age cap. One kept
session per endpoint, so a stream can never accumulate held Ring sessions. And
the wrapper keeps `LiveVideoOpener`'s contract whole — **it may not throw**:
`device_popup.dart` catches, but `cameras_view.dart` calls `video.open` bare, so
an exception let out would take the whole Cameras view down for one tile.

It is composed in `main()` — one pool per process, `VideoConfig(open:)` — and
not inside `VideoConfig`, which is `@immutable` and built by every hermetic
test. So both surfaces get it through the seam they already use, no widget
changed, and the suites still drive the raw opener.

| Log line | Means |
|---|---|
| `I video.stream_kept name=… phase=… for_s=20` | a consumer let go; the producer is being held |
| `I video.stream_reused name=… reuse=N phase=…` | somebody came back inside the window — **the line that separates "the picture was good because the producer never stopped" from "the first open of the day was lucky"** |
| `D video.stream_dropped name=… reason=… reuses=N` | really closed. `linger_expired` is the ordinary case; `too_old` is the two-minute guarantee firing; `failed_while_kept` is a producer that died while it was being held |

**What is and is not proven.** Everything above is hermetic — the pool against
a fake go2rtc, and both surfaces' lifecycles against it. Whether a re-attached
MSE session survives its `<video>` element being re-parented into a fresh
platform view used to be argued from the DOM and never mounted. **It was
mounted on 2026-08-06, in Chromium against the real Ring doorbell, and the
argument was wrong**: the element came back *paused*, because the HTML spec
pauses a media element that leaves its document and only `sourceopen` — which
fires once per session — had ever called `play()`. `_resume` is the fix and
the re-attach now runs live across three reopens. The other half of that
session, `_trim`, was wrong too. Both are recorded in
`live_video_mse.dart`'s class docstring with the measurements.

Still not proven, and it is a narrower thing than it was: no *automated* test
mounts that view. `flutter test --platform chrome` cannot — measured, the
platform-view registry is stubbed there and `onElementCreated` never fires, so
such a test would pass while exercising nothing
([Tests](#the-web-half-runs-nowhere-unless-you-ask-for-it)). The guard is the
browser procedure, not a suite.

### Five answers, because one grey rectangle would be a lie

| Phase | On the wall | In the log |
|---|---|---|
| `unconfigured` | "Live view placeholder — go2rtc stream" | `D popup.stream_skipped device=… reason=no_go2rtc_url` \| `no_stream_name` \| `bad_go2rtc_url` |
| `connecting` | "Connecting to the camera…" | `I popup.stream_open name=…` |
| `playing` | the picture | — |
| `failed` | "Live view unavailable" | `W popup.stream_failed name=… reason="…"` |
| `unsupported` | "Live view unavailable" | `I popup.stream_unsupported name=…`, and **no** `stream_open`/`stream_closed` pair — no socket was ever opened |

`unsupported` is **no longer a whole-platform verdict**. It used to mean "this
is not the web build"; both builds carry a player now, and what still reaches
it is a *browser* with no `MediaSource` in it. The web player checks before it
dials, because `failed` would send an operator to look at a go2rtc that is
perfectly healthy for a fault that is in the browser.

Five and not two because "nobody told the Panel where go2rtc is", "go2rtc
answered and refused" and "this build cannot play video at all" have three
different fixes and three different people to do them. `failed` and
`unsupported` do read identically on the glass, on purpose: what differs is
*who* has to act, and that person is reading journald, not standing in the
hall. They are told apart **in the log**, by `stream_unsupported` against
`stream_failed` — on the appliance the journal is the only channel there is,
and it has to distinguish "this build cannot play video" from "go2rtc is
healthy and said no". What the wall owes whoever walks past is that there is no
picture, said plainly rather than shown as a black rectangle they would stand
there waiting on — which is also why no phase renders a spinner. A
`CircularProgressIndicator` never settles, so `pumpAndSettle` would hang every
widget test that opens a camera.

`unconfigured` is the odd one out: **no opener ever answers it.** That case is
decided before anything is dialled — `_openVideo` returns *null*, logs which of
the three reasons applied, and the video box renders this body for a null
session. The enum value names the body so an opener that one day learns the
difference has somewhere to say it; today the phase on the wall arrives with no
session behind it at all.

`reason=` on `stream_failed` is go2rtc's own sentence: grep it, never branch on
it, never render it. Verbatim except for one pass of `redactCredentials`
(`lib/diagnostics/url_redaction.dart`), which is **best-effort and says so** —
the sentence is composed by another process out of a configuration the Panel
has never seen.

That rule works by structure now, not by guessing which query parameter is the
password. A URL has a recognisable **start** (`scheme://`); inside Go's `%q`
quoting it has a recognisable end, and in prose the end is whitespace or the
sentence punctuation that follows it. Every such run is cut down to scheme,
host and port. Both halves were measured leaking before they existed: go2rtc
quotes a whole source URL back (`?loginuse=…&loginpas=…`, Foscam's real CGI
parameters, which contain neither `user` nor `pass`), and for an `ffmpeg:`
producer it hands back **ffmpeg's own stderr**, where the URL is bare
(`Error opening input file http://…?loginpas=hunter2.`). The second one hides
well, because ffmpeg masks *userinfo* itself, so every `user:pass@` probe comes
back clean while the query beside it is published — and the two-producer camera
layout this project uses puts an `ffmpeg:` line on every camera.

What it costs: go2rtc's `#key=value` source options no longer survive when they
hang off a `scheme://` URL, so `rtsp://cam/live#media=video` logs as
`rtsp://cam <redacted>`. They still read on the producer names go2rtc writes
without an authority, such as `ffmpeg:selftest#video=mjpeg`. Where it stops is
written out in the function's own docstring — a password with a space in it, a
schemeless `user:pass@host`, one character of trailing punctuation — and where
the rule is wrong it is wrong towards redacting too much, which is the
direction to be wrong in when nothing downstream reads the text. Rejected:
dropping `reason=` entirely — `mse: stream not found` is what an operator needs,
and "go2rtc said no" with no reason is the grey rectangle this feature exists to
stop showing, one layer down.

Every one of these lines carries the stream **name**, never the URL —
`diagnostics/log.dart`'s rule, and the name rules above (refuse the paste, echo
back neither it, nor a key that could be one, nor the parser's view of the line
it sat on) are what keep a credentialed paste out of the one file that gets
shipped to whoever is debugging.

Closing the Popup closes the session, from `dispose()` rather than from the
route's future: `Route.popped` completes ~150 ms before the subtree unmounts,
and `dispose()` is the only hook that also runs when the route leaves without
a pop. All ways out — the Close button, the barrier, the doorbell deadline —
converge on it, and it logs `I popup.stream_closed name=… reason=popup_closed`
— but only for a stream that was actually opened. A build that answered
`unsupported` logs neither half of that pair: a `stream_open`/`stream_closed`
for a socket that never existed is the log inventing a connection.

### The go2rtc config shape: one stream, two producers

The two transports are **not** two streams. One `streams:` entry carries two
producers, and `bindings.yaml` names it once:

```yaml
streams:
  cam_porch:
    - rtsp://user:pass@CAMERA-IP/live      # H.264 -> web MSE
    - ffmpeg:cam_porch#video=mjpeg         # -> appliance MJPEG
```

**The second line is not optional, and its absence is silent.** go2rtc does
**not** transcode on demand for a format no producer offers. Measured against
the live 1.9.10 daemon: a stream with only the H.264 producer answers
`GET /api/stream.mjpeg?src=…` with **HTTP 200 and zero bytes**, in 94 ms, and
then holds the connection open. Not a 404, not an error frame — a successful
empty stream. The appliance's watchdog eventually calls that `failed`, and
whoever reads the journal goes looking at the camera, the network and the
kiosk build before they think to look at a missing line in `go2rtc.yaml`.

The transcode **only runs while somebody is watching**, which is what makes it
affordable to declare on every camera: with no consumer, `/api/streams` shows
both producers as bare `url` stubs and `consumers: []`, and no ffmpeg is
running. Closing the Popup returns it to that state — which is also visible in
the timings above, since a second viewer arriving after the teardown pays the
4.1 s cold start again rather than the 2.1 s warm one.

**How fast it returns depends on when the Popup closed**, and only one of the
two cases is under the Panel's control. Closed while `playing`, `consumers` is
`[]` in under a second. Closed *during* the ~2 s connect, `consumers` **rises
after** the Panel's socket is already gone and takes **2–10 s** to reach `[]`:
the on-demand `ffmpeg:<name>#video=mjpeg` producer counts as a consumer of its
own source and finishes starting regardless of who left. Measured, both cases;
the attribution to the producer is inference from the timings. Nothing is done
about it in `_release` — that process is go2rtc's and it idles out on its own —
and it is written down because "consumers back to `[]`" is the check both this
README and Ch. 6 tell an operator to run.

The `selftest` stream in `hub/go2rtc/go2rtc.example.yaml` is written this way
and is what every check in this README was run against.

### Not finished: what stands between this and a picture

**1. One player has met a real camera; the other has not.** This item used to
read "no camera to point at" — that was true until **B2** landed on
2026-08-05, and both halves of it have moved since.

The **web/MSE** player has been driven against the real Ring doorbell, in
Chromium, through the real Popup: 2026-08-06, cold open then three reopens two
seconds apart, `paused false` and `readyState 4` throughout, decoded frames
climbing 103 → 405 with `currentTime` tracking wall-clock. It is also where
[issue #1](https://github.com/dmorozov/SmartHome/issues/1) was found and two
bugs in it fixed, which no synthetic pattern would have surfaced.

The **appliance/MJPEG** player has still only rendered `selftest`. Careful
about what the TODO list's **B2** entry proves here: the 54 real JPEG frames it
records were pulled from `/api/stream.mjpeg` by hand, not through
`MjpegLiveVideoSession` — the endpoint served real Ring, the *player* has not
consumed it. **B3**, the Wyze fleet, is untouched.

What that leaves genuinely open is narrower than it was, and it is now
producer-side rather than player-side: ring-mqtt opens its cloud session only
when a client connects, and the relaunch that follows a quick close/reopen can
deliver an elementary stream with no keyframe to decode from. Measured
2026-08-06: a producer gap of 2.8 s decoded 2 frames, 4.8 s decoded none, 25 s
was clean six times out of six. That is issue #1, it is bounded rather than
cured, and the Popup now shows the Hub's still instead of a green rectangle
when it loses.

**2. The appliance build has never run in the cage.** Compiling it stopped
being the gap on 2026-08-04: `flutter build linux --release` succeeded on the
Hub host (**G4**, done — [TODO.md](../TODO.md) records the release binary running
headless under Xvfb against the real Hub and go2rtc, MJPEG test pattern
rendering in the Popup), and the devcontainer ships the full Linux toolchain
— the same build verified in-container 2026-08-06, the bundle's measured
glibc ceiling (`GLIBC_2.34`) fine on the 24.04 mini PC. What still stands is
cage and touch (**A7**/**G6**): Xvfb with software GL is not the kiosk
compositor, so the cage the Panel actually ships into has still never drawn a
frame of it, and saying otherwise would be inventing evidence. **Not** the same
class of gap on the other side any more: `MseLiveVideoSession.view` used to be
proven in Chrome with no widget tree around it, so the reparenting of the
`<video>` element was argued for and untested. It has since been mounted in a
real browser against the real doorbell, which found two bugs in it — what
remains missing there is an *automated* mount, and that one is measured
impossible under `flutter test --platform chrome` rather than merely not done.

**Settled 2026-08-04, and no longer on this list: go2rtc's cross-origin
refusal (E8).** It used to 403 any WebSocket upgrade carrying an `Origin`
header, so a web Panel served from anywhere except `:1984` never reached the
socket and saw a bare connection failure with no error frame to explain it.
`api: origin: "*"` is now set in `hub/go2rtc/go2rtc.yaml` and mirrored into
the tracked example. Re-measured against the live daemon after the change:
`Origin: http://localhost:8080` → **`101`**, where it was `403`.

The reasoning is worth keeping, because the setting looks careless out of
context. 1.9.10 has **no allowlist** — `api.origin` set to the Panel's exact
origin was measured and still 403s that very origin, so the choice was `"*"`
or no video, never `"*"` versus something tighter. And the origin check was
never the control here: **this system is reachable only from the LAN or over
the VPN, and the network boundary is what keeps strangers off an
unauthenticated service** (ADR-0008 — one box, no port-forward). Declining
`"*"` would have cost the picture for a protection that does not exist.
Owner decision; the exposure it does buy is real and is stated in
`hub/go2rtc/go2rtc.example.yaml` beside the setting. Do not "tighten" it to a
hostname later without re-measuring — it will look correct and silently break
every camera.

### The doorbell opens it by itself

`lib/domain/doorbell.dart` decides what a doorbell's newly-reported state
means. A pure function with `now` injected, because the rule *is* the feature
and a rule that can only be exercised by standing beside a real doorbell is a
rule nobody runs.

Rejected: "the doorbell's `stateChanges` fired". `HaHubClient` emits a change
for **every** usable message with no equality check, and a reconnect replays
the whole snapshot — so "fired" means "the router rebooted" as often as it
means "someone is at the door". That is worse than a spurious rectangle: a
wrong pop opens a real Ring cloud session, and #177014 says a live session can
then suppress a real ding. The Panel would jam the doorbell it exists to
answer.

The rules, **in this order**:

1. an unchanged value is not an event;
2. a state that parses as a timestamp is the `event.*_ding` shape —
   2a. and if it is the *same instant* this Panel has already rung for, it is
   silence;
   2b. otherwise it rings if it is within 60 s of now, either side;
3. first sight of a *word* is never a press (a snapshot states what the entity
   already said, and `on` carries no time, so there is no telling an `on` from
   hours ago from one a second old);
4. otherwise `on` rings, `off` does not, and anything else is `unreadable` —
   one warn line naming the string it could not read, never a guess.

The order is load-bearing at both ends. Unchanged goes first so a reconnect
replaying a press time from ten seconds ago cannot ring for it twice. First
sight goes *after* the timestamp, not before: first sight exists to **guess**
whether a value is old, and a timestamp does not need guessing — it says so,
and the 60 s window is exactly the judgement first sight was invented to fake.
Rejected: first sight vetoing everything, which cost a genuine press for
however long the Ring integration took to load after an HA restart, with a
debug `ding_suppressed reason=first_sight` as the only trace.

**Rule 2a is why there are two memories, not one, and they have opposite
lifetimes.** Rule 1 only catches a replay while the Panel still believes the
old value. Nothing caught one that arrived *after* that belief was dropped: an
entity round-tripping through `unavailable` and re-reporting the **same** press
time rang a second time inside the 60 s window, and #177014 says the second
Ring session can suppress the next real ding. So the press already rung for is
remembered separately and outlives everything. Identity, not "at or before" —
a press time that goes *backwards* is a clock or a replay, and treating it as
answered would let a Ring cloud clock stepping back deafen the bell with no
symptom anywhere. Duplicates are bounded; deafness is not.

`HubController` therefore holds:

| Memory | What it is | Lifetime |
|---|---|---|
| `_lastSeen` | what this doorbell **currently says**, as far as the Panel knows — a belief, never a souvenir | seeded at construction from the Hub's own snapshot; **cleared** when the link leaves `up`; **forgotten per Device** the moment that Device's state goes away |
| `_rungFor` | the press **instant already rung for** — a record of what the Panel has already *done* | seeded from the same snapshot, then **never cleared**, by a link drop or an entity drop or anything else |

The asymmetry is the whole argument, and it is not a hedge: `_rungFor` can
only ever turn a `pressed` into a `quiet`, so no staleness in it can invent a
ring — which is exactly what a stale `_lastSeen` did. `HaHubClient` drops the
entry entirely on `unavailable`, and a belief outliving the value it describes
turns `off` → unavailable → `on` into an edge with nobody at the door, over an
integration reload or an MQTT blip that never touches the Panel's socket.
Stickiness there only ever helped when the value came back *unchanged*.

**The cost, stated because it is real and not because it is fixable.** A press
that is the first thing the Panel hears about a doorbell — after a reconnect
whose snapshot reported the entity `unavailable`, so nothing survived the gap
— is **lost**, and only the next press rings. Rule 2a bought the timestamp
shape out of this. The **word** shape cannot be bought out: `on` restored from
before the gap and `on` from a finger on the button one second ago are the
*same string*, and differ in nothing that exists anywhere on the wire. The
honest answer to a question with no evidence in it is silence; the alternative
rings the house on every HA restart, which #177014 then turns into a doorbell
that misses the real press. Whoever wants that press wants the
`event.<name>_ding` entity, which carries the one fact that would settle it.

`DoorbellPopupHost` is the one widget allowed to push a route on the Hub's
say-so; the Popup it opens closes itself after 30 s, and a second ding while it
is up **extends** that deadline instead of re-pushing, because Ring spin-up is
2–5 s and a re-push would black the wall out at the exact moment somebody is at
the door. Extending stops at `kDoorbellPopupCeiling` — **2 minutes** from when
the Popup opened, past which no ding extends anything. The deadline measures
time since the last ding, and #177014 cares about time since the stream was
*opened*: without a ceiling, a doorbell dinging more often than every 30 s
holds one go2rtc session open forever, which is the exact state the deadline
exists to prevent. Reaching the ceiling does not lose the doorbell — the
session is torn down and the next ding opens a fresh one.

The host asks about *this doorbell*, not about "is a Popup up", so a Popup
showing some other Device is no reason to swallow a ding. Two answers besides
"extend it" and "push one": a Popup a **person** already opened on this
doorbell is held as it is (and gains no deadline it never had — a countdown
smuggled in by somebody else's event would yank the camera away from whoever
went and tapped it); one already on its way out is *deferred* and re-offered
once its `dispose` has closed the session, because pushing during the ~150 ms
exit animation would put a second consumer on a stream the first Popup still
holds.

```
[panel] I ui.ding device=doorbell entity_state=on
[panel] I popup.doorbell device=doorbell reason=ding
[panel] D popup.doorbell_extended device=doorbell
[panel] D popup.doorbell_held device=doorbell reason=person_opened
[panel] D popup.doorbell_deferred device=doorbell reason=stream_closing
[panel] W popup.doorbell_dropped device=doorbell reason=popup_never_closed waited_s=30
[panel] I popup.deadline_ceiling device=doorbell open_s=120
[panel] W popup.dismiss_blocked device=doorbell retry_s=1
[panel] I popup.doorbell_dismissed device=doorbell
[panel] W ui.ding_unreadable device=doorbell state=ringing expected=on|off|<iso8601>
[panel] W ui.ding_stale device=doorbell age_s=612
[panel] D ui.ding_suppressed device=doorbell reason=first_sight
[panel] D ui.ding_suppressed device=doorbell reason=unchanged
[panel] D ui.ding_suppressed device=doorbell reason=stale age_s=3600
[panel] D ui.ding_suppressed device=doorbell reason=already_rung age_s=45
```

`reason=already_rung` is rule 2a: the same press time again, from an entity
that dropped out and came back saying what it said before. Debug, not warn —
nothing is wrong, and the line exists so "the doorbell rang once for two
reports" can be read back rather than inferred. It used to be reported as
`ding_stale`, which sent whoever was holding the log to go and check NTP over
a Panel behaving exactly right.

`popup.doorbell_dropped` is a deferred ding giving up. A ding that arrives
during a Popup's ~150 ms exit waits for that Popup's `dispose`; if the Popup
somehow never closes, the waiter expires after 30 s rather than sitting armed
— because a ding redeemed minutes later opens a Ring session for somebody who
has long since walked away, on top of whatever Popup is up by then.

`popup.dismiss_blocked` is the Popup saying it could not pop itself because
something is stacked on top of it — it only ever pops its own route — so it
re-arms at 1 s and keeps trying rather than quietly losing its deadline. The
ceiling keeps running underneath it.

`ui.ding_stale` earns its place: the press time originates in Ring's cloud,
not on the Hub box, so if the appliance clock drifts past the freshness window
**every** ding classifies quiet and the feature dies with no symptom anywhere.
The age is signed for the same reason — a negative one is the only way that
line can say the appliance clock is *behind*. It is a **warn** only for a press
time that *changed* and still read too old, which is the clock-drift symptom;
the first press time seen after a boot or a gap gets `ding_suppressed
reason=stale` at debug instead, because a snapshot handing over yesterday's
ding is ordinary. The reasons follow the classifier's own order, so the one
named is the rule that actually did the silencing rather than the first rule
that would have.

`popup.doorbell_dismissed` deliberately carries no `reason=`: the host cannot
tell its own deadline firing from a hand on the glass, and a guessed `timeout`
in the one channel that exists to be trusted after the fact is worse than
saying nothing.
`popup.deadline_ceiling` is the one dismissal that *does* name itself, because
`device_popup.dart` is where that decision is taken and it knows.

**The binding is real; the press is not.** This paragraph used to say none of
it had met a real Ring doorbell, with `bindings.yaml` pointing at a dev-Hub
stand-in and ring-mqtt sitting at its auth gate. Both were overtaken on
2026-08-05: ring-mqtt is authenticated (**B2**, done), and `doorbell` binds
`event.front_door_ding` — a real MQTT-event entity minted over ring-mqtt's own
ding topic, because this ring-mqtt publishes no `event.*` of its own
(phase-7 §A). So the question "which entity shape will it produce" is settled,
and it is the timestamp shape the classifier prefers.

**What has still never happened is a finger on the button.** The entity has
seen no real press, so the two press-loss bugs the timestamp shape fixes are
corrected by construction rather than by observation. That is **A8** in the
root [TODO list](../TODO.md) — a four-press protocol, two of them staged around
an HA restart, and it is owner work at the door. Until it runs, treat the
classifier as argued-for and not observed. See
[phase-7 §A4](../docs/plans/device-integrations/phase-7-doorbell-events-and-cameras.md).

## The Cameras view

The Panel's **second full-screen surface**, and until 2026-08-07 this README
mentioned it only in passing inside Popup sections. A right-edge tab on the
Dollhouse (`CamerasTab`, present only if the House has a video Device at all)
slides out a grid of tiles, one per camera and doorbell.

**A tile is off by default and shows a still.** The face is the Hub's own
snapshot — `Image.memory` with `gaplessPlayback`, refreshed every
`kCamerasSnapshotRefresh` (60 s), fetched through HA's `camera_proxy` from the
`snapshot:` binding. That fetch **costs no device session**: HA already holds
the JPEG, so an off tile is a real picture of the porch that wakes nothing. A
Device with a stream but no snapshot shows its kind's icon; one with neither
says "Not wired up yet".

**Tapping goes live**, and `Tap for live` is drawn only where a tap can
actually deliver — a wired stream on a build that knows where go2rtc is.
Tapping again, or closing the view, tears the session down.

**Which tiles come up live on their own is a property of the kind, not of the
Device.** `KindSpec.autoLive` is true for `camera` and **false for
`doorbell`** — so the doorbell tile opens off, every time, and that is
#177014 protection rather than an oversight: any brand's doorbell live view has
cloud side effects, and an open Ring session can suppress the *next* real ding.
It is per-kind for ADR-0006's reason — per-Device would invite hand-editing the
safety back off.

**The view returns itself to the Dollhouse when nobody is watching.**
`kCamerasIdleReturn` is 5 minutes; `kCamerasIdleWarning` (30 s, *part of* that
5 minutes rather than added to it) is the "Still watching?" prompt that softens
it. Unanswered, the view pops. One tap per five minutes is the price of holding
a Ring session open on purpose.

### `cameras.*` — the log vocabulary

Eleven events. The view's own lifecycle, then each tile's.

| Line | When |
|---|---|
| `I cameras.opened tiles=N auto_live=N` | the view opened; `auto_live` is how many tiles came up live by themselves |
| `I cameras.closed open_s=N live=N` | it went away, how long it was up, how many tiles were still live |
| `D cameras.idle_blocked retry_s=30` | the idle deadline fired against a route it may not pop; retries after the warning window |
| `I cameras.idle_return reason=unanswered` | "Still watching?" went unanswered and the view returned itself |
| `D cameras.tile_skipped device=… reason=no_stream_name \| go2rtc_unconfigured` | a tile that cannot dial, and which of the two reasons it is |
| `I cameras.tile_unsupported name=…` | this build cannot play video — the browser has no `MediaSource`. Not a go2rtc fault, and deliberately not `tile_failed` |
| `I cameras.tile_open name=…` | a stream was opened for that tile |
| `W cameras.tile_failed name=… reason=…` | go2rtc's own sentence, already through the players' redaction |
| `I cameras.tile_closed name=… reason=…` | the stream was let go |
| `D cameras.snapshot_ok entity=…` | a still landed. Logged **on change only** — a broken Hub would otherwise write once a minute forever |
| `W cameras.snapshot_failed entity=… status=…` | `status` is an HTTP code or an exception's bare **type name** — never exception text, which embeds the request URL, and that request carries the Hub token |

The `snapshot:` binding key that feeds all of this is documented for the
author in [HOUSE-PLAN.md](HOUSE-PLAN.md); the Popup uses the same key for its
own fallback ([Live video in the Popup](#live-video-in-the-popup)).

**On web this needs Home Assistant to allow the origin.** The still is a
cross-origin `fetch` with an `Authorization` header, so HA must carry an
`http: cors_allowed_origins:` entry or every tile falls back to its icon and
logs `snapshot_failed`. The appliance build uses `dart:io` and is unaffected.
See `appliance/commissioning/03-home-assistant.md` §3.10.

## House Plan pipeline (ADR-0004)

**The manual: [HOUSE-PLAN.md](HOUSE-PLAN.md)** — written for whoever draws
the house, start to finish: install, draw, place Devices, convert, bind,
and every error message with what to do about it.

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
  (CONTEXT.md language; geometry is Panel-side config, the Hub never sees it),
  and `doorbell.dart`, the ding rule as a pure function
- `lib/data/` — `HubClient` interface, `FakeHub`, `house_loader.dart` (parses
  the two House Plan YAML assets)
- `lib/ui/` — theme, `HubController` (ChangeNotifier over `HubClient`),
  `dollhouse/` (iso projection, floor arrangement, floor scene, slab
  painter, stacking view), Popup, `doorbell_popup_host.dart` (the one widget
  allowed to push a route unprompted), `video/` (the go2rtc seam — pure
  interface plus the two players behind it, `live_video_mjpeg.dart` for the
  appliance and `live_video_mse.dart` for web, with `mjpeg_frames.dart`
  holding the multipart framing so it can be tested without a socket)
- `lib/diagnostics/` — structured logging (below)
- `tool/` — the Sweet Home 3D converter + fixtures

## Run

| Target | Command | Works on |
|---|---|---|
| Web | `flutter run -d web-server --web-port 8080 --profile` | the devcontainer (host browser via forwarded 8080) — the dev loop. `--profile` is required: debug gates `main()` on the Dart Debug extension ([Talking to the Hub](#talking-to-the-hub)). Nothing here keeps CanvasKit off the internet — `web/flutter_bootstrap.js` does ([The web build must not need the internet](#the-web-build-must-not-need-the-internet)) |
| Linux desktop | `flutter run -d linux` | builds in the devcontainer; runs where there is a display — the appliance/kiosk path, not a dev loop |

Screenshot the web build without a visible browser (handy for checking the
kiosk's real resolution, and for agents/CI):

```sh
flutter build web --profile && (cd build/web && python3 -m http.server 8100 &)
tool/shot.sh http://localhost:8100/ /tmp/panel.png 1920 1080
```

`tool/shot.sh` resolves Chrome as: explicit `$CHROME`, else
`$CHROME_EXECUTABLE` — which the devcontainer image sets — so this runs
in-container exactly as written; except on Apple-silicon hosts, where the
image ships no Chrome (amd64-only).

## Diagnostics

The Panel ends up on a wall with no keyboard and nobody watching a console,
so it explains itself in one greppable line per event:

A healthy start against the development Hub — from the browser console, from
the `flutter build web` command above plus `--dart-define=LOG=info`. Field
order is not cosmetic and is pinned by tests (`hub.config` renders in
`resolveHubConfig`'s argument order), so it is safe to grep for:

```
[panel] I panel.start hub=ha mode=profile platform=web log=info log_from=build
[panel] I hub.config HUB=build HA_URL=build HA_TOKEN=build GO2RTC_URL=absent env=unavailable
[panel] I popup.go2rtc url=absent
[panel] I house.loaded name="Demo House" floors=3 rooms=15 devices=33 bound=33 streams=1
[panel] I hub.configured url=http://localhost:18123 token=set
[panel] I hub.connecting url=ws://localhost:18123
[panel] I hub.connected url=ws://localhost:18123 devices=33
[panel] I hub.snapshot entities=66 bound=33 missing=0
```

`popup.go2rtc` carries the **address** in the clear, unlike the token on the
line below it — and so, since 2026-08-04, do the three `hub.*` lines under it.
They share one function (`lib/diagnostics/url_redaction.dart`), because the two
copies is how this went wrong: `GO2RTC_URL` was taught twice that userinfo is
not the only part of a URL that can carry a password, while `HA_URL`, one field
over in the same `HubConfig`, was printed whole on **every healthy `HUB=ha`
boot** and again on every reconnect
(`url=http://admin:hunter2@ha.local:8123`). What follows is therefore about all
four lines: scheme, host and port are what answer "is this Panel pointed at
the right go2rtc", and that question is otherwise invisible until somebody taps
a camera. Those three parts are **built up** into the line, not stripped out of
the value. The path is *not* one of them — it was on the list until it was
measured carrying a credential (`http://10.0.0.5:1984/hunter2/` published
`hunter2`), and a path is a reverse-proxy mount point whose presence is worth a
word and whose text is not, so it reports as `path=set` and only when it is
something other than `/`. A query and a fragment are the same bargain and
report the same way (`query=set`, `fragment=set`) — every dropped part gets a
word, so a shortened address can never read as "nothing was configured", and
the next part somebody adds to a URL needs a decision here rather than an
accident. go2rtc 1.9 has `api.username`/`api.password`, so
`GO2RTC_URL=http://user:pass@hub:1984` is a value an operator can legitimately
be handed. Its *presence* is reported as `auth=set`, in log.dart's own
`token=set` vocabulary: an operator who configured go2rtc auth has to be able
to see the Panel got it, rather than reading a shortened URL as "no
credentials".

Naming the parts to keep, rather than the part to drop, is the correction that
matters. This used to drop `Uri.userInfo` and print the rest, on the stated
ground that userinfo is the only part of a URL that can carry a credential —
true of go2rtc's basic auth, false of URLs, and `?password=…` and `#…` went
through whole. A named list excludes the next part somebody invents by
default instead of publishing it by default — and it is the shape that let the
path come *off* the list when a verifier put a token in one, without touching
anything else. Rejected, twice now: keeping the parts that "look safe". A value
with **no host** reads
`url=unusable` and is never echoed: `Uri.tryParse` almost never fails, and it
takes `admin:hunter2@hub:1984` apart as a scheme with the rest as a path —
nothing that looks like a credential to any accessor, so the strip-based
version printed it whole. If the parts cannot be seen, nothing can promise
what is in them; an honest unknown beats a confident wrong answer. Empty host
is also exactly the test `VideoConfig.urlFor` applies before dialling, so a
value this line calls unusable is a value that shows no picture either — one
fact, reported once.

The Hub's two connect lines take the **address alone**, with no `path=`/`auth=`
beside it. Their Uri is the one `HaHubClient.webSocketUrl` built, whose path is
always `/api/websocket` — the Panel's own constant, so `path=set` there would
appear on every Hub and mean nothing. `hub.configured` is the line that sees
the operator's own value and characterises it, once. And `webSocketUrl` still
carries userinfo and the query through to the socket on purpose: a Hub behind a
reverse proxy with basic auth, or an `?api_password=`, has to reach the
handshake. What changed is the log, not the dial.

`hub.socket_error` and `hub.connect_failed` are a different problem and get a
different treatment. They reproduce a sentence a **library** composed, and
`dart:io`'s `HttpException` appends `uri = <the whole URL>` to its own message
— the same shape go2rtc's error frames have, so they go through the same
best-effort `redactCredentials`, which finds URLs by their `scheme://` start
and cuts each one to its address. Best-effort is the honest word: that function
states in its own docstring where it stops.
`streams=` on `house.loaded` is the other half of `bound=`: how many
Devices can show a live view at all, and the only place a copy-pasted
`stream:` ever becomes countable, since two Devices watching one camera is
legal (nothing here writes to a camera, so they cannot fight).

and the same run when it is not healthy:

```
[panel] W hub.missing_entities ids=sensor.oven,climate.ecobee
[panel] W hub.state_unusable device=washer entity=sensor.lg_washer state=unavailable
[panel] I hub.state_recovered device=washer entity=sensor.lg_washer
[panel] W hub.reconnecting in_ms=4000 was_connected=true
[panel] E hub.auth_invalid reason="Invalid access token or password"
```

Same lines everywhere the Panel runs: `flutter run`, the browser console
(filter on the `[panel]` prefix), and on the appliance
`journalctl -u cage@tty1.service` — the Panel has no unit of its own; it is
whatever `cage@<tty>` launches (`appliance/ansible`'s `kiosk_tty`).
`hub.snapshot` / `hub.missing_entities` are the ones that earn their keep —
a Device pin that never fills in is otherwise completely silent, and the
cause is always an `entity:` the Hub has never heard of.

Level is `debug` in debug builds and `info` in release; override with
`LOG=debug|info|warn|error|off` in the environment, or
`--dart-define=LOG=…` (the only route on web). It resolves **environment
first**, exactly like `HUB`/`HA_URL`/`HA_TOKEN`/`GO2RTC_URL` — turning the
logs up on a
Panel already on the wall must not mean rebuilding it — and `log_from=` on
the `panel.start` line names the origin that won. Debug adds every state
change and every tap. A value neither origin can parse is reported as
`W panel.bad_log_level`, never thrown: a typo in a diagnostics flag must
not be why the wall panel comes up black. `Log.installErrorHandlers()`
routes framework and uncaught errors through the same channel, so a crash
leaves a `[panel] E` line rather than only a red screen nobody is standing
in front of.

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

### The web half runs nowhere unless you ask for it

`flutter test` is a **VM** build, so every `if (dart.library.js_interop)`
branch in the tree is not skipped by it — it is absent from it. That includes
the whole MSE player and the web sides of `runtimeEnvironment` and the
snapshot fetcher. Until 2026-08-07 none of it executed on any machine.

```sh
flutter test --platform chrome \
  test/bindings_parser_test.dart test/boot_test.dart test/device_popup_test.dart \
  test/device_presentation_test.dart test/device_traits_test.dart \
  test/device_vocabulary_test.dart test/doorbell_test.dart test/floor_scene_test.dart \
  test/floor_view_test.dart test/house_loader_test.dart test/hub_config_test.dart \
  test/live_video_keepalive_test.dart test/live_video_mse_web_test.dart \
  test/log_test.dart test/url_redaction_test.dart
```

**237 pass** in the devcontainer (Chrome 151, `CHROME_EXECUTABLE` already set
by the image). The list is explicit rather than `flutter test --platform
chrome` over `test/` because most files reach `dart:io` — directly, or through
`test_house.dart`, which reads the House Plan off disk — and a browser build
cannot compile them. That is a property of the fixtures, not a gap: those
suites are VM suites and the VM runs them.

`test/live_video_mse_web_test.dart` is `@TestOn('browser')`, so it is the one
file that runs *only* here, and it is the first automated coverage the MSE
player has ever had.

**What it deliberately does not cover, measured rather than assumed:**
mounting `MseLiveVideoSession.view` in a `testWidgets` pump never fires
`onElementCreated` under `--platform chrome` — the platform-view registry is
stubbed in the harness, so no DOM element is created and nothing is
re-parented. A test asserting the view there would pass while exercising none
of it. So phase 4's open item 3 stays open on purpose, and the `view` /
`_resume` path is guarded by the browser procedure in
[The web build must not need the internet](#the-web-build-must-not-need-the-internet)
instead — which is what found its two bugs on 2026-08-06.

`test/golden/` renders the whole Panel to PNGs — headlessly, no browser and
no server — for four scenes: ground floor, upstairs selected, a Device
Popup, and an unreachable Hub. They catch unintended changes to the
dollhouse's shape, and on failure write `failures/*_isolatedDiff.png`
showing exactly what moved.

**The devcontainer is the canonical golden host**
([ADR-0009](../docs/adr/0009-development-in-the-devcontainer-on-the-target-os.md)):
the goldens were baked in it 2026-08-06. The VM suite there runs **431 pass /
2 skip / 0 failures** (re-measured 2026-08-07; it was 398/1 when the goldens
were baked, and the goldens themselves have not moved since — the growth is
new tests, not new scenes). Green is promised there and nowhere else — a
host renders with its own font stack, so red on any non-container host is the
expected state, and the host's problem rather than the goldens'. Red
*in-container* is the signal that matters: a real rendering change, or a
moved SDK pin — investigate before touching `--update-goldens`, and never
re-bake outside the devcontainer.

*Historical note:* five goldens ran red on the Ubuntu 26.04 Hub host through
2026-08-05 — font drift from the 25.10 → 26.04 upgrade, tracked as
[phase-0 item 13](../docs/plans/device-integrations/phase-0-laptop-bring-up.md)
— and the problem was unresolvable while the goldens were baked on one host
and checked on another: any golden change meant one host green and the other
could not be. The in-container bake **closed item 13**: cross-host drift
stopped being a defect the day green stopped being promised on hosts.

```sh
flutter test test/golden                    # check
flutter test --update-goldens test/golden   # re-bake — devcontainer only; then look at them
python3 tool/test_sh3d_to_yaml.py           # the converter's own suite
```

Regenerating is also the fastest way to just *see* the Panel while working
on it. Two things make the images faithful that flutter_test does not do by
default: real fonts (loaded from the Flutter SDK's cache, so no font
binaries in the repo) and real shadows (`debugDisableShadows`, without
which the neumorphic look disappears).

Matching is exact, and with one canonical host it can stay exact: at
1280×800 even a 1% tolerance is ~10,000 pixels while a whole 34px Device pin
is only ~1,150, so a loose tolerance would let an entire pin change
unnoticed. The `tolerance` dial on `setUpPanelGoldens` existed to reconcile
two rendering hosts (a Mac baking, a Linux laptop checking); that framing is
obsolete — one image both bakes and checks, so there is no cross-host drift
left to absorb, and red elsewhere is answered by running the check
in-container, not by loosening the match. When a golden does move
in-container: regenerate and eyeball the diff, don't rubber-stamp a failure.
