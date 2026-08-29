# The Linux Panel renders with Skia; Impeller freezes the camera wall

**Decision (2026-08-28):** the appliance runner pins the **Skia** renderer.
`panel/linux/runner/my_application.cc` calls
`fl_dart_project_set_enable_impeller(project, false)` unless
`PANEL_RENDERER=impeller` asks otherwise, and prints `panel.renderer
impeller=…` either way. The Cameras wall keeps its neumorphic design
unchanged — rounded clip, shadows, name bars.

## The defect

Flutter 3.47 made **Impeller the default renderer on Linux**, and under it
the RTSP camera wall never plays: all five fvp video textures are **born
dead** — blank faces or uninitialized-FBO confetti under LIVE badges —
while the UI around them animates at 60 fps and the streams provably
decode. Scrolling the grid refreshes the stale content once, which is what
made it look like a repaint bug for two days. The web build (MSE) and the
single-texture zoom are unaffected; the trigger scales with composited
load.

Deterministic when clip/`saveLayer` content shares the scene from birth.
Without the clip the wall usually plays, but roughly one run in three all
five textures stop **at the same instant** after good frames — so the
sever is a wall-wide probabilistic event, not a guilty widget.

## Why Skia and not a redesign

Two candidate fixes were rig-proven to work: pinning Skia, and a no-clip
tile that fakes rounded corners with painted notches. Skia wins because it
keeps the design honest — the notch trick reproduces the look but not the
rule (`CLAUDE.md`: the wall is one continuous soft surface), and it still
carried the wall-wide stop at 1-in-3. Skia showed the complete shipped
design healthy in every run, and the edge-confetti bands that had been read
as decode corruption turned out to be Impeller artifacts and vanished with
it.

The pin lives in the runner because **release builds compile out the
engine's own env switches** (`engine_switches.cc`, `#ifndef
FLUTTER_RELEASE`). An earlier `FLUTTER_ENGINE_SWITCHES` A/B "exonerated"
the renderer for a week while measuring Impeller against Impeller.

## Consequences

- **Re-test Impeller before any Flutter SDK upgrade.** Upstream intends to
  remove the Skia opt-out. `PANEL_RENDERER=impeller panel/tool/freeze_probe.sh`
  is the check. A healthy wall reads 5/6 cells moving — the idle doorbell
  never moves (#177014) — and 4/6 is still healthy when the sixth tile
  wears a "Connecting…" face or its burned-in clock lags its neighbours:
  that is a stalled Wyze daemon, not a severed texture.
- If the opt-out disappears before upstream fixes this, the fallbacks in
  reserve are the no-clip tile, an MJPEG wall with RTSP only on zoom, and a
  hub-side ffmpeg mosaic republished through go2rtc as one texture.
- The upstream case is drafted in [`../upstream/`](../upstream/) (flutter
  and fvp, with evidence) and is the owner's to file.

## What this ruled out — do not re-fix

Everything below was measured innocent, most of it more than once. Under
Impeller they all still freeze; under Skia they all play.

| Suspect | Verdict |
|---|---|
| The arrangeable grid, drag wrappers, sliver grids | Innocent — a clean-room probe grid freezes identically |
| Texture count (five at once) | Innocent — a bare five-texture grid plays under Impeller |
| Stream Director, keep-alive pool, admission gate | Innocent — dialling raw `openRtspVideo` freezes the same |
| Widget mount order (texture mounted before vs. after first frame) | Innocent — 2×2 factorial, three runs per cell, no effect either way |
| Any single piece of tile chrome, and every pair and triple | Innocent — only the clip is deterministic, and only under Impeller |
| Hardware vs. software decoding | Innocent — the 2026-08-26 corruption was `lowLatency: 1` dropping the first key frame |
| fvp's `GdkGLContext` churn (wang-bin/fvp#271) | Refuted here — zero context-change lines in 30+ instrumented runs; FBO creation identical frozen vs. healthy |

The observed mechanism, for whoever picks this up: **mdk renders into the
void.** Per-player accounting (position, cache, fps, vo) is healthy and
indistinguishable from a playing run, `GL_DEBUG=1` prints no GL errors, and
the FBO is created in the raster thread exactly as it is when the wall
plays — the content simply never becomes the frame Impeller samples.

## Re-check this decision if

Impeller's Linux external-texture path lands a fix (watch flutter#181656,
flutter#183561, flutter#191870), the Skia opt-out is removed, or the wall
freezes again *under Skia* — that would be a different bug, and the first
move is `panel/tool/freeze_probe.sh` plus reading the burned-in camera
clocks: a cell whose clock lags its neighbours is a stalled Wyze stream,
not a severed texture.

Method and rig: `.claude/skills/flutter-linux-eyes/SKILL.md`. The hunt
itself is closed on GitHub issue #4 with a ticket per decision.
