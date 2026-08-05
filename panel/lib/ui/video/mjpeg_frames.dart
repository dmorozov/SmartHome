import 'dart:convert';
import 'dart:typed_data';

/// The largest a single part's header block may be — whole or as far as it
/// has arrived — before the stream is called malformed.
///
/// go2rtc's is 60 bytes (`--frame`, `Content-Type`, `Content-Length`, blank
/// line). The cap exists because the alternative to a cap is an unbounded
/// buffer: something that answers 200 and then sends a megabyte with no blank
/// line in it would otherwise be held entirely in memory on a wall panel that
/// runs for months.
///
/// "Whole or as far as it has arrived" is the correction. This was enforced
/// only while the blank line had *not* yet been seen, so whether a stream was
/// refused depended on where the kernel split the socket reads: a 100 kB
/// header block delivered in one packet was accepted, and the identical bytes
/// in 4 kB packets were refused. Packet boundaries are not a property of the
/// stream, so they cannot decide what the stream is.
const kMjpegMaxHeaderBytes = 4096;

/// The largest `Content-Length` a part may declare.
///
/// A 640x480 JPEG measures 7.2 kB and a 4K one is under 2 MB, so 8 MB is far
/// above anything real and far below "allocate whatever the number says".
const kMjpegMaxFrameBytes = 8 * 1024 * 1024;

/// A malformed multipart stream, told apart from every other
/// [FormatException] by its own type.
///
/// The type exists so that the player can reproduce **this** exception's
/// message in a log line and no other. `dart:io`'s own exceptions append
/// `uri = …` to their messages, and that URI is the one string in the whole
/// player that can be carrying a password (`diagnostics/log.dart`: **Never
/// log a secret**). Every message constructed below names counts and nothing
/// else — no bytes from the wire, no header text, no URL.
class MjpegFormatException extends FormatException {
  const MjpegFormatException(super.message);
}

/// Splits go2rtc's `multipart/x-mixed-replace` body into whole JPEG frames.
///
/// Measured against go2rtc 1.9.10, `GET /api/stream.mjpeg?src=…`, each part
/// arriving verbatim as:
///
/// ```
/// --frame\r\nContent-Type: image/jpeg\r\nContent-Length: 11873\r\n\r\n<n bytes>\r\n
/// ```
///
/// **Driven by `Content-Length`, never by scanning for the boundary token.**
/// `--frame` is seven ordinary bytes and JPEG entropy-coded data is
/// effectively random, so a boundary scan will eventually cut a frame in
/// half at a byte sequence that only looks like a separator. Reading exactly
/// the declared number of bytes cannot make that mistake.
///
/// Takes a `Stream<List<int>>` rather than an `HttpClientResponse` so that it
/// is testable without a socket at all, and so that `dart:io` stays out of
/// this file: the framing is the risky part and it is pure byte arithmetic.
/// Chunk boundaries are not part boundaries — `HttpClient` de-chunks the
/// transfer encoding and then hands over whatever the socket read returned,
/// which splits parts anywhere, including inside a header.
///
/// Emits a [MjpegFormatException] on the stream for bytes that claim to be
/// parts and are not: a header past [kMjpegMaxHeaderBytes], a part with no
/// `Content-Length` or one past [kMjpegMaxFrameBytes], and a body that ended
/// having never contained a part header at all.
///
/// That last one was a hole in this promise, not an addition to it: a `200`
/// carrying `<html>hello</html>` used to produce no exception, so the player
/// reported *"go2rtc ended the stream"* for a response that was never a
/// multipart stream — sending an operator to look at a camera when what
/// answered was an error page.
///
/// Ends quietly when the source ends **after at least one part header**, even
/// mid-part: from there on a connection that stops is the caller's event to
/// interpret, not a framing error. Also quiet for a body that was nothing but
/// blank lines, which is an idle server rather than a wrong one.
Stream<Uint8List> mjpegFrames(
  Stream<List<int>> bytes, {
  int maxHeaderBytes = kMjpegMaxHeaderBytes,
  int maxFrameBytes = kMjpegMaxFrameBytes,
}) async* {
  var pending = Uint8List(0);
  // Non-null once a header has been read and we are counting out its body.
  int? want;
  // Whether a part header has ever been read. What separates "the connection
  // stopped mid-stream", which is the player's event to name, from "this was
  // never a multipart body", which nothing downstream can work out for itself.
  var sawHeader = false;

  await for (final chunk in bytes) {
    pending = _followedBy(pending, chunk);
    while (true) {
      if (want == null) {
        // The blank line that ends a part's header. The leftover `\r\n` that
        // terminates the previous part's body is skipped rather than parsed:
        // go2rtc emits exactly one, but a server that emitted two would
        // otherwise present an empty header block and be called malformed
        // for being *more* conventional than go2rtc is.
        pending = _withoutLeadingNewlines(pending);
        final bodyAt = _endOfHeader(pending);
        // The header block, whole when the blank line has arrived and as far
        // as it has got when it has not — one measurement either way, so the
        // verdict does not depend on where the kernel split the reads. See
        // [kMjpegMaxHeaderBytes].
        final headerBytes = bodyAt < 0 ? pending.length : bodyAt;
        if (headerBytes > maxHeaderBytes) {
          throw MjpegFormatException(
              'a part header ran past $maxHeaderBytes bytes');
        }
        if (bodyAt < 0) break;
        sawHeader = true;
        want = _declaredLength(pending, bodyAt, maxFrameBytes);
        pending = Uint8List.sublistView(pending, bodyAt);
      }
      if (pending.length < want) break;
      // A copy, not a view: the frame outlives this loop — it is handed to
      // an image decoder that finishes several parts later — while the view
      // would alias a buffer this loop is about to replace.
      yield pending.sublist(0, want);
      pending = Uint8List.sublistView(pending, want);
      want = null;
    }
  }
  // The source ended. Bytes arrived, no part header was ever among them: this
  // was not a multipart stream, and only this parser is in a position to say
  // so. `pending` has had its blank lines stripped by the loop above, so a
  // body of nothing but `\r\n` lands here empty and stays quiet.
  if (!sawHeader && pending.isNotEmpty) {
    throw const MjpegFormatException(
        'the body ended with no part header in it, so it was never a '
        'multipart stream');
  }
}

