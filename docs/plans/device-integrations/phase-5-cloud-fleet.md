# Phase 5 — The cloud fleet: LG, Whisker, Petlibro, Emporia

Four account-credential integrations. No local path exists for any of them
today (§3.4, §3.7–3.10) — all bind `connectivity: cloud`, displayed as
such in the Popup, accepted as second-class per the architecture. Each
subsection is independent; do them in any order, ~15 min each plus
account fiddling.

## 0. HACS first (Petlibro and Emporia need it)

HACS on HA **Container** installs via script into the config volume, on
the laptop:

```sh
docker exec -it homeassistant bash -c "wget -O - https://get.hacs.xyz | bash -"
docker compose restart homeassistant
```

Then Settings → Devices & Services → Add → HACS → GitHub device-code
auth. HACS's own updates are manual — fine; the Hub is pinned and
deliberate about versions by policy.

## 1. LG washer + dryer — core `lg_thinq`

Prereq: a **Personal Access Token** from the ThinQ account:
connect-pat.lgthinq.com → sign in with the LG account the appliances are
registered to → create PAT. Add integration → **LG ThinQ** → paste PAT +
country. Washer/dryer arrive with run-state, cycle, remaining-time
sensors (cloud push — updates arrive in near-real-time).

Bindings (both are `StatusState` kinds):

```yaml
  washer:
    entity: sensor.<washer>_run_state     # exact ids from HA
    connectivity: cloud
  dryer:
    entity: sensor.<dryer>_run_state
    connectivity: cloud
```

**Verify**: start a cycle; the Panel pin shows it running; when it
finishes, the status returns to idle. (A "cycle finished" Popup/notify is
future Automation material — Automations live in the Hub, not the Panel.)

## 2. Litter-Robot 5 Pro — core `litterrobot`

Add integration → **Whisker (Litter-Robot)** → Whisker account creds.
Entities: cycle status, litter/waste levels, sensors + a start-clean
button entity.

```yaml
  litter-robot:
    entity: sensor.<litter_robot>_status
    connectivity: cloud
```

**Verify**: trigger a clean cycle from HA; status walks through
cycling→idle on the pin.

## 3. Petlibro One RFID + Granary camera feeder — HACS `petlibro`

HACS → Integrations → search **Petlibro** (community integration,
jjjonesjr33/petlibro lineage) → install → restart HA → Add integration →
Petlibro → account creds. **Device-model coverage is the UNVERIFIED bit**
(§3.8–3.9): the One RFID (PLAF301) and Granary camera (PLAF203) are both
newer models; after setup, check exactly which entities each got. Expect
feeding-schedule state, last-feed, food level where supported; the
Granary's *camera* is NOT expected to stream (its video is app-locked —
any camera entity is a bonus, not a plan item).

```yaml
  feeder-petlibro:
    entity: sensor.<petlibro_one>_<best-status-entity>
    connectivity: cloud
  feeder-granary:
    entity: sensor.<granary>_<best-status-entity>
    connectivity: cloud
```

If a model turns out unsupported: leave its `entity:` unbound (pin
renders with unknown state — the honest representation) and file an
upstream issue; do not substitute a fake.

## 4. Emporia Vue 3 + Emporia outlets — HACS `emporia_vue` (D2: cloud now)

HACS → **Emporia Vue** community integration → install → restart → add →
Emporia account creds. Vue 3 arrives as per-circuit power sensors
(~1-minute cloud cadence); Emporia smart plugs arrive as switches with
power readings.

```yaml
  energy-monitor:
    entity: sensor.<vue3>_total_power     # W-valued; PowerState kind
    connectivity: cloud
  # Emporia plugs: bind to outlet-* Keys matching their real rooms, e.g.
  outlet-master:
    entity: switch.<emporia_plug_1>
    connectivity: cloud
```

**The ESPHome reflash stays a separate bench day** (deferred, D2): Vue 3
and the plugs are ESP32-based and flashable for fully-local operation
(§3.4 — back up stock firmware first; Vue 3 needs disassembly + UART).
When that day comes, the entities change ids and `connectivity` flips to
`local` — a bindings-only edit, which is the whole point of the seam.

**Verify**: per-circuit watts move when a known load (kettle, EV) turns
on; Emporia plug toggles from the Panel.

## Done when

- All four integrations report entities; every subsection's bindings are
  in `bindings.yaml`; nothing in this phase claims `connectivity: local`.
- The Panel shows: laundry status, litter-robot status, feeder status ×2,
  live circuit watts, and toggles the Emporia plugs.
- Petlibro coverage findings (which model got what) are recorded in this
  file for the future local-retrofit review.
