#!/usr/bin/env python3
"""Tests the create-or-correct flow in create_or_update_release.py.

The dangerous cases are the ones that look like success, so every case
asserts the calls the script makes, not just its exit code.

Usage: python3 create-release/test_create_or_update_release.py
"""

import io
import sys
import unittest
from pathlib import Path
from unittest import mock

# The script under test sits beside this file, which is not on the path when the
# tests are run from the repository root as CI does.
sys.path.insert(0, str(Path(__file__).resolve().parent))

import create_or_update_release as create


class FakeApi:
    """Answers github_api.request calls from a script, recording each one.

    Responses are keyed by (method, path); a POST to the releases collection
    can be given a sequence of responses so a race can answer differently on
    the lookup before and after it.
    """

    def __init__(self, responses):
        self.responses = {key: list(value) for key, value in responses.items()}
        self.calls = []

    def request(self, method, path, payload=None):
        self.calls.append((method, path, payload))
        remaining = self.responses[method, path]
        return remaining.pop(0) if len(remaining) > 1 else remaining[0]

    def sent(self, method, path, prefix=False):
        return [
            (m, p, body)
            for m, p, body in self.calls
            if m == method and (p.startswith(path) if prefix else p == path)
        ]


REPO = "/repos/owner/repo"

ENVIRONMENT = {
    "TAG": "v37.0",
    "GITHUB_REPOSITORY": "owner/repo",
    "LATEST": "true",
    "NOTES_START": "v36.1",
    "PRERELEASE": "false",
}


def run_main(api, environment=None):
    merged = {**ENVIRONMENT, **(environment or {})}
    with (
        mock.patch.dict(create.os.environ, merged, clear=False),
        mock.patch.object(create.github_api, "request", api.request),
        mock.patch("sys.stdout", io.StringIO()) as out,
    ):
        create.main()
    return out.getvalue()


class TestCreate(unittest.TestCase):
    """Creating a release that does not exist yet."""

    def api(self):
        return FakeApi(
            {
                ("GET", f"{REPO}/releases/tags/v37.0"): [(404, {})],
                ("POST", f"{REPO}/releases/generate-notes"): [
                    (200, {"name": "v37.0", "body": "notes from v36.1"})
                ],
                ("POST", f"{REPO}/releases"): [(201, {"id": 999})],
            }
        )

    def test_creates_with_explicit_flags_and_generated_notes(self):
        api = self.api()
        run_main(api)

        ((_, _, payload),) = api.sent("POST", f"{REPO}/releases")
        self.assertEqual(payload["tag_name"], "v37.0")
        self.assertEqual(payload["name"], "v37.0")
        self.assertIs(payload["prerelease"], False)
        # A string, not a boolean: make_latest is three-state on the API, and
        # it is always stated because the fallback is publish order.
        self.assertEqual(payload["make_latest"], "true")
        self.assertEqual(payload["body"], "notes from v36.1")

    def test_notes_are_generated_back_to_the_resolved_base(self):
        api = self.api()
        run_main(api)

        ((_, _, payload),) = api.sent("POST", f"{REPO}/releases/generate-notes")
        self.assertEqual(payload["previous_tag_name"], "v36.1")
        self.assertEqual(payload["tag_name"], "v37.0")

    def test_no_base_generates_notes_from_the_entire_history(self):
        # An empty previous_tag_name is not "no boundary"; the request would be
        # rejected. With nothing below the release, the API's own generation
        # covers everything that led to it.
        api = FakeApi(
            {
                ("GET", f"{REPO}/releases/tags/v37.0"): [(404, {})],
                ("POST", f"{REPO}/releases"): [(201, {"id": 999})],
            }
        )
        run_main(api, {"NOTES_START": ""})

        self.assertEqual(api.sent("POST", f"{REPO}/releases/generate-notes"), [])
        ((_, _, payload),) = api.sent("POST", f"{REPO}/releases")
        self.assertIs(payload["generate_release_notes"], True)
        self.assertNotIn("body", payload)

    def test_a_candidate_is_created_as_a_prerelease_that_declines_latest(self):
        api = self.api()
        api.responses["GET", f"{REPO}/releases/tags/v38.0-rc.1"] = [(404, {})]
        run_main(api, {"TAG": "v38.0-rc.1", "PRERELEASE": "true", "LATEST": "false"})

        ((_, _, payload),) = api.sent("POST", f"{REPO}/releases")
        self.assertIs(payload["prerelease"], True)
        self.assertEqual(payload["make_latest"], "false")

    def test_failed_notes_generation_fails_the_run(self):
        # Falling back to whole-history notes would silently re-describe every
        # release below the base.
        api = FakeApi(
            {
                ("GET", f"{REPO}/releases/tags/v37.0"): [(404, {})],
                ("POST", f"{REPO}/releases/generate-notes"): [
                    (404, {"message": "Not Found"})
                ],
            }
        )
        with self.assertRaises(SystemExit):
            run_main(api)
        self.assertEqual(api.sent("POST", f"{REPO}/releases"), [])


