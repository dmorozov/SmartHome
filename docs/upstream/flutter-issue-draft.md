# DRAFT — flutter/flutter issue (do not post without owner review)

> Post under the owner's account at github.com/flutter/flutter/issues/new (bug template).
> Before posting: paste real `flutter doctor -v` output where marked, attach the four
> PNGs and two logs from `docs/upstream/evidence/`, and strip this header block.

**Proposed title:** Linux/GTK: multiple external textures (fvp video) freeze under
Impeller — textures born dead once clip/shadow content is in the scene; same app
renders correctly with Impeller disabled

## Steps to reproduce

1. Flutter 3.47.2 stable, Linux desktop (GTK embedder), Ubuntu 26.04 under Wayland
   (GDK Wayland backend; X11 via XWayland reproduces identically).
2. Play five simultaneous RTSP H.264 streams through the `fvp` plugin (0.38.1,
   mdk-sdk 0.38.0) as `Texture` widgets in a `GridView` — one texture per stream,
   software decode (FFmpeg).
3. Wrap each tile in ordinary card chrome: a rounded `ClipRRect`/`Container` clip,
   `BoxShadow`s, a name bar. (A minimal grid of five fvp textures inside clipped,
   shadowed cards is the whole repro; we can extract a standalone app on request —
   our clean-room probe reproduces with nothing but `Texture` + card chrome.)

## Expected

Five moving pictures, as on Windows/macOS, and as this exact app renders on Linux
with Impeller disabled (`fl_dart_project_set_enable_impeller(project, FALSE)`).

## Actual (Impeller, the 3.47 Linux default)

Every video texture is **born dead**: tiles show either a blank face or
uninitialized-FBO confetti while the UI around them (badges, animations) draws at
60 fps and the streams provably decode (player accounting healthy — see log). A
window-wide redraw (scrolling the grid) refreshes the stale content once. This is
deterministic across runs when the clip is present from first frame
(`evidence/impeller-early-born-dead.png` — note LIVE badges over blank/confetti
tiles).

With the clip removed (square textures, decorations painted behind/over instead),
the wall usually plays — but occasionally **all five textures stop at the same
instant** after rendering good frames (`evidence/impeller-noclip-wallwide-stop.png`
— the five camera-burned clocks are synchronized, and the pixels never change
again), suggesting a single global event severs every external texture's output
at once.

The same build, same streams, same machine with Impeller disabled renders the full
design correctly in every run (`evidence/skia-full-design-healthy.png`,
`evidence/skia-default-shipped-config.png`).

A second, possibly related artifact: colored corruption bands along tile edges
appear only under Impeller, never under Skia (visible in the born-dead grab).

## What we ruled out (summary of a two-day bisect)

- Decode is alive and the producer runs: with mdk status logging, frozen runs show
  per-player position advancing, healthy cache, ~20 fps render accounting —
  indistinguishable from a playing run (`evidence/impeller-early-mdk.log` vs
  `evidence/skia-full.log`). No GL errors with mdk's `GL_DEBUG=1`.
- No GdkGLContext churn: fvp's own `gdk gl context change` witness line never fired
  across 30+ instrumented runs; its FBO-creation lines are identical in frozen and
  healthy runs (five FBOs, same raster thread).
- Not texture count (a bare five-texture grid plays under Impeller), not widget
  mount order, not a specific decoration (shadow, rounded background, painted
  corners, and a name bar each play alone and in every pair/triple combination) —
  the deterministic trigger is the rounded clip over the texture set; probability
  of the wall-wide stop grows with composited load. One texture with the same card
  plays fine (a zoomed single camera works).
- `FLUTTER_ENGINE_SWITCHES` is compiled out of release builds
  (`engine_switches.cc`, `#ifndef FLUTTER_RELEASE`), which cost us a week of
  believing an "Impeller vs Skia A/B" that measured Impeller against Impeller —
  the working A/B uses `fl_dart_project_set_enable_impeller`.

## Environment

- Flutter 3.47.2 stable (d3b14c8769), Impeller OpenGLES backend
  (`Using the Impeller rendering backend (OpenGLESSDF)`)
- Ubuntu 26.04, GNOME/Mutter Wayland session; Intel/NVIDIA Optimus (Legion) laptop
- fvp 0.38.1 / mdk-sdk 0.38.0, FFmpeg software decode
- `<PASTE flutter doctor -v HERE>`

## Possibly related

flutter#181656 (Impeller-Linux external texture descriptor fix, in 3.47),
flutter#183561 (ReactorGLES deleting embedder-owned GL textures, in 3.47),
flutter#175887 (FlPixelBufferTexture copy_pixels never called),
flutter#191870 (previous frame stays on screen, Linux present path),
wang-bin/fvp#271 (GL cleanup context bug, fixed in fvp 0.33.0 — mechanism ruled
out here as above).

Given the Skia opt-out is slated for removal, this class of app (camera walls,
multi-video dashboards) currently has no forward path on Linux.
