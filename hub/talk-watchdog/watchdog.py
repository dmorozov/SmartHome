#!/usr/bin/env python3
"""Dead-man switch for Ring talkback.

go2rtc has no idle timeout on internal producers. Nothing reaps a wedged
microphone or an orphaned consumer, and both hold the doorbell in live view on
somebody's battery — a leaked `curl` once did it for ~30 minutes and 160 MB
before a routine `/api/streams` dump found it
(`hub/dev/ring-twoway-lab/RESULTS.md` §"INCIDENT").

This runs beside go2rtc and enforces three things the Panel cannot guarantee
about itself, because the Panel can die:

  1. an absolute cap on how long the microphone may stay hot;
  2. a stop at startup, to clear whatever a crash left open;
  3. a stop on SIGTERM.

It also *detects* two conditions it cannot fix, and says so loudly rather than
pretending otherwise — see "What this cannot do" in README.md.

Stdlib only, on purpose: it has to be the least likely thing in the stack to
break.
"""

import json
import os
import re
import signal
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# go2rtc's /api/streams response embeds the producer URL, and for `ring:` that
# URL carries the live Ring refresh token. Two accidental leaks have already
# cost a re-mint, so nothing reaches stdout without passing through this.
_TOKEN = re.compile(r'(refresh_token=)[^&"\s]*')


def redact(text):
    return _TOKEN.sub(r"\1<REDACTED>", text)


