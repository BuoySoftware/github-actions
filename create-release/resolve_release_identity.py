#!/usr/bin/env python3
"""Derive a release's identity from the repository's tag list.

Reads the pushed tag from TAG and the repository from GITHUB_REPOSITORY, lists
tags over the API with `gh`, and writes `latest`, `notes_start` and `prerelease`
to $GITHUB_OUTPUT.

Runs on the system interpreter with the standard library only, so the action
needs no checkout, runtime setup or dependency install.
"""

import os
import re
import subprocess
import sys

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


class Tag:
    """A parsed version tag, ordered by its numbers and then its ordinal.

    The numbers are held by position rather than by name, because what each
    position means differs between repositories while the ranking does not. An
    absent third number counts as zero, so `v2.2` and `v2.2.0` are one version.
    """

    def __init__(self, name, version, ordinal):
        self.name = name
        self.version = version
        self.ordinal = ordinal

    @classmethod
    def parse(cls, name):
        """The parsed tag, or None when `name` is not a version tag."""
        match = TAG_PATTERN.match(name)
        if not match:
            return None
        first, second, third, ordinal = match.groups()
        version = (int(first), int(second), int(third or 0))
        return cls(name, version, FINAL if ordinal is None else int(ordinal))

    @property
    def is_final(self):
        return self.ordinal == FINAL

    @property
    def rank(self):
        return (self.version, self.ordinal)


def fail(message):
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


def list_tags(repository, max_pages):
    """Every version tag in the repository, a page at a time.

    Tags come from the API, so the action needs no checkout. Identity is decided
    by comparing the pushed tag against the others, and a shallow checkout would
    narrow that comparison into a plausible wrong answer with nothing to detect
    it.

    Every version tag is a candidate boundary, including test and personal ones:
    excluding those would make the notes base depend on who cut the surrounding
    tags.

    Yields None at each page boundary, so the caller can decide whether it has
    seen enough without this function knowing what it is looking for.
    """
    for page in range(1, max_pages + 1):
        result = subprocess.run(
            [
                "gh",
                "api",
                f"repos/{repository}/tags?per_page=100&page={page}",
                "--jq",
                ".[].name",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            fail(f"Could not list tags for {repository} (page {page})")

        names = [line for line in result.stdout.splitlines() if line]
        if not names:
            # The listing ran out, so every tag there is has been seen.
            return
        for name in names:
            tag = Tag.parse(name)
            if tag:
                yield tag
        yield None
    fail(
        f"Reached the {max_pages}-page tag listing limit for {repository} "
        "without finding a version below the pushed tag. Refusing to pick a "
        "notes base from a partial tag list."
    )


def collect_tags(repository, max_pages, pushed):
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
    """
    tags = []
    for tag in list_tags(repository, max_pages):
        if tag is None:
            if any(seen.version < pushed.version for seen in tags):
                break
        else:
            tags.append(tag)
    return sorted(tags, key=lambda tag: tag.rank)


def commit_of(tag):
    """The commit a tag names, or None when it names none or cannot be resolved."""
    result = subprocess.run(
        ["git", "rev-list", "-n", "1", tag.name],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout.strip() or None


def published_boundary(version_tags):
    """The tag a version line published, or None when it holds no tags.

    Its final when the final names the same commit as the line's last candidate,
    otherwise that candidate. A final cut before the line's last candidate sits
    behind it, and basing on it would re-describe everything those later
    candidates already covered.

    The two are compared by the commit each names, not by version: a final always
    outranks its own candidates, so ranking alone cannot tell a published
    boundary from one cut before the version finished.
    """
    candidates = [tag for tag in version_tags if not tag.is_final]
    finals = [tag for tag in version_tags if tag.is_final]

    if not candidates:
        return finals[-1] if finals else None
    if not finals:
        return candidates[-1]

    final, candidate = finals[-1], candidates[-1]
    final_commit = commit_of(final)
    if final_commit and final_commit == commit_of(candidate):
        return final
    return candidate


def notes_base(tags, pushed):
    """The tag the release notes should be generated from, or None for no base.

    Without a base the create step omits the boundary rather than passing an
    empty one, which would generate notes from the entire history.
    """
    # The highest tag below the pushed tag within its own version. Each candidate
    # then documents only what changed since the last one.
    #
    # A final outranks every candidate of its version, so ranking below the
    # pushed tag already means the match is a candidate.
    same_version = [
        tag for tag in tags if tag.version == pushed.version and tag.rank < pushed.rank
    ]
    if same_version:
        return same_version[-1]

    # Nothing below it in its own version, so reach back to the highest version
    # below and take that line's published boundary.
    lower = [tag.version for tag in tags if tag.version < pushed.version]
    if not lower:
        return None
    highest_lower = max(lower)
    return published_boundary([tag for tag in tags if tag.version == highest_lower])


def claims_latest(tags, pushed):
    """Whether the pushed tag should be published as "Latest".

    "Latest" is publish-order by default, which is what put an older release
    under it. A final claims it only when no final sorts above the pushed tag;
    candidates never claim it.
    """
    if not pushed.is_final:
        return False
    return not any(tag.is_final and tag.rank > pushed.rank for tag in tags)


def main():
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

    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        for key, value in identity.items():
            print(f"{key}={value}", file=output)

    print(
        f"{name}: prerelease={identity['prerelease']} "
        f"latest={identity['latest']} "
        f"notes base={identity['notes_start'] or '<none>'}"
    )


if __name__ == "__main__":
    main()
