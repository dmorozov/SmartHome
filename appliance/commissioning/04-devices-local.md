# 4 — Local devices

Running Hub → *the first real hardware in the entity registry*. End state: three
Kasa sockets toggling over the LAN, one thermostat reachable without the
internet, one irrigation controller, and one EV charger correctly recorded as
**blocked** rather than pretended into existence.

"Local" here means one specific thing: the Hub reaches the device over the LAN
and keeps working with the WAN unplugged. It is not a label you choose in
`bindings.yaml` — it is a property of which integration you paired. Two of the
four devices in this chapter will happily hand you a **cloud-backed entity under
a local-looking name** if you click the wrong card. §4.2.1 is the loudest
warning in this document for that reason.

Every measurement below was taken on the Hub host on **2026-08-04** against
Home Assistant **2026.7.4**. Where a fact is not measured it says UNVERIFIED.

**Where this chapter stands on that date**, so the sections below are read as
record or as instruction correctly:

| Device | Local path | Cloud path |
|---|---|---|
| Kasa ×3 | **DONE** — 3 entries loaded (§4.1) | n/a, and no account is involved |
| Ecobee "Main Floor" | **DONE** — paired 2026-08-04 (§4.2.4) | pending, needs credentials + MFA (§4.2.3) |
| Rachio `Rachio-BFF806` | pending, needs the HomeKit code (§4.3.3) | **DONE** — 5 zones loaded (§4.3.2) |
| Tesla Wall Connector | **BLOCKED** at the hardware — full commissioning procedure in §4.4 | n/a |

Both devices with two paths are getting **both**, by owner decision. A pending
card in §4.0's listing is work outstanding, not clutter to dismiss.

Previous chapter: [`01-host-and-network.md`](01-host-and-network.md). The
as-built reasoning behind this chapter is
[`../../docs/plans/device-integrations/phase-2-local-quick-wins.md`](../../docs/plans/device-integrations/phase-2-local-quick-wins.md);
several of its guesses are corrected here and the corrections are called out
where they land.

---

## 4.0 Two ways in, and the shared preamble

Every integration in this chapter can be added through the HA web UI at
`http://192.168.68.81:8123` (Settings → Devices & services → add an
integration), and each has a headless equivalent driven over REST. Use the UI
when a step needs a human — a password, an MFA code, an 8-digit pairing code
off a device screen. Use REST when the step is mechanical, or when you are an
agent with no browser.

**Config flows are REST, not WebSocket.** Three calls, in order:

```bash
export HA=http://127.0.0.1:8123
export TOKEN=$(cat /home/dmorozov/Work/SmartHome/hub/token)   # 0600, gitignored

# 1. start a flow -> returns flow_id and the first step's schema
curl -sX POST "$HA/api/config/config_entries/flow" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"handler":"tplink"}' | jq

# 2. answer a step (repeat per step)
curl -sX POST "$HA/api/config/config_entries/flow/<flow_id>" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"host":"192.168.68.59"}' | jq

# 3. re-read a flow you lost track of
curl -s "$HA/api/config/config_entries/flow/<flow_id>" \
  -H "Authorization: Bearer $TOKEN" | jq
```

`GET /api/config/config_entries/flow` (no id) returns **405 Method Not
Allowed** — measured. Listing *in-progress discovery* flows is a WebSocket
command, and it is the single most useful diagnostic in this chapter because it
is where the double-discovery trap is visible.

**Use [`hactl`](hactl), the tool committed next to this file.** It is the one
WebSocket mechanism in this guide; do not write a second one. It runs
python3+aiohttp inside the `homeassistant` container, because the Hub host has
neither `aiohttp` nor `websockets` (both measured as `ModuleNotFoundError` on
2026-08-04) and installing them needs sudo this host does not have. The token
reaches it through `docker exec -e`, so it never lands in a command line. The
full rationale is [`03-home-assistant.md` §3.5](03-home-assistant.md).

```bash
cd /home/dmorozov/Work/SmartHome/appliance/commissioning

./hactl '[{"type":"config_entries/flow/progress"}]' | python3 -c '
import json,sys
for f in json.load(sys.stdin)[0]["result"]:
    c = f["context"]
    print("%-18s | %-8s | %-46s | %s" % (f["handler"], c.get("source"),
          c.get("title_placeholders"), f.get("step_id")))'
```

Output on 2026-08-04, unedited:

```
upnp               | ssdp     | {'name': 'XE75Pro'}                            | ssdp_confirm
homekit_controller | zeroconf | {'name': 'Rachio-BFF806', 'category': 'Bridge'} | pair
ecobee             | homekit  | None                                           | user
```

Read that carefully, because it is the trap caught mid-resolution. Two physical
devices raised **four** cards between them (§4.2.1). Two of the four are gone —
not dismissed, *consumed*, because the flow behind each was completed: the
Rachio's branded cloud card became a loaded `rachio` entry, and the Ecobee's
`homekit_controller` card became a loaded local pairing. What is left is each
device's other half, and both are still wanted:

| Still pending | Is | Why it is still open |
|---|---|---|
| `homekit_controller` / `Rachio-BFF806` | the Rachio's **local** path | Not yet paired. Needs a HomeKit code (§4.3.3) |
| `ecobee` / source `homekit` | the Ecobee's **cloud** path | Not yet added. Needs ecobee.com credentials + MFA (§4.2.3) |
| `upnp` / `XE75Pro` | the Deco router | Nothing in this house needs it. Harmless; ignore it |

Run this before and after every flow in this chapter. It is the only view that
shows `handler` — the field that decides whether you are about to get a local
or a cloud entity — and the UI card does not show it.

Finally, listing entities — the verification workhorse for the whole chapter:

```bash
curl -s "$HA/api/states" -H "Authorization: Bearer $TOKEN" \
  | jq -r '.[] | "\(.entity_id) = \(.state)"' | sort
```

---

## 4.1 Kasa — three sockets, four switchable outlets

### 4.1.1 SAFETY FIRST — what is plugged into these

Read this before you touch `bindings.yaml`. It is not a style note.

**Current, 2026-08-05 — both plugs were repurposed and both now drive lights:**

| Entity | IP / MAC | What is actually on it | Bindable? |
|---|---|---|---|
| `switch.entry_light` | 192.168.68.59 · `5C:A6:E6:09:B6:19` | **The entry light.** Was a refrigerator until 2026-08-05 | **Yes** — bound to `light-living` (§4.1.1b) |
| `switch.stairs_light` | 192.168.68.60 · `5C:A6:E6:09:B5:F8` | **The stairs light.** Was a fish tank until 2026-08-05 | **Yes** — bound to `light-landing` (§4.1.1b) |

The hazard that governed this section for a day is **gone, not mitigated** —
the loads changed. Read the analysis below anyway: it is the reason these two
were unbindable, and it is the test to re-apply the day either plug moves again.

#### The analysis, and why it no longer binds

Under [ADR-0006](../../docs/adr/0006-togglability-is-decided-by-the-house.md)
togglability is a property of the Device **kind**, decided in the drawing, not
of the entity's live state. `outlet` and `light` are both on/off state families,
so either Key toggles on a single tap — **there is no confirmation step anywhere
in the Panel, by design.** While these plugs ran a fridge and a fish tank, that
put "silently kill the fridge" one mis-tap away from a wall-mounted touchscreen
at child height. A light carries no such consequence, which is the whole of the
change: the Panel behaves identically, the load does not.

Note what did **not** save them, and could not have: nothing in the Panel, the
Hub or the ADR can tell a fridge from a lamp. Both are `switch` entities that
report `on`. The protection was always a human writing down what is physically
plugged in — which is why this table is the first thing in the chapter, and why
it has to be corrected the same day a plug is repurposed rather than the next
time somebody edits `bindings.yaml`.

#### Superseded — owner decision, 2026-08-04

**The risk was put to the owner explicitly, with ADR-0006's one-tap consequence
spelled out, and the owner reaffirmed: bind "Old fridge" and "Aquarium" as
normal outlets.** That was the decision of record for one day. It is now **moot
rather than reversed** — it authorised accepting a hazard that no longer exists.
Kept because the reasoning is worth re-reading, and because the standing rule it
established still holds: this call is the owner's, not that of whoever is editing
`bindings.yaml`.

It also no longer implies the work it used to. That decision left both plugs
waiting on **new outlet Keys drawn in Sweet Home 3D** — the kitchen has no
outlet Key at all. As lights they need nothing of the sort: the placeholder
house already carries 13 `light` Keys, so this became binding work instead of
drawing work. The outlet arithmetic that used to appear here (four live sockets,
three outlet Keys) is retired with it — the EP40's two children are the only
outlets left, and they have `outlet-outdoor-a` / `-b`. `outlet-master` is spare.

#### 4.1.1a Entity ids were renamed, and the ids are the reason

The plugs were renamed **in Home Assistant**, which sets `name_by_user` on the
*device*. That fixes every display surface and **moves no entity id** (§7.4) —
so for a few hours `switch.old_fridge` was the entry light, and a binding would
have had to say so. Both switch entities were therefore renamed properly, via a
registry `new_entity_id` update:

```
switch.old_fridge  -> switch.entry_light    unique_id 5C:A6:E6:09:B6:19 (unchanged)
switch.aquarium    -> switch.stairs_light   unique_id 5C:A6:E6:09:B5:F8 (unchanged)
```

`unique_id` is the plug's MAC and does not move, which is what proves these are
the same two devices and not new registrations.

**The diagnostic entities still carry the old ids** — `switch.old_fridge_led`,
`sensor.aquarium_signal_strength`, `binary_sensor.old_fridge_cloud_connection`,
`button.aquarium_restart` and the two `_on_since` sensors. Nothing binds them
(§4.1.6) and they were left alone deliberately, but a `grep` for `aquarium` in
this Hub still returns hits and that is expected, not leftover work.

#### 4.1.1b Which Keys they took, and the trap in choosing one

| Light | Key | The Key's fictional name |
|---|---|---|
| Entry | `light-living` | "Living Room Light" |
| Stairs | `light-landing` | "Landing Light" |

Both names are wrong about the house and that is fine — the placeholder house
is a fiction, this is the D5 mismatch already accepted for `outlet-outdoor-a`
on a "media" Key, and re-keying at **F1** is a `bindings.yaml`-only edit by
design (ADR-0005).

**`light-hall` is the one that should have taken the entry light, and it is
deliberately not used.** It is the *test suite's* canonical togglable-Device
fixture: `hub_contract_test` builds its world around it and runs that world
against **both** adapters, and `ha_hub_test`, `dollhouse_test` and
`fake_hub_test` all seed `input_boolean.light_hall`. Worse,
`ha_hub_live_test` **toggles** `light-hall` against the dev Hub — a Key bound
to real hardware can never satisfy that, because the dev Hub does not serve
the entity. Binding `light-hall` to `switch.entry_light` was tried and turned
**8 tests red**; the revert is why the entry light sits on a living-room Key.

**The general trap, because this will happen again:** every Key moved to real
hardware must also be added to `_integrated` in
`panel/test/bindings_drift_test.dart`, which is the ledger of Keys expected
*not* to resolve against the dev Hub. Before picking a Key, check it is not a
test fixture:

```bash
cd panel && rg -c 'light-landing|light_landing' test/   # 0 = safe to take
```

A Key with zero test references is free. A Key the tests seed is not, and the
failure will look like a broken adapter rather than a binding choice.

**`light-stairs` was requested and does not exist.** There is no `stair`
anywhere in `house.yaml` — only an "Upstairs" *floor*. Creating that Key is
not a YAML edit: `house.yaml` opens with *"Generated by sh3d_to_yaml.py …
DO NOT EDIT BY HAND (ADR-0004)"*, so a new Key is authored in Sweet Home 3D
and the file regenerated. Doing that against the **placeholder** drawing would
be throwaway work, since F1 replaces the whole house — which is why the stairs
light took an existing Key instead.

### 4.1.2 These are local, and no TP-Link account is involved

All three answer TP-Link's **legacy XOR protocol** on TCP/UDP 9999 — the
pre-KLAP firmware generation. No cloud account, no Tapo credentials, no
`Connect to TP-Link cloud` step in the flow. Measured 2026-08-04:

| IP | Alias | Model | Firmware | `feature` | `child_num` |
|---|---|---|---|---|---|
| .59 | `Old fridge` | HS103(US) | 1.0.3 Build 201015 Rel.142523 | `TIM` | — |
| .60 | `Aquarium` | HS103(US) | 1.0.3 Build 201015 Rel.142523 | `TIM` | — |
| .74 | `TP-LINK_Smart Plug_722C` | EP40(US) | 1.0.2 Build 210105 Rel.165938 | `TIM` | 2 |

