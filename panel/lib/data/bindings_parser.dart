/// Reads `bindings.yaml` — the one hand-maintained half of the House Plan
/// (ADR-0005) — into validated data, with every complaint naming the file,
/// the culprit and the fix.
///
/// Shared on purpose. The Panel parses this at boot and the dev-Hub
/// generator reasons about the same bindings; two parsers over one
/// hand-edited file is how a rule ends up enforced in one place and not the
/// other. Pure Dart, no Flutter: the generator runs under plain `dart run`.
library;

import 'package:yaml/yaml.dart';

import '../domain/device_vocabulary.dart';

/// One binding: what the Hub calls this Device, and whether it needs a
/// vendor cloud. Position, Room, name and kind are not here — those are
/// drawn, and the converter owns them.
class ParsedBinding {
  const ParsedBinding({
    required this.key,
    required this.ordinal,
    required this.entityId,
    required this.streamName,
    required this.substream,
    required this.talkStream,
    required this.snapshotEntity,
    required this.connectivity,
  });

  /// The author-controlled Key, typed once in Sweet Home 3D. Free-form:
  /// any spelling or separator, unique across the house.
  final String key;

  /// Where this binding sits in `bindings.yaml`, counting from 1.
  ///
  /// Carried purely so a complaint can point at a binding whose [key] it
  /// refuses to repeat — see [label]. YAML preserves the order the author
  /// typed, so "the 3rd binding" is a place in the file and not an internal
  /// number.
  final int ordinal;

  /// Null while the hardware is still in a box — the Device renders with
  /// unknown state rather than being dropped.
  final String? entityId;

  /// The go2rtc stream this Device's live view plays, e.g. `ring_doorbell`.
  /// Null is the normal case and stays normal: a camera whose feed is not
  /// wired up yet still draws its pin, and its Popup says so — an honest
  /// unavailable beats a black rectangle. Only camera and doorbell Devices
  /// may carry one; the loader is what enforces that, because only it knows
  /// the Device's kind.
  final String? streamName;

  /// The go2rtc stream a *tile* plays, when the camera offers a smaller one —
  /// e.g. `wyze_living_room_sub`. Null means "there is only one size", and
  /// the tile plays [streamName].
  ///
  /// **Why a second name rather than a suffix convention.** Same reason
  /// `talk:` is its own key: nothing derives one go2rtc stream name from
  /// another, and a `_sub` rule in code would be the Panel deciding what
  /// exists in `go2rtc.yaml` — the exact mistake the rejected `_mjpeg`
  /// convention would have made. A camera with no substream simply has no
  /// line here.
  ///
  /// **Why it exists at all**, measured 2026-08-15: the Cameras view is a
  /// grid of ~400 px tiles and every one of them was pulling 1920×1080. On
  /// this house's fleet the substream is 640×360 — about a ninth of the
  /// pixels — and the full-size stream stays where a person is actually
  /// looking at it, in the Popup. That mattered because these cameras are
  /// 2.4 GHz-only and the Hub is on Wi-Fi too, so a tile's bytes cross the
  /// air twice, and five tiles at once was reliably knocking one or two
  /// cameras off with `Host is unreachable`.
  ///
  /// Only a video kind may carry one, and only alongside a [streamName] —
  /// the loader enforces both, because only it knows the Device's kind.
  final String? substream;

  /// The go2rtc stream this Device's push-to-talk button pushes **into**, e.g.
  /// `ring`. Null is the normal case and stays normal — a doorbell with no
  /// talkback wired up still draws its button's absence honestly.
  ///
  /// A separate key from [streamName] because they are separate go2rtc
  /// streams and neither derives from the other: the Front Door *plays*
  /// `ring_doorbell` (ring-mqtt's RTSP restream) and *talks into* `ring`
  /// (go2rtc's native `ring:` source, the only one of the two carrying a
  /// backchannel — ADR-0011). Only a doorbell may carry one; the loader
  /// enforces that, as with [streamName], because only it knows the kind.
  final String? talkStream;

