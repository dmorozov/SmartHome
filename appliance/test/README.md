# Test Appliance (Docker)

A disposable Ubuntu container with **systemd as PID 1** and **real SSH**, for
exercising the Appliance deployment tooling without the laptop/mini PC: the
Ansible playbooks (`../ansible/`, targeting it over SSH exactly like a real
host) and `spike/bootstrap.sh`.

## Which Ubuntu — 24.04 by default, and that is not an oversight

This container stands in for an **Appliance**, not for the Hub host (it tests
no part of `hub/compose.yaml` — see the caveat at the end). There are two
Appliances and they no longer share an OS:

| Appliance | OS | Needs a stand-in? |
|---|---|---|
| Production mini PC | Ubuntu Server **24.04 LTS** (ADR-0001) | **Yes** — not purchased yet, so this container is its only pre-flight |
| Dev laptop | Ubuntu **26.04 LTS** (upgraded 2026-08-03) | No — it is real, reachable, and a plain converge is safe there (every kiosk gate defaults `false`) |

So the default models the mini PC. Model the laptop when a failure looks
OS-specific, or to isolate one from the laptop's GNOME/daily-driver state:

```sh
UBUNTU_TAG=26.04 ./run.sh rebuild   # one flavour at a time: the images are
                                    # tagged apart, the container name and
                                    # port 2222 are shared
```

Neither flavour exercises the HWE-kernel task — `host_vars/test-appliance.yml`
sets `kiosk_hwe_kernel: false`, because a kernel package is meaningless in a
container. Kernel-meta names must be checked on a real host with
`apt-cache policy`, never here.

Debug loop: scripts are fixed in the repo and re-tested by **reset-and-rerun**
(`./run.sh reset`) — never by hand-fixing container state.

## What it can and cannot test

| Deployment logic — ✅ testable here | Hardware behavior — ❌ needs the real Appliance |
|---|---|
| Package set installs on a clean base (24.04 or 26.04) | cage actually compositing (no GPU/DRM seat) |
| `cage` user creation, unit/PAM installs | Touch input end-to-end |
| systemd unit syntax, `daemon-reload`, enable | Boot-to-TTY, getty eviction, gdm interplay |
| Flutter toolchain + `flutter build linux` | Rendering, fling/pinch behavior |
| `bootstrap.sh` seds, git guard, idempotency | Screen blank/wake, DDC/CI |
| Ansible plays over real SSH (the tested path) | Hybrid-GPU pinning; the HWE-kernel task (`kiosk_hwe_kernel: false`) |

## Usage

```sh
./run.sh up        # build (first time) + create + start + inject SSH key
./run.sh ssh       # shell in over real SSH (what Ansible will use later)
./run.sh reset     # dispose + fresh container (same image)
./run.sh rebuild   # image rebuilt from Dockerfile, then reset
./run.sh destroy   # remove the container
```

Inside, the repo is mounted read-only at `/mnt/SmartHome-src`; test against a
clone (`bootstrap.sh`'s git guard requires one, and the ro mount protects the
working tree):

```sh
# provision from the Mac side:  cd appliance/ansible && ansible-playbook site.yml -l test-appliance
# then inside (./run.sh ssh):
git clone /mnt/SmartHome-src ~/SmartHome
~/SmartHome/spike/bootstrap.sh        # long: clones Flutter + release build
```

## macOS notes (Docker Desktop)

- Containers run in Docker Desktop's Linux VM; systemd as PID 1 needs the
  `--privileged` + `/sys/fs/cgroup` mount that `run.sh` passes.
- The host docker socket is bind-mounted at `/docker.sock` (with `DOCKER_HOST`
  set image-wide), so `docker ps` inside shows the **host's** daemon —
  containers started from inside are siblings, visible and debuggable from the
  Mac. It cannot live at the conventional `/var/run/docker.sock`: systemd
  mounts a tmpfs over `/run` at boot and would shadow the bind.
- Caveat for later hub-stack testing via that socket: bind-mount paths in a
  `compose.yaml` run from inside resolve against the VM/host filesystem, not
  this container's — revisit when the hub compose gets tested this way.
- SSH: `run.sh up` generates a dedicated keypair in `.keys/` (gitignored) and
  injects the public half; `PasswordAuthentication no`, root login disabled.
