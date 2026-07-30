#!/usr/bin/env bash
#
# bootstrap.sh — build the Flutter-under-cage spike app on the Linux laptop.
#
# Runbook: ../docs/research/flutter-cage-spike.md (Step 5 build, Step 6 run).
#
# What it does, from spike/app/:
#   1. Verifies Flutter >= 3.44 is on PATH. The Wayland touch regression
#      (flutter/flutter#182606) is fixed in 3.44.0 stable — a 3.41.x
#      toolchain must never be used.
#   2. Generates the Linux runner: flutter create --platforms=linux .
#   3. Restores the repo-owned lib/, pubspec.yaml, analysis_options.yaml in
#      case flutter create overwrote them.
#   4. Patches linux/runner/my_application.cc for kiosk use (runbook Step 5):
#      HeaderBar off, gtk_window_fullscreen() before the window is shown.
#   5. Builds the release bundle: flutter build linux --release.
#
# Safe to re-run: both runner patches are idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$SCRIPT_DIR/app"
RUNBOOK="docs/research/flutter-cage-spike.md"
RUNNER="linux/runner/my_application.cc"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Linux" ]] \
  || die "flutter build linux only works on Linux hosts (runbook section 2, build logistics). Run this on the laptop."
[[ -f "$APP_DIR/pubspec.yaml" ]] \
  || die "expected $APP_DIR/pubspec.yaml — run from a checkout of the SmartHome repo."

cd "$APP_DIR"

# --- 1. Flutter present and >= 3.44 ----------------------------------------

say "Checking the Flutter toolchain"
command -v flutter >/dev/null 2>&1 || die "flutter is not on PATH.
Install per the runbook ($RUNBOOK, Step 5):
  git clone -b stable https://github.com/flutter/flutter.git ~/flutter
  export PATH=\"\$HOME/flutter/bin:\$PATH\""

VERSION="$(flutter --version --machine 2>/dev/null \
  | sed -n 's/.*"frameworkVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | head -n1 || true)"
if [[ -z "$VERSION" ]]; then
  # Fallback: parse the human banner ("Flutter 3.44.8 • channel stable ...").
  VERSION="$(flutter --version 2>/dev/null \
    | awk '/^Flutter [0-9]/ {print $2; exit}' || true)"
fi
[[ -n "$VERSION" ]] || die "could not parse 'flutter --version' output.
If flutter itself errored above (e.g. 'Unable to extract Dart SDK'), the SDK
bootstrap tools may be missing — run appliance/scripts/install-kiosk.sh, or:
  sudo apt install -y curl git unzip zip xz-utils"

MAJOR="${VERSION%%.*}"
REST="${VERSION#*.}"
MINOR="${REST%%.*}"
[[ "$MAJOR" =~ ^[0-9]+$ && "$MINOR" =~ ^[0-9]+$ ]] \
  || die "unparseable Flutter version '$VERSION'."
if (( MAJOR < 3 || (MAJOR == 3 && MINOR < 44) )); then
  die "Flutter $VERSION is too old — need >= 3.44 (Wayland touch fix, flutter/flutter#182606; 3.41.x is broken).
Install per the runbook ($RUNBOOK, Step 5):
  git clone -b stable https://github.com/flutter/flutter.git ~/flutter
  export PATH=\"\$HOME/flutter/bin:\$PATH\""
fi
say "Flutter $VERSION OK (>= 3.44)"

# --- 2. Generate the Linux runner ------------------------------------------

# Fail early: step 3's git restore requires these files to be committed. An
# untracked scaffold would otherwise abort mid-script, after mutations began.
git ls-files --error-unmatch lib/main.dart pubspec.yaml analysis_options.yaml .gitignore \
  >/dev/null 2>&1 \
  || die "spike/app is not committed to git yet — commit the scaffold first
(the repo-owned-file restore in step 3 depends on 'git checkout')."

