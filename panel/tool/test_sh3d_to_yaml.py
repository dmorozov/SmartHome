#!/usr/bin/env python3
"""Tests for the converter's pure core (ADR-0004 pipeline, Python end).

    cd panel && python3 tool/test_sh3d_to_yaml.py

Everything here goes through `convert` and `emit_yaml` — the real interface,
no argv, no temp files — except the one case that has to prove the adapter
writes nothing when the drawing is rejected. Both checked-in fixtures earn
their keep: placeholder-house converts clean and its emitted YAML is the
shipped asset byte-for-byte, AlpsHotel (a Sweet Home 3D gallery example) is
rejected for the reasons ADR-0004 names.
"""

import pathlib
import re
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, str(pathlib.Path(__file__).parent))

from sh3d_to_yaml import DEVICE_KINDS, bbox, convert, emit_yaml  # noqa: E402

TOOL = pathlib.Path(__file__).parent
FIXTURES = TOOL / 'fixtures'
PLACEHOLDER = 'tool/fixtures/placeholder-house.Home.xml'
SHIPPED = TOOL.parent / 'assets' / 'house' / 'house.yaml'
LOADER = TOOL.parent / 'lib' / 'data' / 'house_loader.dart'

DEN = [(0, 0), (500, 0), (500, 500), (0, 500)]


def home(*body, name='Test House'):
    """A Home.xml with no levels — one implicit Ground Floor. Sweet Home 3D
    stores centimeters, so callers write cm and expect meters back."""
    return ET.fromstring(f'<home name="{name}">{"".join(body)}</home>')


def room(name, pts, level=None):
    points = ''.join(f'<point x="{x}" y="{y}"/>' for x, y in pts)
    lv = f' level="{level}"' if level else ''
    return f'<room name="{name}"{lv}>{points}</room>'


def marker(key='k1', kind='light', name='Marker', x=200, y=150,
           tag='pieceOfFurniture', catalog_id=None, level=None, body=''):
    """A Device marker in the syntax Sweet Home 3D 7.5 actually writes —
    `<property>` children, copied from fixtures/marker-props.Home.xml.

    `None` omits the attribute or property entirely, which is how the
    error cases below are built: a marker with no key, no name, no kind.
    """
    attrs = f' x="{x}" y="{y}"'
    if name is not None:
        attrs += f' name="{name}"'
    if catalog_id is not None:
        attrs += f' catalogId="{catalog_id}"'
    if level is not None:
        attrs += f' level="{level}"'
    props = ''
    if kind is not None:
        props += f"<property name='kind' value='{kind}'/>"
    if key is not None:
        props += f"<property name='placementKey' value='{key}'/>"
    return f'<{tag}{attrs}>{props}{body}</{tag}>'


class PlaceholderFixture(unittest.TestCase):
    """The fixture the shipped House Plan is generated from."""

    def setUp(self):
        self.result = convert(
            ET.parse(FIXTURES / 'placeholder-house.Home.xml').getroot(),
            'Demo House')

    def test_converts_clean(self):
        self.assertEqual(self.result.errors, [])
        self.assertEqual(len(self.result.floors), 3)
        self.assertEqual(
            sum(len(f['rooms']) for f in self.result.floors), 15)
        self.assertEqual(
            sum(len(f['walls']) for f in self.result.floors), 27)
        self.assertEqual([f['slug'] for f in self.result.floors],
                         ['ground-floor', 'upstairs', 'attic'])
        self.assertEqual([f['level'] for f in self.result.floors], [0, 1, 2])

    def test_warns_about_the_unwalled_family_room_boundary(self):
        # Presence, never count: the attic has no walls drawn at all, so it
        # legitimately warns about each of its four boundaries.
        self.assertTrue(
            any('Family Room' in w and 'x=13' in w
                for w in self.result.warnings),
            self.result.warnings)

    def test_golden_matches_the_shipped_asset(self):
        # The DO-NOT-EDIT header's promise, made checkable: what the
        # converter emits today is what the Panel actually loads.
        self.assertEqual(
            emit_yaml(self.result.name, self.result.floors, PLACEHOLDER,
                      self.result.devices),
            SHIPPED.read_text())


