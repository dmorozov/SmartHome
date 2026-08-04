# 3 — Home Assistant

Home Assistant is already running when you get here — the hub-stack chapter
left `homeassistant` Up on host networking, port 8123. What is left is the
part with no compose file behind it: an owner account, a long-lived token, the
MQTT integration, and then every integration after that.

Do the first three in a browser once. Do everything after that headlessly —
§3.5 is why.

Everything below was measured against the live Hub on 2026-08-04:
HA **2026.7.4**, image `ghcr.io/home-assistant/home-assistant:2026.7`,
`network_mode: host`, at `http://192.168.68.81:8123`.

Sibling material: [`../../hub/README.md`](../../hub/README.md) (the stack and
the mini PC migration), [`../../hub/compose.yaml`](../../hub/compose.yaml),
[`../../docs/plans/device-integrations/phase-1-hub-stack.md`](../../docs/plans/device-integrations/phase-1-hub-stack.md)
(broker auth bootstrap + the as-built record this chapter continues), and
[`../../docs/plans/device-integrations/phase-2-local-quick-wins.md`](../../docs/plans/device-integrations/phase-2-local-quick-wins.md)
(the first integrations driven through §3.5).

## 3.1 First run

Open `http://<hub-ip>:8123`. Onboarding is four server-side steps, and you can
ask the Hub which of them are done without logging in — this endpoint needs no
auth:

```sh
curl -s http://<hub-ip>:8123/api/onboarding
```

```json
[{"step":"user","done":true},{"step":"core_config","done":true},
 {"step":"analytics","done":true},{"step":"integration","done":true}]
```

All four are `true` on this Hub. A fresh instance answers `false` and the web
UI walks them in that order: create the owner account, set location/units,
choose analytics, then a "here is what we found on your network" page.

**Name it for the house, not for the laptop.** This instance is the one that
migrates to the mini PC — the whole of `hub/ha-config` (accounts, tokens,
registries, the recorder DB) is copied across and comes up as the same Home
Assistant. Nothing in it is re-created there, so a name like "legion" or
"dev-laptop" becomes wrong the day the box changes.

The instance name itself is cosmetic and changeable later (§3.5, `hactl`, shows the
one-command form). The account is not: it is the identity every long-lived
token is minted against.

### Units are a Panel trap, not a preference

As built, this Hub is US customary:

| Setting | Value |
|---|---|
| `location_name` | `Home` |
| `unit_system` | `us_customary` (temperature `°F`) |
| `time_zone` | `America/Los_Angeles` |
| `currency` / `country` | `USD` / `US` |

Home Assistant converts climate temperatures into the configured unit system
before they reach the WebSocket API, and a `climate.*` entity does **not** name
its own unit — measured: `GET /api/states/climate.main_floor` returns
`"current_temperature": 83` with no unit anywhere. So the reading is only
interpretable against the Hub's `unit_system`.

**This was a live defect and is now FIXED (2026-08-04).** The Panel used to read
the number straight into a field called `currentC` and render it with a `°C`
suffix, so on this `us_customary` Hub a real Ecobee binding rendered
**`83.0 °C`** on the Dollhouse. The fix keeps the number in the Hub's own unit
and carries the unit with it rather than converting:

- [`../../panel/lib/domain/device_state.dart`](../../panel/lib/domain/device_state.dart)
  — `TemperatureUnit`; `ThermostatState.current` / `.target` / `.unit`. The
  lying `currentC` name was the root cause, so it is gone.
- [`../../panel/lib/data/ha_hub.dart`](../../panel/lib/data/ha_hub.dart) — asks
  the Hub `get_config` after `auth_ok` and on every reconnect, and relabels any
  thermostat already folded if the answer arrives late.
- [`../../panel/lib/ui/device_presentation.dart`](../../panel/lib/ui/device_presentation.dart)
  — one rule for degrees. Unknown unit renders a bare `83.0°`, which asserts
  nothing that can be wrong.

You do **not** need to set this Hub to `metric` to protect the Panel, and you
should not: everything else in the house would go metric with it.

Changing the unit system after onboarding is not a re-install — see §3.5, `hactl`.

## 3.2 The long-lived token

The Panel authenticates with a long-lived access token (valid 10 years).
Mint it from your own user profile: the avatar at the bottom of the sidebar →
the **Security** tab → **Long-lived access tokens** → create. HA shows the
token exactly once.