class TestCorrectExisting(unittest.TestCase):
    """The release already exists, so only its flags are corrected."""

    def api(self, edit_status=200):
        return FakeApi(
            {
                ("GET", f"{REPO}/releases/tags/v37.0"): [(200, {"id": 1234})],
                ("PATCH", f"{REPO}/releases/1234"): [(edit_status, {})],
            }
        )

    def test_edits_instead_of_creating(self):
        api = self.api()
        run_main(api)

        self.assertEqual(api.sent("POST", f"{REPO}/releases"), [])
        ((_, path, _),) = api.sent("PATCH", f"{REPO}/releases/", prefix=True)
        # The release is patched by id. A call that named the tag would be
        # rejected as already_exists, destroying any attached asset.
        self.assertEqual(path, f"{REPO}/releases/1234")

    def test_the_edit_names_both_flags_and_nothing_else(self):
        # A field the PATCH does not send cannot be overwritten; naming only
        # the flags is what lets notes, title, target and assets survive.
        api = self.api()
        run_main(api)

        ((_, _, payload),) = api.sent("PATCH", f"{REPO}/releases/", prefix=True)
        self.assertEqual(set(payload), {"prerelease", "make_latest"})
        self.assertIs(payload["prerelease"], False)
        self.assertEqual(payload["make_latest"], "true")

    def test_a_failed_correction_fails_the_run(self):
        # Leaving the flags wrong is the bug this action exists to fix, so it
        # must not pass silently.
        api = self.api(edit_status=422)
        with self.assertRaises(SystemExit):
            run_main(api)


class TestRace(unittest.TestCase):
    """Two jobs pushing the same tag race on the create."""

    def test_losing_the_race_reconciles_the_winners_release(self):
        # The lookup finds nothing, the create is rejected, and by then the
        # release exists: the winner's release is the one this run wanted.
        api = FakeApi(
            {
                ("GET", f"{REPO}/releases/tags/v37.0"): [
                    (404, {}),
                    (200, {"id": 555}),
                ],
                ("PATCH", f"{REPO}/releases/555"): [(200, {})],
                ("POST", f"{REPO}/releases/generate-notes"): [(200, {"body": "notes"})],
                ("POST", f"{REPO}/releases"): [
                    (
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
                ],
            }
        )
        output = run_main(api)

        ((_, path, _),) = api.sent("PATCH", f"{REPO}/releases/", prefix=True)
        self.assertEqual(path, f"{REPO}/releases/555")
        self.assertIn("appeared concurrently", output)

    def test_an_unrecoverable_create_reports_the_apis_reason(self):
        # Only annotation text shows up in the run summary and the checks UI,
        # so the API's reason has to reach it.
        api = FakeApi(
            {
                ("GET", f"{REPO}/releases/tags/v37.0"): [(404, {})],
                ("POST", f"{REPO}/releases/generate-notes"): [(200, {"body": "notes"})],
                ("POST", f"{REPO}/releases"): [
                    (403, {"message": "Resource not accessible by integration"})
                ],
            }
        )
        stderr = io.StringIO()
        with (
            mock.patch("sys.stderr", stderr),
            self.assertRaises(SystemExit) as raised,
        ):
            run_main(api)

        self.assertEqual(raised.exception.code, 1)
        self.assertIn("::error::", stderr.getvalue())
        self.assertIn("Resource not accessible by integration", stderr.getvalue())
        self.assertEqual(api.sent("PATCH", f"{REPO}/releases/", prefix=True), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
