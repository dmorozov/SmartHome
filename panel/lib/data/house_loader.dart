import 'dart:math' as math;
import 'dart:ui';

import 'package:yaml/yaml.dart';

import '../domain/house.dart';
import 'bindings_parser.dart';

/// A pin sitting exactly on its Room's edge is legal — HOUSE-PLAN.md tells
/// the family to place TVs and thermostats against a wall — and even-odd
/// point-in-polygon is ambiguous exactly on the boundary. Meters: generous
/// against a typed coordinate, tiny against room scale.
const _pinEps = 0.05;

/// Builds the [House] from the two House Plan files (ADR-0004, reshaped by
/// ADR-0005): `house.yaml` — converter-generated, never hand-edited, and
/// now carrying the Placements read out of the drawing as well as the
/// geometry — joined with `bindings.yaml`, the one remaining hand-
/// maintained file, which says only which Hub entity each Key binds to and
/// whether the Device is Local or Cloud. Throws [FormatException] with an
/// actionable message on mismatch.
///
/// The join is on the **Key**: the author types it once in Sweet Home 3D,
/// and it becomes [Device.id], so everything downstream — the states map,
/// toggles, pin widget keys, logs — keys on it exactly as it did when ids
/// were hand-written. That is why this cutover stops at this file.
///
/// The returned [House] carries the full House Plan guarantee the Dollhouse
/// assumes: every Room footprint is a closed rectilinear polygon (>= 3
/// corners, axis-aligned edges), every Wall is axis-aligned and non-
/// degenerate, Room and Floor ids are unique across the house, and every
/// Device references an existing Room with its position inside (or within
/// [_pinEps] of the edge of) that Room's footprint. Geometry the converter
/// would reject therefore also dies here — the hand-written-YAML escape
/// hatch (ADR-0004) gets the same enforcement, instead of surfacing as
/// silent paint-time garbage two modules downstream. The converter now
/// computes Room membership rather than a person typing it, so [_checkPin]
/// passes by construction; it stays as the backstop for a mangled file.
House loadHouse({required String houseYaml, required String bindingsYaml}) {
  // Through [readYaml] rather than `loadYaml` for the reason its docstring
  // gives, and for house.yaml too: it is generated, but a hand-edit is the
  // escape hatch ADR-0004 kept, and the parser's exception prints the line it
  // choked on whichever file that line came from.
  final houseDoc = readYaml(houseYaml, file: 'house.yaml');
  final bindings = parseBindings(bindingsYaml);

  final devicesByRoom = <String, List<Device>>{};
  // How the orphan check below will name each Room a Device claims to sit in.
  // Built here, at the *reference*, and not down at the Rooms themselves,
  // because the Room this has to name is the one that does not exist — there
  // is no entry to count to, so the Device that names it is the only position
  // a reader can walk to.
  final roomRefs = <String, String>{};
  // Keyed by Device key and Room id — both unique, enforced below — so the
  // pin check at the end can name an entry it no longer has a position for.
  // Rejected: re-deriving the labels from the built [Floor]s, which recomputes
  // the ordinals and gets them wrong the moment a Device is grouped into a
  // Room whose order differs from `devices:`.
  final deviceLabels = <String, String>{};
  final roomLabels = <String, String>{};
  final seenKeys = <String>{};
  // Bindings are consumed as Placements claim them; whatever is left over
  // is a binding for a Device that no longer exists in the drawing.
  final unclaimed = bindings.keys.toSet();
  // Absent `devices:` is not an error — it is a house.yaml generated before
  // markers existed. It loads as a house with no Devices, which the
  // `house.loaded … devices=0` log makes obvious.
  final placements = (houseDoc['devices'] as YamlList?) ?? YamlList();
  for (var i = 0; i < placements.length; i++) {
    final p = placements[i];
    final key = p['key'] as String;
    final device =
        _label('Device', key, 'the ${ordinalWord(i + 1)} entry under devices:');
    if (!seenKeys.add(key)) {
      throw FormatException(
          'house.yaml: $device repeats a Device key already used — the '
          'converter rejects duplicate keys, so regenerate rather than '
          'editing house.yaml');
    }
    final binding = bindings[key];
    if (binding == null) {
      throw FormatException(
          'bindings.yaml: no entry for $device — add one; '
          'connectivity alone is enough until the hardware exists');
    }
    unclaimed.remove(key);
    deviceLabels[key] = device;
    // Hoisted out of the constructor because the stream check needs it: the
    // parser can say a stream name is well-shaped, but only here is the
    // Device's kind known, and "may this Device play video at all" is a
    // question about the kind.
    final kind = _kind(p['kind'] as String, device);
    _checkStream(binding, kind);
    final placed = Device(
      id: key,
      name: p['name'] as String,
      kind: kind,
      connectivity: binding.connectivity,
      position: _point(p['position'], 'the position: on $device'),
      entityId: binding.entityId,
      streamName: binding.streamName,
      substream: binding.substream,
      talkStream: binding.talkStream,
      snapshotEntityId: binding.snapshotEntity,
    );
    final room = p['room'] as String;
    roomRefs.putIfAbsent(
        room, () => _label('room', room, 'the room: on $device'));
    devicesByRoom.putIfAbsent(room, () => []).add(placed);
  }
  if (unclaimed.isNotEmpty) {
    // Through [ParsedBinding.label], not the keys themselves. This line was
    // measured publishing a password: a paste that lands one column to the
    // left makes the whole camera URL the key, the key matches no Placement,
    // and this is the complaint it earns —
    // `bindings.yaml binds rtsp://admin:hunter2@…, which no longer exist`.
    // Pre-existing, and it is the only one of these messages the doctrine in
    // bindings_parser.dart did not already cover.
    final stale = [
      for (final key in unclaimed.toList()..sort()) bindings[key]!.label,
    ];
    // "still has X, and house.yaml no longer does" rather than "binds X,
    // which no longer exists": the label may be a position rather than a
    // name, and "binds the 2nd binding" reads as a bug in the message.
    throw FormatException(
        'bindings.yaml still has ${stale.join(", ")}, and house.yaml no '
        'longer does — marker deleted from the drawing? Delete the '
        'binding(s) too, or put the marker back and re-run the converter.');
  }

  final roomIds = <String>{};
  final floorIds = <String>{};
  final storeys = houseDoc['floors'] as YamlList;
  final floors = <Floor>[];
  for (var fi = 0; fi < storeys.length; fi++) {
    final f = storeys[fi];
    final floorId = f['id'] as String;
    final floor = _label(
        'floor', floorId, 'the ${ordinalWord(fi + 1)} entry under floors:');
    if (!floorIds.add(floorId)) {
      throw FormatException(
          'house.yaml: $floor repeats a floor id already used — floor ids '
          'must be unique across the whole house');
    }
    final roomEntries = f['rooms'] as YamlList;
    final rooms = <Room>[];
    for (var ri = 0; ri < roomEntries.length; ri++) {
      final r = roomEntries[ri];
      final id = r['id'] as String;
      final room = _label(
          'room', id, 'the ${ordinalWord(ri + 1)} room under $floor');
      if (!roomIds.add(id)) {
        throw FormatException(
            'house.yaml: $room repeats a room id already used — room ids must '
            'be unique across the whole house (Device markers reference '
            'them)');
      }
      roomLabels[id] = room;
      final corners = r['footprint'] as YamlList;
      final footprint = [
        for (var ci = 0; ci < corners.length; ci++)
          _point(corners[ci],
              'the ${ordinalWord(ci + 1)} footprint corner of $room'),
      ];
      _checkFootprint(room, footprint);
      rooms.add(Room(
        id: id,
        name: r['name'] as String,
        footprint: footprint,
        devices: devicesByRoom[id] ?? const [],
      ));
    }
    final wallEntries = (f['walls'] as YamlList?) ?? YamlList();
    final walls = <Wall>[];
    for (var wi = 0; wi < wallEntries.length; wi++) {
      final w = wallEntries[wi];
      final where = 'the ${ordinalWord(wi + 1)} wall under $floor';
      final wall = Wall(_point(w[0], 'the first end of $where'),
          _point(w[1], 'the second end of $where'));
      _checkWall(floor, wall);
      walls.add(wall);
    }
    floors.add(Floor(
      id: floorId,
      name: f['name'] as String,
      level: f['level'] as int,
      rooms: rooms,
      walls: walls,
    ));
  }

  final orphaned = devicesByRoom.keys.where((r) => !roomIds.contains(r));
  if (orphaned.isNotEmpty) {
    throw FormatException(
        'house.yaml: Device(s) name a room that does not exist: '
        '${orphaned.map((r) => roomRefs[r]!).join(", ")} — the converter '
        'computes Room membership, so this file was hand-edited or '
        'truncated; regenerate it.');
  }
  for (final floor in floors) {
    for (final room in floor.rooms) {
      for (final device in room.devices) {
        _checkPin(room, device, roomLabels[room.id]!,
            deviceLabels[device.id]!);
      }
    }
  }

  return House(name: houseDoc['name'] as String, floors: floors);
}

