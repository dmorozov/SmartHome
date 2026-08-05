# Smart Home

A single always-on home appliance: a custom touch "dollhouse" panel for the house, backed by a headless smart-device hub. One box, one house, one family.

## Language

**Appliance**:
The always-on computer hosting the Hub and driving the Panel — the Intel dev laptop during development, the Ryzen AI mini PC in production.
_Avoid_: server, box, host

**Panel**:
The wall-mounted touchscreen running the custom dollhouse UI. There is one Panel now; more may exist later.
_Avoid_: kiosk, dashboard, screen

**Hub**:
The headless smart-home broker (Home Assistant) that owns device state, integrations, and automations. The Panel is its client, never its replacement.
_Avoid_: server, backend, HA (in domain discussion)

**Dollhouse**:
The Panel's main view — the house as stacked 2.5D isometric Floors with tappable Rooms.
_Avoid_: floor plan, map, 3D view

**House Plan**:
The Panel-side description of the house's geometry — Floors with their Rooms and Walls, authored by the family. The Dollhouse renders it; the Hub never sees it.
_Avoid_: blueprint (that is the paper source it may be drawn from), map, layout

**Floor**:
One level of the house in the Dollhouse (e.g. basement, first floor). Floors stack; tapping one expands it. A Floor need not span the whole house footprint (e.g. an upper floor over half the house).
_Avoid_: level, story

**Room**:
A named area on a Floor. Rooms tile their Floor completely — every point belongs to exactly one Room (halls, stairs and the garage are Rooms too; there is no "outside the perimeter"). Rooms display aggregate state (lit, occupied) and hold pinned Devices. Tapping a Room acts on it (e.g. toggles its lights).
_Avoid_: area, zone

**Wall**:
A boundary segment drawn on the House Plan. Only drawn Walls exist: where none is drawn, the boundary is an open passage. Doorways within a Wall are not modeled.
_Avoid_: opening (an opening is just the absence of a Wall), partition

**Device**:
A controllable or observable thing in the house (light, camera, thermostat, feeder…), pinned to a Room in the Dollhouse.
_Avoid_: entity (that is the Hub's internal term), gadget

**Placement**:
A Device marker drawn on the House Plan — where a Device is, as drawn, with its Key and kind. The converter reads Placements out of the drawing and computes each one's Room and position; nobody types meters (ADR-0005).
_Avoid_: marker (that is the Sweet Home 3D furniture piece a Placement is read from), pin (that is how the Dollhouse draws it)

**Key**:
The author-controlled identity of a Device, typed once in Sweet Home 3D and referenced by everything else. Free-form — any spelling or separator — but unique across the house.
_Avoid_: id (ambiguous with the Hub's entity id), name (the Key is not what the Panel displays)

**Local Device**:
A Device that works with no vendor cloud — LAN or mesh protocol only. All NEW purchases must be Local Devices.

**Cloud Device**:
A grandfathered Device that requires its vendor's cloud (Ring, LG, Whisker, Petlibro, oven). Accepted as second-class: may lag or break.

**Retrofit**:
Hardware added to a dumb or cloud-locked device to make it a Local Device (e.g. ratgdo board on the garage opener, ESPHome reflash of the Emporia Vue 3).

**Automation**:
A rule that reacts to Device state (schedules, triggers, scenes). Automations live in the Hub only; the Panel merely displays and triggers.
_Avoid_: rule, scene (unless meaning the Hub's scene concept specifically)

**Popup**:
A transient full-or-partial-screen overlay on the Panel, e.g. live doorbell video on ring. Video began Popup-only; the Cameras view (phase 7, below) is the second video surface. Still no recording.

**Cameras**:
The Panel's full-screen grid of camera tiles, slid out from a right-edge tab on the Dollhouse. Tiles start and stop their own live streams (the doorbell's is off by default — an open Ring session suppresses dings); closing the view stops them all.
_Avoid_: dashboard, camera wall, NVR view
