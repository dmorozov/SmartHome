# The development toolchain, containerized so it stops drifting from the
# target box. Base is Ubuntu 24.04 on purpose: the root README's
# architecture table keeps the mini PC target on Ubuntu Server 24.04 LTS —
# the 26.04 dev laptop is the interim Hub host (ADR-0008), not the target.
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# Pinned to the exact version the dev laptop runs (Dart 3.12.2, which is
# also pubspec.yaml's sdk floor). The pin is load-bearing beyond "same
# compiler": golden images load Roboto/MaterialIcons out of the SDK's own
# cache, so only machines on one Flutter version render identical goldens
# (panel/test/golden/golden_setup.dart).
ARG FLUTTER_VERSION=3.44.8

# One apt layer, grouped by why each package is here:
#  - curl/git/unzip/xz-utils/zip: Flutter SDK's own prerequisites.
#  - clang/cmake/ninja-build/pkg-config/libgtk-3-dev/build-essential: the
#    `flutter build linux` toolchain — the same set G4 verified on the Hub
#    host, so a build that passes here passes there.
#  - xvfb: headless runs of the Linux build (the G4 pattern: Xvfb :99 +
#    LIBGL_ALWAYS_SOFTWARE=1), since a container has no display.
#  - mosquitto-clients: mosquitto_sub/pub against the dev broker.
#  - ffmpeg: ffprobe for checking go2rtc/RTSP streams (hub/dev/README.md).
#  - python3: panel/tool's Sweet Home 3D converter and its test suite —
#    without it, house_pipeline_contract_test silently skips.
#  - jq: JSON spelunking in HA's REST answers.
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get install -y --no-install-recommends \
        curl git unzip xz-utils zip ca-certificates \
        clang cmake ninja-build pkg-config libgtk-3-dev build-essential \
        xvfb \
        mosquitto-clients \
        ffmpeg \
        python3 \
        jq \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Chrome, for `flutter run -d chrome`, headless web screenshots
# (panel/tool/shot.sh reads $CHROME), and anything else that wants a real
# browser engine in the loop. Google ships no linux/arm64 build, so on an
# Apple-silicon Mac this is skipped: the documented dev flow there is
# `flutter run -d web-server` + the host's own browser, which needs no
# browser in the container at all (post-create.sh prints it).
RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
        curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
            | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg \
        && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
            > /etc/apt/sources.list.d/google-chrome.list \
        && apt-get update \
        && apt-get install -y --no-install-recommends google-chrome-stable \
        && apt-get clean && rm -rf /var/lib/apt/lists/*; \
    else \
        echo "arm64: skipping Chrome (no Linux build exists); use -d web-server + the host browser"; \
    fi
# Harmless when Chrome was skipped: nothing dereferences these on arm64
# without printing the shot.sh "set CHROME=" hint first.
ENV CHROME_EXECUTABLE=/usr/bin/google-chrome-stable \
    CHROME=/usr/bin/google-chrome-stable

# The SDK lives in the image, owned by the login user so `flutter upgrade`
# is at least mechanically possible (policy says don't: bump ARG
# FLUTTER_VERSION and rebuild instead, so every machine moves together).
RUN git clone --depth 1 --branch "${FLUTTER_VERSION}" \
        https://github.com/flutter/flutter.git /opt/flutter \
    && chown -R vscode:vscode /opt/flutter \
    # Pre-created so the named volumes (compose.yaml) inherit vscode
    # ownership on first mount instead of arriving root-owned. The second is
    # Playwright's browser cache — post-create.sh fills it, because npm
    # arrives with a devcontainer FEATURE and features are layered on top of
    # this image after it is built.
    && mkdir -p /home/vscode/.pub-cache /home/vscode/.cache/ms-playwright \
    && chown -R vscode:vscode /home/vscode/.pub-cache /home/vscode/.cache

# FLUTTER_ROOT is golden_setup.dart's first route to material_fonts; when
# unset it falls back to walking up from the test-runner binary, and its
# deliberately loud StateError fires only if both routes come up empty.
ENV FLUTTER_ROOT=/opt/flutter \
    PUB_CACHE=/home/vscode/.pub-cache \
    PATH="${PATH}:/opt/flutter/bin:/home/vscode/.pub-cache/bin"

USER vscode

# Download the engine artifacts at build time so the first `flutter run`
# isn't a surprise download, then PROVE the golden fonts landed — a missing
# material_fonts cache should fail this build, not a golden run weeks later.
RUN flutter --version \
    && flutter precache --linux --web \
    # analytics opt-out only; tolerated on failure so a flag rename in a
    # future SDK can't break the image build
    && (flutter config --no-analytics || true)
RUN test -d /opt/flutter/bin/cache/artifacts/material_fonts \
    || { echo "material_fonts missing from the SDK cache — goldens would render placeholder boxes"; exit 1; }
