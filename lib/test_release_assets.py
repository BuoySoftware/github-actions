#!/usr/bin/env python3
"""Tests tag resolution, path checks, and replacement in release_assets.py.

The dangerous outcome is a silent no-op: a run that reports success while the
release gains no asset. The cases concentrate on the refusals that prevent it,
and on the dispatch path where RELEASE_TAG rather than GITHUB_REF_NAME names
the tag.

Usage: python3 lib/test_release_assets.py
"""

import os
import runpy
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

    def __init__(
        self,
        release,
        upload_status=HTTPStatus.CREATED,
        lookup_status=HTTPStatus.OK,
        delete_status=HTTPStatus.NO_CONTENT,
    ):
        self.release = release
        self.upload_status = upload_status
        self.lookup_status = lookup_status
        self.delete_status = delete_status
        self.calls = []
        self.uploads = []

    def release_for(self, repository, tag):
        self.calls.append(("release_for", tag))
        return self.lookup_status, self.release

    def request(self, method, path, payload=None):
        self.calls.append((method, path))
        return self.delete_status, {"message": "Forbidden"}

    def upload(self, url, data):
        self.uploads.append((url, data))
        return self.upload_status, {}

    def error_message(self, body):
        return body.get("message", "?") if isinstance(body, dict) else "?"


def release(assets=()):
    return {"upload_url": UPLOAD, "assets": list(assets)}


def run(fake, path, environment):
    base = {"GITHUB_REPOSITORY": "owner/repo"}
    with (
        mock.patch.object(release_assets, "github_api", fake),
        mock.patch.dict("os.environ", base | environment, clear=True),
    ):
        release_assets.attach_all(path)


def refusal(test, fake, path, environment):
    """The exit code of a run that must refuse, asserted to be non-zero."""
    with test.assertRaises(SystemExit) as raised:
        run(fake, path, environment)

    test.assertNotEqual(raised.exception.code, 0)
    return raised.exception.code


