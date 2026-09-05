# Panel deepening plan — 2026-09-02

The refactoring plan behind the 2026-09-02 architecture review of the Panel
(`panel/`), written against HEAD `1463ebb` with a clean tree. The review's
report, with before/after diagrams, is the artifact at
<https://claude.ai/code/artifact/d8339e30-ffb0-4b6b-a116-522b82a4c5f2>. This
file is the *plan*: what to change, in what order, with which tests, and what
"done" looks like for each step. Line numbers are as of `1463ebb` and will
drift — every step says what to grep for so the drift does not matter.

Vocabulary: **module / interface / implementation / depth / seam / adapter /
leverage / locality** from the codebase-design skill; domain terms from
`CONTEXT.md` (Panel, Popup, Cameras, Stream Director, Camera Health, Talk).
Decisions in `docs/adr/` are not reopened here; where a step touches one, the
ADR is named and the step stays on its side of the line.

## How this plan was produced

Seventeen agents in one workflow: three re-verified the 2026-08-28 review's
seven open candidates against the current tree; five explored one area each
(video seam, Popup, Cameras + composition root, data/domain/Dollhouse, test
shape); one merged seventeen raw findings into eight; eight skeptics tried to
refute each new one by reading the code. Three new candidates survived, five
were refuted with corrections that are recorded below so they are not
re-proposed. Every anchor was re-opened; measured counts replaced estimates.

## Ground rules for every step

- **Git discipline (CLAUDE.md):** every change is left unstaged. Nothing here
  is `git add`ed or committed by an agent; the owner reviews and lands.
