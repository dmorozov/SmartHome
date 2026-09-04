# The Popup is a managed feed, and person intent is never health-gated

**Decision (2026-08-28):** the Popup's live view attaches to the Stream
Director as its third managed surface — `FeedRole.popup` — instead of
hand-rolling the session lifecycle beside it. The role is declared by
**traits** (person-origin from birth, viewport- and overlay-immune,
health-blind, laddered), not by a third arm on every role ternary,
because a closed two-value enum is the shape that let the Popup stay
unmanaged for a month while the Director's own docstring described the
carve-out as deliberate. Which stream it plays — the full-size one, like
the zoom's — is deliberately not a trait: stream choice stays policy data
(`DirectorPolicy.popupStream`), because streams are the owner's tuning
and the traits are the lifecycle's shape.

## What the carve-out actually cost

The 2026-08-28 architecture review measured it: `device_popup.dart`
re-implemented the dial dance verbatim — dial, born-phase inspection,
log-once failure latch, close-by-every-route-out — beside a Director whose
header called itself "the ONE copy of the dance." Two test suites pinned
the same concepts through different interfaces with nothing asserting the
two implementations agreed, and every popup dial bypassed Camera Health,
admission accounting aside. The deletion test was decisive: deleting the
Popup's copy collapses into one `attach()` call, which is the definition
of a module that should have existed already.

## Health-blind, by intent and not by omission

A popup dial goes out **whatever the probe says**, and a playing Popup is
never parked or yanked by a probe flip — anything else is the gate
sneaking back in. This was argued both ways and decided by the owner
against the reviewer's recommendation: the zoom gates on `unreachable`,
a failed dial costs the camera two connections (measured 2026-08-25), and
consistency between the two person-origin surfaces was worth something —
but the person is *standing there asking*, the probe may be stale, and
the dial itself is the freshest probe there is. Outcomes report through
`CameraHealthSource.dialOutcome`, and the sink is real (same day, the
first policy step after the re-seat): **positive evidence only**. A
successful dial marks the camera reachable immediately — a parked tile's
recovery rides that flip instead of waiting out the once-a-minute probe —
and the evidence holds against the Hub's unrelated traffic until the
probe next speaks a *new* reading, at which point the probe regains its
authority. No clock, no decay rules: the probe is its own decay, which is
what answered the old no-op's stated blocker. A failed dial never
overrules the probe — a single failure has too many non-camera causes on
this network (a Wyze RTSP daemon mid-death, go2rtc restarting, the
two-connection contention a recovery storm invites), and a bidirectional
sink would let one bad popup dial blank a tile the probe still vouches
for. What a failure MAY do is take back the word a success gave:
withdraw held dial evidence, returning the verdict to the probe's own
reading — never below it. Adversarial verification forced that clause: a
camera that died again before the probe ever saw it up emits `off`→`off`,
which is nothing, so un-withdrawable evidence would pin `reachable`
forever and set the grab loop and the ladder working a dead daemon
indefinitely. Two sibling guards came out of the same review: a session
*born* playing is the keep-alive pool handing back a lingered picture —
no dial went out, nothing new is known, so it resets the ladder and
reports **no** outcome (the pool's 20 s linger outlives the MJPEG
watchdog's 15 s, so that picture can be a dead camera's last frames);
and the probe's own *unavailability* counts as the probe speaking — a
new fold clears evidence like any other reading, downgrading safely to
`unknown`, which gates nothing. Outcomes for unprobed Devices are
dropped where they land, so the doorbell — whose popup reports like any
other — stays unknown, never a parked camera.

## The ladder, landed in two steps