class AlpsHotelFixture(unittest.TestCase):
    """The negative fixture: a real drawing that breaks the rules."""

    def test_is_rejected_with_the_documented_error_classes(self):
        result = convert(
            ET.parse(FIXTURES / 'AlpsHotel.Home.xml').getroot())
        joined = '\n'.join(result.errors)
        self.assertNotEqual(result.errors, [])
        for expected in ('unnamed room', 'diagonal edge', 'diagonal wall'):
            self.assertIn(expected, joined)
        # Its valid rooms convert fine — one broken room still refuses the
        # whole drawing, which is what `test_nothing_written_on_error` pins.


class ConvertCore(unittest.TestCase):

    def test_origin_shift_applied(self):
        # Everything is measured from the house's NW corner, not from
        # wherever the family happened to draw (ADR-0004).
        result = convert(home(room('Den', [(500, 300), (1000, 300),
                                           (1000, 800), (500, 800)])))
        self.assertEqual(result.errors, [])
        self.assertEqual(result.origin, (5.0, 3.0))
        self.assertEqual(bbox(result.floors[0]['rooms'][0]['pts']),
                         (0.0, 0.0, 5.0, 5.0))

    def test_slug_collision_is_an_error(self):
        # Room ids are slugified names and Device markers reference them,
        # two rooms may not collapse to one id anywhere in the house.
        result = convert(home(
            room('Guest Bathroom', [(0, 0), (300, 0), (300, 300), (0, 300)]),
            room('guest  bathroom!',
                 [(400, 0), (700, 0), (700, 300), (400, 300)])))
        self.assertEqual(len(result.errors), 1, result.errors)
        self.assertIn('Guest Bathroom', result.errors[0])
        self.assertIn('guest  bathroom!', result.errors[0])
        self.assertIn('guest-bathroom', result.errors[0])

    def test_near_axis_edge_is_snapped(self):
        # 1 cm of drawing slop is not a design decision — snap it, so the
        # loader's strict axis check on the far side of the seam holds.
        result = convert(home(room('Den', [(0, 0), (500, 0),
                                           (501, 500), (0, 500)])))
        self.assertEqual(result.errors, [])
        self.assertEqual(
            {v for p in result.floors[0]['rooms'][0]['pts'] for v in p},
            {0.0, 5.0})

    def test_genuinely_diagonal_edge_is_an_error(self):
        result = convert(home(room('Den', [(0, 0), (500, 0),
                                           (550, 500), (0, 500)])))
        self.assertTrue(
            any('diagonal edge' in e for e in result.errors), result.errors)

    def test_no_rooms_is_an_error(self):
        result = convert(home())
        self.assertTrue(
            any('no rooms found' in e for e in result.errors), result.errors)


