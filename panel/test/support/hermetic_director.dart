import 'package:flutter/widgets.dart';
import 'package:panel/ui/video/live_video.dart';
import 'package:panel/ui/video/stream_director.dart';

/// The hermetic adapter at the Stream Director seam — the one place a test
/// with no opinion about the Director gets one, the way `main()` is the one
/// place the wall does. A case whose body needs the Director's handle — to
/// flip `overlaid`, to `attach` a feed, to read the census — builds its own
/// `StreamDirector` and owns its dispose (`cameras_view_test.dart`,
/// `camera_health_test.dart`); `stream_director_test.dart` builds it because
/// the Director is its subject.
///
/// Every video surface takes a Director, required, and none builds its own
/// (2026-09-02). Until then the Cameras view and the Popup each carried a
/// `director ?? StreamDirector(video: …)` fallback, and every Popup test
/// plus 28 of 31 Cameras tests ran that path — a composition the wall never
/// runs, on which a forgotten `director:` argument left Camera Health and
/// the census silently deaf while the picture played on. This widget is
/// where that fallback went, so the tests now exercise the seam `main()`
/// composes: one Director, every surface attached to it.
///
/// A State rather than `addTearDown`, deliberately. The test binding checks
/// its "no Timer left pending" invariant when the tree is disposed, BEFORE
/// tear-downs run, and a Director that has admitted a policy dial holds a
/// spacing Timer (`DirectorPolicy.dialSpacing`, 400 ms). Children unmount
/// before their parent, so by the time this widget's State `dispose`s every
/// tile and Popup has released its feed, and the Director cancels what is
/// left —
/// exactly what the view-owned Director used to do at route teardown.
///
/// Renders [builder]'s subtree unchanged; nothing of its own. Give it a
/// `UniqueKey` when the same test pumps it twice: a Director is built once
/// per State, and an updated widget at the same position keeps its State.
class HermeticDirector extends StatefulWidget {
  const HermeticDirector({
    super.key,
    this.video = const VideoConfig(),
    this.policy = const DirectorPolicy(),
    this.health,
    required this.builder,
  });

  /// Where go2rtc is and how to dial it — `FakeGo2rtc.open`, a
  /// `SettledLiveVideoSession` opener, or the unconfigured default for a
  /// scene that says nothing about video (every golden).
  final VideoConfig video;

  /// The shipped default unless the scene is about policy — a stills-first
  /// case passes `DirectorPolicy(autoLive: DirectorPolicy.never)` here, the
  /// same one-value swap `main()` would make.
  final DirectorPolicy policy;

  /// Camera Health, when the scene has an opinion about it; null otherwise,
  /// which the Director reads as "every camera unknown, outcomes dropped".
  final CameraHealthSource? health;

  final Widget Function(BuildContext context, StreamDirector director)
      builder;

  @override
  State<HermeticDirector> createState() => _HermeticDirectorState();
}

class _HermeticDirectorState extends State<HermeticDirector> {
  late final StreamDirector director = StreamDirector(
    video: widget.video,
    policy: widget.policy,
    health: widget.health,
  );

  @override
  void dispose() {
    director.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, director);
}
