#!/usr/bin/env python3
"""Generate SmartHome.sh3f — the Sweet Home 3D marker library.

    python3 sh3d_marker_library.py -o ~/sh3d-lab/SmartHome.sh3f

Import the result once (Furniture > Import furniture library…) and every
Device kind appears under a "Smart Home" category. Drag a marker into the
plan, double-click it, and the Modify furniture dialog carries an **Other
properties…** button holding an editable `placementKey` — the one thing an
author types. `kind` arrives already filled in from the catalog entry.

Why this file exists (phase 0, E6b). Sweet Home 3D preserves user
`<property>` elements perfectly across a save, but never *shows* one that
was written from outside: the Modify furniture dialog, the Modify rooms
dialog and Furniture > Display column are all empty for a piece carrying
properties, because every one of them is driven by properties the piece's
**catalog entry** declares. Declaring them here is the only way to make
SH3D an editor of our data rather than just a faithful courier for it.

Verified against Sweet Home 3D 7.5 sources, not guessed:

  * `DefaultFurnitureCatalog.getCatalogAdditionalProperties` turns *any*
    `<name>#<index>` key whose name is not a built-in into an additional
    property of entry `<index>`, with an optional `:<TYPE>` key suffix.
  * It builds them with `new ObjectProperty(name, type)`, and that
    constructor delegates to `(name, null, type, true, true, true)` —
    displayable, **modifiable**, exportable. Editability is not optional
    and needs no extra key.
  * `FurnitureController.createHomePieceOfFurniture` copies every catalog
    property name onto the placed piece (dropping only the
    `modelPresetTransformations*` ones), so the declaration reaches the
    drawing.
  * `getContent` resolves a piece's `icon#`/`model#` as
    `jar:<sh3f-url>!<value>`, so those values must be archive-absolute.

Identity comes free with the library: every marker carries
`catalogId="SmartHome#<kind>"`, so the converter recognises a Device
marker by its catalogId and can never mistake a bed for one. The
`placementKey` property is the Device's identity; `bindings.yaml` owns the
Hub entity id (ADR-0004 keeps generated and hand-maintained data apart).

Python stdlib only, matching sh3d_to_yaml.py.
"""

import argparse
import struct
import zlib
import zipfile
from pathlib import Path

# The Device vocabulary, kebab-case exactly as devices.yaml spells it and
# as house_loader.dart's _kind() parses it — a marker whose kind the loader
# rejects would be a paper cut invented here rather than by the author.
KINDS = [
    ('light',          'Light',          (0xFF, 0xC1, 0x07)),
    ('outlet',         'Outlet',         (0x79, 0x55, 0x48)),
    ('thermostat',     'Thermostat',     (0xFF, 0x57, 0x22)),
    ('camera',         'Camera',         (0x3F, 0x51, 0xB5)),
    ('doorbell',       'Doorbell',       (0x00, 0x96, 0x88)),
    ('oven',           'Oven',           (0xE5, 0x39, 0x35)),
    ('tv',             'TV',             (0x37, 0x47, 0x4F)),
    ('washer',         'Washer',         (0x21, 0x96, 0xF3)),
    ('dryer',          'Dryer',          (0x00, 0xBC, 0xD4)),
    ('litter-robot',   'Litter Robot',   (0x8B, 0xC3, 0x4A)),
    ('feeder',         'Feeder',         (0x4C, 0xAF, 0x50)),
    ('garage-door',    'Garage Door',    (0x9E, 0x9E, 0x9E)),
    ('ev-charger',     'EV Charger',     (0x7C, 0x4D, 0xFF)),
    ('energy-monitor', 'Energy Monitor', (0xFF, 0xEB, 0x3B)),
]

CATEGORY = 'Smart Home'
CREATOR = 'SmartHome'

