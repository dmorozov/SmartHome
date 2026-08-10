"""Tests for the talkback dead-man switch.

Run: python3 -m unittest discover -s hub/talk-watchdog/tests -t hub/talk-watchdog

Every fixture below is shaped after JSON read off a live go2rtc 1.9.10 on
2026-08-09, not invented — including the detail that makes test_consumer_...
worth having: an ordinary inbound RTSP listener reports `"audio, sendonly,
ANY"`, so `sendonly` alone cannot mean "somebody is talking".
"""

import io
import json
import os
import sys
import unittest
import urllib.error
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from fake_go2rtc import FakeGo2rtc  # noqa: E402
from watchdog import (  # noqa: E402
    Client,
    Config,
    Watchdog,
    _startup_stop,
    log,
    redact,
    run,
    stream_live,
)

FAKE_TOKEN = "eyJhbGciOi" + "x" * 1194


def cfg(**over):
    env = {
        "GO2RTC": "http://go2rtc-test:1984",
        "TALK_CAP_S": "45",
        "POLL_S": "2",
        "STALE_POLLS": "3",
    }
    env.update({k: str(v) for k, v in over.items()})
    return Config(env)


def idle_producer():
    """What a configured-but-not-dialled `ring:` source looks like: url only."""
    return {"url": f"ring:?device_id=90486cf35236&camera_id=319156885&refresh_token={FAKE_TOKEN}"}


def live_producer(**over):
    producer = {
        "id": 52,
        "format_name": "ring/webrtc",
        "protocol": "ws+udp",
        "remote_addr": "54.213.119.18:48909 host",
        "url": f"ring:?device_id=90486cf35236&refresh_token={FAKE_TOKEN}",
        "sdp": "v=0\r\no=- 3494852903 1786212672 IN IP4 0.0.0.0\r\n",
        "medias": ["video, recvonly, H264", "audio, recvonly, OPUS/48000/2"],
        "receivers": [{"id": 53, "bytes": 17186, "packets": 181}],
        "bytes_recv": 17186,
    }
    producer.update(over)
    return producer


def consumer(cid=31, sent=15773, **over):
    c = {
        "id": cid,
        "format_name": "rtsp",
        "protocol": "rtsp+tcp",
        "remote_addr": "127.0.0.1:36504",
        "user_agent": "Lavf60.16.100",
        # 🔴 The trap: a plain inbound listener advertises sendonly audio.
        "medias": ["video, sendonly, ANY", "audio, sendonly, ANY"],
        "bytes_send": sent,
    }
    c.update(over)
    return c


def streams(ring_live=False, ring_consumers=(), mic_live=False):
    return {
        "ring": {
            "producers": [live_producer() if ring_live else idle_producer()],
            "consumers": list(ring_consumers),
        },
        "mic": {
            "producers": [
                {"id": 61, "format_name": "rtsp", "remote_addr": "127.0.0.1:1"}
                if mic_live
                else {"url": "exec:ffmpeg -re -f pulse -i default ..."}
            ],
            "consumers": [],
        },
    }


def actions(watchdog, body, now):
    return watchdog.evaluate(body, now)


def reasons(acts, kind=None):
    return [d["reason"] for a, d in acts if kind is None or a == kind]


class Liveness(unittest.TestCase):
    def test_configured_producer_alone_is_not_live(self):
        # The producer entry always exists. Testing for the object would report
        # every configured stream as connected to Ring.
        self.assertFalse(stream_live({"producers": [idle_producer()]}))

    def test_dialled_producer_is_live(self):
        self.assertTrue(stream_live({"producers": [live_producer()]}))

    def test_missing_lists_are_tolerated(self):
        self.assertFalse(stream_live({}))
        self.assertFalse(stream_live({"producers": None}))


