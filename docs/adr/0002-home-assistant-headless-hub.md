# Home Assistant (Container) as the headless Hub, despite the Java preference

The Hub is Home Assistant, deployed as HA Container in Docker, run headless; the custom Flutter Panel talks to its WebSocket API (the same API HA's own frontend uses) with a 10-year long-lived token. The owner prefers Java, and openHAB/OpenRemote were the Java candidates — but the device-coverage matrix was lopsided: openHAB has no path at all for Ecobee (dev API closed, no HomeKit-controller equivalent), the Litter-Robot 5 Pro, either Petlibro feeder, or Wyze control, and its LG ThinQ binding is broken; OpenRemote has no consumer-device catalog (no Zigbee/Matter/Thread); ioBroker is not competitive on docs/API. Coverage and API quality were explicitly ranked above implementation language; the Java preference is expressed in the Panel and any sidecar services instead. Full matrix and citations: `docs/research/hub-and-device-integrations.md`.

## Consequences

- The Hub is a black-box appliance: versions pinned, updated on our schedule, internals never modified.
- Automations live in the Hub's native engine; the Panel is a pure view/command layer.
- Device buses that speak MQTT (Zigbee2MQTT, ratgdo) remain directly consumable by any client, keeping the device layer partially hub-portable.
- A small Dart JSON-over-WebSocket client for HA must be hand-rolled (the official maintained client is JS).
