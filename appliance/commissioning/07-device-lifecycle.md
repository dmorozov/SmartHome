# 7 — Device lifecycle: adding, renaming, repurposing, removing

Chapter 4 gets hardware into the entity registry for the **first** time. This
chapter is about everything that happens to it afterwards: a fourth plug
arrives, an outlet stops being "the media shelf" and becomes "the patio", a
factory alias turns out to be permanent, a device is sold and the pin it drove
has to say something honest.

The whole chapter exists because of one fact, and it is worth reading twice
before touching anything:

> **A Home Assistant `entity_id` is assigned once, at first registration, and
> nothing renames it afterwards except an explicit registry write.** Renaming
> the plug in the Kasa app changes what it is *called*. It does not change the
> id the Panel binds to. Neither does deleting the integration and adding it
> back (§7.4.5).

So the cheapest moment in a device's whole life is the thirty seconds in the
vendor app *before* it is added to HA. Every later rename is the four-step
chain in §7.5, and a chain that stops halfway leaves a blank pin on a wall
display with nobody standing in front of it — the exact failure
[ADR-0007](../../docs/adr/0007-the-panel-recovers-alone-and-says-when-it-cannot.md)
exists to make loud.

**AS-BUILT vs INSTRUCTIONS.** Every *measurement* below was taken on the Hub
host on **2026-08-04** against Home Assistant **2026.7.4**, and every API
schema was read out of the running container rather than remembered. No
rename, repurpose or removal has actually been performed on this Hub — the
worked example in §7.8 is instructions, and it says so again where it starts.
Anything not verified says **UNVERIFIED** in those words.

Sibling chapters: [`04-devices-local.md`](04-devices-local.md) (first-time
addition, the Kasa fleet, the double-discovery trap),
[`06-panel-and-bindings.md`](06-panel-and-bindings.md) (the two House Plan
files and every rule that is fatal at boot),
[`03-home-assistant.md`](03-home-assistant.md) §3.5 (the REST/WebSocket
transports this chapter drives).

---

## 7.1 THE KEY QUESTION — answer it before you start

Every operation in this chapter is one of two things, and they cost different
days:

- a **bindings edit** — one text file, `panel/assets/house/bindings.yaml`,
  done in a minute at a laptop; or
- **drawing work** — Sweet Home 3D on the Mac, then `tool/sh3d_to_yaml.py`,
  then `dart run tool/gen_dev_entities.dart`, per
  [ADR-0005](../../docs/adr/0005-devices-authored-in-the-drawing.md). There is
  no supported path that creates a Key from a text editor, and
  `house_loader.dart` enforces it fatally in both directions.

Look your task up here **first**. Discovering halfway through a rename that the
Key you need does not exist is how a five-minute job becomes a Mac session.

