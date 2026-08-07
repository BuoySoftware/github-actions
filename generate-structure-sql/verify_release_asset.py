#!/usr/bin/env python3
"""Verify the structure.sql asset is attached to the pushed tag's release.

A clean exit from the upload is not proof the asset landed. The check requires
the exact file name, so a near-miss like `structure.sql.gz` does not count.
"""

import os
import sys
from http import HTTPStatus
from pathlib import Path
from typing import NoReturn

import github_api


def fail(message: str) -> NoReturn:
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    tag = os.environ["GITHUB_REF_NAME"]
    repository = os.environ["GITHUB_REPOSITORY"]
    name = Path(os.environ["STRUCTURE_SQL_PATH"]).name

    status, release = github_api.request(
        "GET", f"/repos/{repository}/releases/tags/{tag}"
    )
    if status != HTTPStatus.OK or not isinstance(release, dict):
        fail(
            f"Could not read release {tag} to verify its assets: "
            f"{github_api.error_message(release)}"
        )

    attached = [asset["name"] for asset in release.get("assets", [])]
    if name not in attached:
        fail(f"{name} is not attached to release {tag}")
    print(f"verified {name} is attached to release {tag}")


if __name__ == "__main__":
    main()
