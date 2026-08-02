# SH3D → Dollhouse: Architecture Spec — FINAL

**Supersedes v3.** Appendix A records the Home Assistant verification that
prompted the one substantive correction (§1.2). §14 lists changes from v3.

---

## 1. Identity model

```
  PLACEMENT              DEVICE                 ENTITY
  a marker in the plan   physical hardware      a controllable channel
  owned by: the .sh3d    owned by: HA registry  owned by: HA
  changes: house edits   changes: hardware      changes: constantly
```

**The plan produces keys, never entities.** Resolution from key to entities is
always a separate lookup — sometimes trivial, never skipped.

| Case | How it resolves |
|---|---|
| Ceiling fan with a light | one key → two entities |
| Thermostat (climate + temp + humidity + battery) | one key → four entities |
| HVAC unit serving three rooms | three placements, same key, no special case |
| Bulb swapped, entity ID changes | HA changes; plan untouched; no re-upload |
| Device copy-pasted in SH3D | duplicate key — legal, warned, both render |

### 1.1 `id` versus `key`

- **`key`** — resolves to entities. Author-controlled. **May repeat.**
- **`id`** — per-placement, converter-generated, unique per artifact.
  **Not stable across edits.**

**Contract:** consumer state — hidden markers, overrides, saved views — must key
off `key`, never `id`.

### 1.2 Room and level keys — CORRECTED

v3 recommended setting `roomKey` to the HA `area_id` and `levelKey` to the HA
`floor_id`, on the grounds that both are rename-stable. **Both are indeed
rename-stable** (Appendix A.1, A.2) — but the recommendation was still wrong,
for a reason the stability question obscured.

**HA area IDs are not uniformly formatted.** Some are slugified names
(`kitchen`); others are 32-character hex strings
(`51721157e7d0491abbffa49c9b069e7e`), depending on how and when the area was
created (A.3). A designer cannot be asked to type that into an SH3D property
field, and a typo in it is undetectable by eye.

**Final rule:** `roomKey` and `levelKey` are **human-readable and
author-controlled** (`kitchen`, `ground_floor`). The HA join lives in the
resolver as an explicit mapping table:

```yaml
# resolver config, not the plan artifact
areas:
  kitchen:      { ha_area_id: "51721157e7d0491abbffa49c9b069e7e" }
  living_room:  { ha_area_id: "living_room" }
floors:
  ground_floor: { ha_floor_id: "ground_floor" }
```

Seed it once by name matching with human confirmation, then freeze. This costs
one small table and buys three things: the plan stays readable, it stays
hub-agnostic (consistent with §3.3), and a designer never handles an opaque ID.

Slug-of-name remains a **fallback only** for `roomKey`/`levelKey`, and using it
emits a warning naming the room — deriving identity from a display name means
renaming "Kitchen" to "Kitchen / Diner" silently breaks every reference.

---

## 2. Bindable

One fragment, three hosts:

```yaml
key: kitchen_ceiling_fan     # resolution key; may repeat
role: fan                    # OPEN string
capabilities: [on_off, brightness]   # HINT only — see §3
meta: {}                     # namespaced passthrough
```

Attaches to **placements**, **openings** (smart locks, garage doors, blinds),
and **rooms** (area occupancy, room climate).

Any SH3D user property the converter does not recognise lands in `meta` under
its original name rather than being dropped, so a panel feature can read a new
property before the converter has heard of it.

---

## 3. Home Assistant is the capability authority

HA knows what the hardware supports. The plan does not, and should not pretend
to. But **HA has no cross-domain capability vocabulary** — it has three
mechanisms that together approximate one:

| Source | Gives | Catch |
|---|---|---|
| Domain (`light.`, `cover.`, `climate.`) | coarse type | too coarse to render from |
| `supported_features` bitmask | the real data | per-domain; bit 1 differs between `cover` and `climate`, so values are not comparable across domains |
| `device_class` | semantic subtype (`motion`, `garage`, `outlet`) | optional, integration-dependent |
| `supported_color_modes` | `onoff`, `brightness`, `color_temp`, `hs`, `rgb`, `rgbw`, `rgbww`, `xy`, `white` | lights only; superseded the old brightness/colour feature flags |