# A 10 cm cube. Sweet Home 3D scales any model to the entry's
# width/depth/height, so the shape only has to be small, closed, and
# unmistakably not furniture.
MARKER_OBJ = """# SmartHome Device marker
g marker
v -5 0 -5
v  5 0 -5
v  5 0  5
v -5 0  5
v -5 10 -5
v  5 10 -5
v  5 10  5
v -5 10  5
f 1 4 3 2
f 5 6 7 8
f 1 2 6 5
f 2 3 7 6
f 3 4 8 7
f 4 1 5 8
"""


def _png_chunk(tag, data):
    return (struct.pack('>I', len(data)) + tag + data
            + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF))


def icon_png(rgb, size=64):
    """A flat disc in the kind's colour with a darker rim — enough to tell
    the markers apart while scrolling the catalog."""
    dark = tuple(max(0, c - 70) for c in rgb)
    centre = (size - 1) / 2
    outer = size * 0.44
    inner = outer - 3
    rows = []
    for y in range(size):
        row = bytearray(b'\x00')  # filter type 0
        for x in range(size):
            d = ((x - centre) ** 2 + (y - centre) ** 2) ** 0.5
            row += bytes(rgb if d <= inner else dark if d <= outer
                         else (0xFF, 0xFF, 0xFF))
        rows.append(bytes(row))
    header = struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0)
    return (b'\x89PNG\r\n\x1a\n'
            + _png_chunk(b'IHDR', header)
            + _png_chunk(b'IDAT', zlib.compress(b''.join(rows), 9))
            + _png_chunk(b'IEND', b''))


def catalog_properties():
    """PluginFurnitureCatalog.properties.

    Mandatory per entry, all read with `resource.getString` so a missing
    one aborts the load: name, category, icon, model, width, depth,
    height, movable, doorOrWindow. Indexes start at 1 and must be
    contiguous — `readFurniture` stops at the first absent `name#`.
    """
    out = [
        '# SmartHome Device markers — generated by tool/sh3d_marker_library.py.',
        '# Do not hand-edit; regenerate instead.',
        '#',
        '# Each entry declares two additional properties. `placementKey` is the',
        '# Device identity the author types; `kind` is preset and rarely touched.',
        '# The \\: escape is required — an unescaped colon would end the key,',
        '# and Java would read the type as part of the value.',
        '',
        'id=SmartHome#markers',
        'name=SmartHome Device markers',
        'description=Typed markers for placing Devices in the House Plan',
        'version=1.0',
        'license=Public domain',
        'provider=SmartHome',
        '',
    ]
    for i, (slug, label, _) in enumerate(KINDS, start=1):
        out += [
            f'id#{i}=SmartHome#{slug}',
            f'name#{i}={label}',
            f'description#{i}=Device marker — set placementKey in Other properties',
            f'category#{i}={CATEGORY}',
            f'creator#{i}={CREATOR}',
            f'icon#{i}=/resources/{slug}.png',
            f'model#{i}=/resources/marker.obj',
            f'width#{i}=10',
            f'depth#{i}=10',
            f'height#{i}=10',
            f'elevation#{i}=0',
            f'movable#{i}=true',
            f'doorOrWindow#{i}=false',
            # The two that make this library worth building.
            f'placementKey#{i}\\:STRING=',
            f'kind#{i}\\:STRING={slug}',
            '',
        ]
    return '\n'.join(out)


def build(path):
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('PluginFurnitureCatalog.properties', catalog_properties())
        z.writestr('resources/marker.obj', MARKER_OBJ)
        for slug, _, rgb in KINDS:
            z.writestr(f'resources/{slug}.png', icon_png(rgb))
    return path


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('-o', '--output', default='SmartHome.sh3f',
                    help='where to write the library (default: ./SmartHome.sh3f)')
    args = ap.parse_args()

    path = build(Path(args.output).expanduser())
    print(f'wrote {path}  ({len(KINDS)} markers)')
    print('\nSweet Home 3D → Furniture → Import furniture library…')
    print(f'  then look for the "{CATEGORY}" category in the catalog.')


if __name__ == '__main__':
    main()
