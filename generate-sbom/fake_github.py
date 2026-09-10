#!/usr/bin/env python3
"""The upload harness's stand-in GitHub API, serving one fixture directory.

The release-asset routes live in lib/fake_github.py; see ReleaseAssetHandler
for the fixture files that configure the responses.

Usage: python3 generate-sbom/fake_github.py <fixture-dir>
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))

import fake_github

if __name__ == "__main__":
    fake_github.serve(fake_github.ReleaseAssetHandler, Path(sys.argv[1]))