def log(event, **fields):
    fields["event"] = event
    fields["ts"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print(redact(json.dumps(fields, sort_keys=True)), flush=True)


class Config:
    """Everything tunable, from the environment."""

    def __init__(self, env=None):
        env = os.environ if env is None else env
        self.base = env.get("GO2RTC", "http://go2rtc:1984").rstrip("/")
        # The stream talkback is pushed INTO (Ring's backchannel destination).
        self.talk_stream = env.get("TALK_STREAM", "ring")
        # The stream talkback is pushed FROM. Its producer going live is the
        # signal that the microphone is hot — see _talking().
        self.mic_stream = env.get("MIC_STREAM", "mic")
        self.cap_s = float(env.get("TALK_CAP_S", "45"))
        self.poll_s = float(env.get("POLL_S", "2"))
        # Consecutive polls a condition must hold before it is believed.
        self.stale_polls = int(env.get("STALE_POLLS", "5"))
        self.timeout_s = float(env.get("HTTP_TIMEOUT_S", "5"))


# --- reading go2rtc -------------------------------------------------------
#
# Field shapes below were read off a live go2rtc 1.9.10 on 2026-08-09, not
# assumed. A stream object is {"producers": [...], "consumers": [...]}, and
# either list may be absent or null.


def producer_live(producer):
    """True when this producer is actually connected to its source.

    The producer entry ALWAYS exists — it is the configured source, and when
    idle it carries only `url`. It is live only once go2rtc has dialled, at
    which point it gains `id`, `sdp` and `remote_addr`. Testing for the
    producer *object* would report every configured stream as connected.
    """
    return producer.get("id") is not None


def stream_live(stream):
    return any(producer_live(p) for p in stream.get("producers") or [])


def consumers_of(stream):
    return stream.get("consumers") or []


class Client:
    """The two verbs this service is allowed to use.

    🔴 GET and POST only. `PUT` and `DELETE` on /api/streams are
    `delete(streams, src)` + `app.PatchConfig(...)`: they rewrite go2rtc.yaml
    on disk — including the Ring token in it — and stop no producer at all.
    """

    def __init__(self, cfg):
        self._cfg = cfg

    def streams(self):
        url = self._cfg.base + "/api/streams"
        with urllib.request.urlopen(url, timeout=self._cfg.timeout_s) as r:
            return json.loads(r.read().decode())

    def stop_talk(self):
        """The stop call. Idempotent — verified 40/40 returning 200."""
        query = urllib.parse.urlencode({"dst": self._cfg.talk_stream, "src": ""})
        req = urllib.request.Request(
            self._cfg.base + "/api/streams?" + query, data=b"", method="POST"
        )
        with urllib.request.urlopen(req, timeout=self._cfg.timeout_s) as r:
            return r.status


# --- deciding -------------------------------------------------------------


class Watchdog:
    """Pure decision layer: state in, actions out, no I/O.

    `evaluate()` takes the parsed /api/streams body and the current time and
    returns a list of (action, detail) pairs for the caller to perform. Keeping
    the I/O out is what lets the whole policy be tested without a doorbell.
    """

    def __init__(self, cfg):
        self._cfg = cfg
        self._talk_since = None
        self._sent = {}  # consumer id -> last bytes_send
        self._stale = {}  # consumer id -> consecutive polls unchanged
        self._orphan_polls = 0

    def _talking(self, streams):
        """Is the microphone hot?

        Keyed on the mic stream's producer being live, NOT on a `sendonly`
        audio media on the ring producer. Two reasons: `medias` strings carry
        `sendonly` on ordinary inbound *consumers* too (a plain RTSP listener
        reports `"audio, sendonly, ANY"`), and the ring producer's SDP offer
        advertises the backchannel whether or not anything is pushing into it.
        The mic producer going live means an ffmpeg is capturing the
        microphone, which is the condition this service exists to bound.
        """
        return stream_live(streams.get(self._cfg.mic_stream) or {})

    def evaluate(self, streams, now):
        actions = []
        talking = self._talking(streams)
        talk = streams.get(self._cfg.talk_stream) or {}

        # 1. Absolute cap on a hot microphone.
        if talking:
            if self._talk_since is None:
                self._talk_since = now
                log("talk_started")
            held = now - self._talk_since
            if held >= self._cfg.cap_s:
                actions.append(("stop", {"reason": "cap", "held_s": round(held, 1)}))
                # Re-arm rather than clear: if the stop does not take, the next
                # poll caps again. Stop is idempotent, so that is free.
                self._talk_since = now
        elif self._talk_since is not None:
            log("talk_ended", held_s=round(now - self._talk_since, 1))
            self._talk_since = None

        # 2. Consumers that are attached but no longer moving bytes. Nothing
        #    reaps these and no HTTP verb can evict them, so this is a report.
        live_ids = set()
        for consumer in consumers_of(talk):
            cid = consumer.get("id")
            live_ids.add(cid)
            sent = consumer.get("bytes_send", 0)
            unchanged = self._sent.get(cid) == sent
            self._stale[cid] = self._stale.get(cid, 0) + 1 if unchanged else 0
            self._sent[cid] = sent
            polls = self._stale[cid]
            if polls and polls % self._cfg.stale_polls == 0:
                actions.append((
                    "alert",
                    {
                        "reason": "stalled_consumer",
                        "consumer": cid,
                        "user_agent": consumer.get("user_agent"),
                        "remote_addr": consumer.get("remote_addr"),
                        "bytes_send": sent,
                        "stalled_polls": polls,
                    },
                ))
        for cid in list(self._sent):
            if cid not in live_ids:
                del self._sent[cid]
                self._stale.pop(cid, None)

        # 3. A live producer with nobody listening and nobody talking. go2rtc
        #    normally tears the producer down ~1 ms after the last consumer
        #    leaves; if it has not, the doorbell is in live view for nothing.
        #    Safe to stop: with no consumers and no talk there is nothing to
        #    interrupt, and stop is global per destination.
        #
        #    ⚠️ Honest about what the stop reaches. It stops producers pushed
        #    INTO this stream — so a mic push left behind by a dead client is
        #    reliably closed. Whether it also clears a ghost `ring:` producer
        #    (go2rtc#1961, which never reproduced in the lab) is UNVERIFIED.
        #    A `status: 200` on this line means the API accepted the call, not
        #    that the doorbell hung up. If these keep repeating, the producer
        #    is not being cleared and the container needs a restart.
        orphaned = stream_live(talk) and not consumers_of(talk) and not talking
        self._orphan_polls = self._orphan_polls + 1 if orphaned else 0
        if self._orphan_polls >= self._cfg.stale_polls:
            actions.append(("stop", {"reason": "orphaned_producer"}))
            self._orphan_polls = 0

        return actions


# --- running --------------------------------------------------------------


def run(cfg, client, watchdog, sleep=time.sleep, now=time.monotonic, forever=None):
    log(
        "starting",
        go2rtc=cfg.base,
        talk_stream=cfg.talk_stream,
        mic_stream=cfg.mic_stream,
        cap_s=cfg.cap_s,
        poll_s=cfg.poll_s,
    )

    # Fire once before polling anything: a previous run may have died holding
    # the microphone open, and this is the cheapest way to find out it did not
    # matter.
    _stop(client, {"reason": "startup"})

    running = {"go": True}

    def _term(signum, _frame):
        log("signal", signal=signum)
        running["go"] = False

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, _term)

    ticks = 0
    while running["go"] and (forever is None or ticks < forever):
        ticks += 1
        try:
            streams = client.streams()
        except (urllib.error.URLError, OSError, ValueError) as exc:
            # go2rtc restarts, and the container may outlive it. Losing the API
            # is not a reason to exit; it is a reason to say so and retry.
            log("poll_failed", error=type(exc).__name__, detail=str(exc))
            sleep(cfg.poll_s)
            continue

        for action, detail in watchdog.evaluate(streams, now()):
            if action == "stop":
                _stop(client, detail)
            else:
                log("alert", **detail)

        sleep(cfg.poll_s)

    _stop(client, {"reason": "shutdown"})
    log("stopped")


def _stop(client, detail):
    try:
        status = client.stop_talk()
        log("stop", status=status, **detail)
    except (urllib.error.URLError, OSError) as exc:
        log("stop_failed", error=type(exc).__name__, detail=str(exc), **detail)


def main():
    cfg = Config()
    run(cfg, Client(cfg), Watchdog(cfg))
    return 0


if __name__ == "__main__":
    sys.exit(main())