| Lifecycle operation | Bindings edit | Needs a new Key (drawing) |
|---|---|---|
| Swap new hardware onto a Key that already exists | **yes** | no |
| Rename a device or entity in HA, then repoint its binding | **yes** | no |
| Repurpose a plug onto a *different existing* Key of the **same kind** | **yes** | no |
| Flip `connectivity: local` ↔ `cloud` | **yes** | no |
| Un-bind hardware that went away (delete the `entity:` line, keep the entry) | **yes** | no |
| Add a Device the house has no Key for | also | **YES** |
| Repurpose a plug into a **different kind** (outlet → light, outlet → status) | also | **YES** — delete the marker, drop the right one, re-type the Key |
| Change what the **Panel** calls a Device (the pin's label) | no | **YES** — the marker's *Name* |
| Move a Device to another Room, or to a different spot in the same Room | no | **YES** — drag the marker |
| Delete a Device from the house entirely (pin and all) | also | **YES** — delete the marker, convert, then delete its binding |

Two standing consequences of that table on this house today:

**There are three `outlet` Keys and four live switchable sockets.**
`outlet-outdoor-a`, `outlet-outdoor-b`, `outlet-master` — and `switch.old_fridge`,
`switch.aquarium`, plus the EP40's two children. The arithmetic does not work
out, and it does not work out worse every time a plug is added. Count Keys
before you buy hardware.

**OWNER DECISION, 2026-08-04 — the fridge and the aquarium get bound
normally.** The one-tap risk under
[ADR-0006](../../docs/adr/0006-togglability-is-decided-by-the-house.md) was
raised explicitly and the owner reaffirmed the decision. It is recorded here as
a decision, not reopened. Two things follow from it and both are this
chapter's business:

- [`04-devices-local.md`](04-devices-local.md) §4.1.1 and
  [`06-panel-and-bindings.md`](06-panel-and-bindings.md) §6.4 both still
  recommend leaving those two unbound. **Those sections predate this decision
  and are stale on that point.** Their *mechanism* — an `outlet` Key toggles on
  a single tap with no confirmation step anywhere in the Panel — is still
  exactly right, and is why the decision was worth making deliberately.
- Binding them needs **new Keys**, which is the right-hand column of the table
  above. The kitchen has no outlet Key at all. So "bind the fridge" is a
  drawing session, not a `bindings.yaml` edit, and it is queued behind the real
  house drawing landing (`house.yaml` is still generated from
  `tool/fixtures/placeholder-house.Home.xml`, "Demo House").

---

## 7.2 The tools

Same two transports as chapter 3, and the split matters here more than
anywhere: **config entries are REST, registries are WebSocket-only.** There is
no REST view for the device or entity registry at all.

```bash
export HA=http://127.0.0.1:8123
export TOKEN=$(cat /home/dmorozov/Work/SmartHome/hub/token)   # 0600, gitignored
```

| Job | Transport | Call |
|---|---|---|
| Add a device | REST | `POST /api/config/config_entries/flow` (§7.3) |
| List config entries | REST | `GET /api/config/config_entries/entry` |
| Delete a config entry | REST | `DELETE /api/config/config_entries/entry/{entry_id}` (§7.7) |
| See what discovery is holding | WebSocket | `config_entries/flow/progress` |
| List devices | WebSocket | `config/device_registry/list` |
| List entities | WebSocket | `config/entity_registry/list` |
| **Rename a device** | WebSocket | `config/device_registry/update` (§7.4.3) |
| **Rename an entity / change its id** | WebSocket | `config/entity_registry/update` (§7.4.3) |
| Read live state | REST | `GET /api/states` |

The WebSocket driver is [`hactl`](hactl), committed next to these chapters and
already executable. It runs the command inside the `homeassistant` container
because the Hub host has no `aiohttp` and no passwordless sudo to install it.
Every WebSocket snippet below assumes it, and it resolves `hub/token` from its
own location, so it works from any working directory.

Both registry-update commands are decorated `@require_admin` in
`homeassistant/components/config/{device,entity}_registry.py`. The long-lived
token from §3.2 satisfies that, because the onboarding account is the owner.

---

## 7.3 Adding another smart plug or outlet

Four steps, in this order. Steps 1 and 2 are on the operator's phone; only
step 4 is HA's business.

### 7.3.1 Name it in the vendor app, and mean it

Do this **before** step 4, not after. The alias the plug is carrying at the
moment HA first registers it is baked into the entity ids forever (§7.4.1).
The EP40 on this Hub is the live proof: it was added still carrying
`TP-LINK_Smart Plug_722C`, so its two useful entities are permanently

```
switch.tp_link_smart_plug_722c_kasa_smart_plug_722c_0
switch.tp_link_smart_plug_722c_kasa_smart_plug_722c_1
```

unless somebody runs §7.4 by hand. Its two neighbours were named in the app
first and got `switch.old_fridge` and `switch.aquarium`.

Pick the name the *house* uses, not the room it happens to be in this month —
you are naming a socket, and sockets outlive their jobs (§7.6).

### 7.3.2 Reserve its address by MAC

The Deco XE75Pro mesh **serves no local DNS**; every PTR lookup on this LAN
fails and `.local` resolves to link-local IPv6 only
([`01-host-and-network.md`](01-host-and-network.md) §1.2). There is no hostname
handle, so the reservation is keyed on the MAC, made in the Deco app. The exact
app menu wording is **UNVERIFIED** — it is an operator-side mobile app, not
something in this repo.

Two ways to get the MAC without the app. The Deco client list is one. The other
is the legacy-protocol probe from §4.1.2, which also answers "is this thing
even on the pre-KLAP firmware" in the same round trip — read-only, pure stdlib,
no HA involved:

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
for ip in ("192.168.68.59", "192.168.68.60", "192.168.68.74"):   # add the new one
    s = socket.create_connection((ip, 9999), timeout=3)
    p = enc('{"system":{"get_sysinfo":{}}}')
    s.sendall(struct.pack(">I", len(p)) + p)
    n = struct.unpack(">I", s.recv(4))[0]
    buf = b''
    while len(buf) < n: buf += s.recv(n - len(buf))
    s.close()
    d = json.loads(dec(buf))["system"]["get_sysinfo"]
    print(ip, "|", d.get("alias"), "|", d.get("model"), "| mac:", d.get("mac"),
          "| child_num:", d.get("child_num"))
    for ch in d.get("children", []):
        print("     child:", ch.get("id")[-2:], ch.get("alias"), ch.get("state"))
PY
```

Measured output, 2026-08-04:

```
192.168.68.59 | Old fridge | HS103(US) | mac: 5C:A6:E6:09:B6:19 | child_num: None
192.168.68.60 | Aquarium | HS103(US) | mac: 5C:A6:E6:09:B5:F8 | child_num: None
192.168.68.74 | TP-LINK_Smart Plug_722C | EP40(US) | mac: 5C:A6:E6:CA:72:2C | child_num: 2
     child: 00 Kasa_Smart Plug_722C_0 1
     child: 01 Kasa_Smart Plug_722C_1 1
```

**Read `child_num` before you plan the binding.** A non-null value means the
device has multiple outlets, HA will model it as a parent plus N children, and
the parent drives all of them at once — §4.1.5. A connection refused on 9999
does not mean you need a cloud account; it means the device is off the network
or its firmware has moved off the legacy XOR protocol (see §7.3.4).

### 7.3.3 The second Kasa device onwards DOES self-discover

This is the one place where "add another one" is genuinely easier than "add the
first one", and it is worth knowing so you do not go looking for the manual
break-in from §4.1.4.

`tplink`'s UDP broadcast sweep is registered inside `async_setup()`, which runs
only when the component loads — and with no config entry and no DHCP matcher
hit, nothing ever loaded it. That is the chicken-and-egg §4.1.4 solves by
submitting an empty host to reach `pick_device`.

**Three `tplink` entries exist now, so the component is loaded and the sweep is
running.** Re-verified in the running image, 2026-08-04:

```python
# homeassistant/components/tplink/__init__.py
hass.async_create_background_task(_async_discovery(), "tplink first discovery", eager_start=True)
async_track_time_interval(hass, _async_discovery, DISCOVERY_INTERVAL, cancel_on_shutdown=True)
```

```
>>> homeassistant.components.tplink.DISCOVERY_INTERVAL
0:15:00
```

So a new Kasa plug on this LAN raises its own discovery card **within 15
minutes**, with the host pre-filled, and you confirm it rather than typing an
address. DHCP still will not help — the `5C:A6:E6` prefix is not in `tplink`'s
manifest matcher list (§4.1.4) — but you no longer need it to.

Check what discovery is holding rather than refreshing a browser:

```bash
./hactl '[{"type":"config_entries/flow/progress"}]' | python3 -c '
import json,sys
for f in json.load(sys.stdin)[0]["result"]:
    print(f["handler"], "|", f["context"].get("source"), "|",
          f["context"].get("title_placeholders"), "|", f.get("step_id"))'
```

Waiting is optional, not mandatory. If you would rather not wait 15 minutes,
§7.3.5 adds it by IP in one call and the pending discovery flow then aborts
itself as already configured.

### 7.3.4 The UI path

`http://192.168.68.81:8123` → settings → the devices-and-services page. The new
plug appears as a discovered card; confirm it. Exact menu wording for 2026.7 is
**UNVERIFIED** — navigate by function, as everywhere else in this runbook.

One thing to look at before clicking, and it is not cosmetic: **which card**.
The double-discovery trap of §4.2.1 is about HomeKit accessories, but the same
discipline applies to any plug that advertises more than one way — read the
`handler`, which the UI card does not show you and
`config_entries/flow/progress` does.

If the flow asks for **TP-Link cloud credentials**, you are not on this
fleet's footing. All three plugs here answer the pre-KLAP legacy XOR protocol
with no account involved (§4.1.2). Newer Kasa/Tapo firmware generations use
KLAP and do want an account. That is not a defect and not a wrong click — it is
different hardware, and it changes the honest value of `connectivity:` for that
device. **Whether any specific new plug is legacy or KLAP is UNVERIFIED until
the probe in §7.3.2 answers on port 9999.**

### 7.3.5 The headless path

Adding by IP is one call and skips `pick_device` entirely:

```bash
FLOW=$(curl -sX POST "$HA/api/config/config_entries/flow" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"handler":"tplink"}' | jq -r .flow_id)

curl -sX POST "$HA/api/config/config_entries/flow/$FLOW" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"host":"192.168.68.NN"}' | jq
#  -> {"type":"create_entry","title":"<alias> <model>", ...}
```

An **empty** host branches to `pick_device` instead, whose `device` key takes
the **formatted MAC** (lowercase, colon-separated) — not the IP:

```bash
curl -sX POST "$HA/api/config/config_entries/flow/$FLOW" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"host":""}' | jq '.data_schema'          # read the offered MACs
curl -sX POST "$HA/api/config/config_entries/flow/$FLOW" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"device":"5c:a6:e6:xx:xx:xx"}' | jq
```

`pick_device` filters out devices you have already configured, so a short list
is a good sign, not a broken scan.

### 7.3.6 Verify, and the entities to ignore

```bash
./hactl '[{"type":"config/entity_registry/list"}]' | python3 -c '
import json,sys
for e in json.load(sys.stdin)[0]["result"]:
    if e.get("platform") == "tplink":
        print(e["entity_id"], "| dev:", e.get("device_id"), "| disabled:", e.get("disabled_by"))'
```

Every new Kasa plug brings the same passengers, and none of them should ever
reach `bindings.yaml`:

| Arrives | Why not to bind it |
|---|---|
| `switch.<name>_led` | the status LED on the plug body, not the load. It passes the entity-id regex and toggling it does nothing visible from a sofa — a pin that looks broken |
| `binary_sensor.<name>_cloud_connection` | whether the plug can reach **TP-Link's** servers. It reads `on` today on all three, so a bound pin would read "fine" during a total LAN outage |
| `button.<name>_restart`, `sensor.<name>_signal_strength`, `sensor.<name>_on_since` | arrive `disabled_by: "integration"` — diagnostics that create no state until enabled |

`feature: TIM` on all three existing plugs means timer-only: **no `EMETER`, no
watts, no kWh.** A new plug that reports `EMETER` would be the first energy
source in this house; until one does, any plan step that says "bind the Kasa
plug's power sensor" is describing hardware that is not here (§4.1.3).

---

## 7.4 Renaming — the trap that makes this chapter necessary

### 7.4.1 `entity_id` is fixed at creation

Not a convention — a code path. From `homeassistant/helpers/entity_registry.py`
in the running image:

```python
def async_get_or_create(self, domain, platform, unique_id, *, ...):
    entity_id = self.async_get_entity_id(domain, platform, unique_id)
    if entity_id:
        return self._async_update_entity(entity_id, ..., original_name=original_name, ...)
```

Every restart, every integration reload, every rename in the vendor app takes
that early return. The entity is looked up by `(domain, platform, unique_id)`;
the id it already has is reused and the *names* are refreshed around it. The
generator that turns a name into an id only ever runs on the branch below,
where no entry existed yet.

So there are exactly two ways to change an `entity_id`: the registry call in
§7.4.3, or destroying the unique_id itself (new hardware, factory reset that
mints a new device id). Deleting and re-adding the integration is **not** one of
them — §7.4.5.

### 7.4.2 What a rename does change

Renaming the *device* — in the Kasa app, or with `name_by_user` in HA — is not
useless. It changes what a human sees. It just never touches an id.

Measured on this Hub, 2026-08-04, from `/api/states`:

| `entity_id` (fixed) | `friendly_name` (follows the device name) |
|---|---|
| `switch.old_fridge` | `Old fridge` |
| `switch.old_fridge_led` | `Old fridge LED` |
| `switch.tp_link_smart_plug_722c_kasa_smart_plug_722c_0` | `TP-LINK_Smart Plug_722C Kasa_Smart Plug_722C_0` |

All the `tplink` entities carry `has_entity_name: true`, so the display name is
composed at read time as *device name* + *entity name*. Rename the device and
every one of those friendly names follows on the next read; not one entity id
moves.

The registry's own reaction, from `async_device_modified` in
`entity_registry.py`, is the source of that behaviour:

```python
if (by_user := "name_by_user" in changes) or "name" in changes:
    ...
    for entity in entities:
        if entity.has_entity_name:
            continue
        # When a user renames a device, update entity names to reflect
        # the new device name.
```

Entities *without* `has_entity_name` get their stored `name` rewritten. Entities
*with* it are skipped, because their name is already relative to the device.
Neither branch mentions `entity_id`.

**The consequence for the Panel is the whole point of this chapter.** The Panel
does not read `friendly_name` at all — `bindings.yaml` names an `entity_id` and
`HaHubClient` keys its whole world on it (`_byEntity` in
[`../../panel/lib/data/ha_hub.dart`](../../panel/lib/data/ha_hub.dart)). A
rename that stops at the vendor app is invisible to the Panel in both
directions: nothing breaks, and nothing improves.

### 7.4.3 The two registry calls

Both are WebSocket, both are admin-only, both were read out of
`homeassistant/components/config/` in the running container on 2026-08-04.

**Rename the device.** Schema, verbatim:

```python
{
    vol.Required("type"): "config/device_registry/update",
    vol.Optional("area_id"): vol.Any(str, None),
    vol.Required("device_id"): str,
    vol.Optional("disabled_by"): vol.Any(DeviceEntryDisabler.USER.value, None),
    vol.Optional("labels"): [str],
    vol.Optional("name_by_user"): vol.Any(str, None),
}
```

```bash
./hactl '[{"type":"config/device_registry/update",
           "device_id":"<device_id>",
           "name_by_user":"Patio Plug"}]'
```

`name_by_user` is a *user override* laid over the integration's own `name`;
passing `null` removes the override and the factory name comes back. Note what
is **not** in that schema: there is no `name` field and no `new_device_id`. The
device's own name belongs to the integration.

**Rename the entity, and change its id.** The fields this house cares about,
from the same source:

```python
{
    vol.Required("type"): "config/entity_registry/update",
    vol.Required("entity_id"): cv.entity_id,
    vol.Optional("name"): vol.Any(str, None),
    vol.Optional("new_entity_id"): str,
    vol.Optional("area_id"): vol.Any(str, None),
    vol.Optional("icon"): vol.Any(str, None),
    vol.Optional("device_class"): vol.Any(str, None),
    vol.Optional("aliases"): [vol.Any(str, None)],
    vol.Optional("labels"): [str],
    vol.Optional("disabled_by"): ...,      # only null or "user"
    vol.Optional("hidden_by"): ...,        # only null or "user"
    vol.Inclusive("options_domain", "entity_option"): str,
    vol.Inclusive("options", "entity_option"): vol.Any(None, dict),
}
```

```bash
./hactl '[{"type":"config/entity_registry/update",
           "entity_id":"switch.tp_link_smart_plug_722c_kasa_smart_plug_722c_0",
           "new_entity_id":"switch.outdoor_outlet_a",
           "name":"Patio outlet A"}]'
```

`name` is the user override for the entity half of the display name;
`new_entity_id` is the only thing that moves the id. Send both in one call —
they are independent fields and doing them separately buys nothing.

**Errors you can actually hit.** `new_entity_id` is validated in
`_async_update_entity`, and the three `ValueError`s are surfaced by the config
view as WebSocket error code `invalid_info` with the message text passed
straight through:

| Message | Cause |
|---|---|
| `Entity with this ID is already registered` | the target id is taken — including by a *soft-deleted* entity (§7.4.5) |
| `Invalid entity ID` | not `domain.object_id`, or illegal characters |
| `New entity ID should be same domain` | you cannot turn a `switch.` into a `sensor.` |

A wrong `entity_id` in the request returns error code `not_found`,
`"Entity not found"`.

**It takes effect live; no restart.** From `Entity._async_process_registry_update_or_remove`
in `homeassistant/helpers/entity.py`: on an id change the entity is
`async_remove(force_remove=True)`d, `self.entity_id` is reassigned, and it is
re-added to the platform. Do not schedule a Hub restart for a rename.

That same code path has a consequence for a *running* Panel — see §7.5 step 3.

### 7.4.4 Rename which object? Devices are not always where the entities are

Do not assume the entity you care about hangs off the device you are looking
at. Measured on the EP40, 2026-08-04 — this is the single most surprising row
in the registry on this Hub:

```
device e7175d986d9203ba9195a2eab4409348  TP-LINK_Smart Plug_722C            (EP40, the parent)
device 7fc37e5416fa19564a9764f9c0f740cb  ..._Kasa_Smart Plug_722C_0         (Socket for EP40(US), via parent)
device 8e96014b1251ecb5a9ff9759bac37592  ..._Kasa_Smart Plug_722C_1         (Socket for EP40(US), via parent)

switch.tp_link_smart_plug_722c_kasa_smart_plug_722c_0   device_id = e7175d…  <- the PARENT
switch.tp_link_smart_plug_722c_kasa_smart_plug_722c_1   device_id = e7175d…  <- the PARENT
sensor.…_kasa_smart_plug_722c_0_on_since                device_id = 7fc37e…  (disabled diagnostic)
sensor.…_kasa_smart_plug_722c_1_on_since                device_id = 8e9601…  (disabled diagnostic)
```

**The two switchable entities belong to the parent device.** The child devices
carry only the disabled `on_since` diagnostics. So renaming the two child
devices — the obvious move — changes nothing an operator or the Panel will ever
see. The switches' friendly names are composed from the *parent* device name
plus their own `Kasa_Smart Plug_722C_0` / `_1`.

Rule of thumb, and it is cheap to follow: **read `device_id` off the entity
before you rename a device.** One `config/entity_registry/list` call answers it.

### 7.4.5 You cannot get a clean id by deleting and re-adding

The obvious workaround for an ugly entity id is to delete the integration and
add it back. It does not work, and the reason is worth knowing because it also
governs §7.7.

`async_remove` in `entity_registry.py` does not destroy the row — it moves it
into `deleted_entities`, keyed by `(domain, platform, unique_id)`, carrying the
`entity_id`, the user-set `name`, aliases, area, icon, device_class and
disabled/hidden state. When the same unique_id comes back, `async_get_or_create`
restores them:

```python
deleted_entity = self.deleted_entities.pop((domain, platform, unique_id), None)
if deleted_entity is not None:
    ...
    # Restore entity_id if it's available
    if self._entity_id_available(deleted_entity.entity_id):
        entity_id = deleted_entity.entity_id
```

The soft-deleted row is purged only after
`ORPHANED_ENTITY_KEEP_SECONDS = 3600 * 24 * 30` — **30 days** — and only for
entries that have actually been orphaned (`async_purge_expired_orphaned_entities`).

Two practical readings of that:

- Delete-and-re-add a plug and you get **the same ugly entity ids back**,
  within 30 days. Use §7.4.3.
- Conversely, a rename you *did* do survives a delete-and-re-add. That is the
  good half of the same behaviour.
- And it explains one `invalid_info` you would otherwise call a bug: an id can
  be "already registered" by an entity that is not in the registry listing at
  all, because it is sitting in `deleted_entities`.

---

## 7.5 The full change chain

A rename is not one operation, it is five, and the Panel is broken in a
different way after each one you skip. Do them in this order — never write a
binding for an entity id that does not exist yet.

| # | Step | Where | If you stop here |
|---|---|---|---|
| 1 | `config/device_registry/update` with `name_by_user` | Hub | Cosmetic only. The HA UI and every friendly name still show the factory alias. The Panel does not care |
| 2 | `config/entity_registry/update` with `new_entity_id` (and `name`) | Hub | **The id never changes.** `bindings.yaml` keeps working against the old ugly id — nothing is broken, but the rename did not happen |
| 3 | Repoint the Key in [`../../panel/assets/house/bindings.yaml`](../../panel/assets/house/bindings.yaml) | repo | **This is the dangerous one.** The Panel still boots — nothing validates entity existence at load. The pin goes blank forever and the only evidence is one `hub.missing_entities` line (§7.7.3) |
| 4 | Add the Key to `_integrated` in [`../../panel/test/bindings_drift_test.dart`](../../panel/test/bindings_drift_test.dart) | repo | `flutter test` goes red: *"binding(s) point at entities the dev Hub does not serve"*. The suite is correct; real entity ids are not in `hub/dev/ha-config/packages/panel_dev.yaml` and never will be |
| 5 | `flutter test` | repo | You find out on the wall instead of at the laptop |

Notes that only bite in practice:

- **Steps 3 and 4 belong in the same commit.** They are one thought: "this Key
  is real hardware now."
- **Restart the Panel after step 2, even if it looks fine.** From §7.4.3, an id
  change removes the entity and re-adds it, which fires `state_changed` with
  `new_state: null` for the old id. `HaHubClient._onFrame` only applies events
  whose `new_state` is a Map, so the Panel *ignores* that frame and the pin
  keeps its last value. A Panel that has been up since before the rename shows
  a stale reading for an entity that no longer exists, indefinitely — until the
  socket drops and the next `get_states` snapshot corrects it.
- **Step 5 may legitimately fail on `ha_hub_live_test.dart`.** It asserts
  Device readings against the *dev Hub's* seed values (`thermostat.currentC ≈ 21.4`
  and friends). Binding real hardware breaks those by design — chapter 6 §6.8
  is the place that decides what to do about it, per Key.
