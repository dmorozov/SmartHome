# Phase 2 — Local quick wins: Kasa, Tesla Wall Connector, Ecobee, Rachio

Four integrations, zero new containers. Ends with the first physical device
toggled from the Dollhouse and a local climate entity for the `thermostat`
pin.

> **Rewritten 2026-08-04 against the measured LAN and the measured HA
> source.** What changed, in one line each: the Kasa fleet is three plugs
> and no wall switches (§1); the Tesla Wall Connector is **blocked**, not a
> quick win (§2); the Ecobee has a discovery trap the original text walked
> straight into (§3); **Rachio** is new (§4, owner decision D6). The
> original claims are kept in place, struck through in prose, because a
> plan that quietly forgets what it used to believe teaches nothing.

## 1. Kasa — three plugs, four sockets, two of them safe to expose

**Status: all three entries are ALREADY ADDED to HA** — done headlessly
2026-08-04 by driving the config-flow REST API with the long-lived token
(`hub/token`). Nothing in this section needs re-running; it is the record of
what is there and the *binding* work that is still open.

~~"Kasa outdoor plug + two wall switches. Hardware first: the two Kasa Wi-Fi
light switches are still uninstalled — in-wall mains work, which is in scope
for the owner. Breaker off, verify dead, neutral required."~~ **Wrong.** No
Kasa wall switch is on the LAN. The in-wall mains work is not a
prerequisite for anything in this phase and has been removed from it; if the
switches are bought and installed later they are a new, separate pass. What
is live:

| IP | MAC | Model | Alias | Notes |
|---|---|---|---|---|
| `.59` | `5C:A6:E6:09:B6:19` | HS103 | "Old fridge" | fw 1.0.3 (2020). Continuously ON |
| `.60` | `5C:A6:E6:09:B5:F8` | HS103 | "Aquarium" | fw 1.0.3 (2020). Continuously ON |
| `.74` | `5C:A6:E6:CA:72:2C` | **EP40** outdoor | default alias, unrenamed | fw 1.0.2 (2021). `child_num: 2` — two outlets |

Three facts that change the work:

- **No cloud account is needed.** All three answer the legacy TP-Link XOR
  protocol on TCP/UDP 9999. `tplink` is `iot_class: local_polling` and
  stays local; the `binary_sensor.*_cloud_connection` entities merely
  *report* whether the plug can see TP-Link's cloud. They are not a
  dependency and must never be bound.
- **No `EMETER`.** All three report feature `TIM` only, so there are **no
  power and no energy sensors** from any Kasa device. Anything in this repo
  that hoped a Kasa plug could feed an `energy-monitor` or a `PowerState`
  Key cannot be built on this hardware. That job belongs to the Emporia
  work in [phase 5](phase-5-cloud-fleet.md).
- **The first device does not self-discover.** `tplink`'s 73 DHCP matchers
  do **not** include the `5CA6E6` prefix these units use, and its broadcast
  discovery loop only runs once an entry already exists. So the first plug
  must be added by hand and the rest follow. In the flow, leaving **host
  empty** triggers a `pick_device` step listing what the broadcast found —
  which is how all three got added in one pass.

### The entities that exist

```
switch.old_fridge
switch.aquarium
switch.tp_link_smart_plug_722c                                 # EP40 PARENT
switch.tp_link_smart_plug_722c_kasa_smart_plug_722c_0          # EP40 outlet 1
switch.tp_link_smart_plug_722c_kasa_smart_plug_722c_1          # EP40 outlet 2
switch.old_fridge_led  switch.aquarium_led  switch.tp_link_smart_plug_722c_led
binary_sensor.*_cloud_connection  ×3
```

**Bind the two children, never the parent.** The EP40 parent switch drives
*both* outlets at once, so a pin bound to it looks like one socket and
silently operates two. Never bind `switch.*_led` (those are the status LEDs
on the plug bodies) and never bind `*_cloud_connection`.

### The safety problem — read before choosing Keys

Per ADR-0006, togglability follows from the Device **kind**, not from live
state: an `outlet` Key is togglable and has **no confirm step**. Two of the
four live sockets are `switch.old_fridge` and `switch.aquarium`, both ON
continuously for at least eight days. Binding either to an `outlet` Key puts
"cut power to the refrigerator" and "kill the aquarium pump" one stray tap
away, on a wall display, with no confirmation — that is a genuine foot-gun,
not a theoretical one.

Only three `outlet` Keys exist in the placeholder house (`outlet-outdoor-a`,
`outlet-outdoor-b`, `outlet-master`) against four live sockets, so something
goes unbound regardless. Bind the ones that are safe to toggle:

