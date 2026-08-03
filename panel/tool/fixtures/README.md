# Converter fixtures

Sweet Home 3D drawings, kept as their extracted `Home.xml` — the only part anything parses. The `.sh3d` archives are ZIPs whose weight is 3D models and textures (127 MB for the four gallery plans) and are gitignored; drop them here if you want to open one in the app.

## Ours — the drawings the pipeline is built on

| File | What it pins |
|---|---|
| `placeholder-house.Home.xml` | The shipped House Plan. 3 Floors, 15 Rooms, 27 Walls, 33 Device markers mirroring `bindings.yaml`. Its conversion **is** `assets/house/house.yaml`, byte for byte — a stand-in for the real house until it is drawn |
| `marker-props.Home.xml` | Device markers exactly as Sweet Home 3D 7.5 writes them. The first `<pieceOfFurniture>` is verbatim from a real save, so this is the ground truth the marker parser is coded against |
| `no-levels.Home.xml` | The one-storey case: **zero `<level>` elements**, no `level` attribute anywhere. Also keeps a zero-length wall, because real drawings carry that kind of debris |
| `negative-origin.Home.xml` | `placeholder-house` translated by (−300, −200) cm. Must convert to identical YAML — the shared-origin min-shift erasing the offset is the property under test |

## Theirs — four public gallery plans, kept to be refused

`AlpsHotel` · `Blues` · `House-based-on-a-factory` · `Industrial_Loft`

These are what real third-party drawings look like, and the converter is meant to **reject** them with messages rather than guess: 37 of their 95 rooms are unnamed, duplicate room names are idiomatic, diagonal walls are ordinary. `RealWorldPlans` in `../test_sh3d_to_yaml.py` asserts each is refused for its own documented reasons — so the gatekeeper posture is a tested property, not prose.

They are also the evidence base for [`docs/sweet-home-3d-behaviour.md`](../../../docs/sweet-home-3d-behaviour.md), and the same test re-derives every count that document quotes: 1,724 furniture elements, 95 rooms, 411 walls, 1,303 angles all below 2π, 120 furniture groups, 4 `<shelfUnit>`s, and **zero** `<property>` children. The doc cannot drift from the files it cites.

| File | Levels | Rooms (unnamed) | Furniture | Why this one |
|---|---|---|---|---|
| `AlpsHotel.Home.xml` | 4 | 40 (22) | 1037 | over half its rooms unnamed; the widest spread of error classes |
| `Blues.Home.xml` | 3 | 30 (3) | 268 | 218 `pieceOfFurniture` and **zero `<light>` elements** — the proof that element tags classify nothing. Reaches −701 cm |
| `House-based-on-a-factory.Home.xml` | 4 | 21 (8) | 203 | a real mezzanine stack (elevations 0 / 260 / 402 / 604) |
| `Industrial_Loft.Home.xml` | 2 | 4 (4) | 216 | the corpus's only `<shelfUnit>`s (4), a 7.x-only tag; and the only plan drawn entirely in positive coordinates |

## Re-extracting after dropping an archive here

```sh
python3 - <<'EOF'
import zipfile, pathlib
for f in pathlib.Path('tool/fixtures').glob('*.sh3d'):
    name = f.name.replace('-compressed', '').removesuffix('.sh3d')
    (f.parent / f'{name}.Home.xml').write_bytes(zipfile.ZipFile(f).read('Home.xml'))
EOF
```
