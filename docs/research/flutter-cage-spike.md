# Spike runbook: Flutter under cage on the real hardware

Date: 2026-07-30. Audience: the developer executing the spike on the target box.

**Scope.** The OS/platform decision is already made and is not re-litigated here: plain Linux
(the **mini PC** target is Ubuntu Server **24.04 LTS + HWE kernel** per ADR-0001; the **spike
box** — this dev laptop, which is also the Hub host — is Ubuntu **26.04 LTS**, see "Spike host"
below), `cage` as the kiosk compositor, Flutter GTK bundle as the app —
see `docs/research/platform-os-feasibility.md` §4 and §7. This runbook verifies the things
research could not settle from sources alone.

**Spike host (decided after this research ran; hardware corrected 2026-08-03):** NOT the mini PC
(not yet purchased) but the dev laptop — a Lenovo Legion 9 16IRX8: **Intel Core i9-13980HX with
an Intel UHD iGPU (`i915`) and an NVIDIA RTX 4090 Laptop dGPU**, Ubuntu 26.04 LTS — with the
actual HDMI/USB-HID touchscreen. It is *not* the AMD/Radeon machine this runbook was written
against, so the original "same Mesa/`amdgpu` path as Strix Point, therefore the verdict transfers"
argument is void. What transfers is the driver-independent half: cage/wlroots seat and
compositing, the Flutter GTK embedder, libinput touch, the systemd/PAM boot recipe. What does
**not** transfer is everything below the Mesa API — GL/EGL init, Iris-vs-radeonsi quirks, VAAPI,
gfx1150 enablement. So the §4 checklist is a **full re-run** on the mini PC, not a
regression-check. Either way the NVIDIA dGPU must stay out of the compositor's path (Step 0a).

Compiled from the research fragments: cage-on-Ubuntu, Flutter-GTK-on-Wayland, touch-input/display
layer, and prior-art/fallbacks (all researched 2026-07-30 against primary sources). Inline
citations and **UNVERIFIED** flags are preserved from those fragments.

---

## 1. What we must learn

Each unknown below is tagged with *why* it is still unknown despite the research.

### U1 — Two-finger pinch/zoom through the GTK embedder on Wayland, under cage

