#!/usr/bin/env python3
"""Attaching generated files to an existing tag's release.

Shared by the actions that generate a release artifact and upload it. The
release must already exist: attaching never creates one, so a run whose
release-cutting step has not happened fails rather than inventing a release.
"""

import os
import sys
from http import HTTPStatus
from pathlib import Path
from typing import NoReturn
from urllib.parse import quote

import github_api


def fail(message: str) -> NoReturn:
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


def resolve(pattern: str) -> list[Path]:
    """Every existing non-empty file matching the path or glob.

    A glob is accepted because a generator may name its output after the
    repository and version, which the calling workflow does not know.
    """
    root = Path(pattern)
    relative = str(root.relative_to(root.anchor)) if root.anchor else str(root)
    matches = sorted(Path(root.anchor or ".").glob(relative))
    return [path for path in matches if path.is_file() and path.stat().st_size > 0]


def target_tag() -> str:
    """The tag whose release receives the upload.

    A dispatched run builds an arbitrary tag while GITHUB_REF_NAME names the
    branch it was launched from, so the caller passes the tag explicitly.
    """
    return os.environ.get("RELEASE_TAG") or os.environ["GITHUB_REF_NAME"]


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


def attach_all(pattern: str) -> None:
    """Attach every file matching the pattern to the target tag's release."""
    repository = os.environ["GITHUB_REPOSITORY"]
    tag = target_tag()

    paths = resolve(pattern)
    if not paths:
        fail(f"No non-empty file matches {pattern}")

    release = github_api.release_for(repository, tag)
    if release is None:
        fail(
            f"No release exists for {tag}: the release is cut before artifact "
            "jobs run, and attaching does not create one"
        )

    for path in paths:
        attach(repository, release, path)
        print(f"{path.name} attached to release {tag}")
