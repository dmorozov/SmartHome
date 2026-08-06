# Roadmap, standing decisions, and the original plan

Dated planning records, moved out of the root README 2026-08-06 so it can
stay a front door. Nothing here is live work: the human TODO list is
[`../TODO.md`](../TODO.md), formal decisions are [`adr/`](adr/README.md),
and execution status lives in
[`../appliance/COMMISSIONING.md`](../appliance/COMMISSIONING.md) and the
[phase plans](plans/device-integrations/README.md).

## Decisions (grilling session 2026-07-30)

- **Goal**: a reliable working smart home — boring, proven base; creative effort goes into the custom UI.
- **Local vs cloud**: local-first for all NEW device purchases; existing cloud devices accepted as cloud-integrated.
- **Hub choice**: device coverage + custom-frontend API quality win over implementation language (Java preferred only as tiebreaker; hub is treated as a headless black-box appliance). → **Home Assistant Container**.
- **UI surfaces**: custom dollhouse UI targets the single wall touchscreen only; family phones use the hub's stock mobile app (HA Companion) over VPN.
- **Panel count**: one panel now, likely more later — the same Flutter codebase can compile to Flutter Web later to serve additional thin-client panels.
- **Dollhouse rendering**: 2.5D isometric stacked floors (one per level, tap to expand, rooms glow with light state, device icons pinned per room) — not a true 3D model.
- **Automations**: authored and executed in the hub's native engine; the panel is a pure view/command layer.
- **Video, phase 1**: tap-to-open live popup only (doorbell ring pops up Ring video; tap a camera in the dollhouse to view). No recording. → **Amended 2026-08-05 (phase 7)**: the **Cameras** view is the second video surface — right-edge tab on the Dollhouse, tiles tap-to-toggle their own streams, the doorbell's off by default (an open Ring session suppresses dings). Recording is still deferred, by owner decision, and the architecture that will host it is phase-7 §C.
- **Garage (myQ)**: hardware retrofit approved — ratgdo board wired to the opener for fully local control/status (myQ third-party API is dead). Verify opener model compatibility before ordering.
- **Mini-PC**: Ryzen AI, 32GB RAM; REQUIRE a free SO-DIMM slot and 2 × M.2 slots (future: RAM for LLM, second disk for NVR, Hailo-8L accelerator — the Ryzen NPU is NOT a viable Frigate path per research).
- **New lighting/outlets** (~10–25 devices; in-wall mains wiring in scope): Zigbee via Zigbee2MQTT. Buy: SMLIGHT SLZB-06 coordinator (Ethernet, placed centrally), Inovelli Blue Series 2-1 wall switches/dimmers, ThirdReality Gen2 power-metering plugs, Athom ESPHome plugs for special cases. Optional for mission-critical circuits: Lutron Caséta; Shelly Gen3/4 behind-wall relays.
- **DIY capability**: owner is comfortable soldering and building small circuits given good instructions — ESPHome/DIY boards and retrofits (ratgdo etc.) are viable options.

## Future roadmap (explicitly deferred, do not forget)

- **Local voice assistant with local LLM — PRIMARY future target**: this is the reason for choosing strong mini-PC hardware (Ryzen AI NPU/iGPU, 32GB+). Privacy-preserving pipeline fully on-box: wake word + STT + local LLM intent handling; mic-array hardware near the panel TBD. HA's Assist voice pipeline keeps this door open. Size hardware for concurrent hub + restreaming + LLM.
- **NVR + AI detection**: Frigate on the same box — 24/7 recording, person/package detection, event timeline on the panel. Detector: Hailo-8L M.2 module (per `docs/research/frigate-amd-acceleration.md`); iGPU handles VAAPI decode; storage ≈ bitrate-Mbps × 10.8 GB/day/camera. Phase-1 go2rtc restream layer was chosen so this slots in without rework.
- **More panels**: additional rooms get cheap thin clients running the Flutter Web build served from the box (or flutter-pi devices).
- **Ansible provisioning** (port done 2026-07-30, ahead of the original post-spike plan): `appliance/ansible/` — tested against the `appliance/test/` container (fresh-host converge + idempotence). The mini PC gets provisioned by playbook, not by hand. Bash scripts remain the spike-day path of record until the spike passes; future roles to add: docker + hub stack, tailscale, Frigate, voice pipeline.
- **House plan authoring (grilled + pipeline built 2026-07-30 — see ADR-0004; awaiting the real drawing)**: draw the real house in Sweet Home 3D → `panel/tool/sh3d_to_yaml.py` (stdlib Python) → generated `house.yaml` (rectilinear Room polygons tiling each Floor, explicit Walls — undrawn boundary = open passage) + hand-maintained `devices.yaml` (kinds, positions, future Hub entity ids). The Panel parses the YAML at startup; a converter-generated placeholder resembling the real house ships until the actual drawing lands. Later, from the same drawing: furniture on the Dollhouse. Floor navigation is now built (2026-07-31, floor-drift prototype): the Dollhouse shows at most three Floors — the selected one plus its immediate neighbours tucked into its empty isometric corners — and selecting a neighbour re-centres the stack so the next Floor along slides in, which scales to any number of levels.
- **Appliance-hardening**: revisit Ubuntu Core + Ubuntu Frame (immutable OS, transactional updates) once the system design is frozen.

