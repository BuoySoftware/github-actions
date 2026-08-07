#!/usr/bin/env python3
"""Tests the release-identity ranking in resolve_release_identity.py.

Release identity is easy to get wrong in ways that look green. Notes generated
from the wrong base silently describe the wrong range of commits, often hundreds
of them. A final release that declines "Latest" leaves consumers pointing at an
older version, and a candidate that claims it misdirects everyone.

Ranking is a pure function of the tag list, so it is tested by calling it
directly. The tag listing is served in an order that is deliberately not version
order, matching the API: a function that trusts the order it receives fails here.

Usage: python3 create-release/test_resolve_release_identity.py
"""

import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

# The script under test sits beside this file, which is not on the path when the
# tests are run from the repository root as CI does.
sys.path.insert(0, str(Path(__file__).resolve().parent))

import resolve_release_identity as identity

_DERIVE = object()


def parsed(name: str, commit: object = _DERIVE) -> identity.Tag:
    """The parsed tag, failing the test when it is not a version tag.

    Passing no commit derives one from the name, so tags sit on distinct commits
    unless a case co-locates them. Passing `""` means the listing gave no commit,
    which is a case in its own right and must not be confused with the default.
    """
    resolved = f"sha-{name}" if commit is _DERIVE else str(commit)
    tag = identity.Tag.parse(name, resolved)
    if tag is None:
        raise AssertionError(f"{name} should parse as a version tag")
    return tag


def tags(*names: str) -> list[identity.Tag]:
    """The named tags, ranked, as collect_tags would return them.

    Names that are not version tags are dropped, as they are from the listing.
    """
    candidates = [identity.Tag.parse(name, f"sha-{name}") for name in names]
    return sorted((tag for tag in candidates if tag), key=lambda tag: tag.rank)


def notes_base(pushed: str, *names: str) -> str | None:
    """The notes base, with each tag on its own commit."""
    base = identity.notes_base(tags(*names), parsed(pushed))
    return base.name if base else None


def listing(names: list[str]) -> list[dict]:
    """A page of the tags API response, each tag on a commit named after it."""
    return [{"name": name, "commit": {"sha": f"sha-{name}"}} for name in names]


def claims_latest(pushed: str, *names: str) -> bool:
    return identity.claims_latest(tags(*names), parsed(pushed))


class TestParse(unittest.TestCase):
    def test_accepts_two_and_three_part_versions(self):
        self.assertEqual(parsed("v3.0").version, (3, 0, 0))
        self.assertEqual(parsed("v2.2.1").version, (2, 2, 1))

    def test_absent_third_number_counts_as_zero(self):
        # `v2.2` and `v2.2.0` name one version, so a repository that writes both
        # shapes does not get two release lines out of them.
        self.assertEqual(parsed("v2.2").version, parsed("v2.2.0").version)

    def test_accepts_dotted_and_dotless_ordinals(self):
        self.assertEqual(parsed("v1.0-rc.4").ordinal, 4)
        self.assertEqual(parsed("v1.0-rc4").ordinal, 4)

    def test_a_tag_with_no_ordinal_is_final(self):
        self.assertTrue(parsed("v1.0").is_final)
        self.assertFalse(parsed("v1.0-rc.1").is_final)

    def test_suffixes_carry_no_ordering_information(self):
        # Suffixes exist to avoid collisions, so two tags differing only by one
        # rank equally.
        self.assertEqual(
            parsed("v36.0-rc.6-mega").rank,
            parsed("v36.0-rc.6").rank,
        )

    def test_rejects_a_suffix_that_merely_contains_rc(self):
        # An ordinal is what makes a candidate. A branch name is not one.
        self.assertTrue(parsed("v1.0-rcsomething").is_final)

    def test_requires_the_leading_v(self):
        # The retired `YYYYMMDD.N` scheme parses as versions with a leading
        # number in the millions, which would outrank every real release forever.
        self.assertIsNone(identity.Tag.parse("20240131.1"))
        self.assertIsNone(identity.Tag.parse("35.3"))

    def test_rejects_non_version_tags(self):
        for name in ("latest", "v1", "v1.x", "release-1.0", "v1.0.0.0"):
            with self.subTest(name=name):
                self.assertIsNone(identity.Tag.parse(name))

    def test_records_whether_the_third_number_was_written(self):
        # `v2.2` and `v2.2.0` rank identically, but the shape still matters: it
        # is what tells a retired two-number scheme's tags from a live
        # three-number scheme's.
        self.assertFalse(parsed("v2.2").explicit_patch)
        self.assertTrue(parsed("v2.2.0").explicit_patch)

    def test_finals_outrank_every_candidate_of_their_version(self):
        final = parsed("v1.0")
        for ordinal in ("1", "9", "999999"):
            with self.subTest(ordinal=ordinal):
                self.assertGreater(final.rank, parsed(f"v1.0-rc.{ordinal}").rank)

    def test_ranks_numbers_left_to_right(self):
        ordered = ["v2.2.0", "v2.2.1", "v2.3.0", "v3.0.0", "v10.0.0", "v100.0.0"]
        self.assertEqual([tag.name for tag in tags(*reversed(ordered))], ordered)