Reproduce it yourself — pure stdlib, no HA involved, read-only:

```bash
python3 - <<'PY'
import socket, struct, json
def enc(s):
    k = 171; out = b''
    for c in s.encode(): k ^= c; out += bytes([k])
    return out
def dec(b):
    k = 171; out = b''
    for c in b: out += bytes([k ^ c]); k = c
    return out.decode(errors='replace')
for ip in ("192.168.68.59", "192.168.68.60", "192.168.68.74"):
    s = socket.create_connection((ip, 9999), timeout=3)
    p = enc('{"system":{"get_sysinfo":{}}}')
    s.sendall(struct.pack(">I", len(p)) + p)
    n = struct.unpack(">I", s.recv(4))[0]
    buf = b''
    while len(buf) < n: buf += s.recv(n - len(buf))
    s.close()
    d = json.loads(dec(buf))["system"]["get_sysinfo"]
    print(ip, d.get("alias"), d.get("model"), "feature:", d.get("feature"),
          "child_num:", d.get("child_num"))
PY
```

A refused connection on 9999 means the device is off the network or has been
firmware-upgraded off the legacy protocol. It does not mean you need a cloud
account.

### 4.1.3 `feature: TIM` — there is no power measurement here

`TIM` is the timer capability and nothing else. **No `EMETER`.** These three
sockets report on/off and nothing more: no watts, no amps, no kWh, no
today/month energy.

Consequence for the Panel: they can back an `outlet` Key. They **cannot** back
`energy-monitor`, and they cannot be used to prove the `ev-charger` power pin.
Any plan step that says "bind the Kasa plug's power sensor" is describing
hardware that is not in this house.

### 4.1.4 The first device does not self-discover — and why

Two independent mechanisms fail together, which is why this looks like a broken
integration rather than a chicken-and-egg problem.

**DHCP matching misses.** `tplink`'s manifest carries a long list of
`{hostname, macaddress}` DHCP matchers. `grep -c 5CA6E6` over it returns **0**.
All three of this house's Kasa devices are on the `5C:A6:E6` prefix, so no DHCP
lease will ever raise a discovery card for them.

**The broadcast loop is gated on the component loading.** In
`tplink/__init__.py`, the 15-minute UDP broadcast sweep is registered inside
`async_setup()`:

```python
async def async_setup(hass, config) -> bool:
    hass.async_create_background_task(_async_discovery(), "tplink first discovery", ...)
    async_track_time_interval(hass, _async_discovery, DISCOVERY_INTERVAL, ...)
```

`async_setup()` runs only once the `tplink` component is loaded, and with no
config entry and no DHCP hit, nothing ever loads it. So the sweep that *would*
find the devices is waiting on a device having already been found.

**The break-in is the `pick_device` step.** In `async_step_user`, an **empty
host** field short-circuits straight to a broadcast scan:

```python
if not (host := user_input[CONF_HOST]):
    return await self.async_step_pick_device()
```

So: start the `tplink` flow and submit an **empty** host. `pick_device` shows a
dropdown built as `"{alias} {model} ({host}) {formatted_mac}"`, already
filtered to exclude devices you have configured. Pick one. Once the first entry
exists the component is loaded, the 15-minute sweep starts, and the remaining
devices raise their own discovery cards on their own.

Headless equivalent — the `device` value is the **formatted MAC**, not the IP:

```bash
# empty host -> pick_device
FLOW=$(curl -sX POST "$HA/api/config/config_entries/flow" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"handler":"tplink"}' | jq -r .flow_id)
curl -sX POST "$HA/api/config/config_entries/flow/$FLOW" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"host":""}' | jq '.data_schema'      # read the offered MACs
curl -sX POST "$HA/api/config/config_entries/flow/$FLOW" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"device":"5c:a6:e6:09:b6:19"}' | jq
```

Adding by IP directly (`{"host":"192.168.68.59"}`) also works and skips
`pick_device` entirely. Either route is fine for the first device; the point is
that *waiting* for discovery is not a route.

All three entries currently exist, added headlessly:

```
tplink | TP-LINK_Smart Plug_722C EP40 | src=user | state=loaded
tplink | Old fridge HS103             | src=user | state=loaded
tplink | Aquarium HS103               | src=user | state=loaded
```

### 4.1.5 The EP40 trap — bind the children, never the parent

The EP40 is a two-outlet outdoor plug (`child_num: 2`, children
`Kasa_Smart Plug_722C_0` / `_1`). HA models it as **three** switch entities: a
parent plus two children.

**The parent drives both outlets at once.** It is not a group indicator and it
is not harmless. Binding the parent to an `outlet` Key means one tap cuts both
loads.

**Which physical outlet is which — settled 2026-08-05**, by the owner at the
plug: toggled `switch.outdoor_outlet_a` from HA, watched which socket
responded. The names are no longer provisional.

| Panel Key | Entity | HA child | `unique_id` | Physical socket |
|---|---|---|---|---|
| `outlet-outdoor-a` | `switch.outdoor_outlet_a` | `Kasa_Smart Plug_722C_0` | `8006…F4F40F8` **00** | the socket labelled **"Plug 1"** on the plug body |
| `outlet-outdoor-b` | `switch.outdoor_outlet_b` | `Kasa_Smart Plug_722C_1` | `8006…F4F40F8` **01** | the other socket — **inferred by elimination**, not independently toggled |

**Mind the off-by-one.** TP-Link labels the sockets from **1** and HA numbers
the children from **0**, so the socket marked "Plug 1" is child `_0`. Anyone who
matches the digit in the entity id to the digit on the plastic gets both outlets
backwards, and the mistake is invisible from a desk.

The row for B is honest about its provenance: the unit has exactly two sockets
and A is one of them, so B is the other by arithmetic. That is sound, but it is
not the same evidence as A's, and if a future EP40 ever reports `child_num > 2`
the arithmetic stops holding.

Anchor the mapping to **`unique_id`**, not to the entity id and not to the
friendly name. `unique_id` is what the `tplink` integration derives from the
device's own child index — the trailing `00`/`01` above is that index — and it
is the only one of the three that a rename cannot move (§7.4).

The EP40 was added on its factory alias (`TP-LINK_Smart Plug_722C`), which is
why the ids HA minted for it were the ugly ones. Renaming it in the Kasa app
before commissioning would have produced readable ids; renaming it there now
changes nothing already registered, because HA keeps the entity id assigned at
first registration. The two children have since been renamed the only way that
works — a registry `new_entity_id` update (§7.8) — and the parent device now
reads "Patio Outlet", which is a `name_by_user` on the *device*. Note what that
did and did not do: the parent's friendly name changed, its entity id is still
`switch.tp_link_smart_plug_722c`. It is §7.4's rule sitting in the registry as a
worked example.

### 4.1.6 Entities to expect — and the four to ignore

Live registry, re-read 2026-08-05 (the two children carry their post-rename
ids; everything else is unchanged from 2026-08-04):

| Entity | Bind? |
|---|---|
| `switch.entry_light` | **Yes** — bound to `light-living` (§4.1.1b) |
| `switch.stairs_light` | **Yes** — bound to `light-landing` (§4.1.1b) |
| `switch.tp_link_smart_plug_722c` | **No** — parent, drives both outlets |
| `switch.outdoor_outlet_a` | Yes — socket "Plug 1" (§4.1.5) |
| `switch.outdoor_outlet_b` | Yes — the other socket (§4.1.5) |
| `switch.old_fridge_led` | Never — and the id is stale on purpose (§4.1.1a) |
| `switch.aquarium_led` | Never — likewise |
| `switch.tp_link_smart_plug_722c_led` | Never |
| `binary_sensor.old_fridge_cloud_connection` | Never |
| `binary_sensor.aquarium_cloud_connection` | Never |
| `binary_sensor.tp_link_smart_plug_722c_cloud_connection` | Never |

`switch.*_led` is the little status LED on the plug body. It is a `switch`, it
passes the binding regex, and toggling it does nothing anyone can see from a
sofa — a pin that appears broken.

`binary_sensor.*_cloud_connection` reports whether the plug can reach TP-Link's
servers. It is the opposite of what this house cares about, and it is `on`
today on all three, which would make a bound pin read "fine" during a total LAN
outage.

Note these are **`binary_sensor`**, not `sensor` — the phase-2 plan calls them
"the cloud_connection sensors" and that shorthand will not match a grep.

### 4.1.7 Verify

```bash
curl -s "$HA/api/states" -H "Authorization: Bearer $TOKEN" \
  | jq -r '.[] | select(.entity_id|test("outdoor_outlet|722c|entry_light|stairs_light|old_fridge|aquarium"))
                | "\(.entity_id) = \(.state)"' | sort
```

Expect the eleven rows above, by **name**. Do not check this by counting the
`switch` and `binary_sensor` domains: that number was eleven when the plugs were
the only devices on the Hub and it is **27** as of 2026-08-05, because Ecobee and
Rachio landed since. A count that moves whenever an unrelated integration is
added is not a check — the names are. (Same trap as the `.storage` backup in
Ch. 2 §8, and it caught this chapter too.)

Then, the actual proof — pick an EP40 child (**not** the fridge, **not** the
aquarium, **not** the parent) and:

1. Toggle it from the HA UI. The outdoor plug clicks audibly. **Done
   2026-08-05** — `switch.outdoor_outlet_a` toggles, and the socket it drives is
   the one labelled "Plug 1" (§4.1.5).
2. Toggle it at the plug's physical button. The entity state follows within a
   second or two — that is the `state_changed` round-trip the Panel depends on.
   **Not done** — step 1 was one-way, HA → plug.
3. Unplug the Hub host's WAN. Both directions still work. That is what
   `connectivity: local` is asserting. **Not done.**

---

## 4.2 Ecobee — one thermostat, two integrations, four ways to get it wrong

Hardware: ecobee Smart Thermostat Premium, model `EB-STATE5`, accessory name
**"Main Floor"**, 192.168.68.67, MAC `44:61:32:C4:DD:06`, firmware
`p20.4.8.70710`.

Both integrations are meant to run **simultaneously**: cloud for schedules and
weather; HomeKit for local resilience. **The Panel binds the LOCAL one.**
Local-first is the house rule
([ADR-0002](../../docs/adr/0002-home-assistant-headless-hub.md)); the cloud
entities exist for a future schedules UI and for the outage drill's control
case.

### Status as of 2026-08-04

| Path | State |
|---|---|
| **Local — `homekit_controller`** | **DONE.** Paired locally 2026-08-04. Config entry `homekit_controller` / title **"Main Floor"** / source `zeroconf` / `state: loaded`. Entities in §4.2.6 |
| **Cloud — `ecobee`** | **Not done.** Its branded discovery card is still pending (`handler: ecobee`, source `homekit`, step `user`). Needs ecobee.com user + password + MFA, which is a human at a keyboard — §4.2.3 |

So §4.2.4 below is a **record of what was done**, and remains the instruction
for a *fresh* unit — including the touchscreen-enable path, which a new
thermostat still needs and which nothing in HA can do for you. §4.2.3 is still
pending work.

### 4.2.1 THE DOUBLE-DISCOVERY TRAP — read this before you click anything

**One HomeKit advertisement raises TWO cards in Home Assistant.** They look
almost identical in the UI and they do completely different things.

| Card | `handler` | `source` | What you get |
|---|---|---|---|
| Branded **"ecobee"**, with the ecobee logo | `ecobee` | `homekit` | The **CLOUD** integration. Asks for ecobee.com credentials. `iot_class: cloud_polling`. |
| **"HomeKit Device"** | `homekit_controller` | `zeroconf` | The **LOCAL** integration. Asks for an 8-digit pairing code. `iot_class: local_push`. |

Why it happens: `ecobee/manifest.json` declares
`"homekit": {"models": ["EB", "ecobee*"]}`. HA's HomeKit discovery sees an
accessory whose model matches and offers the *branded* integration as a
convenience — but that integration has no local transport at all. Meanwhile
`homekit_controller` claims every `_hap._tcp` advert unconditionally.

**What goes wrong if you pick the branded card**: you complete a cloud login,
you get a working `climate.*`, everything looks correct, and you write
`connectivity: local` next to it in `bindings.yaml` because the card was raised
by a local mDNS advert. The result is a Panel pin that is labelled local, that
the drift test accepts, that the boot log does not complain about — and that
goes dead the moment the WAN drops. **Nothing downstream catches this.** The
`connectivity` field is operator-asserted; `bindings_parser.dart` validates that
it says `local` or `cloud`, never that it is true.

