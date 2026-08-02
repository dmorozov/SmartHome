#!/bin/sh
# Launch Sweet Home 3D with the Device marker properties editable.
#
#     panel/tool/sh3d.sh [file.sh3d]
#
# The file argument is forwarded but observed not to open the drawing on
# macOS 7.5 — the app starts empty. Use File > Open once it is up.
#
# Sweet Home 3D only shows an additional property in the *Modify furniture*
# dialog when the **Home** declares it, and a Home learns its declarations
# from exactly one place: this system property, read at startup by
# `SweetHome3D` and split on `,\s*`. It is never written to the .sh3d, so
# it has to be set on every launch — hence this script rather than a note
# in a README.
#
# Without it the markers still carry `placementKey` and `kind` (the
# catalog declares them, and `createHomePieceOfFurniture` copies them onto
# the placed piece), but nothing in the UI will show or edit them: the
# dialog, the room dialog and Furniture > Display column are all driven by
# the Home's list.
#
# Bare names on purpose. `ObjectProperty.fromDescription` already defaults
# displayable, modifiable and exportable to true, and its attribute parser
# has an off-by-one — `substring("modifiable=".length() + 1)` reads "rue"
# rather than "true" — so spelling `modifiable=true` out loud would set it
# **false**. A `:STRING` suffix is safe; the boolean attributes are not.
#
# Pair with tool/sh3d_marker_library.py, which is what puts the markers in
# the catalog in the first place.

set -e

APP="${SH3D_APP:-/Applications/Sweet Home 3D.app}"
BIN="$APP/Contents/MacOS/SweetHome3D"

if [ ! -x "$BIN" ]; then
  echo "Sweet Home 3D not found at $APP" >&2
  echo "Install it (brew install --cask sweet-home3d) or set SH3D_APP." >&2
  exit 1
fi

# JAVA_TOOL_OPTIONS is read by the JVM itself, so it works through the
# jpackage launcher without touching the installed bundle.
JAVA_TOOL_OPTIONS="-Dcom.eteks.sweethome3d.additionalFurnitureProperties=placementKey,kind" \
  exec "$BIN" "$@"