class TestNotesBase(unittest.TestCase):
    # Mirrors the shapes the real repositories carry: two- and three-part
    # versions, dotted and dotless ordinals, trailing suffixes, and a sparse gap
    # where a minor was never cut.
    MAIN = (
        "v35.3",
        "v36.0-rc.1",
        "v36.0-rc.6-mega",
        "v36.0-rc.7-mega",
        "v36.0",
        "v36.1",
        "v37.0-rc.1",
        "v37.0-rc.3",
        "v37.0-rc.4",
    )

    def test_a_candidate_bases_on_the_one_below_it(self):
        # Each candidate then documents only what changed since the last one.
        self.assertEqual(notes_base("v37.0-rc.4", *self.MAIN), "v37.0-rc.3")

    def test_a_final_reaches_back_past_its_own_candidates(self):
        # The final is promoted at the commit its last candidate already names,
        # so basing it there would generate empty notes. Its notes describe the
        # whole version instead.
        self.assertEqual(notes_base("v36.0", *self.MAIN), "v35.3")

    def test_a_final_with_its_own_candidate_series_reaches_the_previous_line(self):
        # The case the tag populations carry everywhere: v36.1-rc.1 exists, and
        # v36.1 must still base on version 36.0's boundary, not on its own
        # candidate.
        tags_with_rc = (*self.MAIN, "v36.1-rc.1")
        self.assertEqual(notes_base("v36.1", *tags_with_rc), "v36.0-rc.7-mega")

    def test_the_first_candidate_of_a_version_reaches_back(self):
        # Nothing below it in its own version, so the highest version below it
        # supplies the boundary.
        self.assertEqual(notes_base("v37.0-rc.1", *self.MAIN), "v36.1")

    def test_never_bases_on_a_final_of_its_own_version(self):
        # A version's final covers everything its candidates did, so basing a
        # later candidate on it would re-describe all of it.
        self.assertEqual(notes_base("v36.0-rc.7-mega", *self.MAIN), "v36.0-rc.6-mega")

    def test_a_final_never_takes_its_own_candidate_as_base(self):
        self.assertEqual(notes_base("v2.0", "v2.0-rc.1", "v2.0", "v1.0"), "v1.0")

    def test_reaches_back_past_a_final_that_sits_behind_its_last_candidate(self):
        # `v36.1` has no candidates of its own, so it takes version 36.0's
        # published boundary. The final `v36.0` was cut before `v36.0-rc.7-mega`,
        # so basing on it would re-describe what that candidate already covered.
        self.assertEqual(notes_base("v36.1", *self.MAIN), "v36.0-rc.7-mega")

    def test_ignores_versions_above_the_pushed_tag(self):
        self.assertEqual(
            notes_base("v36.0-rc.1", "v36.0-rc.1", "v37.0", "v35.3"), "v35.3"
        )

    def test_crosses_a_gap_where_a_version_was_never_cut(self):
        self.assertEqual(notes_base("v36.0-rc.1", *self.MAIN), "v35.3")

    def test_no_base_when_nothing_is_below(self):
        # The create step then omits the boundary rather than passing an empty
        # one, which would generate notes from the entire history.
        self.assertIsNone(notes_base("v1.0", "v1.0", "v2.0"))

    def test_non_version_tags_are_never_a_base(self):
        self.assertIsNone(notes_base("v2.0", "latest", "nightly", "20240131.1"))

    def test_every_version_tag_is_a_candidate_base(self):
        # Excluding test and personal tags would make the base depend on who cut
        # the surrounding ones.
        self.assertEqual(
            notes_base("v2.1", "v2.0-rc.1", "v2.0-rc.2-someone_test"),
            "v2.0-rc.2-someone_test",
        )