/// A fresh buffer holding [head] then [tail].
///
/// A plain copy rather than a rope or a `BytesBuilder`: at the measured
/// ~185 kB/s with a 7.2 kB mean frame, [head] is a partial frame and the copy
/// is a few kilobytes per socket read. Cheap enough that the simpler shape
/// wins. (The 124 kB/s this used to quote was bytes over the whole request
/// including go2rtc's 2.1 s idle spin-up; the same capture with the startup
/// excluded gives ~185 kB/s at 25 fps. `panel/README.md` retracted the figure
/// and this line had kept it.)
Uint8List _followedBy(Uint8List head, List<int> tail) {
  if (head.isEmpty) {
    return tail is Uint8List ? tail : Uint8List.fromList(tail);
  }
  final joined = Uint8List(head.length + tail.length)
    ..setRange(0, head.length, head)
    ..setRange(head.length, head.length + tail.length, tail);
  return joined;
}

Uint8List _withoutLeadingNewlines(Uint8List bytes) {
  var at = 0;
  while (at < bytes.length && (bytes[at] == 0x0d || bytes[at] == 0x0a)) {
    at++;
  }
  return at == 0 ? bytes : Uint8List.sublistView(bytes, at);
}

/// The index just past the `\r\n\r\n` that ends a header block, or -1.
int _endOfHeader(Uint8List bytes) {
  for (var at = 0; at + 3 < bytes.length; at++) {
    if (bytes[at] == 0x0d &&
        bytes[at + 1] == 0x0a &&
        bytes[at + 2] == 0x0d &&
        bytes[at + 3] == 0x0a) {
      return at + 4;
    }
  }
  return -1;
}

/// The `Content-Length` of the part whose header occupies `bytes[0..bodyAt)`.
///
/// The boundary line and `Content-Type` are read past without being checked.
/// Deliberate: the only field this parser acts on is the length, and
/// rejecting a part because its `Content-Type` was spelled differently would
/// be inventing a requirement go2rtc never promised to keep.
int _declaredLength(Uint8List bytes, int bodyAt, int maxFrameBytes) {
  // latin1, which cannot throw on any byte — a header is ASCII in practice,
  // and a decoder that threw on the odd stray byte would turn a recoverable
  // stream into a dead one. The decoded text is matched against and never
  // reproduced anywhere.
  final header = latin1.decode(Uint8List.sublistView(bytes, 0, bodyAt));
  final field = _contentLength.firstMatch(header);
  if (field == null) {
    throw const MjpegFormatException(
        'a part arrived with no Content-Length, and this parser counts bytes '
        'rather than scanning for the boundary');
  }
  // tryParse, not parse: a run of digits longer than an int is a number this
  // parser must refuse, and refusing it as "past the ceiling" is the same
  // answer with the same message as a merely huge one.
  final length = int.tryParse(field.group(1)!);
  if (length == 0) {
    throw const MjpegFormatException('a part declared Content-Length: 0');
  }
  if (length == null || length > maxFrameBytes) {
    throw MjpegFormatException(
        'a part declared a length past the $maxFrameBytes byte ceiling');
  }
  return length;
}

final _contentLength = RegExp(r'^content-length:\s*(\d+)\s*$',
    multiLine: true, caseSensitive: false);