class TalkCap(unittest.TestCase):
    def test_cap_fires_once_held_past_the_limit(self):
        w = Watchdog(cfg(TALK_CAP_S=45))
        body = streams(mic_live=True, ring_live=True)
        with redirect_stdout(io.StringIO()):
            self.assertEqual(reasons(actions(w, body, 0.0)), [])
            self.assertEqual(reasons(actions(w, body, 44.0)), [])
            self.assertEqual(reasons(actions(w, body, 45.0)), ["cap"])

    def test_cap_re_arms_if_the_stop_does_not_take(self):
        # A stop that silently fails must not leave the mic hot forever.
        w = Watchdog(cfg(TALK_CAP_S=10))
        body = streams(mic_live=True)
        with redirect_stdout(io.StringIO()):
            actions(w, body, 0.0)
            self.assertEqual(reasons(actions(w, body, 10.0)), ["cap"])
            self.assertEqual(reasons(actions(w, body, 15.0)), [])
            self.assertEqual(reasons(actions(w, body, 20.0)), ["cap"])

    def test_idle_mic_never_caps(self):
        w = Watchdog(cfg(TALK_CAP_S=1))
        with redirect_stdout(io.StringIO()):
            for t in range(0, 100, 5):
                self.assertEqual(reasons(actions(w, streams(), float(t))), [])

    def test_sendonly_media_on_a_consumer_is_not_talking(self):
        # The whole point of keying on the mic producer. A listener attached to
        # `ring` reports sendonly audio; that is go2rtc sending TO the listener.
        w = Watchdog(cfg(TALK_CAP_S=5))
        with redirect_stdout(io.StringIO()):
            for t in range(0, 60, 5):
                # Bytes advance: a healthy listener, so only the sendonly
                # medias could possibly be mistaken for talk.
                body = streams(
                    ring_live=True,
                    ring_consumers=[consumer(sent=1000 * t)],
                    mic_live=False,
                )
                self.assertEqual(reasons(actions(w, body, float(t))), [])

    def test_talk_timer_resets_between_sessions(self):
        w = Watchdog(cfg(TALK_CAP_S=10))
        with redirect_stdout(io.StringIO()):
            actions(w, streams(mic_live=True), 0.0)
            actions(w, streams(mic_live=False), 5.0)  # released
            actions(w, streams(mic_live=True), 6.0)  # pressed again
            self.assertEqual(reasons(actions(w, streams(mic_live=True), 12.0)), [])
            self.assertEqual(reasons(actions(w, streams(mic_live=True), 16.0)), ["cap"])


class StalledConsumers(unittest.TestCase):
    def test_alerts_after_stale_polls_and_keeps_reminding(self):
        w = Watchdog(cfg(STALE_POLLS=3))
        stuck = streams(ring_live=True, ring_consumers=[consumer(sent=160_000_000)])
        with redirect_stdout(io.StringIO()):
            got = [reasons(actions(w, stuck, float(t)), "alert") for t in range(9)]
        # poll 0 seeds the counter; 1,2,3 are the first three unchanged polls.
        self.assertEqual(got[3], ["stalled_consumer"])
        self.assertEqual(got[4], [])
        self.assertEqual(got[6], ["stalled_consumer"])

    def test_a_flowing_consumer_never_alerts(self):
        w = Watchdog(cfg(STALE_POLLS=3))
        with redirect_stdout(io.StringIO()):
            for i in range(20):
                body = streams(ring_live=True, ring_consumers=[consumer(sent=1000 * i)])
                self.assertEqual(reasons(actions(w, body, float(i)), "alert"), [])

    def test_a_silent_but_flowing_consumer_never_alerts(self):
        # Ring sends near-digital-silence on a quiet street. Bytes still move,
        # and audio presence must never be a health signal.
        w = Watchdog(cfg(STALE_POLLS=3))
        with redirect_stdout(io.StringIO()):
            for i in range(20):
                body = streams(ring_live=True, ring_consumers=[consumer(sent=100 + i)])
                self.assertEqual(reasons(actions(w, body, float(i)), "alert"), [])

    def test_departed_consumers_are_forgotten(self):
        w = Watchdog(cfg(STALE_POLLS=3))
        with redirect_stdout(io.StringIO()):
            for i in range(30):
                body = streams(ring_live=True, ring_consumers=[consumer(cid=i, sent=5)])
                actions(w, body, float(i))
        self.assertEqual(len(w._sent), 1)  # not 30


