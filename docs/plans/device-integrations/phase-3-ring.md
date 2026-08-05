# Phase 3 — Ring doorbell: events now, streaming plumbing ready

ring-mqtt is already Up (phase 1) and waiting at its auth gate. This phase
authenticates it, binds the doorbell, and lays the go2rtc plumbing that
phase 4's Panel popup will consume. Cloud, permanently (§3.1) —
`connectivity: cloud` and at peace with it.

## 1. Authenticate — DONE 2026-08-05

Browser → `http://<hub-ip>:55123` → Ring account + 2FA code. The refresh
token lands in `hub/ring-mqtt-data/` (gitignored). `docker compose logs
ring-mqtt` then shows device discovery; because MQTT discovery is on, the
doorbell materialises in HA automatically: device "Front Door" (or
similar) with, typically:

- `event.*_ding` (doorbell press events — HA 2026-era ring-mqtt publishes
  event entities; older styles use `binary_sensor.*_ding`. **Prefer
  `event.*_ding` if this version created both** — §2 says why the choice is
  not neutral)
- `binary_sensor.*_motion`
- `camera.*_snapshot` (still image)
- battery/wifi diagnostics

## 2. Bind the doorbell

**AS-BUILT 2026-08-05 — and the preference below did not get to apply.**
ring-mqtt 5.9.3 on this Hub published **no `event.*` entity at all**: 15 mqtt
entities, the `event` domain empty. So the choice this section spends a page
arguing was made by the integration, not by us:

```yaml
  doorbell:
    entity: binary_sensor.front_door_ding
    stream: ring_doorbell
    connectivity: cloud
```

**Superseded 2026-08-05, phase 7 §A: the missing `event.*` entity was
minted** — an HA MQTT-event entity over ring-mqtt's own ding topic
(`hub/ha-config/mqtt.yaml`), and `doorbell` now binds
`event.front_door_ding`, so rule 2 finally applies. The argument below is
kept because it is *why phase 7 exists*.

Read the argument anyway — it is what the **cost** of that shape is, and the
cost was being paid until the supersession above: a press the Panel heard
about for the first time after a gap was lost (rule 3), because `on` restored
from before the gap and `on` from a finger on the button are the same string.

~~**One unexplored way out, deliberately left unwired:**~~ the
`lastDingTime` template-sensor idea is **settled and buried** (2026-08-05):
research confirmed ring-mqtt writes the attribute at push time, but phase 7's
MQTT event entity delivers rule 2 without the template layer or its
startup-refetch format hazard. Ch. 5 §1.3 carries the burial.

The original argument, kept in full:

**Prefer `event.<name>_ding`, and the preference is not cosmetic.** This
stopped being a toss-up when §4's classifier landed
(`panel/lib/domain/doorbell.dart`, 2026-08-04). The rule has to reject an
unchanged value, because `HaHubClient` emits a change for every usable
message with no equality check and a reconnect replays the entire snapshot —
without that rule every reconnect rings the house, and a wrong pop opens a
real Ring session, which #177014 says can then suppress a real ding. Given
that rule, the two entity shapes are not equally safe:

- `event.*_ding` — the **state is the press time**. Two presses are two
  different strings, so the second one is unmistakably new, and the rule can
  additionally ask *how old* it is (60 s window) instead of trusting that any
  change means "now". That window also answers the *first* report the Panel
  ever sees from this entity: the classifier checks the timestamp **before**
  the first-sight rule, so a press that lands before the integration has ever
  reported still rings, judged on its own age. A press time carries its own
  answer; first sight exists only to guess for values that do not.
  It is also the only shape that can be told apart from *itself*: the Panel
  remembers the press instant it has already rung for, so an entity that
  round-trips through `unavailable` and re-reports the **same** time is
  silence (`ding_suppressed reason=already_rung`) rather than a second Ring
  session. Compared by identity, never "at or before" — a press time that goes
  backwards is a clock or a replay, and treating it as answered would let a
  Ring cloud clock stepping back deafen the bell with no symptom anywhere.
  Duplicates are bounded; deafness is not.
- `binary_sensor.*_ding` — the state is `on`/`off`. A second press while the
  entity is still `on` is `on → on`, which the unchanged rule rejects and
  **must** reject. So if ring-mqtt's auto-off is missed, or the entity sticks
  `on` through a hiccup, every subsequent press is invisible. The only
  breadcrumb is `[panel] D ui.ding_suppressed device=doorbell reason=unchanged`
  at debug level. This is the single most likely real-world defect in the
  feature, and choosing the other entity is what avoids it outright. It is also
  the shape that loses a press across a gap: `on` carries no time, so the first
  word seen after a reconnect — or after the entity round-trips through
  `unavailable` — has to be treated as a re-introduction rather than an event
  (`reason=first_sight`), where a press *time* seen at the same moment would be
  judged on its age and ring.

If only the `binary_sensor` shape exists, bind it — the Panel is built to be
honest under both — but write down which one you bound, because the failure
above is silent from the wall and this note is the only place it is explained.