The vocabulary is **derived**, not read — reducing the problem from inventing a
taxonomy to writing a testable mapping function.

### 3.1 Capabilities are runtime state

`supported_features` and `supported_color_modes` live in **state attributes,
not the registry.** An entity that is unavailable or not yet loaded reports
nothing, and values can change at runtime after a firmware update or a Zigbee
re-interview.

This is why freezing capabilities into `plan.yaml` would be wrong by
construction, and it independently confirms read-time resolution (§5). The
resolver joins two sources: the **registry** for identity, area and device
relationships, and the **state stream** for capabilities.

`device_id` may be null — helpers, template entities and groups have no device.

### 3.2 What the plan's hints are for

`role` and `capabilities` in `plan.yaml` exist **only** to draw something
sensible before the WebSocket connects, and to keep offline mode useful. They
need not be complete or correct. The moment `subscribe_entities` delivers
state, HA's answer wins. A hint disagreeing with HA is not an error; it is a
stale guess being corrected.

### 3.3 Carry both shapes

```yaml
capabilities: [on_off, brightness, color_temp]   # normalized, §4
hub:
  domain: light
  device_class: null
  supported_features: 0
  supported_color_modes: [color_temp]
  entity_id: light.kitchen_fan_light
```

The panel renders from `capabilities` and escape-hatches to `hub` for anything
the vocabulary does not yet cover. The mapper is lossy by design, so the
lossless original stays beside it. A second hub, or Matter-direct, then needs a
new mapper rather than a panel rewrite.

**Never key on `entity_id`.** Beyond the usual churn, HA has been actively
changing how entity IDs are generated, including a 2026 change that introduced
area-derived prefixes (A.4). Entity IDs are display and call targets, not
identity.

---

## 4. Capability vocabulary v1

Open list. Unknown values must degrade, never error (§10).

**Control** — `on_off` · `brightness` · `color_temp` · `color` · `position`
(0–100) · `tilt` · `set_temperature` · `hvac_mode` · `fan_speed` · `lock` ·
`open` · `volume` · `playback` · `preset`

**Read** — `temperature` · `humidity` · `illuminance` · `power` · `energy` ·
`battery` · `motion` · `occupancy` · `contact` · `moisture` · `smoke` · `co2` ·
`stream`

**Roles** (icon defaults only) — `light` · `switch` · `outlet` · `cover` ·
`blind` · `curtain` · `garage` · `lock` · `door` · `window` · `thermostat` ·
`fan` · `sensor` · `motion` · `camera` · `speaker` · `tv` · `vacuum` · `area`

### 4.1 Mapping examples

| HA | → role | → capabilities |
|---|---|---|
| `light`, color modes `[brightness]` | `light` | `on_off`, `brightness` |
| `light`, color modes `[color_temp, hs]` | `light` | `on_off`, `brightness`, `color_temp`, `color` |
| `light`, color modes `[onoff]` | `light` | `on_off` |
| `cover`, `device_class: garage` | `garage` | `open`, `on_off` |
| `cover` with `SET_POSITION` | `blind` | `position` (+ `tilt` if supported) |
| `climate` with `TARGET_TEMPERATURE` | `thermostat` | `set_temperature`, `hvac_mode` |
| `lock` | `lock` | `lock` (+ `open` if the `OPEN` feature is set) |
| `binary_sensor`, `device_class: motion` | `motion` | `motion` |
| `sensor`, `device_class: temperature` | `sensor` | `temperature` |

Pure function of `(domain, device_class, supported_features,
supported_color_modes)`. Table-driven, not branching code — new rows are the
expected form of change.

---

## 5. Binding resolution — at read time

```
  plan.yaml  (geometry + keys, versioned, changes rarely)
      +
  resolver   (key → entities + live capabilities, changes constantly)
      =
  what the panel renders
```

Tiers, first match wins:

1. `key` matches an HA device ID → bound to that device's entities.
2. `key` matches an entry in the binding table → bound to its entity list.
3. `key` matches an **alias** for a retired ID → bound, deprecation warning.
4. `key` matches an `entity_id` present in **states but absent from the
   registry** → bound, with a warning. YAML-configured entities without a
   `unique_id` never get a registry entry (A.7), so a registry-only resolver
   silently loses them.
