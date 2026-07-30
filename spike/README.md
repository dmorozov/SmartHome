# Spike: Flutter under cage

Validates the go/no-go for building the Panel in native Flutter: a release
Flutter GTK bundle running under the `cage` Wayland kiosk compositor must
deliver real multi-touch (tap, distinct touch pointers, fling inertia,
pinch/zoom) on the Appliance's touchscreen, plus fullscreen-no-chrome, no
cursor, blank/wake, boot-to-panel, and crash resilience. Full procedure,
unknowns, and fallback ladder: [`../docs/research/flutter-cage-spike.md`](../docs/research/flutter-cage-spike.md).

## Prerequisites

- The dev laptop (AMD Radeon iGPU): Ubuntu 24.04 LTS + HWE kernel, the
  HDMI/USB-HID touchscreen attached.
- System packages (cage, wlr-randr, evtest, Flutter Linux toolchain deps):
  the ansible kiosk role: [`../appliance/ansible/`](../appliance/ansible/)
  (`ansible-playbook site.yml -l laptop`).
- Flutter >= 3.44 stable on PATH — never 3.41.x (Wayland touch regression;
  runbook Step 5).
- Hybrid GPU: know which `/dev/dri/cardN` is the amdgpu iGPU and pin cage to
  it with `WLR_DRM_DEVICES` (runbook Step 0a) — cage must never open the
  NVIDIA card.

## Run

Build over SSH if you like; **launch cage from a local TTY** (it needs the
seat — stop GNOME first: `sudo systemctl stop gdm`). From `spike/`:

```sh
./bootstrap.sh    # verify Flutter, generate + patch the Linux runner, build release bundle
WLR_DRM_DEVICES=/dev/dri/card<N-of-amdgpu> cage -- "$PWD/app/build/linux/x64/release/bundle/spike_app"
WLR_DRM_DEVICES=/dev/dri/card<N-of-amdgpu> GDK_BACKEND=x11 cage -- "$PWD/app/build/linux/x64/release/bundle/spike_app"
```

Run the same touch battery on both launches — the Wayland default and the
XWayland (`GDK_BACKEND=x11`) fallback path.

## Pass/fail (compressed from runbook §4)

| # | Capability | Pass bar |
|---|---|---|
| 1 | Kernel multi-touch | `evtest`: `ABS_MT_SLOT` max >= 2 (prefer >= 5); two slots with distinct `TRACKING_ID`s, independent X/Y |
| 2 | libinput touch | `TOUCH_DOWN/MOTION/UP` frames for 1 and 2 fingers; no spurious pointer device (or one identified + ignorable) |
| 3 | Tap | Counter buttons hit reliably at panel edges and center |
| 4 | Distinct touch pointers | Two fingers = two circles, two pointer ids, `PointerDeviceKind.touch` (not mouse) |
| 5 | Fling inertia | Scroll keeps decelerating after release — on both backends (Wayland and `GDK_BACKEND=x11`) |
| 6 | Pinch/zoom | Smooth continuous scale tracking two fingers; no double-scale jumps/glitches (GtkGestureZoom interplay) |
| 7 | Fullscreen, no chrome | No titlebar/HeaderBar; app fills the panel |
| 8 | No cursor | No pointer sprite ever appears on the touch-only seat |
| 9 | Blank/unblank | `wlr-randr --off/--on` + swayidle: tap wakes; Flutter surface returns fullscreen at correct size; no cage crash in journal |
| 10 | DDC/CI (informational) | Record `ddcutil` yes/no + supported VCP codes; panel-purchase criterion, not a spike blocker |
| 11 | Boot-to-panel | Power-on -> app with no getty/login flash; unit active, `graphical.target` reached |
| 12 | Crash resilience | `pkill -9` -> systemd relaunches cage+app; screen recovers without manual action; unit never enters `failed` |
| 13 | Boot time (measure only) | Record `systemd-analyze` numbers; no pass bar — no prior citable data exists |
