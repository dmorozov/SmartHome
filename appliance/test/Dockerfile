# Test Appliance — Ubuntu with systemd + sshd, for exercising the Appliance
# deployment tooling (appliance/ansible/ over real SSH, spike/bootstrap.sh)
# without the real laptop/mini PC.
#
# WHICH Ubuntu — build arg UBUNTU_TAG, default 24.04. That default is
# deliberate and is NOT "whatever the Hub host runs". This container stands
# in for an *Appliance*, and there are two:
#   24.04 LTS  the production mini PC (ADR-0001). Not purchased yet, so this
#              container is its ONLY pre-flight. Hence the default.
#   26.04 LTS  the dev laptop since 2026-08-03. That box is real, reachable
#              and safe to converge directly (every kiosk gate defaults
#              false), so it needs no stand-in — but
#              `UBUNTU_TAG=26.04 ./run.sh rebuild` reproduces it when a
#              failure is suspected to be OS-specific.
# Both resolve every package below and in group_vars/all.yml (checked
# 2026-08-03 on the 26.04 host; libstdc++-12-dev is still in 26.04 universe
# at 12.5.0 even though gcc 15 is the default compiler).
#
# What this image deliberately does NOT preinstall: the kiosk package set,
# the cage user, the systemd units — installing those is the ansible kiosk
# role's job, and this container exists to test it from a clean slate.
#
# Cannot test here (needs the real Appliance): cage compositing (no GPU/DRM
# seat), touch input, boot-to-TTY/gdm, screen power. Nor the HWE-kernel task,
# at any UBUNTU_TAG: host_vars/test-appliance.yml pins kiosk_hwe_kernel to
# false, so that task is always skipped here. See README.md.

ARG UBUNTU_TAG=24.04
FROM ubuntu:${UBUNTU_TAG}

ENV DEBIAN_FRONTEND=noninteractive

# systemd as PID 1 + SSH + the bare minimum a fresh Appliance would have.
# docker.io provides the docker CLI for the host-socket bind; its daemon and
# containerd are masked below — the host's daemon is the only one in play.
RUN apt-get update && apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus \
        openssh-server sudo git ca-certificates curl less nano \
        python3 python3-apt \
        docker.io \
    && rm -rf /var/lib/apt/lists/* \
    && systemctl mask docker.service containerd.service \
    && systemctl enable ssh

# The base image ships the 'ubuntu' user (uid 1000) — added in noble and kept
# by later releases; it plays the admin-over-SSH role the real Appliance will
# have. run.sh's key injection and host_vars/test-appliance.yml both assume
# it exists: after a first build on a NEW UBUNTU_TAG, confirm with
# `docker exec smarthome-test id ubuntu`. Key-only SSH; the key is injected
# at 'run.sh up' time (never baked into the image).
# The host docker socket is bound at /docker.sock — NOT /var/run/docker.sock,
# because systemd mounts a tmpfs over /run at boot and would shadow it there.
RUN usermod -aG docker ubuntu 2>/dev/null || true; \
    printf 'ubuntu ALL=(ALL) NOPASSWD:ALL\nDefaults env_keep += "DOCKER_HOST"\n' \
        > /etc/sudoers.d/90-ubuntu-test \
    && chmod 0440 /etc/sudoers.d/90-ubuntu-test \
    && printf 'export DOCKER_HOST=unix:///docker.sock\n' \
        > /etc/profile.d/docker-host.sh \
    && printf 'DOCKER_HOST=unix:///docker.sock\n' >> /etc/environment \
    && printf 'PermitRootLogin no\nPasswordAuthentication no\n' \
        > /etc/ssh/sshd_config.d/60-test.conf

# systemd containers stop cleanly on SIGRTMIN+3, not SIGTERM.
STOPSIGNAL SIGRTMIN+3

CMD ["/lib/systemd/systemd"]