> The tab and button wording above is what
> [`../../hub/ha-config/configuration.yaml`](../../hub/ha-config/configuration.yaml)
> and `hub/README.md` already record; it was **not** re-verified in the UI for
> this chapter (the token on this Hub predates it). Treat the exact labels as
> UNVERIFIED and navigate by what they do: profile page, security section,
> long-lived tokens.

Store it at `hub/token`, 0600, and never anywhere else:

```sh
cd <repo>                            # repo root; every path below is from here
install -m 600 /dev/null hub/token   # create empty, correct mode, up front
cat > hub/token                      # paste the token, then Ctrl-D
```

`cat >` rather than an `echo`/`printf` one-liner on purpose: the token never
enters shell history that way. A trailing newline is harmless — every reader
here uses `$(cat hub/token)`, which strips it.

`token` is gitignored (`hub/.gitignore`, the phase-1 §1d addition). Verify both
facts before you move on:

```sh
git check-ignore -v hub/token           # must print the ignore rule
curl -s -H "Authorization: Bearer $(cat hub/token)" http://127.0.0.1:8123/api/
#  -> {"message":"API running."}
```

Everything in §3.5 reads this file. So does the appliance path
(`PANEL_HA_TOKEN` → `/etc/smarthome/panel.env`) and
`panel/test/ha_hub_live_test.dart`.

## 3.3 MQTT integration

Add it in the UI: settings → the devices-and-services page → add an
integration → MQTT (exact labels **UNVERIFIED** for 2026.7 — navigate by
function; the headless equivalent is in §3.5 and needs no menu at all). The
form is one page: on HA Container there is no supervisor, so the flow skips
the "add-on or manual broker" menu and goes straight to the broker step.

| Field | Value | Why |
|---|---|---|
| Broker | `127.0.0.1` | HA is host-networked, so localhost **is** the Hub host, and Mosquitto publishes 1883 on it |
| Port | `1883` | `hub/mosquitto/config/mosquitto.conf`: `listener 1883 0.0.0.0` |
| Protocol | `5` | The form's default at 2026.7 (`DEFAULT_PROTOCOL = PROTOCOL_5`) — leave it |
| Username | `ha` | Created by the broker bootstrap, phase 1 §1c |
| Password | `MOSQUITTO_HA_PASSWORD` from `hub/.broker-passwords.env` | Never typed into this repo |
| Advanced options | unchecked | TLS/websockets/client-id live behind it; none apply here |

The form validates by actually connecting, so a wrong password fails on submit
rather than later.

As built, the stored entry is exactly:

```json
{"broker": "127.0.0.1", "port": 1883, "protocol": "5", "username": "ha"}
```

`127.0.0.1` is deliberate and survives the mini PC migration unchanged — it
means "the broker on this appliance" on any box. Do not put the LAN IP here.

Nothing arrives from MQTT yet: ring-mqtt has no Ring token until phase 3, and
Zigbee2MQTT is parked behind the `zigbee` compose profile. A loaded `mqtt`
entry with zero devices is the correct end state for this chapter.

## 3.4 What is done when you close the browser

```sh
cd <repo>
curl -s -H "Authorization: Bearer $(cat hub/token)" \
  http://127.0.0.1:8123/api/config/config_entries/entry \
  | python3 -c 'import json,sys; [print(e["domain"], e["state"]) for e in json.load(sys.stdin)]'
```

Expect `mqtt loaded`. Expect `bluetooth setup_retry` — that one is §3.7, a known
open issue, not your mistake.

## 3.5 The headless path

Everything past MQTT is driven over the API. Three reasons, in order of how
much they matter:

1. **Repeatability.** A REST call is a line you can paste into an as-built
   record. A click path is not, and the UI wording moves between monthly
   releases.
2. **The browser is on another machine.** The Hub is headless; the operator's
   browser is on the Mac. A flow that needs a code off a device touchscreen
   does not care where the browser is; the ones that need nothing but a host
   and a password should not need a browser at all.
3. **It is how the current fleet actually got in.** The three `tplink` entries
   on this Hub were added this way, with no browser involved.

### Config flows are REST

A config flow is a state machine: create it, read the form it wants, post the
answers, repeat until it returns `"type": "create_entry"` or `"abort"`.