5. No match → unbound. Render greyed, report it. **Never drop the marker** — a
   missing one looks like a modelling mistake, a grey one looks like what it is.

---

## 6. Authoring libraries

**Class library (baseline, ships with the product).** A dozen generic typed
markers — Ceiling Light, Wall Switch, Motion Sensor, Camera, Thermostat, Smart
Lock, Blind, Speaker — each carrying default `role` and `capabilities` as
user-defined properties. The designer places one and types a `placementKey`.
Works offline, before any HA connection, for any customer.

**Everything must function with only this library.**

**Registry library (optimization).** For stable single-tenant homes, generate a
`.sh3f` with one entry per HA device, `id` set to the device ID. SH3D stamps
`catalogId` automatically on drag, so the key arrives with zero typing.
Degrades gracefully to the class library; never a dependency.

Models exist only so a designer can see what they are placing. One small OBJ
per class, shared. Do not model real hardware.

---

## 7. Coordinate system

| | SH3D | Output |
|---|---|---|
| Units | centimetres | metres |
| X | right | east |
| Y | **increases downward** | north (negated) |
| Z | up | up |
| Angles | degrees, clockwise, screen-space | degrees, counter-clockwise |

1. **Negating Y flips handedness, inverting every rotation.** `angle_out =
   -angle_in` normalized to `[0, 360)`. Looks correct until a device faces
   backwards in one quadrant.
2. **Normalize the origin once, globally.** Union bounding box across *all*
   levels, one translation vector. Per-level normalization makes floors drift
   sideways when switching floors.

Verify the angle unit against a fixture: `Home.xml` writes degrees, the Java
model works in radians.

---

## 8. Multi-level rules

**A single-storey home has zero `<level>` elements.** Synthesize a default or
every simple plan fails — and that is what anyone tests with first.

- **Floor order:** sort by `(elevation, elevationIndex)`. Never by name.
- **Absolute Z** = `level.elevation + piece.elevation`.
- **Floor slab** occupies `[elevation - floorThickness, elevation]`.
- **Wall height fallback:** wall → level → home `wallHeight`.
- **`viewable: false`** is exported with the flag, never dropped.
- **Negative elevations** are legal. Do not clamp basements.
- **Furniture groups nest**, and the `level` IDREF sits on the *group*;
  children inherit it. Reading a child's own `level` puts nested devices on the
  wrong floor, silently.

Room membership: point-in-polygon on the same level, device centre,
smallest-area room on a tie, `room: null` plus warning on no match.

### 8.1 Floor and area alignment

HA floors group areas via `floor_id`; areas group devices and entities. Mapped
through the resolver table of §1.2:

```
  SH3D level  ↔  roomKey table  ↔  HA floor
  SH3D room   ↔  areaKey table  ↔  HA area
```

Three cross-validations geometry alone cannot provide:

1. **HA area with no room in the plan** — a gap in the dollhouse.
2. **Room with no HA area** — a modelling artifact, or an area nobody created.
3. **Placement whose resolved entity has an `area_id` different from the room
   it sits in** — the most valuable of the three. It catches a device dragged
   into the wrong room, otherwise invisible: the plan is internally consistent
   and only disagrees with reality.

All three run resolver-side, since they need live registry data. Report; never
auto-correct. The plan may be right and HA wrong.

---

## 9. Output schema

```yaml
schema: dollhouse/3.0
profile: full
source:
  sha256: 3f8a...
  sh3d_version: 7500
  converted_at: 2026-08-01T12:00:00Z
units: meters
axes: {x: east, y: north, z: up}
bounds: [[0, 0], [12.4, 9.8]]          # global, shared by all levels

levels:
  - id: lvl_ground
    key: ground_floor                   # human-readable, author-controlled
    name: Ground Floor
    elevation: 0.0
    floor_thickness: 0.12
    height: 2.5
    order: 0
    viewable: true

    rooms:
      - id: rm_kitchen
        key: kitchen                    # human-readable, author-controlled
        name: Kitchen
        polygon: [[0,0],[4.2,0],[4.2,3.1],[0,3.1]]   # CCW
        area: 13.02
        role: area
        capabilities: [occupancy]

    walls:
      - id: w1
        footprint: [[0,0],[4.2,0],[4.2,0.1],[0,0.1]]
        centreline: [[0,0.05],[4.2,0.05]]
        thickness: 0.1
        base: 0.0
        height: 2.5
        height_at_end: 2.5
        openings:
          - id: op1
            kind: door
            u: [1.20, 2.10]             # along centreline from footprint[0]
            z: [0.00, 2.05]             # from wall base
            shape: rect                 # future: "path"
            key: front_door
            role: lock
            capabilities: [lock, open]

    placements:
      - id: pl_kitchen_fan
        key: kitchen_ceiling_fan
        name: Kitchen Ceiling Fan
        room: rm_kitchen
        position: [2.10, 1.55, 2.38]
        angle: 0.0
        role: fan
        capabilities: [on_off, fan_speed, brightness]   # hint only
        source: catalog_id              # catalog_id | property | fallback
        meta: {}

    decor: []
```

