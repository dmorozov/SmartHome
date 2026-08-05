# Phase 6 — Full-fleet bindings sweep and closure

The audit pass: everything available is bound, everything bound is honest,
and the docs say what is now true.

## 1. The sweep

Run the Panel against the laptop Hub with `LOG=info` in the environment
(`--dart-define=LOG=info` on web) and work the diagnostics until clean:

- `hub.snapshot entities=<n> bound=<m> missing=0` — **missing=0 is the
  phase's headline number** for every Device whose hardware exists.
  Devices whose hardware does NOT exist keep no `entity:` line and are
  excluded by construction (they log nothing).
- No lingering `hub.state_unusable` at rest.
- Every binding's `connectivity:` matches reality per this plan's phases —
  the Popup shows it, so a lie is user-visible. Expected split, **revised
  2026-08-04** after phase 2 was measured:
  - `local`: the EP40's **two** outlet children, Ecobee (HomeKit), any
    RTSP-flashed Wyze. ~~Kasa ×3, Tesla WC~~ — see below.
  - `cloud`: Ring, wyze-bridge cams, LG ×2, Litter-Robot, Petlibro ×2,
    Emporia (until reflash day)
  - unbound (hardware absent): `garage-door` (awaits ratgdo),
    `ev-charger` (the Tesla Wall Connector serves no API — phase 2 §2),
    `oven` (D3 — unless the October decision funds it), `tv-*` (out of
    scope), plus any `light-*`/`outlet-*` Key with no physical device yet.
  - **in the Hub but bound to nothing, on purpose**: `switch.old_fridge`
    and `switch.aquarium` (ADR-0006 single-tap hazard), the EP40 parent
    switch (it drives both children), and all of Rachio (no irrigation
    `DeviceKind` exists). None of these show up in `missing` — §1a.

## 1a. `missing=0` is only half a check — the inverse pass

**Structural gap, found 2026-08-04. The plan never had this check.** Read
`panel/lib/data/ha_hub.dart`: `missing` is
`_byEntity.keys.where((e) => !bound.contains(e))`, and `_byEntity` is built
**from `bindings.yaml`**. So the number only ever answers *"is every entity
I was told about present on the Hub?"* — one direction, and the narrow one.

The consequence: **a real device that has no Key at all is invisible to this
metric.** It puts nothing into `_byEntity`, so it can never be counted
missing. `missing=0` is therefore reachable while devices sit in the Hub
that the Dollhouse does not show and nobody can reach from the wall — which
is the exact failure this phase exists to prevent, and it passes silently.

Not hypothetical. Coming out of phase 2 there are **four live switchable
Kasa sockets against three `outlet` Keys**, and two of those sockets (the
fridge and the aquarium) are deliberately left unbound for the ADR-0006
single-tap reason. All of Rachio is unbound too, for want of an irrigation
`DeviceKind`. `missing` reports zero of them.

So the sweep needs a **second, inverse check**: enumerate the Hub's entities
and list the ones **no binding references**, then classify each. Run it from
the **repo root** (the paths are relative; `hub/token` is 0600, so this must
be your own login):

```sh
curl -sS -H "Authorization: Bearer $(cat hub/token)" \
  http://192.168.68.81:8123/api/states \
  | python3 -c '
import json, re, sys
states = {e["entity_id"] for e in json.load(sys.stdin)}
text = open("panel/assets/house/bindings.yaml").read()
bound = set(re.findall(r"entity:\s*([a-z_]+\.[a-z0-9_]+)", text))
print("bound but absent from the Hub:")
for e in sorted(bound - states): print("  ", e)
print("on the Hub, referenced by no binding:")
for e in sorted(states - bound): print("  ", e)
'
```

The first list is what `hub.missing_entities` already tells you. The second
is the new one, and it will be long — most of it is HA plumbing (`sun.*`,
`person.*`, `update.*`, every `*_led` and `*_cloud_connection`). Length is
not the point; **triage is**. Every entity in it lands in one of four
buckets, and the buckets go into §2's table alongside the mapping:

| Bucket | Meaning | Action |
|---|---|---|
| **Not a Device** | HA internals, diagnostics, LED and status children | none — expected noise |
| **Deliberately unexposed** | real and controllable, and we chose not to pin it (`switch.old_fridge`, `switch.aquarium`) | record *why*, with the ADR reference — otherwise the next sweep re-litigates it |
| **Redundant** | a parent whose children are bound (`switch.tp_link_smart_plug_722c`) | none — binding it too would double-drive the outlets |
| **Genuinely unexposed** | a real Device with no Key | the only real finding. Needs a drawing session (ADR-0005), and possibly a new `DeviceKind` before that |

The honest version of this phase's headline is `missing=0` **and** an empty
"genuinely unexposed" bucket. Automating the inverse check — a test, or a
`[panel]` diagnostic that logs unreferenced non-plumbing entities — is a
reasonable follow-up; the classification is a judgement call and stays human.

## 2. Placeholder-Key hygiene (D5)

Each binding was made against the placeholder house's Keys. Record the
physical-device → Key mapping table HERE as bindings are made (device
serial/location → Key) — when the real Sweet Home 3D drawing lands, its
markers must be typed with these same Keys and the bindings file carries
over untouched (ADR-0005's whole promise). Any Key that got bound to a
device in a *different* real room than the placeholder Room is a note in
the table, not a problem — the real drawing fixes geometry, not identity.

## 3. Test and golden closure

```sh
cd panel
flutter test                          # full suite, including new Popup tests
flutter test --update-goldens test/golden   # regenerate, EYEBALL the diffs
python3 tool/test_sh3d_to_yaml.py
PANEL_LIVE_HUB=1 HA_URL=http://<hub-ip>:8123 HA_TOKEN="$(cat ../hub/token)" \
  flutter test test/ha_hub_live_test.dart                    # against the laptop
```

Goldens will legitimately change (pins now carry real state shapes);
regenerate deliberately and review the diff images — per the panel README,
never rubber-stamp.

## 4. Documentation closure

- `README.md` (root): the "First implementation steps" list and the
  development-topology section get updated — the Hub now runs on the
  laptop (ADR-0008), integrations done, spike remains the final step.
- `hub/README.md`: bring-up notes gain ring-mqtt + wyze-bridge sections
  (promote the relevant text from `hub/dev/README.md`).
- ~~`panel/README.md`: Popup video (MSE/go2rtc) section; `GO2RTC_URL`
  documented next to `HA_URL`, environment-first via `resolveHubConfig`.~~
  **Done 2026-08-04** — "Live video in the Popup", covering `GO2RTC_URL`,
  `stream:` in `bindings.yaml`, the five Popup bodies, the doorbell rule, the
  two transports and the go2rtc config shape they need. The appliance half
  landed with it: `panel_go2rtc_url` → `Environment=GO2RTC_URL=`, documented in
  `appliance/ansible/README.md` and Ch. 6 §6.5a/§6.5b. The "two things still
  missing" this bullet used to name — the MSE shim and go2rtc's cross-origin
  refusal — are both **done**, and rewriting the prose that described them was
  its own pass. **Re-read it at closure time anyway**: what is written in the
  present tense there now is "proven against `selftest`, never against a
  camera", and that sentence becomes a lie the day a camera lands.
- `panel/assets/house/bindings.yaml`: the sweep is also where `stream:`
  values stop being commented examples. Each `cam-*` and the `doorbell` need
  the **name** of a stream that exists in `hub/go2rtc/go2rtc.yaml`, and
  `house.loaded streams=` is the count to check it against — two Devices
  naming one stream is legal, so nothing else will notice a copy-paste.
- This plan directory: each phase file's "Done when" boxes checked with
  dates; A1 camera inventory and §2's Key-mapping table filled in.
- Calendar items (root README) re-checked: the oven decision (Oct 2026)
  and Samsung TV `turn_on` item stand; add "Emporia reflash bench day"
  and "Wyze RTSP firmware security-lag review" if D1 flashed anything.

## Done when

Every box above holds — including §1a's inverse pass with an empty
"genuinely unexposed" bucket, not just `missing=0` — `flutter test` is
green (with every integrated Key listed in `bindings_drift_test.dart`'s
`_integrated` set), and a phone photo of the
Panel showing live watts, a running washer, a doorbell popup, and a
toggled real light exists in the family chat. That last one is the actual
acceptance test.