say "Generating the Linux runner (flutter create)"
flutter create --platforms=linux --project-name spike_app .

# --- 3. Restore repo-owned files -------------------------------------------

say "Restoring repo-owned files flutter create may have overwritten"
git checkout -- lib pubspec.yaml analysis_options.yaml .gitignore
# The generated template test targets the template's MyApp, which this app
# does not define, and the generated in-app README is template noise; the
# spike's real README lives one level up (spike/README.md).
rm -f test/widget_test.dart README.md

# --- 4. Patch the runner for kiosk use -------------------------------------

say "Patching $RUNNER (runbook Step 5)"

manual_patch_help() {
  cat >&2 <<EOF
ERROR: expected pattern not found in $RUNNER — the Flutter runner template
has changed. Apply the runbook ($RUNBOOK, Step 5) edit manually, in
my_application_activate():

  1. Disable the HeaderBar branch (the 'if (use_header_bar)' that creates a
     GtkHeaderBar) so the plain gtk_window_set_title(...) path runs — the
     default runner draws a client-side titlebar under cage.
  2. Add, before the window/view is shown:
       gtk_window_fullscreen(GTK_WINDOW(window));

Then re-run this script; patches already applied are skipped.
EOF
}

if grep -q 'gboolean use_header_bar = FALSE;' "$RUNNER"; then
  say "HeaderBar already disabled — skipping"
else
  grep -q 'gboolean use_header_bar = TRUE;' "$RUNNER" \
    || { manual_patch_help; exit 1; }
  sed -i 's/gboolean use_header_bar = TRUE;/gboolean use_header_bar = FALSE;/' \
    "$RUNNER"
  say "HeaderBar disabled (no client-side titlebar under cage)"
fi

if grep -q 'gtk_window_fullscreen(GTK_WINDOW(window));' "$RUNNER"; then
  say "gtk_window_fullscreen() already present — skipping"
else
  grep -q 'gtk_window_set_default_size' "$RUNNER" \
    || { manual_patch_help; exit 1; }
  # Insert the fullscreen call right after set_default_size — i.e. before
  # gtk_widget_show / view realization — preserving indentation.
  sed -i 's/^\([[:space:]]*\)\(gtk_window_set_default_size.*\)$/\1\2\n\1gtk_window_fullscreen(GTK_WINDOW(window));/' \
    "$RUNNER"
  say "gtk_window_fullscreen() inserted after gtk_window_set_default_size"
fi

# --- 5. Build ---------------------------------------------------------------

say "Building the release bundle"
flutter build linux --release

# Flutter names the output dir after the host arch (x64 on the real laptop
# and mini PC; arm64 e.g. in the arm64 test container on Apple Silicon).
case "$(uname -m)" in
  x86_64)  FLUTTER_ARCH=x64 ;;
  aarch64) FLUTTER_ARCH=arm64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac
BUNDLE="$APP_DIR/build/linux/$FLUTTER_ARCH/release/bundle/spike_app"
[[ -x "$BUNDLE" ]] || die "build finished but $BUNDLE is missing."

# --- Done: how to run (runbook Step 6) --------------------------------------

cat <<EOF

============================================================
Build complete:
  $BUNDLE

Run under cage from a LOCAL TTY — not SSH; cage needs the seat
(runbook Step 6). If GNOME is running first: sudo systemctl stop gdm

  cage -- $BUNDLE

Then repeat the whole touch battery over XWayland (the #182606
repro path — both backends must pass):

  GDK_BACKEND=x11 cage -- $BUNDLE

Hybrid-GPU laptop (runbook Step 0a): cage must NEVER open the
NVIDIA card. Pin it to the amdgpu iGPU:

  readlink /sys/class/drm/card*/device/driver   # find the amdgpu cardN
  WLR_DRM_DEVICES=/dev/dri/card<N> cage -- $BUNDLE

Work through the 13-item pass/fail checklist: $RUNBOOK section 4.
============================================================
EOF