- **No drawing step appears in this chain.** A rename in HA never touches
  `house.yaml`. If your change also needs a new Key, a new pin label, or a
  different kind, that is §7.1's right-hand column and it happens *before*
  step 3, because `bindings.yaml` and `house.yaml` must agree on the Key set in
  both directions or the Panel refuses to boot.

---

## 7.6 Repurposing: same hardware, new job

"This plug used to run the media shelf; now it runs the patio heater." No
hardware moves onto a new network, nothing re-pairs, and the config entry is
untouched.

**What changes**

| Thing | Change | Cost |
|---|---|---|
| The name, everywhere | vendor app → §7.4.3 device + entity rename | the §7.5 chain |
| Which Key it is bound to | move the `entity:` line to the other Key in `bindings.yaml` | bindings edit |
| The Device **kind**, if the new job is a different kind of thing | delete the marker, drop the right one, re-type the Key | **drawing** (§7.1) |
| Where the pin sits, if the plug physically moved rooms | drag the marker, re-run the converter | **drawing** (§7.1) |
| `connectivity:` | only if the transport genuinely changed (a KLAP replacement, an ESPHome reflash) | bindings edit |

**What does not change** — and this is why repurposing is the cheapest
operation in the chapter:

- the config entry (`GET /api/config/config_entries/entry` shows the same
  `entry_id`, same title, same `state: loaded`);