**Verify**: press the physical button → the entity fires in HA
(Developer Tools → States) → the Panel pin re-renders
(`hub.state_changed` at debug level), and the Popup opens by itself (§4).
`[panel] I ui.ding device=doorbell entity_state=…` is the line that says the
rule agreed it was a press; `ui.ding_suppressed`, `ui.ding_stale` and
`ui.ding_unreadable` are the three ways it can disagree, each naming which.
`ding_suppressed` carries a `reason=` naming the rule that actually did the
silencing, in the classifier's own order — `unchanged`, `already_rung`,
`stale`, `first_sight`. They are not interchangeable: `already_rung` says the
Panel already showed you that press, `stale` says the snapshot handed over an
old one, and only `ding_stale` at **warn** means the clocks disagree.

## 3. go2rtc live-view plumbing

ring-mqtt runs an internal RTSP server (bridge network, remapped to host
port 8556 in phase 1). Stream path: ring-mqtt web UI → the camera's info
page shows the RTSP URL and credentials if livestream auth is set. Add to
`hub/go2rtc/go2rtc.yaml` on the laptop:

```yaml
streams:
  ring_doorbell: rtsp://127.0.0.1:8556/<ring-device-id>_live
```

`docker compose restart go2rtc`, then open `http://<hub-ip>:1984` → the
`ring_doorbell` stream → **links → MSE**. First frames take 2–5 s (the
stream spins up on demand — ring-mqtt starts the Ring live session only
when an RTSP client connects, which is exactly the on-demand behavior we
need).

**The #177014 rule** (HA core issue, on the repo calendar): an OPEN Ring
live stream can suppress ding events. Consequences, enforced in phase 4's
Panel work: live view opens on tap, closes with the Popup, is never held
open in the background, and nothing auto-opens the stream on motion.

## 4. Doorbell-ring Popup (Panel behavior, small) — **BUILT 2026-08-04**

Was: the Popup opened only when the *user tapped* the doorbell pin. Now a
ding opens it unprompted, and it closes itself after 30 s
(`kDoorbellPopupDeadline`) — or after 2 minutes no matter how many dings keep
extending that (`kDoorbellPopupCeiling`, item 3 below).

Four things came out differently from the sketch above, each for a reason
worth keeping:

1. **"transitions to *ringing*" was not implementable as written.** There is
   no `ringing`; there is a state string whose shape depends on which entity
   ring-mqtt made (§2). The rule became a pure three-valued classifier —
   `pressed | quiet | unreadable`, `panel/lib/domain/doorbell.dart` — with
   `now` injected. Three values because "I cannot read this string" is a
   different fact from "nobody is at the door", and only one of them deserves
   a warn line and a human.
2. **"a listener on `state_changed`" would have rung the house on every
   reconnect.** `HaHubClient` emits a change for every usable message with no
   equality check, and a reconnect replays the whole snapshot. `HubController`
   therefore keeps **two** memories per doorbell, with **opposite lifetimes**,
   and the asymmetry is the load-bearing part:
   - `_lastSeen` — what the doorbell *currently says*, a **belief, never a
     souvenir**. Seeded at construction from the Hub's own snapshot (the Panel
     is built after its Hub, so otherwise the first change after every dev boot
     reads as a first sight and is swallowed), **cleared** whenever the link
     leaves `up`, and **forgotten per Device the moment that Device's state
     goes away**. `HaHubClient` drops the entry entirely when an entity reports
     `unavailable`, and a belief that outlives the value it describes turns
     `off` → unavailable → `on` into an edge: the house rings with nobody at
     the door, over a Ring cloud hiccup or an integration reload that never
     touches the Panel's own socket. The argument that used to sit here — that
     *keeping* the memory is what stops a recovery ringing — is backwards.
     Stickiness only helps when the value happens to come back unchanged.
   - `_rungFor` — the press **instant already rung for**, `event.*_ding` shape
     only. **Never cleared**, by a link drop or an entity drop or anything
     else. It is not a belief about what the Device says; it is a record of
     what the Panel has already *done*, and re-reporting a press does not
     un-ring it.

   Forgetting the belief alone was not enough, and this was found by probing
   rather than by reading: with `_lastSeen` dropped on an `unavailable`, an
   entity round-tripping and re-reporting the same press time rang **twice**
   inside the 60 s window, and #177014 says the second Ring session can
   suppress the next real ding. Keeping `_rungFor` stale is safe in the one
   direction that matters — it can only turn a `pressed` into a `quiet`, never
   the reverse — which is precisely why the belief beside it may not be kept:
   a stale `_lastSeen` invented rings.

   **The residual cost, which is not fixable and is stated rather than
   hidden.** A press that is the first thing the Panel hears about a doorbell,
   after a reconnect whose snapshot reported the entity `unavailable`, is
   **lost** for the *word* shape; only the next press rings. `_rungFor` bought
   the timestamp shape out of this. The word shape cannot be bought out: `on`
   restored from before the gap and `on` from a finger on the button one second
   ago are the same string and differ in nothing that exists anywhere on the
   wire. Silence is the honest answer to a question with no evidence in it;
   the alternative rings on every HA restart, which #177014 then turns into a
   doorbell that misses the real press. Another reason to bind
   `event.*_ding` (§2).
