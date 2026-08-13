#!/usr/bin/env python3
"""Shared skeleton for the shell harnesses' stand-in GitHub APIs.

Each action's fake_github.py subclasses Handler with its own routes and calls
serve(). Every request is appended to the fixture's `requests.log` as
`METHOD path body`, which is what the harness assertions read; responses are
configured by files in the fixture directory, read through `setting`. Once
listening, the chosen port is written to `port`.
"""

import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


class Handler(BaseHTTPRequestHandler):
    fixture: Path

    @classmethod
    def setting(cls, name: str, fallback: str = "false") -> str:
        path = cls.fixture / name
        return path.read_text().strip() if path.exists() else fallback

    def _reply(self, status: int, body: dict | list) -> None:
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _log_request(self) -> str:
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        printable = body.decode(errors="replace").replace("\n", "\\n")
        with (self.fixture / "requests.log").open("a") as log:
            print(f"{self.command} {self.path} {printable}", file=log)
        return printable

    def log_message(self, format: str, *args: object) -> None:
        pass


def serve(handler: type[Handler], fixture: Path) -> None:
    handler.fixture = fixture
    server = HTTPServer(("127.0.0.1", 0), handler)
    (fixture / "port").write_text(str(server.server_port))
    server.serve_forever()
