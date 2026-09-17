#!/usr/bin/env bash
#
# Tests the "Upload to GitHub Release" step in action.yml.
#
# Losing the asset is silent and costly: when the release already exists, an
# upload that also patches release properties is rejected with
# `already_exists` on `tag_name`, and the asset does not survive the failed
# call. Downstream tooling then reads an empty schema diff from a run that
# otherwise looks green.
#
# The step bodies are extracted from action.yml rather than restated here, so
# the test exercises the shipped logic instead of a copy that can drift. They
# run against a local stand-in GitHub API, with assertions on the requests
# they actually make. Nothing is stubbed on PATH.
#
# Usage: ./generate-structure-sql/test-upload-to-release.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="$SCRIPT_DIR/action.yml"
ACTION_DIR="$SCRIPT_DIR"
HARNESS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES=$(mktemp -d)
trap 'rm -rf "$FIXTURES"' EXIT

ASSET="structure.sql"
failures=0

# The upload step reads the path the generator was given, which is the action's
# structure_sql_path default.
asset_path_for() {
  mkdir -p "$1/db"
  echo "db/$ASSET"
}

write_asset() {
  echo "-- schema" > "$1/$2"
}

source "$SCRIPT_DIR/../lib/upload_harness.sh"

assert_uploads_idempotently() {
  local description="$1" tag="$2" attached_assets="$3"
  local log
  log=$(run_step "refs/tags/$tag" true "$FIXTURES/upload" "$attached_assets")

  if [ "$(status_of "$FIXTURES/upload")" -ne 0 ]; then
    fail "$description" \
      "step exited $(status_of "$FIXTURES/upload"): $(output_of "$FIXTURES/upload" | tr '\n' '|')"
    return
  fi

  if ! grep -q "^POST /uploads/releases/.*name=$ASSET" <<< "$log"; then
    fail "$description" "did not upload the asset: ${log//$'\n'/ | }"
    return
  fi

  # The upload must be idempotent: an asset of the same name left behind by an
  # earlier run is replaced instead of collided with.
  if grep -q "$ASSET" <<< "$attached_assets" \
    && ! grep -q "^DELETE /repos/owner/repo/releases/assets/" <<< "$log"; then
    fail "$description" "did not replace the existing asset: ${log//$'\n'/ | }"
    return
  fi

  # The regression guard: mutating the release is what GitHub rejects.
  if grep -qE "^(POST /repos/owner/repo/releases |PATCH )" <<< "$log"; then
    fail "$description" "mutates the release; already_exists risk: ${log//$'\n'/ | }"
    return
  fi

  printf '  ok   %s\n' "$description"
}

# create-release cuts the release before any artifact job runs, so a missing
# release means the run is misconfigured. Failing loudly beats publishing a
# release with an identity this script would have to invent.
assert_fails_without_release() {
  local description="$1" tag="$2"
  local log output
  log=$(run_step "refs/tags/$tag" false "$FIXTURES/upload")
  output=$(output_of "$FIXTURES/upload")

  if [ "$(status_of "$FIXTURES/upload")" -eq 0 ]; then
    fail "$description" "step succeeded with no release present: ${log//$'\n'/ | }"
    return
  fi

  if grep -qE "^POST /repos/owner/repo/releases " <<< "$log"; then
    fail "$description" \
      "created a release; create-release owns creation: ${log//$'\n'/ | }"
    return
  fi

  if grep -q "^POST /uploads/" <<< "$log"; then
    fail "$description" \
      "attempted upload with no release present: ${log//$'\n'/ | }"
    return
  fi

  # Same line, not merely the same log: only annotation text reaches the run
  # summary and the checks UI.
  if ! grep -q "^::error::No release exists for $tag, or it is still a draft" <<< "$output"; then
    fail "$description" \
      "the missing release is not reported inside the ::error:: annotation: ${output//$'\n'/ | }"
    return
  fi

  printf '  ok   %s\n' "$description"
}