The same trap applies to the Rachio (§4.3). Use `hactl`'s flow list (§4.0) as
your ground truth: the row you want for a local binding is the one whose handler
is literally `homekit_controller`.

**It is also how you audit a decision after the fact.** A config entry keeps the
`source` of the card it came from, so `config_entries/get` tells you which card
someone clicked months later. On this Hub the `rachio` entry reads
`source: homekit` — proof it came from the branded card, i.e. the cloud path.
Here that was deliberate (§4.3). Read that field before you trust a
`connectivity:` line anyone wrote in `bindings.yaml`.

### 4.2.2 Kill the "same VLAN" troubleshooting myth

If the HomeKit card does not appear, do **not** start rearranging the network.
mDNS is proven healthy on this link. Measured from **inside** the HA container,
**after** the Ecobee was paired and while the Rachio still was not:

```
Rachio-BFF806._hap._tcp.local.  ['192.168.68.71', 'fe80::7274:14ff:febf:f806']
   md=Rachio-BFF806  ci=2  sf=1  id=D3:FC:32:3A:79:5D  c#=19
Main Floor._hap._tcp.local.     ['192.168.68.67', 'fe80::4661:32ff:fec4:dd06']
   md=EB-STATE5  ci=9  sf=0  id=61:CB:0F:63:96:36  c#=46
```

`ci` is the HAP accessory category: `9` is *Thermostat*, `2` is *Bridge*.

`sf` is the HAP **status flag**, and it is a bit field, not a count. Bit 0 set
(`sf=1`) means *"has not been paired with any controller"*; clear (`sf=0`) means
*paired*. Nothing in it says how many pairings an accessory can hold.

**This was demonstrated on this hardware, not read off a spec.** The Ecobee
advertised `sf=1` earlier on 2026-08-04; after the `homekit_controller` pairing
was created it advertises `sf=0`, on the same `id`, from the same address. One
bit flipped when one pairing was made. The Rachio, still unpaired, is unchanged
at `sf=1`.

Three things follow, and they are the reason this subsection exists:

- **`sf=1` is what makes HA raise a `homekit_controller` card at all.** An
  accessory at `sf=0` is announcing that it is not looking for a controller, so
  no pairing card appears. If you are hunting a card for a device you already
  paired, this is why — it is correct behaviour, not a discovery bug.
- **`sf=0` does not mean "no slots left".** The Ecobee at `sf=0` is paired to
  this Hub and working. HAP accessories generally accept multiple controller
  pairings; the flag does not report on that either way.
- **A cloud-to-cloud link is not a HAP pairing.** The Ecobee is linked to Alexa,
  and it still advertised `sf=1` before this Hub paired with it.

Reproduce it (the host has no `zeroconf` module; the container does). Note
there is no `docker cp` and no file left in `/tmp` — `docker exec -i … python3 -`
reads the program from stdin:

```bash
docker exec -i homeassistant python3 - <<'PY'
import time
from zeroconf import Zeroconf, ServiceBrowser
class L:
    def add_service(self, zc, t, n):
        i = zc.get_service_info(t, n, timeout=3000)
        if i:
            p = {k.decode(): v.decode() for k, v in (i.properties or {}).items() if k and v}
            print(n, i.parsed_addresses())
            print("   md=", p.get("md"), " ci=", p.get("ci"), " sf=", p.get("sf"),
                  " id=", p.get("id"), " c#=", p.get("c#"))
    def update_service(self, *a): pass
    def remove_service(self, *a): pass
zc = Zeroconf(); ServiceBrowser(zc, "_hap._tcp.local.", L()); time.sleep(10); zc.close()
PY
```

This is a zeroconf probe, not a WebSocket command, so it is the one place in
this chapter that does not go through `hactl`. `hactl` speaks only to HA's
WebSocket API.

If that prints an accessory at `sf=1` and HA still shows no card, the problem is
in HA's discovery state (dismiss and restart), not in the network.

### 4.2.3 Path A — cloud (`ecobee`)

Keyless since HA 2026.3; this Hub runs 2026.7.4. `single_config_entry: true`,
so there is exactly one `ecobee` entry for the whole house, ever.

The `user` step's form shows **three optional fields**: `api_key`, `username`,
`password`. That is one form serving two mutually exclusive paths, and the code
rejects any mixture:

```python
if api_key and not (username or password):      # legacy developer-key + PIN path
elif username and password and not api_key:     # keyless path — use this
else: errors["base"] = "invalid_auth"
```

Fill in **username and password, and leave `api_key` empty.** Filling all three
fails with a generic `invalid_auth` that looks like a wrong password.

MFA: if the account has it, the flow moves to an `mfa` step asking for a single
`code`, with the challenge type interpolated into the prompt. **The code is
time-boxed** — have the authenticator app open before you submit the password,
because a TOTP that expires mid-flow returns `invalid_mfa_code` and you restart
the login.

Headless — the MFA step is the one place a human is unavoidable:

```bash
FLOW=$(curl -sX POST "$HA/api/config/config_entries/flow" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"handler":"ecobee"}' | jq -r .flow_id)
curl -sX POST "$HA/api/config/config_entries/flow/$FLOW" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"username":"<ecobee.com email>","password":"<password>"}' | jq
# -> step_id "mfa" if required; then, promptly:
curl -sX POST "$HA/api/config/config_entries/flow/$FLOW" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"code":"123456"}' | jq
```

Do not paste real credentials into a file that gets committed. This flow stores
a refresh token in HA's own storage; nothing about it belongs in the repo.

Platforms this entry sets up: `binary_sensor`, `climate`, `humidifier`,
`notify`, `number`, `sensor`, `switch`, `weather`.

### 4.2.4 Path B — local (`homekit_controller`) — DONE 2026-08-04

**This is the path the Panel binds, and on this Hub it is complete.** The entry
exists as `homekit_controller` / "Main Floor" / source `zeroconf` /
`state: loaded`. What follows is both the record of how it was done and the
instruction for a fresh unit.

**The advert must exist before HA can offer the card.** It did (§4.2.2) —
HomeKit had already been enabled on this thermostat. The phase-2 plan's
statement that the ecobee advertises only `_airplay._tcp` and `_raop._tcp` is
**stale**; that was true at the earlier survey and was not true by the time this
was run.

If you are commissioning a *different* ecobee and no `_hap._tcp` advert exists,
enable HomeKit on the touchscreen first. There is no way to do it from HA and
no way to force it over the network. The exact on-screen path is
**UNVERIFIED** — it is roughly Main Menu → Settings → an Apple HomeKit entry —
and it must be read off the operator's own thermostat rather than trusted from
this document. What you are looking for is the screen that displays an
**8-digit setup code in `XXX-XX-XXX` form**; that screen appearing is itself the
confirmation you enabled the right thing.

In HA, take the **"HomeKit Device"** card (`homekit_controller`, source
`zeroconf`, title placeholder `{'name': 'Main Floor', 'category': 'Thermostat'}`)
and enter that code. The flow's own description tells you what it is doing:
*"communicates with {name} ({category}) over the local area network using a
secure encrypted connection without a separate HomeKit Controller or iCloud."*
If the card you are looking at does not say that, you are on the wrong card.

#### The pairing code MUST be dashed — this cost a failed attempt

**Type the code exactly as the thermostat shows it, with the dashes —
`XXX-XX-XXX`. Do not strip them to `XXXXXXXX`.**

Measured on this Hub, 2026-08-04, pairing the Ecobee. The real code is a live
pairing credential for a device on this LAN and is deliberately not written
down here; `123-45-678` below stands in for it. The finding is about the
punctuation, not the digits:

| Submitted | Result |
|---|---|
| `12345678` (8 digits, no dashes) | **The form silently re-showed itself.** No error text, no abort, no `invalid_authentication`. It simply looked like nothing had happened |
| `123-45-678` (same digits, dashed) | `create_entry` — the config entry was created |

The failure is dangerous precisely because it is quiet. A re-shown form with no
message reads as "the network is flaky" or "the code is wrong", and the obvious
next moves — restart the thermostat, re-enter the HomeKit screen, go looking at
VLANs (§4.2.2) — all take you further from the actual cause, which is eight
characters of punctuation. `homekit_controller` validates the code against the
`XXX-XX-XXX` shape before it ever reaches the accessory, so an undashed code
never leaves Home Assistant.

Same rule on the REST path, where there is no form to re-show and you get an
unchanged `"type": "form"` back instead:

```bash
curl -sX POST "$HA/api/config/config_entries/flow/$FLOW" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"pairing_code":"123-45-678"}' | jq
#  -> {"type":"create_entry", ...}          dashed
#  -> {"type":"form","step_id":"pair", ...} undashed — the same quiet nothing
```

If a step returns `"type": "form"` with the same `step_id` you just submitted,
you did not advance. Check the punctuation before you check the network. The
same rule applies to the Rachio in §4.3.3.

Three named failure modes, straight from the integration's strings, worth
recognising before you conclude the network is broken. None of them is what an
undashed code produces — that is the point of the block above:

| Abort/step | Meaning | Fix |
|---|---|---|
| `busy_error` | The accessory is mid-pairing with another controller | Abort pairing everywhere else, or restart the thermostat |
| `max_tries_error` | 100+ failed auth attempts | Restart the thermostat; the counter is on the device |
| `protocol_error` | Accessory not in pairing mode | Re-enter the HomeKit screen on the touchscreen |

The Ecobee showed `sf=1` before pairing, so neither of the first two applied.

### 4.2.5 The entity-id collision — do not identify these by name

Both integrations name the climate entity after the device, and the device is
called "Main Floor" in both. `ecobee/climate.py` sets `_attr_name = None` with
`_attr_has_entity_name = True`; `homekit_controller`'s entity name resolves to
the accessory name. **Both want `climate.main_floor`.**

Whichever is registered first takes it. The other becomes `climate.main_floor_2`.
Which is which depends entirely on the order you commissioned them, and the
entity id is then frozen in the registry forever.

**On this Hub the local one won, because it was commissioned first.** Measured
2026-08-04: `climate.main_floor` belongs to config entry `homekit_controller` /
"Main Floor". So when the cloud entry is finally added (§4.2.3), *its* climate
entity will be the `_2`. That is the lucky ordering — the entity the Panel binds
got the clean id — but do not rely on luck on the next house. Commission the
local path first, deliberately.

So: **never decide which climate entity to bind by reading its name.** Check the
owning integration:

```bash
curl -s "$HA/api/config/config_entries/entry" -H "Authorization: Bearer $TOKEN" \
  | jq -r '.[] | select(.domain=="ecobee" or .domain=="homekit_controller")
           | "\(.domain) | \(.title) | \(.entry_id)"'
```

then match `entry_id` against the entity registry over WebSocket
(`config/entity_registry/list`), or simply hover the entity in the UI and read
which integration it belongs to.

### 4.2.6 Entities to expect, and how to verify

**Measured, not predicted.** The `homekit_controller` entry produced **16**
entities across **two** devices — and the second device is the surprise:

```text
# device: the thermostat itself
climate.main_floor                              off   (hvac_action: idle)
sensor.main_floor_current_temperature           83    <- °F, see below
sensor.main_floor_current_humidity              56.0
binary_sensor.main_floor_motion                 off
binary_sensor.main_floor_occupancy              on
select.main_floor_current_mode                  unknown
select.main_floor_temperature_display_units     celsius
switch.main_floor_airplay_enable                on
switch.main_floor_mute                          off
button.main_floor_clear_hold
button.main_floor_identify

# device: an ecobee SmartSensor, bridged through the SAME local entry
sensor.family_room_temperature                  80.78
sensor.family_room_battery                      100
binary_sensor.family_room_motion                off
binary_sensor.family_room_occupancy             off
button.family_room_identify
```

**Correction to an earlier draft of this chapter:** it said remote room sensors
come only from the cloud entry. They do not. The Ecobee's HAP profile bridges
its SmartSensors, so `family_room_*` arrives over the **local** path, with
battery and occupancy, and survives a WAN outage. Do not add the cloud
integration just to get room sensors — check what the local entry already gave
you first.

What the cloud entry (§4.2.3) would still add on top: a second `climate.*`
(§4.2.5), a `weather.*`, and assorted `switch`/`number`/`humidifier` controls
the local HAP profile does not expose. Measured today with no cloud entry
present: there is **no** `weather.*` entity on this Hub at all.

#### The °F/°C trap — found here, now fixed

`climate.main_floor` reports `current_temperature: 83`. The Hub is
`us_customary`, so that is **83 °F**. The Panel used to do no conversion and
append a `°C` suffix, so this binding would have rendered **`83.0 °C`** on the
wall. Pairing this thermostat is what surfaced it.