- the pairing, the credentials, the HomeKit slot, the OAuth token;
- the entity's `unique_id`, which is why the `entity_id` survives untouched
  unless you deliberately move it (§7.4.1);
- the DHCP reservation.

Three things to get right before you finish:

1. **Do not leave the old Key bound to the same entity.** `bindings_parser.dart`
   rejects one entity backing two Devices — *"`<a>` and `<b>` both bind to
   entity `<id>` — one entity, one Device."* — fatally, at boot. Delete the old
   Key's `entity:` line and keep its entry with `connectivity:`; a Device with
   no `entity:` is legal, renders with unknown state, and is invisible to
   `hub.missing_entities` by construction.
2. **Re-answer the togglability question for the new job.** Togglability comes
   from the Device *kind*, never from the live state
   ([ADR-0006](../../docs/adr/0006-togglability-is-decided-by-the-house.md)),
   and an `outlet` Key toggles on one tap with no confirmation step anywhere in
   the Panel. Moving a plug from "a lamp" to "something that must not be
   switched off by a stranger" is a kind change, which is drawing work — not a
   thing you can express in `bindings.yaml`. (The house's live instance of that
   question is the fridge/aquarium decision recorded in §7.1.)
3. **Take the Key out of `_integrated` if the binding goes back to a dev
   stand-in or to nothing.** That set is a ledger of what is real; the drift
   test skips every Key in it. A stale entry silently disables the check for
   that Key forever, which is exactly the failure the test was written to
   catch.