  /// The HA camera entity whose still image faces this Device's tile in the
  /// Cameras view while it is not live, e.g. `camera.front_door_snapshot`.
  /// Null is the normal case: a tile with no snapshot face shows its icon.
  /// Exists because the doorbell's *state* entity (the ding) and its
  /// *picture* entity are different entities, and nothing can derive one
  /// from the other. Only a video kind may carry one; the loader enforces
  /// that, as with [streamName].
  final String? snapshotEntity;

  final Connectivity connectivity;

  /// How a logged complaint names this binding. See [bindingLabel].
  String get label => bindingLabel(key, ordinal);
}

/// How a message that will be logged names the binding it is complaining
/// about: `"cam-den"` for a Key that cannot be hiding a credential, and
/// `the 3rd binding` for one that can.
///
/// The leak this closes. A Key is as hand-typed as a value, and a paste that
/// lands one column to the left — no indent, so YAML reads the whole camera
/// URL as the key — is the same accident [_refuses] exists to contain. It
/// produced a line that contradicted its own promise, measured:
///
///     the stream: under "rtsp://admin:hunter2@cam/live" is not a go2rtc
///     stream name … The value is not echoed here …
///
/// Quiet Keys are still named, because a name is what a reader greps for and
/// every real Key is one. The rest are placed by position, which is what
/// identifies a line in a file whose entries stay in the order they were
/// typed. Rejected: withholding every Key, which costs the everyday message
/// its one useful word; and truncating a long Key, which publishes the start
/// of whatever was pasted.
String bindingLabel(String key, int ordinal) =>
    isQuiet(key) ? '"$key"' : 'the ${ordinalWord(ordinal)} binding';

/// Whether a hand-typed value has nowhere for a credential to hide: letters,
/// digits, space, dot, dash and underscore, and short enough to be a name
/// somebody typed.
///
/// Deliberately the same exclusions as [_streamName] plus a length bound —
/// no `:`, `@`, `/` or `?`, so no URL, no `user:pass` pair and no query
/// string can pass. Rejected: allowing anything log.dart would not have to
/// quote, which admits `user:pass` unchanged.
///
/// Public, and no longer only about bindings.yaml Keys. `house_loader.dart`
/// asks the same question of house.yaml's Device keys, Room ids, Floor ids,
/// kind slugs and the house's own name, and its messages are logged through
/// the same `house.invalid` line. Rejected: a second predicate over there
/// with its own charset — two spellings of "safe to print" drift, and the
/// one that drifts wider is the one nobody notices.
///
/// **What this cannot do, stated so it is not read as more than it is.** The
/// charset it accepts — letters, digits, `.`, `_`, `-`, up to 40 characters —
/// is very nearly base64url's own, so a *bare secret* has the shape of a name
/// and passes. Measured: `I house.loaded name=sk_live_51H8hunter2abcdefghij`,
/// through `boot.dart`'s use of this very predicate to decide whether to
/// withhold. This function answers "could a URL, a `user:pass` pair or a query
/// string be hiding in here", which is the mis-paste question — one wrong
/// keystroke, silently — and it is the question every caller actually has. It
/// does not and cannot answer "is this value itself a secret somebody typed on
/// purpose"; nothing that looks only at characters can. Accepted, on the same
/// terms as [_streamName] one screen up: the value is a name the author chose,
/// the accident it guards against is the one that happens, and a predicate
/// that refused every token-shaped string would refuse `ground-floor-2` and
/// `ecobee_upstairs` too. Rejected: a length cap or an entropy test — the
/// first refuses long descriptive ids while a short token sails through, and
/// the second turns a boolean anyone can read into a threshold nobody can.
bool isQuiet(String value) => _quietValue.hasMatch(value);

final _quietValue = RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._-]{0,39}$');

/// `1st`, `2nd`, `3rd`, `4th` — English, because this sentence is read by a
/// person with the file open, not parsed. Public for the same reason
/// [isQuiet] is: house.yaml's entries are placed by position too.
String ordinalWord(int n) {
  final suffix = switch ((n % 100, n % 10)) {
    (11 || 12 || 13, _) => 'th',
    (_, 1) => 'st',
    (_, 2) => 'nd',
    (_, 3) => 'rd',
    _ => 'th',
  };
  return '$n$suffix';
}

