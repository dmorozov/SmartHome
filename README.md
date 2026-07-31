# Smart Home application

This project is to build a Smart Home system: a custom neumorphic "dollhouse" touch panel backed by a headless open-source hub, both running on one always-on AMD Ryzen AI mini PC.

## Architecture (decided 2026-07-30)

Full reasoning with citations: [`docs/research/`](docs/research/) · Decision records: [`docs/adr/`](docs/adr/)

| Layer | Decision |
|---|---|
| OS | Ubuntu Server 24.04 LTS + HWE kernel (no desktop environment) |
| Display | boot → systemd → `cage` Wayland kiosk → full-screen panel app |
| Panel UI | Native Flutter (≥ 3.44 stable, GTK embedder), neumorphism, 2.5D isometric dollhouse |
| Hub | Home Assistant **Container** (Docker), headless — panel talks to its WebSocket API (10-yr long-lived token) |
| Device buses | Zigbee2MQTT + Mosquitto (MQTT), SMLIGHT SLZB-06 Ethernet coordinator |
| Video | go2rtc (+ ring-mqtt, wyze-bridge as needed); Wyze v3-class flashed to official RTSP firmware |
| Remote access | Tailscale/WireGuard VPN only; nothing internet-exposed; phones use the HA Companion app |

**Rejected** (see ADR-0001): Fuchsia OS (Workstation discontinued, no AMD GPU driver, Flutter tooling deleted from SDK), ChromeOS/Flex (no unattended background services; paid kiosk enrollment), Android-x86/Bliss, webOS OSE. openHAB/OpenRemote/ioBroker rejected as hub (ADR-0002). Matter-over-Thread rejected for mainline device purchases in 2026 (ADR-0003).

## Repository layout

- `appliance/` — provisioning for the Appliance (laptop now, mini PC later): Ansible playbooks (`ansible/`), interactive diagnostics (`scripts/`), disposable Docker test host (`test/`)
- `hub/` — the Hub stack: Docker Compose (HA, Mosquitto, Zigbee2MQTT, go2rtc, pinned), HA config, `custom_components/` for future device fixes (volume-mounted — no custom image until system deps demand one)
- `panel/` — the Panel Flutter app: dollhouse UI prototype + `FakeHub` (runs on web/macOS today; real HA client and Linux/kiosk validation come with the spike)
- `spike/` — the Flutter-under-cage validation app + bootstrap script; runbook in `docs/research/flutter-cage-spike.md`
- `docs/` — research (cited), ADRs, agent docs; `CONTEXT.md` — domain glossary

## Decisions (grilling session 2026-07-30)

- **Goal**: a reliable working smart home — boring, proven base; creative effort goes into the custom UI.
- **Local vs cloud**: local-first for all NEW device purchases; existing cloud devices accepted as cloud-integrated.
- **Hub choice**: device coverage + custom-frontend API quality win over implementation language (Java preferred only as tiebreaker; hub is treated as a headless black-box appliance). → **Home Assistant Container**.
- **UI surfaces**: custom dollhouse UI targets the single wall touchscreen only; family phones use the hub's stock mobile app (HA Companion) over VPN.
- **Panel count**: one panel now, likely more later — the same Flutter codebase can compile to Flutter Web later to serve additional thin-client panels.
- **Dollhouse rendering**: 2.5D isometric stacked floors (one per level, tap to expand, rooms glow with light state, device icons pinned per room) — not a true 3D model.
- **Automations**: authored and executed in the hub's native engine; the panel is a pure view/command layer.
- **Video, phase 1**: tap-to-open live popup only (doorbell ring pops up Ring video; tap a camera in the dollhouse to view). No recording.
- **Garage (myQ)**: hardware retrofit approved — ratgdo board wired to the opener for fully local control/status (myQ third-party API is dead). Verify opener model compatibility before ordering.
- **Mini-PC**: Ryzen AI, 32GB RAM; REQUIRE a free SO-DIMM slot and 2 × M.2 slots (future: RAM for LLM, second disk for NVR, Hailo-8L accelerator — the Ryzen NPU is NOT a viable Frigate path per research).
- **New lighting/outlets** (~10–25 devices; in-wall mains wiring in scope): Zigbee via Zigbee2MQTT. Buy: SMLIGHT SLZB-06 coordinator (Ethernet, placed centrally), Inovelli Blue Series 2-1 wall switches/dimmers, ThirdReality Gen2 power-metering plugs, Athom ESPHome plugs for special cases. Optional for mission-critical circuits: Lutron Caséta; Shelly Gen3/4 behind-wall relays.
- **DIY capability**: owner is comfortable soldering and building small circuits given good instructions — ESPHome/DIY boards and retrofits (ratgdo etc.) are viable options.

