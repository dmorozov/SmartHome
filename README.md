# Smart Home application

This project is to build a Smart Home system: a custom neumorphic "dollhouse" touch panel backed by a headless open-source hub, both on one always-on box. That box is the Ubuntu 26.04 dev laptop today (`192.168.68.81`, ADR-0008); the AMD Ryzen AI mini PC is still unpurchased and blocks nothing.

## TODO — needs you

Everything below needs **the owner specifically**: physical access to a device, a
credential or a payment, or a judgement call about your own house. Anything an agent
could do headlessly is deliberately **not** on this list.

Generated **2026-08-04** from a full audit of the repo plus live re-verification against
the Hub. [`appliance/COMMISSIONING.md`](appliance/COMMISSIONING.md) is the master
runbook; this is only the subset that needs a human. Phase plans live in
[`docs/plans/device-integrations/`](docs/plans/device-integrations/README.md) — not
restated here.

Item IDs (A1, B2, …) are stable handles, not an ordering.

### Do these first

1. **E7** — back up `.storage` + `ring-mqtt-data/` **before** any new pairing exists. Highest value per minute in the list.
2. **A3** — two minutes at the outdoor plug. Unblocks the first real Panel→hardware round-trip.
3. **B2** — Ring 2FA. One login unblocks the whole of phase 3, and it is the only way the Panel's doorbell rule ever meets a real Ring entity.
4. **B4** — HACS GitHub auth. Gates four of the credential items below.
5. **F1** — the drawing. Largest single unlock in the repo, and four other items are queued behind it. Needs a real work session, so start it when you have one.

### At the hardware — physical access

- [ ] **A3 · Which EP40 socket is `_0` and which is `_1`** — stand at the outdoor plug, toggle one child entity, see which socket clicks. *Why you:* nobody has looked. *Time:* 2 min at the plug; ~30 min of rename chain afterwards, agent-doable once you report which is which. *Unblocks:* knowing which physical socket each pin drives. The entities and Keys are already named for their location — `switch.outdoor_outlet_a`/`_b` under Keys `outlet-outdoor-a`/`-b` — so this is now about which is which, not what to call them. → [Ch. 7 §7.8.0 → §7.8.6](appliance/commissioning/07-device-lifecycle.md) — full steps, the worked example of that chapter.
- [ ] **A2 · Get the Rachio's HomeKit setup code off the hardware** — an 8-digit `XXX-XX-XXX` code on the device body, the packaging, or in the Rachio app. *Why you:* it cannot be fetched, derived or reset from the Hub. The `homekit_controller` flow for `Rachio-BFF806` is sitting at step `pair` right now. *Time:* minutes, once the code is in hand. *Unblocks:* WAN-outage-resilient zone control; the cloud entry keeps working regardless. → [Ch. 4 §4.3.3](appliance/commissioning/04-devices-local.md) — steps for the HA side (type it **dashed**; undashed fails silently); *where the code is printed* is UNVERIFIED. If the code is genuinely lost, do **not** factory-reset to recover it — that invalidates the working cloud entry.
- [ ] **A4 · Run the Ecobee outage drill** — pull the Hub host's WAN (or blackhole `ecobee.com`) and prove the *local* entity keeps working while the cloud one goes `unavailable`. *Why you:* it interrupts the household's internet. *Time:* minutes. *Gated on:* **B1** — the drill needs both entries to be conclusive. *Unblocks:* the only proof that `connectivity: local` on the `thermostat` pin is not a lie. → [Ch. 4 §4.2.6, "Verify — the outage drill"](appliance/commissioning/04-devices-local.md) — 5 numbered steps.
- [ ] **A5 · First deliberate Rachio zone test at the sprinkler head** — someone outside, watching water actually run. *Why you:* physical presence, at a time when a running zone is not a problem. *Time:* minutes. **Set E4 first.** *Unblocks:* confidence that the 5 zone switches map to the valves the Rachio app names. → [Ch. 4 §4.3.5](appliance/commissioning/04-devices-local.md) — steps, including the correct attribute key (`Zone number`, capitalised, space-separated).
- [ ] **A1 · Re-commission the Tesla Wall Connector** — the unit at `.52` RSTs every TCP port and still advertises a `PROV_` mDNS record. Unblocking it runs through the Tesla One app against the charger's own AP, possibly a factory reset. *Why you:* physical access to the unit and the breaker, plus a Tesla account session. Nothing on the network side can move it. *Time:* ~15 min if the Quick Start Guide is to hand; a work session if it needs a reset. *Unblocks:* the `ev-charger` Key. Nothing else — phase 2 de-gated on it. → [Ch. 4 §4.4.4 walkthrough → §4.4.5 re-probe → §4.4.6 add to HA](appliance/commissioning/04-devices-local.md) — rewritten 2026-08-04 into a full procedure. **Do §4.4.4 Step 0 first**: confirm from the Deco lease table that `.52` really is the charger before anyone opens a breaker panel.
- [ ] **A6 · Plug the Hub host into Ethernet** — `enp162s0` is `NO-CARRIER`; the Hub is on Wi-Fi. *Why you:* it is a cable. *Time:* minutes. *Unblocks:* the repo's own wired-preferred rule for mDNS and camera streams. Not urgent — a drifted lease now costs one Panel restart, not a re-pairing. → [Ch. 1 §1.2](appliance/commissioning/01-host-and-network.md) — **describes the situation and the reasoning; there is no procedure, because it is a cable.**
- [ ] **A7 · Spike day — Flutter under cage on the real touchscreen** — touchscreen attached, cage launched from a local TTY with `gdm` stopped, 13-item pass/fail battery done hands-on-glass. *Why you:* tap, two-finger, fling and pinch cannot be tested remotely. *Time:* a full work session (timeboxed at 1 day). *Gated on:* **G4** — no toolchain, no bundle to run. *Unblocks:* the entire kiosk track and the go/no-go on native Flutter vs. the web-kiosk fallback (ADR-0001). → [`appliance/README.md` "Spike-day order of operations"](appliance/README.md) → [`docs/research/flutter-cage-spike.md`](docs/research/flutter-cage-spike.md) — 10-step runbook, verbatim systemd/PAM units, 5-rung fallback ladder. **Caveat:** researched against cage 0.1.5 / wlroots 0.17; 26.04 ships 0.2.1 / 0.19. The re-audit is agent work — have it done before you spend the day.

