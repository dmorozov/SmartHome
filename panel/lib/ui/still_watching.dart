import 'package:flutter/material.dart';

import 'theme.dart';

/// "Still watching? Tap anywhere to stay" — the softening on an idle bound
/// ([IdleReturn]).
///
/// Says "tap anywhere", and means it: both surfaces put the whole of
/// themselves under a `Listener`, so there is no target to find and nothing
/// to aim at. Deliberately not a button — a button implies the rest of the
/// surface is not an answer, which would make the easy action the wrong one.
///
/// One widget for one sentence, per CLAUDE.md: it was written twice until
/// 2026-09-03, and the same words drawn twice drift on the first change to
/// either. The two *chromes* are not the same and stay apart — a
/// full-screen surface can afford a raised banner, and the Popup's line
/// lives in a 22 px slot it shares with the Talk caption, whose height the
/// card's layout depends on. So the constructor names the setting rather
/// than the widget being copied.
class StillWatching extends StatelessWidget {
  /// The banner a full-screen surface shows under its content — a raised
  /// puck on the wall's own surface, the neumorphic default.
  const StillWatching.banner({super.key}) : _compact = false;

  /// The single line a Popup shows in its reserved caption slot. No box: it
  /// shares that slot with the Talk caption, and a puck there would make the
  /// card jump the moment the prompt appeared.
  const StillWatching.caption({super.key}) : _compact = true;

  final bool _compact;

  /// The sentence itself, in one place. Both suites find the prompt by it.
  static const sentence = 'Still watching? Tap anywhere to stay';

  @override
  Widget build(BuildContext context) {
    if (_compact) {
      return const Text(
        sentence,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: PanelTheme.inkFaint),
      );
    }
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: PanelTheme.surfaceRaised,
        borderRadius: BorderRadius.circular(12),
        boxShadow: PanelTheme.raised(8),
      ),
      child: const Row(
        children: [
          Icon(Icons.timer_outlined, size: 18, color: PanelTheme.inkFaint),
          SizedBox(width: 10),
          Text(
            sentence,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: PanelTheme.ink,
            ),
          ),
        ],
      ),
    );
  }
}
