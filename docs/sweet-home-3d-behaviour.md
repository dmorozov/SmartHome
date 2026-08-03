# Sweet Home 3D behaviour the pipeline depends on

Measured, not assumed. Sweet Home 3D's file format and its extension points are undocumented in the places that matter, and its support forum is not web-indexed, so every fact below came from an experiment against a real drawing or from reading the 7.5 sources in `/Applications/Sweet Home 3D.app/Contents/app/SweetHome3D.jar`. Recorded here because re-deriving any of it costs an afternoon.

Versions: measured against **Sweet Home 3D 7.5** on macOS, writing `<home version="7400">`.

**Corpus for the static measurements:** four public gallery plans, kept as their extracted `Home.xml` in [`panel/tool/fixtures/`](../panel/tool/fixtures/README.md) — 1,724 furniture elements, 95 rooms, 411 walls. Their `.sh3d` archives are 127 MB and deliberately untracked; every count below comes from the 1.2 MB of XML.

**These numbers are checked, not quoted.** `RealWorldPlans.test_the_corpus_still_backs_the_behaviour_doc` in `panel/tool/test_sh3d_to_yaml.py` re-derives them from the files, so this document cannot drift from its own evidence. Run `python3 tool/test_sh3d_to_yaml.py` from `panel/`.

## User properties

**Unknown `<property>` children survive a stock save.** A drawing whose `Home.xml` was edited outside the app, then opened, modified and saved normally, kept all of them: 13 pieces, 2 properties each, all present afterwards. Stronger than mere preservation — their order changed (`placementKey,kind` in, `kind,placementKey` out), so the application parsed them into its own model and re-serialised them. They are first-class data, not tolerated debris. The archive's legacy Java-serialised `Home` entry does not shadow `Home.xml`.

```xml
<pieceOfFurniture catalogId='SmartHome#light' name='Light' x='988.5' y='696.5602'>
  <property name='kind' value='light'/>
  <property name='placementKey' value='light_kitchen_1'/>
</pieceOfFurniture>
```

**Nothing in the wild uses the mechanism.** Zero of the 1,724 corpus pieces carry a `<property>` child, which is why none of this could be settled by reading real files.

**The UI never shows a property written from outside.** Three independent surfaces come back empty for a piece carrying properties: *Modify furniture*, *Modify rooms*, and *Furniture → Display column*. All three render the **Home's** declared property list, and that list has exactly one source (below). So Sweet Home 3D is a faithful courier for our data and never, by default, an editor of it.

**Making the fields editable takes a startup flag**, read once by `SweetHome3D` and split on `,\s*`:

```sh
JAVA_TOOL_OPTIONS="-Dcom.eteks.sweethome3d.additionalFurnitureProperties=placementKey,kind" \
    "/Applications/Sweet Home 3D.app/Contents/MacOS/SweetHome3D"
```

It is **not persisted** into the `.sh3d` — neither `HomeXMLExporter` nor `HomeXMLHandler` mentions it — so it must be set on every launch. That is what `panel/tool/sh3d.sh` exists for. Opened without it, values are still safe; the fields are merely invisible and uneditable.

**Use bare property names.** `ObjectProperty.fromDescription` parses `name:TYPE displayable=… modifiable=… exportable=…`, but its attribute reader is off by one — `substring("modifiable=".length() + 1)` yields `"rue"` — so writing `modifiable=true` sets it **false**. All three default to true already. `:STRING` is safe; the boolean attributes are not.

**Rooms and Levels have no property mechanism at all**, in the file or the UI. Room and Floor identity is therefore the slug of the drawn name, and there is no way to author a stable key for them.

## The furniture catalog (`.sh3f`)

A catalog entry declares additional properties by any resource-bundle key of the form `<name>#<index>` whose name is not a built-in, with an optional `:<TYPE>` suffix. **The colon must be escaped** or `java.util.Properties` ends the key there and swallows the type into the value:

