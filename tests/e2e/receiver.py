"""Minimal webhook receiver for the end-to-end test.

POST <any path>   stores the delivery (raw body, headers, receive time) in memory
GET  /deliveries  returns all stored deliveries as JSON
GET  /healthz     liveness probe

The receiver does not verify anything itself; test_e2e.py checks signatures and payloads.
Request logging is disabled because the headers carry webhook secrets.
"""

from __future__ import annotations

import base64
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "0.0.0.0"  # noqa: S104 - only reachable inside the compose test network
PORT = 8080
MAX_BODY_BYTES = 10 * 1024 * 1024

_lock = threading.Lock()
_deliveries: list[dict[str, object]] = []


class Handler(BaseHTTPRequestHandler):
    server_version = "docuseal-pdf-api-e2e-receiver"

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY_BYTES:
            self._send_json(413, {"error": "body too large"})
            return
        body = self.rfile.read(length)
        record = {
            "path": self.path,
            "received_at": time.time(),
            "headers": {key.lower(): value for key, value in self.headers.items()},
            "body_b64": base64.b64encode(body).decode("ascii"),
        }
        with _lock:
            _deliveries.append(record)
        self._send_json(200, {"ok": True})

    def do_GET(self) -> None:
        if self.path == "/healthz":
            self._send_json(200, {"ok": True})
        elif self.path == "/deliveries":
            with _lock:
                snapshot = list(_deliveries)
            self._send_json(200, snapshot)
        else:
            self._send_json(404, {"error": "not found"})

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002 - signature of the base class
        """Silence per-request logging (headers contain secrets)."""

    def _send_json(self, status: int, payload: object) -> None:
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"webhook receiver listening on {HOST}:{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
