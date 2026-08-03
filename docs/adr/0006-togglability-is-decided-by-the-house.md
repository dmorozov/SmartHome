# Togglability is decided by the House, never by live state

Whether tapping a Device flips it is answered from the House Plan — from the Device's kind, via its state family in `panel/lib/domain/device_vocabulary.dart` — and never from what the Hub is currently reporting. A light whose state is unknown still toggles; a thermostat never does, no matter what the Hub says about it.

The hazard is concrete and one-sided. Home Assistant's `homeassistant.toggle` spans domains, which is exactly why the Panel uses it: one call works for a light, an outlet, a TV, a garage door, and the Panel needs no per-domain knowledge. The same property means a mistaken call reaches a `climate` entity and flips the real HVAC. Nothing else in the stack prevents that — the Hub will do as it is told — so the refusal has to be Panel-side, and it has to be a fact about the *kind of thing* rather than a fact about its current reading.

Deriving it from live state was rejected for two reasons. It flickers: a Device that is unavailable, or that the Hub has not reported yet, would become untappable and then tappable again, so the wall would teach the family that taps sometimes do nothing. And it fails open in the wrong direction — the moment a `climate` entity happens to report `on`, a state-shape rule would classify it as toggleable. Availability is a Hub concern; togglability is a House concern; conflating them puts a safety rule at the mercy of a network.

Deriving it from the state family rather than listing kinds is what keeps the rule single. A kind declares what shape of state it reports, and togglability follows: the on/off families toggle, the reading families do not. One decision per kind rather than two that can disagree.

Enforcement sits at the `HubClient` seam, so both adapters — the real one and the fake — refuse identically, and a refusal is observable as one `hub.toggle_refused` line rather than a silent no-op. The views ask the same declaration, so what a tap does and what the seam permits cannot drift apart.

A future capability-driven refinement — the Hub telling us what a Device actually supports — may only ever **narrow** this, and only from a resolved snapshot held for the session. It may never widen it, and it may never consult live state. The trigger for revisiting is real hardware whose capabilities are known to the Hub and not derivable from its kind; the design constraint is that the answer must stay availability-independent.

Rejected alongside: a per-state-shape rule re-derived in each view (three copies, already observed drifting), and letting the Hub's own service decide by trying the call and handling the failure (the failure being a changed thermostat).
