#!/usr/bin/env python3
"""A stand-in GitHub API for the shell harness, serving one fixture directory.

The harness points GITHUB_API_URL here, so the shipped step bodies run against
real HTTP with nothing stubbed on PATH. Every request is appended to
`requests.log` as `METHOD path body`, which is what the assertions read: not
whether the step succeeded, but what it actually asked the API to do.

The fixture directory configures the responses:
  tags            one `name` or `name:sha` per line, oldest first; served
                  newest-first as the API does, honouring page/per_page
  release_exists  `true` when the release lookup should find one
  create_result   `ok`, `race` (rejected, release then present) or `hard`
  edit_fails      `true` when the flag correction should be rejected

Once listening, the chosen port is written to `port`.

Usage: python3 create-release/fake_github.py <fixture-dir>
"""

import json
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

FIXTURE = Path(sys.argv[1])


def setting(name: str, fallback: str = "false") -> str:
    path = FIXTURE / name
    return path.read_text().strip() if path.exists() else fallback


def tag_entries() -> list[dict]:
    entries = []
    for line in (FIXTURE / "tags").read_text().splitlines():
        if not line:
            continue
        name, _, sha = line.partition(":")
        entries.append({"name": name, "commit": {"sha": sha or f"sha-{name}"}})
    entries.reverse()
    return entries


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
        body = self.rfile.read(length).decode() if length else ""
        with (FIXTURE / "requests.log").open("a") as log:
            print(f"{self.command} {self.path} {body}", file=log)
        return body

    def do_GET(self) -> None:
        self._log_request()
        url = urlparse(self.path)

        if re.fullmatch(r"/repos/[^/]+/[^/]+/tags", url.path):
            if setting("tags_api_fails") == "true":
                self._reply(502, {"message": "Bad gateway"})
                return
            query = parse_qs(url.query)
            page = int(query.get("page", ["1"])[0])
            per_page = int(query.get("per_page", ["30"])[0])
            entries = tag_entries()
            start = (page - 1) * per_page
            self._reply(200, entries[start : start + per_page])
            return

        if re.fullmatch(r"/repos/[^/]+/[^/]+/releases/tags/[^/]+", url.path):
            if setting("release_exists") == "true" or Handler.exists:
                self._reply(200, {"id": 1234})
            else:
                self._reply(404, {"message": "Not Found"})
            return

        self._reply(404, {"message": f"unexpected GET {url.path}"})

    def do_POST(self) -> None:
        body = self._log_request()
        url = urlparse(self.path)

        if url.path.endswith("/releases/generate-notes"):
            tag = json.loads(body).get("tag_name", "")
            previous = json.loads(body).get("previous_tag_name", "")
            self._reply(200, {"name": tag, "body": f"notes from {previous}"})
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
            self._reply(201, {"id": 999})
            return

        self._reply(404, {"message": f"unexpected POST {url.path}"})

    def do_PATCH(self) -> None:
        self._log_request()
        if setting("edit_fails") == "true":
            self._reply(422, {"message": "Validation Failed"})
            return
        self._reply(200, {"id": 1234})

    def log_message(self, format: str, *args: object) -> None:
        pass


def main() -> None:
    server = HTTPServer(("127.0.0.1", 0), Handler)
    (FIXTURE / "port").write_text(str(server.server_port))
    server.serve_forever()


if __name__ == "__main__":
    main()
