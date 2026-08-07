#!/usr/bin/env python3
"""Verify every expected asset is attached to the pushed tag's release.

A job that exits zero is not proof its asset landed, and a release that looks
fine with a missing asset is the failure nobody notices. EXPECT holds one
entry per line: an exact file name, or a `*`-pattern for producers that name
their own output (`*.spdx.json`).

The asset list is read from the paginated assets endpoint, not from the
truncated copy embedded in the release object, so the check cannot silently
stop checking as assets accumulate.
"""

import os
import sys
from fnmatch import fnmatch
from http import HTTPStatus
from pathlib import Path
from typing import NoReturn

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))

import github_api

PAGE_SIZE = 100


def fail(message: str) -> NoReturn:
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


def release_id(repository: str, tag: str) -> int:
    status, release = github_api.request(
        "GET", f"/repos/{repository}/releases/tags/{tag}"
    )
    if status != HTTPStatus.OK or not isinstance(release, dict):
        fail(
            f"Could not read release {tag} to verify its assets: "
            f"{github_api.error_message(release)}"
        )
    return release["id"]


def attached_names(repository: str, release: int) -> list[str]:
    names: list[str] = []
    page = 1
    while True:
        status, assets = github_api.request(
            "GET",
            f"/repos/{repository}/releases/{release}/assets"
            f"?per_page={PAGE_SIZE}&page={page}",
        )
        if status != HTTPStatus.OK or not isinstance(assets, list):
            fail(f"Could not list release assets: {github_api.error_message(assets)}")
        names.extend(asset["name"] for asset in assets)
        if len(assets) < PAGE_SIZE:
            return names
        page += 1


def main() -> None:
    tag = os.environ["TAG"]
    repository = os.environ["GITHUB_REPOSITORY"]
    expected = [line.strip() for line in os.environ["EXPECT"].splitlines()]
    expected = [entry for entry in expected if entry]
    if not expected:
        fail("EXPECT names no assets; nothing to verify is a configuration error")

    attached = attached_names(repository, release_id(repository, tag))
    missing = [
        entry
        for entry in expected
        if not any(fnmatch(name, entry) for name in attached)
    ]
    if missing:
        fail(
            f"attached to release {tag}: {', '.join(sorted(attached)) or 'nothing'}"
            f" -- missing: {', '.join(missing)}"
        )
    print(f"verified on release {tag}: {', '.join(expected)}")


if __name__ == "__main__":
    main()