// ── House Plan geometry (house.yaml) ────────────────────────────────────

/// Rectilinear polygon, at least a triangle's worth of corners. Everything
/// downstream splits an edge into horizontal-or-vertical with no third case
/// (`Floor.outline`, `Wall.horizontal`), so a diagonal does not fail — it
/// draws wrong.
///
/// Takes the Room's [_label], not its id: the message is logged, and the id
/// is hand-editable text. The *coordinates* are printed in full and that is
/// deliberate — they came through [_point], which admits nothing but numbers,
/// and a pair of numbers is the one locator in this file that cannot be a
/// pasted URL. They are also what a reader greps for.
void _checkFootprint(String room, List<Offset> footprint) {
  if (footprint.length < 3) {
    throw FormatException(
        'house.yaml: $room footprint has fewer than 3 corners');
  }
  for (var i = 0; i < footprint.length; i++) {
    final a = footprint[i];
    final b = footprint[(i + 1) % footprint.length];
    if (a.dx != b.dx && a.dy != b.dy) {
      throw FormatException(
          'house.yaml: $room footprint edge (${_xy(a)})→(${_xy(b)}) '
          'is diagonal — right angles only (ADR-0004); regenerate with the '
          'converter, or fix the hand-written coordinates');
    }
  }
}

/// Axis-aligned and going somewhere. A zero-length Wall projects to a point
/// and a diagonal one to a skewed quad shaded as if it ran east–west.
///
/// [floor] is the Floor's [_label], for [_checkFootprint]'s reason.
void _checkWall(String floor, Wall wall) {
  final (a, b) = (wall.a, wall.b);
  if (a == b) {
    throw FormatException(
        'house.yaml: wall (${_xy(a)})→(${_xy(b)}) on $floor has zero length');
  }
  if (a.dx != b.dx && a.dy != b.dy) {
    throw FormatException(
        'house.yaml: wall (${_xy(a)})→(${_xy(b)}) on $floor is '
        'diagonal — right angles only (ADR-0004)');
  }
}