/// `loadYaml`, with the YAML parser's own complaint reduced to a position.
///
/// **The leak nobody was guarding, and it was never behind [_refuses] at
/// all.** `loadYaml` runs before any check in this file, and the yaml
/// package's `YamlException` is a `SourceSpanFormatException`: its
/// `toString()` reproduces the offending source line with a caret under it.
/// `boot.dart` hands a fatal House Plan exception to `Log.error(error:)`,
/// which is the only artefact a black-screen boot leaves in journald — so a
/// duplicated `stream:` line, a stray tab, or a pasted URL containing `": "`
/// each published the camera password, measured:
///
///     E house.invalid error="Error on line 5, column 5: Duplicate mapping
///     key.\n  ╷\n5 │     stream: rtsp://admin:hunter2@192.168.68.44/live…"
///
/// The *worse* typo published it and the *cleaner* one — the one that parses
/// and is then refused below — did not.
///
/// Line and column are the useful half and carry no secret, so they stay.
/// Rejected: catching this in `boot.dart`'s log-and-rethrow instead. That
/// leaves the exception object itself carrying the source text for any other
/// caller to log, and it is one door per file rather than one door; both
/// House Plan files come through here.
///
/// The parser's own sentence is reproduced only when it looks like one of its
/// constants (`Duplicate mapping key.`, `Expected ':'.`). One yaml message
/// interpolates author text — `Undefined tag: <tag>`, and a YAML verbatim tag
/// is an arbitrary URI — and it joins with `": "`, which is the second of the
/// two tests below. Rejected: dropping the sentence always, which leaves
/// "not valid YAML" and a position for a fault the parser could have named.
dynamic readYaml(String text, {required String file}) {
  try {
    return loadYaml(text);
  } on YamlException catch (e) {
    final at = e.span?.start;
    final where =
        at == null ? '' : ' at line ${at.line + 1}, column ${at.column + 1}';
    final said =
        _quietYamlMessage.hasMatch(e.message) && !e.message.contains(': ')
            ? ' (${e.message})'
            : '';
    throw FormatException(
        '$file is not valid YAML$where$said. The line itself is not echoed '
        'here: this complaint is logged, and the line a mis-paste lands on '
        'can be a camera URL with a password in it — open $file at that '
        'position to read it.');
  }
}

/// Letters, digits, spaces and the punctuation the parser's constant
/// sentences are written with. A source line pasted into a message would
/// carry `/`, `@`, `"` or `<`; none of those are here.
final _quietYamlMessage = RegExp(r"^[A-Za-z0-9 .,'?!()\-:]+$");

/// Home Assistant's entity id shape: `domain.object_id`.
final _entityId = RegExp(r'^[a-z_]+\.[a-z0-9_]+$');

/// A go2rtc stream *name*, and the exclusion of `:` is the whole point.
///
/// `?src=` is not a name lookup. Measured against the live go2rtc 1.9.10 on
/// 2026-08-04: `?src=rtsp://127.0.0.1:9/nope` did not 404 — go2rtc **created
/// a stream by that name and dialled it**. So a fat-fingered RTSP paste in
/// this file becomes a live outbound connection from the Hub, and puts the
/// camera's credentials into `cameras.popup_open name=…`, which is the one
/// thing log.dart forbids absolutely. Rejected: "accept any string, go2rtc
/// will 404 the wrong ones" — it will not; it will obey them.
///
/// The class also excludes every character log.dart's `_needsQuoting` would
/// force into quotes, so a stream name always renders bare in a log line.
///
/// No first-position rule. A go2rtc stream name is a map key in
/// go2rtc.yaml, and `_ring_doorbell` is a legal one; an earlier
/// `^[A-Za-z0-9]` opener refused it while the message described it as
/// conforming, which sends the reader off to retype a value that was
/// already right. Rejected: keeping the opener and rewording the message —
/// the opener bought nothing, because `:`, `/` and `@` (and everything
/// log.dart would quote) are excluded in *every* position by the class
/// itself, so all it did was refuse names go2rtc accepts.
///
/// **The one credential channel this file accepts, stated so it is not
/// rediscovered a fifth time.** A name that passes here is logged as it
/// stands — `cameras.popup_open name=…` on every Popup, and `streams=` counts
/// it at boot — so a bare API token typed where a stream name goes is
/// published, because a token has the shape of a legal name and nothing here
/// can tell them apart. Accepted, deliberately: the name is the whole content
/// of "which camera did the wall try to show", the value is one the operator
/// chose from `go2rtc.yaml` rather than pasted from a camera's web UI, and it
/// cannot be a URL — the class above is what guarantees that. Rejected:
/// hashing or truncating the name in the log, which costs every honest line
/// its meaning to contain a value that should never have been typed here;
/// and a length cap, which would refuse the long descriptive names go2rtc
/// allows while a short token sailed through.
final _streamName = RegExp(r'^[A-Za-z0-9._-]+$');

