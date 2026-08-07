#!/usr/bin/env python3
"""A stand-in GitHub API for the shell harness, serving one fixture directory.

Every request is appended to `requests.log` as `METHOD path body`, which is
what the harness assertions read. The fixture directory configures the
responses:
  release_exists   `true` when the release lookup should find one
  attached_assets  asset names on the existing release, one per line
  create_result    `ok`, `race` (rejected, release then present) or `hard`
  view_fails       `true` when reading the release should return a 500

The release's upload_url points back at this server. Once listening, the
chosen port is written to `port`.

Usage: python3 generate-structure-sql/fake_github.py <fixture-dir>
"""

import json
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlparse

FIXTURE = Path(sys.argv[1])


def setting(name: str, fallback: str = "false") -> str:
    path = FIXTURE / name
    return path.read_text().strip() if path.exists() else fallback


class Handler(BaseHTTPRequestHandler):
    # Whether the release exists, flipped by a lost race so the re-check that
    # follows finds the winner's release.
    exists = False

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
        with (FIXTURE / "requests.log").open("a") as log:
            print(f"{self.command} {self.path} {printable}", file=log)
        return printable

    def _release(self) -> dict:
        assert isinstance(self.server, HTTPServer)
        port = self.server.server_port
        assets = [
            {"name": name, "id": index + 1}
            for index, name in enumerate(setting("attached_assets", "").split())
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
            if setting("view_fails") == "true":
                self._reply(500, {"message": "Internal Server Error"})
                return
            if setting("release_exists") == "true" or Handler.exists:
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

        if re.fullmatch(r"/repos/[^/]+/[^/]+/releases", url.path):
            result = setting("create_result", "ok")
            if result == "race":
                Handler.exists = True
                self._reply(
                    422,
                    {
                        "message": "Validation Failed",
                        "errors": [
                            {
                                "resource": "Release",
                                "code": "already_exists",
                                "field": "tag_name",
                            }
                        ],
                    },
                )
                return
            if result == "hard":
                self._reply(403, {"message": "Resource not accessible by integration"})
                return
            self._reply(201, self._release() | {"assets": []})
            return

        self._reply(404, {"message": f"unexpected POST {url.path}"})

    def do_DELETE(self) -> None:
        self._log_request()
        raw = b""
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, format: str, *args: object) -> None:
        pass


def main() -> None:
    server = HTTPServer(("127.0.0.1", 0), Handler)
    (FIXTURE / "port").write_text(str(server.server_port))
    server.serve_forever()


if __name__ == "__main__":
    main()