No entities, no `hub` block, no HA IDs, no live capabilities. Those exist only
in the resolver's output, never in the stored artifact.

---

## 10. Profiles and compatibility

| | `full` | `compact` | `minimal` |
|---|---|---|---|
| Precision | 3 dp (mm) | 2 dp (cm) | 2 dp |
| Arc tessellation | 5° | 15° | 30° |
| `centreline` | yes | yes | no |
| `decor` | yes | no | no |
| Room polygons | full | simplified | bounding box |

`centreline` is retained even though footprints are converter-computed:
`footprint` alone cannot support wall-snapping, wall-mount orientation, a 2D
minimap, or measurement tools. Forty bytes per wall preserves all of it.

**Compatibility contract.** Version is `MAJOR.MINOR`; minor bumps are
**additive only**. Consumers **must ignore unknown keys** — not "should".
Unknown `role`, `capability` or `kind` values **must degrade, never error**.
Removing or retyping a field requires a major bump.

---

## 11. Validation

**Reject (4xx):** missing `Home.xml`; version above ceiling; level missing or
duplicate `id`; self-intersecting room polygon; zero-length wall.

**Accept and report (converter):** duplicate `key` across placements (legal,
usually a copy-paste — name both locations); placement with no containing room;
placement on a non-viewable level; opening not associable to any wall; miter
clamped to bevel; arc tessellated; overlapping room polygons; **any room or
level falling back to a name-derived key**.

**Resolver-side (needs live HA):** key absent from the registry; HA device
never placed; `roomKey` with no mapping-table entry; HA area with no room; room
with no HA area; **entity area disagreeing with the room it is placed in**
(§8.1).

"HA devices never placed" is the designer's to-do list. Surface it prominently.

---

## 12. Converter modules

```
sh3d/archive.py    zipfile, extract Home.xml, sha256, zip-bomb + XXE guards
sh3d/parse.py      ElementTree → dataclasses. No geometry, no units. Pure.
geom/transform.py  cm→m, Y-flip, angle negation, global origin translation
geom/walls.py      centreline offset, arc tessellation, miter joins + clamp
geom/openings.py   door↔wall association, projection to wall-local (u, z)
geom/rooms.py      polygon repair, CCW normalization, point-in-polygon
emit/yaml_v3.py    deterministic serializer
validate/rules.py  §11, converter-side only
service/api.py     upload endpoint, versioned storage, report
```

The parse layer is unchanged across every spec revision because it is faithful
to `Home.xml` and knows nothing about output shape. Hold that line.

**The three hard parts**, ranked: doors carry no wall IDREF and must be
associated geometrically; miter joins send near-parallel intersections toward
infinity and need a clamp with bevel fallback; `arcExtent` needs tessellation
and `heightAtEnd` gives sloping tops.

**Determinism:** two conversions of an unchanged file must be byte-identical.
Sort by stable keys, round to fixed precision, normalize `-0.0`, fixed key
order, no anchors, never emit SH3D internal object IDs.

---

## 13. Resolver: Home Assistant integration

Separate component. Stateless with respect to geometry; stateful with respect
to HA.

### 13.1 Bootstrap

```
1. auth handshake (long-lived token for a service; OAuth2 for user-facing)
2. config/floor_registry/list      → floors
3. config/area_registry/list       → areas
4. config/device_registry/list     → device → area, manufacturer, model
5. config/entity_registry/list     → entity → device, area, disabled state
6. subscribe_entities              → live state AND capabilities
```

