#!/usr/bin/env python3
"""Phase-0 experiment instrument — inspect and doctor Sweet Home 3D files.

Throwaway: delete this file when phase 0's results table is filled in
(docs/plans/sh3d-import/phase-0-experiment-gate.md). Python stdlib only.

    ./sh3d-lab.py inspect  MyHouse.sh3d
    ./sh3d-lab.py inject   MyHouse.sh3d -o MyHouse-keyed.sh3d

`inspect` prints everything phase 0 needs to know about a drawing — levels,
rooms, walls, every furniture element with its user-defined <property>
children, and the coordinate ranges. Paste its output verbatim.

`inject` writes user-defined properties (placementKey, kind) onto furniture
pieces the way the pipeline eventually would, so a stock Sweet Home 3D can
be asked the one question no documentation answers: does it keep them?
"""

import argparse
import re
import shutil
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

FURNITURE = ('pieceOfFurniture', 'doorOrWindow', 'light', 'shelfUnit',
             'furnitureGroup')


def read_home_xml(path):
    """Home.xml bytes out of a .sh3d archive, or the file itself."""
    p = Path(path)
    if zipfile.is_zipfile(p):
        with zipfile.ZipFile(p) as z:
            names = z.namelist()
            if 'Home.xml' not in names:
                sys.exit(f'{p}: no Home.xml (entries: {names[:5]}…)')
            return z.read('Home.xml'), names
    return p.read_bytes(), None


def walk_furniture(parent, inherited_level=None):
    """(element, effective level id, depth) for every furniture element,
    recursing into groups — child level overrides the group's."""
    for child in parent:
        if child.tag not in FURNITURE:
            continue
        level = child.get('level', inherited_level)
        yield child, level, 0 if parent.tag == 'home' else 1
        if child.tag == 'furnitureGroup':
            yield from walk_furniture(child, level)


def props_of(el):
    return {p.get('name'): p.get('value') for p in el.findall('property')}


def cmd_inspect(args):
    raw, entries = read_home_xml(args.file)
    root = ET.fromstring(raw)

    print('=' * 72)
    print(f'FILE      {args.file}')
    if entries is not None:
        legacy = 'Home' in entries
        print(f'ARCHIVE   {len(entries)} entries · legacy "Home" entry: '
              f'{"PRESENT" if legacy else "absent"}')
    print(f'VERSION   {root.get("version")}   name={root.get("name")!r}   '
          f'wallHeight={root.get("wallHeight")}')
    home_props = props_of(root)
    print(f'HOME PROPS {len(home_props)} (SH3D UI prefs — proof the property '
          f'mechanism round-trips at home scope)')

    levels = root.findall('level')
    print(f'\nLEVELS    {len(levels)}'
          f'{"   *** ZERO — the synthesize-a-default case ***" if not levels else ""}')
    for lv in levels:
        print(f'  id={lv.get("id"):<40} name={lv.get("name")!r:<18} '
              f'elev={lv.get("elevation")} elevIdx={lv.get("elevationIndex")} '
              f'height={lv.get("height")} viewable={lv.get("viewable")} '
              f'props={props_of(lv) or "{}"}')

    rooms = root.findall('room')
    named = [r for r in rooms if r.get('name')]
    print(f'\nROOMS     {len(rooms)}  named={len(named)}')
    for r in rooms:
        pts = [(p.get('x'), p.get('y')) for p in r.findall('point')]
        print(f'  id={r.get("id"):<40} name={r.get("name")!r:<18} '
              f'level={r.get("level")} floorVisible={r.get("floorVisible")} '
              f'props={props_of(r) or "{}"}')
        print(f'      points[{len(pts)}] {pts[:4]}{" …" if len(pts) > 4 else ""}')

    walls = root.findall('wall')
    print(f'\nWALLS     {len(walls)}   '
          f'no-height={sum(1 for w in walls if w.get("height") is None)}   '
          f'arcExtent!=0={sum(1 for w in walls if float(w.get("arcExtent", 0) or 0) != 0)}')

    pieces = list(walk_furniture(root))
    with_props = [(e, lv) for e, lv, _ in pieces if props_of(e)]
    tags = {}
    for e, _, _ in pieces:
        tags[e.tag] = tags.get(e.tag, 0) + 1
    print(f'\nFURNITURE {len(pieces)}   by tag: {tags}')
    print(f'          carrying <property> children: {len(with_props)}'
          f'{"   *** NONE — properties did not survive, or were never set ***" if not with_props else ""}')
    for e, lv in with_props:
        print(f'  <{e.tag}> name={e.get("name")!r} level={lv}')
        print(f'      catalogId={e.get("catalogId")!r}  x={e.get("x")} '
              f'y={e.get("y")}  angle={e.get("angle")}')
        print(f'      PROPS {props_of(e)}')
    if args.all_furniture:
        print('\n  --- every piece (name / catalogId / x / y / angle) ---')
        for e, lv, depth in pieces:
            print(f'  {"  " * depth}<{e.tag}> {e.get("name")!r} '
                  f'cat={e.get("catalogId")!r} x={e.get("x")} y={e.get("y")} '
                  f'angle={e.get("angle")} level={lv}')

    xs, ys = [], []
    for r in rooms:
        for p in r.findall('point'):
            xs.append(float(p.get('x'))); ys.append(float(p.get('y')))
    for w in walls:
        xs += [float(w.get('xStart')), float(w.get('xEnd'))]
        ys += [float(w.get('yStart')), float(w.get('yEnd'))]
    if xs:
        print(f'\nCOORDS    x[{min(xs):.1f}, {max(xs):.1f}]  '
              f'y[{min(ys):.1f}, {max(ys):.1f}]  (cm)')
    angles = [float(e.get('angle')) for e, _, _ in pieces if e.get('angle')]
    if angles:
        print(f'ANGLES    n={len(angles)} min={min(angles):.4f} '
              f'max={max(angles):.4f}  -> {"RADIANS" if max(angles) <= 6.3 else "DEGREES"}')
    print('=' * 72)


