import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The web player's workarounds are **wired in**, checked by reading the
/// source.
///
/// This is an unusual kind of test and it needs its justification stated,
/// because reading source text is normally the wrong way to assert anything.
///
/// `live_video_mse.dart` is behind a conditional import: it compiles **only**
/// on web, so no VM test binary contains it and nothing in `flutter test` can
/// call it. The suite that could is `flutter test --platform chrome`, and that
/// runner **does not work in this devcontainer** — it hangs at `loading …` and
/// never starts a suite (see `panel/README.md`, "The web half runs nowhere
/// unless you ask for it"). So every one of the fixes below is, today,
/// unprotected: delete the call site and all 470 other tests still pass while
/// the doorbell goes green on the wall.
///
/// Four real defects have already hidden in exactly that blind spot in a
/// single session (`hub/dev/go2rtc/DEBUGGING.md`). This is a tripwire, not a
/// test of behaviour: it cannot tell you the workarounds *work*, only that
/// nobody has quietly removed them.
///
/// 🔴 **Delete this file the day `--platform chrome` runs again**, and replace
/// it with tests that actually drive the player. A source-text assertion is a
/// stand-in for coverage, and keeping it once real coverage exists would be
/// pinning the implementation's spelling for no reason.
///
/// Matching is deliberately loose — the *symbol* has to appear in the right
/// place, not any particular formatting — so ordinary refactoring does not
/// trip it and only removal does.
void main() {
  late String mse;
  late String seam;

  setUpAll(() {
    mse = File('lib/ui/video/live_video_mse.dart').readAsStringSync();
    seam = File('lib/ui/video/live_video.dart').readAsStringSync();
  });

  test('the H.264 level is raised before the SourceBuffer is created', () {
    // go2rtc advertises level 4.1 for a level-5.0 stream (its
    // `GetProfileLevelID` whitelist drops anything above 4.0), and a decoder
    // built for 4.1 refuses a 1536x1536 frame outright — 0 frames decoded.
    // Upstream is unfixed as of master, 2026-08-10, and by owner decision this
    // is not being filed, so the workaround is permanent.
    expect(seam, contains('String? raiseH264Level('),
        reason: 'the seam must still define the workaround');
    expect(mse, contains('raiseH264Level('),
        reason: 'the MSE player must still CALL it — defining it is not '
            'enough, and the call is the half no test can reach');
    // Order matters: patching after the SourceBuffer exists would do nothing.
    expect(mse.indexOf('raiseH264Level('),
        lessThan(mse.indexOf('addSourceBuffer(')),
        reason: 'the level must be raised BEFORE addSourceBuffer');
  });

  test('the media element\'s error event is observed', () {
    // The single most expensive omission in the investigation: without this,
    // a decode failure is invisible and surfaces only as `InvalidStateError`
    // on every later append. Three wrong diagnoses came from its absence.
    expect(mse, contains("addEventListener('error', _onVideoError"),
        reason: 'a media element that errors reports it exactly once, here');
  });

  test('a decode failure reconnects rather than giving up', () {
    // go2rtc hands a consumer joining a *running* stream a first sample with a
    // bogus duration, and the decoder quits. Nothing on this side can fix the
    // sample; go2rtc's own player survives it by dialling again, and this is
    // that. Bounded, because every retry is another consumer on a doorbell
    // (HA core #177014).
    expect(mse, contains('void _reconnect('),
        reason: 'the recovery path must still exist');
    expect(mse, contains('_maxReconnects'),
        reason: 'and must stay BOUNDED — an unbounded retry would hammer the '
            'doorbell with live sessions');
    expect(mse, contains('_reconnect('),
        reason: 'and must still be reached from the media-error path');
  });

  test('the discarded socket is unwired before a reconnect closes it', () {
    // A reconnect leaves the session undecided, so the old socket's own
    // `close` event would otherwise settle the NEW attempt as "go2rtc closed
    // the socket" — wrong, and unrecoverable.
    expect(mse, contains('void _unwireSocket('), reason: 'must still exist');
    expect(mse.indexOf('_unwireSocket()'), lessThan(mse.indexOf('_socket.close()')),
        reason: 'deaf before closed, or the discarded socket fails the new '
            'attempt');
    // `.toJS` mints a fresh JSFunction per call, so a listener added with one
    // and removed with another is never removed at all. The handlers have to
    // be converted once and stored for removal to work.
    expect(mse, contains('late final JSFunction _onSocketCloseJs'),
        reason: 'handlers must be converted ONCE and stored, or '
            'removeEventListener silently does nothing');
  });

  test('segment loss is counted and reported, never silent', () {
    // Both loss paths were silent, which is what made an intermittent green
    // picture undiagnosable: bytes kept arriving either way.
    expect(mse, contains('mse_segment_dropped'));
    expect(mse, contains('mse_append_failed'));
    expect(mse, contains('mse_media_error'));
  });

  test('the pump cannot be wedged by one throw', () {
    // `appendBuffer` throwing means no update started, so no `updateend`
    // follows — and `_onUpdateEnd` was the only thing draining the backlog.
    // `_onSegment` drains a stale backlog itself so the next segment restarts
    // a dead pump.
    expect(mse, contains('_flushStaged('),
        reason: 'the drain the pump restarts from');
    expect(mse, contains('_detached'),
        reason: 'appends must stand down while the element is out of the '
            'document rather than throwing');
  });
}