---

## 7.7 Removing a device

### 7.7.1 Delete the config entry

```bash
# find it
curl -s "$HA/api/config/config_entries/entry" -H "Authorization: Bearer $TOKEN" \
  | jq -r '.[] | select(.domain=="tplink") | "\(.entry_id) | \(.title) | \(.state)"'

# remove it
curl -sX DELETE "$HA/api/config/config_entries/entry/<entry_id>" \
  -H "Authorization: Bearer $TOKEN" | jq
#  -> {"require_restart": false}
```

`require_restart` is `not unload_success` — it is `true` only when the
integration could not unload cleanly, in which case its entities linger until
the Hub restarts. Read it; do not assume `false`.

### 7.7.2 What happens on the Hub

`ConfigEntries._async_clean_up` calls both registries:

```python
dev_reg.async_clear_config_entry(entry_id)
ent_reg.async_clear_config_entry(entry_id)
```

so the devices and entities go away together. They disappear from
`config/entity_registry/list` and from `GET /api/states` immediately.

They are **soft-deleted, not destroyed** — §7.4.5. Each entity moves to
`deleted_entities` with an `orphaned_timestamp`, keeping its `entity_id`, user
name, area and icon for 30 days. Re-add the same hardware inside that window
and the old ids come back. Sell the plug and add a *different* one and you get
fresh ids, because the unique_id is different.

