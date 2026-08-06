#!/usr/bin/env python3
"""Derive a release's identity from the repository's tag list.

Reads the pushed tag from TAG and the repository from GITHUB_REPOSITORY, lists
tags over the REST API, and writes `latest`, `notes_start` and `prerelease` to
$GITHUB_OUTPUT.

Runs on the system interpreter with the standard library only, so the action
needs no checkout, runtime setup, CLI or dependency install.
"""

import os
import re
import sys
from collections.abc import Iterator
from dataclasses import dataclass
from http import HTTPStatus
from pathlib import Path
from typing import NoReturn

import github_api

# Two or three dot-separated numbers, an optional release-candidate ordinal, and
# an optional collision-avoidance suffix.
#
# The leading `v` is required. It is what separates the current scheme from the
# retired `YYYYMMDD.N` one, whose tags would otherwise parse as versions with a
# leading number in the millions and outrank every real release.
TAG_PATTERN = re.compile(
    r"""^v
    (\d+)\.(\d+)           # the first two numbers, always present
    (?:\.(\d+))?           # an optional third
    (?:-rc\.?(\d+))?       # an optional release-candidate ordinal
    (?:-[A-Za-z0-9_.-]+)?  # an optional trailing suffix, ignored
    $""",
    re.VERBOSE,
)

# A final release has no ordinal. Ranking it above every candidate of its own
# version needs no special case at each comparison if it simply holds the
# highest possible ordinal.
FINAL = sys.maxsize

# The dot-separated numbers, and the whole tag's position in the ordering.
Version = tuple[int, int, int]
Rank = tuple[Version, int]


@dataclass(frozen=True)
class Tag:
    """A parsed version tag, ordered by its numbers and then its ordinal.

    The numbers are held by position rather than by name, because what each
    position means differs between repositories while the ranking does not. An
    absent third number counts as zero, so `v2.2` and `v2.2.0` are one version.

    `commit` is the commit the tag names, which decides which tag a completed
    version line published. It comes from the tag listing, which resolves an
    annotated tag to its commit rather than reporting the tag object.

    `explicit_patch` records whether the tag wrote its third number, which is
    what tells a live three-number scheme's tags from a retired two-number
    scheme's.
    """

    name: str
    version: Version
    ordinal: int
    commit: str = ""
    explicit_patch: bool = True

    @classmethod
    def parse(cls, name: str, commit: str = "") -> "Tag | None":
        """The parsed tag, or None when `name` is not a version tag."""
        match = TAG_PATTERN.match(name)
        if not match:
            return None
        first, second, third, ordinal = match.groups()
        version: Version = (int(first), int(second), int(third or 0))
        ranked = FINAL if ordinal is None else int(ordinal)
        return cls(name, version, ranked, commit, third is not None)

    @property
    def is_final(self) -> bool:
        return self.ordinal == FINAL

    @property
    def rank(self) -> Rank:
        return (self.version, self.ordinal)


def fail(message: str) -> NoReturn:
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


def list_tags(repository: str, max_pages: int) -> Iterator[Tag | None]:
    """Every version tag in the repository, a page at a time.

    Tags and the commit each one names both come from the API, so the action
    needs no checkout. No tag is excluded: test and personal tags are ordinary
    candidates, or the notes base would depend on who cut the surrounding tags.

    Yields None at each page boundary, so the caller can decide whether it has
    seen enough without this function knowing what it is looking for.
    """
    for page in range(1, max_pages + 1):
        status, entries = github_api.request(
            "GET", f"/repos/{repository}/tags?per_page=100&page={page}"
        )
        if status != HTTPStatus.OK:
            fail(
                f"Could not list tags for {repository} (page {page}): "
                f"{github_api.error_message(entries)}"
            )

        if not entries:
            # The listing ran out, so every tag there is has been seen.
            return
        for entry in entries:
            tag = Tag.parse(entry["name"], entry["commit"]["sha"])
            if tag:
                yield tag
        yield None
    fail(
        f"Reached the {max_pages}-page tag listing limit for {repository} "
        "without finding a version below the pushed tag. Refusing to pick a "
        "notes base from a partial tag list."
    )


