#!/usr/bin/env python3
"""Refuse an SBOM the generator did not really produce.

A file that parses but lists no packages, and a file that is not JSON at all,
are different failures: the first means the scan found nothing, the second
means the generator wrote something unusable. Reporting both as "no packages"
sends the operator after the wrong cause.

Reads the file from SBOM_PATH.
"""

import json
import os
import sys
from pathlib import Path


def main() -> None:
    path = Path(os.environ["SBOM_PATH"])
    raw = path.read_text()

    try:
        document = json.loads(raw)
    except json.JSONDecodeError as error:
        print(f"::error::SBOM is not valid JSON: {error}", file=sys.stderr)
        sys.exit(1)

    packages = document.get("packages", []) if isinstance(document, dict) else []
    print(f"packages: {len(packages)}")
    if not packages:
        print("::error::SBOM lists no packages", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