class TestPublishedBoundary(unittest.TestCase):
    """A completed version line's boundary, which a later version bases on.

    A final cut before its line's last candidate sits behind that candidate, so
    the two are told apart by the commit each names rather than by rank.
    """

    def boundary(self, *names, commits=None):
        commits = commits or {}
        line = sorted(
            (parsed(name, commits.get(name, _DERIVE)) for name in names),
            key=lambda tag: tag.rank,
        )
        found = identity.published_boundary(line)
        return found.name if found else None

    def test_prefers_the_final_when_it_names_the_last_candidates_commit(self):
        # The final is the published boundary of that line.
        self.assertEqual(
            self.boundary(
                "v2.1.0-rc.1",
                "v2.1.0",
                commits={"v2.1.0": "shared", "v2.1.0-rc.1": "shared"},
            ),
            "v2.1.0",
        )

    def test_prefers_the_last_candidate_when_the_final_sits_behind_it(self):
        self.assertEqual(
            self.boundary("v2.1.0-rc.1", "v2.1.0", "v2.1.0-rc.2"), "v2.1.0-rc.2"
        )

    def test_falls_back_to_the_candidate_when_the_final_names_no_commit(self):
        # The listing can omit a commit. Guessing the final is the boundary would
        # silently widen the notes.
        self.assertEqual(
            self.boundary("v2.1.0-rc.1", "v2.1.0", commits={"v2.1.0": ""}),
            "v2.1.0-rc.1",
        )

    def test_two_tags_with_no_commit_are_not_treated_as_co_located(self):
        # Two unknown commits compare equal as strings, which would pick the final
        # on no evidence at all.
        self.assertEqual(
            self.boundary(
                "v2.1.0-rc.1", "v2.1.0", commits={"v2.1.0": "", "v2.1.0-rc.1": ""}
            ),
            "v2.1.0-rc.1",
        )

    def test_a_line_with_only_a_final(self):
        self.assertEqual(self.boundary("v2.1.0"), "v2.1.0")

    def test_a_line_with_only_candidates(self):
        self.assertEqual(self.boundary("v2.1.0-rc.1", "v2.1.0-rc.2"), "v2.1.0-rc.2")

    def test_no_boundary_from_an_empty_line(self):
        self.assertIsNone(identity.published_boundary([]))


class TestClaimsLatest(unittest.TestCase):
    def test_a_final_with_nothing_above_it_claims_latest(self):
        self.assertTrue(claims_latest("v3.0", "v2.0", "v3.0"))

    def test_a_final_below_another_final_declines(self):
        # "Latest" defaults to publish order, which is what put an older release
        # under it. Re-cutting an old tag must not move the pointer back.
        self.assertFalse(claims_latest("v2.0", "v2.0", "v3.0"))

    def test_a_candidate_never_claims_latest(self):
        self.assertFalse(claims_latest("v9.0-rc.1", "v1.0", "v9.0-rc.1"))

    def test_candidates_above_a_final_do_not_block_its_claim(self):
        # Ranking above the pushed tag is not enough to block the claim, only a
        # higher *final* is: a candidate for the next version is unreleased, so a
        # final shipping now is still Latest.
        #
        # The candidates are of the version directly above, so each one outranks
        # the pushed final outright. A version further up would rank above it on
        # its numbers alone and prove nothing about the final-only rule.
        self.assertTrue(claims_latest("v36.0", "v36.0", "v36.1-rc.1", "v36.1-rc.2"))

    def test_a_candidate_of_the_pushed_version_does_not_block_it(self):
        self.assertTrue(claims_latest("v36.0", "v36.0-rc.1", "v36.0"))

    def test_a_suffixed_final_blocks_a_lower_finals_claim(self):
        # Suffixes are ignored for ranking, so a suffixed final is still a final.
        self.assertFalse(claims_latest("v2.0", "v2.0", "v3.0-pltf"))

    def test_the_retired_scheme_does_not_block_a_claim(self):
        # Date-numbered tags parse as versions in the millions, so admitting them
        # would make every real final decline Latest forever.
        self.assertTrue(claims_latest("v3.0", "v3.0", "20240131.1", "20991231.9"))

    def test_the_first_release_claims_latest(self):
        self.assertTrue(claims_latest("v1.0", "v1.0"))