- **Phase discipline (ADR-0013's own):** each step is a revertable unit whose
  observable behaviour is provably unchanged, *unless* the step says
  otherwise in a line that starts with **Behavioural delta:**. There is
  exactly one such delta in the whole plan (B.2) and it is a fix the tests
  pin.
- **Verification recipe** (run inside the devcontainer, ADR-0009):
  ```sh
  cd panel
  flutter analyze
  flutter test                         # hermetic; goldens included
  flutter test test/golden --update-goldens   # ONLY if a step says pixels may move — none does
  ```
  A step that touches composition (Phase A) also gets one look at the real
  wall: `CAMERAS_OPEN=auto` with `tool/freeze_probe.sh` (ADR-0012's rig) —
  the probe's own PLAYING verdict, plus a sane `cameras.opened auto_live=`
  / `cameras.closed live=` pair in the journal (those are the lines that
  carry a count; `cameras.tile_open` carries only the stream name).
- **Neumorphism (CLAUDE.md):** any widget this plan adds (Phase F's
  `StillWatching`, Phase B's corner tag) builds from `PanelTheme` and reuses
  the shared shapes. No stock Material chrome.
- **Docs move with code.** Each phase ends with the doc lines it makes stale.
  The one that recurs: `docs/plans/device-integrations/phase-8-handoff.md`
  has already drifted from the grab gate twice (see Phase C).

## Sequencing

| Phase | Candidate | Strength | Why here |
|---|---|---|---|
| A | One seam for every video surface | Strong | Deletion-heavy; makes every test run the composition the wall runs. Phases C and D add members to this seam and are only worth testing once the tests hit it. |
| B | One CameraFace for the not-live copy | Strong | Fixes a wrong word on the wall today. Independent of A; second because A changes the fixtures B's tests use. |
| C | The still-grab gate behind the Director seam | Strong | Retracts two seam getters. Wants A first (tests then drive the Director the fixture built). |
| D | The Director answers the live census | Worth exploring | Same file family as C; small; do it in the same sitting. |
| E | A contract suite for the video seam | Worth exploring | No production change; shrinks once A removes `_CountedSession`. |
| F | IdleReturn | Worth exploring | Landed 2026-09-03, early at the owner's call (phase-8-handoff.md:769). |
| G | PopupClaim | Worth exploring | **Landed 2026-09-04** at the owner's call, ahead of its trigger. |
| H | Transport tuning through the seam | Worth exploring | **Landed 2026-09-04** at the owner's call; the gate was answered rather than waited on — see the phase. |
| I | go2rtc's address, parsed once | Speculative | **Landed 2026-09-04**, at the owner's call, after H. |
| J | Composition-root prop drilling | Speculative | Re-measure after A; probably dissolves. |
| K | Small tidies | — | Survivors of the refuted candidates; each is an afternoon. |

A, B, C, D and E are recommended in that order; F, G, H and I landed at the owner's call. J waits for its trigger.

---

## Phase A — One seam for every video surface

**Status: landed 2026-09-02, unstaged, awaiting the owner's review.** A.1,
A.2 and A.3 below are done as written, with three deviations worth knowing.
First, the hermetic adapter lives in `test/support/hermetic_director.dart`
(beside the other fakes) rather than inside `test/fixtures.dart`, and every
fixture call site gives it a `UniqueKey`, so a second `pumpWidget` in one
test gets a fresh Director instead of silently keeping the first one's
opener. Second, the fixture takes a `VideoConfig video` rather than the
sketched `FakeGo2rtc go2rtc` + `go2rtcUrl` pair: `VideoConfig` is exactly
what `StreamDirector` consumes, so `panelApp`, `pumpPanel`, `openPopup` and
`HermeticDirector` keep their `video:` parameter and flow it into the
Director — no consumer call site had to drop `video:`, and the ~80-site
mechanical edit forecast in A.2.5 did not happen. Third, `panelApp` also
takes `policy:` and `health:` for the Director it builds, and asserts that a
case bringing its own `director:` passes nothing beside it (the unread-
argument trap, closed in the fixture as well as in lib). Verified:
`flutter analyze` clean; `flutter test` 644 passing, 2 skipped (646 before —
the two deleted cases were the pass-through group); a four-lens adversarial
review of the diff found no behavioural defect and twenty documentation or
fixture findings, all applied. The repo does not follow `dart format`, so
nothing was reformatted.

**The real-wall look is done — 2026-09-03, on the Legion against the live
Hub's go2rtc, on a release bundle built from this working tree.** Both
halves of the recipe:

- `tool/freeze_probe.sh` (shipped Skia): **5/6 cells moving**, the healthy
  signature its own header predicts — the sixth is the idle Ring Doorbell
  tile, which never auto-lives (#177014). Both grabs were read, not just
  the verdict table: five cameras live with badges, and every burned-in
  camera clock advanced across the pair and converged, so these are
  flowing streams rather than stalled ones. `panel.renderer impeller=false`
  confirms ADR-0012's pin still holds.
- The journal pair: `cameras.opened tiles=7 auto_live=5` with exactly five
  `cameras.tile_open` lines, and `cameras.closed open_s=246 live=5`.

The `auto_live=5` half is the Phase A change measured end to end: that
count is computed through the Director's own `VideoConfig` now, and it
agrees with the five tiles that actually dialled. Getting the closed line
took three attempts, and the two that failed were instructive rather than
faulty — the first was stopped 25 s before the idle return was due, and
the second recorded six zoom events, i.e. the view was being tapped and
every pointer event re-arms the five-minute clock exactly as designed. The
third was closed with the close puck.

**Goal.** Every video surface takes a `StreamDirector`, required, and nothing
else for video. The hermetic fallback (a Director built over a fake opener)
exists in exactly one place: the test fixture. `main()` builds one
`VideoConfig`, not two. `StreamDirector.open`, `_CountedSession` and the dead
`countCensus` parameter are deleted.

**Why.** The Director seam has a second adapter nobody chose: a surface-built
Director over a `VideoConfig` that exists only to feed it. Today 100 % of the
Popup suite (58 cases) and 28 of 31 Cameras cases run that private path; the
wall never does (every forward in `main.dart` passes `director:` —
`:386, :437, :464, :483, :500`). A forgotten `director:` degrades silently:
Camera Health and the census stop hearing from that surface, the wall looks
fine. `TODO.md:114` already has to allow for "or the Popup got a fallback
Director" when reading a parked tile. The handoff's N7 (`phase-8-handoff.md:715-719`)
records the policy trap: the fallback constructs `const DirectorPolicy()`
(auto-live), so a stills-first flip in `main()` never reaches a fallback.

**Current state (anchors).**

| What | Where |
|---|---|
| VideoConfig #1 over `keepAlive.open`, into the Director | `lib/main.dart:210` |
| VideoConfig #2 over `director.open`, into `PanelApp.video` | `lib/main.dart:227` |
| `PanelApp{required video, director?}` | `lib/main.dart:298, :303` |
| `DollhouseView{video, director?}` — "Carried unread, exactly like [video]" | `lib/ui/dollhouse/dollhouse_view.dart:91-92, :101`; forwards at `:407-411` |
| `DoorbellPopupHost{required video, director?}` | `lib/ui/doorbell_popup_host.dart:85-86`; forwards at `:293-296` |
| `showDevicePopup{video, director?}` / `_DevicePopupBody` | `lib/ui/device_popup.dart:64-68, :277` |
| Popup fallback `widget.director ?? (_ownDirector = StreamDirector(video: widget.video))` | `lib/ui/device_popup.dart:653`; field `:323`; disposed `:610` |
| `showCamerasView{video, director?}` / `CamerasView` | `lib/ui/cameras/cameras_view.dart:87-94, :130, :135` |
| Cameras fallback `widget.director ?? StreamDirector(video: widget.video)` with `_ownsDirector` | `lib/ui/cameras/cameras_view.dart:209`; `:168, :208`; ownership-dependent dispose `:279-285` |
| The only wall-path read of `widget.video`: the `auto_live` log count | `lib/ui/cameras/cameras_view.dart:222-228` |
| `StreamDirector.open` (counted pass-through) and `_CountedSession` | `lib/ui/video/stream_director.dart:528-545, :1149-1175` |
| `_dropSession({required bool countCensus})` — both callers pass `true` | `lib/ui/video/stream_director.dart:1137`; callers `:836, :842` |
| Class doc still promising "a view that was not handed one builds its own" | `lib/ui/video/stream_director.dart:441-445`; header `:29-31` |
| Stale comment describing `director.open` as the Popup's fallback seam | `lib/main.dart:206-208` |
| Fixture default `StreamDirector? director = null` | `test/fixtures.dart:147`; `panelApp()` `:139-161` |
| Popup suite's own rig, never via `panelApp()` | `test/device_popup_test.dart:82-108` (`openPopup`) |
| Forwarding-pin test ("drop the director: argument anywhere on the way down and nothing goes red") | `test/dollhouse_test.dart:250-282` |
| Pass-through group for `open()` | `test/stream_director_test.dart:652-683` |
| "No Timer left pending" is checked at tree disposal, *before* tear-downs | `test/device_popup_test.dart:920-924` |
| Dial-spacing gate Timer (400 ms default) the view-owned Director cancels at unmount | `lib/ui/video/stream_director.dart:260, :594-599`; `cameras_view.dart:279-281`; handoff rule 9 `phase-8-handoff.md:288-289` |

**Invariants to keep.**
- `StreamDirector` is one per process on the wall, never disposed there
  (`main.dart:196-208`).
- ADR-0013: the Popup attaches `FeedRole.popup`; the ding arbitration, route
  and clocks stay Popup-side. Untouched by this phase.
- The census is shared and has one entry point after this phase: `attach()`.
- No widget test may leave a Timer pending at tree disposal.

### A.1 — Give the fixture a Director that owns its timers

*Behaviour unchanged. Tests only.*

1. In `test/fixtures.dart` add one helper that every hermetic rig uses.
   Shape (sketch, not final):
   ```dart
   /// Wraps [child] in a State that owns a StreamDirector over [go2rtc]
   /// and disposes it when the tree is torn down — children first, then
   /// this State, so every feed has released before the Director's
   /// admission Timer is cancelled. This is the ONE hermetic adapter at
   /// the Director seam; production's is main().
   class HermeticDirector extends StatefulWidget {
     const HermeticDirector({
       required this.go2rtc,           // FakeGo2rtc from test/support
       this.go2rtcUrl = 'http://hub:1984',
       this.policy = const DirectorPolicy(),
       this.health,                    // FakeHealth or null
       required this.builder,          // (context, director) => child
     });
   }
   ```
   `panelApp(...)` gains `FakeGo2rtc? go2rtc` and builds `PanelApp` inside
   `HermeticDirector` when no `director:` is passed. Cases that pass their own
   `director:` (`cameras_view_test.dart:328, :369`; `camera_health_test.dart:205`)
   keep passing it and keep owning its dispose.
2. In `test/device_popup_test.dart`, `openPopup` (`:82-108`) wraps its
   `MaterialApp` in the same `HermeticDirector`. This is the correction the
   skeptic forced: the Popup suite never touches `panelApp()`, so "the
   fixture" must be reachable from two entry points.
3. `test/golden/golden_setup.dart`'s `pumpPanel` builds `PanelApp` directly
   with the seven parameters; give it the same wrapper. Goldens do not move:
   the Popup renders identically over a fixture Director.
4. Run `flutter test`. Everything is still green because nothing in `lib/`
   changed; the fallbacks are simply never reached now. Grep to confirm:
   `grep -n "director: null" test/` should find nothing new.

**Done when:** every widget suite that opens a Popup or the Cameras view does
so through a fixture-owned Director, and `flutter test` is green with no
pending-Timer failures.

### A.2 — Make `director` required on the seven interfaces; drop `video`

*Behaviour unchanged on the wall (it already passes `director:` everywhere).*

1. `lib/ui/cameras/cameras_view.dart`
   - `showCamerasView(...)` and `CamerasView(...)`: `required StreamDirector director`; remove `video`.
   - `_CamerasViewState.initState` (`:209`): `_director = widget.director;` — delete the `??`, delete `_ownsDirector` (`:168, :208`).
   - `dispose` (`:279-285`): always `_director.overlaid = false`; never dispose the Director (it is the wall's or the fixture's).
   - The `auto_live` count (`:222-228`) reads `_director.video.urlFor(...)` — `StreamDirector.video` is already a public final field (`stream_director.dart:452`).
2. `lib/ui/device_popup.dart`
   - `showDevicePopup(...)` and `_DevicePopupBody(...)`: `required StreamDirector director`; remove `video`.
   - `_attachVideo` (`:653`): `widget.director.attach(...)`; delete `_ownDirector` (`:323`) and its dispose (`:610`).
   - The unconfigured/skip reasons already come from the Director (ADR-0013 moved them); nothing else reads `widget.video`. Grep `widget.video` in the file to be sure.
3. `lib/ui/dollhouse/dollhouse_view.dart:91-121` and `lib/ui/doorbell_popup_host.dart:85-120`: keep `director` (now required), delete `video`, delete the "carried unread" paragraphs that only existed to explain the pair.
4. `lib/main.dart`
   - `PanelApp`: `required this.director`; remove `video` (`:298-312`).
   - Delete VideoConfig #2 (`:227`) and the comment at `:206-208`.
   - Every forward: drop `video:`.
5. `test/fixtures.dart` and every test call site that passed `video:` to
   `panelApp`, `showDevicePopup`, `showCamerasView`, `DollhouseView` or
   `DoorbellPopupHost`: pass the go2rtc URL / fake through `HermeticDirector`
   instead. Expect ~20 `panelApp()` call sites and the 57 `openPopup` uses to
   need a mechanical edit — most only drop `video:`.
6. `test/dollhouse_test.dart:250-282` (the forwarding pin) reduces to its
   `dialOutcome` assertion or is deleted: a required parameter cannot be
   dropped, which was the whole point of the test.

**Done when:** `grep -rn "StreamDirector(" panel/lib` finds only `main.dart`;
`grep -rn "director ??" panel/lib` finds nothing; `flutter analyze` is clean;
`flutter test` is green; goldens unchanged.

### A.3 — Delete the counted pass-through

*Behaviour unchanged: nothing on the wall dialled it.*

1. `lib/ui/video/stream_director.dart`: delete `open()` (`:528-545`) and
   `_CountedSession` (`:1149-1175`); delete the `countCensus` parameter of
   `_dropSession` (`:1137`) and its two `true` arguments (`:836, :842`).
2. Header (`:29-31`): remove the sentence about "[open], the counted
   pass-through, remains for any unmanaged caller". Class doc (`:441-445`):
   remove "a view that was not handed one builds its own"; say instead that
   the fixture builds one.
3. `test/stream_director_test.dart:652-683`: delete the pass-through group.
   Keep any case in it that pins the census count through `attach()` (move
   it beside the other census cases).
4. `TODO.md:114`: drop "or the Popup got a fallback Director" from the
   diagnostic recipe. `docs/plans/device-integrations/phase-8-handoff.md:715-719`
   (N7): add one line that the trap is closed by construction.
5. `CONTEXT.md` → *Stream Director*: the entry already says "Every video
   surface opens through it as a managed feed"; no change. Add nothing.

**Done when:** `grep -rn "_CountedSession\|countCensus\|director.open" panel/`
is empty; `flutter test` green.

**Risks and the way back.** The only mechanical risk is Timer hygiene in
tests: the fixture Director must be disposed *during* tree teardown (a
`State.dispose`), not in `addTearDown`, because the pending-Timer check runs
first. A.1 exists to prove that before A.2 touches `lib/`. Revert is one
commit per sub-step; A.1 alone is harmless to keep.

**Follow-ups this unlocks.** Phase J's `{video, director?}` pair is already
`{director}`. Phase E's matrix is six adapters wide, not seven.

---

## Phase B — One CameraFace for the not-live copy

**Status: landed 2026-09-02, unstaged, awaiting the owner's review.** B.1
and B.2 are done as written: `lib/ui/video/camera_face.dart` holds the
latch, the birth read, the phase+retryAttempt listener pair and the "re-"
predicate; the Popup box, the tile and the zoom each hold one and keep their
own phrase table; `_FaceTag` and `_TapForLive` are one `_CornerTag`; the
feed fake moved to `test/support/fake_feed.dart`. One deviation from the
sketch: the predicate's "re-dial in flight" arm also covers `queued` and
`idle` beside `connecting`, because the zoom's phrase table treated those
three arms alike (a timer-born re-dial passes through `queued`) and a
narrower predicate would have changed its words. The surfaces' field is
named `_cameraFace` because the tile already had a `_face()` method. The
behavioural delta landed, narrower than first written: a straight
playing→failed death on a born-playing tile or zoom already said
"Reconnecting…" at HEAD, because the Director climbs the count before it
flips the phase and both surfaces listened to the count while the phase
still read playing; what the birth read fixes is the player dropping back to
`connecting` before it fails. The review caught that the first version of
the three born-playing widget pins passed without the birth read for
exactly that reason, so all three (the Popup's existing one and the two new
Cameras cases) now route the death through `connecting` first. The same
shared predicate also moves the Popup's `queued` cell (a ladder re-dial
held at the admission gate keeps "Reconnecting to the camera…"), declared in
B.2 and pinned by a new Popup case over a full `maxConcurrent` cap. The
golden is byte-identical. Verified: `flutter analyze` clean; `flutter test`
653 passing, 2 skipped (+6 unit, +3 widget). One full run also showed
`live_video_rtsp_test.dart` "the opener never throws" failing — a
pre-existing case that builds a real player against a platform channel;
it passed three times in isolation and in the full rerun, and this phase
touches nothing in that file.

**Goal.** One in-process module turns a `CameraFeed` into the small verdict
every not-live face needs — did a picture ever arrive, is this a
reconnection, what is the human attempt count — with the latch, the
birth read and the dual listening in one place. Each surface keeps its own
phrase table and frame as data (ADR-0013: "one phase table per surface").

**Why.** Three copies of the `_sawPlaying` latch have drifted in *semantics*,
not just words:

| Copy | Latch | Birth read | Listens to | Predicate |
|---|---|---|---|---|
| Popup box `_LiveVideoBoxState` | `device_popup.dart:1207` | **yes** `:1215` | phase only `:1216` (reads `retryAttempt` at `:1257` without listening — against `stream_director.dart:388-393`) | `:1254, :1257` |
| Tile `CameraTileState` | `cameras_view.dart:606` | **no** — `:641` reads `_wasActive` only | both `:636, :640` | `:882-883, :891` |
| Zoom `_ZoomedCameraState` | `cameras_view.dart:1058` | **no** — `:1077` | both `:1072, :1076` | `:1132-1140` |

A feed *can* be born playing — the keep-alive pool hands back a lingered
session at attach (`stream_director.dart:855-857`), and
`cameras_view_test.dart:957` proves tiles re-attach that way. A tile born
playing whose player drops back to `connecting` before it fails (the MSE
rebuild after a media-element error, `stream_director.dart` `_onPlayerPhase`)
says "Connecting…" through the whole ladder, over a picture that was up: the
lie ADR-0013 says the latch exists to prevent ("re-" claims a restoration).
A straight playing→failed death is saved only by an ordering accident: the
Director climbs the count before it flips the phase, and the tile listened
to the count while the phase still read playing.
Nothing pins the tile's positive "Reconnecting…" (`cameras_view_test.dart:771`
is a `findsNothing`). Also in this file family: `_FaceTag` (`:1182`) and
`_TapForLive` (`:1208`) are the same `Container` drawn twice — the CLAUDE.md
"same shape drawn twice drifts" miss.

**Design (sketch).** `lib/ui/video/camera_face.dart`:

```dart
/// The shared core of every not-live face: a feed's phase, whether a
/// picture was ever up in this face's life, and whether the current wait
/// is a restoration. Listens to BOTH notifiers (retryAttempt can climb
/// with no phase change); reads the born value (a listener never fires
/// for the value it was born with). Surfaces keep their own words.
class CameraFace extends ChangeNotifier {
  CameraFace(this.feed) {
    _sawPlaying = feed.phase.value == FeedPhase.playing;   // birth read
    feed.phase.addListener(_changed);
    feed.retryAttempt.addListener(_changed);
  }
  final CameraFeed feed;
  FeedPhase get phase => feed.phase.value;
  bool get sawPlaying => _sawPlaying;
  /// "Reconnecting" is honest only over a picture that was up.
  bool get reconnecting => switch (phase) {
    FeedPhase.retrying => _sawPlaying,
    FeedPhase.connecting => _sawPlaying && feed.retryAttempt.value > 0,
    _ => false,
  };
  /// The human count: "try #2" is the first re-dial.
  int get attempt => feed.retryAttempt.value + 1;
  bool get counting => feed.retryAttempt.value > 0;
  @override void dispose() { /* remove both listeners */ }
}
```

Deliberately **not** in the module: any sentence, any icon, the still, the
corner tag, `isActive`/`wantKeepAlive` (that is Phase D's business), the
Popup's `unconfigured` placeholder (a golden pins its pixels).

Alternative the video-seam explorer raised, worth a line in the grilling:
"a picture was up since attach" is also a Director fact (it resets the
ladder at playing, `stream_director.dart:868/:897`, and reports `connected`).
Exposing `restoring` on `CameraFeed` would make `CameraFace` a pure function
of `(phase, attempt, restoring)` and remove the latch from the Panel
entirely. Not required for this phase; it is a second step if the owner
wants it.

### B.1 — Add the module and its unit suite

*Behaviour unchanged (nothing uses it yet).*

1. Move `timed_feed_test.dart`'s `_RecordingFeed` (`:15`) to
   `test/support/fake_feed.dart` as `FakeFeed implements CameraFeed` with
   settable `phase` and `retryAttempt` notifiers.
2. Write `test/camera_face_test.dart` (plain `test()`, no widgets):
   - born playing → `sawPlaying` true from construction;
   - playing → retrying → `reconnecting` true; connecting with count 0 → false; connecting with count > 0 after a picture → true;
   - retrying → retrying with the count climbing notifies listeners (the "counted face freezes" bug the tile's comment describes);
   - born connecting that keeps failing → never `reconnecting` (a first connect has nothing to restore);
   - stop to idle → count reset is the Director's (`stream_director_test.dart:270-350` already pins it); the face only reflects it;
   - dispose removes both listeners (assert with the fake's `hasListeners`).

### B.2 — Re-seat the three surfaces on it

**Behavioural delta:** the tile and the zoom gain the Popup's born-playing
rule. A tile or zoom re-attached to a lingered picture whose player drops
back to `connecting` before it fails now reads "Reconnecting…" (tile) /
"Reconnecting… try N" (zoom) instead of "Connecting…" (a straight death
already read "Reconnecting…", by the count-before-phase accident above).
Pinned by two new widget cases (below). One more cell moves with the shared
predicate: a camera Popup's ladder re-dial parked at the admission gate
(`queued`, count above zero) keeps "Reconnecting to the camera…" instead of
dropping to "Connecting…" for that wait — latent on today's wall, pinned by
a Popup case over a full `maxConcurrent` cap. Nothing else moves on any
reachable screen.

1. `lib/ui/device_popup.dart` `_LiveVideoBoxState` (`:1199-1290`): replace
   `_sawPlaying`, `initState`'s birth read and the phase listener with one
   `late final CameraFace _face = CameraFace(widget.feed)` and
   `_face.addListener(_rebuild)`. `_body` switches on `_face.phase` and
   `_face.reconnecting`; the phrase table (`:1263-1284`) is unchanged.
2. `lib/ui/cameras/cameras_view.dart` `CameraTileState` (`:598-1010`):
   same swap; `_onPhase` keeps only the `_wasActive`/`onWent` diff (until
   Phase D) and `setState`. `_face()` (`:871-903`) and `_stillFace`
   (`:912-963`) read `_face.reconnecting` where they read `_sawPlaying`.
3. `_ZoomedCameraState` (`:1050-1161`): same swap; `_body()` (`:1116-1160`)
   reads `_face.counting`, `_face.attempt`, `_face.reconnecting`.
4. Replace `_FaceTag` (`:1182`) and `_TapForLive` (`:1208`) with one
   `_CornerTag(String text)` built from `PanelTheme` (same margin 8, padding
   8/3, surface α .85, radius 10, 10 px w700 `inkFaint`).
5. Tests to add (`test/cameras_view_test.dart`): "a tile born playing off
   the pool that then fails says Reconnecting…" and the zoom twin. Tests to
   keep unchanged: every sentence pin in `device_popup_test.dart`
   (`:239, :283, :324, :929-957`) and `cameras_view_test.dart` (`:770-835, :870`).
   Golden `test/golden/goldens/device_popup.png` must not change.

**Done when:** `grep -rn "_sawPlaying" panel/lib` finds only
`camera_face.dart`; `grep -rn "retryAttempt.addListener" panel/lib/ui` finds
only `camera_face.dart`; `flutter test` green; goldens byte-identical.

**Docs.** ADR-0013's "the third copy of that latch on the Panel, and the
clearest argument yet for the shared CameraFace module" — add a one-line
forward pointer that it landed (edit the ADR in place, per
`docs/adr/README.md`'s rule). `CONTEXT.md`: no new term — "CameraFace" is a
module name, not a domain word; do not add it.

---

## Phase C — The still-grab gate behind the Director seam

**Status: landed 2026-09-02, unstaged, awaiting the owner's review.** C.1
and C.2 are done as written: `CameraFeed.stillGrabAllowed` is the one
verdict, computed in `_Feed` beside the dial rule, forwarded by `TimedFeed`;
the tile's `_grabAllowed`, its `_tileVisible` mirror, `CameraFeed.reachability`
and the `StreamDirector.overlaid` getter are gone; the interface member's
doc carries the four arms' reasons that used to sit on the tile. Getter, not
listenable (the 60 s cadence reads it at fetch time; the grilling question
stays open). Two calls the plan left to the owner: the five widget cases in
`cameras_view_test.dart` were **kept** as loop-meets-verdict pins rather
than deleted, since each asserts through the tile's own interface
(FakeSnapshots request counts), and the Director suite gained five cases
under "the still-grab gate" — including the viewport arm, which no widget
test ever reached. Of the five widget cases, the view-open and health ones
are the per-site pins (the initState fetch and the periodic tick); the
pursuing and overlay ones are kept deliberately as layered arm coverage on
the wall rig, not because the seam needs them — the agent's provisional
call, confirmed by the review, and the owner's to reverse. `FakeFeed`
carries a settable `stillGrabAllowed`. The handoff's two drifts (queued
grab-allowed — which, per the history, the shipped gate never was; the
offline arm untested) are fixed in place, and the sibling drift in
`phase-8-cameras-streaming.md` got the same note. Verified: `flutter
analyze` clean; `flutter test` 658 passing, 2 skipped (+5 unit); a
three-lens adversarial review confirmed the truth table identical to HEAD
for every (phase, health, viewport, overlay) cell and found sixteen
documentation and formatting findings, all applied. Behaviour on the wall
unchanged — the tile evaluates the same four facts through one member
instead of three reads.

**Goal.** The feed answers "is a still worth grabbing right now" as one fact
computed where the four inputs live, next to the dial rule that already ANDs
them. Two seam members that exist only for the gate retract; the tile's
private viewport mirror goes.

**Why.** `_grabAllowed` (`cameras_view.dart:735-750`) ANDs four facts —
phase allow-list, Camera Health verdict, viewport, overlay — that the
Director's `_Feed` already holds and already ANDs in `_resume`
(`stream_director.dart:1009-1014`). Two of them cross the seam through
members whose docs say they exist for this one reader:
`CameraFeed.reachability` (`:396-404`, one production reader at
`cameras_view.dart:746` plus a forced pass-through at `timed_feed.dart:106`)
and `StreamDirector.overlaid`'s getter (`:497-500`, one reader at `:748`;
every other `.overlaid` in lib and test is the setter). The third,
viewport, is mirrored as `_tileVisible` (`:611`, written `:818`, pushed
`:819`, read `:747`) because `CameraFeed.visible` is a push-only setter
(`:376`). The Director's own header names the widget private `_grabAllowed`
by name (`:102-104`). The handoff line listed `queued` as grab-allowed
(`phase-8-handoff.md:680-681`); the shipped gate never did (`:739-745`,
test `:398`) — the handoff drifted from day one.

**Design (sketch).** On `CameraFeed`:

```dart
/// Whether a go2rtc frame grab is worth its keyframe dial right now:
/// nothing is being pursued (idle, unconfigured, unsupported — NOT queued,
/// whose dial is about to go out), Camera Health does not say
/// unreachable, the surface is visible, and no overlay covers it. The
/// HA-held still has none of these gates and does not ask.
bool get stillGrabAllowed;
```

Computed in `_Feed` beside `_resume`; `TimedFeed` forwards it (and stops
forwarding `reachability`). Listenable or getter: start as a getter — the
still loop is a 60 s timer that reads the gate at fetch time
(`kCamerasSnapshotRefresh`), and a health-flip wake-up is a separate
decision the grilling can take.

### C.1 — Add the fact, keep the old gate

1. `stream_director.dart`: add the getter to `CameraFeed`, implement in
   `_Feed`, forward in `TimedFeed`.
2. `test/stream_director_test.dart` (`FakeGo2rtc` + `FakeHealth`; fakeAsync
   only where the phase ladder is driven):
   pursued (queued/connecting/playing/retrying) → false; `unreachable` →
   false, flips back → true; `overlaid = true` → false; `visible = false` →
   false; idle + reachable/unknown + visible + not overlaid → true;
   unconfigured and unsupported → true (the still is the whole face there).
   The viewport arm has **no** test today — this is where it gets one.

### C.2 — Switch the tile, retract the members

1. `cameras_view.dart`: `_fetchStill` (`:768`) reads
   `_feed.stillGrabAllowed`; delete `_grabAllowed` (`:708-750`), delete
   `_tileVisible` (`:611`) and its write (`:818`) — keep the push
   `_feed.visible = info.visibleFraction > 0` (`:819`).
2. `stream_director.dart`: delete `CameraFeed.reachability` and its doc
   (`:396-404`), the `overlaid` getter (`:497-500`, keep the setter), and
   rewrite the header sentence at `:102-104` so it no longer names a widget
   private. `timed_feed.dart:106`: delete the pass-through.
3. `cameras_view_test.dart`: the five gate cases (`:258, :297, :323, :365, :398`)
   keep passing — they count `FakeSnapshots` requests through the widget.
   Keep the fetch-side ones (bills the substream tokenless; the doorbell
   canary; main-only grabbed on main); the pure gate cases may be deleted
   once C.1's Director cases cover them, or kept as integration pins — the
   owner's call; deleting is the "replace, don't layer" default.
4. Docs: `phase-8-handoff.md:680-681` (queued is *not* grab-allowed) and
   `:699` (the offline arm *is* tested, since `:323` landed).

**Done when:** `grep -rn "_grabAllowed\|_tileVisible\|\.reachability" panel/lib`
is empty; `flutter test` green.

---

## Phase D — The Director answers the live census

**Status: landed 2026-09-03, unstaged, awaiting the owner's review.** D.1 is
done as written: `StreamDirector.activeFeeds({roles})` is the new per-role
fold over `_feeds` (not `_activeSessions`, per the skeptic); the Cameras
view snapshots it in `deactivate()` (parent-first, every tile and zoom feed
still attached) and logs it in `dispose()`; `onWent` left both widget
interfaces, `_live`, `_tileWent` and the two zoom-transition special cases
left the view, the zoom lost its `_wasActive` mirror entirely, and the tile
keeps its own for `wantKeepAlive` alone. The seven census comment blocks
(four of them explaining the unmount order) reduced to one explanation on
`_closingLive` plus a one-line pointer at each hook. The `auto_live` count
at open was left where it is, as the review required. Verified: `flutter
analyze` clean; `flutter test` 660 passing, 2 skipped (+2 unit cases in a
new "the closing census" group of the Director suite, including that a
Popup feed is not counted under the grid's roles); the two existing widget
pins (`cameras.closed live=1`; a close from a zoom logs 0, not the ghost
grid) pass unchanged through the new path, with their reason strings
updated to name it.

**Confirmed on the wall 2026-09-03** (see Phase A's status for the run):
closing the Cameras view logged `cameras.closed open_s=246 live=5`, and the
five `cameras.tile_closed reason=view_closed` lines precede it in the
journal. That ordering is the whole point of the two hooks — the children
release first, so a count read at `dispose()` would have logged **0**. It
logged 5, which is the number of feeds that were actually streaming (the
idle doorbell and the NOT SET UP tile are not `isActive` and are correctly
absent). The mechanism this phase changed is therefore verified against
real feeds and a real Navigator pop, not only in the harness. A three-lens
review confirmed the count identical to the hand-kept one in every scenario
it could construct, and found thirteen documentation and test-strengthening
findings, all applied.

**One divergence declared rather than fixed.** `activeFeeds` filters by
role, not by asking surface, so it is "this view's feeds" only because the
wall shows one Cameras route at a time. Two live Cameras routes would each
count the other's tiles. The route is stackable today (tap the tab during
the 300 ms close slide), which also confuses the Director's `overlaid` flag
the same way and predates this phase; the assumption is now stated on
`activeFeeds` and `_closingLive`, and the guard that would remove it is
Phase K item 11 — the owner's call, since it changes what a second tap
does.

**Goal.** The tile and the zoom stop reporting whether they are active; the
Cameras view reads the Director's per-role count once, at `deactivate()`,
and logs it at `dispose()`. `onWent` leaves both widget interfaces.

**Why.** Which feeds are active is the Director's fact — it sets every
phase — yet one number on one log line (`cameras.closed live=N`,
`cameras_view.dart:272-275`) is re-derived by three widgets: `onWent` ×10 in
the file (props `:568/:579, :1035/:1044`; wired `:366, :456`; reported
`:643, :669, :1078, :1098`), a `_wasActive` mirror in the tile
(`:601/:630/:641/:667`) and in the zoom (`:1052/:1077/:1096`, for nothing
else), and a `_live` set (`:202, :274, :291, :308, :319`) cleared at zoom-in
and pruned at zoom-out, with seven census comment blocks, four of them
explaining Flutter's unmount order (`:200-201, :267-271, :303-307, :577-579,
:656-658, :1041-1044, :1085-1087`). It has already been wrong once (handoff
D6, `phase-8-handoff.md:206-229`; test `cameras_view_test.dart:907`).

**Skeptic's corrections, folded in.** `_activeSessions`
(`stream_director.dart:479`) is *not* the number: it counts open sessions,
Popup included, while the closed line counts `isActive`
feeds (queued|connecting|playing|retrying, `:105-109`) for tile and zoom
roles. The Director needs a new ~4-line fold over `_feeds` (`:462`; role at
`:685`, phase at `:687`). The role filter is mandatory: the wall's Director
is shared with the Popup. The sibling `auto_live` count at view `initState`
(`:222-227`) cannot become a census read (no tile has attached yet); leave
it.

**Mechanism, verified against the SDK.** `framework.dart`
`_deactivateRecursively` calls `element.deactivate()` *before*
`visitChildren` (parent-first); `_unmount` visits children first. So at
`_CamerasViewState.deactivate()` every tile and zoom feed is still attached
with its live phase — exactly what the skipped drain was preserving.

### D.1

1. `stream_director.dart`: add
   ```dart
   /// How many feeds of [roles] are being pursued or played right now
   /// (FeedPhaseFacts.isActive). The census for a closing surface's log
   /// line; a role filter because the wall's Director is shared with the
   /// Popup.
   int activeFeeds({required Set<FeedRole> roles});
   ```
2. `cameras_view.dart`: override `deactivate()` to snapshot
   `_closingLive = _director.activeFeeds(roles: {FeedRole.tile, FeedRole.zoom})`;
   `dispose()` logs it. Delete `_live`, `_tileWent`, `_zoomIn`'s
   `_live.clear()` (`:308`), `_zoomOut`'s `_live.remove` (`:319`), both
   `onWent` props and their four report sites, the zoom's `_wasActive`, and
   the seven comment blocks. The tile keeps `_wasActive` **only** for
   `wantKeepAlive` (`:625-630`, an independent reason).
3. Tests: `cameras_view_test.dart:886-904` and `:907-929` assert the log
   field through `Log.sink` and keep passing unchanged. Add to
   `stream_director_test.dart` one fakeAsync case per role for
   `activeFeeds`, and one that a popup feed is not counted under
   `{tile, zoom}`. Delete the line at `stream_director_test.dart:17` that
   defers "the census line" to widget tests.

**Done when:** `grep -rn "onWent\|_tileWent\|\b_live\b" panel/lib/ui/cameras`
is empty (scoped: the unscoped form matches the sibling `auto_live` count
this plan keeps and the unrelated `_live` getter in
`thermostat_controls.dart`); `flutter test` green.

---

## Phase E — A contract suite for the video seam

**Status: landed 2026-09-03, unstaged, awaiting the owner's review.** E.1
items 1–3 are done: invariant 6 is stated on `LiveVideoSession.phase` where
an implementer looks (it lived in a Director comment, and both the comment
and this plan's one-line summary of it were **wrong** — `unconfigured` never
follows a live value, but `unsupported` does on the web branch, where the
MSE player dials its socket before `sourceopen` tells it the browser decodes
none of go2rtc's codecs; the interface now says so, the Director's comment
is narrowed to match, and the MSE world declares the exemption);
`test/support/session_world.dart` holds `SessionWorld` and
`runSessionContract`; `test/live_video_contract_test.dart` runs it over five
VM worlds (Settled, the fake, MJPEG over a real socket, RTSP over a
hand-driven controller, the pool's lease) and
`test/live_video_contract_web_test.dart` over the MSE one. `live_video_contract_test.dart` is thirty cases: 24 execute,
6 are skipped with the reason printed by the runner. The web file adds six
more, all of which would execute once the Chrome runner is repaired.

Three deviations from the sketch. First, the two exemptions a world may
claim (`noFailureText`, `noOpener`) are named at the call site rather than
read off the world, because a group's `skip:` is decided before any world is
built; claim one wrongly and the case fails on the null closure rather than
passing. Second, `openBroken` is synchronous — an async wrapper turns a
throw into a rejected future and would pass whatever the opener did. Third, E.1
item 4's deletions were **not** taken, for three different reasons. Three of
the five cases it named also assert a transport-specific witness the
contract deliberately does not reach — MJPEG's frame disposal, the RTSP
controller's teardown and its empty timer queue, the pool's own failure
sentence and unpooled reopen — so deleting the generic half would mean
rewriting the case rather than removing it. `live_video_rtsp_test.dart`'s
opener case stays because the contract exempts that opener outright (see
the fvp note below), not because it witnesses anything extra.
`live_video_test.dart`'s is the one true duplicate on its assertions, and
it is kept for a different reason again: it is the only case that drives
the `VideoConfig.urlFor` → `openLiveVideo` composition, from the one file
that runs both on the VM and in a browser. The owner can still take the
plan's "replace, don't layer" default on the other four.

Verified: `flutter analyze` clean; `flutter test` 684 passing, 8 skipped
(660 + 2 before: +24 executing cases, +6 declared skips). Mutation-checked rather than
assumed, in two rounds. The first: a per-call `view` on the MJPEG player, a
settled value after a live one, and a close that stops reporting without
dropping the socket each turn the suite red on exactly the invariant they
break. A fourth (removing the pool lease's close latch) does **not**, and
the suite is right — `_release` guards the double call itself
(`kept.holder != holder`), so the latch is belt-and-braces there. It is not
on `setMuted`, where removal IS observable, and the review's one new case in
`live_video_keepalive_test.dart` now pins it.

The second round was the review's own, and it found four cases of mine that
could not fail: "born muted" read its witness *after* the case had muted the
session; the MJPEG failure canary staged the one refusal whose sentence is a
string literal; the MJPEG broken open was a healthy one whose refusal landed
asynchronously; and invariant 6 had no settled value to look at in three
worlds. All four are fixed and re-checked by mutation — a fake born unmuted,
an RTSP dial that ignores the born value, a failure text that interpolates
the exception, and an opener that answers a still-dialling session each turn
the suite red now, and none of them did before.

**The MSE column is written and unexecuted**, which is the gap this phase
does not close: `flutter test --platform chrome` hangs in the devcontainer.
The file says so in its header. It also cannot reach `playing` without a
go2rtc, which leaves the picture-half of three cases unstaged; all six of
its cases still execute.

**Found on the way, filed as Phase K item 12:** `openRtspVideo` registers
fvp process-wide inside an unawaited `Future`, so on a VM run the missing
`libfvp` surfaces as an unhandled async error attributed to whichever test
is running. That is the flake seen once during Phase B. The contract
therefore exempts the RTSP opener and says why; the existing case in
`live_video_rtsp_test.dart` keeps that pin, and the hazard with it.

*Fixed 2026-09-03 — see Phase K item 12. The exemption survives the fix but
its reason changed: the opener is safe to call from a test now, and what
still bars it from invariant 5 is that its dial fails asynchronously, so
the session it hands back is live rather than already failed.*

**Goal.** One `runSessionContract(world)` in the shape of
`test/hub_contract_test.dart` (`:20`, 11 tests × 2 adapters over a
`HubWorld` record) runs the seam's six invariants over every
`LiveVideoSession` adapter the VM can host. No production code changes.

**Why.** Adapters (grep `implements LiveVideoSession`): `SettledLiveVideoSession`
(`live_video.dart:328`), `MjpegLiveVideoSession` (`live_video_mjpeg.dart:145`),
`MseLiveVideoSession` (`live_video_mse.dart:170`), `RtspLiveVideoSession`
(`live_video_rtsp_io.dart:234`), `_Lease` (`live_video_keepalive.dart:400`,
reached via `LiveVideoKeepAlive.open` `:181`), `_CountedSession`
(`stream_director.dart:1149` — gone after Phase A), and the test fake
`FakeLiveVideoSession` (`test/support/fake_go2rtc.dart:36`, 72 references,
never held to the contract). The invariants are prose:

| # | Invariant | Stated | Pinned today |
|---|---|---|---|
| 1 | `failure` never contains the URL | `live_video.dart:72-86` | mjpeg `:368/:390`, mse_web `:67/:84`, rtsp `:212` |
| 2 | `view` is never a spinner, stable across calls, survives remount | `:88-110` | mjpeg (2 `identical`), rtsp `:134`, keepalive `:366`; MSE none |
| 3 | born muted; `setMuted` never throws, any phase, idempotent | `:112-127` | rtsp `:261/:283` only |
| 4 | `close` idempotent and drops the connection | `:129-155` | mjpeg `:447`, rtsp `:238`, mse_web `:113`, live_video_test `:157`, keepalive `:302` |
| 5 | an opener never throws — answers a settled failed session | `:167-172` | rtsp `:296`, mse_web `:44`, live_video_test `:157`, keepalive `:494` |
| 6 | settled values never follow a live one | **only** `stream_director.dart:891` (a Director comment) | nobody |

### E.1

1. State invariant 6 in `live_video.dart`'s interface doc, beside the other five.
2. `test/support/session_world.dart`:
   ```dart
   typedef SessionWorld = ({
     String name,
     Future<LiveVideoSession> Function() open,   // through the adapter's real opener where one exists
     Future<void> Function() reachPlaying,       // stage a first picture
     Future<void> Function() fail,               // stage a refusal or a silence
     bool Function() connectionOpen,             // for invariant 4's "drops the connection"
     Future<void> Function() tearDown,
   });
   ```
3. `test/live_video_contract_test.dart`: `runSessionContract(SessionWorld)`
   with one `test()` per invariant (6), executed for each world:
   - **Settled** — `open` returns `SettledLiveVideoSession(failed)`; `reachPlaying` is a no-op (invariants 3, 4, 5, 6 apply; 1 and 2 trivially).
   - **Fake** — `FakeGo2rtc` from `test/support`.
   - **MJPEG** — over a localhost `ServerSocket`, the rig `live_video_mjpeg_test.dart` already has (`:214, :251, :270`); real-async, not fakeAsync.
   - **RTSP** — `RtspLiveVideoSession(controllerFor: (_) => _FakeController())` (`live_video_rtsp_test.dart:322`); fakeAsync.
   - **Lease** — `LiveVideoKeepAlive(opener: fakeGo2rtc.open).open(...)`.
   - **Counted** — only if Phase A has not landed; otherwise omit.
   - **MSE** — a second file under `@TestOn('browser')` calling the same
     `runSessionContract` with a world over the real browser; it runs only
     under `--platform chrome`, which hangs in the devcontainer today
     (`README.md:1536-1541`; `hub/dev/go2rtc/DEBUGGING.md:431` names
     repairing the runner as the preferred fix). Say so in the file header.
4. Then delete the per-adapter duplicates: close-idempotent in mjpeg `:447`,
   rtsp `:238`, live_video_test `:157`; opener-never-throws in rtsp `:296`,
   live_video_test `:157`, keepalive `:494`. Keep every transport-specific
   case (MJPEG framing, the RTSP frame pulse and the `setMuted`-vs-initialize
   race at rtsp `:261`, the pool's grace window).

**Done when:** six invariants appear once in prose and once in code; every
VM-hostable adapter runs the suite; `flutter test` green.

**Prerequisite to bring MSE to the VM (not part of this phase):** a
Dart-typed media port under the MSE player — see the refuted list. It is
verification locality, not depth, and about 25 members wide; the review
recorded it as a dependency of this phase, not a candidate of its own.

---

## Phase F — IdleReturn

**Status: landed 2026-09-03, unstaged, awaiting the owner's review.** The
trigger was the owner's to call and they called it. All five steps are done:
`lib/ui/idle_return.dart` owns the two chained timers, the prompting flag
and rearm/cancel/dispose; `lib/ui/still_watching.dart` draws the sentence
once; both surfaces hold one `IdleReturn` built from their own constants;
`_idleWarn`, `_idleFire`, `_prompting`, `_StillWatching` and `_IdlePrompt`
are gone from `lib/`.

Two decisions the sketch left open. **The prompt's two chromes stay apart**,
because they are not the same shape: the Cameras banner is a raised puck,
and the Popup's line lives in a 22 px slot it shares with the Talk caption,
whose height the card's layout depends on and whose pixels a golden pins.
So `StillWatching` has two named constructors, `banner()` and `caption()`,
over one shared sentence — the words are what drift, and they are now in one
place. **The Cameras view keeps its own blocked-fire retry**, as a private
timer rather than the module's: that is the obstructed-route half of
`_fireIdle`, which the review ruled out of the shared seam. It is cancelled
wherever the bound is rearmed, preserving the rule that a touch resets the
whole dismissal state — previously implicit, because the old code reused one
timer field for both jobs.

Verified: `flutter analyze` clean; `flutter test` 694 passing, 8 skipped
(+8 unit cases in the module's own suite, +1 widget case); the golden is byte-identical and all twelve existing idle
widget cases pass unchanged, by the same finders — and the Cameras five now
find the prompt through `StillWatching.sentence`, so the words live in one
place for the tests too. Step 5's second half, trimming the
pure-choreography cases, was considered and declined: none of the twelve is
pure choreography. Each also pins something `IdleReturn` does not own — the
go2rtc session close, the route-pop guard and its `idle_blocked` line, the
`{device, reason}` log fields, the `_boundsIdle` gate, and each surface's
real hit-test behaviour — so all twelve stay. Mutation-checked: adding
the warning to the bound instead of taking it out of it, a rearm that does
not cancel the pending fire, and a dispose that leaves the timers running
each turn the suite red — 13, 43 and 72 failures respectively, across the
module's suite and both surfaces'.

**The review found one real bug and two unpinned guarantees, all fixed.**
The warn callback flipped `prompting` before arming the fire timer, and the
flag notifies synchronously — so a surface that disposed inside that
notification left a timer nobody could cancel, and `onFire` would have
landed on a dead State. The two statements are now the other way round,
with a case that disposes from the listener. `cancel()`'s post-dispose
guard and the Cameras view's hand-written cancel of its blocked-fire retry
were both correct and pinned by nothing; deleting either left the suite
green. Each now has a case, verified red without it. Three further
mutations confirm all three.

**Trigger.** `docs/plans/device-integrations/phase-8-handoff.md:769`
deferred this extraction until "the third copy would arrive with a
web-specific surface". The memory `web-panel-is-a-second-screen-target`
says that surface is coming; the call was the owner's and they made it
ahead of the bar. The handoff bullet is now marked done.

**Goal.** One pure-Dart `IdleReturn` owns the two chained Timers, the
prompting flag and re-arm/cancel; one `StillWatching` widget draws the
sentence. Each surface keeps its constants, its pointer `Listener`, its gate
and — deliberately — its own fire.

**Why, measured.** Two copies of the choreography: `cameras_view.dart:323-332`
and `device_popup.dart:763-792`; six drifts: blocked-pop retry 30 s
(`:350`) vs 1 s (`device_popup.dart:310`); `Log.debug` each retry (`:347`)
vs `Log.warn` once (`:827-833`); `HitTestBehavior.translucent` (`:377`) vs
`opaque` (`:1042`, reasoned); a raised banner with icon (`:519-545`) vs a
bare 12 px caption (`:1153-1165`); `idle_return` fields `{reason}` vs
`{device, reason}`; the Popup's re-arm also resets `_dismissRetry`
(`:773-774`). "Still watching? Tap anywhere to stay" appears twice
(`cameras_view.dart:535`, `device_popup.dart:1159`).

**What the skeptic ruled out.** Do **not** share the guarded self-pop
("pop me when current, retry while obstructed"). The cadence and log-level
differences are documented as intended (`README.md:1092-1095, :1284`;
`cameras_view.dart:343-346`), and the Cameras view is `RouteAware`
(`:159, :239`) with `didPopNext` (`:251`): it has an *event* for "the
obstruction left" and needs no polling retry. A shared retry would import
the Popup's polling into a surface that does not need it. The Popup's own
three dismissal fields (`_dismissRetry`, `_loggedBlockedDismiss`,
`_retryDismiss`) can become one object *inside the Popup* as a tidy; that
is Phase K, not a shared seam.

**Design (sketch).** `lib/ui/idle_return.dart`:
```dart
class IdleReturn {
  IdleReturn({required Duration returnAfter, required Duration warnFor, required VoidCallback onFire});
  ValueListenable<bool> get prompting;   // true during the warning window
  void rearm();                          // any touch; clears the prompt
  void cancel();
  void dispose();                        // no Timer survives
}
```
`lib/ui/still_watching.dart`: one widget from `PanelTheme`. Decision for the
grilling: the Popup's copy sits in a 22 px reserved caption slot
(`device_popup.dart:895-908`) and the Cameras copy is a banner; one widget
needs either a `compact` variant or the Popup's slot to grow.

**Steps.** (1) Module + `test/idle_return_test.dart` in fakeAsync: arm →
prompt at `returnAfter − warnFor` → fire at `returnAfter`; rearm cancels
both and clears the prompt; cancel; dispose leaves nothing pending.
(2) Cameras view: `_idleWarn/_idleFire/_prompting/_rearmIdle` → one
`IdleReturn(kCamerasIdleReturn, kCamerasIdleWarning, onFire: _fireIdle)`;
`_fireIdle` unchanged. (3) Popup: same with `kDevicePopupIdleReturn`;
`_rearmIdle` becomes a wrapper that checks `_boundsIdle`, resets
`_dismissRetry`, then `rearm()`. (4) Both `_StillWatching`/`_IdlePrompt` →
`StillWatching`. (5) The 12 existing widget cases (`cameras_view_test.dart:626,
:647, :693, :932`; `device_popup_test.dart:1204-1378, :625`) keep passing;
trim the pure-choreography ones once the unit suite covers them.

---

## Phase G — PopupClaim — **DONE 2026-09-04**

**Trigger.** A second *unprompted* Popup — any alert the Hub raises that
should open a route on its own. Today there is exactly one asker
(`DoorbellPopupHost`) and one writer (`_DevicePopupBodyState`), which makes
the seam hypothetical; the module still concentrates an interface (two
caller-side invariants and a four-value enum crossing a file seam) and is
worth doing early if the owner prefers the smaller host. **The owner called
it early**, on the terms the paragraph above offers: the smaller host, ahead
of the second asker. The seam is not hypothetical after all — the unit suite
is its second adapter, and it turned out to be the only place two of the
module's rules could be stated at all (see **What landed**).

**Why, measured.** Fifteen branches across two files: the host's four-arm
switch (`doorbell_popup_host.dart:206-227`), the deferral's three outcomes
(replace `:237`, redeem `:252`, drop `:274`), `stayUp()`'s four returns
(`device_popup.dart:701-718`), `_dismiss`'s four (`:810-843`). ~205 lines of
arbitration; at the registry seam 50 lines of doc for 14 lines of code
(`device_popup.dart:176-226`); 21 lines of doc for one field
(`doorbell_popup_host.dart:140-160`). Test symptom:
`extendDevicePopup('cam-porch')` is called from nine Popup tests against
module globals every case in the binary shares.

**Where the line is (ADR-0013).** "The Director owns the stream; the Popup
owns the route and everything a person touches." PopupClaim is Popup-side.
`stayUp()`, `_leaving` and `_dismiss` stay in the State where the Navigator is.

**Design (sketch).** `lib/ui/popup_claim.dart`:
```dart
sealed class ClaimAnswer {}
final class Claim extends ClaimAnswer {}                       // push now
final class Busy extends ClaimAnswer { final DevicePopupExtension how; } // extended | held
final class Wait extends ClaimAnswer {}                        // the claim calls back

abstract interface class PopupStayer { DevicePopupExtension stayUp(); }

class PopupClaim {
  PopupClaim({this.deferredWindow = kDoorbellDeferredDingWindow,
              void Function(VoidCallback) nextFrame = _postFrame});
  void register(String deviceId, PopupStayer popup);     // from the State's initState
  void deregister(String deviceId, PopupStayer popup);   // from dispose; drains waiters when none left
  ClaimAnswer acquire(String deviceId, {required void Function(ClaimAnswer) onVerdict});
  void dispose();
}
```
Owns `_showing`, `_goneWaiters`, the `_waiting` map and expiry Timers; on
`Wait` it arms the gone-waiter itself, re-judges next frame through the
injected scheduler, and writes `popup.doorbell_dropped` on expiry. The host
shrinks to three arms. `extendDevicePopup`/`whenDevicePopupGone` become
internals or thin shims for the nine tests that call them.

**Tests.** `test/popup_claim_test.dart` in fakeAsync with a fake stayer:
Claim when none showing; Busy(extended)/Busy(held); Wait then verdict after
the last popup deregisters; drop after the window with the warn line; a
newer deferred ding replaces the older; dispose leaves no Timer.
`doorbell_popup_test.dart`'s four arbitration cases (`:151, :190, :234, :283`)
stay as the end-to-end pins.

### What landed

`lib/ui/popup_claim.dart`, and both callers rewired to it. 715 passing /
8 skipped (695 before, +16 unit cases and +1 end-to-end), analyzer clean,
`flutter build linux --release` green.

**Shape, where it differs from the sketch above.**

- `Busy { how }` became two sealed cases, `Extended` and `Held`. The sketch's
  single case carried a `DevicePopupExtension` payload, which is the four-value
  enum crossing a file seam that this phase exists to retire — the caller would
  have switched on the enum *inside* the case and been back where it started.
- A fifth case, `Dropped(waited)`, joined `Claim`/`Extended`/`Held`/`Wait`. The
  sketch left the drop as a log line the claim writes ("writes
  `popup.doorbell_dropped` on expiry"). It is not the claim's line to write: the
  claim does not know whose request it was or that "ding" is the word for it,
  and one asker's vocabulary baked into a module built for several is exactly
  the coupling the phase is undoing. So the drop is an *answer*, and the host
  keeps its own warn. `waited` rides on it rather than being read off
  `kPopupClaimWindow` at the call site, because the window is
  constructor-injectable and a caller reporting the default would be reporting a
  number that was not the one the claim used.
- `DevicePopupExtension` was renamed `StayVerdict` and lost a value. `none`
  turned out to have no producer once the claim owned "nothing is showing this
  Device" — `stayUp()` can only ever answer `extended`, `held` or `leaving`
  about *itself*. The old name was wrong twice over: it was not per-Device, and
  two of its four values were not extensions.
- `acquire` grew an `owner`, and `abandon(owner)` with it. The claim outlives
  every route, so a request the host leaves waiting in it is not collected with
  the tree the way `_DeferredDing`'s Timer was.
- `deregister` returns `void`, not the sketch's implied "gone" edge. Nothing in
  the Popup's `dispose` needs it: `onGone` and `_feed.release()` are both about
  the Popup this caller pushed, and what happens at the Device's edge is the
  claim's own.
- `PopupClaim.dispose()` was written and then deleted: `abandon` covers the one
  lifecycle a caller has, and a method only tests call is the shallow surface
  this exercise is against.

**The rule the sketch did not have.** A request offered again to a wall that is
*still* leaving keeps its **original** clock. The sketch's redemption re-entered
`acquire`, which re-armed the window from zero — so a chain of closing Popups
could hold a ding well past the 30 s that exists to say when it went stale.
`_redeem` now returns without touching the clock when it finds another `Wait`;
that Popup's own deregistration brings it back.

**What the review changed.** 27 findings, 21 refuted, 6 confirmed (two of them
the same over-long doc line seen by two lenses). Two were real defects:

- **A Popup *arriving* did not re-offer a waiting request.** The request was
  re-judged only when the Device's list went empty, so a ding deferred behind a
  closing Popup while somebody tapped that same camera's pin sat out the whole
  30 s window behind a wall showing the very camera it wanted — and was then
  dropped as `popup_never_closed`, which was true of nothing. `register` calls
  `_reoffer` now, and `deregister` calls it unconditionally rather than only at
  the empty edge. The frame's delay was already there and is load-bearing twice
  over: a Popup asked during its own `initState` answers `leaving` about
  itself, because `_route` is looked up in `didChangeDependencies`. This is not
  a regression the phase introduced — `_goneWaiters` drained on the same empty
  edge and the old `_dropStale` wrote the same false warn.
- **`_redeem`'s `identical` guard was unpinned.** Two Popups closing and two
  dings landing in one frame queue two offers against one Device, the first
  holding a request already thrown away. Without the guard both are answered:
  two `Claim`s for one free Device, and `_push` has no de-dup of its own. The
  case is in the suite now, and it kills both the deletion and the weaker
  `_waiting[deviceId] == null` form — the latter only via the pending-Timer
  assertion, since it answers the stale request and abandons the live one's
  clock.

Three were prose or hygiene: the redemption is the end of the *current* frame,
not the next one (three comments); a re-worded doc paragraph left a 119-column
line; and a `claim.abandon('host')` in one unit case was a no-op that made the
`pendingTimers` assertion after it unable to fail. `device_popup_test`'s
`tearDown(abandon(ringer))` was measured with the same question and removed for
the same reason — every case that draws a `Wait` settles the tree, which takes
the clock off, and one that did not should fail on the harness's pending-Timer
check rather than be tidied up.

**Proof.** A 15-mutation sweep, all killed: `deregister` clearing the whole
stack, `_judge` iterating oldest-first, `Wait`→`Claim`, the redemption
answering a still-leaving wall, the redemption answering `Claim` blind, the
redemption running inline instead of next-frame, `acquire` not cancelling the
older clock, `abandon` ignoring the owner, the Popup never registering, the
Popup never deregistering, the host never abandoning, the host pushing on a
`Wait`, the stale-request guard deleted, that guard weakened to a null check,
and `register` not re-offering.

The host's `abandon` needed a case built for it. Every ordinary teardown redeems
the waiting request on the way out and takes its clock off, so the host's
`abandon` looked unreachable until a case held a Device permanently
`leaving` — `doorbell_popup_test.dart`'s `_NeverLeaves` — and let the Panel go
down under it. It rests on the harness checking for pending Timers *before* it
runs `addTearDown` callbacks, which is why the stand-in is deregistered from a
tear-down and not from the case body; deregistering inside the body redeems the
ding and cancels the very leak the case is there to catch.

**Where the nine `extendDevicePopup` test calls went.** `device_popup_test.dart`
grew a `ring(deviceId)` helper — one `acquire` against the shared claim, the way
the host asks — and a `tearDown` that abandons its `ringer`. Not a shim in
`lib/`: a pass-through kept alive by tests is the thing the deletion test is
for.

---

## Phase H — Transport tuning through the video seam — **DONE 2026-09-04**

**Trigger.** `live_video_rtsp_io.dart:130-135` schedules the frame pulse
(and its debug line) for deletion after a week on the wall with
`VIDEO_REPAINT_PULSE=off`. Decide that first: if the pulse goes, two of the
four knobs go with it and this phase shrinks to decoders + lowLatency, both
consumed once by `fvp.registerWith`. Sequence H after that decision.

**How the gate was answered.** It could not be waited on, because the wait
had never started: `VIDEO_REPAINT_PULSE=off` had never been set on the wall
for a minute, let alone a week — at that moment `cage@.service.j2` templated
`HUB`, `HA_URL`, `GO2RTC_URL` and `LOG`, and nothing else (the two video vars
were added later the same day, which is what makes the rescue real). Two further facts settled
it. The code's stated reason for keeping the pulse on — "the evidence is from
the dev box's Intel/NVIDIA stack, the appliance is different silicon" — is
about the Ryzen mini PC, which `appliance/ansible/inventory.yml` still lists
as `minipc.placeholder.invalid`: unpurchased, so the only real appliance is
the Legion, whose kiosk is pinned to the same i915 the freeze probe measures.
And four fresh probe runs on 2026-09-04 found no rendering difference between
the arms — two sub-6 verdicts were both a camera sitting on "Connecting…" in
both grabs, which the rig's own rule says to settle by looking rather than by
reading the number.

So the **owner flipped the default** rather than deleting: `framePulse` ships
`false`, `VIDEO_REPAINT_PULSE=on` is the rescue, and the phase kept all four
knobs. What is still unmeasured is the compositor — the probe runs under
XWayland on GNOME, the kiosk under cage/wlroots, and the embedder's
frame-available path is exactly what differs between them — and
off-by-default is what finally starts measuring it. `_FramePulse`'s deletion
stays where it was: after a week on the wall with nothing lost.

**Why, measured.** Four process-wide mutable globals in
`live_video_rtsp_io.dart` (`rtspVideoDecoders :82`, `rtspLowLatency :112`,
`rtspFramePulse :137`, `rtspVideoDebug :167`) plus four inert twins in
`live_video_rtsp_web.dart` (`:9, :13, :17, :38` — "exists only so main()
compiles from one file — assigning it does nothing") = 8 declarations for 4
values; assigned in `main.dart` (`:138, :148, :163, :171`) from ~70 lines of
env parsing (`:103-175`) with no test, beside a `resolveHubConfig` that does
the same job deeply with 18 tests; read at 9 sites; a prose ordering
invariant ("set before the first open, from main() and nowhere else",
`:55-57`) enforced by nothing; `test/live_video_rtsp_test.dart:58` mutates a
global under a `tearDown`. The class itself states the precedent it breaks:
"constructor-injectable deadlines and controller factory … a class that
cannot be interrogated cannot be tested" (`:228-232`).

**Design (sketch).**
```dart
// lib/config/video_tuning.dart — pure, tested like resolveHubConfig
@immutable class RtspTuning {
  const RtspTuning({this.decoders = const ['FFmpeg'], this.lowLatency = 0,
                    this.framePulse = true, this.debug = false});
  final List<String>? decoders;  // null = fvp's own list ("auto")
  final int lowLatency; final bool framePulse; final bool debug;
}
RtspTuning resolveRtspTuning(Map<String, String> environment, {String? buildDecoders, ...});

// lib/ui/video/live_video_rtsp_io.dart
LiveVideoOpener rtspOpener(RtspTuning tuning);   // registers fvp on first open — "first wins", stated once
class RtspLiveVideoSession { RtspLiveVideoSession(Uri endpoint, {required RtspTuning tuning, ...deadlines, controllerFor}); }
// lib/ui/video/live_video_rtsp_web.dart
LiveVideoOpener rtspOpener(RtspTuning _) => openLiveVideo-with-warn-once;
```
`main.dart:118` becomes `rawOpen = transport == 'rtsp' ? rtspOpener(tuning) : openLiveVideo`.

### What landed

`lib/config/video_tuning.dart` (`RtspTuning` + `resolveRtspTuning`), both
transport branches taking it as an argument, and `main()` down from ~50 lines
of parsing to one call. 735 passing / 8 skipped (+16 tuning cases, +2 in the
RTSP suite), analyzer clean, release build green, and the boot line on a real
run reads `panel.video_player decoders=FFmpeg low_latency=0
repaint_pulse=off`.

**Where it differs from the sketch.**

- **`registerRtspPlayer(tuning)` does not register on first open.** The sketch
  said "registers fvp on first open — first wins"; that lazy call *was* the
  2026-09-03 flake and now happens in `main()`. What survives of "first wins"
  is stated on the function: fvp registers once per process, so a second
  call's tuning is ignored — a fact fvp imposes, not a bug to fix.
- **`RtspTuning` is defaulted on the session, not required.**
  `RtspLiveVideoSession` takes `tuning = const RtspTuning()` beside its two
  deadlines, so a case that is not about tuning says nothing about it — and
  the const default is the same value `resolveRtspTuning` produces from an
  empty environment, which one case pins so the two cannot drift.
- **`VIDEO_TRANSPORT` stayed in `main()`.** It names which of three transports
  plays; folding a three-way choice into a type called *Rtsp*Tuning would be a
  category error, and it is the one video setting `main()` still warns about,
  because naming a transport that does not exist gets you a different player
  than you asked for.
- **No `sources`/`overridden` map.** `HubConfig` carries one because "wrong
  address" and "right address, daemon down" are indistinguishable on the
  badge. Nothing here is an address; a wrong decoder is a broken picture, and
  what the boot line wants is the *value*. Copying the precedent whole would
  have been cargo cult.
- **The web branch lost four inert globals and gained one ignored parameter.**
  `rtspOpener(RtspTuning _)` strikes the same bargain the four twins did — let
  `main()` compile from one file — at one declaration instead of four.

**Proof.** 15 mutations, 12 killed. The three survivors are all in code no
test binary can execute, and saying so is the honest report rather than
padding the suite: `registerWith`'s options (calling `registerRtspPlayer` in a
test is precisely the flake that was removed), `main()`'s two call sites (the
untested composition root — Phase J), and `_pulse`'s `framePulse` guard in a
debug-only run, which needs a `TextureBox` and `VideoPlayer` builds none on a
VM run because no platform hands it a texture id (walked the tree: zero). That
last gained the half that *is* observable — a debug-only session still wraps
and still ticks, so `ticks=` in the log means something — and its case says in
as many words which half `tool/freeze_probe.sh` measures instead.

**The appliance side.** Flipping a default is only cheap if the rescue is, so
the kiosk role gained `panel_video_repaint_pulse` (empty = no `Environment=`
line, exactly like `panel_log_level`). Without it the rescue would have been a
`systemctl edit` drop-in that the next converge silently reverts — taking a
rendering workaround with it whose absence looks fine in a screenshot.

---
`camerasAutoOpen` (`main.dart:167, :515`) is a rig knob, not tuning; leave it.

**Tests.** `test/video_tuning_test.dart` (env-first, define-second, `auto` →
null, empty names dropped, bad lowLatency → 0). `live_video_rtsp_test.dart`'s
pulse group (`:55-125`) passes `tuning:` and loses the `tearDown` at `:58`.
Decoders/lowLatency stay hermetically untestable (fvp is the real external).

---

## Phase I — go2rtc's address, parsed once — **DONE 2026-09-04**

**Only** worth doing after H, and only if the owner wants the Director's raw
string peek typed. The friction is navigational and the guards have never
drifted.

**Measured.** The guard `if (base == null || base.host.isEmpty) return null;`
appears in `live_video.dart:226`, `snapshot.dart:160` (`Go2rtcStillsConfig`),
`talk.dart:152`, plus `snapshot.dart:94` (`SnapshotConfig`, HA_URL) and
`ha_hub.dart:75` (throws). Three of them say they copy the first
(`snapshot.dart:92, :158`; `talk.dart:150`). `config.go2rtcUrl` fans out five
times in `main.dart` (`:102, :210, :227, :236, :242`). The strongest anchor
the explorer missed: `stream_director.dart:773-775` peeks at
`director.video.go2rtcUrl.isEmpty` to choose ADR-0013's `no_go2rtc_url` vs
`bad_go2rtc_url` — the one consumer that needs the absent-vs-unusable
verdict and re-derives it from the string.

**Scope, after the skeptic.** go2rtc only: four guards + the Director peek.
Not the Hub half (`SnapshotConfig` returns null while `HaHubClient` throws
inside `bootPanel` by design — `boot.dart:196-201`, `main.dart:217-221`). Not
the transport mappers (`live_video.dart:195-202` and
`live_video_mjpeg.dart:83-88` record, with rejected alternatives, that the
MJPEG/RTSP forms live inside the transport files). The null arm does **not**
vanish: absent go2rtc is a supported boot state (`hub_config.dart:82-89`) and
a bad address must only cost the picture (`live_video.dart:210-215`,
`device_popup_test.dart:203-221`).

**Design (sketch).**
```dart
sealed class Go2rtcAddress {
  factory Go2rtcAddress.parse(String raw);   // Absent | Unusable | At(Uri)
}
```
Configs keep a `String go2rtcUrl` constructor (82 `VideoConfig(go2rtcUrl:`
+ 12 `TalkConfig(go2rtcUrl:` test constructions must not churn) and derive
`address` once; `urlFor` becomes one `switch`. The Director asks the value
for its skip reason. `hub_config.dart:34-35`'s "plain strings because their
consumers take plain strings" is the code rationale to revise; it is not an
ADR.

### What landed

`lib/config/go2rtc_address.dart` — a sealed `Go2rtcAddress` with
`Go2rtcAbsent | Go2rtcUnusable | Go2rtcAt(base)` and one `parse`. The four
copies are gone: `VideoConfig.urlFor`, `Go2rtcStillsConfig.urlFor` and
`TalkConfig._urlFor` each derive an `address` and switch on it, and the
Director's raw-string peek is now an exhaustive `switch` over the same value.
746 passing / 8 skipped (+11), analyzer clean, release build green.

**The title overpromises, and the doc says so.** "Parsed once" is the *rule*
written once, not parsing executed once. All three configs have `const`
constructors and ten-odd default parameter values across `lib/` and `test/`
depend on that (`this.talk = const TalkConfig()`), so none can hold a
`late final` parsed field — each derives its address from a getter, which
parses on the call exactly as the four copies did. Nothing got faster.
Measured before designing around it: 15 `const VideoConfig`, 12
`const TalkConfig`, 5 `const Go2rtcStillsConfig`.

**What it did buy.** One place to be right about a guard whose subtlety was
real and undocumented by any test: `Uri.tryParse` accepts `localhost:1984` as
a URI whose *scheme* is `localhost`, with no host at all — the single likeliest
thing for somebody to hand-type into `GO2RTC_URL`. And the absent-vs-unusable
verdict is a type rather than an `.isEmpty` peek, so ADR-0013's `no_go2rtc_url`
/ `bad_go2rtc_url` split cannot silently drift from what the openers do.

**Boundaries held, as the skeptic scoped them.** `SnapshotConfig.urlFor` keeps
its own `HA_URL` guard — a bad Hub address stops the Hub and `HaHubClient`
throws to say so, while a bad go2rtc must only cost the picture, and merging
those would make one rule out of two deliberately different answers. The
transport mappers are untouched. `HubConfig.go2rtcUrl` stays a `String`: it is
handed on as a *setting*, and a Panel booted with no go2rtc is a supported
state the boot line already reports.

**Proof.** 10 mutations, all killed — the host guard dropped, empty read as
unusable, unusable read as absent, each of the three consumers made to stop
refusing a bad address, the stream-name check loosened, both Director arms
swapped, and https downgraded to `ws`. Three of those are caught only by the
new file; the rest fail existing suites too, which is the evidence that the
four copies really were one rule.

**One edge found and pinned rather than changed:** a scheme-less `//host/path`
has a host, so it parses as an address and always did. Unchanged behaviour,
now asserted.

---

## Phase J — Composition-root prop drilling (Speculative)

Re-measure after Phase A: the `{video, director?}` pair is already
`{director}`, which removes one of the four drilled names and both "carried
unread" doc blocks (`dollhouse_view.dart:99-121`, `doorbell_popup_host.dart:96-120`).
What remains is `PanelApp`'s eight parameters (`main.dart:293-304`) and the
quartet `{director, snapshots, stills, talk}` forwarded through two modules
that read none of it. A bundle value narrows the interface but has no
implementation behind it — by the deletion test's own definition a
pass-through — so it stays Speculative. The one cheap fix is real and can go
in Phase K: the two verbatim `showCamerasView` calls in `main.dart:476-484`
and `:493-501` as one closure.

---

## Phase K — Small tidies (survivors of the refuted candidates)

Each is an afternoon, none needs a seam, all are behaviour-preserving.

1. **`_closeTalk()` in the Popup.** The release guard is written twice
   (`device_popup.dart:475-476` in `_stopTalking`, `:596-597` in `dispose`).
   One private helper. This is what survives of "lift the Talk session out
   of the Popup" (refuted: one caller; six contract clauses over ~60 lines
   is an interface as wide as its implementation; the test double-pump at
   `device_popup_test.dart:1674` is the pulse ring's, which stays in the
   widget either way).
2. **`error:` on `Log.warn` and `Log.info`.** `ha_hub.dart:250` and `:260`
   call `redactCredentials` by hand only because `Log.warn`
   (`log.dart:186-187`) has no `error:` parameter and the backstop at
   `log.dart:92` runs on `error=` alone. Add the parameter, delete the two
   hand calls. This is what survives of "redact every log field at the
   seam" (refuted: measured over-redaction — `'Basic wash'` → `'Basic
   <redacted>'`, `'mon: 08:00-09:00@home'` → `'mon: <redacted>@home'` — and
   the named residual, a bare token in `auth_invalid reason=`, is untouched
   by `redactCredentials` anyway).
3. **Host the two player deadlines in `live_video.dart`** beside
   `kMseH264Level` (`:242`), and let all three players read them.
   `live_video_rtsp_io.dart:30-31` currently aliases MJPEG's constants
   through the seam's platform re-export; `live_video_mse.dart:45/:54` are
   tied to `live_video_mjpeg.dart:52/:69` only by a "kept equal
   deliberately" comment (`:44-46`).
4. **One `guardedOpen` helper** for the shared `catch` of the five never-throw
   wrappers (`live_video_mjpeg.dart:111-120`, `live_video_rtsp_io.dart:185-216`,
   `live_video_mse.dart:100-119`, `live_video_keepalive.dart:197-212`,
   `stream_director.dart:800-806` after Phase A — the sixth, inside the
   deleted `open()`, went with it). The `try` bodies differ and
   stay. Items 3 and 4 are what survive of "one player lifecycle behind the
   three transports" (refuted: MSE's `!_undecided` fail guard is a
   documented semantic difference for post-dial `unsupported`
   (`live_video_mse.dart:940-951`), the skeleton has never needed a triple
   fix, and a shared core would expose seven members to hide fourteen lines).
5. **One `showCamerasView` closure in `main.dart`** (`:476-484` and
   `:493-501` are verbatim copies).
6. **Popup dismissal fields as one object.** `_dismissRetry`,
   `_loggedBlockedDismiss`, `_retryDismiss` (`device_popup.dart:310, :329, :338`)
   and the two hand-cancels (`:714-715`, `:773-774`) become one private
   `_OwnRouteDismissal`. Popup-only; no shared seam claimed (see Phase F for
   why).
7. **Handoff doc drift.** `phase-8-handoff.md:680-681` (queued is not
   grab-allowed), `:699` (the offline arm is tested), `:715-719` (N7 closed
   by Phase A).
8. **`_VideoNotice` colours.** `device_popup.dart:1382/:1397` paint
   `Colors.white38` on a hard-coded dark frame while the Cameras faces use
   `PanelTheme.inkFaint` — a neumorphism note for the owner (CLAUDE.md), not
   a depth one; the golden will move if it changes.
9. **`DirectorPolicy.retrySchedule` non-empty.** The const constructor
   cannot assert it (`stream_director.dart:325`); an `assert` at `attach()`
   turns a StateError on the first failed policy dial into a message at
   construction time in debug builds.
10. **`FakeHub` echo policy.** `thermostat_controls_test.dart:455-494` needed
    three subclasses (`_DeafFakeHub`, `_SlowEchoFakeHub`,
    `_QuantisingFakeHub`) to script late/never/quantised echoes; a knob on
    `FakeHub`'s command seam, the way it has `driftEvery`, retires them.
11. ~~**One Cameras route at a time.**~~ **Done 2026-09-03, unstaged.**
    `showCamerasView` had no guard, and during the 300 ms close slide the
    exiting route ignores pointers, so a tap on the edge tab pushed a second
    view over the first. Two live views confuse the Director's `overlaid`
    flag and each counts the other's tiles in the closing census (Phase D).

    The owner called the trigger. Implemented as the filed sketch, with one
    change: the claim is held as **the route**, not as a mounted-view flag.
    The route's lifetime is the one that actually matches the rule — it is
    claimed synchronously inside `showCamerasView` (a mount-time flag would
    leave the first frame unguarded, so two taps in one frame would both get
    through) and released in `_CamerasRoute.dispose()`, which the Navigator
    runs once the route is off the stack for good, slide included. A test
    that pumps a bare `CamerasView` never touches it, and a Navigator torn
    down mid-route disposes its own entries, so no claim leaks between cases
    — neither of which a view-held flag gives you.

    **What the second tap now does:** nothing, and it says so —
    `cameras.open_ignored` at info. The tap is dropped rather than queued.
    That is the behaviour change this item was gated on.

    One hazard found while writing it and closed: claiming the wall *before*
    `Navigator.of(context).push(route)` would latch it shut for the rest of
    the process if `Navigator.of` threw, with no route left alive to release
    it. The claim is staked after the push returns and is still synchronous.

    Three cases in `cameras_view_test.dart` ("one Cameras route at a time"):
    the close-slide tap, the release once the slide finishes, and a direct
    second call while the wall is fully up. The close-slide case asserts the
    `open_ignored` line **before** asserting no second view, because without
    it the case passes just as well when the tap lands on the leaving route
    and no open is ever attempted — the same green for the opposite reason.
    Mutation (delete the guard): cases 1 and 3 fail, case 2 passes, which is
    correct — case 2 pins the release, which holds when there is no guard at
    all. 698 passing / 8 skipped.
12. ~~**The RTSP opener's unhandled async error.**~~ **Done 2026-09-03,
    unstaged.** `openRtspVideo` called `fvp.registerWith`, which schedules
    its `DynamicLibrary.open` inside an unawaited `Future`
    (`video_player_mdk.dart:216`). On a VM run the library is absent, so the
    failure landed as an unhandled async error attributed to whichever test
    was running — seen twice, once during Phase B and once during Phase F,
    both times in a full parallel run and never in isolation.

    Fixed by the second of the three options filed here: registration moved
    out of the opener into `registerRtspPlayer()`, which `main()` calls when
    the transport is `rtsp`, and a test binary never calls `main()`. This
    was the option that cost nothing, because **the explicit call was never
    what registered fvp on the appliance**: fvp declares
    `dartPluginClass: VideoPlayerRegistrant` for Linux, so Flutter's
    generated `dart_plugin_registrant.dart` already registers it before
    `main` — the freeze-probe logs show fvp's banner ahead of
    `panel.start`. Our call exists to pass `rtspVideoDecoders` and
    `rtspLowLatency` — which `main()`'s own comment beside the
    `VIDEO_DECODERS` read (`main.dart:135`) already calls "a composition-root
    decision by construction". It now sits at that root.

    Two consequences worth knowing. The `panel.video_player` line moves from
    the first dial to boot, printing beside `panel.video_transport` instead
    of seconds later. And the decoder options now apply on a wall that opens
    no RTSP stream at all, which is the correct ordering and was previously
    luck.

    Pinned by `live_video_rtsp_test.dart`'s "the opener does not register
    the native player", which asserts on `VideoPlayerPlatform.instance`
    rather than on our own log line — fvp registers once per process, so a
    log-watching pin is only true if it happens to run first, and the
    mutation proved exactly that: putting `registerRtspPlayer()` back in the
    opener left a log-based pin green while failing the case next door.
    `video_player_platform_interface` is a new dev dependency for that one
    assertion. Six consecutive full runs green (695 passing, 8 skipped).
13. **One listened notifier in `test/support`.** `ListenedNotifier<T>`
    (`test/support/fake_feed.dart`, Phase B) is `ProbeNotifier`
    (`test/support/fake_health.dart`) drawn a second time — the same
    `listened => hasListeners` trick. Move it to its own support file and
    make `ProbeNotifier` a `typedef` over it (or delete it and update the
    note at `stream_director_test.dart:900` that names it).

---

## Refuted this round — do not re-propose as filed

| Candidate | Why it fell | What survives |
|---|---|---|
| Lift the Talk session machine out of the Popup State | N=1 caller; interface ≈ implementation; the double-pump is the pulse ring's | K.1 |
| One own-route dismissal shared by Popup and Cameras | Cadence and log level differ by documented decision; Cameras is RouteAware and has the event | K.6, and Phase F's "do not share the fire" |
| One player lifecycle behind the three transports | MSE guard differs on purpose; never a triple fix; a core would be shallow | K.3, K.4, Phase E |
| A substitutable media port under the MSE player | One production adapter; ~25 members; verification locality, not depth | Prerequisite for Phase E's MSE world on the VM; complementary to repairing the chrome runner |
| Redact every log field at the seam | Measured over-redaction; the named residual is untouched anyway | K.2 |

## Already deep — leave alone

Named by the explorers so this plan does not touch what works: `bootPanel`
(three failure modes, two adapters, 20 cases); `HubController` and its
foundation-only import list; the `HubClient` contract suite; `loadHouse`
and `parseBindings`; `classifyDing`; `CameraOrderStore` / `arrangeCameras`;
`CameraGrid`; `LiveVideoKeepAlive` (hermetic fakeAsync + opt-in live suite);
`HubCameraHealth` / `CameraHealthSource`; `TimedFeed`; the Director's own
`_Feed.dial()`; `mjpegFrames`; `FeedPhaseFacts`; the Dollhouse stack
(`FloorScene`, `FloorArrangement`, `IsoProjection`); `resolveHubConfig`;
`url_redaction` as a function.

## Open questions for the owner

1. Phase H's precondition: run the week of `VIDEO_REPAINT_PULSE=off` first?
2. Phase B's second step: should `CameraFeed` expose `restoring` (a
   Director fact) so the latch leaves the Panel entirely, or is the widget-
   side `CameraFace` enough?
3. Phase C: getter or listenable for `stillGrabAllowed` — should a health
   flip wake the still loop, or is the 60 s cadence fine?
4. Phase E: repair the chrome runner (DEBUGGING.md:431) before or after the
   VM-side suite lands?

*(Phase F's trigger question is answered: the owner called it on
2026-09-03 and the phase landed.)*