// ── Devices against the House Plan (Placements × bindings.yaml) ────────

/// A Device pins to a point in its own Room. The converter computes both
/// the Room and the position from one marker in the drawing, so they can no
/// longer disagree — this is the backstop for a `house.yaml` that was
/// hand-edited or truncated, which is the escape hatch ADR-0004 kept and
/// therefore the case that still needs guarding.
void _checkPin(Room shape, Device device, String room, String label) {
  if (shape.contains(device.position)) return;
  for (var i = 0; i < shape.footprint.length; i++) {
    final a = shape.footprint[i];
    final b = shape.footprint[(i + 1) % shape.footprint.length];
    if (_segmentDistance(a, b, device.position) <= _pinEps) return;
  }
  throw FormatException(
      'house.yaml: $label position [${_xy(device.position)}] '
      'is not inside $room — the converter computes membership '
      'from the drawing, so this file was hand-edited or truncated; '
      'regenerate it');
}

/// Only a camera or a doorbell shows a live view, so a `stream:` on
/// anything else is a hand-written line nothing will ever read — the
/// identical failure to the unclaimed-binding check above, and fatal for
/// the identical reason. "An honest unknown beats a confident wrong answer"
/// governs live *state*; this is configuration, and the person who typed it
/// believes a camera feed is wired up. Rejected: ignoring it, or warning —
/// the wall is unattended (ADR-0001), so a warning here is a sentence
/// nobody ever reads, and the author keeps their wrong belief.
///
/// Names neither the binding's key nor the stream name. The key goes through
/// [ParsedBinding.label] like every message in `bindings_parser.dart`. The
/// *name* is withheld here and only here, and the asymmetry is the point: a
/// stream on a light is refused, so this name never reaches
/// `cameras.popup_open` and this message is the one and only place it could be
/// published — while a name on a real camera is logged on every Popup and has
/// to be (see `_streamName` in bindings_parser.dart, which states that
/// residual and why it is accepted). Withholding it costs nothing: the reader
/// has the file open at the line, and "delete the stream: line" needs no
/// value to act on.
void _checkStream(ParsedBinding binding, DeviceKind kind) {
  // Narrower than the video test below, because two-way audio is narrower:
  // a camera plays video and a doorbell plays video, but only a doorbell has
  // a speaker at the other end. `_PushToTalkButton` is gated on exactly this
  // kind, so a `talk:` on a camera would be a name nothing ever posts.
  if (kind != DeviceKind.doorbell && binding.talkStream != null) {
    throw FormatException(
        'bindings.yaml: ${binding.label} is a ${specOf(kind).slug} and has a '
        'talk: — only a doorbell has a speaker to talk out of, so nothing '
        'would ever push to it; delete the line, or fix the marker\'s kind in '
        'the drawing and re-run the converter. The name is not echoed, for '
        "the stream: message's reason below.");
  }
  // A substream with no stream is a tile that plays a small picture and a
  // Popup that plays nothing — every time, silently, on a Device that looks
  // wired. Refused here rather than tolerated, because the two lines sit
  // together and deleting the wrong one is the likely typo.
  //
  // Gated on the kind so that a `substream:` on a *light* is answered by the
  // video rule below and not by this one: "a light cannot play video" is the
  // author's actual mistake, and "add a stream:" would be advice towards a
  // second line that is equally refused.
  if (specOf(kind).video &&
      binding.substream != null &&
      binding.streamName == null) {
    throw FormatException(
        'bindings.yaml: ${binding.label} has a substream: and no stream: — '
        'the substream is what a *tile* plays, and the Popup would still have '
        'nothing to open. Add the stream:, or delete the substream:. Neither '
        'name is echoed, for the stream: message\'s reason below.');
  }
  if (specOf(kind).video) return;
  if (binding.substream != null) {
    throw FormatException(
        'bindings.yaml: ${binding.label} is a ${specOf(kind).slug} and has a '
        'substream: — only a camera or a doorbell plays video, so nothing '
        'would ever play it; delete the line, or fix the marker\'s kind in '
        'the drawing and re-run the converter. The name is not echoed, for '
        "the stream: message's reason below.");
  }
  if (binding.streamName != null) {
    throw FormatException(
        'bindings.yaml: ${binding.label} is a ${specOf(kind).slug} and has a '
        'stream: — only a camera or a doorbell plays video, so nothing would '
        'ever play it; delete the line, or fix the marker\'s kind in the '
        'drawing and re-run the converter. The name is not echoed: nothing '
        'else in the Panel ever saw it, and a bare API token typed where a '
        'name goes has the shape of a legal name.');
  }
  if (binding.snapshotEntity != null) {
    // The same wrong-belief failure as a stream on a light, refused for the
    // same reason. The value is withheld for symmetry with the stream
    // message even though it passed the parser's camera-entity rule: two
    // messages in one function with two disclosure policies is how the
    // narrower one gets widened in a refactor.
    throw FormatException(
        'bindings.yaml: ${binding.label} is a ${specOf(kind).slug} and has a '
        'snapshot: — only a camera or a doorbell wears a still-image face, '
        'so nothing would ever fetch it; delete the line, or fix the '
        'marker\'s kind in the drawing and re-run the converter.');
  }
}

