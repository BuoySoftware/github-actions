#!/usr/bin/env python3
"""Attach the generated structure.sql to a tag's GitHub release.

Reads the tag from RELEASE_TAG, falling back to the pushed tag in GITHUB_REF,
and the file from STRUCTURE_SQL_PATH.
"""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))

import release_assets


def main() -> None:
    release_assets.attach_all(os.environ["STRUCTURE_SQL_PATH"])


if __name__ == "__main__":
    main()