| Method + path | Does |
|---|---|
| `POST /api/config/config_entries/flow` | Start a flow. Body `{"handler": "<domain>"}`. Returns the first step (or an abort) |
| `GET /api/config/config_entries/flow/{flow_id}` | Current step of a live flow, including its `data_schema` |
| `POST /api/config/config_entries/flow/{flow_id}` | Submit one step. Body is the step's fields |
| `DELETE /api/config/config_entries/flow/{flow_id}` | Abort/dismiss a flow (this is what the ✕ on a discovery card does) |
| `GET /api/config/config_entries/flow_handlers` | Every domain that has a config flow |
| `GET /api/config/config_entries/entry` | All config entries: domain, title, source, state, failure reason |
| `POST /api/config/config_entries/entry/{entry_id}/reload` | Reload one entry |

Two measured details that cost time if you assume otherwise:

- **`GET /api/config/config_entries/flow` returns `405: Method Not Allowed`.**
  The index view implements POST only. Listing *pending* flows — everything
  discovery has queued up — is a WebSocket call (*What only the WebSocket
  gives you*, below). That split is the whole reason this path needs both
  transports.
- Every one of these requires an **admin** token. The long-lived token from
  §3.2 is one, because your onboarding account is the owner.

All calls carry the token and JSON:

```sh
cd <repo>/hub
T=$(cat token); H="Authorization: Bearer $T"
curl -s -H "$H" -H 'Content-Type: application/json' \
  -X POST http://127.0.0.1:8123/api/config/config_entries/flow \
  -d '{"handler":"tplink"}'
```

### Worked example — the tplink entries

This is the recorded path for the three Kasa devices on this Hub. Field names
verified against `homeassistant/components/tplink/config_flow.py` in the
running image.

```sh
# 1. start the flow -> step_id "user", one field: host
FLOW=$(curl -s -H "$H" -H 'Content-Type: application/json' \
  -X POST http://127.0.0.1:8123/api/config/config_entries/flow \
  -d '{"handler":"tplink"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["flow_id"])')

# 2. an EMPTY host is not an error — it branches to step_id "pick_device",
#    which runs tplink's broadcast discovery and lists what it found.
curl -s -H "$H" -H 'Content-Type: application/json' \
  -X POST http://127.0.0.1:8123/api/config/config_entries/flow/$FLOW \
  -d '{"host":""}'

# 3. answer with the formatted MAC from that list
curl -s -H "$H" -H 'Content-Type: application/json' \
  -X POST http://127.0.0.1:8123/api/config/config_entries/flow/$FLOW \
  -d '{"device":"5c:a6:e6:09:b6:19"}'
#  -> {"type":"create_entry","title":"Old fridge HS103", ...}
```

Step 2 is in the source, not folklore:
`if not (host := user_input[CONF_HOST]): return await self.async_step_pick_device()`.
The `pick_device` key is `device` and its values are formatted MACs
(lowercase, colon-separated). Passing a real IP at step 1 skips straight to
creating the entry.

### The same shape for MQTT

The MQTT entry on this Hub was created in the browser (§3.3), so the sequence
below is **UNVERIFIED end-to-end** — the endpoints are verified, and the field
names are read from `mqtt/config_flow.py` in the running image, but nobody has
run these two calls on this box:

```sh
FLOW=$(curl -s -H "$H" -H 'Content-Type: application/json' \
  -X POST http://127.0.0.1:8123/api/config/config_entries/flow \
  -d '{"handler":"mqtt"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["flow_id"])')
# step_id "broker": broker, port, protocol, username, password, advanced_options
curl -s -H "$H" -H 'Content-Type: application/json' \
  -X POST http://127.0.0.1:8123/api/config/config_entries/flow/$FLOW \
  -d "{\"broker\":\"127.0.0.1\",\"port\":1883,\"protocol\":\"5\",\"username\":\"ha\",\"password\":\"$MOSQUITTO_HA_PASSWORD\"}"
```

If you do run it, source the password rather than typing it:
`set -a; . <repo>/hub/.broker-passwords.env; set +a` — and remember that the
shell history now holds it.

### What only the WebSocket gives you

`ws://127.0.0.1:8123/api/websocket`, authenticate with the same token, then
send commands with incrementing integer `id`s. The ones this house needs:

| Command | Gives |
|---|---|
| `config_entries/flow/progress` | **Every pending flow**, with `handler`, `context.source`, and `step_id`. The headless equivalent of the discovered-devices list |
| `config_entries/flow/subscribe` | Live add/remove events for the same, for a watch loop |
| `config_entries/get` | All entries, same content as the REST `entry` list |
| `config_entries/subscribe` | Live entry changes |
| `config/entity_registry/list` | Every entity: `entity_id`, `platform`, `disabled_by`. This is where binding candidates come from |
| `config/device_registry/list` | Devices, and which entries they belong to |
| `config/core/update` | Location, time zone, currency, `unit_system` — see below |

### `hactl` — the driver

**It is in the repo: [`hactl`](hactl), next to this file. Do not re-derive it,
and do not inline a one-off script beside it.** This is the single documented
WebSocket mechanism for the whole guide; chapter 4 calls the same tool.

```sh
cd <repo>/appliance/commissioning
./hactl '[{"type":"config_entries/flow/progress"}]'
```

Why it is shaped the way it is:

- **It runs inside the HA container.** The Hub host has `curl` and `python3`
  but **no `aiohttp`, no `websockets`, and no `zeroconf`** — all three measured
  as `ModuleNotFoundError` on 2026-08-04 — and installing any of them needs
  sudo, which this host does not hand out without a password. The container
  already ships `aiohttp 3.14.3` on Python 3.14.6, and `docker exec` needs no
  sudo because your user is in the `docker` group.
- **It reaches HA at `127.0.0.1:8123` from in there**, which works only because
  HA is host-networked (chapter 2 §1). On a bridge-networked HA this address
  would be wrong.
- **The token goes through `docker exec -e`**, so it never appears in a command
  line, in `ps`, or in `docker inspect` of the long-lived container. Do not
  "simplify" it into an argv position.
- **The argument is a JSON array** of command objects, run in order on one
  authenticated connection; `id` is added for you. Output is a JSON array of
  `{cmd, success, result, error}`, one element per command — pipe it into
  `python3 -c` and filter. Non-`result` frames (events) are skipped.
- **Exit status is meaningful**: 0 only if every command returned
  `success: true`. A failed command still prints, with its `error` object, so a
  batch is debuggable.

It resolves `hub/token` from its own location, so it works from any cwd.
`HUB_DIR`, `HA_CONTAINER` and `HA_WS_URL` override that if the layout differs.

Verified calls — the outputs below were produced by this tool against this Hub
on 2026-08-04:

```sh
# every entry, one line each
./hactl '[{"type":"config_entries/get"}]' | python3 -c '
import json,sys
for e in json.load(sys.stdin)[0]["result"]:
    print(e["domain"], "|", e.get("title"), "|", e.get("source"), "|", e.get("state"), "|", e.get("reason"))'

# what discovery is holding for you right now
./hactl '[{"type":"config_entries/flow/progress"}]'

# binding candidates for a platform (disabled_by "integration" = diagnostic,
# not created unless you enable it)
./hactl '[{"type":"config/entity_registry/list"}]' | python3 -c '
import json,sys
for e in json.load(sys.stdin)[0]["result"]:
    if e.get("platform") == "tplink": print(e["entity_id"], e.get("disabled_by"))'
```

The first of those printed this on 2026-08-04 — the non-`system` rows are the
whole integrated fleet at the end of chapter 4:

```text
mqtt               | 127.0.0.1                    | user      | loaded
tplink             | TP-LINK_Smart Plug_722C EP40 | user      | loaded
tplink             | Old fridge HS103             | user      | loaded
tplink             | Aquarium HS103               | user      | loaded
rachio             | den.morozov@gmail.com        | homekit   | loaded
homekit_controller | Main Floor                   | zeroconf  | loaded
bluetooth          | Intel Corporate None (…)     | integration_discovery | setup_retry
```

Note `rachio`'s source: **`homekit`**, not `user`. That entry was created from
the *branded* card that a HomeKit advert raised — which is the cloud
integration. §3.6 is about exactly that, and the `source` field is how you tell
after the fact which card someone clicked.