Steps 2–5 are the **registry snapshot**: cacheable, changes rarely. Step 6 is
the **live stream** and is the only source of `supported_features`.

`config/entity_registry/list_for_display` is a lighter alternative to step 5,
but it excludes disabled entities and abbreviates property keys — a behaviour
difference, not just a size one.

**The registry is not a complete inventory.** YAML-configured entities without
a `unique_id` never enter it (A.7). Step 6 is therefore the authoritative
entity list; steps 4–5 add metadata to the subset that has it. Build the
resolver's index from states and enrich from the registry, not the reverse.

`config/entity_registry/get` (singular) returns an extended entry including
capabilities, which `list` omits (A.8). Not useful for bootstrap — it does not
scale — but a good targeted fallback for a single entity that was unavailable
at subscribe time.

**Pin an HA version in CI.** The registry commands used here are stable in
practice but largely undocumented (A.9), so drift will surface as a runtime
failure rather than a deprecation notice.

### 13.2 Invalidation

Subscribe to registry-updated events and re-fetch the affected registry. Do
not poll.

**Do not read new values out of the event payload.** The registry-updated
events report the *previous* value in their `changes` field rather than the new
one, which has been reported repeatedly and remained the behaviour as of
2025.9 (A.5). Treat the event purely as a signal to re-fetch.

A registry snapshot carries a revision so the panel can tell whether its cached
bindings are current.

### 13.3 Three distinct failure states

| State | Meaning | Panel |
|---|---|---|
| **Unbound** | key not in registry or binding table | grey marker, "not linked" |
| **Unavailable** | in registry, entity reporting unavailable | dimmed, "offline" |
| **Stale** | no HA connection at all | last-known state + staleness age |

Do not collapse these — different visuals, different user action. "Not linked"
is a configuration task, "offline" is a hardware problem, "stale" is your own
connectivity.

### 13.4 Offline

Last registry snapshot plus the plan's hints renders a complete,
non-interactive dollhouse. That is the entire justification for keeping hints
in the artifact (§3.2). Test it as a first-class path, not when someone's Wi-Fi
drops.

### 13.5 Where it lives

Panel-side is simpler. A service between panel and HA gives shared caching, one
place to audit binding failures, and an offline snapshot surviving app
reinstalls. Does not affect the schema — but it decides how offline behaves, so
decide deliberately.

---

## 14. Changes from v3

| Area | Change |
|---|---|
| §1.2 | **Corrected.** `roomKey`/`levelKey` are human-readable, not HA IDs. HA join moves to a resolver mapping table. Driven by A.3. |
| §3.3 | Explicit prohibition on keying by `entity_id`, with A.4 as evidence |
| §8.1 | Alignment routed through the mapping table |
| §9 | HA IDs explicitly excluded from the artifact |
| §11 | New resolver check: `roomKey` with no mapping entry |
| §13.2 | **New constraint.** Registry-updated events carry stale values; re-fetch, never trust the payload (A.5) |
| Appendix A | New — verification record |

---

## Appendix A — Verification record

Checked 1 August 2026 against Home Assistant official documentation and
community reports.

**A.1 — `area_id` is rename-stable. CONFIRMED.**
Official documentation states the area ID is stable, does not change when the
area is renamed, and is safe to hard-code in templates.
`https://www.home-assistant.io/template-functions/area_id/`

**A.2 — `floor_id` is rename-stable. CONFIRMED.**
Official documentation states every floor has an internal ID that stays the
same even when the floor is renamed. The companion `floor_name` page notes
explicitly that the *name* shifts over time while the ID does not.
`https://www.home-assistant.io/template-functions/floor_id/`
`https://www.home-assistant.io/template-functions/floor_name/`

**A.3 — `area_id` format is NOT uniform. CONFIRMED — and this is what changed
the recommendation.**
Community reports show a single instance returning a mix of slugified names and
32-character hex strings from the same template call, depending on how each
area was created. Rename-stable but not human-readable, and not safely typed by
hand.
`https://community.home-assistant.io/t/why-some-areas-have-a-slugified-area-id-others-a-system-generated-number/334997`

