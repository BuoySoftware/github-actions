#!/usr/bin/env python3
"""Attach the generated structure.sql to the pushed tag's GitHub release.

Reads the tag from GITHUB_REF_NAME and the file from STRUCTURE_SQL_PATH. An
existing release is attached to without being modified; a missing one is
created first. The upload replaces a same-named asset from an earlier run.
"""

import os
import sys
from http import HTTPStatus
from pathlib import Path
from typing import Any, NoReturn
from urllib.parse import quote

import github_api


def fail(message: str) -> NoReturn:
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


def release_for(repository: str, tag: str) -> dict | None:
    status, release = github_api.request(
        "GET", f"/repos/{repository}/releases/tags/{tag}"
    )
    if status == HTTPStatus.OK and isinstance(release, dict):
        return release
    return None


def created_release(repository: str, tag: str) -> dict:
    """The release for the tag, created now or found after losing the race."""
    payload: dict[str, Any] = {
        "tag_name": tag,
        "name": tag,
        "generate_release_notes": True,
        # `-rc.1` and `-rc1` are both in use.
        "prerelease": "-rc" in tag,
    }
    status, release = github_api.request(
        "POST", f"/repos/{repository}/releases", payload
    )
    if status == HTTPStatus.CREATED and isinstance(release, dict):
        print(f"Created release {tag}")
        return release

    # Another job may have cut the release between the lookup and the create.
    raced = release_for(repository, tag)
    if raced is not None:
        print(f"Release {tag} appeared concurrently; attaching to it")
        return raced

    fail(f"Could not create release {tag}: {github_api.error_message(release)}")


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


def main() -> None:
    tag = os.environ["GITHUB_REF_NAME"]
    repository = os.environ["GITHUB_REPOSITORY"]
    path = Path(os.environ["STRUCTURE_SQL_PATH"])

    release = release_for(repository, tag)
    if release is not None:
        print(f"Release {tag} already exists; attaching without modifying it")
    else:
        release = created_release(repository, tag)

    attach(repository, release, path)
    print(f"structure.sql attached to release {tag}")


if __name__ == "__main__":
    main()
