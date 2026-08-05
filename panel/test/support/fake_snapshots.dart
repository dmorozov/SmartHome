import 'dart:convert';
import 'dart:typed_data';

import 'package:panel/ui/video/snapshot.dart';

/// A 1×1 PNG, decodable by `Image.memory` under `flutter_test` — what the
/// fake serves so widget tests can watch a tile actually paint.
final Uint8List kOnePixelImage = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhf'
    'DwAChwGA60e6kgAAAABJRU5ErkJggg==');

/// The snapshot seam driven by hand — `fake_go2rtc.dart`'s sibling, for the
/// sibling seam: [requests] records every fetch the Cameras view asked for,
/// and the test decides what comes back.
///
/// Hand-written because this repo has no mockito; every fake is written out.
class FakeSnapshots {
  final requests = <Uri>[];
  final tokens = <String>[];

  /// What the next fetch answers. Swap for a [SnapshotResult.refused] to
  /// stage a broken tile.
  SnapshotResult next = SnapshotResult.ok(kOnePixelImage);

  /// Hand this to `SnapshotConfig(fetch: ...)`.
  Future<SnapshotResult> fetch(Uri url, {required String token}) async {
    requests.add(url);
    tokens.add(token);
    return next;
  }
}
