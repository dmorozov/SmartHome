# Phase 6 — Full-fleet bindings sweep and closure

The audit pass: everything available is bound, everything bound is honest,
and the docs say what is now true.

## 1. The sweep

Run the Panel against the laptop Hub with `--dart-define=LOG=info` and
work the diagnostics until clean:

- `hub.snapshot entities=<n> bound=<m> missing=0` — **missing=0 is the
  phase's headline number** for every Device whose hardware exists.
  Devices whose hardware does NOT exist keep no `entity:` line and are
  excluded by construction (they log nothing).
- No lingering `hub.state_unusable` at rest.
- Every binding's `connectivity:` matches reality per this plan's phases —
  the Popup shows it, so a lie is user-visible. Expected split:
  - `local`: Kasa ×3, Tesla WC, Ecobee (HomeKit), any RTSP-flashed Wyze
  - `cloud`: Ring, wyze-bridge cams, LG ×2, Litter-Robot, Petlibro ×2,
    Emporia (until reflash day)
  - unbound (hardware absent): `garage-door` (awaits ratgdo),
    `oven` (D3 — unless the October decision funds it), `tv-*` (out of
    scope), plus any `light-*`/`outlet-*` Key with no physical device yet.

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
flutter test test/ha_hub_live_test.dart --dart-define=HA_TOKEN=... # against the laptop
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
- `panel/README.md`: Popup video (MSE/go2rtc) section; `GO2RTC_URL`
  dart-define documented next to `HA_URL`.
- This plan directory: each phase file's "Done when" boxes checked with
  dates; A1 camera inventory and §2's Key-mapping table filled in.
- Calendar items (root README) re-checked: the oven decision (Oct 2026)
  and Samsung TV `turn_on` item stand; add "Emporia reflash bench day"
  and "Wyze RTSP firmware security-lag review" if D1 flashed anything.

## Done when

Every box above holds, `flutter test` is green, and a phone photo of the
Panel showing live watts, a running washer, a doorbell popup, and a
toggled real light exists in the family chat. That last one is the actual
acceptance test.