```yaml
  outlet-outdoor-a:
    entity: switch.tp_link_smart_plug_722c_kasa_smart_plug_722c_0
    connectivity: local
  outlet-outdoor-b:
    entity: switch.tp_link_smart_plug_722c_kasa_smart_plug_722c_1
    connectivity: local
```

`outlet-master` keeps whatever it has; the fridge and the aquarium stay
**deliberately unexposed** until a Key kind exists that does not toggle on a
single tap. Recording that choice matters, because phase 6's `missing=0`
cannot see it — see [phase 6 §1a](phase-6-bindings-sweep.md).

Adding a fourth `outlet` Key is **not** a `bindings.yaml` edit. Per
ADR-0005, Devices are authored in the drawing: a Sweet Home 3D session on
the Mac (`panel/tool/sh3d.sh`, its startup flag is mandatory), then
`tool/sh3d_to_yaml.py`, then `dart run tool/gen_dev_entities.dart`.

**Verify**: tap the Room/pin in the Panel → the physical outlet clicks;
toggle at the plug button → the pin updates (state_changed round-trip). This
is the plan's first end-to-end proof.

## 2. Tesla Wall Connector — BLOCKED, not a quick win

~~"Local HTTP, monitoring only. Find its IP (router table), reserve it, then
Add → Tesla Wall Connector → host `<wc-ip>`."~~ **The unit does not serve
HTTP.** Measured 2026-08-04 at `192.168.68.52` (`08:d1:f9`, Espressif OUI):

| Probe | Result |
|---|---|
| ICMP | alive |
| TCP 1–10000, 15 sweeps over 75 s | **every port RST** — refused, not filtered |
| `http://192.168.68.52/api/1/vitals` | unreachable |
| mDNS | advertises `PROV_8037F0F._smartenergy._tcp` |

`RST` rather than a timeout is the whole diagnosis: nothing is filtering
this traffic, there is simply nothing listening. And `PROV_<hex>` is the
**ESP-IDF provisioning-manager default service name** — the name a unit
advertises while it is still waiting to be commissioned. The application
HTTP server never came up. The most likely reading is that Wi-Fi
commissioning was never completed, so the unit joined the network but never
started its API.

Recheck before touching the hardware — both paste-able, both read-only:

```sh
ping -c 3 192.168.68.52
curl -sS --max-time 5 http://192.168.68.52/api/1/vitals ; echo "exit=$?"
```

Unblocking it means **re-commissioning the Wall Connector**, which is a
physical/hands-on step done through Tesla's own setup flow against the
unit's own Wi-Fi access point. **UNVERIFIED**: the exact 2026 wording and
sequence of that flow, and whether this Gen 3 unit needs a factory reset
first. That comes from the operator's own device and Tesla's own
documentation — it is not written down here because nobody in this repo has
seen it.

**`sensor.<wall-connector>_power` is an unverified guess.** `/api/1/vitals`
has never responded on this unit, so its vitals key set has never been
observed and the entity id above was invented, not read. Do not bind it.
Until the unit serves HTTP, the `ev-charger` Key keeps **no `entity:`
line** — the same treatment [phase 6](phase-6-bindings-sweep.md) gives every
Device whose hardware is not available, so it is excluded from `missing`
by construction rather than sitting there as a permanent red mark.

**Done for this section** is a decision, not an entity: either the operator
re-commissions the unit and §2 gets rewritten with real vitals, or
`ev-charger` is formally deferred. It no longer gates this phase.

## 3. Ecobee — dual path (grilling decision, 2026-08-03)

Both integrations, same thermostat, run simultaneously (§3.3): cloud for
features, HomeKit for local resilience. **The Panel binds to the HomeKit
entity** — local-first is the house rule; the cloud entities serve a future
schedules/vacations UI.

The unit is at `.67`, `44:61:32:C4:DD:06`, an EB-STATE5 "Main Floor",
fw p20.4.8.70710. Today it advertises **only** `_airplay._tcp` and
`_raop._tcp`: HomeKit is **off**, so no `_hap._tcp` record exists yet and
`homekit_controller` has nothing to find. Enabling it is a touchscreen
action — the Apple HomeKit item under the thermostat's own settings menu
(**UNVERIFIED**: the exact 2026 menu wording on p20.4.x). It ends with the
screen displaying a setup code. The pairing slot is free (D0a: linked to
Alexa cloud-to-cloud and the ecobee app only, never to Apple Home).

### 3a. THE TRAP — one advert, two cards, and one of them is a lie

The moment that `_hap._tcp` record appears, HA raises **two** discovery
cards for the same thermostat:

| Card | Source | What it actually is |
|---|---|---|
| **"ecobee"**, branded | `homekit` | the **CLOUD** integration. `ecobee`'s manifest carries `homekit: {models: ["EB", "ecobee*"]}` and `iot_class: cloud_polling` — this unit's `EB-STATE5` matches `EB`, so a HomeKit advert *summons the cloud card* |
| **"HomeKit Device"** | `zeroconf` | `homekit_controller`, the **LOCAL** one. This is the one to pair |

Pairing through the branded card yields cloud-backed entities that the
Panel would then label `connectivity: local`. The Popup shows connectivity,
so that is a user-visible lie, and the outage drill below is what catches
it. This is not hypothetical: **it is observable right now with the
Rachio**, which raises exactly that pair of cards today (§4).

Rule: for local pairing, take the card that says **HomeKit Device**, never
the vendor-branded one.

### 3b. Cloud (5 min)

Add → **ecobee** → ecobee.com username + password, then an MFA step whose
code is **time-boxed** — have the phone in hand before starting. No
developer API key: keyless since HA 2026.3, and our pin is 2026.7. The
integration is `single_config_entry: true`, so there is exactly one of it
ever. Entities: `climate.*`, remote sensors, weather.

### 3c. HomeKit-controller (local)

Enable HomeKit on the touchscreen (above), take the **HomeKit Device** card,
enter the setup code. Entities arrive as a second `climate.*` plus
humidity/temperature sensors.

~~"If it doesn't appear within a minute: thermostat and laptop must be on the
same subnet/VLAN; power-cycle the thermostat's HomeKit menu and retry."~~
**Deleted — that is a red herring on this link.** mDNS is proven healthy
here: the Rachio's HAP advert is visible from *inside* the HA container.
If the card does not appear, the fault is the thermostat not advertising
(HomeKit still off, or the menu not committed), not the network.

Binding:

```yaml
  thermostat:
    entity: climate.<homekit-entity-id>   # the LOCAL one, not the cloud one
    connectivity: local
```

**This binding breaks a test.** `panel/test/ha_hub_live_test.dart` asserts
`thermostat.currentC` is within 0.05 of the vocabulary seed
(`ThermostatState(currentC: 21.4, targetC: 21.0)` in
`panel/lib/domain/device_vocabulary.dart`). A real Ecobee will not read
21.4°C, so that assertion must be relaxed to a plausibility range — the
test's job is proving the Hub round-trip, not pinning a house temperature.
See "Done when".

**Verify — the outage drill** (this is why the dual path exists): pull the
laptop's WAN (or block ecobee.com), and setpoint changes from the Panel
must still work via the HomeKit entity while the cloud `climate.*` goes
unavailable. Restore, both recover. Log lines to watch:
`hub.state_unusable` / `hub.state_recovered` for the cloud entities. **This
drill is also the trap detector**: if the "local" entity dies with the WAN,
the branded card was paired.

## 4. Rachio — 5 zones (owner decision D6, 2026-08-04)

New in this plan; it postdates the research document, so there is **no
§3.x** for it. The controller is at `.71`, `70:74:14`, hostname
`Rachio-BFF806`, 5 zones.

Same dual shape as the Ecobee, and the same trap — here it is **measured,
not predicted**: the Rachio raises **both** a **"Rachio"**-branded card
(source `homekit`; the manifest carries `homekit: {models: ["Rachio"]}`
with `iot_class: cloud_push`) and a **"HomeKit Device"** card (source
`zeroconf`) for its local HomeKit **Bridge**, category "Bridge", currently
unpaired. §3a's rule applies verbatim, and this device is where you can go
look at the two cards side by side before the Ecobee ever advertises.

It also will not self-discover by DHCP: `rachio`'s matchers are MACs
`009D6B*`, `F0038C*`, `74C63B*` and this unit is `70:74:14`. Its zeroconf
matcher (`rachio*` on `_http._tcp.local.`) may still fire — **UNVERIFIED**,
only the HAP advert has been observed here. Adding it by hand is fine.

### 4a. Cloud (the API key)

Add → **Rachio** → it asks for one field, an API key. HA's own flow text
points at `https://app.rach.io/` → Settings → **"GET API KEY"** (that
wording is quoted from `rachio/strings.json`, not invented). Entities the
integration creates:

| Platform | Entities |
|---|---|
| `switch` | standby, rain delay, **one per zone** (5 here) |
| `binary_sensor` | rain, flow |
| `calendar` | per base station |

**The push caveat, read from the source.** `rachio` is `cloud_push`: it
registers a webhook and hands Rachio's cloud a URL to POST to. Without a
Nabu Casa subscription the code falls through to
`webhook.async_generate_url(...)`, which yields HA's **internal** URL —
`http://192.168.68.81:8123/api/webhook/<id>`, unreachable from the
internet. Setup still succeeds and logs nothing louder than a debug line
saying the URL "must be accessible from the internet in order to receive
updates". So **watering started from the Rachio app may not show up in HA**.
How stale it actually goes is **UNVERIFIED** — observe it before deciding
whether this needs solving, and do not open a port to fix a problem that
has not been demonstrated.