Cage forwards every touch point per `touch_id` via `wlr_seat_touch_notify_*`
([seat.c@8a009212](https://github.com/cage-kiosk/cage/blob/8a009212bcc7/seat.c)), and the Flutter
GTK embedder delivers each `GdkEventSequence` as a distinct `PointerDeviceKind.touch` pointer
([fl_touch_manager.cc](https://github.com/flutter/flutter/blob/master/engine/src/flutter/shell/platform/linux/fl_touch_manager.cc)).
Pinch math is then done in the framework (`InteractiveViewer` / `onScaleUpdate`), as on mobile.

**Why unknown:** the embedder also wires `GtkGestureZoom`/`GtkGestureRotate` through
`FlScrollingManager`, which generates `PointerPanZoom` events for *touchpads* (the scroll path
filters on `GDK_SOURCE_TOUCHPAD` —
[fl_scrolling_manager.cc](https://github.com/flutter/flutter/blob/master/engine/src/flutter/shell/platform/linux/fl_scrolling_manager.cc)).
The code strongly suggests GTK gestures do **not** also claim touchscreen sequences, but the
research found **no test evidence either way** — a double delivery would corrupt scale gestures.
Additionally, GitHub searches found **zero published cage+Flutter setups** (`gh search` for
`cage flutter kiosk`, `ExecStart cage flutter` — no relevant hits, 2026-07-30), so this exact
combination has no prior art to lean on; the spike is first-party validation.

### U2 — Fling inertia (touch scroll physics) on this stack

Because the embedder marks touch pointers `kFlutterPointerDeviceKindTouch`
([fl_engine.cc](https://github.com/flutter/flutter/blob/master/engine/src/flutter/shell/platform/linux/fl_engine.cc)),
default `ScrollBehavior` drag-scrolling and fling physics should apply with no workaround.

**Why unknown:** the old contrary issues
[#90366](https://github.com/flutter/flutter/issues/90366) ("does not register
PointerDeviceKind.touch") and [#52202](https://github.com/flutter/flutter/issues/52202) ("does
not support multi-touch") are **still open** — assessed as stale (they predate the Dec-2024
multi-touch engine work, [flutter/engine#54214](https://github.com/flutter/engine/pull/54214)),
but never formally closed. And for the 3.41.x Wayland touch regression
([#182606](https://github.com/flutter/flutter/issues/182606)), **no fixing PR/commit was ever
identified (UNVERIFIED)** — the fixed-in-3.44 claim rests on the issue's multi-machine
confirmations, so behavior on *this* machine still needs a hands-on check.

### U3 — The cage boot recipe actually working on this Ubuntu 24.04 box

The systemd unit + PAM stack is canonical (verbatim from the
[cage wiki](https://github.com/cage-kiosk/cage/wiki/Starting-Cage-on-boot-with-systemd)), and
noble's cage package was verified commit-by-commit to contain the whole touch path (§2 below).

**Why unknown:** three environment-specific facts could not be verified from sources:
(a) whether `libpam-systemd` is present on *minimized* Ubuntu images (**UNVERIFIED** — it is on
standard Server installs); (b) Ubuntu's `libseat1` default backend order (**UNVERIFIED** — logind
inside a PAM session is the path the cage wiki assumes and "the common report is that it just
works"); (c) noble's cage is a git snapshot (`0.1.5+20240127`, effectively master-as-of-Dec-2023
on wlroots 0.17) — no AMD-specific cage bugs were found in the tracker, but this exact build has
never been observed on Strix Point/amdgpu by anyone we can cite.

### U4 — Screen power control (blank at night, wake on touch)

**Why unknown:** cage does **not** implement wlr-output-power-management — verified absent in
both master and the noble package
([#245](https://github.com/cage-kiosk/cage/issues/245) open since 2021, implementing PR
[#512](https://github.com/cage-kiosk/cage/pull/512) still open as of 2026-07-30) — so **`wlopm`
does not work under cage** and the fallback is `wlr-randr --output <name> --off/--on`. That path
*removes the output from the layout* rather than DPMS-blanking it
([emersion in #245](https://github.com/cage-kiosk/cage/issues/245#issuecomment-1691361944));
whether cage's scene and the fullscreen Flutter surface survive off/on cycles cleanly is
**UNVERIFIED** (related open re-enable bug under `-m last`:
[#515](https://github.com/cage-kiosk/cage/issues/515)). Also **UNVERIFIED**: whether the wake
tap is safely swallowed by the app (it *will* be delivered to Flutter as a real touch), and
whether this panel implements DDC/CI at all (`ddcutil` power/brightness — "many small HDMI
touchscreens don't").

### U5 — Boot-to-UI time

**Why unknown:** **UNVERIFIED — no citable measurements exist** for a Linux Flutter kiosk
boot-to-UI; the fragment's single-digit-to-low-teens-seconds figure is explicitly an estimate,
not a measurement. Measure with `systemd-analyze` during the spike.

---

## 2. Known facts going in

Do not re-test these; they are established from primary sources (all verified 2026-07-30 unless
flagged).

**Cage package in noble is newer than it looks, and touch-complete.**
`cage 0.1.5+20240127-2build1` ([packages.ubuntu.com/noble/cage](https://packages.ubuntu.com/noble/cage))
is a git snapshot ≈ upstream master `8a009212` (2023-12-13), i.e. most of what shipped as v0.2.0.
Verified **in** that snapshot: the `touch_frame` fix (commit
[`7ec7e3df`](https://github.com/cage-kiosk/cage/commit/7ec7e3df) — without touch frames many
toolkits mis-assemble multi-touch gestures), true per-point multi-touch forwarding
([seat.c@8a009212](https://github.com/cage-kiosk/cage/blob/8a009212bcc7/seat.c)), cursor
auto-hide on touch-only seats (same file, `update_capabilities()`), no exit on last-DRM-output
unplug ([commit 96ffaa34](https://github.com/cage-kiosk/cage/commit/96ffaa340e)), idle-notify-v1,
and app-exit-code propagation. **Verdict: noble's cage is fine for the spike.** For the real
build, cage 0.2.1 on Ubuntu 26.04 LTS (or 0.3.1 from source, which requires building wlroots
0.20) is the better long-term base — decide only if the spike actually hits a fixed-upstream bug.

**Boot recipe is documented.** The canonical `cage@.service` + `/etc/pam.d/cage` come verbatim
from the [cage wiki](https://github.com/cage-kiosk/cage/wiki/Starting-Cage-on-boot-with-systemd)
(reproduced in the runbook below). `PAMName=cage` + `pam_systemd.so` registers a logind session,
which is what grants the unprivileged user DRM master + input access — no seatd, no
`video`/`input` group hacks. Ubuntu specifics: enable **`cage@tty1`** (Ubuntu Server runs
`getty@tty1`; `Conflicts=getty@%i.service` then replaces it cleanly), and `systemctl set-default
graphical.target`.

**Flutter version pin.** The Wayland touch regression
[#182606](https://github.com/flutter/flutter/issues/182606) (touch dead, mouse fine; broken
through the 3.41.x stable series) is **confirmed fixed in 3.44.0 stable** (reporter closed it
2026-05-22 after confirming on Ubuntu 26.04 + 3.44.0). Nuance: the reporter noted the bug did
*not* reproduce on Ubuntu 24.04 even with broken versions. Current stable at research time:
**3.44.8** (2026-07-23, per the
[release feed](https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json)).
**Pin ≥ 3.44 stable; never fall back to a 3.41.x toolchain.** (The issue reproduced with the
touch device delivered via XWayland — so the spike tests both the default Wayland backend and
`GDK_BACKEND=x11`.)

**GTK backend selection.** GTK3 tries Wayland before X11 whenever `WAYLAND_DISPLAY` is present
([gdk/gdkdisplaymanager.c, gtk-3-24](https://gitlab.gnome.org/GNOME/gtk/-/blob/gtk-3-24/gdk/gdkdisplaymanager.c)),
and Flutter never restricts backends — so under cage the app is a **native Wayland client by
default**. Cage sets `WAYLAND_DISPLAY` (and `DISPLAY` for XWayland) for its child
([cage.1.scd](https://github.com/cage-kiosk/cage/blob/master/cage.1.scd)); the noble package
hard-depends on `xwayland`, so `GDK_BACKEND=x11` is an always-available fallback.

**The default Flutter runner is wrong for kiosks.** The generated `my_application.cc` uses a GTK
HeaderBar (client-side titlebar) on Wayland
([template](https://github.com/flutter/flutter/blob/master/packages/flutter_tools/templates/app/linux.tmpl/runner/my_application.cc.tmpl),
[#111453](https://github.com/flutter/flutter/issues/111453)); Flutter/GTK3 does not support
xdg-decoration ([#94381](https://github.com/flutter/flutter/issues/94381)) and cage's `-d` only
suppresses CSD "when possible". **Fix: patch the runner** — delete the header-bar branch and call
`gtk_window_fullscreen(GTK_WINDOW(window))` before the view is shown.

**Cursor.** Cage hides the cursor whenever the seat has no pointer-capable device — a touch-only
USB HID touchscreen means **no cursor out of the box**. There is no cursor-hiding CLI flag (PRs
[#335](https://github.com/cage-kiosk/cage/pull/335) and
[#519](https://github.com/cage-kiosk/cage/pull/519) both rejected). Gotcha: hardware exposing
spurious pointer-capable input nodes makes the cursor appear — check `libinput list-devices`;
mitigations: udev `ENV{LIBINPUT_IGNORE_DEVICE}="1"`, or Flutter-side
`MouseRegion(cursor: SystemMouseCursors.none)` (mapped to GDK cursor `"none"` in
[fl_mouse_cursor_handler.cc](https://github.com/flutter/flutter/blob/master/engine/src/flutter/shell/platform/linux/fl_mouse_cursor_handler.cc)).

**Protocols under cage (noble snapshot):**

| Protocol | Support | Consequence |
|---|---|---|
| wlr-output-management-v1 | Yes | `wlr-randr` works: modes, `--transform`, `--off/--on` (noble packages `wlr-randr 0.3.0-1`) |
| wlr-output-power-management-v1 | **No** ([#245](https://github.com/cage-kiosk/cage/issues/245)) | **`wlopm` does not work under cage** — even though noble packages it, and upstream cage 0.3.x still lacks it |
| idle-notify-v1 | Yes | `swayidle` works — noble's swayidle **1.8.0** gained ext-idle-notify support exactly in 1.8.0 ([releases](https://github.com/swaywm/swayidle/releases)) |
| idle-inhibit-v1 | Yes | An app/plugin could hold the screen awake (pub.dev plugin existence: **UNVERIFIED**) |
| virtual-keyboard-v1 | Yes | Key-injecting OSKs could type — but see next row |
| input-method-v2 / text-input-v3 | **No** ([#406](https://github.com/cage-kiosk/cage/issues/406), [#417](https://github.com/cage-kiosk/cage/issues/417)) | No compositor-mediated OSK (squeekboard/wvkbd dead ends under cage). Plan: **in-app Flutter OSK widget** |
| screencopy-v1 | Yes | `grim` screenshots — verify the spike remotely |

**Touch plumbing below the compositor.** Modern USB touchscreens are HID multitouch devices on
the kernel's `hid-multitouch` driver emitting evdev MT protocol type B
([kernel MT docs](https://docs.kernel.org/input/multi-touch-protocol.html)); libinput forwards
raw per-finger points for touch*screens* (its pinch/swipe gesture engine is touch*pad*-only) —
gesture recognition is Flutter's job. With a **single output in native orientation, unmapped
touch coordinates degenerate to correct behavior** — rotation is the case that needs the
`WL_OUTPUT` udev rule and/or `LIBINPUT_CALIBRATION_MATRIX`
([cage#126](https://github.com/cage-kiosk/cage/issues/126),
[#243](https://github.com/cage-kiosk/cage/issues/243),
[libinput udev config](https://wayland.freedesktop.org/libinput/doc/latest/device-configuration-via-udev.html)).
The spike runs landscape/native: do neither.

**Rendering.** The embedder renders Skia-on-OpenGL via EGL on Wayland; Impeller on Linux is
"Experimental … not recommended" through 3.44 ([docs.flutter.dev/perf/impeller](https://docs.flutter.dev/perf/impeller)).
No open AMD/radeonsi Flutter bugs found (the one open GL-on-Wayland bug is NVIDIA-specific,
[#188966](https://github.com/flutter/flutter/issues/188966)) — **but 2026-08-03**: that survey
covered the *mini PC's* driver, not the spike box's. The spike box is Intel `i915`/Iris, for which
no equivalent bug survey was ever run; treat its GL path as UNSURVEYED, not clean.
Strix Point wants the HWE stack:
noble-updates has HWE kernel `7.0.0-28` and **Mesa 25.2.8**
([packages.ubuntu.com](https://packages.ubuntu.com/noble-updates/linux-generic-hwe-24.04)) —
comfortably past gfx1150 enablement. The GA 6.8 kernel + Mesa 24.0 stack is the one combination
likely to misbehave.

**Lifecycle.** Cage forks the app as its child and **exits when the app exits, propagating its
exit code** — so `Restart=always` in the unit restarts compositor + app together on any crash.

**Build logistics.** Cross-compiling from macOS is impossible (`'"build linux" only supported on
Linux hosts.'` —
[build_linux.dart](https://github.com/flutter/flutter/blob/master/packages/flutter_tools/lib/src/commands/build_linux.dart));
build **on the box** (or on an x64 CI runner whose image matches the **oldest** box the bundle
must run on — `ubuntu-24.04` for the mini PC's Ubuntu Server 24.04, *not* the dev laptop's 26.04.
glibc is backward- but not forward-compatible, so a bundle linked against 26.04's glibc will not
start on 24.04, while a 24.04-built one runs on both). `flutter build linux --release` needs
no display server — SSH is fine.

**Prior art.** Canonical's Ubuntu Frame Flutter demo proves the identical architecture — a stock
`flutter build linux --release` GTK bundle as a native Wayland client under a kiosk compositor,
supervised restart-always
([iot-example-graphical-snap, branch 24/Flutter-demo](https://github.com/canonical/iot-example-graphical-snap)).
Cage itself was written *for a home-automation panel*
([author's page](https://www.hjdskes.nl/projects/cage/)). Keep `GDK_GL=gles` in the back pocket
if GL context creation fails (from the Frame demo; should be unnecessary on the i915 iGPU's full GL).

---

## 3. Runbook

Do the layers bottom-up (kernel → libinput → Wayland → Flutter) so any failure is immediately
attributable to the right layer.

### Step 0 — OS install

1. On the laptop (primary dev box), install **Ubuntu Desktop LTS amd64** — 26.04 as of
   2026-08-03, not the 24.04 this runbook was written against (GNOME wanted for
   daily dev; it includes `libpam-systemd`). Enable OpenSSH. During spike runs, GNOME's display
   manager must release the seat: either `sudo systemctl stop gdm3` (or `gdm`, depending on
   package) before launching cage from a TTY, or run the Step 8 boot test with
   `sudo systemctl disable gdm3` for the session. (On the
   final mini PC appliance: Ubuntu **Server** standard install, no DE at all.)
### Step 0a — Hybrid-graphics check (laptop-specific, do this FIRST)

The laptop pairs an Intel UHD iGPU (`i915`) with an NVIDIA RTX 4090 dGPU. cage/wlroots must run on the iGPU — the
NVIDIA proprietary driver is the worst-supported wlroots combo, and a failure there would
contaminate the spike verdict. **UNVERIFIED for this specific laptop model**: which GPU the HDMI
connector is wired to (on many performance laptops it is the dGPU).

```bash
sudo apt install -y drm-info
drm_info | less        # per /dev/dri/cardN: driver (i915 vs nvidia) and connector list
# Simpler: for each card, which connectors does it own?
ls -l /sys/class/drm/ | grep -E 'card[0-9]-'   # e.g. card1-HDMI-A-1 → card1 owns HDMI
readlink /sys/class/drm/card*/device/driver    # which card is i915 (iGPU), which is nvidia
ls -l /dev/dri/by-path/                        # the stable pin path — cardN is not guaranteed stable
```

- If **HDMI belongs to the iGPU (`i915`) card**: pin cage to it and proceed —
  `WLR_DRM_DEVICES=/dev/dri/by-path/pci-0000:00:02.0-card cage -- <app>` (add as `Environment=`
  in the Step 8 unit). Pin by `by-path`, never `/dev/dri/cardN`: cardN follows driver probe
  order and is not guaranteed stable across boots or kernel changes. Do not assume the iGPU is
  the low-numbered card either — on this laptop the NVIDIA dGPU enumerates as `card1` and the
  i915 iGPU as `card2` (2026-08-03).
- If **HDMI belongs to the NVIDIA card**: (a) check BIOS/UEFI for a MUX / "hybrid graphics" /
  "iGPU only" switch; (b) try a **USB-C DP-alt-mode → HDMI adapter** — USB-C outputs are commonly
  iGPU-wired (**UNVERIFIED** per model); (c) last resort, run the spike on the laptop's built-in
  screen for the software layers and accept that touch tests wait for an iGPU-driven output.
- Never let cage open the NVIDIA card: `WLR_DRM_DEVICES` pinning above is mandatory either way.

2. Install the HWE stack and fully update (the mini PC's Strix Point graphics need it):

   The HWE meta-package name embeds the LTS release it backports *into*, so it must never be
   hardcoded: `linux-generic-hwe-24.04` on the mini PC's 24.04, `linux-generic-hwe-26.04` on the
   26.04 dev laptop. Derive it from the running release. This is the manual mirror of
   `kiosk_hwe_kernel_packages` in `appliance/ansible/group_vars/all.yml`, which is the automated
   path (the kiosk role does the same lookup and asserts on an unmapped release). HWE stacks
   exist **only on Ubuntu LTS releases** — on an interim release there is nothing to install.

   ```bash
   sudo apt update
   HWE="linux-generic-hwe-$(lsb_release -rs)"   # LTS releases only; 26.04 on this laptop
   sudo apt install -y "$HWE"
   sudo apt-mark manual "$HWE"   # else a release upgrade can leave it auto and autoremovable
   sudo apt full-upgrade -y
   sudo reboot
   # after reboot, sanity-check:
   uname -r                      # expect the HWE kernel, not the GA one (6.8 on 24.04)
   dpkg -l libpam-systemd        # must be installed (PAM session -> logind)
   ```

### Step 1 — Packages

```bash
sudo apt install -y cage wlr-randr swayidle grim ddcutil evtest libinput-tools wev
# all in noble universe
sudo apt install -y clang cmake ninja-build pkg-config libgtk-3-dev libstdc++-12-dev
# Flutter Linux toolchain prerequisites (docs.flutter.dev/platform-integration/linux/setup)
sudo apt install -y curl git unzip zip xz-utils
# Flutter SDK bootstrap prerequisites — verified missing-by-default in the
# appliance/test container: without unzip, the flutter launcher fails with
# "Unable to extract Dart SDK".
```

### Step 2 — Verify touch at the kernel layer (evtest)

```bash
sudo evtest    # pick the touchscreen from the device menu
```

In the capability dump, require (per the
[kernel MT docs](https://docs.kernel.org/input/multi-touch-protocol.html)):

- `ABS_MT_POSITION_X` / `ABS_MT_POSITION_Y` — minimum MT event set;
- `ABS_MT_SLOT` — type-B protocol; its **max = simultaneous contacts the firmware tracks**
  (need ≥ 2, prefer ≥ 5);
- `ABS_MT_TRACKING_ID` — per-contact lifecycle.

Live test: two fingers down → interleaved `ABS_MT_SLOT 0/1` blocks with distinct
`ABS_MT_TRACKING_ID`s and independent X/Y streams. **This is the ground truth for pinch
capability.** If the device enumerates in `lsusb` but emits no events, open the USB-quirks
drawer (`usbhid.quirks=` kernel parameter — device-specific, **UNVERIFIED** for any 2026 panel).

### Step 3 — Verify at the libinput layer

```bash
sudo libinput list-devices        # device present, "touch" capability listed
                                  # ALSO: look for spurious pointer-capable nodes (cursor gotcha)
sudo libinput debug-events        # tap/drag: expect TOUCH_DOWN / TOUCH_MOTION / TOUCH_UP frames
libinput quirks list /dev/input/eventN   # which quirks database entries apply
```

If a bogus pointer device exists (HDMI-CEC node, touch controller with a mouse interface), plan
the udev rule `ENV{LIBINPUT_IGNORE_DEVICE}="1"` for it.

### Step 4 — Verify a Wayland client under cage (pre-Flutter)

From a **logged-in local tty** (not SSH — cage needs the seat):

```bash
cage -- wev          # touch the screen; wev prints seat events
```

Caveat: whether wev prints `wl_touch` events is **UNVERIFIED** (the noble manpage doesn't
enumerate touch; upstream sourcehut was 502ing during research). If wev stays silent on touch
while Step 3 passed, skip straight to Step 6 — the Flutter app itself is the layer-3 probe.

### Step 5 — Install Flutter on the box, build the test app

```bash
git clone -b stable https://github.com/flutter/flutter.git ~/flutter
export PATH="$HOME/flutter/bin:$PATH"
flutter --version        # MUST be >= 3.44.0 (Wayland touch fix); 3.44.8 current at research time
flutter create spike_app && cd spike_app
```

**Patch the runner** (`linux/runner/my_application.cc`, in `my_application_activate()`): delete
the HeaderBar branch (the `if` that creates `GtkHeaderBar`) and replace with:

```c
gtk_window_set_title(window, "spike_app");
gtk_window_fullscreen(GTK_WINDOW(window));   // before gtk_widget_show / view realization
```

**Test app content** (`lib/main.dart`) — four pages behind a bottom nav, the whole app wrapped in
`MouseRegion(cursor: SystemMouseCursors.none, ...)`:

1. **Counter page** — the stock counter. Baseline: tap targeting works at all.
2. **Multi-touch visualizer** — a `Listener` (`onPointerDown/Move/Up`) over a `CustomPaint` that
   draws a circle per active pointer and logs `event.pointer`, `event.kind`,
   `event.localPosition`. **Pass-relevant observation: two fingers must appear as two distinct
   pointers with `PointerDeviceKind.touch`** (validates U2 against the stale #90366/#52202).

   ```dart
   class TouchVizPage extends StatefulWidget { /* ... */ }
   // state holds Map<int, Offset> active;
   Listener(
     onPointerDown: (e) => setState(() => active[e.pointer] = e.localPosition),
     onPointerMove: (e) => setState(() => active[e.pointer] = e.localPosition),
     onPointerUp:   (e) => setState(() => active.remove(e.pointer)),
     onPointerCancel: (e) => setState(() => active.remove(e.pointer)),
     child: CustomPaint(painter: DotsPainter(active), child: const SizedBox.expand()),
   )
   // also debugPrint('${e.pointer} ${e.kind} ${e.localPosition}') in each handler
   ```

3. **Fling page** — a plain `ListView.builder` with ~200 tall items. Observation: after a quick
   drag-and-release, scrolling must continue with deceleration (fling inertia).
4. **Pinch page** — an `InteractiveViewer` (min/max scale e.g. 0.5–8.0) around a large gridded
   image or `GridPaper`, plus a `GestureDetector.onScaleUpdate` readout of the current scale
   factor. Observation: smooth two-finger pinch/zoom with **no jumps, stutters, or
   double-application of scale** (the GtkGestureZoom double-delivery risk, U1).

```bash
flutter build linux --release
# output: build/linux/x64/release/bundle/spike_app  (self-contained dir; deploy = copy dir)
```

### Step 6 — Run under cage, test touch (the core of the spike)

From a local tty:

```bash
cage -- ~/spike_app/build/linux/x64/release/bundle/spike_app
```

Work through: tap (counter), two-finger visualizer, fling, pinch. Then repeat the same battery
with the X11 path forced (the #182606 repro came through XWayland, so test both):

```bash
GDK_BACKEND=x11 cage -- ~/spike_app/build/linux/x64/release/bundle/spike_app
```

Also confirm: no titlebar (runner patch effective), no cursor visible (touch-only seat +
`SystemMouseCursors.none`). Grab evidence remotely over SSH with `grim` (screencopy works under
cage): `WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/$(id -u <user>) grim /tmp/shot.png`
(export the cage session's env — same trick lets `flutter run -d linux` target the cage session
from SSH).

### Step 7 — Screen blank/wake probe

Manual probe first, from SSH with the cage session env exported:

```bash
wlr-randr                                   # learn the output name (e.g. HDMI-A-1)
wlr-randr --output HDMI-A-1 --off; sleep 3; wlr-randr --output HDMI-A-1 --on
```

Watch `journalctl -f` / the cage log for output-remove side effects, and **check the Flutter
surface comes back full-screen at the right size** (output `--off` removes the output from the
layout — [#245 discussion](https://github.com/cage-kiosk/cage/issues/245#issuecomment-1691361944);
cage won't exit thanks to [96ffaa34](https://github.com/cage-kiosk/cage/commit/96ffaa340e), but
resize-back is the **UNVERIFIED** part). Then the automated pattern (syntax per
[swayidle(1)](https://manpages.ubuntu.com/manpages/noble/man1/swayidle.1.html)) with a short
timeout for testing:

```bash
swayidle -w \
  timeout 30 'wlr-randr --output HDMI-A-1 --off' \
  resume     'wlr-randr --output HDMI-A-1 --on'
```

Wait 30 s → screen off; tap → screen on. Note whether the wake tap also *acts* inside the app
(it is delivered as a real touch — the production app must debounce input-after-blank).

DDC/CI probe (compositor-independent alternative):

```bash
sudo modprobe i2c-dev
sudo ddcutil detect
sudo ddcutil capabilities
sudo ddcutil getvcp 10                      # brightness
sudo ddcutil setvcp D6 0x05                 # power off (VCP D6) — panel-dependent, UNVERIFIED
```

Record the result either way — DDC/CI support is a **panel-selection criterion** if
night-dimming matters.

### Step 8 — Boot-to-panel: systemd unit + PAM

`/etc/systemd/system/cage@.service` — verbatim from the
[cage wiki](https://github.com/cage-kiosk/cage/wiki/Starting-Cage-on-boot-with-systemd), with the
`ExecStart` app swapped in and the fragment-recommended restart tweaks:

```ini
# This is a system unit for launching Cage with auto-login as the
# user configured here. For this to work, wlroots must be built
# with systemd logind support.

[Unit]
Description=Cage Wayland compositor on %I
# Make sure we are started after logins are permitted. If Plymouth is
# used, we want to start when it is on its way out.
After=systemd-user-sessions.service plymouth-quit-wait.service
# Since we are part of the graphical session, make sure we are started
# before it is complete.
Before=graphical.target
# On systems without virtual consoles, do not start.
ConditionPathExists=/dev/tty0
# Spike addition: never park the unit in 'failed' with a dead screen.
# (Belongs in [Unit] per systemd.unit(5) — in [Service] it is only a
# backward-compat alias and could be ignored, defeating pass item 12.)
StartLimitIntervalSec=0
# D-Bus is necessary for contacting logind, which is required.
Wants=dbus.socket systemd-logind.service
After=dbus.socket systemd-logind.service
# Replace any (a)getty that may have spawned, since we log in
# automatically.
Conflicts=getty@%i.service
After=getty@%i.service

[Service]
Type=simple
ExecStart=/usr/bin/cage /home/cage/spike_app/bundle/spike_app
ExecStartPost=+sh -c "tty_name='%i'; exec chvt $${tty_name#tty}"
Restart=always
# Spike addition: fast relaunch (StartLimitIntervalSec lives in [Unit], above)
RestartSec=1
# Optional: uncomment if the USB touchscreen enumerates late at boot
# (wlroots refuses to start with zero input devices — cage wiki Troubleshooting)
#Environment=WLR_LIBINPUT_NO_DEVICES=1
# Optional belt-and-braces (GTK already prefers Wayland):
#Environment=GDK_BACKEND=wayland
User=cage
# Log this user with utmp, letting it show up with commands 'w' and
# 'who'. This is needed since we replace (a)getty.
UtmpIdentifier=%I
UtmpMode=user
# A virtual terminal is needed.
TTYPath=/dev/%I
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
# Fail to start if not controlling the virtual terminal.
StandardInput=tty-fail

# Set up a full (custom) user session for the user, required by Cage.
PAMName=cage

[Install]
WantedBy=graphical.target
# EMPIRICAL CORRECTION (appliance/test container, systemd 255/noble): the
# wiki's 'Alias=display-manager.service' line that belongs here BREAKS
# 'systemctl enable cage@tty1' — "Cannot alias cage@tty1.service as
# display-manager.service" (systemd cannot alias template instances). Omit
# it; boot-in works via the WantedBy symlink alone.
# tty1, not the wiki's tty7 — we enable cage@tty1 explicitly (getty lives on
# tty1); aligning DefaultInstance avoids surprises on an instance-less enable.
DefaultInstance=tty1
```

`/etc/pam.d/cage` (wiki recipe minus `nullok`: nothing in the systemd
`PAMName=` flow ever calls `pam_authenticate` and the cage account is locked,
so `nullok` was only a dormant blank-password auth path):

```
auth           required        pam_unix.so
account        required        pam_unix.so
session        required        pam_unix.so
session        required        pam_systemd.so
```

Setup:

```bash
# dedicated unprivileged user: system account, locked password, no login
# shell — the only way in is the unit's PAM session (matches the ansible
# kiosk role, which automates this whole step)
sudo useradd --system --create-home --home-dir /home/cage --shell /usr/sbin/nologin cage
# copy the bundle: rsync -a ~/spike_app/build/linux/x64/release/bundle/ /home/cage/spike_app/bundle/
sudo systemctl enable cage@tty1.service    # explicit tty1 instance —
                                           # Conflicts= then evicts Ubuntu's getty@tty1 cleanly
sudo systemctl set-default graphical.target
sudo reboot
```

Notes baked into the recipe:

- Do **not** pass `-s` to cage — VT switching stays disabled (default), Ctrl-Alt-F2 is dead.
  **Keep SSH working before you reboot.**
- If cage logs "no seat" errors, escape hatch: `apt install seatd`, enable `seatd.service`, add
  the user to `video`+`input` groups, `LIBSEAT_BACKEND=seatd` (libseat default backend order on
  Ubuntu: **UNVERIFIED**; logind-via-PAM is the expected path).
- Appliance polish (optional for the spike, record findings anyway): in `/etc/default/grub` set
  `GRUB_TIMEOUT=0` and `GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3"`; in
  `/etc/systemd/logind.conf` set `NAutoVTs=0` and `ReserveVT=0`
  ([logind.conf(5)](https://manpages.ubuntu.com/manpages/noble/man5/logind.conf.5.html));
  `vt.global_cursor_default=0` hides the blinking VT cursor but its doc text is **UNVERIFIED** —
  confirm on-device via `/sys/module/vt/parameters/global_cursor_default`.

### Step 9 — Crash/restart and boot-time measurements

```bash
# from SSH:
pkill -9 -f spike_app          # app dies -> cage exits (propagates exit code) -> systemd restarts
journalctl -u cage@tty1 -f     # confirm clean relaunch, screen comes back to the app
systemd-analyze
systemd-analyze critical-chain cage@tty1.service   # record boot-to-UI (U5 — no prior data exists)
```

---

## 4. Pass/fail criteria

| # | Capability | How to test | Pass bar |
|---|---|---|---|
| 1 | Kernel multi-touch | Step 2, `evtest` capability dump + two fingers | `ABS_MT_SLOT` max ≥ 2 (prefer ≥ 5); two slots with distinct `TRACKING_ID`s and independent X/Y |
| 2 | libinput touch | Step 3, `libinput debug-events` | `TOUCH_DOWN/MOTION/UP` frames for 1 and 2 fingers; no spurious pointer device (or one identified + ignorable) |
| 3 | Tap | Step 6, counter page | Buttons hit reliably at panel edges and center |
| 4 | Distinct touch pointers | Step 6, visualizer page | Two fingers = two circles, two pointer ids, `PointerDeviceKind.touch` (not mouse) |
| 5 | Fling inertia | Step 6, ListView page | Scroll continues with natural deceleration after release, both backends (default Wayland and `GDK_BACKEND=x11`) |
| 6 | Pinch/zoom | Step 6, InteractiveViewer page | Smooth continuous scale tracking two fingers; **no double-scale jumps/glitches** (GtkGestureZoom interplay) |
| 7 | Fullscreen, no chrome | Step 6, visual | No titlebar/HeaderBar, app fills the panel |
| 8 | No cursor | Step 6, visual | No pointer sprite ever appears on the touch-only seat |
| 9 | Blank/unblank | Step 7, `wlr-randr --off/--on` + swayidle | Screen off on idle; tap wakes it; Flutter surface returns fullscreen at correct size, no cage crash in journal |
| 10 | DDC/CI (informational) | Step 7, `ddcutil detect/capabilities/getvcp 10` | Record yes/no + supported VCP codes; not a spike blocker — a panel-purchase criterion |
| 11 | Boot-to-panel | Step 8, reboot | Power-on → app with no getty/login flash; unit active, `graphical.target` reached |
| 12 | Crash resilience | Step 9, `pkill -9` | systemd relaunches cage+app automatically; screen recovers without manual action; unit never enters `failed` |
| 13 | Boot time (measure only) | Step 9, `systemd-analyze` | Record numbers — no prior citable data exists (U5); no pass bar for the spike |

Attribution rule from the research: cage verifiably forwards all touch points — **any multi-touch
failure at Step 6 while Steps 2–3 pass lives in the Flutter embedder or the kernel HID driver,
not in cage.**

---

## 5. Fallback ladder

Pick the rung matching the observed failure mode (rungs are alternatives keyed to causes, not a
strict sequence). Same systemd skeleton works for A and D by swapping `ExecStart`.

### Rung A — Weston kiosk-shell

**Trigger:** *cage itself* misbehaves on this GPU/output (crashes, damage/output glitches, focus
quirks) while the Flutter Wayland client is fine.

Noble ships weston 13.0.0 with `kiosk-shell.so` in the package
([packages.ubuntu.com/noble/weston](https://packages.ubuntu.com/noble/weston)). Minimal
`weston.ini` (keys verified against the
[noble weston.ini(5) manpage](https://manpages.ubuntu.com/manpages/noble/en/man5/weston.ini.5.html)):

```ini
[core]
shell=kiosk

[autolaunch]
path=/usr/local/bin/start-spike.sh   # wraps the Flutter bundle + env
watch=true                           # weston exits when the app exits -> systemd restarts both

[output]
name=HDMI-A-1
app-ids=com.example.spike_app        # the GTK APPLICATION_ID from the Flutter runner
```

The Ubuntu package ships **no unit files**; reuse the cage@tty1 skeleton with
`ExecStart=/usr/bin/weston` (`weston@tty1` as a packaged recipe: **UNVERIFIED** — community
convention). Multi-touch quality under kiosk-shell specifically: **UNVERIFIED**, but weston is
the reference compositor and touch is a core protocol feature.

### Rung B — `GDK_BACKEND=x11` under cage's XWayland

**Trigger:** compositor fine, but Flutter's *Wayland* GTK path has broken tap/drag/pinch (input
offsets, dead regions, pinch not recognized).

Noble's cage hard-depends on `xwayland`, and cage exports `DISPLAY` to the child. One line in the
unit:

```ini
Environment=GDK_BACKEND=x11
```

XWayland translates `wl_touch` into XInput2 touch events, so multi-touch is *expected* to survive
for GTK3 (XI2.2-aware) — **UNVERIFIED** from source this session (freedesktop GitLab blocked
fetch); the Step 6 x11 run is the verification. Expect slightly higher latency and
pointer-emulation edge cases for the first touch point.

### Rung C — labwc as compositor

**Trigger:** cage's *stale noble package* (0.1.5-snapshot/wlroots 0.17 vs upstream 0.3.1/wlroots
0.20) is identified as the root cause, and you want a current, apt-packaged wlroots compositor
without building cage+wlroots from source or adopting snaps. (Noble ships labwc 0.7.1 —
[packages.ubuntu.com/noble/labwc](https://packages.ubuntu.com/noble/labwc).)

`~/.config/labwc/rc.xml` (from [labwc-config(5)](https://labwc.github.io/labwc-config.5.html)):

```xml
<windowRules>
  <windowRule identifier="com.example.spike_app" serverDecoration="no">
    <action name="Maximize" />
  </windowRule>
</windowRules>
<keyboard><!-- no <default/>, no keybinds: all shortcuts disabled --></keyboard>
```

`~/.config/labwc/autostart`: `~/spike_app/bundle/spike_app &`. Trade-off: full stacking WM — no
built-in guarantee the app stays fullscreen/focused; a restarted app relies on the window rule
re-matching.

### Rung D — flutter-pi (no compositor, bare KMS/DRM)

**Trigger:** *both* compositor paths fail on input or the iGPU, or boot-to-pixels time becomes a
hard requirement. Accept the plugin-ecosystem and engine-binary costs.

- [ardera/flutter-pi](https://github.com/ardera/flutter-pi), release 1.1.1 (2026-01-31). x86-64
  is explicitly supported (README: KMS/DRI + "x86 or x86 64bit"); amdgpu specifically:
  **UNVERIFIED, likely-works** (no amdgpu success report found in the issue tracker).
- **Gate before committing:** check `flutterpi_tool build --arch=x64` — whether a prebuilt **x64
  target** engine exists or you must build `libflutter_engine.so` yourself is **UNVERIFIED**
  ([flutter-engine-binaries-for-arm](https://github.com/ardera/flutter-engine-binaries-for-arm)
  is ARM-focused).
- Touch via libinput (README); multi-touch pinch not explicitly documented — **UNVERIFIED**.
- The feared "no fling inertia through the embedder API"
  ([flutter/flutter#120020](https://github.com/flutter/flutter/issues/120020)) is a **stale
  premise**: closed same-day 2023-02-05 — a third-party embedder passed pointer timestamps in
  milliseconds instead of the expected microseconds; never a flutter-pi defect. Inertia should
  work; still verify empirically.
- Plugin cost: pure-Dart packages fine; native-Linux plugins need flutter-pi-side
  implementations (provided: gstreamer video player, audioplayers, partial sentry, gpiod,
  serial); no webview; desktop plugins (window_manager etc.) won't work.

Config sketch: `flutter-pi --release /path/to/flutterpi-built-assets` from a systemd unit (no
compositor, no PAM/VT dance needed beyond DRM master via logind/seatd).

### Rung E (bonus) — Ubuntu Frame snap

**Trigger:** you want vendor-supported kiosk plumbing (config options, OSK, power-save —
[Frame config reference](https://canonical-ubuntu-frame-documentation.readthedocs-hosted.com/24/reference/ubuntu-frame-configuration-options/))
more than a minimal stack, and snapd on the box is acceptable.

`snap install ubuntu-frame`, run it as a daemon, point the Flutter bundle at its Wayland socket —
the fully Canonical-documented path
([iot-example-graphical-snap 24/Flutter-demo](https://github.com/canonical/iot-example-graphical-snap)).

Also on the shelf (from the touch/display fragment): if `wlr-randr --off` proves flaky for screen
power, **sway in kiosk mode** supports `output * power off` natively — noted as plan-B for the
power-control axis specifically, not researched in depth.

---

## 6. Open items the spike cannot answer

- **Final panel hardware selection.** The spike characterizes *this* touchscreen only. For the
  production panel: DDC/CI support (brightness/standby — "cheap HDMI touchscreens frequently
  don't implement it"; make it a purchase criterion), firmware touch-slot count (≥ 5 preferred),
  USB HID quirks, and HDMI-CEC support (**UNVERIFIED** for this device class; most PC-style touch
  monitors lack CEC) must be re-verified per candidate panel.
- **Portrait mounting.** If the dollhouse panel ends up portrait, touch does not follow
  `wlr-randr --transform` unless the device is `WL_OUTPUT`-mapped and/or a
  `LIBINPUT_CALIBRATION_MATRIX` is set — and results with the udev mapping are **mixed** per
  [cage#243](https://github.com/cage-kiosk/cage/issues/243). Needs the final panel + mount
  decision; budget dedicated time.
- **Doorbell audio while the screen is blanked.** Whether the HDMI audio sink survives
  `wlr-randr --off` (or clips the first chime while the link retrains) is **UNVERIFIED** and
  panel-dependent; the fragment's recommendation is spike both HDMI and a USB speaker, ship USB.
  Decide once the audio hardware is chosen.
- **In-app on-screen keyboard.** Cage lacks text-input/input-method, so any text entry needs a
  Flutter-side OSK widget — a build-phase design task, not a spike measurement. (If an external
  OSK ever becomes a hard requirement, that forces a compositor change.)
- **Long-term cage base.** Whether to stay on noble's snapshot, move to Ubuntu 26.04 LTS (cage
  0.2.1/wlroots 0.19), or build 0.3.1+wlroots 0.20 from source — decide only if the spike hits a
  fixed-upstream bug; no trustworthy 0.3.x PPA for noble exists (**UNVERIFIED** whether any
  third-party one is current).
- **Which engine commit fixed #182606** — still unidentified upstream (**UNVERIFIED**); the
  practical mitigation is the ≥ 3.44 pin, permanently.
- **Idle-inhibit from Flutter** — cage supports idle-inhibit-v1, but whether any pub.dev plugin
  speaks it today is **UNVERIFIED**; needed later for "keep screen awake during active use".