**A.4 — `entity_id` generation is actively changing.**
A 2026 core change introduced area-derived prefixes into generated entity IDs,
prompting substantial pushback and a maintainer response describing it as part
of a multi-year naming overhaul. Reinforces that entity IDs are call targets,
never identity.
`https://github.com/home-assistant/core/issues/173125`

**A.5 — Registry-updated events report previous values.**
Reported against 2025.9.3, referencing two earlier reports of the same
behaviour: subscribers to `device_registry_updated` receive the area value the
device had *before* the change, not after. Constrains §13.2 to treat events as
signals only.
`https://github.com/home-assistant/core/issues/152288`

**A.6 — Also relevant.** Manually editing `area_id` in
`.storage/core.area_registry` orphans every device referencing it, confirming
`area_id` behaves as a foreign key throughout the system and is not safely
rewritten.
`https://community.home-assistant.io/t/change-area-id/429999`

**A.7 — The entity registry is not a complete inventory.**
Reported and reproduced: MQTT entities configured in YAML do not appear in
`config/entity_registry/list` despite functioning normally. Entities without a
`unique_id` never receive a registry entry. A registry-only resolver loses them
silently. Drove the new tier 4 in §5.
`https://community.home-assistant.io/t/websocket-api-call-to-config-entity-registry-list-does-not-include-mqtt-sensors/720404`

**A.8 — `list` and `get` return different shapes.**
The base registry entry carries identity; an extended form returned by the
singular `get` adds frontend data including capabilities. Bulk `list` omits it.
`https://deepwiki.com/home-assistant/frontend/4.1-entity-management`

**A.9 — The WebSocket command set is largely undocumented.**
The official WebSocket API page does not enumerate available commands;
`config/area_registry/list` and its siblings work but are not documented.
Community thread confirms this is the known state, not a search failure. Every
registry call in §13.1 is undocumented-but-stable, so pin a version in CI.
`https://community.home-assistant.io/t/where-are-the-websocket-messages-documented/823923`

**A.10 — The Sweet Home 3D forum is not indexed.**
Thread URLs resolve to stubs with no retrievable content. Every SH3D-side
unknown must be settled by experiment against a real installation, not by
research. This is why Appendix B exists in the shape it does.

---

## Appendix B — Verification backlog

Every remaining unknown, with the method that settles it and the fallback if
the answer is unfavourable. **The contingency column is the important one:** an
unknown with a cheap fallback is a scheduling detail, an unknown without one is
a design risk.

### B.1 Blocking — do not start geometry or binding code

Items V1–V4 are answered by a **single experiment**: build a three-entry
`.sh3f` in Furniture Library Editor 2.0 with user-defined properties, import
it, place all three, save, then unzip and read `Home.xml`. One sitting.

| ID | Question | If unfavourable |
|---|---|---|
| **V1** | Do `<property>` elements survive a save/load round-trip when `additionalFurnitureProperties` is **not** set? | **Highest risk in the design.** If SH3D drops unknown properties on save, any designer without the launcher script silently destroys every binding. Fallback: encode the key in the piece `name` with a delimiter, accepting the fragility §1 argues against. |
| **V2** | Do catalog-level user properties propagate onto the placed piece, or stay in the catalog? | If they stay, the class library cannot pre-seed `role`/`capabilities` and every placement needs manual typing. Fallback: derive `role` from `catalogId` prefix, and keep a class table in the converter rather than the library. |
| **V3** | Is `catalogId` written for pieces from a **user-imported** `.sh3f`, or only the bundled catalog? | Kills the zero-typing path in §6.2 outright. Fallback: `placementKey` typed by hand for every device — the design still works, it just costs the designer a field per placement. |
| **V4** | Does copy-paste preserve `catalogId`? | Decides whether duplicate keys are the common case (warning must be prominent) or an edge case. No design impact either way. |
| **V5** | Is `angle` in `Home.xml` degrees or radians? | Hedged three times in this spec. Read `HomeXMLHandler.setPieceOfFurnitureAttributes` — the conversion happens at the I/O boundary. Wrong answer means every device orientation is wrong by a factor of 57. |
| **V6** | Is the plan Y axis confirmed to increase **downward**? | Assumed throughout §7. Verify by placing a piece at a known corner and reading its `y`. Wrong answer mirrors the entire house. |
| **V11** | Are furniture coordinates **inside a group** absolute, or relative to the group? | `parse.py` assumes absolute. If relative, every grouped device is misplaced and the fix is a transform composition in `_walk_furniture`. |
| **V23** | Does `subscribe_entities` carry attributes — including `supported_features` — in its initial snapshot, or only in diffs? | §3.1 makes it the sole bulk source of capabilities. If the snapshot omits attributes, add a `get_states` call to the bootstrap. |

