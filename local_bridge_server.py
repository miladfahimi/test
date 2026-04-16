#!/usr/bin/env python3
"""Local bridge server between a browser UI and MiladTradeManager EA."""

from __future__ import annotations

import json
from collections import deque
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock

HOST = "127.0.0.1"
PORT = 8000
WEB_DIR = Path(__file__).with_name("web")

STACKS = {
    "XAUUSD",
    "XAGUSD",
    "US30",
    "US500",
    "USTEC",
    "NAS100",
}

COMMANDS = {
    "buy",
    "sell",
    "sale",
    "rescue",
    "close50",
    "close30",
    "get100",
}

command_queue: deque[dict[str, str]] = deque()
queue_lock = Lock()


def push_command(command: str, stack: str) -> None:
    with queue_lock:
        command_queue.append({"command": command, "stack": stack})


def pop_command() -> dict[str, str]:
    with queue_lock:
        if not command_queue:
            return {"command": "", "stack": ""}
        return command_queue.popleft()


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, data: dict, status: HTTPStatus = HTTPStatus.OK) -> None:
        payload = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _serve_index(self) -> None:
        index_file = WEB_DIR / "index.html"
        if not index_file.exists():
            self.send_error(HTTPStatus.NOT_FOUND, "index.html not found")
            return

        payload = index_file.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:  # noqa: N802
        if self.path in ("/", "/index.html"):
            self._serve_index()
            return

        if self.path == "/api/command/next":
            self._send_json(pop_command())
            return

        if self.path == "/api/status":
            with queue_lock:
                size = len(command_queue)
            self._send_json({"ok": True, "queue_size": size})
            return

        self.send_error(HTTPStatus.NOT_FOUND, "Not found")

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/api/command":
            self.send_error(HTTPStatus.NOT_FOUND, "Not found")
            return

        content_length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(content_length)

        try:
            body = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            self._send_json({"ok": False, "error": "Invalid JSON"}, status=HTTPStatus.BAD_REQUEST)
            return

        command = str(body.get("command", "")).strip().lower()
        stack = str(body.get("stack", "")).strip().upper()

        if command not in COMMANDS:
            self._send_json(
                {"ok": False, "error": f"Unsupported command: {command}"},
                status=HTTPStatus.BAD_REQUEST,
            )
            return

        if stack not in STACKS:
            self._send_json(
                {"ok": False, "error": f"Unsupported stack: {stack}"},
                status=HTTPStatus.BAD_REQUEST,
            )
            return

        push_command(command, stack)
        self._send_json({"ok": True, "queued": command, "stack": stack})

    def log_message(self, fmt: str, *args) -> None:
        return


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Local bridge server running on http://{HOST}:{PORT}")
    print("Open the UI at http://127.0.0.1:8000/")
    server.serve_forever()


if __name__ == "__main__":
    main()
