import 'package:flutter/material.dart';

import '../domain/house.dart';
import 'theme.dart';

/// How far below the top of the Panel the stack of edge tabs begins.
///
/// Owner-set (2026-08-15), and the number is about the *Dollhouse*, not about
/// the tabs: the house's own name and its hint line occupy the top of the
/// screen, and a tab riding up beside them reads as part of the title rather
/// than as a handle onto something else. 150 clears both and still leaves the
/// tabs in the upper half, where a hand reaching for the edge of a wall panel
/// naturally lands.
const kEdgeTabsTop = 150.0;

/// The gap between stacked tabs. Enough that two handles read as two, not as
/// one control with a seam.
const kEdgeTabGap = 12.0;

/// A handle riding the Panel's right edge, opening something that is not the
/// Dollhouse.
///
/// **Flush to the screen edge, deliberately.** Every other thing on the Panel
/// sits inside `main.dart`'s 24 px gutter; these do not, and that is what
/// makes them read as tabs of a surface parked off-screen rather than as
/// buttons floating on this one. It is also the whole reason they live in
/// `PanelApp`'s outer Stack instead of inside the padded Column with
/// everything else — a tab inside the gutter is a button, and the shape
/// (rounded on the left, square on the right) would be lying about where it
/// comes from.
///
/// The shape is shared rather than copied because there are two of these now
/// and the pair has to read as a set: same width, same corner, same shadow,
/// only the glyph differs. A second hand-rolled Container would drift on the
/// first change to either.
class EdgeTab extends StatelessWidget {
  const EdgeTab({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;

  /// What a screen reader calls it. Not drawn: at this size a word would set
  /// the tab's width, and two tabs of different widths stop reading as a pair.
  final String label;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 18),
          decoration: BoxDecoration(
            color: PanelTheme.surfaceRaised,
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(16),
            ),
            boxShadow: PanelTheme.raised(8),
          ),
          child: Icon(icon, size: 22, color: PanelTheme.inkFaint),
        ),
      ),
    );
  }
}

/// The handle that opens the doorbell's Popup — the same Popup a ding raises
/// and a tap on the Dollhouse pin opens, reached without hunting for the pin.
///
/// Wears [deviceIcon]'s own answer for [DeviceKind.doorbell] rather than a
/// hand-picked glyph, so the tab and the pin on the Dollhouse can never come
/// to disagree about what a doorbell looks like — which is the whole reason
/// somebody scanning the wall knows this tab is about that Device.
class DoorbellTab extends StatelessWidget {
  const DoorbellTab({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => EdgeTab(
    icon: deviceIcon(DeviceKind.doorbell),
    label: 'Doorbell',
    onTap: onTap,
  );
}