/// The complaint for a value this file refuses to repeat back.
///
/// Naming the file, the binding and the field is enough to find the line in a
/// hand-edited bindings.yaml — the reader has the file open. Echoing the
/// value is convenience, not information, and it is the half that cannot be
/// taken back: `boot.dart` hands a fatal [FormatException] to
/// `Log.error(error:)`, which is the *only* artefact a black-screen boot
/// leaves behind, and it lands in journald on the appliance and the browser
/// console on web. A camera URL pasted into `stream:` — the exact typo the
/// stream rule exists to catch — carries `user:password@host` with it, so
/// refusing the value would be what published the password. `entity:` gets
/// the same treatment: it is one line away and just as easy to paste into.
///
/// The *key* goes through [bindingLabel] for the same reason and not as a
/// courtesy: this message used to name the key verbatim, so a paste that
/// landed on the key line produced `the stream: under
/// "rtsp://admin:hunter2@cam/live" … The value is not echoed here`, a
/// sentence that broke its own promise in its own second half.
///
/// Rejected: redacting the middle (`rtsp://…@…`), which still publishes the
/// host and invites the next person to widen it; and naming just the first
/// offending character, which can be a character of the password.
FormatException _refuses(
        String key, int ordinal, String field, String problem) =>
    FormatException(
        'bindings.yaml: the $field: under ${bindingLabel(key, ordinal)} '
        '$problem. Neither the value nor a key that could be hiding one is '
        'echoed here: this complaint is logged, and a mis-paste into this '
        'file can be a camera URL with a password in it — open bindings.yaml '
        'and read the line.');

/// One optional text field off a binding, or a [FormatException] in this
/// file's usual shape.
///
/// `entity: 007` is an integer to YAML, and `binding['entity'] as String?`
/// threw a bare `_TypeError` naming neither the file nor the key — breaking
/// the promise this library's own docstring makes to whoever hand-edited
/// the file. `stream: 007` is a plausible typo for a stream *named* `007`,
/// so the same hole would be reopened. Rejected: `?.toString()`, which
/// would quietly turn `007` into the entity id `7` and fail three modules
/// downstream with nothing pointing back here.
///
/// This message *does* echo the value, unlike [_refuses] above, and the
/// difference is what YAML already told us: a *scalar* read as something
/// other than text is a number, a bool or a date, and none of those can be
/// `rtsp://user:pass@host` — that shape is a String to YAML and returns on
/// the line above. `quote it: stream: "007"` *is* the fix, and it cannot be
/// written without the value.
///
/// A collection is the exception, and it was the hole. This used to claim
/// that the shape [_refuses] withholds "never arrives here"; it arrives as
///
///     stream:
///       url: rtsp://admin:hunter2@cam/live
///
/// — the hand-edit of somebody half-remembering go2rtc's own config shape,
/// one line off the same mis-paste [_refuses] exists to contain. YAML reads
/// it as a map, so it came through here and printed the password back, twice
/// per line. Collections go to [_refuses] instead: `quote it` is not the fix
/// for a nested block anyway, so nothing is lost by withholding it.
///
/// The key is named through [bindingLabel] even here, where the value is
/// echoed on purpose: the two are independent accidents. A number typed under
/// a URL-shaped key is still a URL-shaped key.
String? _text(dynamic binding, String key, int ordinal, String field) {
  final value = binding == null ? null : binding[field];
  if (value == null) return null;
  if (value is String) return value;
  if (value is YamlMap || value is YamlList) {
    throw _refuses(key, ordinal, field,
        'is a block of its own rather than one line of text (YAML read it as '
        'a ${value.runtimeType}) — this field takes a single value on the '
        'same line as its name');
  }
  throw FormatException(
      'bindings.yaml: ${bindingLabel(key, ordinal)} has $field: $value, which '
      'YAML read as a ${value.runtimeType} rather than text — quote it: '
      '$field: "$value"');
}