## Spike plan (decided 2026-07-30)

- **Hardware**: the dev laptop (Lenovo Legion 9 16IRX8 — Intel UHD iGPU/`i915` + NVIDIA RTX 4090 dGPU) + the HDMI touchscreen (mini PC purchase not blocked on this). What transfers to the Strix Point target is the driver-independent half — cage/wlroots, the Flutter GTK embedder, libinput touch, the systemd/PAM boot recipe. The Mesa driver underneath is `i915` here and `radeonsi`/`amdgpu` there, so every GPU-specific result (GL/EGL init, VAAPI, gfx1150 enablement) is re-verified on the mini PC, not assumed.
- **Step zero — hybrid-graphics check**: determine which GPU owns the HDMI port (`drm_info`, `/sys/class/drm`, BIOS MUX setting). If HDMI is dGPU-wired: use a USB-C DP-alt-mode→HDMI adapter (usually iGPU-routed) or switch BIOS to iGPU-only. Pin cage to the iGPU with `WLR_DRM_DEVICES=/dev/dri/by-path/pci-0000:00:02.0-card` (the `i915` card on this laptop) — by PCI path, never `/dev/dri/cardN`, whose numbering is not guaranteed stable across boots. The NVIDIA card must stay out of the kiosk compositor's path.
- **Scope**: full appliance plumbing — touch tests (tap/drag/fling/pinch) PLUS boot-straight-to-app systemd, auto-restart on crash, screen blank/wake (cage + wlopm), cursor hiding, silent boot.
- **Timebox**: 1 day, 3 rungs — cage → Weston kiosk-shell → `GDK_BACKEND=x11` under XWayland. If multi-touch fails on all three, the UI decision flips to the web-kiosk fallback (same substrate, per ADR-0001).
- **Screen power (night blank / wake on touch)**: REQUIRED, mechanism-flexible. Research finding: cage has no wlr-output-power-management, so `wlopm` does not work. Priority order: `wlr-randr --off/--on` trick (spike pass-item 9) → DDC/CI via `ddcutil` (panel-dependent) → compositor swap to sway/labwc → Flutter-side night mode as last resort.
- **Runbook**: `docs/research/flutter-cage-spike.md` — 10-step layer-by-layer procedure (evtest → libinput → cage → Flutter), 13-item pass/fail checklist, 5-rung fallback ladder, verbatim systemd/PAM units, hybrid-GPU Step 0a for the laptop.

## First implementation steps (original plan — superseded, kept for the shape of it)

Live status lives in [`../appliance/COMMISSIONING.md`](../appliance/COMMISSIONING.md) and the
phase plans; what still needs *you* is in [`../TODO.md`](../TODO.md).

1. **Day-one spike (before building the dollhouse UI)**: run Flutter under cage on the actual touchscreen; verify tap, drag, fling inertia, multi-touch. Fallbacks: Weston kiosk-shell → labwc → `GDK_BACKEND=x11` under XWayland → flutter-pi. — *still open (A7); the UI was built ahead of it against the web/macOS targets.*
2. Buy: mini PC (check SO-DIMM + 2×M.2), ratgdo32, SLZB-06, first Inovelli/ThirdReality batch. — *still open (D1–D3, D5).*
3. Flash: Wyze v3/Pan v3 → official RTSP firmware (floodlight applicability UNVERIFIED — test one unit first); Emporia Vue 3 → ESPHome (deferred, D2 in the plan); ratgdo32 → ESPHome. — *still open (E3, B3).*
4. Stand up: Docker stack, Tailscale, cage kiosk service. — **done for HA + Mosquitto + ring-mqtt + go2rtc**; Zigbee2MQTT is parked behind a compose profile until the coordinator exists, Tailscale and the kiosk service are not yet done.
5. Configure: HA long-lived token for the panel; Ecobee via HomeKit-controller (local); second Petlibro account for HA. — **token and local Ecobee done**; Petlibro account is B7. (Samsung TVs dropped from scope 2026-08-03.)

## Original notes (pre-grilling, kept for reference)

- UI Neumorphism links: <https://github.com/mrsaeeddev/awesome-neumorphism>, <https://pub.dev/packages/neumorphic> (Flutter)
- Device fleet: Ring Video Doorbell, multiple Wyze cameras (some floodlight), Ecobee thermostat, smart outlets, Emporia Vue 3 energy monitor, Samsung SmartThings oven + TVs, Whisker Litter-Robot 5 Pro, Petlibro One RFID feeder, Granary Smart Camera Feeder, LG washer/dryer, Chamberlain myQ garage opener with camera, Tesla Wall Connector.
- Hardware on hand: HDMI touchscreen; all devices on the same home network.