### B.2 Important — resolve before the service goes live

| ID | Question | Method | If unfavourable |
|---|---|---|---|
| **V7** | DTD drift between 7.x and the 5.4 DTD this spec was written against | Diff the DTD comment in a current `HomeXMLHandler` | New elements to ignore; `parse.py` already tolerates unknown children |
| **V8** | `additionalFurnitureProperties` declaration syntax | Experiment; forum unreachable (A.10) | Blocks the launcher script only; tier-2 binding still works via library-seeded properties |
| **V9** | `PluginFurnitureCatalog.properties` key format | Round-trip through Furniture Library Editor 2.0 | Blocks the registry library generator; class library unaffected |
| **V10** | Is a group child's own `level` attribute really ignored? | Move a group between floors in SH3D, save, inspect | `nested_group` fixture already encodes the current assumption; flip it if wrong |
| **V13** | `elevationIndex` semantics when levels share an elevation | Build a mezzanine, inspect | Affects floor-selector ordering only |
| **V14** | Can a home **with** levels still contain objects carrying no `level` attribute? | Inspect a plan where a level was added after objects existed | `parse.py` currently leaves `level_id` as `None`; may need assignment to the lowest level |
| **V16** | Can a 7.x `.sh3d` ever lack `Home.xml`? | Check whether the legacy `Home` entry is still the only guaranteed one | `archive.py` rejects on missing `Home.xml`; would need a Java-dump fallback, which is expensive |
| **V19** | Does the sign of `arcExtent` indicate curve direction? | Draw two arc walls curving opposite ways | Arcs tessellate the wrong way — visible, not silent |
| **V20** | Does an absent wall `height` mean "inherit level height"? | Inspect a wall left at default | §8 assumes yes; wrong answer gives flat or over-tall walls |
| **V22** | Does `floor_id` share the format non-uniformity of `area_id` (A.3)? | Inspect a real HA instance with several floors | §1.2 already avoids depending on it; confirmation only |
| **V25** | Does an entity inherit its device's area unless explicitly overridden? | Inspect registry entries for a multi-entity device | §8.1 check 3 depends on it; wrong answer produces false mismatch reports |
| **V17** | Can Shapely's mitred buffer with a limit do most of `geom/walls.py`? | Prototype against `acute_corner` and `arc_wall` fixtures | Pure effort question — determines whether miter joins are a day or a fortnight |

### B.3 Worth knowing, not blocking

| ID | Question |
|---|---|
| **V12** | Does 7.x write `id` on rooms and furniture, and is it stable across edits? Spec already forbids emitting it; confirmation only. |
| **V15** | `cutOutShape` SVG path syntax, for the deferred `shape: path` support |
| **V18** | The miter limit value SH3D itself uses, so footprints match its rendering |
| **V24** | Whether the stale-value behaviour in registry-updated events (A.5) persists in the current HA release |
| **V26** | WebSocket command stability across HA versions — ongoing, monitored via the CI pin |
| **V27** | Payload size and any rate limiting on very large registries |

### B.4 Product decisions, not verifications

| ID | Decision |
|---|---|
| **V28** | Resolver placement — panel-side or a service between panel and HA (§13.5) |
| **V29** | Whether `decor` appears at all in the `full` profile. If not, drop it at parse time and halve output size. |
| **V30** | First pass of the capability vocabulary (§4) against a real device inventory rather than the illustrative list |

### B.5 Working agreement

- Every item resolved gets recorded in Appendix A with its source or method,
  and the corresponding row struck from B.
- Every item resolved **unfavourably** gets a fixture added before the
  workaround is written.
- B.1 must be empty before `geom/` or the binding resolver is started. B.2 must
  be empty before the upload service accepts real plans.