The re-seat shipped the popup role **unladdered** — one dial per
lifetime, exactly the Popup's behaviour before it, so the re-seat's
observable behaviour was provably unchanged (the phase-1 discipline: each
policy flip is its own revertable step). The flip followed the same day:
popup **cameras** now climb the zoom's 5/15/60 ladder, because the zoom
and the Popup are the same gesture at different sizes and a camera that
hiccups mid-watch should come back without the person re-tapping. The
doorbell does not move: the kind wall in `_onDialFailed` outranks the
role's trait, so a Ring stream is still never re-dialled on a timer
(#177014), pinned by tests at both the Director and the wall.

Two consequences worth stating, because neither is obvious from the trait:

**"Live view unavailable" is no longer a camera's word *in the Popup*.**
A laddered camera never rests at `failed`, so in the Popup that sentence
is now reachable only by the doorbell (the kind wall) and by a build that
cannot play video at all. The scope matters: the Cameras view keeps its
own vocabulary — a `failed` tile or zoom reads "Live view failed", and
"Live view unavailable" is still what a camera with no usable go2rtc URL
reads there. One phase table per surface, and this consequence belongs to
the Popup's.
The new word is the ladder's: **"Reconnecting to the camera…"** — and it
is spoken only over a picture that was actually up, because *"re-" claims
a restoration*. A first connect that keeps failing goes on saying
"Connecting to the camera…", which is the rule the Cameras view already
applies to the same phases (owner request, 2026-08-26), and it needs a
`_sawPlaying` latch in the Popup's video box — the third copy of that
latch on the Panel, and the clearest argument yet for the shared
`CameraFace` module the same review proposed. *(Landed 2026-09-02:
`lib/ui/video/camera_face.dart` is that module — one latch, one birth
read, one listener pair for all three surfaces, each keeping its own
phrase table. The tile and the zoom gained the Popup's born-playing rule
with it; until then only the Popup read the born phase, and a tile
re-attached to a lingered picture whose player dropped back to
`connecting` before failing said "Connecting…" through the whole ladder —
a straight death was saved only by the Director counting before it flips
the phase. One more cell moved with the shared predicate: a camera Popup's
ladder re-dial parked at the admission gate (`queued`, count above zero)
now keeps "Reconnecting to the camera…" instead of dropping to
"Connecting…" for the wait — the mid-climb flicker this section's own rule
argues against; latent on today's wall, where nothing else dials under an
open camera Popup.)*

**A health-blind ladder is bounded by the route, not the probe.** The two
decisions compound: a popup feed never parks at `offline`, so on a camera
that is simply dead nothing stops the climb except the Popup's own
clocks — the ding deadline, the ceiling, the idle return. That is a
bound of minutes with somebody standing there, not an unattended knock,
and it is the reason those clocks are load-bearing rather than tidy.
Reverting the ladder is still one word (`laddered: false`).

The flip also moved one guarantee down a layer, and this is the shape of
bug the re-seat exists to prevent. Before it, nothing re-dialled under a
watching Popup, so unmuting once in `initState` was enough; a ladder
re-dial opens a *new* session, and every session is born muted, so the
audible surface would have come back silent when the picture came back.
`setMuted` therefore sets the intent on the **feed**, which re-applies it
to whatever session it is holding — rather than the widget re-asserting
on every phase change, which would mean the caller knowing that re-dials
happen at all. Only a surface that actually asked is touched, so a tile's
dials never go near the flag (six camera audio tracks over each other is
the measured alternative).

## The clocks stayed out of the Director

The ding Popup's extendable deadline and absolute ceiling moved into a
**decorator** — `TimedFeed`, wrapping any `CameraFeed`, exposing
`extend()`/`ceilingReached` — not into `DirectorPolicy`. The deadline
times a *route* (how long the unprompted Popup may hold the wall), not a
stream; the stream-side age bound already exists in the keep-alive pool
(`kLiveVideoMaxHeld`), eight of nine feeds would never arm the knobs, and
the fire is a Navigator pop the Director cannot perform. The constants
stayed in `doorbell_popup_host.dart`, so the pool suite's
`linger < deadline` inequality test did not move. The route mechanics —
blocked-dismiss retries, `isActive` vs `isCurrent` — stayed in the widget,
where the Navigator is.

## What else moved, and what deliberately did not

The five `popup.stream_*` journal lines became `cameras.popup_*` — one
dance, one grep vocabulary — and the Popup's finer skip reasons
(`no_stream_name` / `no_go2rtc_url` / `bad_go2rtc_url`) were adopted
seam-wide, replacing the coarser `go2rtc_unconfigured`. `CameraFeed` grew
exactly one member, a `setMuted` pass-through: unmute and the ADR-0011
duck stay the Popup widget's, because the duck is gesture-phased — mute
on press, unmute on release — and a gesture cannot be a Director policy.
Splitting one flag between a policy and a gesture was rejected as worse
than a slightly wider interface. The ding arbitration, deferral machinery,
registry, idle prompt, stills, Talk, and chrome all stayed caller-side:
the seam line is *the Director owns the stream; the Popup owns the route
and everything a person touches*. The census and any future
`maxConcurrent` cap are shared, with the standing rule that a cap may
queue tiles behind a Popup, never the reverse.

One behavioural delta beyond the approved list surfaced in adversarial
verification and is **accepted**: a mid-life stream failure now closes
the session *at failure time* — the Director's discipline for every role
— where the old Popup held the dead session until dismissal. The closed
line (`cameras.popup_closed reason=failed`) is written then, and the
dismissal writes none. The old hold-until-dispose was an artifact, not a
design: a failed Ring session held open is #177014's own hazard, and the
keep-alive pool retires failed sessions outright, so nothing is lost by
letting go early. Pinned by the go2rtc-refusal test's close-timing
assertions.

**Reopening this:** the health-blind stance is the clause a future review
will most want to "fix" — it is intentional, decided with the two-
connection cost on the table. What would justify revisiting it is
evidence that doomed popup dials materially cost the 2.4 GHz air (the
band the cameras live on), measured, not inferred; the change would be
one trait flip plus a copy decision for the offline face.
