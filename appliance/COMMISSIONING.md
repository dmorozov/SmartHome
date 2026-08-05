# Commissioning the SmartHome appliance

The end-to-end procedure for standing up the whole system on a fresh box: bare
OS → Hub stack → Home Assistant → real devices → pins on the Panel — and then
keeping it true as the house changes. **Seven chapters** under
[`commissioning/`](commissioning/), plus
[`commissioning/hactl`](commissioning/hactl), the single WebSocket driver every
chapter calls, plus this spine.

**Read this page first for three things you cannot get from the chapters:** what
is already done versus what is merely written down, the single list of things
the operator has to go and obtain, and the traps that cost someone a day.

---

## AS-BUILT vs INSTRUCTIONS — the distinction that burns people

This repo mixes a record of a machine that exists with a plan for machines that
do not. Both are written in the imperative. Assume every chapter is one or the
other and you will be wrong about half of it, so the split is stated per
chapter, and again inside them.

| Kind | Means | How it reads |
|---|---|---|
| **AS-BUILT** | Executed on the Hub host and measured. Commands were run; outputs are quoted from the run | Numbers, container tags, entity ids, log lines |
| **INSTRUCTIONS** | Not done here. Correct as far as it goes, verified against source or vendor docs where possible | Placeholders, `<angle brackets>`, explicit UNVERIFIED marks |

Anything the author could not verify says **UNVERIFIED** in those words. That
includes every web-UI click path: HA's menu wording moves between monthly
releases and the vendor apps are not in this repo at all. Where a value must
come off the operator's own device — a HomeKit setup code, an MFA code, a
Deco client list — the chapter says so instead of inventing a path.

---

## The ordered path

| # | Chapter | Delivers | State |
|---|---|---|---|
| 1 | [01-host-and-network.md](commissioning/01-host-and-network.md) | An SSH-reachable Linux box that survives a closed lid, with Docker on a live apt source and the repo checked out. No container yet | **AS-BUILT** |
| 2 | [02-hub-stack.md](commissioning/02-hub-stack.md) | `hub/compose.yaml` up: HA, Mosquitto (auth on), ring-mqtt, go2rtc; Zigbee parked. Nothing onboarded | **AS-BUILT** |
| 3 | [03-home-assistant.md](commissioning/03-home-assistant.md) | Owner account, the long-lived token in `hub/token`, the MQTT integration — then the headless REST/WebSocket path everything after this uses | **AS-BUILT**, except the headless onboarding and MQTT-flow variants (marked) |
| 4 | [04-devices-local.md](commissioning/04-devices-local.md) | Kasa ×3, Ecobee, Rachio, and the Tesla Wall Connector recorded as blocked rather than pretended into existence | **AS-BUILT** for the Kasa fleet, the Ecobee's local pairing, the Rachio's cloud entry and the Tesla-blocked finding. **INSTRUCTIONS** for the two halves still open — the Rachio's local HomeKit pairing (§4.3.3) and the ecobee cloud entry (§4.2.3). The chapter's own status table is §4.0 |
| 5 | [05-devices-cloud.md](commissioning/05-devices-cloud.md) | Ring, Wyze, HACS, LG, Whisker, Petlibro, Emporia — every vendor-account device | **INSTRUCTIONS.** None of it is set up |
| 6 | [06-panel-and-bindings.md](commissioning/06-panel-and-bindings.md) | The Panel pointed at the real Hub, and each pin bound to a real entity | **INSTRUCTIONS** for the binding work — all 33 bindings still point at dev stand-ins. **§6.9a is AS-BUILT**: the Linux release build ran against this Hub and rendered live video, under Xvfb and against synthetic inputs. Read its caveat table before repeating the claim |
| 7 | [07-device-lifecycle.md](commissioning/07-device-lifecycle.md) | Everything that happens to a device *after* the first time: a fourth plug, a rename, a repurpose, a sale — and the five-step chain from a registry write to a green `flutter test` | **INSTRUCTIONS**, built on **AS-BUILT** measurement. Every id, registry row and API schema was read off this Hub on 2026-08-04; no rename, repurpose or removal has been performed here |

Chapters 3–6 need chapters 1–2 done. Chapters 4 and 5 are independent of each
other and may interleave. Chapter 6 is last of the bring-up only because it is
cheapest when the entity ids already exist — a binding written against a
predicted entity id is the failure mode ADR-0007 exists to prevent.

### Chapter 7 is not step seven

It is the chapter you come back to. The split from chapter 4 is by **when**,
not by device — both cover the same Kasa plugs, from opposite ends of a
device's life:

