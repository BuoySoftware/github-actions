#!/usr/bin/env python3
"""Tests the asset assertion in verify_release_assets.py.

The dangerous outcome is a false pass, so the cases concentrate on what the
script accepts, and on the paginated listing that keeps it honest when the
embedded asset array would have been truncated.

Usage: python3 verify-release-assets/test_verify_release_assets.py
"""

import io
import sys
import unittest
from http import HTTPStatus
from pathlib import Path
from unittest import mock

# The script under test sits beside this file, which is not on the path when
# the tests are run from the repository root as CI does.
sys.path.insert(0, str(Path(__file__).resolve().parent))

import verify_release_assets as verify

RELEASE = "/repos/owner/repo/releases/tags/v1.2.3"
ASSETS = "/repos/owner/repo/releases/1234/assets"


class FakeApi:
    """Answers github_api.request calls, recording each one."""

    def __init__(self, responses):
        self.responses = dict(responses)
        self.calls = []

    def request(self, method, path, payload=None):
        self.calls.append((method, path))
        return self.responses[method, path]

    def error_message(self, body):
        return body.get("message", "?") if isinstance(body, dict) else "?"


def run(fake, expect):
    environment = {
        "TAG": "v1.2.3",
        "GITHUB_REPOSITORY": "owner/repo",
        "EXPECT": expect,
    }
    with (
        mock.patch.object(verify, "github_api", fake),
        mock.patch.dict("os.environ", environment),
        mock.patch("sys.stderr", new=io.StringIO()) as stderr,
    ):
        try:
            verify.main()
        except SystemExit as stop:
            return stop.code, stderr.getvalue()
    return 0, stderr.getvalue()


def listing(*names):
    return {
        ("GET", RELEASE): (HTTPStatus.OK, {"id": 1234}),
        ("GET", f"{ASSETS}?per_page=100&page=1"): (
            HTTPStatus.OK,
            [{"name": name} for name in names],
        ),
    }


class VerifyReleaseAssets(unittest.TestCase):
    def test_passes_when_every_expected_asset_is_attached(self):
        code, _ = run(
            FakeApi(listing("structure.sql", "app.spdx.json")),
            "structure.sql\n*.spdx.json",
        )
        self.assertEqual(code, 0)

    def test_fails_when_a_named_asset_is_missing(self):
        code, stderr = run(FakeApi(listing("app.spdx.json")), "structure.sql")
        self.assertEqual(code, 1)
        self.assertIn("missing: structure.sql", stderr)

    def test_fails_when_no_asset_matches_a_pattern(self):
        code, stderr = run(FakeApi(listing("structure.sql")), "*.spdx.json")
        self.assertEqual(code, 1)
        self.assertIn("missing: *.spdx.json", stderr)

    def test_a_near_miss_name_does_not_satisfy_an_exact_entry(self):
        code, _ = run(FakeApi(listing("structure.sql.gz")), "structure.sql")
        self.assertEqual(code, 1)

    def test_fails_when_the_release_cannot_be_read(self):
        fake = FakeApi({("GET", RELEASE): (HTTPStatus.NOT_FOUND, {"message": "no"})})
        code, stderr = run(fake, "structure.sql")
        self.assertEqual(code, 1)
        self.assertIn("Could not read release v1.2.3", stderr)

    def test_an_empty_expectation_fails(self):
        code, stderr = run(FakeApi(listing("structure.sql")), "\n  \n")
        self.assertEqual(code, 1)
        self.assertIn("names no assets", stderr)

    def test_reads_every_page_of_the_asset_listing(self):
        first = [{"name": f"asset-{index}"} for index in range(100)]
        fake = FakeApi(
            {
                ("GET", RELEASE): (HTTPStatus.OK, {"id": 1234}),
                ("GET", f"{ASSETS}?per_page=100&page=1"): (HTTPStatus.OK, first),
                ("GET", f"{ASSETS}?per_page=100&page=2"): (
                    HTTPStatus.OK,
                    [{"name": "structure.sql"}],
                ),
            }
        )
        code, _ = run(fake, "structure.sql")
        self.assertEqual(code, 0)
        self.assertIn(("GET", f"{ASSETS}?per_page=100&page=2"), fake.calls)


if __name__ == "__main__":
    unittest.main()
