# The Panel recovers on its own, and says plainly when it cannot

The Panel is a wall display with no keyboard and nobody watching a console (ADR-0001). Every failure it can survive, it must survive unattended; every failure it cannot, it must state in words a person walking past can act on. Those are two different things, so `HubClient` reports three states rather than a reachable/unreachable boolean: **up**, **retrying**, and **gaveUp**.

**Retrying is forever.** A Hub restart, a network blip, the appliance rebooting, the router coming back after a power cut — the Panel reconnects with exponential backoff from one second to a thirty-second ceiling and then knocks at that interval indefinitely. There is no attempt limit, because an attempt limit is a promise to stop working while nobody is looking. The backoff resets on a successful handshake, so one bad afternoon does not leave the Panel half a minute behind every future blip. Readings survive the outage — the house does not blank itself because a socket blinked — and the badge says they are stale.

**Giving up is only ever a rejected token.** `auth_invalid` is the one failure waiting cannot fix: the credential is wrong and a human must mint a new one. Retrying it forever would be a busy loop nobody can see. So the socket closes, retries stop, and the badge reads **NEEDS NEW TOKEN** — naming the action, not the diagnosis, because whoever is standing there needs to know what to do and nothing else.

The distinction is the point. Collapsed into one "offline" state, the two failures look identical on the wall while requiring opposite responses: wait, or go make a token. The colour stays binary so the across-the-room read is unambiguous — green live, red stale — and the text carries which kind of stale.

An earlier design threw on a rejected token. That exception was raised inside the socket's stream listener, where no caller could catch it: it could not reach the UI, could not be handled, and left the Panel retrying against a credential that would never work. A state the wall renders replaced it.

Rejected: an on-screen error dialog (there is no keyboard to dismiss it, and it would hide the house); a retry limit with a manual "reconnect" button (the appliance must come back from a power cut with nobody home); and per-Device availability states layered on top — a Device the Hub does not know about is simply unbound, and renders with unknown state, which is a House-side fact and not a link-health one.

This is testable without sleeping, and must stay so: the recovery promise is pinned with a fake clock and an injectable socket factory, so the whole backoff sequence, the reset, and the give-up path run in milliseconds. A recovery guarantee verified by waiting is a guarantee nobody runs.