**Fixed 2026-08-04**: the Panel now learns the Hub's temperature unit over
`get_config` and carries it with the reading instead of assuming Celsius. See
[`03-home-assistant.md` §3.1](03-home-assistant.md) for the three files. No
change to this Hub's `unit_system` is needed or wanted.

Related, and easy to misread: `select.main_floor_temperature_display_units`
reads `celsius`. That is the **thermostat's own screen**, a HAP characteristic
of the device. It has no effect on what HA reports or on what the Panel renders.

Binding, once the local entity id is known for certain:

```yaml
  thermostat:
    entity: climate.<the homekit_controller one>
    connectivity: local
```

**Verify — the outage drill.** This is the entire reason the dual path exists,
and it is the only test that distinguishes a correct binding from the §4.2.1
mistake:

1. Note both `climate.*` entities' states.
2. Pull the Hub host's WAN (or blackhole `ecobee.com`).
3. Change the setpoint via the **local** entity. It must work.
4. The **cloud** entity must go `unavailable` within its poll interval.
5. Restore connectivity; both recover.

If the entity you intend to bind goes `unavailable` in step 4, you paired the
branded card. Delete that entry and redo §4.2.4.

**Not yet run on this Hub**, because it needs both entries and the cloud one
does not exist yet (§4.2.3). Steps 4 and the whole comparison are what make it
conclusive, so do not record a pass off the half you can run today. The half you
*can* run now is still worth doing once, as a smoke test: pull the WAN and
confirm `climate.main_floor` and the `family_room_*` sensors keep updating. A
local entry that fails *that* is broken outright, and you would rather know
before the drill.

Panel-side note: `panel/test/ha_hub_live_test.dart` asserts
`thermostat.currentC` against a **21.4 seed** from the dev stand-in. Binding a
real Ecobee breaks that test by design — it is not a regression, and it is
addressed in the bindings chapter, not here.

---

## 4.3 Rachio — 5-zone irrigation (new in this chapter)

Hardware: Rachio controller at 192.168.68.71, MAC prefix `70:74:14`, accessory
name `Rachio-BFF806`, **5 zones** (owner-confirmed). It advertises
`_hap._tcp` with `ci=2` (Bridge) and `sf=1` (unpaired) — verified 2026-08-04,
same command as §4.2.2.

### Status as of 2026-08-04

| Path | State |
|---|---|
| **Cloud — `rachio`** | **DONE.** Config entry `rachio` / title `den.morozov@gmail.com` / source `homekit` / `state: loaded`. 5 zone switches plus standby, rain delay, one schedule switch, and two binary sensors — all listed in §4.3.4 |
| **Local — `homekit_controller` (Bridge)** | **Not done.** Its card is still pending (`handler: homekit_controller`, `category: Bridge`, step `pair`) and the accessory still advertises `sf=1`. Needs the HomeKit setup code off the hardware — §4.3.3 |

**Zone-run duration (owner item E4): DONE 2026-08-04.** `manual_run_mins` is now
**5**; the code default it replaced is **10**. Recorded in §4.3.2. It changes what
a mis-tap costs and *nothing else* — in particular it does not touch the Rachio
app's schedule, which is the confusion §4.3.7 exists to clear up.

**Also new 2026-08-04:** two Home Assistant scripts, `hub/ha-config/scripts.yaml`
— un-ignored in git so it *can* be committed, but not committed yet (§4.3.9).
Neither has ever been run.

**Owner decision: the Rachio gets both, like the Ecobee.** The local bridge is
not a replacement for the cloud entry (see below) and the cloud entry is not
resilient. Do not dismiss the pending card.

Note the cloud entry's `source: homekit` — that entry was created from the
*branded* card raised by the HomeKit advert, which is the cloud integration.
Here that was the intent. §4.2.1 is about what happens when it is not.

### 4.3.1 The same two-card trap applies here

`rachio/manifest.json` declares `"homekit": {"models": ["Rachio"]}`, so exactly
as with the Ecobee, one `Rachio-BFF806._hap._tcp.local.` advert raises two
cards. **Recorded observation, 2026-08-04, before either was completed:**

```
rachio             | homekit  | None                                            | user
homekit_controller | zeroconf | {'name': 'Rachio-BFF806', 'category': 'Bridge'} | pair
```

The branded `rachio` card is `iot_class: cloud_push`. The `homekit_controller`
card is the local one. §4.2.1 applies verbatim.

Completing the cloud path consumed the first row. What `hactl` shows now is the
second row alone, still at step `pair` — which is the §4.0 listing. A single row
is not evidence that the trap was imaginary; it is evidence that one of the two
flows was answered.

Unlike the Ecobee, the Rachio's local HAP profile is a **Bridge** — it exposes
the zones as valve accessories and does not carry the schedules, rain delay,
flow sensing or calendar that the cloud integration provides. If you want those,
the cloud entry is not optional. That asymmetry is why the Ecobee's local entry
could plausibly have stood alone (§4.2.6 — it even brings the room sensors) and
the Rachio's cannot.

### 4.3.2 Path A — cloud API key — DONE 2026-08-04

The entry exists and is loaded; this is the record of how, and the instruction
for the next controller.

From HA's own `rachio/strings.json`, `config.step.user.description`, verbatim:

> "You will need the API key from {api_key_url}. Go to Settings, then select
> 'GET API KEY'."

and `config_flow.py` line 97 fills that placeholder with:

```python
"api_key_url": "https://app.rach.io/",
```

So the path is **`https://app.rach.io/` → Settings → "GET API KEY"**. That
wording is quoted from the integration, not from memory of the Rachio web app,
and the single `user` step takes exactly one field, `api_key`.

```bash
FLOW=$(curl -sX POST "$HA/api/config/config_entries/flow" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"handler":"rachio"}' | jq -r .flow_id)
curl -sX POST "$HA/api/config/config_entries/flow/$FLOW" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"api_key":"<key from app.rach.io>"}' | jq
```

The integration is `cloud_push` and depends on `http` — it registers a webhook
so Rachio's cloud can push zone-start events back. That webhook needs a
reachable external URL to be genuinely push; without one it degrades to polling.
Whether an external URL is configured on this Hub is **UNVERIFIED** and is a
question for the cloud-fleet chapter, not this one.

#### The zone-run duration — owner item E4, DONE 2026-08-04

One option is worth setting once the entry exists: *"Duration in minutes to run
when activating a zone switch"*. It is stored as `manual_run_mins` in the config
entry's `options`, and it is the knob that decides what a mis-tap costs in water.

It is now set. Measured from the entry itself, not from the UI:

```bash
jq '.data.entries[] | select(.domain=="rachio") | .options' \
  hub/ha-config/.storage/core.config_entries
# -> {"manual_run_mins": 5}
#    It was {} — meaning nothing had ever been set and the code default applied.
```

The default it replaced, read out of the running image rather than remembered:

```python
# homeassistant/components/rachio/const.py — HA 2026.7
CONF_MANUAL_RUN_MINS = "manual_run_mins"
DEFAULT_MANUAL_RUN_MINS = 10
```

`switch.py` reads it as `.get(CONF_MANUAL_RUN_MINS, DEFAULT_MANUAL_RUN_MINS)` at
exactly two call sites, and both are a `turn_on`. So **a tap on a zone switch now
runs that zone for 5 minutes, where yesterday it ran for 10.** The cost of an
accident is halved, and it is a number instead of the word "short".

Why 5 rather than 2 or 15: this value only ever governs an *accident* or a quick
hand check, never a real watering run. A real run comes from the schedule or from
the script in §4.3.9, and both of those carry their own per-zone times — so a
long value here would make mis-taps expensive without making any deliberate run
better. Shorter than that gets its own problem: two minutes is not long enough to
walk out to a sprinkler head and watch whether water is actually coming out,
which is the one legitimate use for a manual tap and is exactly what A5 (§4.3.5)
is about to do.

**What this option cannot do is change the Rachio app's schedule.** That was the
owner's question and it deserves a straight answer, so it has its own section:
§4.3.7.

### 4.3.3 Path B — local HomeKit bridge — STILL PENDING

The bridge still advertises `sf=1`, so it is still offering itself for pairing
and its card is still open. Same `homekit_controller` flow as §4.2.4: take the
**"HomeKit Device"** card whose title placeholder is
`{'name': 'Rachio-BFF806', 'category': 'Bridge'}` and enter the 8-digit
`XXX-XX-XXX` setup code.

**Type it dashed.** The undashed form fails silently — the form simply
re-appears with no error. That cost a failed attempt on the Ecobee; the finding
and the evidence are in §4.2.4, and this is the next flow it will bite.

**Where that code is printed is UNVERIFIED.** For HomeKit accessories generally
it is on the device body or its packaging, next to a small house icon — that is
what the pairing form's own text says. Whether this particular controller prints
it on the unit, shows it in the Rachio app, or only shipped it on the box is not
something this document can tell you; read it off the operator's own hardware.
This is the one thing blocking the path, and it is hands-on-hardware work, not
HA work.

If it is genuinely lost, the cloud path (§4.3.2) still works — and on this Hub
it is already working — so the consequence is confined to losing local
resilience for the zones, not losing irrigation control. Recovering it would
mean a factory reset of the controller, which would also invalidate the cloud
entry's view of it. Do not reach for that to fix a missing sticker.

### 4.3.4 Entities to expect

**Measured 2026-08-04.** The cloud entry produced exactly **10** entities. The
device is named `Rachio-DK`, which is where the `rachio_dk_` prefix comes from —
it is the controller's name in the Rachio account, not anything HA chose:

```text
switch.rachio_dk_backyard_garden            off    zone 1
switch.rachio_dk_front_yard_grass_side      off    zone 2
switch.rachio_dk_front_yard_grass_main      off    zone 3
switch.rachio_dk_backyard_perimeter         off    zone 4
switch.rachio_dk_front_yard_camelias        off    zone 5
switch.rachio_dk_standby                    off
switch.rachio_dk_rain_delay                 unknown
switch.rachio_dk_normal_schedule_schedule   off
binary_sensor.rachio_dk_rain                off
binary_sensor.rachio_dk_connectivity        on
```

**The zone numbers are not in entity-id order and not in any order you would
guess** — `backyard_perimeter` is zone 4, sitting between the two front-yard
grass zones. They come from the controller's physical terminal wiring. Read them
with the query in §4.3.5; never infer a zone number from a name.

Five zone switches, as the owner said. Reconciled against the source
(`rachio/switch.py`, `binary_sensor.py`, `calendar.py`, `strings.json`):

| Platform | Entity | Notes |
|---|---|---|
| `switch` | one per **zone** | `_attr_name` is the zone name; unique id `{controller}-zone-{id}`. **5 here.** Attributes carry zone number, shade, crop type, slope |
| `switch` | Standby | `translation_key: standby`; disables the whole controller |
| `switch` | Rain delay | `translation_key: rain_delay`. Sits at `unknown` until one is set — not a fault |
| `switch` | one per **schedule** | named `"<schedule> Schedule"`, hence the doubled word in `..._normal_schedule_schedule`. One schedule exists here |
| `binary_sensor` | Rain, Connectivity | The predicted "Flow" sensor **did not appear** — no flow hardware on this controller |
| `calendar` | `Rachio Base Station {base}` | **None appeared.** There is no base station here, which the source says is the condition |

There is also a `RachioValve` class for Smart Hose Timer hardware. This house
has none, and no valve entities appeared — confirmed.

From the local HomeKit bridge, once §4.3.3 is done: the zones as switch/valve
entities and nothing else. No standby, no rain delay, no schedule, no rain
sensor. **Expect an entity-id collision** exactly as in §4.2.5 — the local zone
entities will land as `_2` variants, because the cloud entry registered first
and holds these ids. Check the owning config entry, never the name.

### 4.3.5 Verify

```bash
curl -s "$HA/api/states" -H "Authorization: Bearer $TOKEN" \
  | jq -r '.[] | select(.attributes["Zone number"] != null)
           | "\(.entity_id) zone \(.attributes["Zone number"]) = \(.state)"'
```

Note the attribute key: it is literally **`Zone number`**, capitalised and
space-separated, not `zone_number`. An earlier draft of this chapter used
`zone_number` and it matches nothing. Measured shape of one zone's attributes:

```json
{"Zone number": 3, "Summary": "", "Shade": "LOTS_OF_SUN",
 "Type": "Warm Season Grass", "Slope": "Flat",
 "friendly_name": "Rachio-DK Front yard Grass  / Main"}
```

