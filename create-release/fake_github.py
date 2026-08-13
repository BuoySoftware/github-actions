#!/usr/bin/env python3
"""The create-release harness's stand-in GitHub API, serving one fixture dir.

Routes on top of the shared skeleton in lib/fake_github.py. The fixture
configures the responses:
  tags            one `name` or `name:sha` per line, oldest first; served
                  newest-first as the API does, honouring page/per_page
  release_exists  `true` when the release lookup should find one
  create_result   `ok`, `race` (rejected, release then present) or `hard`
  edit_fails      `true` when the flag correction should be rejected

Usage: python3 create-release/fake_github.py <fixture-dir>
"""

import json
import re
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))

import fake_github


class Handler(fake_github.Handler):
    # Whether the release exists, flipped by a lost race so the re-check that
    # follows finds the winner's release.
    exists = False

    def tag_entries(self) -> list[dict]:
        entries = []
        for line in (self.fixture / "tags").read_text().splitlines():
            if not line:
                continue
            name, _, sha = line.partition(":")
            entries.append({"name": name, "commit": {"sha": sha or f"sha-{name}"}})
        entries.reverse()
        return entries

    def do_GET(self) -> None:
        self._log_request()
        url = urlparse(self.path)

        if re.fullmatch(r"/repos/[^/]+/[^/]+/tags", url.path):
            if self.setting("tags_api_fails") == "true":
                self._reply(502, {"message": "Bad gateway"})
                return
            query = parse_qs(url.query)
            page = int(query.get("page", ["1"])[0])
            per_page = int(query.get("per_page", ["30"])[0])
            entries = self.tag_entries()
            start = (page - 1) * per_page
            self._reply(200, entries[start : start + per_page])
            return

        if re.fullmatch(r"/repos/[^/]+/[^/]+/releases/tags/[^/]+", url.path):
            if self.setting("release_exists") == "true" or Handler.exists:
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
            result = self.setting("create_result", "ok")
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
        if self.setting("edit_fails") == "true":
            self._reply(422, {"message": "Validation Failed"})
            return
        self._reply(200, {"id": 1234})


if __name__ == "__main__":
    fake_github.serve(Handler, Path(sys.argv[1]))