| You are | Read | Because |
|---|---|---|
| Putting hardware into an **empty** registry for the first time | **4** | Discovery, the two-card trap, pairing codes, and what each integration actually produces |
| Doing anything to hardware **already in** the registry — adding a fourth plug beside three that work, renaming, repurposing, removing | **7** | The `entity_id`-is-frozen rule, the two registry calls that are the only way round it, and the chain that ends at `flutter test` |

Read 7 **before** the vendor-app rename you were about to do, not after.
Its §7.3.1 is the point: the cheapest moment in a device's whole life is the
thirty seconds *before* HA first registers it, and after that every rename is
a five-step chain across two repos. Chapter 7 also supersedes chapter 4 on one
point of fact — the *first* Kasa cannot self-discover (4 §4.1.4), but the
second onwards does, within 15 minutes (7 §7.3.3).

### One tool, not seven scripts

Chapters 3, 4 and 7 all drive Home Assistant headlessly, and they all use the
same two transports with the same split: **config flows are REST, registries are
WebSocket-only**. There is no REST view of the device or entity registry at all,
and `GET /api/config/config_entries/flow` answers **405** — listing *pending*
flows is WebSocket too.

The WebSocket half is [`commissioning/hactl`](commissioning/hactl), committed
next to the chapters. **Do not re-derive it and do not write a second one.** It
runs python3 + aiohttp *inside* the `homeassistant` container, because the Hub
host has neither `aiohttp` nor `websockets` and installing either needs sudo
this host does not hand out; the token reaches it through `docker exec -e`, so
it never appears in a command line, in `ps`, or in `docker inspect`. Its
rationale is [3 §3.5](commissioning/03-home-assistant.md).

```sh
cd <repo>/appliance/commissioning
./hactl '[{"type":"config_entries/flow/progress"}]'
```

The one exception is the mDNS/`sf`-flag probe in
[4 §4.2.2](commissioning/04-devices-local.md), which is zeroconf rather than
HA's WebSocket API. It runs in the container too — and **it needs `docker exec
-i`**: without `-i` the heredoc is never delivered, python3 runs an empty
program, and the probe prints nothing and exits **0**, which is
indistinguishable from the finding you were looking for.

---

## What the operator must obtain

The highest-value table on this page. Every credential, code, decision and
hands-on-hardware action the system **still needs**, in one pass. **None of it
can be fetched, derived or reset from this repo**, and roughly half of it is
time-boxed or comes off a screen in another room.

**Already obtained on this Hub, so no longer listed below.** A fresh build
still needs every one of them, and the chapter section is named so you can find
the procedure:

| Obtained | Where the procedure lives |
|---|---|
| Mosquitto passwords for `ha` / `ring` / `z2m` — **URL-safe**, because the `ring` one rides inside `mqtt_url` where `@` or `:` silently breaks parsing | [2 §3c](commissioning/02-hub-stack.md) |
| HA owner account name + password — the identity every long-lived token is minted against, and it migrates to the mini PC with `hub/ha-config` | [3 §3.1](commissioning/03-home-assistant.md) |
| **Rachio API key** — `https://app.rach.io/` → Settings → **"GET API KEY"** (wording quoted from HA's own `rachio/strings.json`). The `rachio` entry is loaded | [4 §4.3.2](commissioning/04-devices-local.md) |
| **Ecobee HomeKit setup code** — 8 digits, `XXX-XX-XXX`, read off the thermostat's touchscreen. Paired locally 2026-08-04 | [4 §4.2.4](commissioning/04-devices-local.md) |

Gather what you can before starting; the rest are marked *live* and must be
done with the flow open.

### Things you invent

| What | Constraint | Needed by |
|---|---|---|
| Wyze RTSP stream user/password | Set in the Wyze app after flashing; nothing external issues it | Ch. 5 |

### Things you fetch from a vendor

