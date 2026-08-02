#!/usr/bin/env python3
"""Convert a Sweet Home 3D file into the Panel's generated house.yaml.

Usage:
    python3 sh3d_to_yaml.py INPUT -o assets/house/house.yaml [--name "My House"]

INPUT is a .sh3d archive or a bare Home.xml extracted from one.
Python stdlib only — no installs needed.

The pipeline and its rules are decided in docs/adr/0004 (grilled 2026-07-30):
  * every room must be named in Sweet Home 3D — ids are slugified names,
    unique across the whole house (devices.yaml references them)
  * room polygons must be rectilinear (right angles only)      -> ERROR
  * rooms on the same floor must not overlap                   -> ERROR
  * diagonal walls                                             -> ERROR
  * enclosed gaps between rooms (floor does not tile)          -> warning
  * room boundaries with no wall drawn along them              -> warning
The converter never invents geometry: an undrawn wall is an open passage.
Doors and windows placed in walls are ignored.

Output units are meters, origin at the house's NW corner (minimum x/y over
all floors — every floor shares this one origin), x east, y south. Room
polygon points are ordered so their shoelace area is positive in these
(y-south) coordinates.
"""

import argparse
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
from collections import defaultdict, namedtuple

ConvertResult = namedtuple(
    'ConvertResult', 'name floors origin errors warnings')

TOL_AXIS = 0.02  # m — max off-axis drift before an edge counts as diagonal
GRID = 0.1       # m — sampling grid for overlap / gap checks
WALL_NEAR = 0.25  # m — how far a wall centerline may sit from a room edge
COVER_WARN = 0.5  # warn when less than this fraction of a boundary is walled
CM = 0.01        # Sweet Home 3D stores centimeters


def load_home_xml(path):
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            with z.open('Home.xml') as f:
                return ET.parse(f).getroot()
    return ET.parse(path).getroot()


def slugify(name):
    return re.sub(r'[^a-z0-9]+', '-', name.lower()).strip('-')


def fmt(v):
    s = f'{v:.3f}'.rstrip('0').rstrip('.')
    return s if s not in ('', '-0') else '0'


def rectilinearize(pts, label, errors):
    """Drop duplicate points, snap near-axis edges onto the axis, drop
    collinear midpoints. Appends an error per genuinely diagonal edge."""
    out = []
    for p in pts:
        if out and abs(p[0] - out[-1][0]) <= TOL_AXIS \
                and abs(p[1] - out[-1][1]) <= TOL_AXIS:
            continue
        out.append([p[0], p[1]])
    if len(out) > 1 and abs(out[0][0] - out[-1][0]) <= TOL_AXIS \
            and abs(out[0][1] - out[-1][1]) <= TOL_AXIS:
        out.pop()
    if len(out) < 3:
        errors.append(f'{label}: fewer than 3 distinct corners')
        return out
    for i in range(len(out)):
        a, b = out[i], out[(i + 1) % len(out)]
        dx, dy = abs(a[0] - b[0]), abs(a[1] - b[1])
        if dx <= TOL_AXIS and dy <= TOL_AXIS:
            continue
        if dx <= TOL_AXIS:
            b[0] = a[0]
        elif dy <= TOL_AXIS:
            b[1] = a[1]
        else:
            errors.append(
                f'{label}: diagonal edge ({fmt(a[0])},{fmt(a[1])})→'
                f'({fmt(b[0])},{fmt(b[1])}) — right angles only; square 45° '
                f'corners off by assigning them to one room (ADR-0004)')
    # remove collinear midpoints
    cleaned = []
    n = len(out)
    for i in range(n):
        p0, p1, p2 = out[i - 1], out[i], out[(i + 1) % n]
        cross = (p1[0] - p0[0]) * (p2[1] - p0[1]) \
            - (p1[1] - p0[1]) * (p2[0] - p0[0])
        if abs(cross) > 1e-9:
            cleaned.append(p1)
    return cleaned


def shoelace(pts):
    s = 0.0
    for i in range(len(pts)):
        a, b = pts[i], pts[(i + 1) % len(pts)]
        s += a[0] * b[1] - b[0] * a[1]
    return s / 2.0