Five rows, zone numbers 1–5, matching the zone names in the Rachio app. Then
turn one zone switch on and confirm at the sprinkler head that water actually
runs, and that it stops after the configured duration — **5 minutes** now that
E4 is done (§4.3.2). **Not yet done** — this is owner item A5, and it wants
someone outside, at a time when a running zone is not a problem.

#### The panic button, before you tap anything

**`switch.turn_off` on ANY Rachio zone stops the WHOLE controller.** Not that
zone — the controller. Every zone switch *and* the schedule switch route
`turn_off` to the same call:

```python
# homeassistant/components/rachio/switch.py — RachioZone and RachioSchedule both
def turn_off(self, **kwargs: Any) -> None:
    """Stop watering all zones."""
    self._controller.stop_watering()     # -> rachio.device.stop_water(controller)
```

In most integrations that would be a bug report. Here it is the property you
want while standing outside: if the zone you started turns out to be aimed at an
open window, turning off *whichever* zone switch is already under your thumb
stops the water. You do not have to find the right one, and there is no wrong one.

Three ways to say the same thing, in the order you will actually reach for them:

| Reach for | Why |
|---|---|
| `switch.turn_off` on any zone | Nearest to hand. The Panel tap, once there is a pin (§4.3.6) |
| `script.rachio_stop_all_watering` | §4.3.9. Identical call, but findable by name in a hurry |
| `rachio.stop_watering` with no `devices:` | Defaults to every controller on the account — here, the one |

Two more findings from the same reading, both of which matter with water on the
ground:

- **Turning a zone ON stops everything first.** `RachioZone.turn_on` calls
  `self.turn_off()` before starting its own zone. Tapping zone 3 during a
  schedule run does not *add* zone 3 — it cancels the run and waters zone 3
  alone for `manual_run_mins`. Convenient for a hand check, destructive if you
  thought you were adding to a cycle.
- **`switch.rachio_dk_standby` is inverted, and is not a stop button.** Standby's
  `turn_on` puts the controller into standby (`rachio.device.turn_off(...)`) and
  its `turn_off` *resumes* it. So "turn off the standby switch" is the opposite of
  stopping — and standby governs future schedules, not water already running.
  Reach for a zone, never for standby.

### 4.3.6 There is no Panel Key for this yet

`panel/assets/house/house.yaml` has 33 Keys and **not one of them is a sprinkler
or irrigation Key**. Under
[ADR-0005](../../docs/adr/0005-devices-authored-in-the-drawing.md) a new Key is
authored in the drawing — a Sweet Home 3D session on the Mac, then
`tool/sh3d_to_yaml.py`, then `dart run tool/gen_dev_entities.dart`. **It is not a
`bindings.yaml` edit**, and `bindings_parser.dart` enforces that: the Key sets in
`house.yaml` and `bindings.yaml` must match exactly in both directions, fatal at
boot.

So Rachio *pinning* ends at the Hub for now. The entities exist and are correct;
the Panel gains pins for them in a later drawing session. The three sections
below are about operating what already exists.

### 4.3.7 Three ways to run water — and only one uses `manual_run_mins`

§4.3.4 lists the entities without saying what they *do*, and the paths differ
enough that picking the wrong one is a watering decision, not a trivia question.
Read out of `switch.py` and `device.py` in the running image, 2026-08-04.

| # | What you do | What Rachio is asked to do | Per-zone times come from | Rain skip / seasonal shift | Uses `manual_run_mins`? |
|---|---|---|---|---|---|
| 1 | Turn ON `switch.rachio_dk_normal_schedule_schedule` | `schedulerule.start(<rule id>)` — Rachio runs it **server-side** | **The app's own schedule**, held in Rachio's cloud | **Yes.** Weather intelligence, rain skip and seasonal shift all apply | **No** |
| 2 | `rachio.start_multiple_zone_schedule` on a list of zone switches | `zone.start_multiple([...])` — zones in sequence | **The literal minutes you passed** in `duration:` | **No.** It waters exactly what you asked for | **No** |
| 3 | Turn ON **one** zone switch | `zone.start(zone_id, secs)` | **`manual_run_mins`** — 5 (§4.3.2) | **No** | **Yes — this and only this** |

There is no fourth path. `rachio.start_watering` looks like one and is not: it is
registered as an *entity* service bound to `turn_on` with an optional `duration:`,
so on a zone switch it is row 3 with a one-off override, and on the schedule
switch it is row 1 with the `duration:` **silently ignored**. Stopping any of the
three is the same call, and it is the panic button in §4.3.5.

#### E4 cannot alter the schedule in the Rachio app

This is the thing to be unmistakable about. Rows 1 and 2 never read the option:

```python
# RachioSchedule.turn_on — one argument, the rule id. No duration crosses the wire.
self._controller.rachio.schedulerule.start(self._schedule_id)

# the start_multiple service handler — minutes come from the CALL, nowhere else
time = int(next(duration, default_time)) * 60
zones_list.append({ATTR_ID: ..., ATTR_DURATION: time, ATTR_SORT_ORDER: count})

# RachioZone.turn_on — the ONLY place manual_run_mins reaches water
manual_run_time = timedelta(minutes=self._person.config_entry.options.get(
    CONF_MANUAL_RUN_MINS, DEFAULT_MANUAL_RUN_MINS))
self._controller.rachio.zone.start(self.zone_id, manual_run_time.seconds)
```

`grep -n MANUAL_RUN_MINS switch.py` returns four lines: two imports, and two
`.get(CONF_MANUAL_RUN_MINS, DEFAULT_MANUAL_RUN_MINS)` reads. Both reads sit
inside a `turn_on` — `RachioZone` and `RachioValve` (hose timers, none on this
account). The schedule never sees it. **Setting `manual_run_mins` to 5 did not shorten the evening
watering, did not overwrite the app's per-zone times, and cannot.** The schedule
lives in Rachio's cloud (§4.3.8); Home Assistant only ever asks it to start.

The inverse is worth stating too: **row 2 cannot be made to track the app.** The
integration exposes no per-zone schedule durations to a template — the schedule
switch carries a rounded *total* and nothing else (§4.3.8), and the zone
attributes carry `Zone number`, `Shade`, `Type`, `Slope` and no duration at all.
That is the whole reason §4.3.9's script is a hand-maintained copy.

#### The positional-duration trap

`duration:` maps **positionally** onto `entity_id:`, and a short list does not
error. `default_time = service.data[ATTR_DURATION][0]`, then
`next(duration, default_time)` — so once the list runs out every remaining zone
gets the **first** value, not the last:

- `duration: [19, 8, 7, 16, 5]` on five zones — one each, as intended.
- `duration: 19` on five zones — all five for 19 minutes. This is the documented
  "one time for all zones" convenience (`cv.ensure_list_csv` makes the scalar a
  list), and it is fine.
- `duration: [19, 8]` on five zones — 19, 8, **19, 19, 19**. Silently. On this
  house that is 84 minutes of water instead of 27, and nothing warns you.

Reorder one list without the other and you water the wrong zone for the wrong
time. There is no zone id in the mapping to protect you, which is why §4.3.9's
script carries a `# zone N` comment on every single line.

#### What is actually registered on this Hub

Measured live, `GET /api/services`, 2026-08-04 — five services, not six:

```text
rachio.start_watering                 entity service -> turn_on, optional duration
rachio.start_multiple_zone_schedule   entity_id list + positional duration list
rachio.stop_watering                  optional `devices:`; omitted = all controllers
rachio.pause_watering                 optional `devices:`, duration 1–60 min
rachio.resume_watering                optional `devices:`
```

**`rachio.set_zone_moisture_percent` does not exist here**, and a doc that lists
it is wrong about this house. `switch.py` registers it only `if has_flex_sched`,
and the controller reports `flexScheduleRules: 0` — the one rule is a fixed
schedule. Correspondingly, `pause_watering` and `resume_watering` *do* exist only
because the controller is not a Generation 1 (`can_pause` is set by
`model.split("_")[0] != MODEL_GENERATION_1`, and this one is `GENERATION3_16ZONE`).
Both facts are properties of *this* hardware and this account. Re-read the list
after any controller change rather than trusting this block.

#### Which one the Panel should eventually tap

Not decided here — the Panel has no irrigation Key yet (§4.3.6) — but the
reading points one way. Row 3 on a single zone is what a tap on an `outlet`-like
pin would do, and ADR-0006's single-tap togglability is exactly what makes that
risky for irrigation. Row 1 is the safe default for a wall control: it is the
button that means "water the garden the way the app says", weather logic
included. That belongs in the F2 discussion, with this section as its input.

### 4.3.8 The schedule itself, as Rachio's cloud holds it

**Measured 2026-08-04** by reading the vendor API directly. This is recorded so
the next reader can tell whether §4.3.9's hand-copied durations have drifted —
and re-read it themselves rather than trusting this table.

Controller `Rachio-DK`, model **`GENERATION3_16ZONE`**, status `ONLINE`. Note the
model: **16 terminals, 5 of them enabled.** "5 zones" throughout this chapter
means five *enabled* zones on a sixteen-zone controller, not a five-zone unit —
which matters the day someone wires a sixth. The API returns all 16; HA creates
switches only for the enabled ones, which is why §4.3.4 counts five.

One schedule rule, enabled, summary *"Every day at sunset"*, and it lives in
`scheduleRules` rather than `flexScheduleRules`, which is what makes HA report
its `Type` as `FIXED`.

**The rule's name is `"Normal Schedule "` — the character before the closing
quote is a space.** That is not a typo in this document. It propagates: HA names
the schedule switch `"<rule name> Schedule"`, so the friendly name comes out as
`Rachio-DK Normal Schedule  Schedule` with a **doubled space**, and the slug
collapses to the doubled-word `switch.rachio_dk_normal_schedule_schedule` of
§4.3.4. So the odd-looking entity id has two separate causes stacked on it — the
integration appending the word "Schedule", and a stray space in the rule name.
Renaming the rule in the app to tidy it would change the friendly name and every
label derived from it; the entity id would *not* follow, because the unique id is
`{controller}-schedule-{rule id}` and the id is already registered. Cosmetic fix,
real churn — leave it. The same class of thing is already visible in zone 3's
name, `Front yard Grass  / Main`, which also carries a double space (§4.3.5).

| Run order | Zone | Name as the app holds it | Seconds | Minutes |
|---|---|---|---|---|
| 1 | 1 | Backyard Garden | 1153 | 19.22 |
| 2 | 2 | Front yard Grass / Side | 480 | 8.00 |
| 3 | 3 | Front yard Grass  / Main | 420 | 7.00 |
| 4 | 4 | Backyard Perimeter | 1008 | 16.80 |
| 5 | 5 | Front yard Camelias | 300 | 5.00 |
| | | **total** | **3361** | **56.02** |

#### 55 or 56 — both, and here is why

Neither number is wrong, so this document states both rather than picking one:

- **55 minutes** — truncate each zone to whole minutes and add: 19+8+7+16+5.
- **56 minutes** — add the raw seconds and divide: 3361 / 60 = 56.02.

They disagree because two zones are not whole minutes: zone 1 is 19 min 13 s and
zone 4 is **16 min 48 s**, which is where the tempting "16" comes from — it is a
truncation, not a rounding, and the honest round is 17. Home Assistant shows the
second number, because the integration rounds the total. Measured attributes of
`switch.rachio_dk_normal_schedule_schedule`:

```json
{"Summary": "Every day at sunset", "Enabled": true,
 "Duration": "56 minutes", "Type": "FIXED",
 "friendly_name": "Rachio-DK Normal Schedule  Schedule"}
```

That attribute is `f"{round(self._duration / 60)} minutes"` and it is the **only**
schedule timing HA exposes — a total, never the per-zone split. Hence §4.3.9.

The practical consequence: §4.3.9's script asks for the truncated 55 minutes, so
it runs **61 seconds short** of the app's schedule, spread across zones 1 and 4.
Irrelevant for irrigation, worth writing down so the next reader does not go
hunting a discrepancy that is arithmetic rather than drift.

#### Re-reading it — read-only, and without pasting a key

Every call below is a `GET`. The same API has `POST` endpoints that start water;
do not improvise near them, and see the constraint in §4.3.9 about not running
anything that waters the garden.