### 7.7.3 What the Panel does with a binding whose entity has vanished — verified

**It is not fatal at boot.** This was traced through the code rather than
assumed, because the answer decides whether a removal is a five-minute job or
an outage:

- `bindings_parser.dart` validates *shape only*: the `^[a-z_]+\.[a-z0-9_]+$`
  entity-id regex, one entity per Device, a mandatory `connectivity:`. It never
  contacts a Hub.
- `house_loader.dart` validates that the Key sets in `house.yaml` and
  `bindings.yaml` match in both directions. It does not look at entity ids at
  all.
- Nothing else runs at load. **A binding pointing at an entity that does not
  exist anywhere is a completely legal House Plan and the Panel boots on it.**

At runtime it shows up as *missing*, which is a different and much quieter
thing than broken:

```
[panel] I hub.snapshot entities=<n> bound=<m> missing=1
[panel] W hub.missing_entities ids=switch.the_one_you_deleted
```

`missing` is computed once per `get_states` snapshot — that is, at every
successful connect — by subtracting the entities the Hub returned from the
entity ids `bindings.yaml` named. The id list is capped at 8 with `more=<n>`;
`hub.snapshot` carries the true count.

On the wall, the pin renders with its icon face, does not glow, shows no
reading, and its Popup body says the literal word **`Unknown`**
(`device_presentation.dart`, `statusText`, `null => 'Unknown'`). That is the
honest rendering of a Device the Hub cannot see, and it is the same rendering
as a Device that was never bound.

Three sharp edges, all verified:

1. **A running Panel keeps showing the old value.** HA fires `state_changed`
   with `new_state: null` when an entity is removed; `HaHubClient._onFrame`
   only applies frames where `new_state is Map`, so it ignores it. The pin
   holds its last reading until the socket drops and a fresh snapshot arrives.
   A Panel that was up when you deleted the fridge's integration goes on
   showing the fridge as `On`. **Restart the Panel after a removal.**
2. **Tapping that pin is a silent no-op.** The Panel still sends
   `homeassistant.toggle` for the bound id, and HA accepts it. Measured
   2026-08-04:

   ```
   POST /api/services/homeassistant/toggle {"entity_id":"switch.no_such_entity_lifecycle_probe"}
   -> HTTP 200, body []
   ```

   Success, empty result. So there is no `hub.command_failed` line either —
   nothing anywhere says the tap did nothing.
3. **`missing=0` is not coverage.** It only compares the ids you wrote against
   the Hub's snapshot. A Device with no `entity:` line is excluded by
   construction; a real device with no Key is invisible; an id that resolves
   but is the *wrong* entity resolves fine. Chapter 6 §6.6 has the full list.

