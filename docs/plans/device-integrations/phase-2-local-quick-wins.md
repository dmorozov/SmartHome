# Phase 2 — Local quick wins: Kasa, Tesla Wall Connector, Ecobee

Three integrations, zero new containers. Ends with the first physical
device toggled from the Dollhouse and a local climate entity for the
`thermostat` pin.

## 1. Kasa outdoor plug + two wall switches

Hardware first: the two Kasa Wi-Fi light switches are still uninstalled —
in-wall mains work, which is in scope for the owner. Breaker off, verify
dead, neutral required (Kasa switches need a neutral in the box). Onboard
each device with the Kasa app to get it onto the Wi-Fi (provisioning needs
the app), then give **each device a DHCP reservation**.

HA side (host networking = discovery just works): Settings → Devices &
Services — the `tplink` integration self-discovers each device; confirm
each. If one doesn't appear, add manually by IP. Entities arrive as
`switch.<name>` (plug) and `switch.`/`light.<name>` (switches).

Bindings (D5 — placeholder Keys; pick the Keys whose Rooms best match the
real placement, e.g.):

```yaml
  outlet-media:            # or whichever Room the outdoor plug maps to
    entity: switch.<kasa-plug-entity>
    connectivity: local
  light-family:
    entity: light.<kasa-switch-1>     # or switch.* — bind what HA created
    connectivity: local
```

**Verify**: tap the Room/pin in the Panel → the physical plug clicks;
toggle at the wall → the pin updates (state_changed round-trip). This is
the plan's first end-to-end proof.

## 2. Tesla Wall Connector

Local HTTP, monitoring only (§3.12 — there is no control API). Find its
IP (router table), reserve it, then Settings → Devices & Services → Add →
**Tesla Wall Connector** → host `<wc-ip>`. Entities: vitals as sensors
(state, vehicle connected, session energy, power).

Binding: `ev-charger` is a `PowerState` kind — bind the **watts** sensor:

```yaml
  ev-charger:
    entity: sensor.<wall-connector>_power   # exact id from HA; W-valued
    connectivity: local
```

**Verify**: pin shows live watts; plug a car in (or wait for one) and the
reading moves.

## 3. Ecobee — dual path (grilling decision, 2026-08-03)

Both integrations, same thermostat, run simultaneously (§3.3): cloud for
features, HomeKit for local resilience. **The Panel binds to the HomeKit
entity** — local-first is the house rule; the cloud entities serve a
future schedules/vacations UI.

### 3a. Cloud (5 min)

Settings → Devices & Services → Add → **ecobee** → ecobee.com username +
password (TOTP MFA supported). No developer API key — keyless since HA
2026.3; our pin is 2026.7. Entities: `climate.*`, remote sensors, weather.

### 3b. HomeKit-controller (local)

Slot confirmed free (Alexa is cloud-to-cloud and doesn't occupy it; never
paired to Apple Home). On the thermostat touchscreen: **Main Menu →
Settings → Apple HomeKit → Enable/Pair** → it displays a setup code. In
HA: the discovered **HomeKit Device** appears in Settings → Devices &
Services (zeroconf, works under host networking) → Configure → enter the
code. If it doesn't appear within a minute: thermostat and laptop must be
on the same subnet/VLAN; power-cycle the thermostat's HomeKit menu and
retry. Entities arrive as a second `climate.*` (+ humidity/temperature
sensors).

Binding:

```yaml
  thermostat:
    entity: climate.<homekit-entity-id>   # the LOCAL one, not the cloud one
    connectivity: local
```

**Verify — the outage drill** (this is why the dual path exists): pull the
laptop's WAN (or block ecobee.com), and setpoint changes from the Panel
must still work via the HomeKit entity while the cloud `climate.*` goes
unavailable. Restore, both recover. Log lines to watch:
`hub.state_unusable` / `hub.state_recovered` for the cloud entities.

## Done when

- Kasa plug + both switches toggle from the Panel and report wall-side
  changes; all three `connectivity: local`.
- `ev-charger` pin shows live power.
- Two climate entities exist; Panel binds the HomeKit one; the outage
  drill passes.
- `hub.missing_entities` no longer lists any of this phase's entities.