| What | Where from | Needed by |
|---|---|---|
| **ecobee.com email + password, then a *live* MFA code** | The ecobee account the thermostat is registered to. This is the Ecobee's **outstanding half** — the local pairing is done, the cloud entry is not. The MFA code is time-boxed: have the authenticator open *before* submitting the password, because a code that expires mid-flow returns `invalid_mfa_code` and you restart the login. Fill in username **and** password and leave `api_key` **empty** — all three filled fails as a generic `invalid_auth` | Ch. 4 (cloud path), [§4.2.3](commissioning/04-devices-local.md) |
| Ring email + password, then a **live 2FA code** | Ring's own 2FA channel for that account. Cannot be scripted or pre-fetched | Ch. 5 |
| Wyze email + password **and** API Key ID + API Key | `https://developer-api-console.wyze.com/#/apikey/view` | Ch. 5 (bridge path) |
| A GitHub account | HACS install completes over GitHub's device-code flow | Ch. 5 |
| LG ThinQ **Personal Access Token** + country | `connect-pat.lgthinq.com`, signed in as the account the appliances are registered to. **Token lifetime is UNVERIFIED** — record the issue date | Ch. 5 |
| Whisker / Litter-Robot app email + password | The app account that owns the robot | Ch. 5 |
| A **second, dedicated** Petlibro account | Create it and share the devices to it. Petlibro allows one login per account — signing HA in as the family account logs the phone out | Ch. 5 |
| Emporia app email + password | The app account that owns the Vue 3 | Ch. 5 |
| Samsung account (browser OAuth) | Only if D3 goes ahead. **$4.99/mo from October 2026**; PATs have been 24-hour since 2024-12-30 | Ch. 5 (not a phase) |

### Things that exist only on the hardware or in an app