`config/entity_registry/list` returned **65** entities on this Hub, 22 of them
`tplink`: five switches that actually switch (the EP40 parent plus its two
children, and the two HS103s), plus a `_led` switch and a `_cloud_connection`
binary sensor per device, plus diagnostics that arrive
`disabled_by: "integration"` and create nothing until enabled. Which of those
may be bound — and which are foot-guns — belongs to the Panel's
`panel/assets/house/bindings.yaml` work, not to this chapter.

Changing core config headlessly, e.g. the units decision from §3.1:

```sh
./hactl '[{"type":"config/core/update","unit_system":"metric","update_units":true}]'
```

`unit_system` accepts `metric` or `us_customary` (`imperial` is accepted as a
deprecated alias). `update_units: true` also re-suggests units on existing
entities. Same command takes `location_name`, `time_zone`, `currency`,
`country`, `latitude`/`longitude`/`elevation`.

### Onboarding over REST — exists, unused

`/api/onboarding/users`, `/core_config`, `/analytics`, `/integration` are real
endpoints, unauthenticated until the step is done, and
`POST /api/onboarding/users` takes `{name, username, password, client_id,
language}` and returns an `auth_code` to exchange for tokens. This Hub was
onboarded in a browser, so that path is **UNVERIFIED here** — recorded only so
that a future from-scratch rebuild knows it does not have to open a browser at
all. `GET /api/onboarding` (§3.1) is the one endpoint of the set that has been
exercised.

## 3.6 What discovery does, and does not do

The discovered-devices page is not magic and not complete. It is a queue of
*pending config flows* that some discovery component created for you. Same
flows, same REST endpoints as §3.5 — the only difference is that HA started
them and pre-filled the host.

Active on this Hub (all via `default_config`): `dhcp`, `zeroconf`, `ssdp`,
`usb`, `bluetooth`, plus `integration_discovery` (integrations telling each
other about things).

| Mechanism | Covers | Measured limit on this LAN |
|---|---|---|
| zeroconf/mDNS | HomeKit, AirPlay, Roku, printers… | Works. The Rachio's `_hap._tcp` advert is visible from inside the HA container — "must be the same VLAN" is a red herring here |
| dhcp | Devices whose MAC/hostname matches an integration's manifest | `tplink`'s manifest lists 37 MAC prefixes and **`5CA6E6` is not one of them** — all three Kasa devices are `5C:A6:E6:*`, so none of them ever raised a DHCP card |
| ssdp | UPnP | Raised exactly one flow: the Deco gateway as `upnp` / `XE75Pro` |
| Integration-owned broadcast | e.g. `tplink`'s own UDP 9999 sweep | Only runs from an open flow's `pick_device` step, or on a schedule **once an entry exists**. So the *first* Kasa cannot self-discover; add it manually and the rest follow |
| bluetooth | BLE devices | Broken here — §3.7 |

Consequences worth internalising:

- **An empty discovery list is not evidence a device is absent.** The Kasa
  fleet was on the LAN and answering the whole time.
- **A pending flow is inert.** It holds no entry, creates no entity, and
  survives restarts. `DELETE /api/config/config_entries/flow/{flow_id}`
  dismisses one; ignoring it costs nothing.
- **One advert can raise two different flows.** **Recorded observation,
  2026-08-04, before either device was integrated** — one
  `Rachio-BFF806._hap._tcp.local.` advert, two cards:

  ```text
  handler: rachio             source: homekit    step: user   <- CLOUD integration
  handler: homekit_controller source: zeroconf   step: pair   <- LOCAL integration
                              alternative_domain: rachio
  ```

  The vendor-branded card is the cloud integration; `homekit_controller` is the
  local one. Picking the branded card gets you cloud-backed entities that the
  Panel would then label `connectivity: local`. Read `handler`, not the pretty
  name — which is exactly what `config_entries/flow/progress` shows you and the
  UI card does not. The full treatment, including what it costs downstream, is
  [`04-devices-local.md` §4.2.1](04-devices-local.md).

  **The pair is dated because completing either half consumes that half's
  card.** Later the same day, with the Rachio's *cloud* entry created and the
  Ecobee's *local* pairing created, `config_entries/flow/progress` reads:

  ```text
  handler: upnp               source: ssdp      step: ssdp_confirm   name=XE75Pro
  handler: homekit_controller source: zeroconf  step: pair           name=Rachio-BFF806
                              alternative_domain: rachio               category=Bridge
  handler: ecobee             source: homekit   step: user
  ```

  Two devices, and each is now showing the *opposite* surviving half: the
  Rachio's local card is still open because only its cloud path is done, and
  the Ecobee's branded cloud card is still open because only its local path is
  done. Nothing about the trap changed — the evidence for it just moved. Both
  survivors are wanted here (the owner's decision is that Rachio and Ecobee each
  get **both** paths), so neither is dismissed.

  Corollary worth knowing before you go looking for a card that "should" be
  there: **a device that is already paired stops advertising itself as
  pairable**, so its `homekit_controller` card does not come back. The mDNS flag
  that carries this is measured in
  [`04-devices-local.md` §4.2.2](04-devices-local.md).

