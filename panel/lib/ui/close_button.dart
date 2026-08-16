import 'package:flutter/material.dart';

import 'theme.dart';

/// The one way out of anything on the Panel: a small raised puck with an X,
/// top-right of whatever it closes.
///
/// **One idiom, everywhere**, and that is the whole point of it being a widget
/// rather than a shape each surface draws for itself. The Panel has no
/// keyboard and no Escape key, so "how do I get out of this" must have exactly
/// one answer wherever somebody is standing — and until 2026-08-15 it had
/// three: a `Close` text button at the bottom of a Popup, this puck at the top
/// of it, and a bare Material [IconButton] on the Cameras view.
///
/// Named with the `Panel` prefix because `package:flutter/material.dart`
/// already exports a `CloseButton`, and a file importing both would have to
/// choose — the same reason [PanelTheme] wears it.
///
/// A [GestureDetector] rather than an [IconButton]: the Popup wraps its card
/// in a [Listener] that re-arms the idle bound on any touch, and listeners
/// never enter the gesture arena, so this cannot lose a press to it. 48 px of
/// target around a 36 px puck, because the thing pressing it is a thumb.
///
/// Callers pass their own [key] — `popup-close`, `cameras-close` — so a test
/// can say *which* way out it means without asserting the glyph.
class PanelCloseButton extends StatelessWidget {
  const PanelCloseButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  /// The puck, and the touch target around it.
  static const diameter = 36.0;
  static const target = 48.0;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Close',
      button: true,
      child: GestureDetector(
        onTap: onPressed,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: target,
          height: target,
          child: Center(
            child: Container(
              width: diameter,
              height: diameter,
              decoration: BoxDecoration(
                color: PanelTheme.surfaceRaised,
                shape: BoxShape.circle,
                boxShadow: PanelTheme.raised(8),
              ),
              child: const Icon(Icons.close, color: PanelTheme.ink, size: 20),
            ),
          ),
        ),
      ),
    );
  }
}