| What | Where | Needed by |
|---|---|---|
| **Every device's MAC address**, and Deco-app access to reserve it | The Deco mobile app's client list. The Deco serves **no local DNS** and every PTR lookup fails, so a MAC reservation is the only stable addressing available. The app's exact wording is UNVERIFIED. For a Kasa plug the MAC also comes off the legacy-protocol probe in [7 §7.3.2](commissioning/07-device-lifecycle.md), read-only and stdlib-only | Ch. 1, and again per device |
| **Rachio HomeKit setup code**, 8 digits, `XXX-XX-XXX` | The Rachio's **outstanding half** — the cloud entry is loaded, the local `homekit_controller` card is still open at step `pair` and the bridge still advertises `sf=1`. **Where the code is printed is UNVERIFIED** — device body, packaging, or the Rachio app; read it off the operator's own hardware. Type it **dashed** (trap #3). If genuinely lost, the local path is unavailable until a factory reset — which would also invalidate the cloud entry's view of the controller, so do not reach for it to fix a missing sticker | Ch. 4 (local path), [§4.3.3](commissioning/04-devices-local.md) |
| Ecobee **HomeKit setup code**, same form, **only for a fresh unit** | This Hub's is done. A different thermostat needs HomeKit enabled on its touchscreen first — not obtainable from HA or over the network, exact on-screen path UNVERIFIED, roughly Main Menu → Settings → Apple HomeKit. The screen showing an 8-digit `XXX-XX-XXX` code *is* the confirmation you enabled the right thing | Ch. 4 (local path) |
| Wyze **MAC → model** mapping for the five `D0:3F:27` hosts | Cross-match the Deco client list against the Wyze app's Device Info. "Five Wyze MACs" is not "five cameras" — and the model decides which D1 branch each unit takes | Ch. 5 |
| Wyze camera **firmware level** per unit | The Wyze app. RTSP went to production firmware 2026-02-02 for Cam v3 / Pan v3; whether these units are on it is UNVERIFIED. **No RTSP for Cam v4** | Ch. 5 |
| A **Tesla One / Tesla app** session, and physical access to the Wall Connector | The unit at `.52` is stuck in ESP-IDF provisioning mode. Re-run commissioning, or factory reset per Tesla's Gen-3 documentation (procedure UNVERIFIED here) | Ch. 4 — **blocking** |
| The **Mac**, Sweet Home 3D, and the real `.sh3d` drawing | A new Panel Key is authored in the drawing (ADR-0005) via `panel/tool/sh3d.sh` — the startup launcher is mandatory or the `Placementkey` field is invisible. There is no Linux path. **Three separate things are queued behind this one session**: the Rachio's five zones (no irrigation Key, and no irrigation *kind* either — see Status), kitchen Keys for the fridge and the aquarium, and any Key for the Ecobee's bridged room sensor | Ch. 6, Ch. 7 |
| ~~The **EP40's outlet-to-socket mapping**~~ — **obtained 2026-08-05** | `switch.outdoor_outlet_a` (child `_0`) drives the socket labelled **"Plug 1"**; B is the other one, by elimination. Left in this table as the worked example of what "only on the hardware" means: no probe, registry read or vendor API could have produced it, and it took someone standing at the plug watching a socket. **Beware the off-by-one** — TP-Link labels from 1, HA numbers children from 0, so "Plug 1" is `_0` | Ch. 4 §4.1.5, [7 §7.8.0](commissioning/07-device-lifecycle.md) |
| **Two Kasa Wi-Fi wall switches, installed** | Bought but **not installed** — the in-wall mains work has not happened and no Kasa wall switch is on the LAN at all (measured; [`../docs/plans/device-integrations/README.md`](../docs/plans/device-integrations/README.md)). Nothing in phases 0–6 depends on them; if they go in later that is a new, separate pass and no chapter covers it yet | — (out of phase) |
| An **SMLIGHT SLZB-06** in Ethernet mode | Not purchased. Zigbee2MQTT stays parked behind the `zigbee` compose profile until it exists (ADR-0003) | Ch. 2 §7 |
| The controller's SSH public key | `ssh-copy-id` from the Mac; `~/.ssh/authorized_keys` is empty on the Hub host today | Ch. 1 |

### Decisions already taken — record them, do not re-litigate them

| Decision | Taken | What still follows from it |
|---|---|---|
| **Bind "Old fridge" and "Aquarium" normally**, as ordinary outlets | Owner, 2026-08-04. ADR-0006's one-tap-no-confirmation consequence was put to the owner explicitly and reaffirmed | It does **not** make the work smaller: both need **new Keys**, which is drawing work under ADR-0005, and the kitchen has no outlet Key at all today. [4 §4.1.1](commissioning/04-devices-local.md) and [7 §7.1](commissioning/07-device-lifecycle.md) carry it. See the chapter-disagreement note under Status |
| **The Rachio gets both paths**, cloud *and* local HomeKit — like the Ecobee | Owner, 2026-08-04 | The pending `homekit_controller` card is **work outstanding, not clutter**. Do not dismiss it. Only the cloud entry carries standby, rain delay, schedules and the rain sensor; only the local bridge survives a WAN outage. [4 §4.3](commissioning/04-devices-local.md) |
| **Commission the local path first**, deliberately, wherever a device has two | Recorded from the entity-id race the Ecobee won by luck | Whichever integration registers first takes the clean `climate.main_floor`; the loser gets `_2`, frozen forever. [4 §4.2.5](commissioning/04-devices-local.md) |
| **Rachio's zone-run duration: 5 minutes** | Owner, 2026-08-04. The `rachio` entry's options are now `{"manual_run_mins": 5}` (verified); the integration's own default is `DEFAULT_MANUAL_RUN_MINS = 10` | It governs **one thing only** — toggling a single zone switch on, e.g. from a Panel tap. It does not touch the app's schedule, and the two other ways this house can run water ignore it entirely. Which is which is [4 §4.3](commissioning/04-devices-local.md)'s table; do not infer it from this row |

### Decisions to make deliberately, before they make themselves

| Decision | Why now | Chapter |
|---|---|---|
| GNOME battery auto-suspend | Still `suspend` at 900 s. Unplug the laptop and the house goes dark 15 minutes later. Closing it removes the only thing stopping a flat battery | Ch. 1 |
| `unit_system`: `metric` or `us_customary` | **No longer a Panel trap** — the Panel now reads the Hub's own unit and renders it (trap #10). So this is a genuine house preference again: pick the one the household reads, knowing every other HA surface follows it too | Ch. 3 |
| D1 / D2 / D3 in the plan D-log | Wyze flashing scope, Emporia reflash timing, SmartThings subscription | Ch. 5 |
| A **repeatable** backup step for `hub/ha-config/.storage` and `hub/ring-mqtt-data/` | **No phase 0–6 has one, and that is unchanged.** A one-off encrypted copy was taken 2026-08-04 and is the only copy in existence — it is not on this disk, so nothing here can verify or refresh it, and the next change to the registries makes it stale. Losing both means re-pairing by hand, including a physical re-pair at the thermostat. Chapter 2 §8 gives the manual tarball as the honest interim | Ch. 2 §8 |
| Whether this Hub should have Bluetooth at all | The `bluetooth` entry sits in `setup_retry` forever. The remedy (`-v /run/dbus:/run/dbus:ro`) is written down and **UNVERIFIED**; nothing in phases 1–6 needs BLE and the adapter will not exist on the mini PC. Disabling the entry is the honest alternative | Ch. 3 §3.7 |

Secrets land in exactly two files on the Hub host, both gitignored, both 0600:
[`../hub/.broker-passwords.env`](../hub/) (the three broker passwords) and
[`../hub/token`](../hub/) (the Panel's long-lived HA token). Everything else a
vendor issues is typed into HA and lives in `hub/ha-config/.storage`. No
credential value belongs in this repo, in a shell history, or in an
`Environment=` line.

---

## Status — what is commissioned today

Measured on the Hub host **2026-08-04**, and re-measured against the live
config-entry, pending-flow and state lists before this page was published.
**The machine is the ground truth, not any table in this repo** — including this
one. Re-measure before believing a row:

```sh
cd <repo>/appliance/commissioning
./hactl '[{"type":"config_entries/get"},{"type":"config_entries/flow/progress"}]'
```

| Layer | Commissioned | Outstanding |
|---|---|---|
| Host | Ubuntu 26.04, SSH up, lid ignored (verified live), docker-ce 29.7.1 + compose v5.4.0 on a live apt source, repo cloned. **Flutter Linux toolchain present and proven** — `flutter build linux --release` succeeds (**G4**) | Wi-Fi lease at `192.168.68.81` is **unreserved**; wired `enp162s0` cabled-down; GNOME battery auto-suspend still `suspend`/900 s. The toolchain was installed **by hand**, so `flutter_toolchain_packages` does not yet describe the host that builds ([1 §1.7a](commissioning/01-host-and-network.md)) — do not assume a fresh converge reproduces this box |
| Hub stack | 4 containers Up. Broker `allow_anonymous false`, users `ha`/`ring`/`z2m`, `passwd` `1883:1883 0600` | Zigbee2MQTT parked (no coordinator, ADR-0003); `/run/dbus` volume not added; **still no repeatable backup step** — a one-off encrypted copy was taken 2026-08-04 and is the only one, and it lives off this disk, so a restore depends entirely on it |
| Home Assistant | Onboarded, token minted at `hub/token`. **`mqtt` entry loaded** — `127.0.0.1:1883`, user `ha`, protocol 5, zero devices, which is its correct end state. **`script: !include scripts.yaml` added** and `hub/ha-config/scripts.yaml` created, un-ignored by a `hub/.gitignore` negation the way `automations.yaml` is ([3 §3.8](commissioning/03-home-assistant.md)); two script entities live, neither ever executed. `hactl` is **in the repo** at [`commissioning/hactl`](commissioning/hactl) and is the single WebSocket mechanism for the whole guide | `bluetooth` entry in `setup_retry` (DBus not mounted) — expected, not your mistake. `scripts.yaml` is un-ignored but **still untracked** (`??`) — `git add` it, or the wall is the only copy |
| Local devices | **3 × `tplink` entries loaded** — `switch.entry_light`, `switch.stairs_light` (both **repurposed from fridge/aquarium 2026-08-05** and renamed, Ch. 4 §4.1.1), and the EP40 parent + 2 children, all added headlessly, no cloud account involved. **`homekit_controller` "Main Floor" loaded** — the Ecobee's LOCAL entry, paired 2026-08-04, and it won the race for `climate.main_floor`; 16 entities over two devices, including a bridged SmartSensor. **`rachio` entry loaded** — the CLOUD one, 10 entities: 5 zone switches, standby, rain delay, a schedule switch, rain + connectivity sensors | **Rachio local HomeKit** — card open at step `pair`, bridge still `sf=1`, needs the setup code. **Ecobee cloud** — branded card open at step `user`, needs ecobee.com credentials + MFA. **Tesla Wall Connector — blocked at the hardware**: every TCP port RSTs, still advertising `PROV_*._smartenergy._tcp`, so nothing HA can do unblocks it. **Two Kasa wall switches — not installed**, no such device is on the LAN, out of phase |
| Cloud fleet | Nothing. ring-mqtt is Up and sitting at the auth gate, which is its correct state | **Every phase 3–5 device**: Ring 2FA, Wyze identification + flashing + streams, HACS, LG ThinQ, Whisker, Petlibro, Emporia. SmartThings is a decision (D3), not a task |
| Panel | The °F/°C rendering defect is **fixed** (trap #10). **First light, 2026-08-04:** the `flutter build linux --release` bundle connected to this Hub, opened a doorbell Popup unprompted on a state change, **rendered live MJPEG** from go2rtc, and tore the stream down cleanly ([6 §6.9a](commissioning/06-panel-and-bindings.md)) | Nothing bound to real hardware. All 33 Placements are bound, every one to a `hub/dev/` stand-in, so all 33 read `missing` against the real Hub; `_integrated` is still `{}`; `kiosk_app` still points at the spike bundle. **First light was Xvfb, not `cage`; no touch; a synthetic pattern, not a camera; an injected state, not a real Ring** — and the `stream: selftest` line that fed it was reverted, so a Panel built from the repo today shows no video. The five open items are §6.9a's table |

**The loaded `rachio` entry came in through the branded card** — its `source` is
`homekit`, which is trap #2 below. That was the right call here and is not a
mistake to undo: only the cloud entry carries standby, rain delay, schedules and
the rain sensor, and the local HomeKit bridge exposes bare zone valves. But it
means those entities are cloud-backed, and anything bound to them must say
`connectivity: cloud`. The `source` field is also how you audit that choice
months later, so read it before trusting anyone's `connectivity:` line.

Two arithmetic facts worth carrying: there are **four** live switchable sockets
and **three** `outlet` Keys, and there is **no irrigation kind** in
`panel/lib/domain/device_vocabulary.dart` at all (14 kinds, verified) — so the
Rachio's five zones have nowhere to land on the Panel, and getting them there is
a **code change plus a drawing session**, not just a drawing session.

> **Two chapters are stale against decisions recorded above, and the
> disagreement is theirs, not this page's.**
> [4 §4.1.1](commissioning/04-devices-local.md) carries the owner decision
> correctly. Both drifts it named were corrected on 2026-08-04:
> [6 §6.4](commissioning/06-panel-and-bindings.md) now records the owner's
> decision to bind the fridge and the aquarium normally (and what it still
> costs — new Keys, i.e. drawing work), and
> [7 §7.2](commissioning/07-device-lifecycle.md) now points at
> [`commissioning/hactl`](commissioning/hactl), which is committed and
> executable.

---

## Things that will bite you

Each of these cost someone time. They are listed where they bite, not where
they are explained; follow the chapter link for the evidence.

| # | Trap | What actually happens | Chapter |
|---|---|---|---|
| 1 | **The Mosquitto `passwd` ownership inversion** | `mosquitto_passwd` prints *"use `chown root`"*. Follow it and the broker restart-loops on `Error: Unable to open pwfile` — it opens the file **after** dropping to uid 1883. The file must be `1883:1883 0600`, and `mosquitto_passwd` resets it to `root:root` on **every** run, so the chown is mandatory each time | [2 §3](commissioning/02-hub-stack.md) |
| 2 | **The double-discovery card** | One `_hap._tcp` advert raises **two** HA cards: a vendor-branded one (`handler: ecobee` / `rachio`, source `homekit`) which is the **cloud** integration, and `homekit_controller` (source `zeroconf`) which is the **local** one. Pick the branded card and you get cloud-backed entities that you then label `connectivity: local` — a label nothing downstream validates. The pin dies the moment the WAN drops. Read `handler`, never the pretty name | [4 §4.2.1](commissioning/04-devices-local.md) |
| 3 | **The HomeKit pairing code MUST be dashed** | Typed as the thermostat shows it, `XXX-XX-XXX`, it creates the entry. Stripped to eight bare digits — **the same digits** — the form **silently re-shows itself**: no error text, no abort, no `invalid_authentication`. It looks exactly like nothing happened. `homekit_controller` validates the `XXX-XX-XXX` shape before the code ever leaves HA, so the obvious next moves (restart the thermostat, re-open the HomeKit screen, go hunting VLANs) all take you further from the cause, which is two hyphens. On REST you get an unchanged `{"type":"form"}` with the same `step_id`. **Measured — it cost a failed attempt on the Ecobee, and the Rachio is the next flow it will bite** | [4 §4.2.4](commissioning/04-devices-local.md), [4 §4.3.3](commissioning/04-devices-local.md) |
| 4 | **The EP40 parent switch** | The two-outlet plug registers **three** switches. `switch.tp_link_smart_plug_722c` is the parent and it drives **both** outlets at once. Bind the `_kasa_smart_plug_722c_0` / `_1` children. Never the parent, never `switch.*_led`, never `binary_sensor.*_cloud_connection` | [4 §4.1.5](commissioning/04-devices-local.md), [6 §6.3](commissioning/06-panel-and-bindings.md) |
| 5 | **The first Kasa cannot self-discover** | `tplink`'s DHCP matchers do not include the `5CA6E6` prefix, and its broadcast sweep is registered in `async_setup()` — which runs only once an entry exists. Waiting for discovery is not a route. Start the flow with an **empty host**: that branches to `pick_device`, which runs the sweep. After the first entry the rest raise their own cards within the 15-minute interval | [4 §4.1.4](commissioning/04-devices-local.md), [7 §7.3.3](commissioning/07-device-lifecycle.md) |
| 6 | **`entity_id` is fixed at first registration** | Not a convention, a code path: `async_get_or_create` looks the entity up by `(domain, platform, unique_id)` and takes an early return that refreshes the *names* around an id it never touches. So renaming the plug in the Kasa app changes what it is **called** and nothing the Panel binds to — and **deleting and re-adding the integration does not help either**, because removal is a *soft* delete into `deleted_entities` that restores the same id for **30 days**. The only ways out are a `config/entity_registry/update` with `new_entity_id`, or genuinely new hardware. The corollary is the cheap fix: name the device in the vendor app **before** HA first sees it. The EP40 is the live proof — added on its factory alias, permanently `switch.tp_link_smart_plug_722c_kasa_smart_plug_722c_0` | [7 §7.4](commissioning/07-device-lifecycle.md) |
| 7 | **`docker.sources` after a release upgrade** | `do-release-upgrade` writes `Enabled: no` into every third-party source and leaves `Suites:` on the old codename — silently. `apt-get -s upgrade` then reports 0 packages while Docker sits frozen with no security path. Detect with `apt-cache policy docker-ce`: a trapped one names only `/var/lib/dpkg/status`. Fix it **before** the hub stack exists, because it restarts `dockerd` | [1 §1.5](commissioning/01-host-and-network.md) |
| 8 | **Environment beats `--dart-define`** | The Panel resolves `HUB`/`HA_URL`/`HA_TOKEN`/`GO2RTC_URL`/`LOG` **environment first**. That is why `panel_hub_kind`, `panel_ha_url`, `panel_go2rtc_url` and `panel_log_level` default to `""` in `group_vars/all.yml` and must stay empty — a "harmless" default there silently forces a Panel built with `--dart-define=HUB=ha` back onto the fake Hub. And **web builds have no process environment**: on `-d chrome` an exported `HA_URL` is discarded and the boot log says `env=unavailable` | [6 §6.5, §6.7](commissioning/06-panel-and-bindings.md) |
| 9 | **A new Key is drawing work** | Keys are authored in Sweet Home 3D (ADR-0005), not in `bindings.yaml`. The sequence is `panel/tool/sh3d.sh` → `tool/sh3d_to_yaml.py` → `dart run tool/gen_dev_entities.dart`. A binding whose Key has no Placement is a **fatal boot error** — on the appliance that is a restart loop behind a black screen. And a Rachio pin needs more than a drawing: the Device vocabulary has no irrigation kind, so that one is a code change too | [6 §6.2](commissioning/06-panel-and-bindings.md), [4 §4.3.6](commissioning/04-devices-local.md) |
| 10 | **The °F/°C rendering defect — FIXED** | HA converts climate temperatures into the Hub's unit system *before* they reach the API, and a `climate.*` entity's attributes never say which one that was (measured: `current_temperature: 83`, no unit anywhere in the payload). The Panel used to hold that number in a field named `currentC` and append a hard-coded `°C`, so this Hub's real Ecobee rendered **`83.0 °C`** on the wall. **Now fixed**, and worth knowing because chapters 3 and 4 still describe the defect as live | see below |
| 11 | **`GO2RTC_URL=absent` is not a misconfiguration** | It is the only Panel **address** with no built-in default, deliberately (`HA_TOKEN` has none either, but a default secret is not a thing that could exist): `HA_URL`'s default is earned because `HUB=fake` gates it, and a camera is a camera under every Hub — so a `localhost:1984` default would dial nothing on every run, and a *wrong* address would stay invisible until somebody tapped a camera. Absent, the Panel boots normally, every pin renders, and one Popup says the view is unavailable. Do not "fix" it by writing an address into `group_vars/all.yml` unless a go2rtc stream actually exists. Setting it *does* now produce a picture — both builds have a real player, go2rtc's `origin: "*"` landed 2026-08-04 (**E8**, decided), and the Linux release bundle has been **observed** rendering a frame ([6 §6.9a](commissioning/06-panel-and-bindings.md)) — but only for a stream that exists, which today means `selftest` | [6 §6.5a](commissioning/06-panel-and-bindings.md) |
| 12 | **A headless Panel run needs `GDK_BACKEND=x11`, or it opens on the wrong screen** | Running the Linux bundle under `Xvfb :99` with only `DISPLAY=:99` set is not enough. GTK finds the host's own Wayland session and honours that instead: the window opens on the operator's real desktop, Xvfb's root window is left with **zero children**, and the screenshot you take of `:99` is black. No error, no warning — indistinguishable from a build that cannot render, which is the wrong thing to spend an afternoon on. Set `GDK_BACKEND=x11` **and** empty `WAYLAND_DISPLAY`. Headless verification only; the real kiosk is `cage` on a Wayland seat and wants neither | [6 §6.9a](commissioning/06-panel-and-bindings.md) |

**Where trap #10 was fixed**, so nobody re-derives it: `ThermostatState` now
carries a `TemperatureUnit?` alongside its two numbers instead of asserting
Celsius in a field name
([`../panel/lib/domain/device_state.dart`](../panel/lib/domain/device_state.dart));
`HaHubClient` learns the unit from `get_config`'s `unit_system.temperature` and
passes the reading through **unconverted**
([`../panel/lib/data/ha_hub.dart`](../panel/lib/data/ha_hub.dart)); and
`device_presentation.dart` writes the degree symbol in exactly one place, which
renders a bare `83.0°` while the unit is still unknown rather than guessing
([`../panel/lib/ui/device_presentation.dart`](../panel/lib/ui/device_presentation.dart)).
The safety property is that a suffix appears only when the Hub stated it — the
wall can be uninformative, never wrong. Two consequences: `unit_system` is a
preference again rather than a trap, and
[3 §3.1](commissioning/03-home-assistant.md) and
[4 §4.2.6](commissioning/04-devices-local.md) are stale where they tell you to
settle the question before binding a thermostat.

Five more, cheaper but just as real:

- **`climate.main_floor` is first-come.** Both the cloud and the local Ecobee
  integrations want that exact entity id; the loser gets `_2`. Which is which
  depends on commissioning order and is then frozen in the registry forever.
  Identify the entity by its owning config entry, never by its name. The same
  collision is waiting for the Rachio's zones when its local bridge is paired.
- **The first real binding turns the suite red.**
  `panel/test/bindings_drift_test.dart` carries `const _integrated = <String>{};`
  and every rebound Key must be added to it, in the same commit as the binding.
  `panel/test/ha_hub_live_test.dart` asserts Device readings against the **dev
  Hub's vocabulary seeds** — a real Ecobee will not produce them. Neither file
  is mentioned in any phase plan.
- **A running Panel does not notice a rename or a removal.** HA fires
  `state_changed` with `new_state: null`, and `HaHubClient._onFrame` only
  applies frames whose `new_state` is a Map — so the pin holds its last reading
  indefinitely, until the socket drops and a fresh `get_states` corrects it.
  **Restart the Panel** after either. Worse, tapping a pin whose entity is gone
  returns HTTP 200 with an empty body, so nothing anywhere logs that the tap did
  nothing ([7 §7.5, §7.7.3](commissioning/07-device-lifecycle.md)).
- **`missing=0` is not coverage.** It compares the ids you wrote against the
  Hub's snapshot. A Device with no `entity:`, a real device with no Key, and a
  binding pointed at the *wrong* existing entity all report clean.
- **An empty discovery list is not evidence of absence.** The Kasa fleet was on
  the LAN and answering the whole time. Equally, mDNS is proven healthy on this
  link — "must be the same VLAN" is a red herring here. And a device that is
  already paired stops advertising itself as pairable (`sf` bit 0 clears), so a
  missing `homekit_controller` card can simply mean success.

---

## Where the reasoning lives

This document is procedure. It deliberately does not restate the narrative or
the decisions.

| For | Read |
|---|---|
| Why each device takes the path it takes, phase by phase, plus the D-log (D0–D6) | [`../docs/plans/device-integrations/`](../docs/plans/device-integrations/) |
| The architectural decisions the procedure obeys | [`../docs/adr/`](../docs/adr/) — [0002](../docs/adr/0002-home-assistant-headless-hub.md) (headless Hub), [0003](../docs/adr/0003-zigbee-z2m-not-matter-thread.md) (Zigbee), [0005](../docs/adr/0005-devices-authored-in-the-drawing.md) (Devices are drawn), [0006](../docs/adr/0006-togglability-is-decided-by-the-house.md) (togglability), [0007](../docs/adr/0007-the-panel-recovers-alone-and-says-when-it-cannot.md) (the Panel says when it cannot), [0008](../docs/adr/0008-device-integrations-on-a-linux-host-never-macos.md) (Linux host, never macOS) |
| The stack's standing notes and the mini PC migration | [`../hub/README.md`](../hub/README.md) |
| Drawing the house | [`../panel/HOUSE-PLAN.md`](../panel/HOUSE-PLAN.md) |
| Kiosk provisioning, and how the token reaches the Panel | [`README.md`](README.md), [`ansible/README.md`](ansible/README.md) |

**The Hub host has no passwordless sudo.** Every privileged step in every
chapter is handed to the operator to run at a terminal; an agent session cannot
complete them. The chapters are written so that the bring-up needs almost none.
