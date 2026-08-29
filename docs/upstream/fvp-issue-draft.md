# DRAFT — wang-bin/fvp issue (do not post without owner review)

> Post under the owner's account at github.com/wang-bin/fvp/issues/new AFTER the
> flutter issue exists, and link it where marked. Strip this header block.

**Proposed title:** Linux/GTK: renderVideo output never reaches the screen under
Impeller (Flutter 3.47 Linux default) — multi-player wall shows blank/garbage
textures; fine with Impeller disabled

Since Flutter 3.47 made Impeller the default renderer on Linux, a five-player RTSP
wall (fvp 0.38.1, mdk 0.38.0, software decode, GTK embedder, Ubuntu 26.04
Wayland) renders blank or uninitialized-FBO-garbage textures — deterministically
once a rounded clip sits over the textures, and occasionally as a
simultaneous all-player stop without one. The same build with
`fl_dart_project_set_enable_impeller(project, FALSE)` renders every configuration
correctly. Full evidence and bisect summary in the flutter issue:
`<LINK FLUTTER ISSUE HERE>`.

Observations that may help place it in the plugin:

- mdk's accounting looks healthy while the glass is dead: per-player position
  advances, cache full, ~20 fps render pace, `vo` steady — identical to a playing
  run. `GL_DEBUG=1` prints no GL errors. renderVideo appears to run to completion
  every frame with its output never reaching Flutter's texture.
- The plugin's `gdk gl context change` cleanup witness never fires (30+
  instrumented runs), and the `created fbo: N tex: M in raster thread T` lines are
  identical in frozen and healthy runs — so this looks distinct from the
  #270/#271 cleanup-context family: the FBO is created "successfully" in the
  raster thread either way, but under Impeller its content never becomes the
  frame Impeller samples once clip/saveLayer content shares the scene.
- Single player + same card chrome: fine. Five players, no clip: usually fine,
  rare simultaneous stop of all five.

Happy to run patches/diagnostics — we have an unattended screenshot-diff rig that
verdicts a run in ~40 s, so turnaround on candidate fixes is minutes.
