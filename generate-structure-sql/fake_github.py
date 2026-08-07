#!/usr/bin/env python3
"""The upload harness's stand-in GitHub API, serving one fixture directory.

Routes on top of the shared skeleton in lib/fake_github.py. The fixture
configures the responses:
  release_exists   `true` when the release lookup should find one
  attached_assets  asset names on the existing release, one per line

The release's upload_url points back at this server.

Usage: python3 generate-structure-sql/fake_github.py <fixture-dir>
"""

import re
import sys
from http.server import HTTPServer
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))

import fake_github


class Handler(fake_github.Handler):
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

        if re.fullmatch(r"/repos/[^/]+/[^/]+/releases/\d+/assets", url.path):
            self._reply(200, self._release()["assets"])
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


if __name__ == "__main__":
    fake_github.serve(Handler, Path(sys.argv[1]))