class TestCollectTags(unittest.TestCase):
    """Paging stops once the listing is bounded, and not before."""

    def collect(self, pages, pushed, max_pages=20):
        calls = []

        def fake_request(method, path, payload=None):
            page = int(path.split("&page=")[1])
            calls.append(page)
            names = pages[page - 1] if page <= len(pages) else []
            return 200, listing(names)

        with mock.patch.object(identity.github_api, "request", fake_request):
            collected = identity.collect_tags("owner/repo", max_pages, parsed(pushed))
        return [tag.name for tag in collected], calls

    def test_carries_the_commit_each_tag_names(self):
        # The commit decides which tag a completed version line published, so it
        # has to survive the fetch. A fetch that dropped it would still rank
        # correctly and pick the wrong notes base.
        def fake_request(method, path, payload=None):
            page = int(path.split("&page=")[1])
            names = ["v2.0", "v2.0-rc.1", "v1.0"] if page == 1 else []
            return 200, listing(names)

        with mock.patch.object(identity.github_api, "request", fake_request):
            collected = identity.collect_tags("owner/repo", 20, parsed("v3.0"))

        self.assertTrue(collected, "the listing was never fetched")
        self.assertTrue(
            all(tag.commit for tag in collected),
            f"every tag needs a commit, got {[(t.name, t.commit) for t in collected]}",
        )

    def test_reads_tags_from_the_listing_endpoint(self):
        # The tags endpoint is what reports the commit each tag names with the
        # annotated tags already resolved; it is also what keeps the action free
        # of any checkout.
        seen = []

        def fake_request(method, path, payload=None):
            seen.append((method, path))
            return 200, []

        with mock.patch.object(identity.github_api, "request", fake_request):
            identity.collect_tags("owner/repo", 20, parsed("v3.0"))

        self.assertTrue(seen, "the listing was never fetched")
        for method, path in seen:
            self.assertEqual(method, "GET")
            self.assertTrue(
                path.startswith("/repos/owner/repo/tags?"),
                f"fetched {path} instead of the tags listing",
            )

    def test_stops_after_the_page_holding_a_lower_version(self):
        # The base is in the pushed tag's own version or the highest below it, so
        # a page holding a lower version bounds what later pages could add.
        collected, calls = self.collect([["v9.0", "v8.0"], ["v7.0"]], "v9.0")
        self.assertEqual(calls, [1])
        self.assertEqual(collected, ["v8.0", "v9.0"])

    def test_keeps_paging_while_every_tag_is_at_or_above_the_pushed_version(self):
        collected, calls = self.collect(
            [["v9.0-rc.1"], ["v9.0-rc.2"], ["v8.0"]], "v9.0"
        )
        self.assertEqual(calls, [1, 2, 3])
        self.assertIn("v8.0", collected)

    def test_consumes_the_whole_page_before_stopping(self):
        # Order within a page is the API's, not a version ranking, so a lower tag
        # early in the page does not mean the rest can be skipped.
        collected, _ = self.collect([["v8.0", "v9.0-rc.9"]], "v9.0")
        self.assertEqual(collected, ["v8.0", "v9.0-rc.9"])

    def test_an_exhausted_listing_ends_paging(self):
        collected, calls = self.collect([["v9.0"], []], "v9.0")
        self.assertEqual(calls, [1, 2])
        self.assertEqual(collected, ["v9.0"])

    def test_refuses_a_partial_tag_list(self):
        # Answering from a truncated listing would pick a plausible wrong base
        # with nothing to detect it.
        with self.assertRaises(SystemExit):
            self.collect([["v9.0-rc.1"]] * 3, "v9.0", max_pages=2)

    def test_fails_when_the_listing_errors(self):
        # A failed listing is not an empty repository, and the API's own reason
        # has to reach the annotation.
        stderr = io.StringIO()
        with (
            mock.patch.object(
                identity.github_api,
                "request",
                lambda *a, **k: (502, {"message": "Bad gateway"}),
            ),
            contextlib.redirect_stderr(stderr),
            self.assertRaises(SystemExit),
        ):
            identity.collect_tags("owner/repo", 20, parsed("v1.0"))
        self.assertIn("Bad gateway", stderr.getvalue())

    def test_a_three_number_push_drops_the_retired_two_number_scheme(self):
        # A repository that moved from vN.M to vX.Y.Z counted through the same
        # majors twice, so the retired tags overlap the live ones — an old v9.1
        # outranks every new v2.x final, and an old v2.2 collides with the new
        # v2.2.0 line outright. Ranking cannot tell them apart; the shape can.
        collected, _ = self.collect(
            [["v35.5", "v9.1", "v2.2-rc1", "v2.1.1", "v2.1.0"]], "v2.1.1"
        )
        self.assertEqual(collected, ["v2.1.0", "v2.1.1"])

    def test_a_two_number_push_keeps_every_tag(self):
        # A repository on two-number versions never retired anything; stray
        # three-number tags there are ordinary candidates.
        collected, _ = self.collect([["v36.1", "v1.0.0", "v35.5"]], "v36.1")
        self.assertEqual(collected, ["v1.0.0", "v35.5", "v36.1"])

    def test_dropped_tags_do_not_bound_paging(self):
        # The retired v2.1 sits below the pushed version, but stopping on it
        # would cut the listing off before the live v2.1.1 the base needs.
        collected, calls = self.collect(
            [["v2.2.0-rc.2", "v2.1"], ["v2.1.1"], ["v1.9"]], "v2.2.0-rc.2"
        )
        self.assertEqual(calls, [1, 2])
        self.assertEqual(collected, ["v2.1.1", "v2.2.0-rc.2"])

    def test_ranks_tags_rather_than_trusting_the_listing_order(self):
        # The API places a version's final after its own candidates and sorts
        # v100 above v99.
        collected, _ = self.collect(
            [["v100.0", "v99.0", "v99.0-rc.1", "v98.0"]], "v100.0"
        )
        self.assertEqual(collected, ["v98.0", "v99.0-rc.1", "v99.0", "v100.0"])