### Accounts, credentials and vendor apps — one laptop-and-phone session

- [ ] **B2 · Authenticate ring-mqtt** — Ring email + password + a live 2FA code at `http://192.168.68.81:55123/`. *Why you:* out-of-band 2FA; cannot be scripted or pre-fetched. *Time:* minutes. *Unblocks:* **the whole of phase 3** — the `doorbell` Key, ding/motion events, and the `ring_doorbell` go2rtc stream. **Revised 2026-08-04:** phase 4's Popup video work no longer waits on this; it was built and tested against a hand-written stand-in. What still does wait is correctness — the rule that decides what a ding *is* has never seen a real Ring entity, and when you authenticate, bind the **`event.*_ding`** entity if this ring-mqtt offers both shapes ([phase-3 §2](docs/plans/device-integrations/phase-3-ring.md) says why the other one can swallow a press). → [Ch. 5 §1.1](appliance/commissioning/05-devices-cloud.md) — steps, plus what to watch in `docker logs -f ring-mqtt`.
- [ ] **B4 · Complete the HACS install's GitHub device-code auth** — a GitHub account and a browser. *Why you:* the device-code step only. The installer itself needs no owner and no sudo. *Time:* minutes. *Unblocks:* **B6, B7, B8** (all HACS-only). → [Ch. 5 §3](appliance/commissioning/05-devices-cloud.md) — steps, plus a warning worth acting on: the installer writes a `hacs/` tree into **tracked** `hub/custom_components/`, so decide gitignore-vs-vendor before the diff exists.
- [ ] **B1 · Add the Ecobee cloud entry** — ecobee.com email + password + a live MFA code. *Why you:* account credentials and a time-boxed code. *Time:* 5–10 min, with the authenticator already open. *Unblocks:* schedules, vacations, a `weather.*` entity, the humidifier/ventilator controls the local HAP profile does not expose — and the control case for **A4**. → [Ch. 4 §4.2.3](appliance/commissioning/04-devices-local.md) — the best-specified credential flow in the repo, including the trap where filling `api_key` *and* username/password fails as a generic `invalid_auth`. The cloud entity lands as `climate.main_floor_2`; that is the lucky ordering, do not "fix" it.
- [ ] **B5 · LG ThinQ Personal Access Token** — created at `connect-pat.lgthinq.com` signed in as the LG account the appliances are registered to. *Time:* ~15 min. *Unblocks:* the `washer` and `dryer` Keys. → [Ch. 5 §4](appliance/commissioning/05-devices-cloud.md) — steps, plus the caveats that matter (PAT lifetime UNVERIFIED — record the issue date; do not build a Panel affordance on remote start).
- [ ] **B6 · Whisker / Litter-Robot account credentials** — the app account's email + password. *Time:* ~15 min. *Needs:* B4. *Unblocks:* the `litter-robot` Key. → [Ch. 5 §5](appliance/commissioning/05-devices-cloud.md) — steps. The LR5 Pro camera is not exposed in HA; do not plan it on the Panel.
- [ ] **B7 · Create a second, dedicated Petlibro account and share the feeders to it** — *Why you:* Petlibro allows one login per account, so signing HA in as the family account logs your phone out. Account work only you can do, and it must happen **before** touching HA. *Time:* ~20 min. *Needs:* B4. *Unblocks:* the `feeder-petlibro` and `feeder-granary` Keys. → [Ch. 5 §6](appliance/commissioning/05-devices-cloud.md) — steps, including the fallback of adding `jjjonesjr33/petlibro` as a custom HACS repository.
- [ ] **B8 · Emporia app account credentials** — the account that owns the Vue 3. *Time:* ~15 min. *Needs:* B4. *Unblocks:* the `energy-monitor` Key — **and it is the only route to any power/energy data in this house**: all three Kasa plugs report `feature: TIM`, no `EMETER`. → [Ch. 5 §7](appliance/commissioning/05-devices-cloud.md) — steps; `magico13/ha-emporia-vue` is not in the HACS default store, add it as a custom repo.
- [ ] **B3 · Identify the five Wyze units, and get the Wyze API key pair** — the Deco app's client list (the only naming source on this LAN) plus the Wyze app's Device Info per unit; the bridge path also needs an API Key ID + API Key from `developer-api-console.wyze.com`. *Why you:* both sources are owner-only apps. *Time:* ~20 min for identification; flashing is a separate session. *Unblocks:* **phase 4's camera half** — its other half, live video in the Popup, is built on both targets, and since **E8** was decided it waits on nothing but a camera to point at, which is this item. Five `D0:3F:27` MACs is not five cameras, and the *model* per unit is what E3 branches on. → [Ch. 5 §2.1 → §2.2 → §2.3](appliance/commissioning/05-devices-cloud.md) — steps, and it corrects two things phase 4 gets wrong. **No RTSP for Cam v4.**
- [ ] **C1 · DHCP reservations by MAC on the Deco, starting with the Hub host** — *Why you:* the Deco XE75Pro is administered from a phone app the repo cannot reach, and it serves **no local DNS**, so a MAC reservation is the only stable addressing available. `192.168.68.81` is still an unreserved lease. *Time:* minutes per device. *Unblocks:* stable addressing for the Hub, every camera in phase 4, the Tesla WC, the SLZB-06 — and it is where each MAC gets a human name, which is the join key for **B3**. Same app session as B3. → [Ch. 1 §1.2](appliance/commissioning/01-host-and-network.md) — **partial:** it tells you how to get the MAC and why the reservation must be MAC-keyed, but the Deco app's menu wording is UNVERIFIED. Hygiene, not an emergency.

