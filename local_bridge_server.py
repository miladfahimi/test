#!/usr/bin/env python3
"""Local bridge server between a browser UI and MiladTradeManager EA."""

from __future__ import annotations

import json
import os
import socket
import sys
from collections import deque
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock
from time import time

HOST = os.getenv("BRIDGE_HOST", "127.0.0.1")
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
    "closeall",
    "close50",
    "close30",
    "get100",
}

command_queue: deque[dict[str, str]] = deque()
queue_lock = Lock()
bridge_lock = Lock()
last_bridge_poll_ts = 0.0


def get_port() -> int:
    raw_port = os.getenv("BRIDGE_PORT", "8000").strip()
    try:
        port = int(raw_port)
    except ValueError:
        print(f"Invalid BRIDGE_PORT='{raw_port}': expected an integer.", file=sys.stderr)
        raise SystemExit(2)

    if not (1 <= port <= 65535):
        print(f"Invalid BRIDGE_PORT='{raw_port}': expected 1-65535.", file=sys.stderr)
        raise SystemExit(2)
    return port


def detect_lan_ip() -> str | None:
    """Best-effort local LAN IP detection for startup hints."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # No packets are sent, but connect helps select the outbound interface.
        sock.connect(("8.8.8.8", 80))
        ip = sock.getsockname()[0]
        if ip and not ip.startswith("127."):
            return ip
    except OSError:
        return None
    finally:
        sock.close()
    return None


def push_command(command: str, stack: str, lot: str = "", ticket: str = "") -> None:
    with queue_lock:
        command_queue.append({"command": command, "stack": stack, "lot": lot, "ticket": ticket})


def pop_command() -> dict[str, str]:
    global last_bridge_poll_ts
    with queue_lock:
        with bridge_lock:
            last_bridge_poll_ts = time()
        if not command_queue:
            return {"command": "", "stack": ""}
        return command_queue.popleft()


def get_bridge_state() -> dict[str, float | bool | None]:
    with bridge_lock:
        ts = last_bridge_poll_ts

    if ts <= 0:
        return {
            "bridge_connected": False,
            "last_bridge_poll_unix": None,
            "last_bridge_poll_seconds_ago": None,
        }

    seconds_ago = max(0.0, time() - ts)
    # Consider bridge "connected" if EA polled within the last 5 seconds.
    return {
        "bridge_connected": seconds_ago <= 5.0,
        "last_bridge_poll_unix": ts,
        "last_bridge_poll_seconds_ago": round(seconds_ago, 2),
    }


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
            self._send_json({"ok": True, "queue_size": size, **get_bridge_state()})
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
        lot = str(body.get("lot", "")).strip()
        ticket = str(body.get("ticket", "")).strip()

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

        if lot:
            try:
                lot_value = float(lot)
            except ValueError:
                self._send_json(
                    {"ok": False, "error": f"Invalid lot: {lot}"},
                    status=HTTPStatus.BAD_REQUEST,
                )
                return
            if lot_value <= 0:
                self._send_json(
                    {"ok": False, "error": "Lot must be greater than zero"},
                    status=HTTPStatus.BAD_REQUEST,
                )
                return

        push_command(command, stack, lot, ticket)
        self._send_json({"ok": True, "queued": command, "stack": stack, "lot": lot, "ticket": ticket})

    def log_message(self, fmt: str, *args) -> None:
        return


def main() -> None:
    port = get_port()
    server = ThreadingHTTPServer((HOST, port), Handler)
    print(f"Local bridge server running on http://{HOST}:{port}")
    if HOST == "0.0.0.0":
        print(f"Open the UI from this PC at http://127.0.0.1:{port}/")
        lan_ip = detect_lan_ip()
        if lan_ip:
            print(f"Open the UI from your phone at http://{lan_ip}:{port}/")
            print(f"Quick local test: curl http://{lan_ip}:{port}/api/status")
        else:
            print(f"Open the UI from your phone at http://<your-pc-lan-ip>:{port}/")
        print(f"Verify listen socket: ss -ltnp | grep {port}")
        print(
            "If phone still times out: allow inbound TCP on this port in firewall and disable AP/client isolation on Wi-Fi."
        )
    else:
        print(f"Open the UI at http://{HOST}:{port}/")
    server.serve_forever()


if __name__ == "__main__":
    main()