def contains(pts, x, y):
    """Even-odd point-in-polygon."""
    inside = False
    n = len(pts)
    for i in range(n):
        (x1, y1), (x2, y2) = pts[i], pts[(i + 1) % n]
        if (y1 > y) != (y2 > y):
            xt = x1 + (y - y1) * (x2 - x1) / (y2 - y1)
            if x < xt:
                inside = not inside
    return inside


def bbox(pts):
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return min(xs), min(ys), max(xs), max(ys)


def check_overlaps_and_gaps(floor_name, rooms, errors, warnings):
    """Grid-sample the floor: a cell inside two rooms is an overlap error;
    an uncovered cell not reachable from outside is an enclosed gap."""
    if not rooms:
        return
    x0 = min(bbox(r['pts'])[0] for r in rooms) - GRID
    y0 = min(bbox(r['pts'])[1] for r in rooms) - GRID
    x1 = max(bbox(r['pts'])[2] for r in rooms) + GRID
    y1 = max(bbox(r['pts'])[3] for r in rooms) + GRID
    nx = max(1, int((x1 - x0) / GRID))
    ny = max(1, int((y1 - y0) / GRID))
    boxes = [bbox(r['pts']) for r in rooms]
    owner = [[-1] * nx for _ in range(ny)]
    overlaps = set()
    for j in range(ny):
        cy = y0 + (j + 0.5) * GRID
        for i in range(nx):
            cx = x0 + (i + 0.5) * GRID
            for k, room in enumerate(rooms):
                bx = boxes[k]
                if not (bx[0] <= cx <= bx[2] and bx[1] <= cy <= bx[3]):
                    continue
                if contains(room['pts'], cx, cy):
                    if owner[j][i] >= 0:
                        overlaps.add((rooms[owner[j][i]]['name'], room['name']))
                    else:
                        owner[j][i] = k
    for a, b in sorted(overlaps):
        errors.append(
            f'{floor_name}: rooms "{a}" and "{b}" overlap — rooms must '
            f'partition the floor, never share area (ADR-0004)')
    # flood fill uncovered cells from the border; what's left is enclosed gaps
    reach = [[False] * nx for _ in range(ny)]
    stack = [(i, j) for j in range(ny) for i in range(nx)
             if (i in (0, nx - 1) or j in (0, ny - 1)) and owner[j][i] < 0]
    for i, j in stack:
        reach[j][i] = True
    while stack:
        i, j = stack.pop()
        for di, dj in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ni, nj = i + di, j + dj
            if 0 <= ni < nx and 0 <= nj < ny and not reach[nj][ni] \
                    and owner[nj][ni] < 0:
                reach[nj][ni] = True
                stack.append((ni, nj))
    gaps = [(i, j) for j in range(ny) for i in range(nx)
            if owner[j][i] < 0 and not reach[j][i]]
    if gaps:
        i, j = gaps[0]
        warnings.append(
            f'{floor_name}: {len(gaps)} grid cell(s) of enclosed space belong '
            f'to no room (near {fmt(x0 + i * GRID)},{fmt(y0 + j * GRID)}) — '
            f'rooms should tile the floor completely')


def check_wall_coverage(floor_name, rooms, walls, warnings):
    """Warn about room boundary edges that have (almost) no wall on them."""
    axis_walls = {'h': [], 'v': []}
    for w in walls:
        (ax, ay), (bx, by) = w
        if abs(ay - by) <= TOL_AXIS:
            axis_walls['h'].append((ay, min(ax, bx), max(ax, bx)))
        elif abs(ax - bx) <= TOL_AXIS:
            axis_walls['v'].append((ax, min(ay, by), max(ay, by)))
    seen = set()
    for room in rooms:
        pts = room['pts']
        for i in range(len(pts)):
            a, b = pts[i], pts[(i + 1) % len(pts)]
            if abs(a[1] - b[1]) <= TOL_AXIS:
                axis, c, lo, hi = 'h', a[1], min(a[0], b[0]), max(a[0], b[0])
            else:
                axis, c, lo, hi = 'v', a[0], min(a[1], b[1]), max(a[1], b[1])
            key = (axis, round(c, 2), round(lo, 2), round(hi, 2))
            if key in seen or hi - lo < GRID:
                continue
            seen.add(key)
            covered = 0.0
            for wc, wlo, whi in axis_walls[axis]:
                if abs(wc - c) <= WALL_NEAR:
                    covered += max(0.0, min(hi, whi) - max(lo, wlo))
            if covered / (hi - lo) < COVER_WARN:
                warnings.append(
                    f'{floor_name}: boundary of "{room["name"]}" along '
                    f'{"y" if axis == "h" else "x"}={fmt(c)} '
                    f'({fmt(lo)}..{fmt(hi)}) is mostly unwalled — open '
                    f'passage, or a forgotten wall?')