### At a terminal — needs the sudo password, or the Mac

This host has no passwordless sudo. Each of these is small; an agent session simply cannot finish any of them. Do them in one sitting.

- [ ] **E7 · Back up `hub/ha-config/.storage` and `hub/ring-mqtt-data/`** — *Why you:* the mitigation reads root-owned files, so it needs `sudo`, and the resulting tarball holds cleartext credentials and the Ring refresh token, so where it lives is your call. *Time:* minutes to run, an hour to design something durable. *Unblocks:* protection against the only genuine re-pairing cliff in the system — losing `.storage` means re-entering every credential **and a physical trip to the thermostat's touchscreen**. No backup exists today and **no phase has a backup step**. Do it **before** B1/B2/A2 create more pairings. → [Ch. 2 §8, "The re-pairing cliff"](appliance/commissioning/02-hub-stack.md) — exact `docker compose stop` / `tar` / `start` recipe, honestly labelled as the interim manual mitigation.
- [ ] **G4 · Install the Flutter Linux toolchain on the Hub host** — `clang`, `cmake`, `ninja-build`, `libgtk-3-dev`, `liblzma-dev` are all missing; `flutter build linux` has never run on this box. *Time:* minutes, then one proof build. *Unblocks:* any real Panel bundle at all — which gates **A7** and `kiosk_app` — **and, since 2026-08-04, phase 4's video on the wall.** This item said the opposite twice and was wrong both times. It first claimed to gate video, was corrected to "not phase 4's video: playback is web-only by decision", and that correction died with the decision that the appliance is the primary target and must play. The appliance now has a real MJPEG player; it is exercised by the suite and has been driven against the live go2rtc from this host, but **`flutter build linux` has never run here, so no frame of it has ever been rendered inside the cage kiosk**. Until this item is done, "the wall plays video" is an argument, not an observation. → [phase-0 open item 14](docs/plans/device-integrations/phase-0-laptop-bring-up.md) + [Ch. 1 §1.7](appliance/commissioning/01-host-and-network.md) — **names the packages and the gap; there is no single clean step list.** The converge is the intended route and it needs `liblzma-dev` added to `flutter_toolchain_packages` first.
- [ ] **G1 · `apt-mark manual linux-generic-hwe-26.04`** — *Why it matters:* `apt-mark showauto` still lists it, and its only parent is a removable transitional shim, so one `apt autoremove` can orphan the running kernel stack. *Time:* minutes. Cheapest route is one gated `ansible-playbook … --ask-become-pass` converge — the kiosk role now claims it. → [Ch. 1 §1.5, "Two things it does not do"](appliance/commissioning/01-host-and-network.md).
- [ ] **G2 · Push the Mac's SSH public key to the Hub host** — `ssh-copy-id`, run **from the Mac**, a machine no agent session here can reach. `~/.ssh/authorized_keys` is 0 bytes. *Time:* minutes. Nothing is broken — password auth works — but every Ansible converge prompts. → [Ch. 1 §1.3](appliance/commissioning/01-host-and-network.md) — one line.
- [ ] **G3 · Move the three broker passwords into a password store** — `hub/.broker-passwords.env` (0600, gitignored) still holds all three in cleartext; the repo says outright it exists only to make this bring-up reproducible. *Why you:* it is your password manager. *Time:* minutes. → [Ch. 2 §8 secrets inventory](appliance/commissioning/02-hub-stack.md) — **states the requirement; the destination is yours.**
- [ ] **G5 · Standing: `sudo apt upgrade` the Docker packages deliberately** — `unattended-upgrades` allows Ubuntu origins only, so `download.docker.com` packages never auto-update, and under ADR-0008 the whole Hub *is* Docker. *Time:* minutes, recurring. Not a task — a standing obligation. → [Ch. 1 §1.5](appliance/commissioning/01-host-and-network.md) — the `--only-upgrade` line naming all six packages.