```properties
placementKey#1\:STRING=
kind#1\:STRING=light
```

`DefaultFurnitureCatalog` builds these with `new ObjectProperty(name, type)`, which delegates to `(name, null, type, true, true, true)` — displayable, **modifiable**, exportable, unconditionally. `FurnitureController.createHomePieceOfFurniture` then copies every catalog property name onto the placed piece (dropping only `modelPresetTransformations*`), so a declaration reaches the drawing.

Mandatory per entry, all read with `resource.getString`: `name`, `category`, `icon`, `model`, `width`, `depth`, `height`, `movable`, `doorOrWindow`. Indexes start at 1 and **must be contiguous** — `readFurniture` stops at the first absent `name#`, so a gap truncates the catalog silently. Content paths resolve as `jar:<sh3f-url>!<value>`, so `icon#`/`model#` must be archive-absolute (`/resources/…`).

The catalog declaration and the launch flag are **complementary, not alternatives**: the catalog puts values on the piece, the flag tells the Home the properties exist. Neither alone gives an editable field.

## Coordinates and geometry

- **Units are centimetres**; the Panel's House Plan is metres.
- **y increases southward.** Measured directly: a room drawn north of another has the smaller `y`. This matches ADR-0004's convention exactly — no negation anywhere.
- **Angles are radians**, not degrees. Measured across the corpus: 1,303 furniture angles (plus 174 on textures and 7 on labels — 1,484 in all), maximum 6.2832 = 2π, **none above 6.3**, clustered at float32 multiples of π. A degrees→radians conversion would mis-rotate everything by ~57×. The attribute is optional and **absent means zero** — an unrotated piece carries no `angle` at all.
- **Negative coordinates are the norm**, not an edge case: three of the four example plans have them (one reaches −700 cm) and the fourth never comes near the origin. The converter's shared-origin min-shift handles this.
- **A one-storey drawing writes no `<level>` element at all**, and no room, wall or piece carries a `level` attribute. Every real example plan has levels on everything, so this path only appears in first drawings — which is exactly when it matters.
- **Group children carry absolute plan coordinates**, verified 529/529 across the corpus' 120 `<furnitureGroup>`s, so a group's own position must never be added to them. A child's own `level` overrides its group's.
- **`arcExtent="0.0"` occurs on straight walls** — test `!= 0`, never presence.
- **Zero-length walls happen** and Sweet Home 3D saves them without complaint (a mis-click while drawing).
- **`<home name>` is the file name**, not a house name, and it follows the file across saves. Use the converter's `--name`.

## Things that classify nothing

- **Element tags do not identify Devices.** One real plan has 218 furniture pieces and zero `<light>` elements. Recognition must key on the marker property or `catalogId`, never the tag.
- **7.x emits `<shelfUnit>`**, which a walk written against the four legacy tags drops silently. Only 4 in the whole corpus — rare enough to miss, common enough to matter.
- **`catalogId` comes in three dialects** in the wild — `Creator#id`, flattened `creator-id`, and opaque 20-character tokens — so match exact strings from a table, never parse the shape. Ours are `SmartHome#<kind>`.
- **Duplicate names are the default, not an accident.** Sweet Home 3D names every placed piece after its catalog entry, so a 13-piece drawing produced 6 distinct name-slugs (four "Kitchen cabinet", four "Fixed window"). Anything deriving identity from a name collides immediately.
- **Sizes are advisory.** A 10 cm marker came back as 9.8425 — 10 cm rounded to the nearest ⅛ inch, the display unit. Positions are exact; dimensions are not.

## Third-party plans do not convert

Measured across all four example files: 39% of rooms are unnamed (37/95), duplicate room names are idiomatic both within and across floors, and diagonal walls are ordinary. `catalogId` is present on 92% of pieces (1,590/1,724) — missing only on in-app geometry like shapes and roofs. This pipeline serves one disciplined drawing, and ADR-0004's rules are authoring guidance — the converter's errors say how to fix the drawing rather than tolerating it.