def convert(root, name=None):
    """Parsed Home.xml element -> ConvertResult. The whole conversion.

    Reads no files, writes none, never exits — every complaint comes back
    in `errors` and `warnings` for the caller to present.

    name    the house name: the --name override, else the file's own,
            else 'House', with any trailing '.sh3d' stripped
    floors  [{'slug', 'name', 'level', 'rooms': [{'id', 'name', 'pts'}],
             'walls': [[[x, y], [x, y]], ...]}], lowest level first, in
            meters from the one shared origin; empty floors dropped
    origin  (min_x, min_y) — the NW-corner shift already applied to every
            coordinate above, which is what devices.yaml positions are
            measured from
    """
    errors, warnings = [], []
    house_name = name or root.get('name') or 'House'
    house_name = re.sub(r'\.sh3d\s*$', '', house_name).strip()

    levels = root.findall('level')
    if levels:
        levels.sort(key=lambda lv: (float(lv.get('elevation', '0')),
                                    int(lv.get('elevationIndex', '0'))))
        below = sum(1 for lv in levels if float(lv.get('elevation', '0')) < 0)
        floors = []
        for i, lv in enumerate(levels):
            name = lv.get('name') or f'Level {i}'
            floors.append({'key': lv.get('id'), 'name': name,
                           'slug': slugify(name), 'level': i - below,
                           'rooms': [], 'walls': []})
    else:
        floors = [{'key': None, 'name': 'Ground Floor', 'slug': 'ground-floor',
                   'level': 0, 'rooms': [], 'walls': []}]
    by_key = {f['key']: f for f in floors}
    floor_slugs = defaultdict(list)
    for f in floors:
        floor_slugs[f['slug']].append(f['name'])
    for slug, names in floor_slugs.items():
        if len(names) > 1:
            errors.append(f'two levels slugify to "{slug}" — rename them to '
                          f'be distinct: {names}')

    raw_rooms, raw_walls = [], []
    for rm in root.findall('room'):
        floor = by_key.get(rm.get('level', floors[0]['key']))
        if floor is None:
            continue
        pts = [(float(p.get('x')) * CM, float(p.get('y')) * CM)
               for p in rm.findall('point')]
        raw_rooms.append({'floor': floor, 'name': rm.get('name'), 'pts': pts})
    for w in root.findall('wall'):
        floor = by_key.get(w.get('level', floors[0]['key']))
        if floor is None:
            continue
        raw_walls.append({'floor': floor, 'seg': [
            [float(w.get('xStart')) * CM, float(w.get('yStart')) * CM],
            [float(w.get('xEnd')) * CM, float(w.get('yEnd')) * CM]]})

    if not raw_rooms:
        errors.append('no rooms found — draw and name rooms in Sweet Home 3D')
        return ConvertResult(
            house_name, [], (0.0, 0.0), errors, warnings)

    # one shared origin: NW corner of everything drawn, on any floor
    min_x = min(min(p[0] for p in r['pts']) for r in raw_rooms if r['pts'])
    min_y = min(min(p[1] for p in r['pts']) for r in raw_rooms if r['pts'])
    for w in raw_walls:
        for p in w['seg']:
            min_x, min_y = min(min_x, p[0]), min(min_y, p[1])

    slugs = {}
    for r in raw_rooms:
        pts = [(round(x - min_x, 3), round(y - min_y, 3)) for x, y in r['pts']]
        if not r['name']:
            cx, cy = bbox(pts)[0], bbox(pts)[1]
            errors.append(f'unnamed room on "{r["floor"]["name"]}" (near '
                          f'{fmt(cx)},{fmt(cy)}) — name every room in Sweet '
                          f'Home 3D; ids come from names (ADR-0004)')
            continue
        label = f'room "{r["name"]}" ({r["floor"]["name"]})'
        pts = rectilinearize(pts, label, errors)
        if len(pts) < 3:
            continue
        if shoelace(pts) < 0:
            pts.reverse()
        slug = slugify(r['name'])
        if slug in slugs:
            errors.append(
                f'rooms "{slugs[slug]}" and "{r["name"]}" both get id '
                f'"{slug}" — room names must be unique across the whole '
                f'house (devices.yaml references them); rename one, e.g. '
                f'"Guest Bathroom" vs "Kids Bathroom"')
            continue
        slugs[slug] = r['name']
        r['floor']['rooms'].append({'id': slug, 'name': r['name'], 'pts': pts})

    for w in raw_walls:
        seg = [[round(p[0] - min_x, 3), round(p[1] - min_y, 3)]
               for p in w['seg']]
        (ax, ay), (bx, by) = seg
        dx, dy = abs(ax - bx), abs(ay - by)
        if dx <= TOL_AXIS and dy <= TOL_AXIS:
            continue  # zero-length
        if dx <= TOL_AXIS:
            seg[1][0] = ax
        elif dy <= TOL_AXIS:
            seg[1][1] = ay
        else:
            errors.append(
                f'diagonal wall ({fmt(ax)},{fmt(ay)})→({fmt(bx)},{fmt(by)}) '
                f'on "{w["floor"]["name"]}" — right angles only (ADR-0004)')
            continue
        w['floor']['walls'].append(seg)

    for f in floors:
        check_overlaps_and_gaps(f['name'], f['rooms'], errors, warnings)
        check_wall_coverage(f['name'], f['rooms'], f['walls'], warnings)

    floors = [f for f in floors if f['rooms'] or f['walls']]
    if not floors:
        errors.append('no floor has any geometry')

    return ConvertResult(
        house_name, floors, (min_x, min_y), errors, warnings)