class OrphanedProducer(unittest.TestCase):
    def test_live_with_no_consumers_and_no_talk_is_stopped(self):
        w = Watchdog(cfg(STALE_POLLS=3))
        body = streams(ring_live=True, ring_consumers=[], mic_live=False)
        with redirect_stdout(io.StringIO()):
            got = [reasons(actions(w, body, float(t)), "stop") for t in range(5)]
        self.assertEqual(got, [[], [], ["orphaned_producer"], [], []])

    def test_not_stopped_while_talking(self):
        # A push-only call legitimately has zero consumers. Stopping here would
        # cut off somebody mid-sentence.
        w = Watchdog(cfg(STALE_POLLS=3, TALK_CAP_S=999))
        body = streams(ring_live=True, ring_consumers=[], mic_live=True)
        with redirect_stdout(io.StringIO()):
            for t in range(10):
                self.assertEqual(reasons(actions(w, body, float(t)), "stop"), [])

    def test_not_stopped_while_a_consumer_is_attached(self):
        w = Watchdog(cfg(STALE_POLLS=3))
        body = streams(ring_live=True, ring_consumers=[consumer(sent=1)])
        with redirect_stdout(io.StringIO()):
            for t in range(10):
                self.assertEqual(reasons(actions(w, body, float(t)), "stop"), [])

    def test_counter_resets_when_a_consumer_arrives(self):
        w = Watchdog(cfg(STALE_POLLS=3))
        with redirect_stdout(io.StringIO()):
            actions(w, streams(ring_live=True), 0.0)
            actions(w, streams(ring_live=True), 1.0)
            actions(w, streams(ring_live=True, ring_consumers=[consumer()]), 2.0)
            self.assertEqual(reasons(actions(w, streams(ring_live=True), 3.0), "stop"), [])


