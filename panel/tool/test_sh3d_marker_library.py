#!/usr/bin/env python3
"""Tests for the Sweet Home 3D marker library (phase 0, E6b).

    cd panel && python3 tool/test_sh3d_marker_library.py

Two kinds of test, for the two ways this file can rot.

**Drift.** The library's kind list must stay equal to the Panel's Device
vocabulary. Nothing else notices when they diverge: a
marker with a kind the loader rejects looks perfectly fine in Sweet Home
3D and fails much later, in the Panel, with a stack trace pointing at
YAML nobody hand-wrote. So the table itself is read here and compared,
rather than a copy of it being trusted.

**Sweet Home 3D's parser.** Every rule below was read out of the 7.5
sources, and each is a rule the application enforces silently — a
mis-escaped colon or a gap in the index sequence does not raise anything,
it just makes markers vanish from the catalog. `_additional_properties`
replays `DefaultFurnitureCatalog.getCatalogAdditionalProperties` so a
regression shows up here instead of in the furniture browser.
"""

import pathlib
import re
import struct
import sys
import tempfile
import unittest
import zipfile
import zlib

sys.path.insert(0, str(pathlib.Path(__file__).parent))

from sh3d_marker_library import (  # noqa: E402
    CATEGORY, CREATOR, KINDS, build, catalog_properties)

TOOL = pathlib.Path(__file__).parent
VOCABULARY = TOOL.parent / 'lib' / 'domain' / 'device_vocabulary.dart'

# `readPieceOfFurniture` reads these with `resource.getString`, so a missing
# one is a MissingResourceException, not a default.
MANDATORY = ('name', 'category', 'icon', 'model',
             'width', 'depth', 'height', 'movable', 'doorOrWindow')

# `DefaultFurnitureCatalog.PropertyKey` — a `<name>#<index>` key counts as an
# additional property only when its name is *not* one of these.
DEFAULT_PROPERTIES = {
    'id', 'name', 'description', 'information', 'license', 'tags',
    'creationDate', 'grade', 'category', 'icon', 'iconDigest', 'planIcon',
    'planIconDigest', 'model', 'modelSize', 'modelDigest', 'multiPartModel',
    'width', 'depth', 'height', 'movable', 'doorOrWindow',
    'staircaseCutOutShape', 'elevation', 'dropOnTopElevation',
    'modelRotation', 'modelFlags', 'creator', 'resizable', 'deformable',
    'texturable', 'horizontallyRotatable', 'price',
    'valueAddedTaxPercentage', 'currency',
}


def java_properties(text):
    """`java.util.Properties` key/value splitting, which is not `=`-splitting:
    the separator is the first unescaped `=` or `:`, so a key containing a
    colon must escape it. That escape is the whole reason this helper
    exists — `kind#1:STRING` unescaped would silently become key `kind#1`
    with value `STRING=light`, and the type would be lost."""
    props = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith(('#', '!')):
            continue
        key, escaped = '', False
        for i, char in enumerate(line):
            if escaped:
                key += char
                escaped = False
            elif char == '\\':
                escaped = True
            elif char in '=:':
                props[key] = line[i + 1:]
                break
            else:
                key += char
        else:
            props[key] = ''
    return props


def _additional_properties(props):
    """`DefaultFurnitureCatalog.getCatalogAdditionalProperties`, line for
    line: split on the *last* `#`, read the piece index up to an optional
    `:`, keep the name when it is not a default property, and read the type
    after the colon. Returns {index: {name: (type, value)}}."""
    found = {}
    for key, value in props.items():
        sharp = key.rfind('#')
        if sharp == -1 or sharp + 1 >= len(key):
            continue
        colon = key.find(':', sharp + 1)
        try:
            index = int(key[sharp + 1: colon if colon != -1 else len(key)].strip())
        except ValueError:
            continue  # not a key that matches a piece of furniture
        name = key[:sharp]
        if name in DEFAULT_PROPERTIES:
            continue
        found.setdefault(index, {})[name] = (
            key[colon + 1:] if colon > 0 else None, value)
    return found


class KindVocabulary(unittest.TestCase):
    def test_matches_the_panels_vocabulary_exactly(self):
        """The one test that catches a real future mistake: adding a kind to
        the Panel and forgetting the catalog, or the reverse."""
        panel = re.findall(r"slug: '([a-z0-9-]+)'", VOCABULARY.read_text())
        self.assertTrue(panel, 'could not read the slugs out of the table')
        # Membership, not order: catalog order is how the markers appear in
        # Sweet Home 3D's browser, a cosmetic choice. A kind on one side
        # and not the other is what breaks.
        self.assertEqual({slug for slug, _, _ in KINDS}, set(panel))

    def test_slugs_are_unique_and_kebab_case(self):
        slugs = [slug for slug, _, _ in KINDS]
        self.assertEqual(len(slugs), len(set(slugs)))
        for slug in slugs:
            self.assertRegex(slug, r'^[a-z0-9]+(-[a-z0-9]+)*$')


