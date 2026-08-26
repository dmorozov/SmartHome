#!/usr/bin/env python3
"""Find the Wyze cameras on this LAN, and say whether any of them is
actually serving RTSP yet.

WHY THIS EXISTS. Phase 4's path A (Ch. 5 §2.2) was written as
write-then-check: put an `rtsp://` URL into
`~/.sh_keys/go2rtc/go2rtc.yaml`, restart go2rtc, then look at :1984. That
ordering puts a camera password into the live config *before* anything
knows the camera answers, and when the picture does not appear it cannot
tell you which half is wrong — the camera, the credentials, the URL path,
or the config. This asks the camera directly, first, and writes nothing
anywhere.

That is not a hypothetical. Bringing this fleet up on 2026-08-15, the
plan's URL was wrong in three independent ways at once — scheme, port and
path — and each wrong guess produced a *different* misleading symptom. The
worst is the path: with the right credentials and the wrong path, the
camera authenticates and then closes the connection saying nothing, which
looks exactly like a bad password. The way to tell them apart is to send a
deliberately WRONG password, which answers `401 Invalid Authorization` —
so a silent close means the credentials were ACCEPTED. `rtsp --probe-auth`
does that comparison for you.

TWO SUBCOMMANDS, matching the two questions the phase actually asks:

    wyze-fleet.py scan          which Wyze units are on this LAN, and is
                                any of them listening on an RTSP port?
    wyze-fleet.py rtsp HOST     does THIS camera serve a playable stream
                                with these credentials, and what is in it?

`scan` hardcodes no inventory. It sweeps this host's own subnet, keeps
every neighbour carrying Wyze Labs' OUI, and prints MAC alongside IP —
MAC because that is the identity the commissioning docs insist on
(Ch. 5 §2.1: two units swapped IPs inside three days before the DHCP
reservations of C1 existed). Match the MACs it prints against the A1
inventory table in `docs/plans/device-integrations/phase-4-cameras.md`
for the human names; this script deliberately does not carry a second
copy of that table.

CREDENTIALS ARE NEVER ARGUMENTS. The RTSP user and password are ones the
owner invents in the Wyze app, and a password typed as an argument lands
in shell history and in every `ps` on the box. They are read from the
environment (`WYZE_RTSP_USER` / `WYZE_RTSP_PASS`, e.g. sourced from
~/.sh_keys — ADR-0010) or prompted for, and no output path prints the
password: URLs are echoed with it replaced.

Standard library only, and no sudo: the neighbour table and a TCP
connect are all this needs. There is no ffprobe on this host.
"""

from __future__ import annotations

import argparse
import getpass
import hashlib
import ipaddress
import os
import re
import socket
import ssl
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

# Wyze Labs Inc, per the IEEE registry — the same lookup Ch. 5 §2.1
# records against /usr/share/ieee-data/oui.txt.
WYZE_OUI = "d0:3f:27"

# The ports a Wyze camera serves RTSP on once the toggle is enabled.
#
# 554 is the standard and 8554 is what a few builds and every bridge use —
# but on THIS fleet (v3, firmware 4.36.16.7064, toggle enabled 2026-08-15)
# the one that actually answers is 322, and it answers TLS: the cameras
# serve RTSPS, not plain RTSP. 554 is open on all five and replies to
# nothing at all, plaintext or TLS, which is the trap this constant exists
# to keep somebody out of — "554 is open" reads like success and is not.
RTSP_PORTS = (554, 8554, 322)

# Ports on which a listener is expected to be RTSPS rather than RTSP, so
# `scan` can say which of the two a camera is offering instead of leaving
# the reader to find out with a plaintext client that hangs.
TLS_PORTS = (322,)

# What the official RTSP firmware exposes. Kept as a default rather than
# a certainty — read the real one off the Wyze app's RTSP screen, which
# prints the whole URL.
DEFAULT_PATH = "/stream0"

# Per scheme, so that `--tls` alone is a working command: RTSPS is a
# different port, and leaving 554 under it would report "nothing is
# listening" about a camera that is.
DEFAULT_PORTS = {"rtsp": 554, "rtsps": 322}


# --------------------------------------------------------------------------
# scan
# --------------------------------------------------------------------------