# RELEASE_TAG takes precedence over the ref, so the release the step looks up is
# the one named explicitly rather than whatever ref the run is on.
assert_attaches_to_release_tag() {
  local description="$1" github_ref="$2" release_tag="$3"
  local log output
  log=$(run_step "$github_ref" true "$FIXTURES/upload" "" "$release_tag")
  output=$(output_of "$FIXTURES/upload")

  if [ "$(status_of "$FIXTURES/upload")" -ne 0 ]; then
    fail "$description" \
      "step exited $(status_of "$FIXTURES/upload"): $(output_of "$FIXTURES/upload" | tr '\n' '|')"
    return
  fi

  if ! grep -q "^GET /repos/owner/repo/releases/tags/$release_tag" <<< "$log"; then
    fail "$description" \
      "looked up a release other than $release_tag: ${log//$'\n'/ | }"
    return
  fi

  if ! grep -q "^POST /uploads/releases/.*name=$ASSET" <<< "$log"; then
    fail "$description" "did not upload the asset: ${log//$'\n'/ | }"
    return
  fi

  if ! grep -q "attached to release $release_tag" <<< "$output"; then
    fail "$description" "did not report the named tag: ${output//$'\n'/ | }"
    return
  fi

  printf '  ok   %s\n' "$description"
}

# The generator writes the file to a path this step only reads. An absent file
# must stop the run rather than leave the release without its asset.
assert_refuses_a_missing_asset() {
  local description="$1"
  local log output
  log=$(run_step "refs/tags/v37.0" true "$FIXTURES/upload" "" "" false)
  output=$(output_of "$FIXTURES/upload")

  if [ "$(status_of "$FIXTURES/upload")" -eq 0 ]; then
    fail "$description" "step succeeded with no structure.sql on disk"
    return
  fi

  if grep -q "^POST /uploads/" <<< "$log"; then
    fail "$description" "uploaded with no structure.sql on disk: ${log//$'\n'/ | }"
    return
  fi

  if ! grep -q "^::error::No non-empty file matches db/$ASSET" <<< "$output"; then
    fail "$description" \
      "the missing file is not reported inside the ::error:: annotation: ${output//$'\n'/ | }"
    return
  fi

  printf '  ok   %s\n' "$description"
}

# The path the step reads must be the one the action's input names, or the
# upload reads a file the generator never wrote.
assert_asset_path_comes_from_the_input() {
  local description="$1" declared
  declared=$(awk '/name: Upload to GitHub Release/,/shell: bash/' "$ACTION" \
    | sed -n 's/^ *ASSET_PATH: //p')

  if [ "$declared" != "\${{ inputs.structure_sql_path }}" ]; then
    fail "$description" "the step uploads \`$declared\`"
    return
  fi

  printf '  ok   %s\n' "$description"
}

echo "Upload to GitHub Release"

# The release already exists, which create-release guarantees on every push.
# A re-run finds its own earlier asset and must replace it.
assert_uploads_idempotently "existing release, no asset yet"      "v37.0-rc.1" ""
assert_uploads_idempotently "existing release, replaces its own"  "v37.0" "$ASSET"
assert_uploads_idempotently "existing release, other assets"      "v37.0" "checksums.txt"
assert_asset_path_comes_from_the_input \
  "the uploaded path is the one structure_sql_path names"

echo
echo "Missing release"
assert_fails_without_release "fails when the release does not exist" "v38.0-rc.1"
assert_fails_without_release "fails for a final tag too"             "v38.0"

# A dispatched run checks out an arbitrary tag while the ref names the branch it
# was launched from, so the tag travels in RELEASE_TAG instead.
echo
echo "Explicit release tag"
assert_attaches_to_release_tag "attaches to the named tag, not the branch" \
  "refs/heads/main" "v36.1"
assert_attaches_to_release_tag "the named tag wins over a tag ref" \
  "refs/tags/v38.0-rc.1" "v36.1"

echo
echo "Refusals"
assert_refuses_without_a_tag "fails on a branch push with no named tag" \
  "refs/heads/main"
assert_refuses_without_a_tag "fails when there is no ref at all" ""
assert_refuses_a_missing_asset "fails when structure.sql was never written"
assert_upload_gate_is_unconditional \
  "the upload gate does not skip a dispatched run with no tag ref"

if [ "$failures" -gt 0 ]; then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi

echo
echo "all assertions passed"
