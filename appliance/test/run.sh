#!/usr/bin/env bash
# run.sh — lifecycle of the Test Appliance container (see Dockerfile, README.md).
#
#   ./run.sh up        build image (if needed) + (re)create + start + inject SSH key
#   ./run.sh reset     dispose the container and create a fresh one (same image)
#   ./run.sh rebuild   rebuild the image from the Dockerfile, then reset
#   ./run.sh ssh       open a shell in the container over real SSH
#   ./run.sh destroy   remove container (image and keys stay)
#
# Which Ubuntu it models: UBUNTU_TAG, default 24.04 — the production mini
# PC's OS (ADR-0001) and the only Appliance with no hardware to converge.
#   UBUNTU_TAG=26.04 ./run.sh rebuild   models the 26.04 dev laptop instead.
# One flavour at a time: the images are tagged apart, the container name and
# port 2222 are shared.
#
# The container is DISPOSABLE by design: deployment scripts are debugged by
# reset-and-rerun, never by hand-fixing container state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

UBUNTU_TAG="${UBUNTU_TAG:-24.04}"   # 24.04 = mini PC (ADR-0001); 26.04 = dev laptop
IMAGE="smarthome-appliance-test:${UBUNTU_TAG}"

# Whether to hand the container the HOST's Docker socket. Default OFF, and the
# default changed on 2026-08-07 — phase-0 open item 15.
#
# It used to be unconditional, and it was harmless when it was written: the dev
# box was a Mac, so that socket belonged to Docker Desktop's disposable Linux
# VM and "the host's daemon" meant a throwaway. It is not a throwaway now. The
# same laptop is the Hub host (ADR-0008), so from phase 1 onward that socket is
# root-equivalent access to the daemon running Home Assistant, Mosquitto,
# ring-mqtt and go2rtc — handed to a `--privileged` container whose entire
# purpose is executing deployment code under debug.
#
# Nothing in the test bed's own job needs it: the Ansible playbooks reach this
# container over SSH like any host, and `spike/bootstrap.sh` does not use
# Docker. What the mount buys is the debugging convenience README.md
# describes — `docker ps` inside showing sibling containers — so it stays
# available, behind a name you have to type:
#
#   TEST_DOCKER_SOCKET=1 ./run.sh up
#
# Only do that when the Hub stack is down, or on a machine that is not the Hub.
TEST_DOCKER_SOCKET="${TEST_DOCKER_SOCKET:-0}"
CONTAINER=smarthome-test
SSH_PORT=2222
KEY_DIR="${SCRIPT_DIR}/.keys"          # gitignored
KEY="${KEY_DIR}/id_ed25519"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker not found on PATH."

build_image() {
    say "Building image ${IMAGE} (Ubuntu ${UBUNTU_TAG})"
    docker build --build-arg "UBUNTU_TAG=${UBUNTU_TAG}" -t "${IMAGE}" "${SCRIPT_DIR}"
}

ensure_image() {
    docker image inspect "${IMAGE}" >/dev/null 2>&1 || build_image
}

ensure_key() {
    if [[ ! -f "${KEY}" ]]; then
        say "Generating dedicated SSH keypair (gitignored: appliance/test/.keys/)"
        mkdir -p "${KEY_DIR}"
        ssh-keygen -t ed25519 -N '' -C smarthome-appliance-test -f "${KEY}"
    fi
}

destroy() {
    if docker container inspect "${CONTAINER}" >/dev/null 2>&1; then
        say "Removing container ${CONTAINER}"
        docker rm -f "${CONTAINER}" >/dev/null
    fi
}

up() {
    ensure_image
    ensure_key
    destroy

    say "Starting ${CONTAINER} from ${IMAGE} (systemd PID 1; SSH on localhost:${SSH_PORT})"

    # The socket mount is opt-in — see TEST_DOCKER_SOCKET at the top for why
    # the default flipped. Target is /docker.sock, not the conventional
    # /var/run/docker.sock, because systemd's tmpfs over /run would shadow the
    # bind (DOCKER_HOST is set image-wide to match).
    local socket_mount=()
    if [ "${TEST_DOCKER_SOCKET}" != "0" ]; then
        if docker ps --format '{{.Names}}' | grep -qE '^(homeassistant|mosquitto|go2rtc|ring-mqtt)$'; then
            die "TEST_DOCKER_SOCKET=1 refused: the Hub stack is running on this
  daemon, and the mount would give a --privileged test container
  root-equivalent control of it (phase-0 item 15). Stop the Hub stack first,
  or run the test bed on a machine that is not the Hub."
        fi
        say "TEST_DOCKER_SOCKET is set — exposing the host daemon at /docker.sock"
        socket_mount=(-v /var/run/docker.sock:/docker.sock)
    fi

    # --privileged + cgroup mount: required for systemd as PID 1. The repo is
    # mounted read-only; tests clone from it (bootstrap.sh's git guard needs a
    # real clone, and ro keeps the test from ever mutating the working tree).
    docker run -d \
        --name "${CONTAINER}" \
        --hostname appliance-test \
        --privileged \
        --cgroupns=host \
        -v /sys/fs/cgroup:/sys/fs/cgroup \
        "${socket_mount[@]}" \
        -v "${REPO_ROOT}:/mnt/SmartHome-src:ro" \
        -p "${SSH_PORT}:22" \
        "${IMAGE}" >/dev/null

    say "Waiting for systemd + sshd"
    for _ in $(seq 1 30); do
        if docker exec "${CONTAINER}" systemctl is-active ssh >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    docker exec "${CONTAINER}" systemctl is-active ssh >/dev/null 2>&1 \
        || die "sshd did not come up; check: docker logs ${CONTAINER}"

    say "Injecting SSH public key for user 'ubuntu'"
    docker exec "${CONTAINER}" install -d -m 0700 -o ubuntu -g ubuntu /home/ubuntu/.ssh
    docker cp "${KEY}.pub" "${CONTAINER}:/home/ubuntu/.ssh/authorized_keys"
    docker exec "${CONTAINER}" sh -c \
        'chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys && chmod 0600 /home/ubuntu/.ssh/authorized_keys'

    # The ro repo mount is owned by an alien uid — git refuses it without this.
    docker exec -u ubuntu "${CONTAINER}" \
        git config --global --add safe.directory /mnt/SmartHome-src

    say "Ready. Connect with:  ${SCRIPT_DIR}/run.sh ssh"
    echo "    (raw: ssh -i ${KEY} -p ${SSH_PORT} -o StrictHostKeyChecking=no ubuntu@localhost)"
    echo "    Repo mounted read-only at /mnt/SmartHome-src — clone it inside:"
    echo "    git clone /mnt/SmartHome-src ~/SmartHome"
}

case "${1:-}" in
    up)      up ;;
    reset)   up ;;                       # up already disposes + recreates
    rebuild) build_image; up ;;
    destroy) destroy; say "Destroyed." ;;
    ssh)
        [[ -f "${KEY}" ]] || die "no key yet — run: $0 up"
        exec ssh -i "${KEY}" -p "${SSH_PORT}" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            ubuntu@localhost "${@:2}"
        ;;
    *)
        sed -n '2,17p' "$0"; exit 1 ;;
esac
