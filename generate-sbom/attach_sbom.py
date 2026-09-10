#!/usr/bin/env python3
"""Attach the generated SBOM to a tag's GitHub release.

Reads the file from SBOM_PATH and the tag from RELEASE_TAG, falling back to
the pushed tag in GITHUB_REF. A run with neither is refused rather than
skipped: a skipped step reports success while the release gains no asset.
"""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))

import release_assets

TAG_REF_PREFIX = "refs/tags/"


def resolved_tag() -> str:
    tag = os.environ.get("RELEASE_TAG", "").strip()
    if tag:
        return tag

    ref = os.environ.get("GITHUB_REF", "")
    if ref.startswith(TAG_REF_PREFIX):
        return ref[len(TAG_REF_PREFIX) :]

    release_assets.fail(
        "upload_to_release is true but no tag could be resolved: pass "
        "release_tag, or run the action on a tag push"
    )


def main() -> None:
    os.environ["RELEASE_TAG"] = resolved_tag()
    release_assets.attach_all(os.environ["SBOM_PATH"])


if __name__ == "__main__":
    main()