def cmd_inject(args):
    raw, _ = read_home_xml(args.file)
    root = ET.fromstring(raw)
    n = 0
    for el, _, _ in walk_furniture(root):
        if el.tag == 'furnitureGroup':
            continue
        if args.limit and n >= args.limit:
            break
        name = el.get('name') or f'piece{n}'
        key = re.sub(r'[^a-z0-9]+', '-', name.lower()).strip('-') or f'piece{n}'
        for prop in ('placementKey', 'kind'):
            for old in el.findall(f"property[@name='{prop}']"):
                el.remove(old)
        made = [ET.Element('property', {'name': 'placementKey', 'value': key}),
                ET.Element('property', {'name': 'kind', 'value': 'light'})]
        for i, p in enumerate(made):
            el.insert(i, p) if args.props_first else el.append(p)
        print(f'  + {el.tag} {name!r} -> placementKey={key}')
        n += 1
    if not n:
        sys.exit('no furniture found — place a few pieces first')

    body = ET.tostring(root, encoding='UTF-8', xml_declaration=True)
    src, dst = Path(args.file), Path(args.output)
    if zipfile.is_zipfile(src):
        shutil.copy(src, dst)
        with zipfile.ZipFile(src) as zin:
            keep = [i for i in zin.infolist()
                    if i.filename != 'Home.xml'
                    and not (args.drop_legacy and i.filename == 'Home')]
            data = {i.filename: zin.read(i.filename) for i in keep}
        with zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED) as zout:
            zout.writestr('Home.xml', body)
            for name, blob in data.items():
                zout.writestr(name, blob)
    else:
        dst.write_bytes(body)
    print(f'\nwrote {dst}  ({n} piece(s) keyed'
          f'{", legacy Home entry dropped" if args.drop_legacy else ""})')
    print('Now: open it in Sweet Home 3D, move something, save, and re-inspect.')


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest='cmd', required=True)

    i = sub.add_parser('inspect', help='report everything phase 0 needs')
    i.add_argument('file', help='.sh3d archive or a bare Home.xml')
    i.add_argument('--all-furniture', action='store_true',
                   help='also list every piece, not just keyed ones')
    i.set_defaults(func=cmd_inspect)

    j = sub.add_parser('inject', help='write placementKey/kind onto pieces')
    j.add_argument('file')
    j.add_argument('-o', '--output', required=True)
    j.add_argument('--limit', type=int, default=0, help='0 = every piece')
    j.add_argument('--props-first', action='store_true',
                   help='insert <property> before other children (retry knob '
                        'if SH3D refuses to open the file)')
    j.add_argument('--drop-legacy', action='store_true',
                   help='omit the legacy Java "Home" entry (retry knob if the '
                        'injected properties do not appear after reopening)')
    j.set_defaults(func=cmd_inject)

    args = ap.parse_args()
    args.func(args)


if __name__ == '__main__':
    main()