/// Distance from [p] to segment [a]–[b]. Exact for the axis-aligned
/// segments [_checkFootprint] guarantees: clamping into the segment's box
/// lands on the segment itself.
double _segmentDistance(Offset a, Offset b, Offset p) {
  final x = p.dx.clamp(math.min(a.dx, b.dx), math.max(a.dx, b.dx)).toDouble();
  final y = p.dy.clamp(math.min(a.dy, b.dy), math.max(a.dy, b.dy)).toDouble();
  return (p - Offset(x, y)).distance;
}

/// The slug list lives in the Device vocabulary; this only owns the error,
/// because only this caller knows the slug came from a generated file.
///
/// The rejected slug is held to [isQuiet] like every other hand-editable value
/// here, rather than named through [_label]: a slug has no position of its own
/// to fall back to — it is one field of a Device the message has already named
/// — so the fallback is to say nothing about it.
///
/// A typo is exactly the case where echoing it is worth something: `camara`
/// beside the list of real slugs is the whole diagnosis. What is withheld is
/// the other thing that lands on a `kind:` line, a paste that missed the field
/// above it, and that one is a camera URL. This cannot lean on the value
/// having been validated the way an accepted slug could — it is here
/// *because* it failed validation, so `unknown` buys no guarantee at all.
DeviceKind _kind(String slug, String device) =>
    kindFromSlug(slug) ??
    (throw FormatException(
        'house.yaml: $device has an unknown kind — one of: '
        '${deviceKindSlugs.join(", ")}; the value is '
        '${isQuiet(slug) ? '"$slug"' : 'not echoed here, because an unknown '
            'kind is arbitrary text and this complaint is logged — open '
            'house.yaml at that Device and read the line'}. The converter '
        'validates kinds, so regenerate rather than hand-edit'));