class Redaction(unittest.TestCase):
    def test_token_is_stripped_from_a_producer_url(self):
        out = redact(json.dumps(idle_producer()))
        self.assertNotIn(FAKE_TOKEN, out)
        self.assertIn("refresh_token=<REDACTED>", out)

    def test_log_redacts(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            log("poll_failed", detail=f"ring:?refresh_token={FAKE_TOKEN}&x=1")
        self.assertNotIn(FAKE_TOKEN, buf.getvalue())
        self.assertIn("<REDACTED>", buf.getvalue())

    def test_device_and_camera_ids_survive(self):
        # Only the credential is secret; the ids are needed to read the logs.
        out = redact(json.dumps(idle_producer()))
        self.assertIn("device_id=90486cf35236", out)
        self.assertIn("camera_id=319156885", out)


class LoopBehaviour(unittest.TestCase):
    def _run(self, fake, ticks, **over):
        c = cfg(GO2RTC=fake.url, **over)
        clock = iter(float(i) for i in range(0, 10_000))
        buf = io.StringIO()
        with redirect_stdout(buf):
            run(
                c,
                Client(c),
                Watchdog(c),
                sleep=lambda _s: None,
                now=lambda: next(clock),
                forever=ticks,
            )
        return buf.getvalue()

    def test_stops_at_startup_before_reading_anything(self):
        with FakeGo2rtc([streams()]) as fake:
            self._run(fake, ticks=0)
        self.assertEqual(fake.requests[0][0], "POST")
        self.assertEqual(fake.gets(), [])

    def test_stops_again_on_shutdown(self):
        with FakeGo2rtc([streams()]) as fake:
            self._run(fake, ticks=2)
        self.assertEqual(len(fake.posts()), 2)  # startup + shutdown
        self.assertTrue(all(p.endswith("src=") for p in fake.posts()))

    def test_never_issues_put_or_delete(self):
        # PUT/DELETE rewrite go2rtc.yaml on disk — token included — and stop
        # no producer. Nothing in this service may reach for them.
        body = streams(ring_live=True, mic_live=True, ring_consumers=[consumer()])
        with FakeGo2rtc([body]) as fake:
            self._run(fake, ticks=30, TALK_CAP_S=3)
        methods = {m for m, _ in fake.requests}
        self.assertEqual(methods, {"GET", "POST"})

    def test_cap_reaches_the_wire(self):
        with FakeGo2rtc([streams(mic_live=True)]) as fake:
            out = self._run(fake, ticks=10, TALK_CAP_S=4)
        self.assertIn('"reason": "cap"', out)
        self.assertGreater(len(fake.posts()), 2)  # more than startup + shutdown

    def test_a_dead_api_does_not_kill_the_loop(self):
        # STARTUP_GRACE_S=0 keeps this about the poll loop: without it the
        # startup stop would spend the whole grace retrying a port that is
        # never going to answer, and this suite would take 30 s to say
        # something it can say instantly.
        c = cfg(GO2RTC="http://127.0.0.1:9", STARTUP_GRACE_S=0)  # discard port
        buf = io.StringIO()
        with redirect_stdout(buf):
            run(c, Client(c), Watchdog(c), sleep=lambda _s: None, forever=3)
        self.assertEqual(buf.getvalue().count('"event": "poll_failed"'), 3)
        self.assertIn('"event": "stopped"', buf.getvalue())


class StartupStop(unittest.TestCase):
    """The startup stop has to survive go2rtc not being up yet.

    Compose's `depends_on:` waits for go2rtc's *container*, not for its HTTP
    listener to bind, so on a cold boot this service wins the race. Measured on
    a real one, 2026-08-10T03:25:53Z: `starting` and `stop_failed reason=startup
    detail="[Errno 111] Connection refused"` in the same second, the single
    attempt spent for nothing.
    """

    class _Client:
        """Refuses `fails` times with ECONNREFUSED, then answers 200."""

        def __init__(self, fails):
            self._left = fails
            self.attempts = 0

        def stop_talk(self):
            self.attempts += 1
            if self._left > 0:
                self._left -= 1
                raise urllib.error.URLError("[Errno 111] Connection refused")
            return 200

    def _startup(self, client, **over):
        c = cfg(**over)
        slept = []
        clock = iter(float(i) for i in range(0, 10_000))
        buf = io.StringIO()
        with redirect_stdout(buf):
            ok = _startup_stop(c, client, slept.append, lambda: next(clock))
        return ok, buf.getvalue(), slept

    def test_retries_until_go2rtc_answers(self):
        client = self._Client(fails=3)
        ok, out, slept = self._startup(client)
        self.assertTrue(ok)
        self.assertEqual(client.attempts, 4)
        self.assertIn('"reason": "startup"', out)
        self.assertIn('"status": 200', out)
        self.assertNotIn("startup_stop_gave_up", out)
        # Waited the poll interval between tries rather than spinning.
        self.assertEqual(slept, [2.0, 2.0, 2.0])

    def test_a_go2rtc_already_up_costs_exactly_one_attempt(self):
        client = self._Client(fails=0)
        ok, out, slept = self._startup(client)
        self.assertTrue(ok)
        self.assertEqual(client.attempts, 1)
        self.assertEqual(slept, [])
        # Byte-identical to the log this wrote before the retry existed: no
        # `attempts` key on the path where it would only ever say 1.
        self.assertNotIn("attempts", out)
        self.assertNotIn("stop_failed", out)

    def test_gives_up_after_the_grace_rather_than_blocking_for_ever(self):
        # The failure mode this guards: an unbounded retry turns a permanently
        # down go2rtc into a watchdog that never reaches its poll loop and so
        # never reports anything at all.
        client = self._Client(fails=10_000)
        ok, out, _ = self._startup(client, STARTUP_GRACE_S=6)
        self.assertFalse(ok)
        self.assertIn('"event": "startup_stop_gave_up"', out)
        self.assertIn('"attempts": 6', out)

    def test_only_the_first_failure_is_logged(self):
        # Fifteen identical lines every cold boot is a log nobody skims. The
        # give-up line carries the count, so nothing is hidden by this.
        client = self._Client(fails=10_000)
        _, out, _ = self._startup(client, STARTUP_GRACE_S=6)
        self.assertEqual(out.count('"event": "stop_failed"'), 1)

    def test_a_startup_that_gave_up_still_enters_the_poll_loop(self):
        # The whole point of bounding it. A watchdog that died at startup
        # because go2rtc was down is worse than one that starts late.
        c = cfg(GO2RTC="http://127.0.0.1:9", STARTUP_GRACE_S=0)  # discard port
        buf = io.StringIO()
        with redirect_stdout(buf):
            run(c, Client(c), Watchdog(c), sleep=lambda _s: None, forever=2)
        out = buf.getvalue()
        self.assertIn('"event": "startup_stop_gave_up"', out)
        self.assertEqual(out.count('"event": "poll_failed"'), 2)
        self.assertIn('"event": "stopped"', out)


if __name__ == "__main__":
    unittest.main()
