import 'package:flutter/foundation.dart';

import 'stream_director.dart';

/// The shared core of every not-live face — the Popup's video box, the
/// Cameras tile, the zoom: a feed's phase, whether a picture was EVER up in
/// this face's life, and whether the wait it is in is a restoration.
///
/// Three copies of this had drifted apart (measured 2026-09-02). Only the
/// Popup's read the born value, so a tile re-attached to a lingered picture
/// — the keep-alive pool handing one back at attach — whose player dropped
/// back to `connecting` before it failed (the MSE rebuild after a
/// media-element error) said "Connecting…" through the whole ladder, over a
/// picture that was up: the lie the latch exists to prevent, because
/// **"re-" claims a restoration** (ADR-0007's rule applied to a verb, owner
/// request 2026-08-26). A straight playing→failed death was saved only by
/// an ordering accident — the Director climbs the count before it flips
/// the phase, and the tile listened to the count while the phase still read
/// playing. And only two of the three listened to [CameraFeed.retryAttempt]
/// beside [CameraFeed.phase], though the feed's own contract says a face
/// that listens to phase alone freezes its count — a re-dial failing
/// synchronously is retrying→retrying, no phase change.
///
/// What is deliberately NOT here, by ADR-0013's "one phase table per
/// surface": any sentence, icon, still, tag or frame. A surface holds one of
/// these and its own phrase table over ([phase], [reconnecting],
/// [counting], [attempt]) — the words differ by surface on purpose ("Live
/// view unavailable" is the Popup's for three phases the Cameras view tells
/// apart), and that stays data in each surface.
///
/// Listens to both notifiers from construction and notifies its own
/// listeners on either; a surface's listener is its `setState` and nothing
/// more. [dispose] removes both — call it from the surface's own dispose:
/// before the surface releases the feed (tile, zoom), or before the owner
/// that outlives the box does (the Popup).
class CameraFace extends ChangeNotifier {
  CameraFace(this.feed) {
    // Read at birth as well as on change: a listener never fires for the
    // value it was born with, and a feed CAN be born playing (the pool's
    // lingered session, `stream_director.dart`).
    _sawPlaying = feed.phase.value == FeedPhase.playing;
    feed.phase.addListener(_changed);
    feed.retryAttempt.addListener(_changed);
  }

  final CameraFeed feed;
  var _sawPlaying = false;

  FeedPhase get phase => feed.phase.value;

  /// Whether a picture has ever arrived in this face's life.
  bool get sawPlaying => _sawPlaying;

  /// Whether the wait the feed is in is a restoration — honest only over a
  /// picture that was up. `retrying` is a wait between ladder dials;
  /// `connecting` (or `queued`, which a timer-born re-dial passes through
  /// when it meets the admission gate — on every laddered role, the Popup's
  /// included) with the count above zero is the re-dial itself; a fresh
  /// dial with the count at zero is a fresh start whatever came before — an
  /// idle park resets the ladder, and the resume dial is rung zero, not a
  /// resumption. `idle` is in the arm defensively: the Director zeroes the
  /// count before every park, so it never fires today; it is armed so a
  /// Director that stopped zeroing could not make a surface's own idle arm
  /// say a bare "Connecting…" over a picture that was up.
  bool get reconnecting => switch (phase) {
        FeedPhase.retrying => _sawPlaying,
        FeedPhase.connecting ||
        FeedPhase.queued ||
        FeedPhase.idle =>
          _sawPlaying && counting,
        _ => false,
      };

  /// Whether the ladder is climbing — what the counted faces say out loud.
  bool get counting => feed.retryAttempt.value > 0;

  /// The human count: "try #2" is the FIRST re-dial, because the person
  /// watched attempt #1 fail — [CameraFeed.retryAttempt]'s own rule.
  int get attempt => feed.retryAttempt.value + 1;

  void _changed() {
    if (feed.phase.value == FeedPhase.playing) _sawPlaying = true;
    notifyListeners();
  }

  @override
  void dispose() {
    feed.phase.removeListener(_changed);
    feed.retryAttempt.removeListener(_changed);
    super.dispose();
  }
}