class AttachAllTest(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "example-sbom.spdx.json"
        self.path.write_text('{"spdxVersion": "SPDX-2.3"}')

    def test_dispatch_attaches_to_the_named_tag_not_the_launch_branch(self):
        fake = FakeApi(release())
        run(
            fake,
            str(self.path),
            {"RELEASE_TAG": "v1.0.0", "GITHUB_REF": "refs/heads/main"},
        )

        self.assertIn(("release_for", "v1.0.0"), fake.calls)
        self.assertEqual(len(fake.uploads), 1)
        self.assertIn("name=example-sbom.spdx.json", fake.uploads[0][0])

    def test_tag_push_falls_back_to_the_pushed_ref(self):
        fake = FakeApi(release())
        run(fake, str(self.path), {"RELEASE_TAG": "", "GITHUB_REF": "refs/tags/v1.0.0"})

        self.assertIn(("release_for", "v1.0.0"), fake.calls)

    def test_existing_asset_is_deleted_before_reupload(self):
        assets = [{"name": "example-sbom.spdx.json", "id": 99}]
        fake = FakeApi(release(assets))
        run(fake, str(self.path), {"GITHUB_REF": "refs/tags/v1.0.0"})

        self.assertIn(("DELETE", "/repos/owner/repo/releases/assets/99"), fake.calls)
        self.assertEqual(len(fake.uploads), 1)

    def test_a_branch_push_with_no_named_tag_is_refused(self):
        fake = FakeApi(release())
        refusal(self, fake, str(self.path), {"GITHUB_REF": "refs/heads/main"})

        self.assertEqual(fake.calls, [])
        self.assertEqual(fake.uploads, [])

    def test_missing_file_is_refused(self):
        fake = FakeApi(release())
        absent = str(Path(self.directory.name) / "absent.spdx.json")
        refusal(self, fake, absent, {"GITHUB_REF": "refs/tags/v1.0.0"})

        self.assertEqual(fake.uploads, [])

    def test_empty_file_is_refused(self):
        self.path.write_text("")
        fake = FakeApi(release())
        refusal(self, fake, str(self.path), {"GITHUB_REF": "refs/tags/v1.0.0"})

        self.assertEqual(fake.uploads, [])

    def test_absent_release_is_refused(self):
        fake = FakeApi(None, lookup_status=HTTPStatus.NOT_FOUND)
        refusal(self, fake, str(self.path), {"GITHUB_REF": "refs/tags/v1.0.0"})

        self.assertEqual(fake.uploads, [])

    def test_a_404_blames_the_missing_or_draft_release(self):
        fake = FakeApi({"message": "Not Found"}, lookup_status=HTTPStatus.NOT_FOUND)
        with mock.patch.object(release_assets, "print") as printed:
            refusal(self, fake, str(self.path), {"GITHUB_REF": "refs/tags/v1.0.0"})

        message = printed.call_args[0][0]
        self.assertIn("No release exists for v1.0.0, or it is still a draft", message)

    def test_a_403_does_not_claim_the_release_is_missing(self):
        # A denied or rate-limited lookup sends the operator to the token, not
        # to re-cutting a release that exists.
        fake = FakeApi({"message": "Forbidden"}, lookup_status=HTTPStatus.FORBIDDEN)
        with mock.patch.object(release_assets, "print") as printed:
            refusal(self, fake, str(self.path), {"GITHUB_REF": "refs/tags/v1.0.0"})

        message = printed.call_args[0][0]
        self.assertNotIn("No release exists", message)
        self.assertIn("403", message)
        self.assertIn("Forbidden", message)
        self.assertEqual(fake.uploads, [])

    def test_failed_upload_is_refused(self):
        fake = FakeApi(release(), upload_status=HTTPStatus.UNAUTHORIZED)
        refusal(self, fake, str(self.path), {"GITHUB_REF": "refs/tags/v1.0.0"})

    def test_failed_delete_is_refused(self):
        # A replacement that cannot delete must not upload: the release would
        # otherwise keep the stale asset under a collided name.
        assets = [{"name": "example-sbom.spdx.json", "id": 99}]
        fake = FakeApi(release(assets), delete_status=HTTPStatus.FORBIDDEN)
        refusal(self, fake, str(self.path), {"GITHUB_REF": "refs/tags/v1.0.0"})

        self.assertEqual(fake.uploads, [])


class ResolveTest(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    def test_a_relative_path_resolves_against_the_working_directory(self):
        (Path(self.directory.name) / "sbom.spdx.json").write_text("{}")
        previous = Path.cwd()
        os.chdir(self.directory.name)
        self.addCleanup(os.chdir, previous)

        resolved = release_assets.resolve("sbom.spdx.json")
        self.assertEqual(resolved and resolved.name, "sbom.spdx.json")

    def test_a_directory_at_the_path_is_not_a_file(self):
        decoy = Path(self.directory.name) / "decoy.spdx.json"
        decoy.mkdir()
        self.assertIsNone(release_assets.resolve(str(decoy)))

    def test_an_empty_file_does_not_resolve(self):
        empty = Path(self.directory.name) / "sbom.spdx.json"
        empty.write_text("")
        self.assertIsNone(release_assets.resolve(str(empty)))


class ScriptEntryTest(unittest.TestCase):
    """The upload steps run this module directly, with ASSET_PATH."""

    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "example-sbom.spdx.json"
        self.path.write_text('{"spdxVersion": "SPDX-2.3"}')

    def run_script(self, environment):
        base = {"GITHUB_REPOSITORY": "owner/repo"}
        with (
            mock.patch.dict("os.environ", base | environment, clear=True),
            mock.patch.dict(sys.modules, {"github_api": self.fake}),
        ):
            runpy.run_path(str(Path(release_assets.__file__)), run_name="__main__")

    def test_asset_path_is_attached_to_the_named_tag(self):
        self.fake = FakeApi(release())
        self.run_script({"ASSET_PATH": str(self.path), "RELEASE_TAG": "v1.0.0"})

        self.assertIn(("release_for", "v1.0.0"), self.fake.calls)
        self.assertEqual(len(self.fake.uploads), 1)
        self.assertIn("name=example-sbom.spdx.json", self.fake.uploads[0][0])

    def test_an_absent_asset_path_is_not_a_silent_success(self):
        self.fake = FakeApi(release())
        with self.assertRaises(KeyError):
            self.run_script({"RELEASE_TAG": "v1.0.0"})

        self.assertEqual(self.fake.uploads, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