class Placements(unittest.TestCase):
    """Device markers read out of the drawing (ADR-0005). The converter is
    the authoring-time gate: every complaint names the piece the way the
    author sees it in Sweet Home 3D, because that is where the fix is."""

    def convert_den(self, *body):
        return convert(home(room('Den', DEN), *body))

    def test_marker_is_extracted_with_membership_and_position_computed(self):
        result = self.convert_den(
            marker(key='light-den', kind='light', name='Den Light',
                   x=200, y=150))
        self.assertEqual(result.errors, [])
        self.assertEqual(result.devices, [{
            'key': 'light-den', 'name': 'Den Light', 'kind': 'light',
            'room': 'den', 'position': (2.0, 1.5)}])

    def test_key_spelling_is_the_authors_business(self):
        # Underscores, hyphens, capitals, digits — SH3D constrains none of
        # it and neither do we. Only emptiness and collisions are rejected.
        for key in ('light_kitchen_1', 'Light-Kitchen', 'l1'):
            result = self.convert_den(marker(key=key))
            self.assertEqual(result.errors, [], key)
            self.assertEqual(result.devices[0]['key'], key)

    def test_position_is_origin_shifted_like_every_other_coordinate(self):
        result = convert(home(
            room('Den', [(500, 300), (1000, 300), (1000, 800), (500, 800)]),
            marker(x=700, y=500)))
        self.assertEqual(result.errors, [])
        self.assertEqual(result.origin, (5.0, 3.0))
        self.assertEqual(result.devices[0]['position'], (2.0, 2.0))

    def test_a_marker_never_moves_the_origin(self):
        # The origin anchors every wall and footprint in the house; letting
        # a stray marker define it would move the whole drawing.
        result = convert(home(room('Den', DEN), marker(x=-9000, y=-9000)))
        self.assertEqual(result.origin, (0.0, 0.0))
        self.assertTrue(any('not in any room' in e for e in result.errors),
                        result.errors)

    def test_marker_inside_a_group_keeps_absolute_coordinates(self):
        # Group children carry absolute plan coordinates (529/529 measured
        # in real files), so the group's own position must not be added.
        result = self.convert_den(
            f'<furnitureGroup name="Kit" x="9999" y="9999">'
            f'{marker(x=200, y=150)}</furnitureGroup>')
        self.assertEqual(result.errors, [])
        self.assertEqual(result.devices[0]['position'], (2.0, 1.5))

    def test_marker_in_a_group_takes_its_own_floor_over_the_groups(self):
        result = convert(home(
            '<level id="l0" name="Ground Floor" elevation="0"'
            ' elevationIndex="0"/>',
            '<level id="l1" name="Upstairs" elevation="300"'
            ' elevationIndex="0"/>',
            room('Den', DEN, level='l0'),
            room('Loft', DEN, level='l1'),
            f'<furnitureGroup name="Kit" level="l0">'
            f'{marker(level="l1")}</furnitureGroup>'))
        self.assertEqual(result.errors, [])
        self.assertEqual(result.devices[0]['room'], 'loft')

    def test_markers_on_any_furniture_tag_are_walked(self):
        # Tags classify nothing — one real plan had 218 pieces and zero
        # <light> elements — so the walk must cover all five, shelfUnit
        # included (7.x-only; a legacy four-tag walk drops it silently).
        for tag in ('pieceOfFurniture', 'doorOrWindow', 'light', 'shelfUnit'):
            result = self.convert_den(marker(tag=tag))
            self.assertEqual(result.errors, [], tag)
            self.assertEqual(len(result.devices), 1, tag)

    def test_kind_comes_from_the_catalog_when_no_property_carries_it(self):
        result = self.convert_den(
            marker(kind=None, catalog_id='SmartHome#thermostat'))
        self.assertEqual(result.errors, [])
        self.assertEqual(result.devices[0]['kind'], 'thermostat')

    def test_a_library_marker_still_needs_a_key(self):
        result = self.convert_den(
            marker(key=None, kind=None, catalog_id='SmartHome#light'))
        self.assertEqual(result.devices, [])
        self.assertIn('no key', result.errors[0])
        self.assertIn('sh3d.sh', result.errors[0])

    def test_a_key_with_no_kind_anywhere_errors(self):
        result = self.convert_den(marker(kind=None, catalog_id='eTeks#bed'))
        self.assertEqual(result.devices, [])
        self.assertIn('no kind', result.errors[0])

    def test_unknown_kind_errors_listing_the_valid_ones(self):
        result = self.convert_den(marker(kind='lightbulb'))
        self.assertEqual(result.devices, [])
        self.assertIn('lightbulb', result.errors[0])
        for kind in ('light', 'energy-monitor'):
            self.assertIn(kind, result.errors[0])

    def test_nameless_marker_errors(self):
        result = self.convert_den(marker(name=None))
        self.assertEqual(result.devices, [])
        self.assertIn('no name', result.errors[0])

    def test_duplicate_key_errors_naming_both_rooms(self):
        result = convert(home(
            room('Den', DEN),
            room('Hall', [(600, 0), (1100, 0), (1100, 500), (600, 500)]),
            marker(key='dup', x=200, y=150),
            marker(key='dup', x=800, y=150)))
        self.assertEqual(len(result.devices), 1)
        joined = '\n'.join(result.errors)
        self.assertIn('dup', joined)
        self.assertIn('Den', joined)
        self.assertIn('Hall', joined)

    def test_marker_outside_every_room_errors(self):
        result = self.convert_den(marker(key='stray', x=900, y=900))
        self.assertEqual(result.devices, [])
        self.assertIn('stray', result.errors[0])
        self.assertIn('not in any room', result.errors[0])

    def test_marker_on_a_room_edge_is_assigned(self):
        # Pins land on walls — HOUSE-PLAN.md tells the family to put them
        # there — and even-odd containment is ambiguous exactly on the
        # boundary. Same 0.05 m allowance as the loader's _pinEps.
        on_edge = self.convert_den(marker(x=500, y=250))
        self.assertEqual(on_edge.errors, [])
        self.assertEqual(on_edge.devices[0]['room'], 'den')

        just_past = self.convert_den(marker(x=506, y=250))
        self.assertTrue(any('not in any room' in e for e in just_past.errors),
                        just_past.errors)

    def test_ordinary_furniture_is_ignored_and_emits_no_devices_key(self):
        # The safety property: a drawing full of beds converts exactly as
        # it did before markers existed.
        result = self.convert_den(
            '<pieceOfFurniture name="Bed" catalogId="eTeks#bed"'
            ' x="200" y="150"/>',
            '<doorOrWindow name="Door" catalogId="eTeks#door" x="0" y="250"/>')
        self.assertEqual(result.errors, [])
        self.assertEqual(result.devices, [])
        self.assertNotIn(
            'devices:', emit_yaml(result.name, result.floors, 'x',
                                  result.devices))

    def test_the_real_marker_fixture_round_trips(self):
        # Not synthetic XML: a drawing Sweet Home 3D saved, with a key
        # typed into its Other properties dialog.
        result = convert(
            ET.parse(FIXTURES / 'marker-props.Home.xml').getroot())
        self.assertEqual(result.errors, [])
        self.assertEqual(
            [(d['key'], d['kind'], d['room']) for d in result.devices],
            [('light_kitchen_1', 'light', 'kitchen'),
             ('camera_kitchen_1', 'camera', 'kitchen'),
             ('thermostat_hall_1', 'thermostat', 'hall')])

    def test_a_house_drawn_off_origin_pins_every_device_identically(self):
        """The min-shift has to reach markers too, or a house drawn away
        from the origin would pin every Device in the wrong place — and the
        wild norm is negative coordinates, not a tidy (0,0) corner."""
        def converted(fixture):
            result = convert(
                ET.parse(FIXTURES / fixture).getroot(), 'Demo House')
            self.assertEqual(result.errors, [], fixture)
            return result

        # negative-origin is the placeholder moved by (-300, -200) cm and
        # nothing else, markers included.
        here = converted('placeholder-house.Home.xml')
        moved = converted('negative-origin.Home.xml')
        self.assertEqual(len(here.devices), 33)
        self.assertEqual(here.devices, moved.devices)
        self.assertNotEqual(here.origin, moved.origin)
        # Not just the Devices: the entire emitted House Plan.
        self.assertEqual(emit_yaml(here.name, here.floors, 'f', here.devices),
                         emit_yaml(moved.name, moved.floors, 'f',
                                   moved.devices))


class Vocabulary(unittest.TestCase):

    def test_device_kinds_match_the_loader_exactly(self):
        """Drift here is silent: a kind the converter accepts and the
        loader rejects produces a House Plan that fails at Panel boot,
        pointing at generated YAML nobody wrote by hand."""
        loader = re.findall(r"'([a-z0-9-]+)' => DeviceKind\.",
                            LOADER.read_text())
        self.assertTrue(loader, 'could not read _kind() out of the loader')
        self.assertEqual(list(DEVICE_KINDS), loader)


class Adapter(unittest.TestCase):
    """The one case that needs the shell: errors must reach the exit code
    without leaving a half-converted House Plan behind."""

    def test_nothing_written_on_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = pathlib.Path(tmp, 'house.yaml')
            run = subprocess.run(
                [sys.executable, str(TOOL / 'sh3d_to_yaml.py'),
                 str(FIXTURES / 'AlpsHotel.Home.xml'), '-o', str(out)],
                capture_output=True, text=True)
            self.assertEqual(run.returncode, 1)
            self.assertIn('nothing written', run.stderr)
            self.assertFalse(out.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
