import 'package:flutter_test/flutter_test.dart';
import 'package:panel/data/bindings_parser.dart';
import 'package:panel/domain/device_vocabulary.dart';

/// The hand-maintained file's rules, tested where they live rather than
/// only through the loader — the generator reads the same parser, and a
/// rule enforced in one caller and not the other is the failure this
/// module exists to prevent.
void main() {
  test('parses a binding with an entity', () {
    final bindings = parseBindings('''
bindings:
  light-den:
    entity: input_boolean.light_den
    connectivity: local
''');
    final binding = bindings['light-den']!;
    expect(binding.key, 'light-den');
    expect(binding.entityId, 'input_boolean.light_den');
    expect(binding.connectivity, Connectivity.local);
  });

  test('an entity-less binding is legal — hardware still in its box', () {
    final binding = parseBindings('''
bindings:
  future-camera:
    connectivity: cloud
''')['future-camera']!;
    expect(binding.entityId, isNull);
    expect(binding.connectivity, Connectivity.cloud);
  });

  test('a stream names a go2rtc key, not a URL — a scheme would tell go2rtc '
      'to go dial it', () {
    // Measured against the live go2rtc: `?src=rtsp://…` creates the stream
    // and connects to it, so this is not a 404 the server would absorb —
    // it is an outbound connection, with the camera password in the URL and
    // therefore in the log line that names the stream.
    expect(
      () => parseBindings('''
bindings:
  cam-den:
    stream: rtsp://user:hunter2@192.168.1.9/live
    connectivity: cloud
'''),
      _rejects('not a go2rtc stream name'),
    );
  });

  test('a rejected stream is not echoed back — the line that reports it is '
      'logged, and would otherwise publish the camera password', () {
    // boot.dart hands this FormatException to Log.error(error:), and on a
    // fatal boot that line is the only artefact left behind: journald on
    // the appliance, the browser console on web. Refusing a pasted URL must
    // not be the thing that puts its credentials somewhere new.
    const pasted = 'rtsp://admin:hunter2@192.168.68.44/live';
    try {
      parseBindings('''
bindings:
  doorbell:
    stream: $pasted
    connectivity: cloud
''');
      fail('expected a FormatException');
    } on FormatException catch (e) {
      final logged = e.toString();
      for (final part in [pasted, 'hunter2', 'admin', '192.168.68.44']) {
        expect(logged, isNot(contains(part)), reason: 'leaked "$part"');
      }
      // And it is still enough to find the line and fix it by hand.
      expect(logged, contains('bindings.yaml'));
      expect(logged, contains('doorbell'));
      expect(logged, contains('stream'));
      expect(logged, contains('go2rtc.yaml'));
    }
  });

  test('a rejected entity is not echoed back either — the same paste lands '
      'one line above, into the same log', () {
    const pasted = 'rtsp://admin:hunter2@192.168.68.44/live';
    try {
      parseBindings('''
bindings:
  doorbell:
    entity: $pasted
    connectivity: cloud
''');
      fail('expected a FormatException');
    } on FormatException catch (e) {
      final logged = e.toString();
      for (final part in [pasted, 'hunter2', 'admin', '192.168.68.44']) {
        expect(logged, isNot(contains(part)), reason: 'leaked "$part"');
      }
      expect(logged, contains('bindings.yaml'));
      expect(logged, contains('doorbell'));
      expect(logged, contains('entity'));
    }
  });

  test('a stream name may start with an underscore or a dot — those are '
      'legal go2rtc keys, and refusing them refused nothing dangerous', () {
    // The excluded characters — `:`, `/`, `@` — are excluded everywhere, so
    // a first-position rule only cost the reader a message that described
    // their conforming name as malformed.
    for (final name in ['_ring_doorbell', '.hidden-cam', '-cam']) {
      final binding = parseBindings('''
bindings:
  cam-den:
    stream: "$name"
    connectivity: cloud
''')['cam-den']!;
      expect(binding.streamName, name);
    }
  });

  test('a camera with no stream yet is legal — the Popup says unavailable, '
      'the Panel still boots', () {
    final binding = parseBindings('''
bindings:
  cam-den:
    entity: sensor.den_cam
    connectivity: cloud
''')['cam-den']!;
    expect(binding.streamName, isNull);
  });

  test('two Devices may watch one stream: nothing here writes, so nothing '
      'can fight', () {
    // Unlike entities, which are refused: that rule guards against two pins
    // toggling each other. go2rtc multiplexes consumers over one producer,
    // and one camera watched from two rooms is a real house.
    final bindings = parseBindings('''
bindings:
  cam-den:
    stream: front_door
    connectivity: cloud
  cam-hall:
    stream: front_door
    connectivity: cloud
''');
    expect(bindings['cam-den']!.streamName, 'front_door');
    expect(bindings['cam-hall']!.streamName, 'front_door');
  });

  test('a mistyped scalar is a FormatException naming the file, not a type '
      'error', () {
    // `007` is an integer to YAML, and a stream genuinely named 007 is a
    // plausible thing to type. The complaint has to name the file, the key
    // and the fix like every other one here — a bare _TypeError names none
    // of the three.
    try {
      parseBindings('''
bindings:
  cam-den:
    stream: 007
    connectivity: cloud
''');
      fail('expected a FormatException');
    } on FormatException catch (e) {
      expect(e.message, contains('bindings.yaml'));
      expect(e.message, contains('cam-den'));
      expect(e.message, contains('quote it'));
    }
  });

  test('an empty file parses to nothing rather than throwing', () {
    expect(parseBindings('bindings:\n'), isEmpty);
  });

  test('keys are free-form — any spelling the author likes', () {
    // Sweet Home 3D constrains nothing about the Key, so neither do we.
    final bindings = parseBindings('''
bindings:
  light_kitchen_1:
    connectivity: local
  Light-Kitchen-2:
    connectivity: local
''');
    expect(bindings.keys, containsAll(['light_kitchen_1', 'Light-Kitchen-2']));
  });

  test('rejects an entity id that is not domain.object_id', () {
    expect(
      () => parseBindings('''
bindings:
  light-den:
    entity: LightDen
    connectivity: local
'''),
      _rejects('not a Home Assistant entity id'),
    );
  });

  test('rejects two Devices bound to one entity', () {
    // Two pins driving one entity would toggle each other.
    expect(
      () => parseBindings('''
bindings:
  light-den:
    entity: input_boolean.light_den
    connectivity: local
  light-den-again:
    entity: input_boolean.light_den
    connectivity: local
'''),
      _rejects('one entity, one Device'),
    );
  });

  test('demands connectivity, and rejects anything else', () {
    for (final body in ['    connectivity: wifi', '', '    entity: a.b']) {
      expect(
        () => parseBindings('bindings:\n  light-den:\n$body\n'),
        _rejects('(local | cloud)'),
        reason: body.isEmpty ? 'omitted' : body,
      );
    }
  });

  test('every message names the file and the culprit', () {
    // These are read by whoever hand-edited the file, so they have to say
    // which key is wrong, not just that something is. The wrong *value* is
    // not among the things they say — see the connectivity test below.
    try {
      parseBindings('bindings:\n  oven-thing:\n    connectivity: wired\n');
      fail('expected a FormatException');
    } on FormatException catch (e) {
      expect(e.message, contains('bindings.yaml'));
      expect(e.message, contains('oven-thing'));
      expect(e.message, contains('local | cloud'));
    }
  });

  test('a paste that lands in connectivity: is withheld like one that lands '
      'in stream: — they are one line apart', () {
    // This message used to name the value, on the argument that connectivity
    // "is not a field anyone pastes an address into". It sits one line below
    // `stream:` in the same block, and a paste landing one line off is the
    // same accident with the same password in it.
    const pasted = 'rtsp://admin:hunter2@192.168.68.44/live';
    try {
      parseBindings('''
bindings:
  cam-den:
    connectivity: $pasted
''');
      fail('expected a FormatException');
    } on FormatException catch (e) {
      final logged = e.toString();
      for (final part in [pasted, 'hunter2', 'admin', '192.168.68.44']) {
        expect(logged, isNot(contains(part)), reason: 'leaked "$part"');
      }
      expect(logged, contains('bindings.yaml'));
      expect(logged, contains('cam-den'));
      expect(logged, contains('local | cloud'));
    }
  });

  test('a nested block where a value belongs is refused without repeating it '
      'back — go2rtc\'s own config shape is the paste people half-remember',
      () {
    // The leak this closes: a map or a list reached the "quote it" message,
    // which prints the value twice, and that message's own docstring claimed
    // a credential-shaped value could never arrive there. `stream:` taking a
    // nested `url:` is exactly what somebody writes who remembers go2rtc's
    // config rather than this file's.
    const pasted = 'rtsp://admin:hunter2@192.168.68.44/live';
    final nested = {
      'a nested map': '    stream:\n      url: $pasted',
      'a list': '    stream:\n      - $pasted',
      'a nested map under entity:': '    entity:\n      id: $pasted',
    };
    for (final shape in nested.entries) {
      try {
        parseBindings('bindings:\n  cam-den:\n${shape.value}\n'
            '    connectivity: cloud\n');
        fail('expected a FormatException for ${shape.key}');
      } on FormatException catch (e) {
        final logged = e.toString();
        for (final part in [pasted, 'hunter2', 'admin', '192.168.68.44']) {
          expect(logged, isNot(contains(part)),
              reason: '${shape.key} leaked "$part"');
        }
        expect(logged, contains('bindings.yaml'), reason: shape.key);
        expect(logged, contains('cam-den'), reason: shape.key);
      }
    }
  });

  test('a binding with a bare value instead of a block is this file\'s '
      'complaint, not a type error from three modules down', () {
    // `cam-den: something` reached `String.operator[]` and threw a raw
    // _TypeError — "type 'String' is not a subtype of type 'int' of 'index'"
    // — which names neither the file nor the key, the one promise this
    // library's docstring makes to whoever hand-edited it.
    const pasted = 'rtsp://admin:hunter2@192.168.68.44/live';
    try {
      parseBindings('bindings:\n  cam-den: $pasted\n');
      fail('expected a FormatException');
    } on FormatException catch (e) {
      expect(e.toString(), contains('bindings.yaml'));
      expect(e.toString(), contains('cam-den'));
      expect(e.toString(), isNot(contains('hunter2')));
    }
  });

  test('a mis-paste the YAML parser refuses gives a position, not the line it '
      'choked on — the source line is the paste', () {
    // `loadYaml` runs before every check in this file, and the yaml package's
    // exception is a `SourceSpanFormatException`: its `toString()` reproduces
    // the offending source line with a caret under it. `boot.dart` hands this
    // to `Log.error(error:)`, so the *worse* typo published the password and
    // the cleaner one — refused by `_refuses`, above — did not.
    const password = 'hunter2';
    const pasted = 'rtsp://admin:$password@192.168.68.44/live';
    final mispastes = {
      'a duplicated key': 'bindings:\n  cam-den:\n    stream: den_cam\n'
          '    stream: $pasted\n    connectivity: cloud\n',
      'a tab in the indentation':
          'bindings:\n  cam-den:\n\t    stream: $pasted\n',
      'a colon-space inside the pasted URL': 'bindings:\n  cam-den:\n'
          '    stream: rtsp://admin: $password@192.168.68.44/live\n',
      'an undefined alias':
          'bindings:\n  cam-den:\n    stream: *rtsp_admin_${password}_cam\n',
    };

    for (final mispaste in mispastes.entries) {
      try {
        parseBindings(mispaste.value);
        fail('expected a FormatException for ${mispaste.key}');
      } on FormatException catch (e) {
        final logged = e.toString();
        for (final part in [pasted, password, 'admin', '192.168.68.44']) {
          expect(logged, isNot(contains(part)),
              reason: '${mispaste.key} leaked "$part"');
        }
        // Line and column are the useful half and carry no secret.
        expect(logged, contains('bindings.yaml'), reason: mispaste.key);
        expect(logged, contains('line '), reason: mispaste.key);
        expect(logged, contains('column '), reason: mispaste.key);
      }
    }
  });

  test('the parser\'s own sentence survives when it is one of its constants, '
      'because "Duplicate mapping key" is what the reader came for', () {
    try {
      parseBindings('bindings:\n  cam-den:\n    stream: a\n    stream: b\n');
      fail('expected a FormatException');
    } on FormatException catch (e) {
      expect(e.toString(), contains('Duplicate mapping key'));
    }
  });

  test('the one yaml message that interpolates author text is withheld, so a '
      'tag cannot smuggle a value out through the parser\'s wording', () {
    // `Undefined tag: <tag>` is the only message in the yaml package built
    // from the document rather than from a constant, and a YAML verbatim tag
    // is an arbitrary URI. It joins with ": ", which is the test the filter
    // applies.
    try {
      parseBindings('bindings:\n  cam-den:\n    stream: !!hunter2 x\n'
          '    connectivity: local\n');
      fail('expected a FormatException');
    } on FormatException catch (e) {
      expect(e.toString(), isNot(contains('hunter2')));
      expect(e.toString(), contains('line '));
    }
  });

  test('a paste that lands on the key line is withheld like one that lands on '
      'a value: a key is hand-typed too', () {
    // The line that contradicted its own promise, measured on shipped code:
    //   the stream: under "rtsp://admin:hunter2@cam/live" is not a go2rtc
    //   stream name … The value is not echoed here …
    // One column of indent is the whole difference between a pasted URL
    // becoming a value and becoming a key.
    const pasted = 'rtsp://admin:hunter2@192.168.68.44/live';
    final cases = {
      'a refused stream under it': 'bindings:\n  $pasted:\n'
          '    stream: rtsp://x\n    connectivity: cloud\n',
      'a refused entity under it':
          'bindings:\n  $pasted:\n    entity: NotAnId\n    connectivity: cloud\n',
      'no connectivity under it': 'bindings:\n  $pasted:\n    entity: a.b\n',
      'a refused connectivity under it':
          'bindings:\n  $pasted:\n    connectivity: wired\n',
      'a scalar instead of a block': 'bindings:\n  $pasted: cloud\n',
      'a number where text belongs':
          'bindings:\n  $pasted:\n    stream: 007\n    connectivity: cloud\n',
      'a second Device on the same entity': 'bindings:\n  $pasted:\n'
          '    entity: a.b\n    connectivity: cloud\n'
          '  cam-hall:\n    entity: a.b\n    connectivity: cloud\n',
    };

    for (final shape in cases.entries) {
      try {
        parseBindings(shape.value);
        fail('expected a FormatException for ${shape.key}');
      } on FormatException catch (e) {
        final logged = e.toString();
        for (final part in [pasted, 'hunter2', 'admin', '192.168.68.44']) {
          expect(logged, isNot(contains(part)),
              reason: '${shape.key} leaked "$part"');
        }
        // Placed instead of named, so the reader can still count down to it.
        expect(logged, contains('binding'), reason: shape.key);
      }
    }
  });

  test('an ordinary Key is still named, because a name is what a reader greps '
      'for and withholding every key would cost every message its one useful '
      'word', () {
    try {
      parseBindings('bindings:\n  cam-den:\n    connectivity: wired\n');
      fail('expected a FormatException');
    } on FormatException catch (e) {
      expect(e.toString(), contains('"cam-den"'));
    }
  });
}

Matcher _rejects(String culprit) => throwsA(isA<FormatException>()
    .having((e) => e.message, 'message', contains(culprit)));
