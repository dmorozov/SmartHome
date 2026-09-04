import 'package:flutter_test/flutter_test.dart';
import 'package:panel/ui/video/camera_face.dart';
import 'package:panel/ui/video/stream_director.dart';

import 'support/fake_feed.dart';

/// The face's verdict, tested through its own interface — no widget, no
/// go2rtc, no Director. The three surfaces' phrase tables are pinned where
/// they live (`device_popup_test.dart`, `cameras_view_test.dart`); what is
/// pinned HERE is the one core they share: the latch, its birth read, the
/// dual listening and the "re-" predicate.
void main() {
  test('a feed born playing is known to have played — a listener never '
      'fires for the value it was born with', () {
    final feed = FakeFeed()..phase.value = FeedPhase.playing;
    final face = CameraFace(feed);
    addTearDown(face.dispose);

    expect(face.sawPlaying, isTrue);
    expect(face.reconnecting, isFalse, reason: 'playing is not a wait');

    feed.phase.value = FeedPhase.retrying;
    expect(face.reconnecting, isTrue,
        reason: 'the picture the pool handed back WAS up; its loss is a '
            'restoration to claim');
  });

  test('a first connect that keeps failing never says "re-" — there is '
      'nothing to restore', () {
    final feed = FakeFeed();
    final face = CameraFace(feed);
    addTearDown(face.dispose);

    expect(face.sawPlaying, isFalse);
    expect(face.reconnecting, isFalse);

    feed.phase.value = FeedPhase.retrying;
    expect(face.reconnecting, isFalse);

    feed.retryAttempt.value = 1;
    feed.phase.value = FeedPhase.connecting;
    expect(face.counting, isTrue);
    expect(face.attempt, 2, reason: 'the person watched attempt #1 fail');
    expect(face.reconnecting, isFalse,
        reason: 'counted out loud, but still only connecting');

    // Nor through the gate, nor at an (unreachable) counted idle.
    feed.phase.value = FeedPhase.queued;
    expect(face.reconnecting, isFalse);
    feed.phase.value = FeedPhase.idle;
    expect(face.reconnecting, isFalse);
  });

  test('a picture that died is a restoration through the whole climb, and '
      'a fresh start after an idle park is not', () {
    final feed = FakeFeed();
    final face = CameraFace(feed);
    addTearDown(face.dispose);

    feed.phase.value = FeedPhase.playing;
    expect(face.sawPlaying, isTrue);

    feed.phase.value = FeedPhase.retrying;
    expect(face.reconnecting, isTrue);

    // The re-dial itself: the count stays put through its connecting phase
    // (the feed's contract), so the face keeps saying "re-".
    feed.retryAttempt.value = 1;
    feed.phase.value = FeedPhase.connecting;
    expect(face.reconnecting, isTrue);
    expect(face.attempt, 2);

    // A timer-born re-dial passes through queued when it meets the admission
    // gate — the zoom's arm already, and the Popup's new reading (its own
    // table fell back to the plain word here until 2026-09-02).
    feed.phase.value = FeedPhase.queued;
    expect(face.reconnecting, isTrue);

    // The defensive idle arm: unreachable today (the Director zeroes the
    // count before every park), armed so it could never say a bare
    // "Connecting…" over a picture that was up.
    feed.phase.value = FeedPhase.idle;
    expect(face.reconnecting, isTrue);

    feed.phase.value = FeedPhase.playing;
    expect(face.reconnecting, isFalse);

    // An idle park resets the ladder: the resume dial is rung zero, and
    // says so — whatever came before.
    feed.retryAttempt.value = 0;
    feed.phase.value = FeedPhase.idle;
    expect(face.reconnecting, isFalse);
    feed.phase.value = FeedPhase.connecting;
    expect(face.reconnecting, isFalse,
        reason: 'a fresh dial with the count at zero is a fresh start');
    expect(face.sawPlaying, isTrue,
        reason: 'the latch is for the face\'s life, not for one dial');
  });

  test('the count climbing with no phase change still notifies — a face '
      'that listened to phase alone would freeze at "try 2"', () {
    final feed = FakeFeed()..phase.value = FeedPhase.retrying;
    final face = CameraFace(feed);
    addTearDown(face.dispose);
    var notified = 0;
    face.addListener(() => notified++);

    feed.retryAttempt.value = 1;
    expect(notified, 1);
    expect(face.attempt, 2);

    // retrying→retrying: a re-dial that failed synchronously.
    feed.retryAttempt.value = 2;
    expect(notified, 2);
    expect(face.attempt, 3);

    feed.phase.value = FeedPhase.connecting;
    expect(notified, 3);
  });

  test('the verdict phases are never restorations', () {
    final feed = FakeFeed()..phase.value = FeedPhase.playing;
    final face = CameraFace(feed);
    addTearDown(face.dispose);

    for (final phase in [
      FeedPhase.failed,
      FeedPhase.offline,
      FeedPhase.unconfigured,
      FeedPhase.unsupported,
    ]) {
      feed.phase.value = phase;
      expect(face.reconnecting, isFalse, reason: '$phase');
    }
  });

  test('dispose takes both listeners off the feed — the feed outlives the '
      'face by a frame in the Popup', () {
    final feed = FakeFeed();
    final face = CameraFace(feed);
    expect(feed.phase.listened, isTrue);
    expect(feed.retryAttempt.listened, isTrue);

    face.dispose();

    expect(feed.phase.listened, isFalse);
    expect(feed.retryAttempt.listened, isFalse);
  });
}
