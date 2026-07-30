# Smart Home

A single always-on home appliance: a custom touch "dollhouse" panel for the house, backed by a headless smart-device hub. One box, one house, one family.

## Language

**Appliance**:
The always-on computer hosting the Hub and driving the Panel — the AMD laptop during development, the Ryzen AI mini PC in production.
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

**Floor**:
One level of the house in the Dollhouse (e.g. basement, first floor). Floors stack; tapping one expands it.
_Avoid_: level, story

**Room**:
A named area on a Floor. Rooms display aggregate state (lit, occupied) and hold pinned Devices. Tapping a Room acts on it (e.g. toggles its lights).
_Avoid_: area, zone

**Device**:
A controllable or observable thing in the house (light, camera, thermostat, feeder…), pinned to a Room in the Dollhouse.
_Avoid_: entity (that is the Hub's internal term), gadget

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
A transient full-or-partial-screen overlay on the Panel, e.g. live doorbell video on ring. Phase-1 video is Popup-only (no recording).