/// Parses and validates the whole file. Throws [FormatException] on the
/// first problem; the caller decides what to do with it.
Map<String, ParsedBinding> parseBindings(String yaml) {
  // Through [readYaml], not `loadYaml`: the parser's own exception prints the
  // source line it choked on, and this file's whole point is that a line in it
  // can be a camera URL.
  final doc = readYaml(yaml, file: 'bindings.yaml');
  final out = <String, ParsedBinding>{};
  // One entity may back only one Device: two pins driving one entity would
  // toggle each other, and neither could be reasoned about from the wall.
  // Keyed by entity id, valued by the *label* the clash message will use
  // rather than the key itself: the message is logged, and nothing here is
  // allowed to hold a hand-typed key in a form a message can print raw.
  final seenEntities = <String, String>{};
  // 1-based, so it reads as a place in the file. Counted over every entry
  // including the ones that throw, so the number a complaint quotes is the
  // number a reader counts down to.
  var ordinal = 0;

  for (final entry in ((doc?['bindings'] as YamlMap?) ?? YamlMap()).entries) {
    final key = entry.key as String;
    final binding = entry.value;
    ordinal++;
    // Checked before any field is read off it. `bindings: cam-den: <scalar>`
    // used to reach `binding['entity']`, i.e. `String.operator[]`, and escape
    // this library's contract with a raw `_TypeError` naming neither the file
    // nor the key — the same breach `_text` was written to close, one level
    // up. Null is allowed through: a key with nothing under it is a binding
    // with no fields, and the missing `connectivity:` below names it.
    if (binding != null && binding is! YamlMap) {
      throw FormatException(
          'bindings.yaml: ${bindingLabel(key, ordinal)} is not a block of '
          'settings — a binding is entity:, stream: and connectivity: '
          'indented under the key, and this one has something else there '
          '(YAML read it as a ${binding.runtimeType}). Neither what it has '
          'nor a key that could be hiding a credential is echoed here, for '
          'the reason the entity: and stream: messages give: open '
          'bindings.yaml and read the line.');
    }
    final entityId = _text(binding, key, ordinal, 'entity');

    if (entityId != null) {
      if (!_entityId.hasMatch(entityId)) {
        throw _refuses(key, ordinal, 'entity',
            'is not a Home Assistant entity id (domain.object_id, lower '
            'case — e.g. sensor.den_temperature); copy it from Home '
            "Assistant's own entity list rather than typing it");
      }
      final clash = seenEntities[entityId];
      if (clash != null) {
        // The *entity* may be named: it got past `_entityId`, so it is
        // lower-case letters, digits, dots and underscores — no `:`, `@` or
        // `/`, nothing a credential can hide in — and "which entity" is the
        // whole content of the complaint. The two keys still go through
        // [bindingLabel]; a key is hand-typed and this one is not.
        throw FormatException(
            'bindings.yaml: $clash and ${bindingLabel(key, ordinal)} both '
            'bind to entity "$entityId" — one entity, one Device.');
      }
      seenEntities[entityId] = bindingLabel(key, ordinal);
    }

    final streamName = _text(binding, key, ordinal, 'stream');
    if (streamName != null && !_streamName.hasMatch(streamName)) {
      throw _refuses(key, ordinal, 'stream',
          'is not a go2rtc stream name (one or more of letters, digits, dot, '
          'dash and underscore, and nothing else) — name the stream in '
          'go2rtc.yaml and put that name here; a URL here would tell go2rtc '
          'to go and dial it');
    }
    // Deliberately no seenStreams check, unlike entities above: that rule's
    // reason is a *write* hazard, and nothing in the Panel writes to a
    // stream — go2rtc multiplexes consumers over one producer by design.
    // One camera watched from two rooms is a house this must not refuse;
    // the `streams=` count on `house.loaded` is the copy-paste safety net.

    // Held to exactly [_streamName]'s rule, for exactly its reason: this
    // name is handed to go2rtc as a `?src=` too, so a URL here would tell it
    // to go and dial that instead of looking a stream up.
    final substream = _text(binding, key, ordinal, 'substream');
    if (substream != null && !_streamName.hasMatch(substream)) {
      throw _refuses(key, ordinal, 'substream',
          'is not a go2rtc stream name (one or more of letters, digits, dot, '
          'dash and underscore, and nothing else) — name the stream in '
          'go2rtc.yaml and put that name here; a URL here would tell go2rtc '
          'to go and dial it');
    }

    // Held to exactly [_streamName]'s rule, and refused with the same
    // reasoning: a URL here would tell go2rtc to go and dial it, and this key
    // reaches go2rtc as a `dst=` that go2rtc pushes a live microphone into.
    final talkStream = _text(binding, key, ordinal, 'talk');
    if (talkStream != null && !_streamName.hasMatch(talkStream)) {
      throw _refuses(key, ordinal, 'talk',
          'is not a go2rtc stream name (one or more of letters, digits, dot, '
          'dash and underscore, and nothing else) — name the stream in '
          'go2rtc.yaml and put that name here; a URL here would tell go2rtc '
          'to go and dial it');
    }

    final snapshotEntity = _text(binding, key, ordinal, 'snapshot');
    if (snapshotEntity != null &&
        (!_entityId.hasMatch(snapshotEntity) ||
            !snapshotEntity.startsWith('camera.'))) {
      // Stricter than entity: above on purpose — this field is only ever
      // fetched through HA's camera_proxy, which serves camera entities, so
      // a ding sensor or a URL pasted here would fail silently on every
      // refresh tick otherwise.
      throw _refuses(key, ordinal, 'snapshot',
          'is not a camera entity id (camera.object_id, lower case — e.g. '
          'camera.front_door_snapshot); the still face of a tile comes from '
          "an HA camera entity, copied from Home Assistant's entity list");
    }
    // Not deduped, like streams and unlike entity: — a snapshot is a
    // read-only reference, and two Devices wearing one camera's still is a
    // house this must not refuse.

    out[key] = ParsedBinding(
      key: key,
      ordinal: ordinal,
      entityId: entityId,
      streamName: streamName,
      substream: substream,
      talkStream: talkStream,
      snapshotEntity: snapshotEntity,
      // Deliberately no default: a planned Ring camera is a Cloud Device
      // before it is ever bound, so guessing `local` would mislabel it.
      //
      // Withheld like `entity:` and `stream:`, not echoed. This used to name
      // the value, arguing that "it is not a field anyone pastes an address
      // into" — but it sits one line below `stream:` in the same block, and a
      // paste landing one line off is the identical accident with the
      // identical password in it. The two words are in the message; which
      // wrong one was typed is on the line the reader already has open.
      //
      // Through [_text], so `connectivity: 007` is this file's complaint too
      // rather than a raw cast failure.
      connectivity: switch (_text(binding, key, ordinal, 'connectivity')) {
        'local' => Connectivity.local,
        'cloud' => Connectivity.cloud,
        // Nothing to withhold *in the field* when there is nothing there — but
        // the key is still hand-typed, so it goes through [bindingLabel] like
        // every other one. This message named it raw, which is how a mis-paste
        // on the key line reached journald through the most ordinary complaint
        // in the file.
        null => throw FormatException(
            'bindings.yaml: ${bindingLabel(key, ordinal)} has no '
            'connectivity: — every Device states whether it needs a vendor '
            'cloud (local | cloud)'),
        _ => throw _refuses(key, ordinal, 'connectivity',
            'is neither of the two words this field takes (local | cloud)'),
      },
    );
  }
  return out;
}