```bash
# The key comes from the config entry. Never paste an API key into a shell —
# it lands in shell history, and there is already a copy on this disk.
KEY=$(jq -r '.data.entries[] | select(.domain=="rachio") | .data.api_key' \
        hub/ha-config/.storage/core.config_entries)

PERSON=$(curl -s -H "Authorization: Bearer $KEY" \
        https://api.rach.io/1/public/person/info | jq -r .id)

curl -s -H "Authorization: Bearer $KEY" \
     "https://api.rach.io/1/public/person/$PERSON" > /tmp/rachio.json

# the controller
jq -r '.devices[] | "\(.name) \(.model) \(.status) — \(.zones|length) terminals"' \
   /tmp/rachio.json

# enabled zones only — a 16-zone controller reports all 16
jq -r '.devices[].zones[] | select(.enabled) | "\(.zoneNumber)\t\(.name)"' \
   /tmp/rachio.json | sort -n

# the schedule, per zone, in run order
jq -r '(.devices[].zones | map({key: .id, value: {n: .zoneNumber, nm: .name}})
        | from_entries) as $z
       | .devices[].scheduleRules[]
       | "\(.name) enabled=\(.enabled) total=\(.totalDuration)s",
         (.zones[] | "  \(.sortOrder)  zone \($z[.zoneId].n)  \($z[.zoneId].nm)  \(.duration)s")' \
   /tmp/rachio.json
```

Two cautions, both about the file that lands in `/tmp`:

- **`shred -u /tmp/rachio.json` when you are done.** That payload is the whole
  account tree — `email`, `fullName`, and per device `serialNumber`, `macAddress`,
  `latitude` and `longitude`. It is not a config dump, it is the house's address.
- **`.storage/core.config_entries` holds the API key in plaintext and is mode
  `644`,** so any local account can read it. That is HA's own layout and not
  something this chapter changes, but it belongs on the list the hardening pass
  looks at, alongside the other credential-at-rest items.

### 4.3.9 Two Home Assistant scripts — new 2026-08-04

Created this session, and **neither has ever been executed** —
`last_triggered: null` on both, verified. That is deliberate: running either one
waters the garden, and A5 (§4.3.5) is the first deliberate water event.

| Entity | What it does |
|---|---|
| `script.rachio_run_normal_schedule_now` | Row 2 of §4.3.7 — all five zones in sequence, `[19, 8, 7, 16, 5]` minutes, no rain skip |
| `script.rachio_stop_all_watering` | The panic button of §4.3.5, given a findable name |

#### Where they live, and why that is tracked

`hub/ha-config/scripts.yaml`, **exempted from the ignore rules so git can see
it**, via a new negation in `hub/.gitignore` sitting directly alongside the one
that already exempts `automations.yaml`:

```gitignore
ha-config/*
!ha-config/configuration.yaml
!ha-config/automations.yaml
!ha-config/scripts.yaml
```

Verify with `git check-ignore -v hub/ha-config/scripts.yaml` — it should report
the **negation** line as the matching rule, which is git's way of saying "not
ignored". As of 2026-08-04 the file is un-ignored and still shows as `??` in
`git status`; it has not been committed yet.

Same reasoning as `automations.yaml`: this is configuration, not runtime state,
and it holds no secrets. The alternative — leaving it inside the blanket
`ha-config/*` ignore with everything else — was rejected because the HA UI writes
*back* to this file when somebody edits a script from the wall, and `git diff` is
then the only record that they did. An untracked scripts.yaml is a file that
changes silently.

#### Restart once, reload thereafter

`hub/ha-config/configuration.yaml` gained one line:

```yaml
script: !include scripts.yaml
```

**Adding that line required a full Home Assistant restart** — it sets up an
integration that was not previously loaded, and no reload service can conjure
one. Every *subsequent* edit to `scripts.yaml` needs only the `script.reload`
action. Worth knowing which one you are about to need: a restart on this Hub
drops the WebSocket the Panel is holding, a reload does not.

Validate before restarting, not after, because a syntax error in an `!include`
leaves HA refusing to start with the Panel already dark:

```bash
docker exec homeassistant \
  python3 -m homeassistant --script check_config -c /config
```

#### The durations are a COPY, and they do not follow the app

This is the one real cost of the script and the thing most likely to be wrong in
a year. `[19, 8, 7, 16, 5]` was read off the Rachio API on 2026-08-04 (§4.3.8) and
**transcribed**. Re-time the schedule in the Rachio app and this file does not
notice; it will happily keep watering yesterday's times.

Deriving it live was the obvious alternative and it is not available.
`start_multiple_zone_schedule` takes literal minutes, and there is no template
that can read a schedule rule back out of the integration — the only timing HA
publishes is the schedule switch's rounded **total** (§4.3.8), which cannot be
split back into five numbers. So the choice was a hand-maintained copy with its
provenance written down in the file, or no such script at all.

If you re-time the schedule: change it in the app, then re-run the §4.3.8 probe,
then update both the `duration:` list **and** the comment block in
`scripts.yaml` that records where the numbers came from. The comment is what
tells the next reader these are transcribed rather than invented.

Note also that the script's 55 minutes is the truncated sum, 61 seconds short of
the app's 56.02 — §4.3.8 explains why, and it is arithmetic, not drift.

#### Why the script exists at all, given the schedule switch

Because it is a different behaviour, not a shortcut to the same one. The schedule
switch (row 1) asks Rachio to run the rule and lets Rachio apply rain skip and
seasonal shift — right for the everyday case, and the right thing to leave bound
to that switch. The script (row 2) asks for the zones, in order, for exactly those
minutes, with no skip logic: the "water it now, I have looked outside myself"
button — after a repair, before guests, or when Rachio skipped a cycle you wanted.
Keep both. Collapsing them into one would lose whichever behaviour was not chosen.

---

## 4.4 Tesla Wall Connector — the commissioning procedure, and why this unit is blocked

The phase-2 plan lists this as a five-minute local integration. For *this* unit it is
not: the thing at 192.168.68.52 serves no HTTP at all. But "blocked" was the wrong
place to stop writing. The block is **at the hardware**, it is clearable by the owner
in about fifteen minutes standing at the charger, and §4.4.4 onwards is the procedure
to clear it and finish the integration — not a note that it exists.

Read §4.4.1 first. It answers the question that was actually asked, and the answer
changes what you should go and do.

### 4.4.1 Is the local API opt-in? No. Answering the owner's question

**Hypothesis put by the owner: "it might not be enabled by default." Tested against
the sources below: NOT SUPPORTED.** There is no opt-in, no toggle, no developer mode,
no token and no pairing step. A Gen 3 Wall Connector that has finished commissioning
and joined a 2.4 GHz network serves `/api/1/*` over **plain HTTP on port 80,
unauthenticated**, to anything on the LAN.

**Confidence: high** that no user-facing enablement setting exists. **Confidence:
medium-high** that the API is served unconditionally once the unit is commissioned —
that part is an inference from six sources that all behave as if it is true and none
of which mentions a precondition, rather than from a Tesla statement saying so in as
many words. Tesla publishes no local-API documentation at all.

The evidence, in descending order of how much it would have cost the author to be
wrong:

1. **Home Assistant's config flow validates a host by calling the API and nothing
   else.** [`config_flow.py`](https://github.com/home-assistant/core/blob/dev/homeassistant/components/tesla_wall_connector/config_flow.py)
   does one thing: construct a `WallConnector(host=…)` and `await
   wall_connector.async_get_version()`. If enablement were a step, this flow would
   have to ask about it. It takes a hostname.
2. **The pinned client library speaks unauthenticated HTTP.**
   [`tesla_wall_connector/api.py`](https://github.com/einarhauks/tesla-wall-connector/blob/main/tesla_wall_connector/api.py)
   builds every request as `f"http://{self.host}/api/1/{endpoint}"`. There is no
   credential, no header, no TLS and no handshake anywhere in the package.
3. **evcc does the same, independently.**
   [`charger/twc3.go`](https://github.com/evcc-io/evcc/blob/master/charger/twc3.go)
   issues a bare `GET {uri}/api/1/vitals` and parses it. Two unrelated projects
   converged on "just ask it".
4. **No firmware release has ever gated it.** Wall Monitor tracks every Gen 3
   firmware build since the 21.x series
   ([release notes](https://wallmonitor.app/app/firmware-release-notes)). Across the
   whole tracked history the only API change is an *addition* — 24.12.51 (2024-04-27)
   added `git_branch` to `/api/1/version` and `evse_not_ready_reasons` to
   `/api/1/vitals`. Nothing removes, restricts or gates the endpoints.
5. **Home Assistant's own integration page names no prerequisite** beyond "a Gen 3
   Tesla Wall Connector with Wi-Fi"
   ([docs](https://www.home-assistant.io/integrations/tesla_wall_connector/)).
6. **Tesla's commissioning material configures three things** — circuit-breaker size,
   Wi-Fi, and group power management
   ([Commissioning Procedure](https://energylibrary.tesla.com/docs/Public/Charging/WallConnector/Gen3/Install/UniversalWC/en-us/GUID-113D0CEF-00D6-45BC-B71B-18D38EF157A8.html)).
   No published Tesla setting mentions a local API, "local access", or an HTTP server.

**One piece of counter-evidence, examined and rejected.** Wall Monitor's
[communication-errors page](https://wallmonitor.app/faq/troubleshooting) lists *"did
not allow local access"* as a cause of failure. That is the **phone's** iOS
local-network permission prompt, not a setting on the Wall Connector. It is about the
client, not the charger.

**What is genuinely conditional**, and must not be confused with the above: the Wall
Connector **associates only with 2.4 GHz networks**
([Tesla](https://energylibrary.tesla.com/docs/Public/Charging/WallConnector/Gen3/Install/UniversalWC/en-us/GUID-113D0CEF-00D6-45BC-B71B-18D38EF157A8.html)).
Wi-Fi association is the gate. The API is not.

**So the correct reading of this unit is not "the API is switched off."** It is one
of: the application firmware is not running, commissioning never completed, or the
device at .52 is not a commissioned Wall Connector. All three are addressed by the
same procedure, and all three are cleared at the hardware.

### 4.4.2 As found — measured 2026-08-04

Preserved as a dated record. Re-measure with §4.4.5 before trusting any of it.

| Probe | Result on 2026-08-04 |
|---|---|
| ICMP to 192.168.68.52 | **Alive.** 3/3, ~40–112 ms RTT (a re-probe the same day measured ~70 ms) |
| TCP 80 / 443 / 8080 / 4070 / 8443 | **RST — connection refused, not filtered** |
| TCP 1–10000, full sweep, 15 passes over 75 s | Every port refused |
| MAC | `08:d1:f9:80:37:f0` — Espressif OUI |
| mDNS | `PROV_8037F0F._smartenergy._tcp.local.` → `192.168.68.52`, TXT `wifi_connected=true`, `eth_connected=false`, `id=F2344A001A08D1F98037F0` |
| mDNS, 12 s browse, most recent | Answered only the `_services._dns-sd._udp` enumeration — **did not** re-answer the `_smartenergy` record |

Two things follow, and only two:

**RST is the load-bearing observation.** A firewall drops; a host with no listener
resets. Something is running the IP stack at .52 and nothing is listening above it.
That rules out network policy as the cause and rules *in* "the HTTP server is not
running".

**The identity of .52 is not established.** The MAC prefix `08:D1:F9` is Espressif's,
and the Gen 3 is an ESP32 design, so that is *consistent* with a Wall Connector — but
it is **not** one of the three Tesla-registered prefixes the integration matches on
(`DC44271*`, `98ED5C*`, `4CFCAA*`, from
[`manifest.json`](https://github.com/home-assistant/core/blob/dev/homeassistant/components/tesla_wall_connector/manifest.json)).
Nothing measured so far proves this is the Wall Connector rather than some other
ESP32 device on the LAN. **Step 0 of §4.4.4 settles it before anyone opens a
breaker panel.**

### 4.4.3 What `PROV_` tells you, and what it does not

The earlier draft of this chapter read the `PROV_` advert as proof that
"commissioning got halfway and stopped". That conclusion is **overstated** and is
corrected here.

- **`PROV_` is Espressif's naming convention, not a state flag.** ESP-IDF's Wi-Fi
  provisioning manager names its SoftAP/service `PROV_` + a MAC-derived suffix
  ([ESP-IDF Wi-Fi Provisioning](https://docs.espressif.com/projects/esp-idf/en/v4.4/esp32/api-reference/provisioning/wifi_provisioning.html)).
- **This is not the stock provisioning advert.** ESP-IDF's provisioning manager
  advertises mDNS service type **`_esp_wifi_prov._tcp`**. This unit advertises
  **`_smartenergy._tcp`** — a different, vendor-chosen type that has merely borrowed
  the `PROV_` name convention. **Whether `_smartenergy._tcp` is Tesla's is
  UNVERIFIED**; no public source tying that service type to Tesla was found.
- **The advert can persist after provisioning succeeds.** ESP-IDF's API will start
  the provisioning service *even when the device is already provisioned*
  (`wifi_prov_mgr_is_provisioned()` returning true), and the mDNS record lives until
  the application explicitly stops the manager. A `PROV_` record coexisting with
  `wifi_connected=true` is therefore **consistent with normal idle behaviour of
  firmware that never tears the service down** — it is not, on its own, evidence of a
  failed setup.
- **Home Assistant never looks at mDNS for this device.** The manifest declares
  `dhcp` matchers only; there is no `zeroconf` block. So the presence or absence of
  any mDNS record has zero bearing on whether HA can integrate the unit. It is a clue
  for humans, not a dependency.

**Practical consequence:** do not use the `PROV_` record as a pass/fail signal. The
only signal that matters is whether `GET /api/1/version` returns JSON (§4.4.5). Keep
browsing for the record anyway — it is a cheap way to tell "the device is alive and
its Wi-Fi stack is up" from "it fell off the network" — but stop treating it as the
diagnosis.

### 4.4.4 Commissioning at the hardware — the walkthrough

Hands-on-hardware work, the owner's, roughly fifteen minutes. Nothing in Home
Assistant can do any of it and nothing on the Hub can force it.

**Prerequisites**

- The Wall Connector's **Quick Start Guide** (the card in the packaging). It carries
  the QR code and a **12-digit Wi-Fi password** on its front — see step 4 and, if it
  is lost, step 8.
- A phone on **2.4 GHz-capable Wi-Fi** with Bluetooth on, and the **Tesla One** app
  (the current path) — [Wall Monitor's Tesla One
  walkthrough](https://wallmonitor.app/faq/connect_using_tesla_one).
- Access to the **circuit breaker** feeding the charger.

**Step 0 — prove .52 is the Wall Connector before touching anything.**
A commissioned Gen 3 presents a DHCP hostname of the form `TeslaWallConnector_XXXXXX`
— that is exactly what HA's DHCP matcher keys on (`"hostname": "teslawallconnector_*"`).
Open the Deco app's client/lease list and look for that hostname against MAC
`08:d1:f9:80:37:f0`. If the lease shows some other hostname, .52 is a different
device and the rest of this section does not apply — find the real charger first.
The Deco serves no local DNS and no PTR records resolve on this network, so the lease
table is the only place to look; see
[`01-host-and-network.md`](01-host-and-network.md).

**Step 1 — put the unit into setup mode.**
At the charger, **press and hold the button on the charging handle for 5 seconds**,
until **the LED ring pulses green**
([Tesla, Commissioning Procedure](https://energylibrary.tesla.com/docs/Public/Charging/WallConnector/Gen3/Install/UniversalWC/en-us/GUID-113D0CEF-00D6-45BC-B71B-18D38EF157A8.html)).
Community write-ups say "5–10 seconds"
([Wall Monitor](https://wallmonitor.app/faq/joining_wall_connector_wifi)); Tesla's own
text says 5. Hold until the green pulse starts, then let go — the pulse, not the
count, is the confirmation.

**Step 2 — know the window.**
The setup network broadcasts for about **15 minutes** and then shuts off by itself
(Wall Monitor's troubleshooting page says 10–15 min and warns against relying on it
for anything ongoing). To reopen it, hold the handle button 5 s again, **or** cycle
the circuit breaker off and back on.

**Step 3 — the setup access point.**
The unit raises its own Wi-Fi network named **`TeslaWallConnector_XXXXXX`**, the
suffix being unique per unit.

**Step 4 — the password.**
The Wi-Fi password is the **12-digit code printed on the front of the Quick Start
Guide**, which also carries the setup **QR code**. Scanning the QR is the intended
path; typing the SSID and password by hand is the fallback.

**Step 5a — commission with the Tesla One app (the current path).**
Tesla's procedure is: hold the handle button 5 s, wait for the green pulse, then
select **Join** in the app; when prompted, **Scan QR Code** and scan the Quick Start
Guide again. On iOS, allow the local-network permission when asked — the app cannot
reach the charger without it. Wall Monitor documents the app path as **More → Tesla
Device Setup**, then scan or enter the SSID/password. **The exact in-app menu labels
beyond that are UNVERIFIED** — read them off the app rather than from this document.

**Step 5b — commission from the built-in web page (legacy firmware).**
Older firmware serves a setup page directly on the access point. Join
`TeslaWallConnector_XXXXXX` from a laptop, then browse to **`http://192.168.92.1`**
and follow the on-screen steps. Newer firmware expects the Tesla One flow instead —
if 192.168.92.1 does not load, that is the reason, not a fault. Note this address is
the *setup* AP only; it is never the charger's address on the house LAN.

**Step 6 — set the two things that matter and finish.**
Commissioning sets the **circuit-breaker size** (get this right — it bounds charge
current) and joins the unit to the **house 2.4 GHz SSID**. Do not stop at "the app
found the charger": drive the flow through to its completion screen. The half-finished
state is exactly what §4.4.2 looks like from the network.

**Step 7 — record the LAN IP, then pin it.**
The app shows the address the charger received: tap the **Wi-Fi** row, then the active
network, to read the IP. Then give it a **DHCP reservation by MAC** in the Deco app —
MAC-based reservation is the only stable addressing this network offers
([`01-host-and-network.md`](01-host-and-network.md)). Do this *before* adding it to
HA: the config entry stores a host, and a lease change silently breaks it.

**Step 8 — if the Quick Start Guide is lost.**
Two recoveries, per [Wall
Monitor](https://wallmonitor.app/faq/finding_qr_code):
1. **Tesla's Diagnose flow** — sign in at Tesla Support's [charging troubleshooting
   tool](https://www.tesla.com/contactus/troubleshooting?troubleshootingGuide=diagnoseHomeChargingProblem)
   with the part number and serial number off the unit and select *Lost Wall Connector
   Password*. Resolution can take up to 24 hours.
2. **The backup QR code inside the unit** — *"turn off the power to your Wall
   Connector"*, remove the two screws at the top and two at the bottom, and lift the
   body off the base plate; the backup QR and Wi-Fi credentials are printed inside.
   **This is live electrical work behind a 240 V breaker. Kill the breaker first, and
   if there is any doubt, it is an electrician's job, not a commissioning task.**

**Step 9 — if setup will not complete.**
Power-cycle at the breaker (off, ~10 s, on) and re-run from step 1; the unit reopens
its setup window on power-up. **A documented "factory reset" key sequence for the Gen 3
is UNVERIFIED** — Tesla publishes a power-cycle and a re-commission, not a reset
chord, and this document will not invent one. If a power cycle plus a clean
re-commission does not produce a device that answers §4.4.5, that is a Tesla support
case (the same Diagnose flow as step 8), not a Home Assistant problem.

### 4.4.5 Confirm the local API answers — re-probe from the Hub

Run this after commissioning, from the Hub host. Read-only. Substitute the reserved IP
from step 7 if it is no longer .52.

```bash
WC=192.168.68.52

# 1. Is anything listening now?
for p in 80 443 8080; do
  timeout 3 bash -c "echo > /dev/tcp/$WC/$p" 2>/dev/null \
    && echo "port $p OPEN" || echo "port $p refused"
done

# 2. THE test. This is the exact call HA's config flow makes to validate a host,
#    so if this fails the flow will fail with cannot_connect.
curl -s --max-time 10 "http://$WC/api/1/version" | jq

# 3. The payload the ev-charger pin will be built from.
curl -s --max-time 10 "http://$WC/api/1/vitals" | jq

# 4. The other two endpoints the integration reads.
curl -s --max-time 10 "http://$WC/api/1/lifetime" | jq
curl -s --max-time 10 "http://$WC/api/1/wifi_status" | jq
```

**The unit is integrable when and only when step 2 returns JSON.** Not step 1, and
not step 3 — the config flow calls `/api/1/version`, so that is the endpoint that
decides whether the flow succeeds.

`/api/1/version` also **closes out §4.4.2's open question**: it returns
`serial_number` and `part_number`. A serial and a Tesla part number coming back off
.52 is the proof that it is the Wall Connector; nothing before that is.

Two response quirks the client library works around, worth knowing before you
conclude the JSON is broken
([`api.py`](https://github.com/einarhauks/tesla-wall-connector/blob/main/tesla_wall_connector/api.py)):
the firmware sometimes emits bare `nan` (invalid JSON, which `jq` will reject) and
sometimes omits the final `}`. Both are known firmware defects, both are repaired by
the library, and neither means the unit is unhealthy. If `jq` chokes, re-run without
it and look at the raw body.

The mDNS browse from the earlier draft is still useful as a liveness check, and the
`docker exec -i` warning attached to it is still load-bearing — see §4.4.9. But per
§4.4.3 it is not the pass/fail signal.

### 4.4.6 Add it to Home Assistant

Only once §4.4.5 step 2 returns JSON. Run the `hactl` flow-progress listing from §4.0
before and after.

**No discovery card will appear.** HA discovers this integration by DHCP, matching
hostname `teslawallconnector_*` against MAC prefixes `DC44271*`, `98ED5C*`, `4CFCAA*`.
This unit is on `08:d1:f9`, which is not in that list, so **add it by IP**. Waiting
for a card is not a route — the same shape of problem as the Kasa devices in §4.1.4,
for the same reason.

**UI path:** Settings → Devices & services → Add integration → *Tesla Wall Connector*
→ enter the host. One step, one field.

**Headless:**

```bash
FLOW=$(curl -sX POST "$HA/api/config/config_entries/flow" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"handler":"tesla_wall_connector"}' | jq -r .flow_id)
curl -sX POST "$HA/api/config/config_entries/flow/$FLOW" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"host":"192.168.68.52"}' | jq
#  -> {"type":"create_entry","title":"Tesla Wall Connector", ...}
```

The entry title is the constant **"Tesla Wall Connector"** — it is not read off the
device — and the entry's unique id is the serial number. `cannot_connect` from this
call means `/api/1/version` did not answer; go back to §4.4.5.

**On HA 2026.8 and later the `user` step gains a second field, `split_phase`.** This
Hub is on 2026.7.4, where the step takes `host` alone — verified against the
`2026.7.4` tag. Read §4.4.7 before you upgrade, because that field is not cosmetic.

### 4.4.7 Entities to expect — and which one is the watts pin

Everything in this subsection is read from the source pinned at **this Hub's version,
2026.7.4** (`tesla-wall-connector==1.1.0`). **All entity ids below are PREDICTED, not
observed** — no entry has ever loaded here. Read them out of the registry (§4.4.9)
before writing one into `bindings.yaml`.

#### There is no watts key. The power number is computed, and on this house it will be wrong

This is the correction the repo needed, and it is bigger than a name.

**`/api/1/vitals` does not contain a power field.** The key set is agreed by four
independent implementations — HA's client library, evcc's `Vitals` struct, the
ioBroker adapter and openHAB's community write-up — and none of them lists watts:

```
contactor_closed  vehicle_connected  session_s  session_energy_wh
grid_v  grid_hz  vehicle_current_a
currentA_a  currentB_a  currentC_a  currentN_a
voltageA_v  voltageB_v  voltageC_v
relay_coil_v  (newer firmware: relay_k1_v, relay_k2_v)
pcba_temp_c  handle_temp_c  mcu_temp_c
uptime_s  input_thermopile_uv  prox_v  pilot_high_v  pilot_low_v
config_status  evse_state  current_alerts  evse_not_ready_reasons
```

`total_power_w` is a **client-side calculation**, not a device key. At library 1.1.0
it is, unconditionally:

```python
# tesla_wall_connector/vitals.py @1.1.0
@property
def total_power_w(self) -> float:
    """Total power calculated from three phases"""
    return round(
        (self.voltageA_v * self.currentA_a) +
        (self.voltageB_v * self.currentB_a) +
        (self.voltageC_v * self.currentC_a), 1)
```

**This house is North American split-phase service, and that formula over-reads on
split phase.** The integration's own code owner, on
[tesla-wall-connector#18](https://github.com/einarhauks/tesla-wall-connector/issues/18):
*"the issue here is that total power is being calculated using all 3 phases. For the
North American version of the wall connector, the 3rd phase is bogus and not to be
used."* Two independently reported magnitudes: **~9.5 kW actual reported as ~12.1 kW**
(that issue) and **12 kW actual reported as 15 kW**
([home-assistant/core#169343](https://github.com/home-assistant/core/issues/169343)).
Call it 25–30 % high, not a rounding error.

The fix is [home-assistant/core#175883](https://github.com/home-assistant/core/pull/175883),
merged **2026-07-13**, which adds a `split_phase` boolean to the config flow *and* an
options flow, and bumps the client to 1.2.0 where the split-phase branch computes
`grid_v × vehicle_current_a` instead. **It is not in 2026.7.4** — verified by reading
the `2026.7.4` tag, whose `config_flow.py` schema is `{vol.Required(CONF_HOST): str}`
and whose manifest pins `tesla-wall-connector==1.1.0`. It ships in **2026.8**
(present at tag `2026.8.0b5`, pinning 1.2.0).

**Consequence for the `ev-charger` binding, and it is a decision, not a detail:**
commissioning this charger on 2026.7.4 gives the Panel a power pin that is
confidently and consistently wrong by about a quarter. Either upgrade the Hub to
2026.8 and set **split_phase = true** before binding, or bind it and accept a known
bad number. Do not bind it and assume it is right. Whichever way it goes, the
Hub-upgrade question belongs in
[`07-device-lifecycle.md`](07-device-lifecycle.md), not here.

#### The second trap: it reports kilowatts, not watts

`total_power_w` carries `native_unit_of_measurement=W` but
`suggested_unit_of_measurement=kW`, so **the state HA publishes is in kW**. The `_w`
in the key names the library's internal property, not the entity's unit. Session and
lifetime energy are the same shape: native Wh, suggested **kWh**. Any Panel binding or
template that reads this entity as watts is out by 1000×.

#### The entity set at 2026.7.4 — 16 sensors, 2 binary sensors

Device name is the constant **"Tesla Wall Connector"**, and `_attr_has_entity_name`
is `True`, so ids compose as `sensor.tesla_wall_connector_<entity name slug>`.

| Friendly name | Predicted entity id | Unit | Bind? |
|---|---|---|---|
| **Total power** | `sensor.tesla_wall_connector_total_power` | **kW** | **Yes — this is the `ev-charger` power pin.** Read §4.4.7's two traps first |
| Status | `sensor.tesla_wall_connector_status` | enum | Useful — `charging`, `waiting_car`, `not_connected`, … |
| Session energy | `sensor.tesla_wall_connector_session_energy` | kWh | Maybe |
| *(lifetime energy)* | `sensor.tesla_wall_connector_energy` | kWh | Maybe |
| Grid voltage / Grid frequency | `..._grid_voltage`, `..._grid_frequency` | V, Hz | Diagnostic |
| Phase A/B/C voltage | `..._phase_a_voltage`, `_b_`, `_c_` | V | Diagnostic |
| Phase A/B/C current | `..._phase_a_current`, `_b_`, `_c_` | A | Diagnostic |
| Handle / PCB / MCU temperature | `..._handle_temperature`, `..._pcb_temperature`, `..._mcu_temperature` | °C | Diagnostic |
| Status code | `..._status_code` | int | **Disabled by default** (`entity_registry_enabled_default=False`) |
| Vehicle connected | `binary_sensor.tesla_wall_connector_vehicle_connected` | plug | Yes |
| Contactor closed | `binary_sensor.tesla_wall_connector_contactor_closed` | battery_charging | Diagnostic |

Notes that will otherwise cost someone an afternoon:

- **The lifetime-energy sensor has no translation key at 2026.7.4.** Its
  `SensorEntityDescription` sets no `translation_key` and no `name`, so HA falls back
  to naming it by its device class — plain **"Energy"** — which is why the predicted
  id is `..._energy` and not `..._lifetime_energy`. On `dev` it has since gained the
  friendly name "Lifetime energy" with `suggested_object_id="energy"`, i.e. the id
  stays put while the label changes. Do not match this entity by label.
- **`sensor.tesla_wall_connector` — the current dev stand-in in `bindings.yaml` — will
  not be created.** Every entity gets the device-name prefix *plus* a name, so the
  bare id belongs to nothing. It will keep reading as a missing entity, which is the
  correct behaviour for a stand-in and is why §4.4.9 says leave it alone until the
  hardware answers.
- The phase-2 plan's guess `sensor.<wall-connector>_power` matches nothing. So does
  the older draft of this chapter, which predicted `_power` too.
- **`vehicle_current_a` ("Vehicle current") and `wifi_rssi` ("Wi-Fi RSSI") do not
  exist at 2026.7.4.** They arrive with 2026.8, along with the `wifi_status` fetch —
  the 2026.7.4 coordinator polls `vitals` and `lifetime` only. Expect the entity count
  to go 18 → 20 on that upgrade.
- Poll interval is a hard-coded **30 s** (`DEFAULT_SCAN_INTERVAL`). It is not
  configurable, and §4.4.8's lock-up row is about what happens when you poll this
  firmware for a long time.
- **Every entity is created unconditionally** and each value getter indexes the parsed
  payload directly. A firmware generation that omits a key does not yield an empty
  sensor — it faults the getter. Compare §4.4.5 step 3's real output against the key
  list above before assuming the table holds.

### 4.4.8 Troubleshooting, keyed on symptom

| Symptom | Most likely cause | What to do |
|---|---|---|
| ICMP replies; **every** TCP port RSTs | IP stack up, application firmware not serving — **this unit's 2026-08-04 state** — or .52 is not a Wall Connector | §4.4.4 step 0, then re-commission from step 1 |
| ICMP replies; port 80 **times out** (no RST) | The local API has locked up. Distinct from the row above | Power-cycle at the **breaker**. Restarting HA does not fix it — [evcc#28525](https://github.com/evcc-io/evcc/issues/28525) |
| Entity set goes `unavailable` and instantly recovers, repeatedly | Weak Wi-Fi at the charger, not a software fault | Improve RF coverage at the garage. An owner in [core#150022](https://github.com/home-assistant/core/issues/150022) fixed years of this with one extra AP; 6 lost pings in 800 was enough to trip it |
| Host unreachable entirely | Dropped off Wi-Fi, or the DHCP lease moved | Check the Deco lease table; reserve by MAC (§4.4.4 step 7) |
| `/api/1/vitals` answers but the HA flow says `cannot_connect` | The flow validates **`/api/1/version`**, not vitals | `curl http://<host>/api/1/version` and fix that endpoint |
| `jq` reports invalid JSON from `/api/1/vitals` | Known firmware defect: bare `nan`, or a missing final `}` | Not a fault. The client library repairs both; re-run without `jq` to see the raw body |
| Entry loads, then a sensor faults or the whole entry errors | Firmware omits a key the pinned library indexes directly | Diff §4.4.5 step 3's output against §4.4.7's key list |
| **Total power reads ~25–30 % high** | Three-phase formula applied to split-phase service | §4.4.7. Needs HA **2026.8** and `split_phase = true`; there is no fix on 2026.7.4 |
| Power number is out by 1000× | The entity publishes **kW**, not W, despite the `_w` key | §4.4.7 |
| No discovery card ever appears | MAC `08:d1:f9` is not in the DHCP matcher list | Expected. Add by IP (§4.4.6) |
| Handle button held 5 s, no `TeslaWallConnector_*` network appears | Unit unpowered, or firmware not running | Cycle the breaker, retry once; then Tesla's Diagnose flow (§4.4.4 step 8) |
| Joined the setup AP but `192.168.92.1` will not load | Newer firmware replaced the built-in web setup with the Tesla One flow | Use Tesla One (§4.4.4 step 5a) |
| A probe script returns silently and exits 0 | `docker exec` without `-i` — the heredoc never reached the container | §4.4.9. Sanity-check the plumbing before believing any empty result |

### 4.4.9 Current state, and how to verify it

**Expect no `tesla_wall_connector` entities today.** That is the correct end state for
this chapter until the hardware is commissioned:

```bash
curl -s "$HA/api/config/config_entries/entry" -H "Authorization: Bearer $TOKEN" \
  | jq -r '.[] | select(.domain=="tesla_wall_connector") | .title'   # expect: empty
```

Once an entry does exist, this is how you replace §4.4.7's predictions with facts —
run it before touching `bindings.yaml`:

```bash
curl -s "$HA/api/states" -H "Authorization: Bearer $TOKEN" \
  | jq -r '.[] | select(.entity_id|test("tesla_wall_connector"))
           | "\(.entity_id) = \(.state) \(.attributes.unit_of_measurement // "")"'
```

Check the **unit column** on the Total power row. If it says `kW`, §4.4.7's second
trap is live.

The `ev-charger` Key exists in `house.yaml` (line 99, kind `ev-charger`) and its
binding still points at the dev stand-in `sensor.tesla_wall_connector` marked
`connectivity: cloud`. **Leave it there until the real entity ids are read out of the
registry above.** A pin bound to a predicted entity id shows up as
`hub.missing_entities` noise at every boot and teaches the family to ignore the one
signal that is supposed to mean something
([ADR-0007](../../docs/adr/0007-the-panel-recovers-alone-and-says-when-it-cannot.md)).

The mDNS liveness browse, kept because it is still the cheapest way to tell "alive on
Wi-Fi" from "gone":

```bash
docker exec -i homeassistant python3 - <<'PY'
import time
from zeroconf import Zeroconf, ServiceBrowser
class L:
    def add_service(self, zc, t, n):
        i = zc.get_service_info(t, n, timeout=3000)
        if i: print(n, i.parsed_addresses())
    def update_service(self, *a): pass
    def remove_service(self, *a): pass
zc = Zeroconf()
for t in ("_smartenergy._tcp.local.", "_tesla._tcp.local."):
    ServiceBrowser(zc, t, L())
time.sleep(9); zc.close()
PY
```

> **Do not drop the `-i`.** Measured 2026-08-04:
> `docker exec homeassistant python3 - <<'PY' … PY` prints nothing and exits **0**,
> because without `-i` the heredoc is never delivered to the container's stdin and
> python3 executes an empty program. A silent success is indistinguishable from "no
> `_smartenergy._tcp` advert found" — and per §4.4.3 you might now read *that* as good
> news. You would conclude the opposite of the truth from a plumbing bug. Sanity-check
> first if any probe comes back suspiciously empty:
>
> ```bash
> docker exec -i homeassistant python3 - <<'PY'
> print("stdin ok")
> PY
> ```
>
> The same applies to the zeroconf probe in §4.2.2. It does not apply to `hactl`,
> which passes `-i` itself.

---

## 4.5 What this chapter hands to the bindings chapter

| Key | Status after this chapter |
|---|---|
| `outlet-outdoor-a` / `outlet-outdoor-b` / `outlet-master` | Two can take the EP40 children. The third has no safe candidate — the remaining sockets are the fridge and the aquarium (§4.1.1). |
| `thermostat` | **Ready now: `climate.main_floor`**, which is the `homekit_controller` entry's (§4.2.5, measured — the local one won the id). Breaks `panel/test/ha_hub_live_test.dart`'s 21.4 seed. **Settle the °F/°C question first** (§4.2.6) or it renders `83.0 °C`. |
| `ev-charger` | Still blocked at the hardware, but **no longer blocked on knowledge** — §4.4 is now a full commissioning procedure the owner can run. Leave the stand-in binding in place until real entity ids are read out of the registry (§4.4.9). Two facts the bindings chapter must not discover the hard way: the watts pin is **`sensor.tesla_wall_connector_total_power`** (predicted), and it publishes **kW, not W**; and on 2026.7.4 that number over-reads by ~25–30 % on this house's split-phase service, with the fix only in HA 2026.8 (§4.4.7). |
| *(no Key)* | Rachio's 5 zones, live now as `switch.rachio_dk_*` (§4.3.4). Needs a drawing session under ADR-0005 (§4.3.6). |
| *(no Key yet)* | The Ecobee's bridged room sensor — `sensor.family_room_temperature`, `binary_sensor.family_room_occupancy`, and a battery level (§4.2.6). Local, and unasked-for; worth a Key when the real house is drawn. |
| *(no Key, deliberately)* | `switch.old_fridge`, `switch.aquarium`. **Owner decision 2026-08-04: bind these normally.** The ADR-0006 one-tap risk in §4.1.1 was raised explicitly and the decision was reaffirmed — do not re-litigate it. It still needs **new Keys**, which is Sweet Home 3D drawing work under ADR-0005, not a `bindings.yaml` edit: the kitchen has no outlet Key today. |

Two Panel-side landmines that the phase plans do not mention, restated here so
they are not discovered by a red suite:

- `panel/test/bindings_drift_test.dart` carries `const _integrated = <String>{};`.
  **Every Key rebound to real hardware must be added to that set** or the suite
  fails.
- `panel/assets/house/house.yaml` is still generated from
  `tool/fixtures/placeholder-house.Home.xml` ("Demo House"). Its Keys are
  placeholders standing in for a house that has not been drawn yet. Binding real
  hardware to a placeholder Key is fine as an interim step; believing the Key
  names describe the real house is not.
