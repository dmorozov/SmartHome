---
name: flutter-linux-eyes
description: See and judge the running Flutter Linux Panel without a person watching — screenshot-diff a live window, verdict frozen vs playing, and bisect rendering bugs (frozen video, stale textures, garbage tiles) with runtime arms. Use when debugging Panel rendering on Linux, when a change needs visual proof, or when a human-in-the-loop test cycle is the bottleneck.
---

# Flutter Linux eyes

Autonomous eyes for the Panel on this box: launch a build, photograph its
window, diff the photographs, and look at them yourself. Born in the
frozen-wall hunt of 2026-08-27, where the human-run cycle ("run this arm,
tell me what you see") cost a round-trip per experiment and the rig
collapsed it to ~40 s, unattended.

## The loop

1. `flutter build linux --release` (from `panel/`).
2. `VIDEO_TILE=<arm> tool/freeze_probe.sh` — the rig launches the bundle
   under X11, auto-opens the Cameras view (`CAMERAS_OPEN=auto`), waits out
   warmup, grabs the window twice, and prints a per-cell verdict:
   `PLAYING` cells moved between grabs, `frozen` cells did not. Knobs ride
   the environment like any hand run (`VIDEO_TILE`, `VIDEO_MIX`,
   `CAMERAS_GRID`, `WARMUP`, `GAP`, `OUT`). Its header carries the scar
   tissue — read it before editing it.
3. **Look at the grabs with the Read tool.** The verdict table says
   whether pixels moved; only the image says what is actually on screen —
   a verdict over the wrong view is worthless (the rig once graded a
   Dollhouse for half a sweep). Garbage confetti in a tile is a texture
   whose FBO was never drawn into; a clean stale picture is one that
   stopped being drawn into — different failure ages, same conviction.
4. **Calibrate before believing.** Run one arm known to play and one known
   to freeze; only when both read correctly do new verdicts count. Any
   sweep that comes back uniform re-runs a control before its results are
   used — every all-frozen sweep so far that skipped this was measuring a
   broken rig, not the app.
5. **Read the burned-in camera clocks before trusting a frozen cell.** A
   cell whose clock LAGS its neighbours is a stalled STREAM (hub-side —
   the Wyze daemons stall and rove between cameras); one whose clock
   MATCHES the wall while its pixels hold still is a severed TEXTURE.
   Mean-diff cannot tell them apart — five "frozen" verdicts in one
   sweep were stalls (2026-08-28).
6. **Near a behavioural boundary, one run proves nothing.** The wall-wide
   sever is probabilistic: the same pinned arm read 0/6, then 5/6, then
   render-healthy 3/6 across three runs. Repeat until the split is
   legible and grade arms as odds, not booleans — a single-observation
   conviction is a hypothesis wearing a verdict's clothes.

## Seeing an app X tools cannot see

The desktop session is Wayland and even exports `GDK_BACKEND=wayland`, so
a launched GTK app is invisible to every X tool by default. The rig forces
`GDK_BACKEND=x11`; XWayland renders the window on the normal desktop and
ImageMagick's `import -window` can capture it. Present on this box:
`import`/`compare`/`convert`, `xwininfo`, `xprop`, python3+PIL. Absent:
`xdotool`, `gnome-screenshot`, `grim`, `ffmpeg` — there are no scripted
clicks, which is why navigation is the app's job (an env knob like
`CAMERAS_OPEN=auto`, never a synthetic tap).

Trust rules, each bought with a voided experiment:

- **Resolve the window by `_NET_WM_PID` against your own child** — never
  by name order. A leaked window from a dead run sits first in the tree
  and lies with a straight face.
- **Sweep strays before launch, verify kills after.** A plain `kill` has
  failed silently more than once; `kill -9` and re-check.
- **No capture without a live compositor.** A blanked or locked screen
  freezes every window's last buffer while the app runs healthy
  underneath — check `org.gnome.ScreenSaver.GetActive` first, and inhibit
  idle for the run (`gnome-session-inhibit`). Blanked-screen captures
  read "frozen" and are lies.
- **X11 can change the symptom, not the bug.** GL context bugs that
  freeze pictures on Wayland can crash on X11/GLX (fvp#271's shape) — a
  crash where Wayland froze is the same suspect speaking louder.

## The app-side half

`VIDEO_DEBUG=on` makes each stream log once a second: `video.pulse`
(ticks/frames/pos/tex) separates decode from raster from glass, and
`video.pixels` hashes a `RenderRepaintBoundary.toImage` readback
(`changed`/`SAME`/`blank`). Caveat: the pixel sampler segfaults release
GLES runs on this stack — rig runs leave `VIDEO_DEBUG` off and trust the
screenshots; use the sampler only in log-only sessions.

Instrument the OFF state too. A knob whose off-position does the same
nothing as its on-position reads as "ruled out" while measuring nothing —
the shipped `late final Ticker` that never started was caught only by a
`ticks=0` line, after both positions "reproduced" the freeze.

## Bisect discipline

- Arms are runtime env-var switches (`VIDEO_TILE`, `CAMERAS_GRID`,
  `VIDEO_MIX` in `cameras_view.dart`/`camera_grid.dart`), so one build
  serves a whole sweep.
- **Pin every arm with a widget test asserting it does what its name
  claims** — removes exactly the wrapper, keeps the element alive across
  the boundary it says it holds. Three arms in one hunt silently tested
  nothing (a field that could never be set, a widget that built itself, a
  remount at the exact moment under test) and each sent the hunt down a
  wrong branch until its test caught it.
- **Sweep combinations, not just singles.** The frozen wall's factors
  were each innocent alone and guilty together — a one-switch-at-a-time
  sweep proves less than it feels like it proves.

## What the engine promises (Flutter 3.47, GTK embedder)

Mechanism facts for reasoning about stale external textures, verified
against engine source and upstream issues during the hunt:

- The engine re-paints everything every frame and **cannot** cache a
  texture's content: raster cache refuses texture subtrees, damage diffing
  always marks textures dirty (flutter#92925's fix), and the resolved
  image wraps the live GL texture with no pixel copy.
- Therefore a stale picture means the producer stopped drawing: fvp
  renders video **only inside the engine's texture-populate callback**,
  into an FBO bound to the raster GdkGLContext ("fbo can not be shared").
  Populate runs once per `mark_texture_frame_available`, not per frame.
- The documented severing mechanism: the ≥3.32 GTK compositor rework can
  present populate with a **different current GL context** once
  saveLayer-class effects enter the scene — the FBO name is then invalid
  there, renderVideo draws into nothing, no error is raised
  (wang-bin/fvp#271; multi-player freeze fvp#266; FBO-state precedent
  flutter#120815; overlay-over-texture crashes flutter#150668).

Findings of the hunt itself live in
`docs/plans/device-integrations/phase-8-handoff.md` (N5, 2026-08-27
addendum) — this skill is the method, that document is the state.