/// A `[x, y]` pair, or a complaint that says where to look and nothing about
/// what it found.
///
/// The value used to be echoed (`got: $pair`), which made this the widest of
/// the thirteen: [what] is a whole sub-tree of house.yaml — a device position,
/// a footprint corner, a wall end — and YAML hands over whatever is on the
/// line, so a `position:` that a paste turned into a scalar printed the paste.
/// The runtime type stays: `YamlMap` versus `String` is what tells a reader
/// they typed a block where a pair goes, and a type name is not author text.
///
/// The number check is here rather than left to the casts below for the same
/// reason the collection check is: `(pair[0] as num)` throws a bare
/// `_TypeError` that names two types and no file, which is the breach `_text`
/// in bindings_parser.dart was written to close one file over. It leaks nothing
/// — Dart's cast error carries types only — but it is not a message anybody
/// can act on, and `boot.dart` promises these are all built to be logged.
Offset _point(dynamic pair, String what) {
  if (pair is! YamlList || pair.length != 2) {
    throw FormatException(
        'house.yaml: $what must be a [x, y] pair and this is not one (YAML '
        'read it as a ${pair.runtimeType}). The value is not echoed here: '
        'this complaint is logged, and a mis-paste lands on exactly this kind '
        'of line — open house.yaml and read it.');
  }
  if (pair[0] is! num || pair[1] is! num) {
    throw FormatException(
        'house.yaml: $what must be two numbers, and YAML read these as '
        '${pair[0].runtimeType} and ${pair[1].runtimeType} — quote nothing, '
        'measure in metres: [4, 3.5]. The values are not echoed here, for the '
        'reason the message above gives.');
  }
  return Offset((pair[0] as num).toDouble(), (pair[1] as num).toDouble());
}

/// How a logged complaint names one entry in `house.yaml`: `room "den"` when
/// the value cannot be hiding a credential, and [position] — where the entry
/// sits in the file — when it can.
///
/// The leak this closes, and it is `bindingLabel`'s twin. That function was
/// added after a mis-paste in **bindings.yaml** was measured publishing a
/// camera password through a key; the thirteen `FormatException`s in this file
/// are the same accident in the other House Plan file, and they were left
/// printing raw. Measured through the real `bootPanel`:
///
///     E house.invalid error="FormatException: house.yaml: duplicate room id
///     \"rtsp://admin:hunter2@192.168.68.44/live\" — …"
///
/// house.yaml is generated, which is not a defence: this file says four
/// separate times that a hand-edit is the escape hatch ADR-0004 kept, and
/// every check below exists *for* the hand-edited file. A generated file never
/// reaches any of these messages at all.
///
/// [isQuiet] rather than a second predicate of this file's own — see its
/// docstring. Note what that charset buys once a value has passed it: no `:`,
/// `@`, `/` or `?`, so a named id is provably not a URL and not a `user:pass`
/// pair, which is why the everyday `room "den"` keeps its one useful word
/// instead of being withheld along with the paste. Over-redacting here would
/// cost every honest message its greppable term and buy nothing.
///
/// Rejected: truncating a long value, which publishes the start of whatever
/// was pasted — and `rtsp://admin:hunter2@…` puts the password in the first
/// twenty characters.
String _label(String noun, String value, String position) =>
    isQuiet(value) ? '$noun "$value"' : position;

/// `13, 10.6` — a point the way the YAML files write it, whole meters
/// without a trailing `.0`, so the culprit in an error message can be
/// grepped straight back into the file it came from.
String _xy(Offset p) => '${_meters(p.dx)}, ${_meters(p.dy)}';

String _meters(double v) =>
    v.isFinite && v == v.roundToDouble() ? '${v.toInt()}' : '$v';
