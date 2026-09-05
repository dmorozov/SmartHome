# Smart Home application

A Smart Home system: a custom neumorphic "dollhouse" touch panel — a 2.5D isometric model of the real house on a wall touchscreen, rooms glowing with light state, devices live under your finger — backed by a headless open-source hub (Home Assistant), both on one always-on box. The target box is an AMD Ryzen AI mini PC, not yet purchased; an interim host runs the real house meanwhile ([ADR-0008](docs/adr/0008-device-integrations-on-a-linux-host-never-macos.md)), and nothing is blocked on the purchase.

## Start here

| I want to… | Go to |
|---|---|
| Set up the development environment | [`.devcontainer/README.md`](.devcontainer/README.md) — open the repo in a devcontainer, that is the whole setup ([ADR-0009](docs/adr/0009-development-in-the-devcontainer-on-the-target-os.md)) |
| Do the first-time configuration | The manual credential steps (HA onboarding, Panel token, MQTT, Ring, `gh auth`) are printed by `post-create.sh` on container create, and documented durably in [`hub/dev/README.md`](hub/dev/README.md) |
| Build the Panel | [`panel/README.md`](panel/README.md) — web (`flutter build web`) and the appliance's Linux release bundle (`flutter build linux --release`, in the devcontainer, glibc-safe for the mini PC) |
| Run the Panel | [`panel/README.md` "Talking to the Hub"](panel/README.md#talking-to-the-hub) — the dev loop (`-d web-server --profile` + host browser), FakeHub by default, the dev Hub via dart-defines; daily commands also in [`.devcontainer/README.md`](.devcontainer/README.md) |
| Draw the house / place Devices | [`panel/HOUSE-PLAN.md`](panel/HOUSE-PLAN.md) — start-to-finish, no programming required |
| Package and install for production (mini PC / interim host) | [`appliance/COMMISSIONING.md`](appliance/COMMISSIONING.md) — the master runbook, bare OS → Hub stack → devices → Panel on the wall; provisioning by playbook in [`appliance/ansible/`](appliance/ansible/README.md) |
| See what needs a human | [`TODO.md`](TODO.md) — credentials, hardware, purchases, judgement calls; measured, not guessed |
| Understand the domain language | [`CONTEXT.md`](CONTEXT.md) · decision records in [`docs/adr/`](docs/adr/README.md) |
| Read the plans and history | [`docs/plans/`](docs/plans/device-integrations/README.md) (dated phase records) · [`docs/roadmap.md`](docs/roadmap.md) (standing decisions, future roadmap, the original plan) · [`docs/research/`](docs/research/) (cited surveys) |

## Development environment (decided 2026-08-06 — [ADR-0009](docs/adr/0009-development-in-the-devcontainer-on-the-target-os.md); the 2026-07-30 host/Mac topology is superseded)

- **All development runs in the devcontainer** — open the repo in VS Code, "Reopen in Container", done. [`.devcontainer/README.md`](.devcontainer/README.md) is the guide; the hook scripts are the setup documentation. Inside: Flutter 3.44.8 pinned on **Ubuntu 24.04 — the mini-PC target OS, deliberately not the host's 26.04** (which sits outside Flutter's supported 20.04–24.04 range) — full web + Linux toolchains, and the dev Hub stack (`hub/dev/`) up automatically as sibling containers on shifted host ports. Appliance bundles built in it are glibc-guaranteed to run on the mini PC; the goldens are baked in it and canonical there; it works the same on any machine with Docker, Apple silicon included.
- **The laptop keeps its non-development roles**: interim production Hub host (ADR-0008 — `hub/compose.yaml`, host networking, mDNS; the canonical ports on this machine are the real house's), and the physical half of spike day (cage on the `i915` iGPU, the touchscreen). Both are appliance concerns, documented in `appliance/`.
- **Migration**: the production Docker stack moves unchanged from laptop to mini PC when it arrives.

## Architecture (decided 2026-07-30)

Full reasoning with citations: [`docs/research/`](docs/research/) · Decision records: [`docs/adr/`](docs/adr/README.md)

**Setting up the house:** [`panel/HOUSE-PLAN.md`](panel/HOUSE-PLAN.md) — the manual for drawing your floor plan and placing Devices on it. No programming required.

| Layer | Decision |
|---|---|
| OS | Mini PC (target): Ubuntu Server 24.04 LTS + HWE kernel, no desktop. Hub host today: the dev laptop on Ubuntu 26.04 with GNOME (ADR-0008) |
| Display | boot → systemd → `cage` Wayland kiosk → full-screen panel app |
| Panel UI | Native Flutter (≥ 3.44 stable, GTK embedder), neumorphism, 2.5D isometric dollhouse |
| Hub | Home Assistant **Container** (Docker), headless — panel talks to its WebSocket API (10-yr long-lived token) |
| Device buses | Zigbee2MQTT + Mosquitto (MQTT), SMLIGHT SLZB-06 Ethernet coordinator |
| Video | go2rtc (+ ring-mqtt, wyze-bridge as needed); Wyze v3-class flashed to official RTSP firmware |
| Remote access | Tailscale/WireGuard VPN only; nothing internet-exposed; phones use the HA Companion app |

**Rejected** (see ADR-0001): Fuchsia OS (Workstation discontinued, no AMD GPU driver, Flutter tooling deleted from SDK), ChromeOS/Flex (no unattended background services; paid kiosk enrollment), Android-x86/Bliss, webOS OSE. openHAB/OpenRemote/ioBroker rejected as hub (ADR-0002). Matter-over-Thread rejected for mainline device purchases in 2026 (ADR-0003).

## Repository layout

- `.devcontainer/` — the development environment (ADR-0009): pinned toolchain on the mini-PC target OS + the dev Hub stack as sibling containers; its `README.md` is the how-to
- `appliance/` — provisioning for the Appliance (laptop now, mini PC later): Ansible playbooks (`ansible/`), interactive diagnostics (`scripts/`), disposable Docker test host (`test/`)
- `hub/` — the Hub stack: Docker Compose (HA, Mosquitto, Zigbee2MQTT, go2rtc, pinned), HA config, `custom_components/` for future device fixes (volume-mounted — no custom image until system deps demand one)
- `panel/` — the Panel Flutter app: dollhouse UI prototype, `FakeHub` and the real Home Assistant WebSocket client (pick with `HUB=fake|ha` in the environment, or `--dart-define=HUB=fake|ha` — the only route on web), structured `[panel]` logging, and golden tests that render the UI headlessly (baked and verified in the devcontainer, the canonical golden host; kiosk validation comes with the spike)
- `spike/` — the Flutter-under-cage validation app + bootstrap script; runbook in `docs/research/flutter-cage-spike.md`
- `docs/` — research (cited), ADRs, agent docs; `CONTEXT.md` — domain glossary

## Video streaming

RTSP is the shipped transport, with MJPEG kept as a first-class production
rollback rather than a deprecation. Which one runs resolves environment first,
then the build define, then `rtsp` — and the boot line names the winner every
start (`panel.video_transport transport=…`), so a wall playing the wrong player
is one journald line away from diagnosis.

On the appliance the switches are Ansible vars, never hand-edits. A `-e`
extra-var lasts exactly the converge it is passed to; a setting that has to
hold goes in `host_vars/<box>.yml`, which is where ADR-0014 puts every per-box
value:

- Roll back to MJPEG for one converge: `ansible-playbook site.yml -l <box> -e panel_video_transport=mjpeg`.
  A rollback that has to hold is `panel_video_transport: mjpeg` in that box's
  `host_vars` — otherwise the next plain converge re-templates the unit
  without the line and, wherever the kiosk is enabled, restarts cage back onto
  RTSP.
- Back to RTSP: remove the var (from `host_vars` if it was written there) and
  re-converge. Empty emits no `Environment=` line at all, so the Panel keeps
  its own default.

Never `systemctl edit`. The kiosk role writes `cage@.service` and nothing
else, so a drop-in is *not* reverted by a converge: it survives every one and,
because drop-ins parse after the unit file and the later `Environment=` wins,
silently overrides whatever the var says.

The web build does not consult the transport setting: a browser's transport is
MSE, full stop, and it has no process environment to read one from anyway.

**How the RTSP player is tuned** is a separate question from which transport
runs, and the two are worth keeping apart. Four settings ride one value
(`RtspTuning`), of which exactly two are properties of the machine: which
decoders fvp may use, and whether a playing stream forces the engine to redraw.
Both ship at values chosen deliberately — software decode, and the frame pulse
**off** since 2026-09-04 — and both are graded by a person watching the wall at
commissioning rather than detected by the Panel. That is
[ADR-0014](docs/adr/0014-video-settings-are-set-by-a-person-not-detected.md),
and the procedure is commissioning 6 §6.10.

Two consequences worth carrying:

1. **The MJPEG wrapper producers in the live go2rtc config are load-bearing
   fallback, not dead lines.** Retiring them is off the table while both
   transports stay first-class. The Hub-side saving RTSP has over them
   (52 % → 35 % CPU, 573 → 117 MiB) materialises whenever RTSP is the active
   transport, because the transcodes only run while an MJPEG consumer is
   attached.
2. **Inbound doorbell audio is RTSP-only.** A rollback to MJPEG trades it away
   ([ADR-0011](docs/adr/0011-ring-two-way-audio-via-go2rtc-half-duplex.md)),
   which is the one cost of the rollback that is not obvious from the picture.

The full record — the transport decision, the macroblock fault that turned out
to be `lowLatency` rather than the decoder, and the measurements behind every
default — is in
[`docs/plans/device-integrations/phase-8-handoff.md`](docs/plans/device-integrations/phase-8-handoff.md).
