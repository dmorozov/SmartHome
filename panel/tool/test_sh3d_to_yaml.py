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
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, str(pathlib.Path(__file__).parent))

from sh3d_to_yaml import bbox, convert, emit_yaml  # noqa: E402

TOOL = pathlib.Path(__file__).parent
FIXTURES = TOOL / 'fixtures'
PLACEHOLDER = 'tool/fixtures/placeholder-house.Home.xml'
SHIPPED = TOOL.parent / 'assets' / 'house' / 'house.yaml'


def home(*body, name='Test House'):
    """A Home.xml with no levels — one implicit Ground Floor. Sweet Home 3D
    stores centimeters, so callers write cm and expect meters back."""
    return ET.fromstring(f'<home name="{name}">{"".join(body)}</home>')


def room(name, pts):
    points = ''.join(f'<point x="{x}" y="{y}"/>' for x, y in pts)
    return f'<room name="{name}">{points}</room>'


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
            emit_yaml(self.result.name, self.result.floors, PLACEHOLDER),
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
        # Room ids are slugified names and devices.yaml references them, so
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
