#!/usr/bin/env python3
"""Create the GitHub release for the pushed tag, or correct an existing one.

Reads the tag from TAG and its resolved identity from LATEST, NOTES_START and
PRERELEASE, and talks to the release REST API directly.

When the release already exists -- because someone cut it by hand, or because
another job won the race on the same tag -- its prerelease and "Latest" flags
are corrected instead. The correction patches the release by id and names only
those two fields, so notes, title, target and any attached assets survive it.

Runs on the system interpreter with the standard library only.
"""

import os
import sys
from http import HTTPStatus
from typing import Any, NoReturn

import github_api


def fail(message: str) -> NoReturn:
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


def existing_release(repository: str, tag: str) -> int | None:
    """The id of the tag's release, or None when it cannot be found.

    Only a definite hit counts. A lookup that failed for another reason is
    treated as absence, so the create that follows surfaces the real error
    with the API's own message rather than this probe masking it.
    """
    status, release = github_api.request(
        "GET", f"/repos/{repository}/releases/tags/{tag}"
    )
    if status == HTTPStatus.OK and isinstance(release, dict):
        return int(release["id"])
    return None


def reconcile(
    repository: str, release: int, tag: str, prerelease: str, latest: str
) -> None:
    """Correct the flags on an existing release, leaving everything else alone.

    Both flags are always stated, not just the one that happens to be wrong.
    The payload names nothing else: a field the PATCH does not send cannot be
    overwritten, which is what lets a human-edited release survive the
    correction. In particular it never names the tag -- recreating the release
    by tag is rejected as already_exists, and the rejection takes any attached
    asset with it.
    """
    status, body = github_api.request(
        "PATCH",
        f"/repos/{repository}/releases/{release}",
        {"prerelease": prerelease == "true", "make_latest": latest},
    )
    if status != HTTPStatus.OK:
        fail(
            f"Could not correct the release flags on {tag}: "
            f"{github_api.error_message(body)}"
        )
    print(f"Corrected {tag}: prerelease={prerelease} latest={latest}")


def generated_notes(repository: str, tag: str, notes_start: str) -> str:
    """The release notes for the tag, generated back to the resolved base."""
    status, notes = github_api.request(
        "POST",
        f"/repos/{repository}/releases/generate-notes",
        {"tag_name": tag, "previous_tag_name": notes_start},
    )
    if status != HTTPStatus.OK:
        fail(
            f"Could not generate notes for {tag} from {notes_start}: "
            f"{github_api.error_message(notes)}"
        )
    return str(notes["body"])


def main() -> None:
    tag = os.environ["TAG"]
    repository = os.environ["GITHUB_REPOSITORY"]
    latest = os.environ["LATEST"]
    notes_start = os.environ["NOTES_START"]
    prerelease = os.environ["PRERELEASE"]

    release = existing_release(repository, tag)
    if release is not None:
        print(f"Release {tag} already exists; correcting its flags")
        reconcile(repository, release, tag, prerelease, latest)
        return

    # "Latest" is three-state on the API: omitting make_latest is not the same
    # as declining it, and the fallback is publish order.
    payload: dict[str, Any] = {
        "tag_name": tag,
        "name": tag,
        "prerelease": prerelease == "true",
        "make_latest": latest,
    }
    if notes_start:
        payload["body"] = generated_notes(repository, tag, notes_start)
    else:
        # No boundary at all: notes are still generated, from the entire
        # history, because nothing precedes this release. An empty
        # previous_tag_name would be rejected rather than meaning that.
        payload["generate_release_notes"] = True

    status, created = github_api.request(
        "POST", f"/repos/{repository}/releases", payload
    )
    if status == HTTPStatus.CREATED:
        print(
            f"Created release {tag}: prerelease={prerelease} latest={latest} "
            f"notes base={notes_start or '<none>'}"
        )
        return

    # Another job pushing the same tag may have won the race. Its release is
    # the one this run wanted, so reconcile the flags onto it rather than
    # failing.
    release = existing_release(repository, tag)
    if release is not None:
        print(f"Release {tag} appeared concurrently; correcting its flags")
        reconcile(repository, release, tag, prerelease, latest)
        return

    fail(f"Could not create release {tag}: {github_api.error_message(created)}")


if __name__ == "__main__":
    main()
