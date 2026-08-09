"""A go2rtc stand-in, so the watchdog can be tested without a doorbell.

Serves scripted `/api/streams` bodies and records every request — method
included, because "the watchdog must never issue PUT or DELETE" is a real
requirement (both rewrite go2rtc.yaml on disk, token and all) and an assertion
about a method is only worth making if something is watching for it.
"""

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class FakeGo2rtc:
    def __init__(self, bodies=None):
        # Popped one per GET; the last one repeats forever.
        self._bodies = list(bodies or [{}])
        self.requests = []  # (method, path)
        self._server = None
        self._thread = None

    @property
    def url(self):
        host, port = self._server.server_address[:2]
        return f"http://127.0.0.1:{port}"

    def posts(self):
        return [path for method, path in self.requests if method == "POST"]

    def gets(self):
        return [path for method, path in self.requests if method == "GET"]

    def _next_body(self):
        if len(self._bodies) > 1:
            return self._bodies.pop(0)
        return self._bodies[0]

    def start(self):
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def _record_and_reply(self, payload):
                fake.requests.append((self.command, self.path))
                body = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                self._record_and_reply(fake._next_body())

            def do_POST(self):
                self._record_and_reply({})

            def do_PUT(self):
                self._record_and_reply({})

            def do_DELETE(self):
                self._record_and_reply({})

            def log_message(self, *args):
                pass  # keep the test output readable

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()
        return self

    def stop(self):
        self._server.shutdown()
        self._server.server_close()
        self._thread.join(timeout=5)

    def __enter__(self):
        return self.start()

    def __exit__(self, *exc):
        self.stop()