### 4b. Local (HomeKit bridge)

The bridge is unpaired and its slot is free. Pair it via the **HomeKit
Device** card. Local pairing is what makes zone control survive a WAN
outage; it does not carry the schedule/rain-skip intelligence, which is
cloud-side.

### 4c. No Panel binding — and why that is correct

`panel/lib/domain/device_vocabulary.dart` has fourteen `DeviceKind` values
and **none of them is irrigation**. There is therefore no Key a Rachio zone
can honestly bind to, and forcing one into `outlet` would inherit
single-tap togglability (ADR-0006) for something that should not be tapped
by accident. Phase 2 delivers Rachio **into the Hub only** — visible and
controllable in HA, absent from the Dollhouse.

Giving it a pin later is a two-part change, in this order: a new
`DeviceKind` + `KindSpec` + seed (a vocabulary edit that ripples through
the loader, `FakeHub`, the state fold and the dev-entity generator — the
file's own doc comment lists them), *then* a drawing session per ADR-0005.
That is a deliberate piece of work, not a line in `bindings.yaml`.

## Done when

~~"Kasa plug + both switches toggle from the Panel; `ev-charger` pin shows
live power."~~ Neither is reachable: there are no wall switches, and the
Wall Connector serves no API. The achievable end state:

- **Kasa** ✅ done — three entries in HA, five switchable-socket entities
  (plus three LED switches and three cloud-connection sensors that stay
  unbound), all local.
- The **two EP40 outlets** toggle from the Panel and report plug-side
  changes; both `connectivity: local`; the parent switch is bound by
  nothing.
- The fridge and aquarium plugs are visible in HA and **deliberately not
  bound**, with that choice written into phase 6's mapping table.
- **Ecobee**: two `climate.*` entities exist, the Panel binds the HomeKit
  one, and **the outage drill passes** — which is simultaneously the proof
  that the branded card was not the one paired.
- **Rachio**: 5 zone switches + standby/rain-delay/rain/flow in HA, HomeKit
  bridge paired locally. No Panel binding, by design (§4c).
- **`ev-charger`**: formally deferred with no `entity:` line, or §2
  rewritten because the unit was re-commissioned. Either closes it.
- **`panel/test/bindings_drift_test.dart`**: every rebound Key added to
  `const _integrated = <String>{}`. The set is the ledger of "this one is
  real now"; a Key that moves to real hardware without being listed makes
  the suite go red against the dev-Hub stand-ins. For this phase that is
  `outlet-outdoor-a`, `outlet-outdoor-b`, `thermostat`. **The original plan never
  mentioned this file at all.**
- **`panel/test/ha_hub_live_test.dart`**: the 21.4°C seed assertion relaxed
  before `thermostat` points at a real Ecobee.
- `flutter test` green, `hub.missing_entities` no longer listing this
  phase's entities.

## As built — 2026-08-04

| Item | Result |
|---|---|
| Kasa ×3 in HA | ✅ **Done.** Three `tplink` config entries, all `source: user`, created headlessly by driving `POST /api/config/config_entries/flow` with the token in `hub/token`. Entities confirmed live via `GET /api/states`: `switch.old_fridge` on, `switch.aquarium` on, `switch.tp_link_smart_plug_722c` + its two children on. |
| First-device discovery gap | ✅ Diagnosed and worked around — `5CA6E6` is in none of `tplink`'s 73 DHCP matchers, so the empty-host `pick_device` step was used instead. Documented in §1 so it is not rediscovered on the mini PC. |
| Kasa power sensors | ❌ **Impossible on this hardware.** Feature list is `TIM` only; no `EMETER` on any of the three. |
| Tesla Wall Connector | ❌ **Blocked.** No config entry attempted — the unit refuses every TCP port. Evidence table in §2. |
| Ecobee | ⏸ Not started: HomeKit is off on the touchscreen, so `homekit_controller` has nothing to discover. Cloud half needs the ecobee.com credentials and a live MFA code. Both are operator steps. |
| Rachio | ⏸ Not started: needs the API key from `app.rach.io`, an operator step. The dual-card trap was **confirmed by observation** on this device — it is what proved §3a is real before the Ecobee ever advertises. |
| Bindings | ⏸ **Nothing rebound yet.** All 33 entries in `panel/assets/house/bindings.yaml` (33 Keys, 33 `entity:` lines, matching house.yaml's 33 Placements) still point at the `hub/dev/` stand-ins, so every one reads "missing" against the real Hub. That is expected until the bindings above are made — and it is the reason `_integrated` is still empty. |
