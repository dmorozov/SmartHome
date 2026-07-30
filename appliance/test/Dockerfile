# Test Appliance — Ubuntu 24.04 with systemd + sshd, for exercising the
# deployment tooling (appliance/scripts/*, later the Ansible playbooks)
# without the real laptop/mini PC.
#
# What this image deliberately does NOT preinstall: the kiosk package set,
# the cage user, the systemd units — installing those is install-kiosk.sh's
# job, and this container exists to test that script from a clean slate.
#
# Cannot test here (needs the real Appliance): cage compositing (no GPU/DRM
# seat), touch input, boot-to-TTY/gdm, screen power. See README.md.

FROM ubuntu:24.04

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

# The noble base image ships the 'ubuntu' user (uid 1000) — it plays the
# admin-over-SSH role the real Appliance will have. Key-only SSH; the key is
# injected at 'run.sh up' time (never baked into the image).
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
