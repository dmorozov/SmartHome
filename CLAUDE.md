# SmartHome

## Git discipline — review before anything lands

**You MUST leave every change unstaged. Never `git add`, never `git commit` without confirmation.
Staging, committing and pushing are the owner's actions or only when the owner directly asked for that.

## Panel UI — neumorphic, always

**Anything drawn on the Panel is neumorphic unless there is a stated reason it cannot be.** The wall is one continuous soft light surface; a control that does not belong to it reads as a bug, not as emphasis.

In practice that means: build from `PanelTheme` (`panel/lib/ui/theme.dart`) — `surface`, `surfaceRaised`, `ink`, `inkFaint`, and `raised()` for the dual light/shadow pair — and express state through **form** (raised, inset, a ring) before reaching for colour. Colour is reserved: `accent` for ready, the fault red for live-or-failed, `glow` for a lit Room. Nothing else gets a hue.

**Reuse the shared widget before drawing a new one.** `PanelCloseButton` (`ui/close_button.dart`) and `EdgeTab` (`ui/edge_tab.dart`) exist because the same shape drawn twice drifts on the first change to either. A second hand-rolled `Container` with a `BoxDecoration` is how the Cameras view ended up with a flat Material `IconButton` while every Popup wore a raised puck.

Reach for a stock Material widget only when nothing on screen shows its chrome, and say so where you do it. `Dialog`, `Navigator` and the gesture recognisers are fine; `IconButton`, `ElevatedButton`, `Card` and friends are not — they bring Material's ink, elevation and radius, none of which match the wall.

## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues (`dmorozov/SmartHome`) via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