def collect_tags(repository: str, max_pages: int, pushed: Tag) -> list[Tag]:
    """The tags needed to decide `pushed`'s identity, in ascending order.

    Paging stops after the page on which a version strictly below the pushed
    tag's appears. The notes base is either in the pushed tag's own version or in
    the highest one below it, and the listing is ordered newest-first, so a page
    holding a lower version bounds anything a later page could contribute.

    The whole page is consumed before stopping rather than only up to the first
    lower tag, because the order within a page is the API's and not a version
    ranking: it places a version's final after its own candidates, and sorts
    v100 above v99. Tag dates are not consulted either, since tags are routinely
    cut out of chronological order, nor is commit ancestry: most release tags are
    unreachable from the default branch.

    A three-number push sees only three-number tags. A repository that writes
    all three numbers has retired any two-number scheme it used before, and the
    retired tags overlap the live scheme's numbers — both counted through the
    same majors — so they are dropped entirely rather than ranked. Dropped tags
    do not bound paging either, or the base could be cut off behind one. A
    two-number push filters nothing.
    """
    tags = []
    for tag in list_tags(repository, max_pages):
        if tag is None:
            if any(seen.version < pushed.version for seen in tags):
                break
        elif not pushed.explicit_patch or tag.explicit_patch:
            tags.append(tag)
    return sorted(tags, key=lambda tag: tag.rank)


def published_boundary(version_tags: list[Tag]) -> Tag | None:
    """The tag a version line published, or None when it holds no tags.

    Its final when the final names the same commit as the line's last candidate,
    otherwise that candidate. A final cut before the line's last candidate sits
    behind it, and basing on it would re-describe everything those later
    candidates already covered.

    The two are compared by the commit each names, not by version: a final always
    outranks its own candidates, so ranking alone cannot tell a published
    boundary from one cut before the version finished.

    A tag whose commit is unknown cannot be shown to be the published boundary,
    so the line's last candidate stands.
    """
    candidates = [tag for tag in version_tags if not tag.is_final]
    finals = [tag for tag in version_tags if tag.is_final]

    if not candidates:
        return finals[-1] if finals else None
    if not finals:
        return candidates[-1]

    final, candidate = finals[-1], candidates[-1]
    if final.commit and final.commit == candidate.commit:
        return final
    return candidate


def notes_base(tags: list[Tag], pushed: Tag) -> Tag | None:
    """The tag the release notes should be generated from, or None for no base.

    Without a base the create step omits the boundary rather than passing an
    empty one, which would generate notes from the entire history.
    """
    # A candidate bases on the highest candidate below it in its own version,
    # documenting only what changed since the last one. A final never does: it
    # is promoted at the commit its last candidate already names, so basing it
    # there would generate empty notes. The final reaches back instead, and its
    # notes describe the whole version.
    if not pushed.is_final:
        same_version = [
            tag
            for tag in tags
            if tag.version == pushed.version and tag.rank < pushed.rank
        ]
        if same_version:
            return same_version[-1]

    # Reach back to the highest version below and take that line's published
    # boundary.
    lower = [tag.version for tag in tags if tag.version < pushed.version]
    if not lower:
        return None
    highest_lower = max(lower)
    return published_boundary([tag for tag in tags if tag.version == highest_lower])


def claims_latest(tags: list[Tag], pushed: Tag) -> bool:
    """Whether the pushed tag should be published as "Latest".

    "Latest" is publish-order by default, which is what put an older release
    under it. A final claims it only when no final sorts above the pushed tag;
    candidates never claim it.
    """
    if not pushed.is_final:
        return False
    return not any(tag.is_final and tag.rank > pushed.rank for tag in tags)


def main() -> None:
    name = os.environ["TAG"]
    repository = os.environ["GITHUB_REPOSITORY"]
    max_pages = int(os.environ["MAX_PAGES"])

    pushed = Tag.parse(name)
    if not pushed:
        fail(
            f"{name} is not a version tag; expected two or three dot-separated "
            "numbers, as v1.2 or v1.2.3, optionally followed by -rc<n> and a "
            "suffix"
        )

    tags = collect_tags(repository, max_pages, pushed)
    base = notes_base(tags, pushed)

    # A release candidate, and only a release candidate, is a prerelease. The
    # ordinal is what decides it, so a suffix that merely contains "rc" is not a
    # candidate.
    identity = {
        "latest": str(claims_latest(tags, pushed)).lower(),
        "notes_start": base.name if base else "",
        "prerelease": str(not pushed.is_final).lower(),
    }

    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        for key, value in identity.items():
            print(f"{key}={value}", file=output)

    print(
        f"{name}: prerelease={identity['prerelease']} "
        f"latest={identity['latest']} "
        f"notes base={identity['notes_start'] or '<none>'}"
    )


if __name__ == "__main__":
    main()