## 3.7 Known open issue — bluetooth `setup_retry`

`integration_discovery` finds the laptop's Intel adapter and adds a `bluetooth`
entry on its own. It cannot set up. Current state, verbatim from
`config_entries/get`:

```text
domain: bluetooth   title: Intel Corporate None (AC:45:EF:D2:E5:4B)
source: integration_discovery   state: setup_retry
reason: hci0 (AC:45:EF:D2:E5:4B): DBus service not found;
        docker config may be missing `-v /run/dbus:/run/dbus:ro`: {ex}
```

(The trailing `{ex}` is an unformatted placeholder in HA's own message, not a
truncation.) The container has no path to the host's system bus; the socket is
there on the host — `/run/dbus/system_bus_socket` — just not mounted in.

The fix is one line in the `homeassistant` service in
[`../../hub/compose.yaml`](../../hub/compose.yaml):

```yaml
    volumes:
      - ./ha-config:/config
      - ./custom_components:/config/custom_components
      - /run/dbus:/run/dbus:ro          # <- not present today
```

followed by `cd <repo>/hub && docker compose up -d homeassistant` (recreates
the container; no sudo, no state loss — `ha-config` is a bind mount).

**This has NOT been applied.** It is written down as the known remedy, not as a
step you have completed. Before applying it, decide whether this Hub should
have Bluetooth at all: nothing in phases 1–6 needs BLE, the adapter belongs to
the laptop and will not exist on the mini PC in the same form, and mounting the
system bus read-only into a container is a real (small) increase in what that
container can see. The honest alternative is to disable the entry and let the
Hub stop retrying. Disabling is **WebSocket only** — there is no REST view for
it, only `entry`, `entry/{entry_id}` and `entry/{entry_id}/reload`:

```sh
./hactl '[{"type":"config_entries/get"}]' | python3 -c '
import json,sys
for e in json.load(sys.stdin)[0]["result"]:
    if e["domain"] == "bluetooth": print(e["entry_id"])'
# then, with that id:
./hactl '[{"type":"config_entries/disable","entry_id":"<entry_id>","disabled_by":"user"}]'
```

> The disable command is **UNVERIFIED** — it has not been run on this Hub. Its
> schema (`entry_id`, `disabled_by` accepting only `"user"` or `null`) is read
> from `config/config_entries.py` in the running image, and the same action is
> available in the UI on the entry's own card. The read-only half (finding the
> `entry_id`) is verified.

Either way, `setup_retry` on `bluetooth` is expected output on this Hub today
and is not a symptom of anything else being wrong.

## 3.8 Operational notes

- **`hub/ha-config` runtime state is root-owned.** `.storage`, the recorder DB
  and the logs are written by the container as root; this host has no
  passwordless sudo, so deleting or moving them is an operator action, not
  something a script here can do. `git status` stays clean regardless — git
  tracks modes, not owners.
- **`.storage` holds credentials in the clear** (the MQTT password, every
  integration's tokens). It is gitignored. The mini PC migration copies it, so
  it moves over a channel you trust.
- **Pin discipline.** HA is pinned to `2026.7` on purpose. `hub/README.md`
  carries the dated risk that matters before moving past `2026.8` (the
  `samsungtv` implicit Wake-on-LAN removal). The pin is the guard; do not float
  it to keep an integration happy.
- **Secrets referenced, never inlined.** Broker passwords:
  `hub/.broker-passwords.env` (0600, gitignored). Panel token: `hub/token`
  (0600, gitignored). Neither value belongs in this repo, in a shell history,
  or in an as-built table.
