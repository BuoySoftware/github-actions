#!/usr/bin/env python3
"""Tests tag resolution, path matching, and replacement in release_assets.py.

The dangerous outcome is a silent no-op: a run that reports success while the
release gains no asset. The cases concentrate on the refusals that prevent it,
and on the dispatch path where RELEASE_TAG rather than GITHUB_REF_NAME names
the tag.

Usage: python3 lib/test_release_assets.py
"""

import os
import sys
import unittest
from http import HTTPStatus
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import mock

# The module under test sits beside this file, which is not on the path when
# the tests are run from the repository root as CI does.
sys.path.insert(0, str(Path(__file__).resolve().parent))

import release_assets

UPLOAD = "https://uploads.example/repos/owner/repo/releases/1/assets{?name,label}"


class FakeApi:
    """Answers github_api calls, recording each one."""

    def __init__(self, release, upload_status=HTTPStatus.CREATED):
        self.release = release
        self.upload_status = upload_status
        self.calls = []
        self.uploads = []

    def release_for(self, repository, tag):
        self.calls.append(("release_for", tag))
        return self.release

    def request(self, method, path, payload=None):
        self.calls.append((method, path))
        return HTTPStatus.NO_CONTENT, None

    def upload(self, url, data):
        self.uploads.append((url, data))
        return self.upload_status, {}

    def error_message(self, body):
        return body.get("message", "?") if isinstance(body, dict) else "?"


def release(assets=()):
    return {"upload_url": UPLOAD, "assets": list(assets)}


def run(fake, pattern, environment):
    base = {"GITHUB_REPOSITORY": "owner/repo"}
    with (
        mock.patch.object(release_assets, "github_api", fake),
        mock.patch.dict("os.environ", base | environment, clear=True),
    ):
        release_assets.attach_all(pattern)


class AttachAllTest(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "example-sbom.spdx.json"
        self.path.write_text('{"spdxVersion": "SPDX-2.3"}')

    def test_dispatch_attaches_to_the_named_tag_not_the_launch_branch(self):
        fake = FakeApi(release())
        run(fake, str(self.path), {"RELEASE_TAG": "v1.0.0", "GITHUB_REF_NAME": "main"})

        self.assertIn(("release_for", "v1.0.0"), fake.calls)
        self.assertEqual(len(fake.uploads), 1)
        self.assertIn("name=example-sbom.spdx.json", fake.uploads[0][0])

    def test_tag_push_falls_back_to_the_pushed_ref(self):
        fake = FakeApi(release())
        run(fake, str(self.path), {"RELEASE_TAG": "", "GITHUB_REF_NAME": "v1.0.0"})

        self.assertIn(("release_for", "v1.0.0"), fake.calls)

    def test_glob_resolves_a_name_the_workflow_cannot_predict(self):
        fake = FakeApi(release())
        pattern = str(Path(self.directory.name) / "*.spdx.json")
        run(fake, pattern, {"GITHUB_REF_NAME": "v1.0.0"})

        self.assertEqual(len(fake.uploads), 1)

    def test_existing_asset_is_deleted_before_reupload(self):
        assets = [{"name": "example-sbom.spdx.json", "id": 99}]
        fake = FakeApi(release(assets))
        run(fake, str(self.path), {"GITHUB_REF_NAME": "v1.0.0"})

        self.assertIn(("DELETE", "/repos/owner/repo/releases/assets/99"), fake.calls)
        self.assertEqual(len(fake.uploads), 1)

    def test_missing_file_is_refused(self):
        fake = FakeApi(release())
        pattern = str(Path(self.directory.name) / "absent.spdx.json")
        with self.assertRaises(SystemExit):
            run(fake, pattern, {"GITHUB_REF_NAME": "v1.0.0"})

        self.assertEqual(fake.uploads, [])

    def test_empty_file_is_refused(self):
        self.path.write_text("")
        fake = FakeApi(release())
        with self.assertRaises(SystemExit):
            run(fake, str(self.path), {"GITHUB_REF_NAME": "v1.0.0"})

        self.assertEqual(fake.uploads, [])

    def test_absent_release_is_refused(self):
        fake = FakeApi(None)
        with self.assertRaises(SystemExit):
            run(fake, str(self.path), {"GITHUB_REF_NAME": "v1.0.0"})

        self.assertEqual(fake.uploads, [])

    def test_failed_upload_is_refused(self):
        fake = FakeApi(release(), upload_status=HTTPStatus.UNAUTHORIZED)
        with self.assertRaises(SystemExit):
            run(fake, str(self.path), {"GITHUB_REF_NAME": "v1.0.0"})


class ResolveTest(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    def test_relative_pattern_resolves_against_the_working_directory(self):
        (Path(self.directory.name) / "sbom.spdx.json").write_text("{}")
        previous = Path.cwd()
        os.chdir(self.directory.name)
        self.addCleanup(os.chdir, previous)

        self.assertEqual(
            [path.name for path in release_assets.resolve("*.spdx.json")],
            ["sbom.spdx.json"],
        )

    def test_directory_matching_the_pattern_is_ignored(self):
        (Path(self.directory.name) / "decoy.spdx.json").mkdir()
        pattern = str(Path(self.directory.name) / "*.spdx.json")
        self.assertEqual(release_assets.resolve(pattern), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