class TestMain(unittest.TestCase):
    """The step outputs, and the tags the run refuses to answer for."""

    def run_main(self, tag, tag_names, output_path):
        env = {
            "TAG": tag,
            "GITHUB_REPOSITORY": "owner/repo",
            "MAX_PAGES": "20",
            "GITHUB_OUTPUT": str(output_path),
        }

        def fake_request(method, path, payload=None):
            page = int(path.split("&page=")[1])
            names = tag_names if page == 1 else []
            return 200, listing(names)

        # main() reports the identity it resolved on stdout, which is the step's
        # log rather than anything under test here.
        with (
            mock.patch.dict(identity.os.environ, env, clear=False),
            mock.patch.object(identity.github_api, "request", fake_request),
            mock.patch("sys.stdout", io.StringIO()),
        ):
            identity.main()

        values = {}
        for line in output_path.read_text().splitlines():
            key, _, value = line.partition("=")
            values[key] = value
        return values

    def test_writes_the_three_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "outputs"
            output.touch()
            values = self.run_main("v37.0", ["v37.0", "v36.0", "v35.0"], output)

        self.assertEqual(
            values, {"latest": "true", "notes_start": "v36.0", "prerelease": "false"}
        )

    def test_a_candidate_is_a_prerelease_and_declines_latest(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "outputs"
            output.touch()
            values = self.run_main("v37.0-rc.1", ["v37.0-rc.1", "v36.0"], output)

        self.assertEqual(values["prerelease"], "true")
        self.assertEqual(values["latest"], "false")

    def test_a_semver_push_is_immune_to_the_retired_scheme(self):
        # The retired scheme's finals rank above every new final and its `v2.2`
        # tags collide with the live v2.2.x line; both would poison the outputs
        # if they were compared. Shapes mirror the real population: dotless
        # ordinals are the retired scheme's habit.
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "outputs"
            output.touch()
            values = self.run_main(
                "v2.1.1", ["v35.5", "v9.1", "v2.2-rc1", "v2.1.1", "v2.1.0"], output
            )

        self.assertEqual(
            values,
            {"latest": "true", "notes_start": "v2.1.0", "prerelease": "false"},
        )

    def test_a_candidate_never_bases_on_the_retired_scheme(self):
        # Old v2.2-rc1 and new v2.2.0-rc.1 parse to the same rank on different
        # commits, seventeen months apart.
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "outputs"
            output.touch()
            values = self.run_main(
                "v2.2.0-rc.2",
                ["v2.2.0-rc.2", "v2.2.0-rc.1", "v2.2-rc1", "v2.2", "v2.1.1"],
                output,
            )

        self.assertEqual(
            values,
            {"latest": "false", "notes_start": "v2.2.0-rc.1", "prerelease": "true"},
        )

    def test_refuses_a_tag_that_is_not_a_version(self):
        # The action is triggered by a tag push, and not every tag pushed is a
        # release. Answering for one would publish a release for it.
        #
        # The message is asserted, not just the exit code: a run that carried the
        # unparsed tag onwards would fail at the tag listing instead and report a
        # network problem for what is really a tag that was never a release.
        for tag in ("latest", "20240131.1", "v1", "release-1.0"):
            with self.subTest(tag=tag):
                environment = {
                    "TAG": tag,
                    "GITHUB_REPOSITORY": "owner/repo",
                    "MAX_PAGES": "20",
                }
                with (
                    mock.patch.dict(identity.os.environ, environment, clear=False),
                    mock.patch("sys.stderr", io.StringIO()) as errors,
                    self.assertRaises(SystemExit) as raised,
                ):
                    identity.main()

                self.assertEqual(raised.exception.code, 1)
                self.assertIn("is not a version tag", errors.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