3. **"auto-closes after N seconds of no interaction" became a flat 30 s**,
   restarted by a *second ding* rather than by touching the screen. A wall
   panel has no hover and no keyboard, so "interaction" would have meant "a
   tap", and a tap on this Popup is already the Close button. A second ding
   extends rather than re-pushes, because phase-3 §3 measures Ring spin-up at
   2–5 s and a re-push would black the wall out at the exact moment somebody
   is at the door. Extending is capped at `kDoorbellPopupCeiling`, **2 minutes**
   from when the Popup opened: the deadline measures time since the *last
   ding*, and #177014 is about time since the stream was *opened*, so with no
   ceiling a doorbell dinging more often than every 30 s re-arms it forever and
   holds one go2rtc session open — the precise state the deadline exists to
   prevent. The ceiling logs `I popup.deadline_ceiling device=… open_s=120`,
   and reaching it loses nothing: the next ding opens a fresh Popup with a
   fresh session.
4. **"is a Popup up" was the wrong question; "is *this Device's* Popup up" is
   the right one.** Two doorbells are two streams, and a Popup showing A's
   camera is no reason to swallow B's ding. Asked per Device, a ding can also
   find a Popup a *person* opened on that same doorbell — held as it is, with
   no deadline smuggled into it (D14) and no second session on a stream
   somebody is already watching — or one already on its way out, which is
   deferred until its `dispose` has closed the stream and then re-offered.
   `popup.doorbell_held` and `popup.doorbell_deferred` are those two lines, and
   `popup.dismiss_blocked` is a third: a Popup whose deadline fires while
   another route sits on top of it re-arms at 1 s rather than silently losing
   its deadline and holding the stream.

`HubController` cannot push routes and must not learn how — it imports
`flutter/foundation.dart` only, and `bootPanel` builds it before any widget
exists. So detection lives there and pushing lives in
`panel/lib/ui/doorbell_popup_host.dart`, one widget inside `MaterialApp`.

Tested as planned and then some: `test/doorbell_test.dart` (the classifier,
pure — including that a fresh press time rings on first sight while a first
*word* does not), `test/hub_controller_test.dart` (a scripted press rings once;
a reconnect re-stating the same ding rings nothing; a drop to `unavailable` and
back has not rung, **whatever it says on the way back**; the first change after
boot rings, because the controller adopts what the Hub was already holding),
`test/doorbell_popup_test.dart` (it opens and closes itself; a second ding
keeps the video up; a doorbell that never stops ringing still gives the stream
up at the ceiling; a ding on a doorbell a person already has open leaves that
Popup alone rather than opening a second session on the same stream, and
smuggles no countdown into it; a ding during the exit animation waits for the
old session to close), `test/device_popup_test.dart` (the deadline dies with the
widget; a route stacked on top does not leave the Popup with no deadline).
**Actual video inside the Popup is now real on both targets** (phase-4 §B):
MJPEG over HTTP on the appliance, MSE over a WebSocket on web, each driven
against a live go2rtc. What it has never played is a Ring camera, because
there is not one (**B2**) — and when there is, note the budget: the doorbell
Popup's 30 s deadline has to absorb Ring's 2–5 s cloud spin-up *plus*, on the
appliance, go2rtc's 2.1 s JPEG transcode start. It does, comfortably, but that
is the sum to keep an eye on if the deadline is ever shortened.

**What this does not prove**: any of it against a real Ring entity. See §2.

## Done when

Status re-read 2026-08-04, after §4's Panel work landed. Everything still
open is behind **one** owner action — B2, the Ring login. Nothing here is
waiting on an agent.

- Physical button press → Panel doorbell pin reacts (entity round-trip
  verified) and the Popup opens unprompted (FakeHub-tested behavior, then
  observed live).
  - ✅ **Done 2026-08-04 — the tested half.** A scripted press opens the
    Popup unprompted and it dismisses itself; a reconnect that re-states the
    same ding opens nothing. `test/doorbell_test.dart`,
    `test/hub_controller_test.dart`, `test/doorbell_popup_test.dart`.
  - ⬜ **Open — the observed-live half.** Needs a real Ring entity, i.e.
    **B2**. `bindings.yaml` still points `doorbell` at a dev-Hub stand-in, so
    no physical button has ever reached this code. Until then the classifier's
    verdicts are correct *by construction under both documented shapes*, which
    is not the same as correct.
- ⬜ **Open.** `ring_doorbell` plays in the go2rtc web UI via MSE, on demand,
  and a ding is still delivered while NO stream is open (the #177014 rule
  holds because nothing holds a stream). Needs **B2** for the stream to exist
  at all. The Panel half of the rule *is* enforceable and enforced — the
  session opens with the Popup and closes in `dispose()`, and the auto-opened
  Popup closes itself after 30 s, or after 2 minutes however hard it is
  extended — but "a ding still arrives while no stream is open" can only be
  observed against real Ring hardware.
- ⬜ **Open.** Ring refresh token exists only under `hub/ring-mqtt-data/`;
  `git status` shows nothing new tracked. No token exists yet (**B2**); the
  gitignore that will contain it is already in place and was verified in
  phase 1.