### 7.7.4 The correct end state in the repo

Delete the `entity:` line. **Keep the Key's entry**, with its `connectivity:`:

```yaml
  outlet-outdoor-a:
    connectivity: local        # hardware sold 2026-08-xx; pin renders unknown
```

Deleting the whole Key entry is a **fatal boot error** —
*"bindings.yaml: no entry for Device `<key>` — add one; connectivity alone is
enough until the hardware exists"* — unless you also delete the marker in the
drawing and re-run the converter, which is the drawing-work row in §7.1.

Then take the Key **out** of `_integrated` (§7.6, note 3) and run
`flutter test`.

---

## 7.8 Worked example — renaming the EP40's two outlets

**Mixed, and the split matters. §7.8.1–§7.8.4 are INSTRUCTIONS** — a correct
recipe, whose ids and values were measured 2026-08-04 and are quoted unedited.
**§7.8.5 is AS-BUILT:** the rename has since been performed, so that section
records what the registry actually holds rather than what the commands above
would have produced. The two differ, deliberately — see §7.8.5.

### 7.8.0 Two things to settle first — both now settled

**Which outlet is which — established 2026-08-05.** `switch.outdoor_outlet_a`
(child `_0`) drives the socket labelled **"Plug 1"** on the plug body; B is the
other one by elimination. Full table, provenance and the 1-based/0-based
off-by-one that will trip the next reader: **Ch. 4 §4.1.5**. The names below are
therefore no longer provisional, which is what unblocks binding them to Keys a
stranger can tap.

Settle this *before* naming anything on a plug that is already on a Key —
toggle one child from the HA UI, watch which load stops, write it down. Here it
went the other way round (names first, mapping a day later) and it was survivable
only because nothing was wired to either socket at the time.

**Renaming does not create the Key.** These two entities are destined for
`outlet-outdoor-a` / `outlet-outdoor-b` / `outlet-master` — placeholder Keys in a
placeholder house — and the third of those has no safe candidate. The rename is
worth doing regardless: it is what makes the eventual binding readable, and the
ids are frozen until somebody runs it.

### 7.8.1 Starting state, measured

```
device  e7175d986d9203ba9195a2eab4409348  name "TP-LINK_Smart Plug_722C"  model EP40
        (192.168.68.74, MAC 5C:A6:E6:CA:72:2C, name_by_user: None)
device  7fc37e5416fa19564a9764f9c0f740cb  "…_Kasa_Smart Plug_722C_0"  via e7175d…
device  8e96014b1251ecb5a9ff9759bac37592  "…_Kasa_Smart Plug_722C_1"  via e7175d…

switch.tp_link_smart_plug_722c_kasa_smart_plug_722c_0  device_id e7175d…
   original_name "Kasa_Smart Plug_722C_0"  name None  has_entity_name true
   friendly_name "TP-LINK_Smart Plug_722C Kasa_Smart Plug_722C_0"  state on
switch.tp_link_smart_plug_722c_kasa_smart_plug_722c_1  device_id e7175d…
   original_name "Kasa_Smart Plug_722C_1"  name None  has_entity_name true
   friendly_name "TP-LINK_Smart Plug_722C Kasa_Smart Plug_722C_1"  state on
```

Note again that both switches hang off the **parent** device (§7.4.4).

### 7.8.2 Re-read the ids (never work from a copied hash)

```bash
./hactl '[{"type":"config/device_registry/list"},
          {"type":"config/entity_registry/list"}]' | python3 -c '
import json,sys
out = json.load(sys.stdin)
for d in out[0]["result"]:
    if d.get("model") and "EP40" in str(d.get("model")):
        print("DEV", d["id"], "|", d.get("name"), "|", d.get("name_by_user"))
for e in out[1]["result"]:
    if e["entity_id"].startswith("switch.tp_link_smart_plug_722c_kasa"):
        print("ENT", e["entity_id"], "| dev:", e.get("device_id"))'
```

### 7.8.3 Rename the parent device

```bash
./hactl '[{"type":"config/device_registry/update",
           "device_id":"e7175d986d9203ba9195a2eab4409348",
           "name_by_user":"Patio Plug"}]'
```

Both switches' friendly names become `Patio Plug Kasa_Smart Plug_722C_0` / `_1`
on the next read. **No entity id moved** — that is §7.4.1, demonstrated.

Optionally rename the two child devices as well, purely so the HA device list
is not a wall of factory strings. It has no effect on the switches:

```bash
./hactl '[{"type":"config/device_registry/update",
           "device_id":"7fc37e5416fa19564a9764f9c0f740cb","name_by_user":"Outdoor Outlet A"},
          {"type":"config/device_registry/update",
           "device_id":"8e96014b1251ecb5a9ff9759bac37592","name_by_user":"Outdoor Outlet B"}]'
```

### 7.8.4 Rename the two entities — the step that actually matters

```bash
./hactl '[{"type":"config/entity_registry/update",
           "entity_id":"switch.tp_link_smart_plug_722c_kasa_smart_plug_722c_0",
           "new_entity_id":"switch.outdoor_outlet_a",
           "name":"Outlet A"},
          {"type":"config/entity_registry/update",
           "entity_id":"switch.tp_link_smart_plug_722c_kasa_smart_plug_722c_1",
           "new_entity_id":"switch.outdoor_outlet_b",
           "name":"Outlet B"}]'
```