def host_subnet() -> ipaddress.IPv4Network:
    """The subnet this host is on, read off the interface rather than
    typed. This LAN is a /22, which is 1022 addresses — worth knowing
    before wondering why the sweep takes a few seconds."""
    out = subprocess.run(
        ["ip", "-4", "-o", "addr", "show", "scope", "global"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 4 or parts[1].startswith(("docker", "br-", "veth")):
            continue
        return ipaddress.ip_network(parts[3], strict=False)
    raise SystemExit("no global IPv4 address on a non-container interface")


def sweep(net: ipaddress.IPv4Network) -> None:
    """Populate the neighbour cache. The replies are discarded — a device
    that ignores ICMP still answers ARP, and it is the ARP result this
    reads. Same trick as the two-liner in Ch. 5 §2.1, widened."""

    def one(ip: ipaddress.IPv4Address) -> None:
        subprocess.run(
            ["ping", "-c1", "-W1", str(ip)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    with ThreadPoolExecutor(max_workers=128) as pool:
        list(pool.map(one, net.hosts()))


def neighbours() -> list[tuple[str, str]]:
    """(ip, mac) for every neighbour carrying the Wyze OUI, IP-sorted."""
    out = subprocess.run(
        ["ip", "neigh", "show"], capture_output=True, text=True, check=True
    ).stdout
    found = []
    for line in out.splitlines():
        m = re.match(r"^(\S+)\s+dev\s+\S+\s+lladdr\s+(\S+)", line)
        if m and m.group(2).lower().startswith(WYZE_OUI):
            found.append((m.group(1), m.group(2).lower()))
    return sorted(set(found), key=lambda p: ipaddress.ip_address(p[0]))


def port_open(host: str, port: int, timeout: float = 2.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def cmd_scan(args: argparse.Namespace) -> int:
    net = ipaddress.ip_network(args.subnet, strict=False) if args.subnet else host_subnet()
    print(f"sweeping {net} ({net.num_addresses - 2} addresses) …", file=sys.stderr)
    sweep(net)

    units = neighbours()
    if not units:
        print(f"no {WYZE_OUI}:* neighbour on {net}")
        return 1

    print(f"{'IP':<16} {'MAC':<18} RTSP")
    serving = 0
    for ip, mac in units:
        open_ports = [p for p in RTSP_PORTS if port_open(ip, p)]
        if open_ports:
            serving += 1
            state = "listening on " + ", ".join(
                f"{p} (rtsps)" if p in TLS_PORTS else str(p) for p in open_ports
            )
        else:
            state = "no listener on " + "/".join(str(p) for p in RTSP_PORTS)
        print(f"{ip:<16} {mac:<18} {state}")

    print()
    print(f"{len(units)} Wyze unit(s); {serving} serving RTSP.")
    if not serving:
        # Say what the absence means, because the absence is the normal
        # state before anyone has touched the app and reads like a fault.
        print(
            "\nNone of them serves RTSP yet. That is what a camera looks like\n"
            "before the toggle is enabled — Wyze Cam v3 firmware ≥ 4.36.16.5654\n"
            "carries RTSP but ships it OFF (Ch. 5 §2.2). Enable it per camera in\n"
            "the Wyze app: the camera → Settings → Advanced Settings → RTSP,\n"
            "invent a user and password there, then re-run this."
        )
    return 0


# --------------------------------------------------------------------------
# rtsp
# --------------------------------------------------------------------------


class RtspError(Exception):
    pass


def _digest(header: str, method: str, uri: str, user: str, password: str) -> str:
    """RFC 2069/2617 Digest, MD5 only — which is all any camera in this
    class offers. Written out rather than pulled from a library because
    the whole point of this script is that it needs nothing installed."""
    fields = dict(re.findall(r'(\w+)="([^"]*)"', header))
    realm = fields.get("realm", "")
    nonce = fields.get("nonce", "")

    def md5(s: str) -> str:
        return hashlib.md5(s.encode()).hexdigest()

    ha1 = md5(f"{user}:{realm}:{password}")
    ha2 = md5(f"{method}:{uri}")
    response = md5(f"{ha1}:{nonce}:{ha2}")
    return (
        f'Digest username="{user}", realm="{realm}", nonce="{nonce}", '
        f'uri="{uri}", response="{response}"'
    )


def _basic(user: str, password: str) -> str:
    import base64

    return "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()


class RtspClient:
    def __init__(self, host: str, port: int, tls: bool, timeout: float = 6.0):
        self.uri_host = f"{host}:{port}"
        raw = socket.create_connection((host, port), timeout=timeout)
        if tls:
            # A camera serves RTSPS with its own self-signed certificate,
            # so verification is off by design here. This proves the
            # stream is reachable, not that the peer is trusted — and the
            # trust boundary for this system is the LAN (ADR-0008), not a
            # certificate.
            ctx = ssl._create_unverified_context()
            raw = ctx.wrap_socket(raw, server_hostname=host)
        self.sock = raw
        self.seq = 0
        self.buf = b""

    def request(self, method: str, uri: str, auth: str | None) -> tuple[int, dict, bytes]:
        self.seq += 1
        lines = [f"{method} {uri} RTSP/1.0", f"CSeq: {self.seq}", "User-Agent: wyze-fleet.py"]
        if auth:
            lines.append(f"Authorization: {auth}")
        if method == "DESCRIBE":
            lines.append("Accept: application/sdp")
        self.sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())

        while b"\r\n\r\n" not in self.buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RtspError("connection closed before a complete response")
            self.buf += chunk
        head, _, rest = self.buf.partition(b"\r\n\r\n")
        text = head.decode("latin-1")
        status = int(text.split(None, 2)[1])
        headers = {}
        for line in text.splitlines()[1:]:
            k, _, v = line.partition(":")
            headers[k.strip().lower()] = v.strip()

        length = int(headers.get("content-length", 0))
        while len(rest) < length:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RtspError("connection closed mid-body")
            rest += chunk
        self.buf = rest[length:]
        return status, headers, rest[:length]

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


def describe_media(sdp: str) -> list[str]:
    """The two or three lines of an SDP anybody actually needs: what
    media the camera offers and in what codec. `m=` names the medium and
    the payload type; the matching `a=rtpmap:` names the codec."""
    rtpmap = dict(re.findall(r"a=rtpmap:(\d+)\s+(\S+)", sdp))
    out = []
    for kind, _port, _proto, payloads in re.findall(
        r"m=(\w+)\s+(\d+)\s+(\S+)\s+(.*)", sdp
    ):
        codecs = [rtpmap.get(p, f"payload {p}") for p in payloads.split()]
        out.append(f"{kind}: {', '.join(codecs)}")
    return out


def cmd_rtsp(args: argparse.Namespace) -> int:
    if args.port is None:
        args.port = DEFAULT_PORTS["rtsps" if args.tls else "rtsp"]

    user = args.user or os.environ.get("WYZE_RTSP_USER") or input("RTSP user: ")
    password = os.environ.get("WYZE_RTSP_PASS") or getpass.getpass("RTSP password: ")
    if not user or not password:
        print("both a user and a password are needed", file=sys.stderr)
        return 2

    scheme = "rtsps" if args.tls else "rtsp"
    path = args.path if args.path.startswith("/") else "/" + args.path
    uri = f"{scheme}://{args.host}:{args.port}{path}"
    # Written the way the docs write it — the port only when it is not the
    # scheme's default, so what this prints can be pasted into
    # go2rtc.yaml beside Ch. 5 §2.2's `rtsp://user:pass@<cam-ip>/live`
    # without the two shapes drifting.
    authority = args.host if args.port == DEFAULT_PORTS[scheme] else f"{args.host}:{args.port}"
    # The only form of this URL that is ever printed.
    print(f"{scheme}://{user}:***@{authority}{path}")

    # ONE REQUEST PER CONNECTION. These cameras close the socket after
    # answering, so a client that pipelines DESCRIBE-after-401 on the same
    # connection reads EOF and blames the credentials. Measured 2026-08-15;
    # it is the difference between this tool working and this tool lying.
    def once(method: str, auth: str | None):
        client = RtspClient(args.host, args.port, args.tls)
        try:
            return client.request(method, uri, auth)
        finally:
            client.close()

    def describe_with(pw: str):
        """DESCRIBE, challenge, re-DESCRIBE — each on its own connection.
        Returns (status, body) with status None for a silent close."""
        try:
            status, headers, body = once("DESCRIBE", None)
            if status != 401 or "www-authenticate" not in headers:
                return status, body
            challenge = headers["www-authenticate"]
            auth = (
                _digest(challenge, "DESCRIBE", uri, user, pw)
                if challenge.lower().startswith("digest")
                else _basic(user, pw)
            )
            status, headers, body = once("DESCRIBE", auth)
            return status, body
        except (RtspError, OSError):
            return None, b""

    try:
        RtspClient(args.host, args.port, args.tls).close()
    except OSError as e:
        print(f"  connect    FAILED  {e}")
        print(
            "\nverdict: nothing is listening on this port. If RTSP is enabled in the\n"
            f"app, try the other transport — {'plain RTSP on 554' if args.tls else 'RTSPS with --tls (port 322)'}."
        )
        return 1

    status, body = describe_with(password)
    print(f"  DESCRIBE   {status if status is not None else '—':<5}"
          + (f"SDP {len(body)} bytes" if status == 200 else "connection closed with no reply"))

    if status == 200:
        for line in describe_media(body.decode("latin-1", "replace")):
            print(f"    {line}")
        print(
            "\nverdict: playable. Add it to ~/.sh_keys/go2rtc/go2rtc.yaml as TWO\n"
            "producers, not one (phase-4 §B1 — leave the second out and the\n"
            "appliance build gets HTTP 200 and zero bytes, silently). Note the\n"
            "`ffmpeg:` wrapper on the first: go2rtc 1.9.10's own RTSP client\n"
            "cannot talk TLS to these cameras, and ffmpeg can.\n"
            f"\n  wyze_<location>:\n"
            f"    - {'ffmpeg:' if args.tls else ''}{scheme}://<user>:<password>"
            f"@{authority}{path}{'#video=copy#audio=copy' if args.tls else ''}\n"
            "    - ffmpeg:wyze_<location>#video=mjpeg\n"
        )
        return 0

    if status == 401:
        print("\nverdict: serving RTSP, but it REFUSED these credentials.")
        print("Re-read the user and password off the Wyze app's RTSP screen.")
        return 1

    if status is not None:
        print(f"\nverdict: the camera answered DESCRIBE with {status}.")
        print(f"The path may be wrong — {path!r} was tried; the app prints the real one.")
        return 1

    # A silent close is ambiguous on its own, so ask the one question that
    # disambiguates it: does a KNOWN-WRONG password behave differently? A
    # camera that says 401 to nonsense and nothing to the real password has
    # accepted the password and objected to something else — in practice the
    # path. This comparison is the whole reason this subcommand exists.
    print("\n  disambiguating — re-running with a deliberately wrong password:")
    wrong_status, _ = describe_with("wrong-on-purpose-9x7")
    print(f"  DESCRIBE   {wrong_status if wrong_status is not None else '—':<5}"
          + ("(rejected, as it should be)" if wrong_status == 401 else "also closed"))

    if wrong_status == 401:
        print(
            "\nverdict: THE CREDENTIALS ARE CORRECT — a wrong password is refused with\n"
            "401 and yours is not. The camera accepted the login and then objected to\n"
            f"something else, and the usual something else is the PATH: {path!r} was\n"
            "tried. On this firmware it is /stream0 (main) or /stream1 (substream),\n"
            "not /live. Re-run with --path /stream0."
        )
    else:
        print(
            "\nverdict: the camera closes on everything, right password or wrong.\n"
            "That is not an authentication answer. Check that this is the RTSP port\n"
            "for this transport — these cameras leave 554 open and mute while serving\n"
            "RTSPS on 322 — and that the stream is still enabled in the app."
        )
    return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Credentials come from WYZE_RTSP_USER / WYZE_RTSP_PASS or a prompt, "
        "never from an argument.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_scan = sub.add_parser("scan", help="find Wyze units on the LAN and probe for RTSP")
    p_scan.add_argument(
        "--subnet", help="CIDR to sweep (default: this host's own, read off the interface)"
    )
    p_scan.set_defaults(func=cmd_scan)

    p_rtsp = sub.add_parser("rtsp", help="handshake with one camera's RTSP stream")
    p_rtsp.add_argument("host", help="camera IP, e.g. 192.168.68.57")
    p_rtsp.add_argument(
        "--port", type=int, default=None, help="default 554, or 322 with --tls"
    )
    p_rtsp.add_argument("--path", default=DEFAULT_PATH, help=f"default {DEFAULT_PATH}")
    p_rtsp.add_argument("--user", help="RTSP user (or WYZE_RTSP_USER)")
    p_rtsp.add_argument("--tls", action="store_true", help="RTSPS instead of RTSP")
    p_rtsp.set_defaults(func=cmd_rtsp)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
