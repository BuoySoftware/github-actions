#!/usr/bin/env python3
"""Shared skeleton for the shell harnesses' stand-in GitHub APIs.

Each action's fake_github.py subclasses Handler with its own routes and calls
serve(). Every request is appended to the fixture's `requests.log` as
`METHOD path body`, which is what the harness assertions read; responses are
configured by files in the fixture directory, read through `setting`. Once
listening, the chosen port is written to `port`.

ReleaseAssetHandler carries the release-asset routes the upload harnesses
share, so an action that only attaches a generated file needs no routes of
its own. Run as a script, this module serves exactly that handler:

    python3 lib/fake_github.py <fixture-dir>
"""

import json
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlparse


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


class ReleaseAssetHandler(Handler):
    """The routes an attach-only upload step touches.

    The fixture configures the responses:
      release_exists   `true` when the release lookup should find one
      attached_assets  asset names on the existing release, one per line

    The release's upload_url points back at this server.
    """

    def _release(self) -> dict:
        assert isinstance(self.server, HTTPServer)
        port = self.server.server_port
        assets = [
            {"name": name, "id": index + 1}
            for index, name in enumerate(self.setting("attached_assets", "").split())
        ]
        return {
            "id": 1234,
            "assets": assets,
            "upload_url": f"http://127.0.0.1:{port}/uploads/releases/1234/assets{{?name,label}}",
        }

    def do_GET(self) -> None:
        self._log_request()
        url = urlparse(self.path)

        if re.fullmatch(r"/repos/[^/]+/[^/]+/releases/tags/[^/]+", url.path):
            if self.setting("release_exists") == "true":
                self._reply(200, self._release())
            else:
                self._reply(404, {"message": "Not Found"})
            return

        self._reply(404, {"message": f"unexpected GET {url.path}"})

    def do_POST(self) -> None:
        self._log_request()
        url = urlparse(self.path)

        if url.path.startswith("/uploads/"):
            self._reply(201, {"name": "uploaded"})
            return

        self._reply(404, {"message": f"unexpected POST {url.path}"})

    def do_DELETE(self) -> None:
        self._log_request()
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()


def serve(handler: type[Handler], fixture: Path) -> None:
    handler.fixture = fixture
    server = HTTPServer(("127.0.0.1", 0), handler)
    (fixture / "port").write_text(str(server.server_port))
    server.serve_forever()


if __name__ == "__main__":
    serve(ReleaseAssetHandler, Path(sys.argv[1]))