## Calendar items (from research — dated risks)

- **Before HA 2026.8**: define explicit `turn_on`/WOL actions per Samsung TV (implicit Wake-on-LAN removal in `samsungtv`).
- **By October 2026**: decide — pay Samsung's $4.99/mo SmartThings API "Personal Plan" or drop the oven integration.
- **Known issue**: HA core #177014 — open Ring live streams can suppress doorbell events; open streams on demand only.

## Future roadmap (explicitly deferred, do not forget)

- **Local voice assistant with local LLM — PRIMARY future target**: this is the reason for choosing strong mini-PC hardware (Ryzen AI NPU/iGPU, 32GB+). Privacy-preserving pipeline fully on-box: wake word + STT + local LLM intent handling; mic-array hardware near the panel TBD. HA's Assist voice pipeline keeps this door open. Size hardware for concurrent hub + restreaming + LLM.
- **NVR + AI detection**: Frigate on the same box — 24/7 recording, person/package detection, event timeline on the panel. Detector: Hailo-8L M.2 module (per `docs/research/frigate-amd-acceleration.md`); iGPU handles VAAPI decode; storage ≈ bitrate-Mbps × 10.8 GB/day/camera. Phase-1 go2rtc restream layer was chosen so this slots in without rework.
- **More panels**: additional rooms get cheap thin clients running the Flutter Web build served from the box (or flutter-pi devices).
- **Ansible provisioning** (port done 2026-07-30, ahead of the original post-spike plan): `appliance/ansible/` — tested against the `appliance/test/` container (fresh-host converge + idempotence). The mini PC gets provisioned by playbook, not by hand. Bash scripts remain the spike-day path of record until the spike passes; future roles to add: docker + hub stack, tailscale, Frigate, voice pipeline.
- **House plan authoring (grilled + pipeline built 2026-07-30 — see ADR-0004; awaiting the real drawing)**: draw the real house in Sweet Home 3D → `panel/tool/sh3d_to_yaml.py` (stdlib Python) → generated `house.yaml` (rectilinear Room polygons tiling each Floor, explicit Walls — undrawn boundary = open passage) + hand-maintained `devices.yaml` (kinds, positions, future Hub entity ids). The Panel parses the YAML at startup; a converter-generated placeholder resembling the real house ships until the actual drawing lands. Later, from the same drawing: furniture on the Dollhouse; also deferred: zoom/scroll Floor navigation once floor count grows past two.
- **Appliance-hardening**: revisit Ubuntu Core + Ubuntu Frame (immutable OS, transactional updates) once the system design is frozen.

## Spike plan (decided 2026-07-30)