### Decisions only you can take

- [ ] **E1 · GNOME battery auto-suspend — accept the flat battery, or accept the 15-minute outage** — `sleep-inactive-battery-type` is still `'suspend'` at 900 s, so unplugging the laptop kills the whole house's Hub 15 minutes later. Turning it off removes the only thing stopping an unplugged daily-driver laptop draining flat. *Why you:* it is a power setting on your personal machine, not a technical call. *Time:* minutes; execution is one command in your own session. → [Ch. 1 §1.4, "GNOME auto-suspend"](appliance/commissioning/01-host-and-network.md) — the exact `gsettings set`, plus both caveats.
- [ ] **E4 · Rachio's zone-run duration** — *Why you:* this is the knob that decides what a mis-tap costs in water. A zone switch tapped from the Panel runs for that long, then stops; the default is short. **Do it before A5.** *Time:* minutes. → [Ch. 4 §4.3.2, last paragraph](appliance/commissioning/04-devices-local.md) — **names the option and where it lives; the exact UI path is not quoted.**
- [ ] **E5 · `unit_system` — `metric` or `us_customary`** — a genuine household preference; every HA surface in the house follows it. *Time:* minutes. **De-escalated:** this used to be a Panel trap and is not any more — the `83.0 °C`-on-the-wall defect is fixed. Low-stakes preference, not a blocker. → [Ch. 3 §3.1](appliance/commissioning/03-home-assistant.md) for the facts, [§3.5](appliance/commissioning/03-home-assistant.md) for the one-line `hactl` change.
- [ ] **E6 · Should this Hub have Bluetooth at all?** — mounting the host's system D-Bus socket into the HA container is a small but real increase in what that container can see. The honest alternative is to disable the entry and let the Hub stop retrying. *Why you:* a posture decision on your machine — the *execution* of either option needs no owner and no sudo. *Time:* minutes. *Unblocks:* nothing in phases 1–6 needs BLE, and the adapter will not exist on the mini PC. → [Ch. 3 §3.7](appliance/commissioning/03-home-assistant.md) — steps for both options, both UNVERIFIED, neither applied.
- [x] **E8 · go2rtc's `origin: "*"` — DECIDED 2026-08-04: accepted, and landed the same day.** Nothing is left for you here; it is kept on the list because the *reasoning* is the part worth being able to re-read. go2rtc **403s any WebSocket upgrade carrying an `Origin` header** unless `api.origin` says otherwise, and a browser always sends one — so a Panel served from anywhere except `:1984` itself could never open a stream, and what it saw was a bare connection failure with no error frame to explain it. The obvious tighter alternative — name the Panel's exact origin and nothing else — was measured on the same instance and is **broken in 1.9.10**: `api.origin` set to `"http://localhost:8080"` still 403s that very origin. **There is no allowlist**; the choice was `"*"` or no video. *Why it was yours:* it widens what any page in any LAN browser can reach on an **unauthenticated** service — today one synthetic test pattern, after phase 4 every camera in the house. *The reasoning for accepting it:* **access to this system is LAN-only or over the VPN, so the network boundary is the control** (ADR-0008 — one box, no port-forward). The origin check was never what kept strangers off an unauthenticated service; declining `"*"` would have cost the Panel its picture in exchange for a protection that was not there. Revisit when a real camera stream lands, which is when the exposure stops being synthetic — and do **not** "tighten" this to a hostname later without re-measuring: it will look correct and silently break every camera. *Landed:* `api: origin: "*"` in `hub/go2rtc/go2rtc.yaml`, mirrored into the tracked `hub/go2rtc/go2rtc.example.yaml`. Re-measured against the live 1.9.10 daemon (`revision df95ce3`): no `Origin` → `101`, `Origin: http://127.0.0.1:1984` → `101`, `Origin: http://localhost:8080` → **`101`**, where that last one was `403` before. *Unblocked:* the transport half of phase 4 §B, which is now built for both targets — what still gates a picture on the wall is a camera to point at (**B3**/**B2**), not this. → [phase-4 §B0](docs/plans/device-integrations/phase-4-cameras.md) — the block, its security note, and the `curl` that reads the `101` back.
- [ ] **E3 · Wyze fleet flashing scope** — a fleet-wide risk decision on your own hardware: the RTSP firmware lags mainline (no further security updates) and loses some app features. Recommendation is to flash **one** v3 and decide the fleet after it has run for a few days. *Gated on:* B3. *Unblocks:* whether any camera in this house is ever `connectivity: local` — the only genuinely local outcome available in phase 4/5. → [plan D-log D1](docs/plans/device-integrations/README.md) + [Ch. 5 §2.2](appliance/commissioning/05-devices-cloud.md) — steps for the experiment; the decision gate is stated explicitly.
- [ ] **E2 · The SmartThings oven — decide before October 2026** — a recurring $4.99/mo subscription against a dated deadline, plus a Samsung account OAuth login if it goes ahead. *Time:* minutes to decide. *Unblocks:* the `oven` Key. If it goes the other way, the honest end state is the `entity:` line removed and an unknown-state pin. Worth knowing first: what you get is *monitoring plus a Stop button*, not remote cooking control. → [Ch. 5 §8](appliance/commissioning/05-devices-cloud.md) + [research §3.5](docs/research/hub-and-device-integrations.md) — **decision support, deliberately not steps** ("Do not build this").

### Purchases

- [ ] **D2 · SMLIGHT SLZB-06 Zigbee coordinator, Ethernet mode** — *Why you:* money. ADR-0003 pins the product. *Unblocks:* Zigbee2MQTT, and therefore all of **D3**. → [Ch. 2 §7](appliance/commissioning/02-hub-stack.md) — steps for the bring-up once the hardware exists (copy the example config, set IP + port 6638, `docker compose --profile zigbee up -d`, then pin the exact image tag).
- [ ] **D1 · ratgdo32 board for the myQ garage opener** — *Why you:* money, plus a compatibility check only you can make: read the learn-button colour on the physical opener (Security+ 2.0 = yellow; 1.0 has a wall-panel caveat) **before ordering**. Chamberlain's third-party API shutdown is permanent and HA dropped the integration in 2023.12 — **there is no software-side move at all.** *Effort:* a purchase, then 3 wires into the wall-control terminals + an ESPHome flash. *Unblocks:* the `garage-door` Key, the only Key in the house that is togglable and has no hardware. → [research §3.11](docs/research/hub-and-device-integrations.md) — **covers the product decision thoroughly (ratgdo32 ≈ $45, Konnected blaQ as the alternative) but contains no install procedure; no commissioning chapter covers ratgdo yet.**
- [ ] **D3 · First batch of Zigbee switches/outlets, and the in-wall mains work** — *Why you:* money, and mains wiring inside walls. *Gated on:* D2. *Unblocks:* every `light-*` Key — 13 of the 33 Keys are lights, all currently on dev stand-ins. → [research §4](docs/research/hub-and-device-integrations.md) and "New lighting/outlets" below — **product guidance with citations, not a procedure.**
- [ ] **D5 · The Ryzen AI mini PC** — *Why you:* money, plus criteria only you can check at the point of sale: a free SO-DIMM slot and **2 × M.2** (future RAM for a local LLM, second disk for NVR, Hailo-8L accelerator). *Blocks nothing today* — ADR-0008 puts the Hub on the laptop. Remember it keeps Ubuntu Server **24.04** + HWE, not 26.04. → "Mini-PC" below + [`docs/research/frigate-amd-acceleration.md`](docs/research/frigate-amd-acceleration.md) — **criteria, not steps.**
- [ ] **D4 · Install the two Kasa Wi-Fi wall switches** — in-wall mains work: breaker off, verify dead, neutral required. *Unblocks:* **nothing.** Worth stating plainly — the plan opened believing phase 2 depended on these; it does not, no Kasa wall switch is on the LAN at all, and phase 2 was rewritten to drop the dependency. → [`appliance/COMMISSIONING.md`](appliance/COMMISSIONING.md), "Things that exist only on the hardware", the Kasa wall-switch row — **it describes the situation and says outright that no chapter covers the install.** There is no procedure to follow.
- [ ] **D6 · (Deferred) Final production touchscreen** — criteria to verify per candidate panel: DDC/CI support (cheap HDMI touchscreens frequently do not implement it — make it a purchase criterion), firmware touch-slot count ≥ 5, USB HID quirks, HDMI-CEC. Not yet due; the spike characterises the screen already on hand. → [`docs/research/flutter-cage-spike.md` §6](docs/research/flutter-cage-spike.md) — **names the criteria; no procedure.**

### Drawing work — Sweet Home 3D, on the Mac

- [ ] **F1 · Draw the real house, and author the Keys it unblocks** — *Why you:* it is your house, and there is **no Linux path** (`panel/tool/sh3d.sh` hard-codes the macOS bundle, and the launcher is mandatory — without it the `Placementkey` field is invisible). Under ADR-0005 a Key is authored in the drawing, never in `bindings.yaml`, and the loader enforces that fatally in both directions. What ships today is generated from a placeholder — "Demo House", 33 Placements. Binding real hardware to placeholder Keys is fine; believing the Key names describe your house is not. *Effort:* a work session, probably several, plus `python3 tool/sh3d_to_yaml.py` and `dart run tool/gen_dev_entities.dart`. → [`panel/HOUSE-PLAN.md`](panel/HOUSE-PLAN.md) — the best start-to-finish document in this repo for a non-programmer, including every error message and what to do about it; [Ch. 6 §6.2](appliance/commissioning/06-panel-and-bindings.md) for the exact command sequence.
  Four things are queued behind that one session:
  - Kitchen outlet Keys for **"Old fridge"** and **"Aquarium"** — decided 2026-08-04 to bind them normally as outlets, ADR-0006's one-tap-no-confirmation consequence accepted. The kitchen has no outlet Key at all today, so this is drawing work before it is binding work.
  - The outlet arithmetic: 3 `outlet` Keys, 4 live switchable sockets. The EP40's two children take two existing Keys and the two new kitchen Keys cover the fridge and the aquarium, leaving `outlet-master` spare. **Two new Keys, not three.**
  - Camera Keys: three `cam-*` exist against up to five Wyze units. If four or five are worth showing, the extras have nowhere to bind — plan the session, or decide deliberately that two stay off the Panel.
  - A Key for the Ecobee's bridged room sensor — `sensor.family_room_temperature` / `binary_sensor.family_room_occupancy` / battery arrived over the **local** path, unasked-for.
- [ ] **F2 · An irrigation Key for the Rachio — drawing *and* code** — *Why it is separate:* `panel/lib/domain/device_vocabulary.dart` carries 14 `DeviceKind` values and none of them is irrigation, so a Rachio pin is a code change (new `DeviceKind` + `KindSpec` + seed, rippling through the loader, `FakeHub`, the state fold and the dev-entity generator) **and then** a drawing session. Forcing a zone into `outlet` would inherit single-tap togglability (ADR-0006) for something that should not be tapped by accident. *Your half:* the drawing, and the product decision that irrigation belongs on the wall at all. The code half is agent work. *Unblocks:* the 5 loaded Rachio zone switches currently have nowhere to land on the Panel. → [Ch. 4 §4.3.6](appliance/commissioning/04-devices-local.md) + [phase-2 §4c](docs/plans/device-integrations/phase-2-local-quick-wins.md) — **describes the two-part change clearly; there is no step-by-step for the vocabulary edit** beyond the doc comment in `device_vocabulary.dart`, which lists what ripples.

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

- `appliance/` — provisioning for the Appliance (laptop now, mini PC later): Ansible playbooks (`ansible/`), interactive diagnostics (`scripts/`), disposable Docker test host (`test/`)
- `hub/` — the Hub stack: Docker Compose (HA, Mosquitto, Zigbee2MQTT, go2rtc, pinned), HA config, `custom_components/` for future device fixes (volume-mounted — no custom image until system deps demand one)
- `panel/` — the Panel Flutter app: dollhouse UI prototype, `FakeHub` and the real Home Assistant WebSocket client (pick with `HUB=fake|ha` in the environment, or `--dart-define=HUB=fake|ha` — the only route on web), structured `[panel]` logging, and golden tests that render the UI headlessly (runs on web/macOS today; Linux/kiosk validation comes with the spike)
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

- ~~**Before HA 2026.8**: define explicit `turn_on`/WOL actions per Samsung TV~~ — **closed 2026-08-03**: Samsung TVs are out of scope by owner decision, and HA is pinned at `2026.7`, which is the guard. The pending `samsungtv` zeroconf card on the Hub is dismissible clutter, not work.
- **By October 2026**: decide — pay Samsung's $4.99/mo SmartThings API "Personal Plan" or drop the oven integration. → **E2** in [TODO — needs you](#todo--needs-you).
- **Known issue**: HA core #177014 — open Ring live streams can suppress doorbell events; open streams on demand only. **Enforced in the Panel since 2026-08-04**: the Popup opens a stream when it opens and closes it in `dispose()` (which runs even when the route leaves without a pop), nothing holds one in the background, and the Popup a ding opens closes itself after 30 s rather than leaving a session up for nobody.

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

## Development topology (decided 2026-07-30)

- **Primary dev box**: the Intel laptop (Lenovo Legion 9 16IRX8 — i9-13980HX, Intel UHD iGPU, NVIDIA RTX 4090 Laptop dGPU), Ubuntu 26.04 LTS, GNOME for daily work (NVIDIA proprietary driver 595.84 OK for the desktop). One machine does: Flutter UI dev natively (hot reload + Linux release builds), the Docker hub stack (HA, Mosquitto, Zigbee2MQTT, go2rtc) with real host networking + mDNS device discovery, and the cage spike (on the `i915` iGPU, separate TTY or DE stopped).
- **macOS**: optional secondary for UI dev (`flutter run -d macos`); cannot build Linux bundles and Docker-on-macOS breaks multicast/mDNS (kills Ecobee HomeKit-controller pairing and TV discovery) — so the laptop hosts everything stateful. **Exception (2026-07-31)**: `hub/dev/` runs Home Assistant alone on the Mac (arm64 image, same 2026.7 pin) with a generated stand-in fleet, so the Panel's `HubClient` can be developed against real HA protocol traffic without the appliance. Only discovery-dependent integrations need the Linux box.
- **Migration**: the Docker stack moves unchanged from laptop to mini PC when it arrives.

## First implementation steps (original plan — superseded, kept for the shape of it)

Live status lives in [`appliance/COMMISSIONING.md`](appliance/COMMISSIONING.md) and the
phase plans; what still needs *you* is in [TODO — needs you](#todo--needs-you) above.

1. **Day-one spike (before building the dollhouse UI)**: run Flutter under cage on the actual touchscreen; verify tap, drag, fling inertia, multi-touch. Fallbacks: Weston kiosk-shell → labwc → `GDK_BACKEND=x11` under XWayland → flutter-pi. — *still open (A7); the UI was built ahead of it against the web/macOS targets.*
2. Buy: mini PC (check SO-DIMM + 2×M.2), ratgdo32, SLZB-06, first Inovelli/ThirdReality batch. — *still open (D1–D3, D5).*
3. Flash: Wyze v3/Pan v3 → official RTSP firmware (floodlight applicability UNVERIFIED — test one unit first); Emporia Vue 3 → ESPHome (deferred, D2 in the plan); ratgdo32 → ESPHome. — *still open (E3, B3).*
4. Stand up: Docker stack, Tailscale, cage kiosk service. — **done for HA + Mosquitto + ring-mqtt + go2rtc**; Zigbee2MQTT is parked behind a compose profile until the coordinator exists, Tailscale and the kiosk service are not yet done.
5. Configure: HA long-lived token for the panel; Ecobee via HomeKit-controller (local); second Petlibro account for HA. — **token and local Ecobee done**; Petlibro account is B7. (Samsung TVs dropped from scope 2026-08-03.)

## Original notes (pre-grilling, kept for reference)

- UI Neumorphism links: <https://github.com/mrsaeeddev/awesome-neumorphism>, <https://pub.dev/packages/neumorphic> (Flutter)
- Device fleet: Ring Video Doorbell, multiple Wyze cameras (some floodlight), Ecobee thermostat, smart outlets, Emporia Vue 3 energy monitor, Samsung SmartThings oven + TVs, Whisker Litter-Robot 5 Pro, Petlibro One RFID feeder, Granary Smart Camera Feeder, LG washer/dryer, Chamberlain myQ garage opener with camera, Tesla Wall Connector.
- Hardware on hand: HDMI touchscreen; all devices on the same home network.

## Home Assistant (development Hub)

### First time initialization

1. open http://localhost:8123, finish onboarding
2. profile → Security → create a long-lived access token

Onboarding: https://www.home-assistant.io/getting-started/onboarding/

The token lives in `hub/dev/token` (gitignored) — **never in a tracked
file**. The Panel reads it from there at build time; see
[`hub/dev/README.md`](hub/dev/README.md).

### Documentation

Website: https://www.home-assistant.io/
Documentation: https://www.home-assistant.io/installation/
Live demo: https://demo.home-assistant.io/#/lovelace/home

### Create a house

0. Install Seet Home 3D

You can use free version or install from the App Store (OSX):

```bash
brew install --cask sweet-home3d
```