def emit_yaml(name, floors, source):
    """The exact house.yaml text, header naming `source` as its origin."""
    out = [f'# Generated by sh3d_to_yaml.py from {source} — '
           f'DO NOT EDIT BY HAND (ADR-0004).',
           '# Meters from the house NW corner; x east, y south. Walls are',
           '# first-class: an undrawn wall is an open passage.',
           f'name: "{name}"',
           'floors:']
    for f in floors:
        out.append(f'  - id: {f["slug"]}')
        out.append(f'    name: "{f["name"]}"')
        out.append(f'    level: {f["level"]}')
        out.append('    rooms:')
        for r in f['rooms']:
            pts = ', '.join(f'[{fmt(x)}, {fmt(y)}]' for x, y in r['pts'])
            out.append(f'      - id: {r["id"]}')
            out.append(f'        name: "{r["name"]}"')
            out.append(f'        footprint: [{pts}]')
        out.append('    walls:')
        for (a, b) in f['walls']:
            out.append(f'      - [[{fmt(a[0])}, {fmt(a[1])}], '
                       f'[{fmt(b[0])}, {fmt(b[1])}]]')
    return '\n'.join(out) + '\n'


def main():
    """The adapter: argv in, files and exit codes out. Nothing else."""
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('input', help='.sh3d archive or bare Home.xml')
    ap.add_argument('-o', '--output', required=True, help='house.yaml path')
    ap.add_argument('--name', help='house name (default: from the file)')
    args = ap.parse_args()

    result = convert(load_home_xml(args.input), args.name)
    if result.errors:
        report_and_exit(result.errors, result.warnings)

    floors, warnings = result.floors, result.warnings
    min_x, min_y = result.origin
    with open(args.output, 'w') as fh:
        fh.write(emit_yaml(result.name, floors, args.input))

    for w in warnings:
        print(f'warning: {w}', file=sys.stderr)
    n_rooms = sum(len(f['rooms']) for f in floors)
    n_walls = sum(len(f['walls']) for f in floors)
    print(f'wrote {args.output}: {len(floors)} floor(s), {n_rooms} room(s), '
          f'{n_walls} wall(s), {len(warnings)} warning(s)')
    print(f'origin shift: yaml (x, y) = Sweet Home 3D (x, y) in cm / 100 '
          f'minus ({fmt(min_x)}, {fmt(min_y)}) m — use this to compute '
          f'devices.yaml positions from plan coordinates')


def report_and_exit(errors, warnings):
    for w in warnings:
        print(f'warning: {w}', file=sys.stderr)
    for e in errors:
        print(f'error: {e}', file=sys.stderr)
    print(f'aborted: {len(errors)} error(s) — nothing written',
          file=sys.stderr)
    sys.exit(1)


if __name__ == '__main__':
    main()
