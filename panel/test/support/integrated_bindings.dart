/// The Keys whose `entity:` has moved off a dev-Hub stand-in and onto real
/// hardware.
///
/// Adding a Key here is the deliberate act of saying "this one is real now".
/// Two suites read it, and they want opposite things from it, which is why it
/// lives here rather than in either of them:
///
///  - `bindings_drift_test.dart` uses it to EXCUSE a binding that no longer
///    resolves against the dev Hub. Without the ledger, moving a Device to
///    real hardware would fail a hermetic test on every machine.
///  - `ha_hub_live_test.dart` uses it to STOP PREDICTING a Device's value. A
///    stand-in answers with the seed the Device vocabulary generated it from;
///    real hardware answers with whatever the house is actually doing, and no
///    assertion about the seed can survive that.
///
/// It was private to the drift suite until 2026-08-07, and the live suite
/// paid for it: `thermostat` moved to the ecobee on 2026-08-04 and the live
/// test went on casting `hub.states['thermostat']` to `ThermostatState`, so
/// against the dev Hub — where `climate.main_floor` does not exist — it threw
/// `type 'Null' is not a subtype of type 'ThermostatState'` before reaching
/// the toggle round-trip that is the point of the test. Phase 2's Done-when
/// had predicted exactly that ("the 21.4 °C seed assertion relaxed before
/// `thermostat` points at a real Ecobee") and nobody was told, because the
/// live suite is opt-in and `flutter test` stayed green for two days.
///
/// So the ledger is one list, in one place, and the next Device to move
/// updates both suites by being written down once.
const integratedBindings = <String>{
  // Phase 2, 2026-08-04 — real hardware on the laptop Hub.
  'outlet-outdoor-a', // Kasa EP40 outdoor socket A -> switch.outdoor_outlet_a
  'outlet-outdoor-b', // Kasa EP40 outdoor socket B -> switch.outdoor_outlet_b
  'thermostat', // ecobee "Main Floor" -> climate.main_floor (HomeKit, local)
  // 2026-08-05 — two Kasa HS103s repurposed from a fridge and an aquarium to
  // house lights, which is what made them bindable at all (Ch. 4 §4.1.1,
  // ADR-0006). The Key names are placeholder-house fictions: the entry light
  // is NOT in the living room and the stairs light is NOT on the landing.
  // `light-hall` would have been right for the entry and is deliberately not
  // used — it is the live suite's own togglable fixture, and keeping it a
  // stand-in is what lets that suite flip a switch without touching the
  // house; see bindings.yaml.
  'light-living', // -> switch.entry_light  (was switch.old_fridge)
  'light-landing', // -> switch.stairs_light (was switch.aquarium)
  // 2026-08-05 — ring-mqtt authenticated; the doorbell is real hardware now.
  // Later the same day (phase 7 §A) the binding moved to the minted event
  // entity; the stream and snapshot ride along.
  'doorbell', // -> event.front_door_ding
  //            (+ stream: ring_doorbell, snapshot: camera.front_door_snapshot)
};
