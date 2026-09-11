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


def main() -> None:
    release_assets.attach_all(os.environ["SBOM_PATH"])


if __name__ == "__main__":
    main()