Each returns `{"entity_entry": {...}}` with the new id in it. If either returns
error code `invalid_info` with `Entity with this ID is already registered`, the
target id is taken — possibly by a soft-deleted entity you cannot see in the
listing (§7.4.5); pick another id or wait out the 30 days.

Do **not** try `"new_entity_id":"sensor.outdoor_outlet_a"` — that is
`New entity ID should be same domain`.

### 7.8.5 Verify on the Hub

```bash
curl -s "$HA/api/states" -H "Authorization: Bearer $TOKEN" | python3 -c '
import json,sys
for e in json.load(sys.stdin):
    if "outdoor_outlet" in e["entity_id"] or "722c" in e["entity_id"]:
        print(e["entity_id"], "=", e["state"], "|", e["attributes"].get("friendly_name"))'
```

**AS-BUILT, measured 2026-08-05.** What the Hub returns today:

```
binary_sensor.tp_link_smart_plug_722c_cloud_connection = on  | Patio Outlet Cloud connection
switch.tp_link_smart_plug_722c                         = on  | Patio Outlet
switch.tp_link_smart_plug_722c_led                     = on  | Patio Outlet LED
switch.outdoor_outlet_a                                = off | Outdoor Outlet A
switch.outdoor_outlet_b                                = on  | Outdoor Outlet B
```

The new ids are in place and **no**
`switch.tp_link_smart_plug_722c_kasa_smart_plug_722c_*` rows remain. The parent
`switch.tp_link_smart_plug_722c`, its `_led` and its `_cloud_connection` stay —
they were not renamed and must not be bound (§7.3.6, §4.1.5).

**Two divergences from §7.8.3–§7.8.4, both intentional, both worth reading:**

1. The parent's `name_by_user` is **`Patio Outlet`**, not the `Patio Plug` the
   command proposes, and the optional child-*device* rename was skipped
   (`name_by_user: None` on both children). Neither matters: no entity id moved,
   which is §7.4.1 demonstrated on live hardware.
2. The friendly names are **`Outdoor Outlet A` / `Outdoor Outlet B`** — plain,
   with no device prefix. The old expectation here read `Patio Plug Outlet A`,
   and that was wrong about the naming model, not just about the string. Both
   entities have `has_entity_name: true`, and the rule is: a user-set registry
   `name` **replaces** the friendly name outright; only `original_name` gets
   composed with the device name. The parent is the control — `name: None`,
   `original_name: None`, so its friendly name falls through to the device's
   `Patio Outlet`.

Then toggle one from the HA UI and confirm the right load responds. **Done
2026-08-05**, and that is where §7.8.0's mapping came from. Note that this is
the one-way half of the round-trip; driving the plug's physical button and
watching the entity follow is still untested (Ch. 4 §4.1.7 step 2).

### 7.8.6 Finish the chain in the repo

```yaml
# panel/assets/house/bindings.yaml
  outlet-outdoor-a:
    entity: switch.outdoor_outlet_a
    connectivity: local
  outlet-outdoor-b:
    entity: switch.outdoor_outlet_b
    connectivity: local
```

```dart
// panel/test/bindings_drift_test.dart
const _integrated = <String>{'outlet-outdoor-a', 'outlet-outdoor-b'};
```

```sh
cd panel && flutter test
```

One commit, both files. Then restart the Panel (§7.5).

---

## 7.9 Verification checklist

Run after any operation in this chapter. Every line is pasteable.

```bash
export HA=http://127.0.0.1:8123
export TOKEN=$(cat /home/dmorozov/Work/SmartHome/hub/token)

# 1. The config entries you expect, and nothing in setup_retry that surprises you
curl -s "$HA/api/config/config_entries/entry" -H "Authorization: Bearer $TOKEN" \
  | jq -r '.[] | "\(.domain) | \(.title) | \(.source) | \(.state)"' | sort

# 2. The entity ids as they now stand
./hactl '[{"type":"config/entity_registry/list"}]' | python3 -c '
import json,sys
for e in json.load(sys.stdin)[0]["result"]:
    if e.get("platform") == "tplink": print(e["entity_id"], e.get("disabled_by") or "")'

# 3. Every id bindings.yaml names actually exists on the Hub
curl -s "$HA/api/states" -H "Authorization: Bearer $TOKEN" | jq -r '.[].entity_id' | sort > /tmp/have
grep -oE '^\s+entity: \S+' /home/dmorozov/Work/SmartHome/panel/assets/house/bindings.yaml \
  | awk '{print $2}' | sort > /tmp/want
comm -23 /tmp/want /tmp/have     # <- anything printed here becomes hub.missing_entities

# 4. The Panel's own suite
cd /home/dmorozov/Work/SmartHome/panel && flutter test
```

Step 3 is the one that catches a chain stopped at §7.5 step 2 or 3, and it is
the only check in this chapter that fails *before* the Panel is on a wall.
Expect it to print the 30-odd dev stand-in ids until the bindings sweep is done
— what matters is that no id you just renamed is in the list.

Done when steps 1–4 agree, the Panel has been restarted, and the Key ledger in
`_integrated` says the same thing about reality that `bindings.yaml` does.

Further reading:
[`06-panel-and-bindings.md`](06-panel-and-bindings.md) §6.1 (the same
bindings-vs-drawing split, from the Panel's side) and §6.8 (the two tests that
fail on correct work);
[`../../panel/HOUSE-PLAN.md`](../../panel/HOUSE-PLAN.md) (the drawing manual,
for everything in §7.1's right-hand column);
[ADR-0005](../../docs/adr/0005-devices-authored-in-the-drawing.md) and
[ADR-0006](../../docs/adr/0006-togglability-is-decided-by-the-house.md).
