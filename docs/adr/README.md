# Decision records

The decisions this project is built on, and the reasoning that would otherwise have to be reconstructed. Each one states what was chosen, what was rejected, and why — so a future change can disagree deliberately rather than by accident.

| # | Decision | In one line |
|---|---|---|
| [0001](0001-plain-linux-kiosk-not-fuchsia-or-chromeos.md) | Plain Linux kiosk | The appliance is ordinary Linux running one full-screen app, not a smart-display OS |
| [0002](0002-home-assistant-headless-hub.md) | Home Assistant as a headless Hub | The Hub is a black box the Panel talks to; the Panel is a pure view and command layer |
| [0003](0003-zigbee-z2m-not-matter-thread.md) | Zigbee via Zigbee2MQTT | Not Matter/Thread, for reasons that were true in 2026 and are worth re-checking later |
| [0004](0004-house-plan-sweet-home-3d-yaml-pipeline.md) | House Plan drawn in Sweet Home 3D | Geometry is drawn, converted to YAML, and never hand-edited; metres, one origin, right angles only |
| [0005](0005-devices-authored-in-the-drawing.md) | Devices are authored in the drawing | Supersedes one clause of 0004: Devices are markers in the plan, positions and Rooms computed |
| [0006](0006-togglability-is-decided-by-the-house.md) | Togglability is a House-side fact | Whether a tap flips a Device follows from its kind, never from live state — this is what protects the HVAC |
| [0007](0007-the-panel-recovers-alone-and-says-when-it-cannot.md) | Recover alone; say so when you can't | Reconnect forever with backoff, but a rejected token is terminal and names the action a human must take |
| [0008](0008-device-integrations-on-a-linux-host-never-macos.md) | Integrations on a Linux host, never macOS | Docker-on-Mac can't do multicast in any form; the Hub runs on the laptop now, the mini PC later |
| [0009](0009-development-in-the-devcontainer-on-the-target-os.md) | Development in the devcontainer, on the target OS | Dev and tests run in a pinned Ubuntu 24.04 container — the mini PC's OS, not the host's; native host and Mac dev stopped being documented flows |
| [0010](0010-secrets-consolidated-outside-the-repo.md) | Secrets consolidated under ~/.sh_keys | Every credential our own stack owns the path for moved outside the repo tree; HA's internal `.storage` is the one deliberate exception |
| [0011](0011-ring-two-way-audio-via-go2rtc-half-duplex.md) | Ring two-way audio via go2rtc, half-duplex | Talkback uses go2rtc's native `ring:` source as shipped — two HTTP POSTs, no bespoke service; echo handled by muting playback while the button is held, AEC underneath |
| [0012](0012-panel-renders-with-skia-on-linux.md) | The Linux Panel renders with Skia | Impeller (the Flutter 3.47 Linux default) leaves the five-texture camera wall born dead; the runner pins Skia, the design is unchanged, re-test before any SDK upgrade |
| [0013](0013-the-popup-is-a-managed-feed.md) | The Popup is a managed feed | The Popup's live view is the Stream Director's third role, declared by traits; its dials are health-blind by intent, its clocks are a decorator, and the ding arbitration stays its own |
| [0014](0014-video-settings-are-set-by-a-person-not-detected.md) | Video settings are set by a person | Per-machine video tuning is graded by eye at commissioning and delivered as `Environment=` lines; the Panel never inspects the box to configure itself, and a capability probe would have been wrong about the one fault we had |

## Related reference material

- **[../sweet-home-3d-behaviour.md](../sweet-home-3d-behaviour.md)** — measured facts about Sweet Home 3D's file format and extension points that the pipeline depends on. Undocumented upstream; re-deriving any of it costs an afternoon.
- **[../research/](../research/)** — the surveys behind 0001–0003.
- **[../research/ffmpeg-ring-opus-corruption.md](../research/ffmpeg-ring-opus-corruption.md)** — why the doorbell's inbound audio must be consumed with GStreamer, what that is measured on, and why the cause 0011 originally named was withdrawn. Read before filing anything upstream.
- **[../../panel/HOUSE-PLAN.md](../../panel/HOUSE-PLAN.md)** — the manual for actually drawing the house and placing Devices.

## Writing a new one

Prose, not a template — say what was decided, what it rules out, and what would justify reopening it. Number sequentially. When a later decision supersedes part of an earlier one, edit the earlier ADR to point forward (0004 → 0005 is the worked example) rather than leaving a reader to discover the contradiction.