- **Hardware**: the AMD-CPU laptop (Radeon iGPU + NVIDIA dGPU) + the HDMI touchscreen (mini PC purchase not blocked on this; the iGPU's Mesa/`amdgpu` driver path transfers to the Strix Point target).
- **Step zero — hybrid-graphics check**: determine which GPU owns the HDMI port (`drm_info`, `/sys/class/drm`, BIOS MUX setting). If HDMI is dGPU-wired: use a USB-C DP-alt-mode→HDMI adapter (usually iGPU-routed) or switch BIOS to iGPU-only. Pin cage to the iGPU with `WLR_DRM_DEVICES=/dev/dri/card<iGPU>` — the NVIDIA card must stay out of the kiosk compositor's path.
- **Scope**: full appliance plumbing — touch tests (tap/drag/fling/pinch) PLUS boot-straight-to-app systemd, auto-restart on crash, screen blank/wake (cage + wlopm), cursor hiding, silent boot.
- **Timebox**: 1 day, 3 rungs — cage → Weston kiosk-shell → `GDK_BACKEND=x11` under XWayland. If multi-touch fails on all three, the UI decision flips to the web-kiosk fallback (same substrate, per ADR-0001).
- **Screen power (night blank / wake on touch)**: REQUIRED, mechanism-flexible. Research finding: cage has no wlr-output-power-management, so `wlopm` does not work. Priority order: `wlr-randr --off/--on` trick (spike pass-item 9) → DDC/CI via `ddcutil` (panel-dependent) → compositor swap to sway/labwc → Flutter-side night mode as last resort.
- **Runbook**: `docs/research/flutter-cage-spike.md` — 10-step layer-by-layer procedure (evtest → libinput → cage → Flutter), 13-item pass/fail checklist, 5-rung fallback ladder, verbatim systemd/PAM units, hybrid-GPU Step 0a for the laptop.

## Development topology (decided 2026-07-30)

- **Primary dev box**: the AMD laptop, fresh Ubuntu 24.04 LTS + HWE kernel, GNOME for daily work (NVIDIA proprietary driver OK for the desktop). One machine does: Flutter UI dev natively (hot reload + Linux release builds), the Docker hub stack (HA, Mosquitto, Zigbee2MQTT, go2rtc) with real host networking + mDNS device discovery, and the cage spike (on the iGPU, separate TTY or DE stopped).
- **macOS**: optional secondary for UI dev (`flutter run -d macos`); cannot build Linux bundles and Docker-on-macOS breaks multicast/mDNS (kills Ecobee HomeKit-controller pairing and TV discovery) — so the laptop hosts everything stateful.
- **Migration**: the Docker stack moves unchanged from laptop to mini PC when it arrives.

## First implementation steps

1. **Day-one spike (before building the dollhouse UI)**: run the Flutter counter app under cage on the actual touchscreen; verify tap, drag, fling inertia, multi-touch. Fallbacks if it fails: Weston kiosk-shell → labwc → `GDK_BACKEND=x11` under XWayland → flutter-pi.
2. Buy: mini PC (check SO-DIMM + 2×M.2), ratgdo32, SLZB-06, first Inovelli/ThirdReality batch.
3. Flash: Wyze v3/Pan v3 → official RTSP firmware (floodlight-bundle applicability UNVERIFIED — test one unit first); Emporia Vue 3 → ESPHome (back up stock firmware first); ratgdo32 → ESPHome.
4. Stand up: Docker stack (HA, Mosquitto, Zigbee2MQTT, go2rtc), Tailscale, cage kiosk service.
5. Configure: HA long-lived token for the panel; Ecobee via HomeKit-controller (local); second Petlibro account for HA; Samsung TVs wired + same subnet.

## Original notes (pre-grilling, kept for reference)

- UI Neumorphism links: <https://github.com/mrsaeeddev/awesome-neumorphism>, <https://pub.dev/packages/neumorphic> (Flutter)
- Device fleet: Ring Video Doorbell, multiple Wyze cameras (some floodlight), Ecobee thermostat, smart outlets, Emporia Vue 3 energy monitor, Samsung SmartThings oven + TVs, Whisker Litter-Robot 5 Pro, Petlibro One RFID feeder, Granary Smart Camera Feeder, LG washer/dryer, Chamberlain myQ garage opener with camera, Tesla Wall Connector.
- Hardware on hand: HDMI touchscreen; all devices on the same home network.
