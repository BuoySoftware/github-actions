#!/usr/bin/env python3
"""Attach the generated structure.sql to the pushed tag's GitHub release.

Reads the tag from GITHUB_REF_NAME and the file from STRUCTURE_SQL_PATH. The
release must already exist and is attached to without being modified. The
upload replaces a same-named asset from an earlier run.
"""

import os
import sys
from http import HTTPStatus
from pathlib import Path
from typing import NoReturn
from urllib.parse import quote

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))

import github_api


def fail(message: str) -> NoReturn:
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


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

    release = github_api.release_for(repository, tag)
    if release is None:
        fail(
            f"No release exists for {tag}: create-release cuts the release "
            "before artifact jobs run, and attaching does not create one"
        )

    attach(repository, release, path)
    print(f"structure.sql attached to release {tag}")


if __name__ == "__main__":
    main()