class CatalogParsing(unittest.TestCase):
    def setUp(self):
        self.props = java_properties(catalog_properties())
        self.extra = _additional_properties(self.props)

    def test_every_marker_declares_placementKey_and_kind(self):
        self.assertEqual(sorted(self.extra), list(range(1, len(KINDS) + 1)))
        for index, (slug, _, _) in enumerate(KINDS, start=1):
            self.assertEqual(
                self.extra[index],
                {'placementKey': ('STRING', ''), 'kind': ('STRING', slug)},
                msg=f'entry {index} ({slug})')

    def test_the_colon_in_a_typed_key_survives_escaping(self):
        """Without the `\\:` escape the type is swallowed into the value.
        Asserted directly, because the failure is invisible in the app."""
        self.assertIn('placementKey#1\\:STRING=', catalog_properties())
        self.assertIn('placementKey#1:STRING', self.props)
        self.assertNotIn('placementKey#1', self.props)

    def test_mandatory_keys_present_for_every_entry(self):
        missing = [f'{key}#{i}'
                   for i in range(1, len(KINDS) + 1)
                   for key in MANDATORY
                   if f'{key}#{i}' not in self.props]
        self.assertEqual(missing, [])

    def test_indexes_are_contiguous_and_stop(self):
        """`readFurniture` stops at the first absent `name#`, so a gap
        silently truncates the catalog rather than skipping one marker."""
        for i in range(1, len(KINDS) + 1):
            self.assertIn(f'name#{i}', self.props)
        self.assertNotIn(f'name#{len(KINDS) + 1}', self.props)

    def test_catalog_ids_identify_a_marker(self):
        """Phase 1 recognises a Device marker by its catalogId, which is how
        an ordinary bed can never be mistaken for one."""
        for index, (slug, _, _) in enumerate(KINDS, start=1):
            self.assertEqual(self.props[f'id#{index}'], f'{CREATOR}#{slug}')
            self.assertEqual(self.props[f'category#{index}'], CATEGORY)
            self.assertEqual(self.props[f'creator#{index}'], CREATOR)


class Archive(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.zip = zipfile.ZipFile(build(pathlib.Path(tmp.name, 'M.sh3f')))

    def test_content_paths_resolve_inside_the_archive(self):
        """`getContent` builds `jar:<sh3f>!<value>`, so every icon#/model#
        must name a real entry and must be archive-absolute."""
        props = java_properties(
            self.zip.read('PluginFurnitureCatalog.properties').decode())
        names = set(self.zip.namelist())
        for index in range(1, len(KINDS) + 1):
            for key in ('icon', 'model'):
                value = props[f'{key}#{index}']
                self.assertTrue(value.startswith('/'), msg=value)
                self.assertIn(value.lstrip('/'), names)

    def test_icons_are_valid_png(self):
        for slug, _, _ in KINDS:
            png = self.zip.read(f'resources/{slug}.png')
            self.assertEqual(png[:8], b'\x89PNG\r\n\x1a\n', msg=slug)
            width, height, depth, colour = struct.unpack('>IIBB', png[16:26])
            self.assertEqual((depth, colour), (8, 2), msg=slug)
            start = png.index(b'IDAT') + 4
            length = struct.unpack('>I', png[start - 8:start - 4])[0]
            raw = zlib.decompress(png[start:start + length])
            self.assertEqual(len(raw), height * (1 + width * 3), msg=slug)

    def test_icons_differ_between_kinds(self):
        icons = {self.zip.read(f'resources/{slug}.png') for slug, _, _ in KINDS}
        self.assertEqual(len(icons), len(KINDS))

    def test_the_model_is_a_closed_obj(self):
        obj = self.zip.read('resources/marker.obj').decode()
        self.assertEqual(len(re.findall(r'^v ', obj, re.M)), 8)
        faces = re.findall(r'^f (.+)$', obj, re.M)
        self.assertEqual(len(faces), 6)
        # Every vertex used, each on exactly three faces: a closed box.
        used = [int(i) for face in faces for i in face.split()]
        self.assertEqual(sorted(used), sorted(list(range(1, 9)) * 3))


if __name__ == '__main__':
    unittest.main(verbosity=2)
