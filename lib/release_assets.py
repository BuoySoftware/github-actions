#!/usr/bin/env python3
"""Attaching generated files to an existing tag's release.

Shared by the actions that generate a release artifact and upload it. The
release must already exist: attaching never creates one, so a run whose
release-cutting step has not happened fails rather than inventing a release.

Run as a script, it attaches the file named by ASSET_PATH to the release for
the tag in RELEASE_TAG, falling back to the pushed tag in GITHUB_REF:

    python3 lib/release_assets.py
"""

import os
import sys
from http import HTTPStatus
from pathlib import Path
from typing import NoReturn
from urllib.parse import quote

import github_api

TAG_REF_PREFIX = "refs/tags/"


def fail(message: str) -> NoReturn:
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


def resolve(path: str) -> Path | None:
    """The path, when it names an existing non-empty file."""
    candidate = Path(path)
    if candidate.is_file() and candidate.stat().st_size > 0:
        return candidate
    return None


def target_tag() -> str:
    """The tag whose release receives the upload.

    A dispatched run builds an arbitrary tag while the ref names the branch it
    was launched from, so the caller passes the tag explicitly. A run with
    neither an explicit tag nor a tag ref is refused rather than skipped: a
    skipped step reports success while the release gains no asset.
    """
    tag = os.environ.get("RELEASE_TAG", "").strip()
    if tag:
        return tag

    ref = os.environ.get("GITHUB_REF", "")
    if ref.startswith(TAG_REF_PREFIX):
        return ref[len(TAG_REF_PREFIX) :]

    fail(
        "upload_to_release is true but no tag could be resolved: pass "
        "release_tag, or run the action on a tag push"
    )


def attach(repository: str, release: dict, path: Path) -> None:
    """Upload the file to the release, replacing a same-named earlier asset."""
    name = path.name
    for asset in release.get("assets", []):
        if asset["name"] == name:
            status, body = github_api.request(
                "DELETE", f"/repos/{repository}/releases/assets/{asset['id']}"
            )
            if status != HTTPStatus.NO_CONTENT:
                fail(
                    f"Could not replace the existing {name} asset: "
                    f"{github_api.error_message(body)}"
                )

    url = release["upload_url"].split("{")[0] + f"?name={quote(name)}"
    status, body = github_api.upload(url, path.read_bytes())
    if status != HTTPStatus.CREATED:
        fail(f"Could not upload {name}: {github_api.error_message(body)}")


def attach_all(path: str) -> None:
    """Attach the generated file to the target tag's release."""
    repository = os.environ["GITHUB_REPOSITORY"]
    tag = target_tag()

    resolved = resolve(path)
    if resolved is None:
        fail(f"No non-empty file matches {path}")

    status, body = github_api.release_for(repository, tag)
    if status == HTTPStatus.NOT_FOUND:
        fail(
            f"No release exists for {tag}, or it is still a draft: the release "
            "is cut before artifact jobs run, attaching does not create one, "
            "and a draft must be published before assets can attach"
        )
    if status != HTTPStatus.OK or not isinstance(body, dict):
        fail(
            f"Could not look up the release for {tag}: the API answered "
            f"{status}: {github_api.error_message(body)}"
        )

    attach(repository, body, resolved)
    print(f"{resolved.name} attached to release {tag}")


if __name__ == "__main__":
    attach_all(os.environ["ASSET_PATH"])
