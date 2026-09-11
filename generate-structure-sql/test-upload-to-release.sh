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
FIXTURES=$(mktemp -d)
trap 'rm -rf "$FIXTURES"' EXIT

failures=0

# Extract a step's `run:` body. The awk range restarts on each `name:` line, so
# it lands on the named step regardless of step order. Steps take their values
# from `env:`, so there are no `${{ }}` expressions left in the body to
# substitute -- the harness sets the same variables the runner would.
#
# A step whose command is short enough to sit on the `run:` line itself is
# extracted from there.
extract_step() {
  local step_name="$1" step
  step=$(awk "/name: $step_name/,/shell: bash/" "$ACTION")

  if grep -q 'run: |' <<< "$step"; then
    sed -n '/run: |/,/shell: bash/p' <<< "$step" \
      | sed '1d;$d' \
      | sed 's/^        //'
  else
    sed -n 's/^      run: //p' <<< "$step"
  fi
}

# Runs a step against a fresh stand-in API serving the given fixture, and
# echoes the requests the step made, one per line. Records the step's exit
# code for `status_of` and its own output for `output_of`.
run_step() {
  local github_ref="$1" release_exists="$2" fixture="$3" attached_assets="${4:-}"
  local release_tag="${5:-}"
  local step
  step=$(extract_step "Upload to GitHub Release")
  rm -rf "$fixture"
  mkdir -p "$fixture/db"

  if [ -z "$step" ]; then
    # No `run:` body to extract -- the step is a `uses:` action, or was renamed.
    echo 2 > "$fixture/status"
    return
  fi

  echo "-- schema" > "$fixture/db/structure.sql"
  echo "$release_exists" > "$fixture/release_exists"
  echo "$attached_assets" > "$fixture/attached_assets"
  : > "$fixture/requests.log"

  python3 "$SCRIPT_DIR/../lib/fake_github.py" "$fixture" &
  local server_pid=$!
  local waited=0
  while [ ! -s "$fixture/port" ] && [ "$waited" -lt 100 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  if [ ! -s "$fixture/port" ]; then
    echo 3 > "$fixture/status"
    kill "$server_pid" 2>/dev/null
    return
  fi

  (
    cd "$fixture" || exit 2
    # The runner invokes `shell: bash` as `bash --noprofile --norc -e -o
    # pipefail`. Step output goes to a file so stdout stays free for the
    # request log.
    env GITHUB_API_URL="http://127.0.0.1:$(cat "$fixture/port")" \
      GITHUB_REF="$github_ref" GH_TOKEN="stub" \
      GITHUB_ACTION_PATH="$SCRIPT_DIR" \
      GITHUB_REPOSITORY="owner/repo" \
      RELEASE_TAG="$release_tag" \
      STRUCTURE_SQL_PATH="db/structure.sql" \
      bash --noprofile --norc -e -o pipefail -c "$step" \
      > "$fixture/output" 2>&1
  )
  # Callers capture stdout via command substitution, so the status has to travel
  # through the filesystem rather than a variable the subshell would discard.
  echo $? > "$fixture/status"
  kill "$server_pid" 2>/dev/null
  wait "$server_pid" 2>/dev/null
  cat "$fixture/requests.log" 2>/dev/null
}

# Reads the status recorded by the most recent run_step against `fixture`.
status_of() {
  cat "$1/status" 2>/dev/null || echo 2
}

# Reads the step's own stdout/stderr from the most recent run_step.
output_of() {
  cat "$1/output" 2>/dev/null
}

assert_uploads_idempotently() {
  local description="$1" tag="$2" attached_assets="$3"
  local log
  log=$(run_step "refs/tags/$tag" true "$FIXTURES/upload" "$attached_assets")

  if [ "$(status_of "$FIXTURES/upload")" -ne 0 ]; then
    printf '  FAIL %s (step exited %s)\n' "$description" "$(status_of "$FIXTURES/upload")"
    printf '       output: %s\n' "$(output_of "$FIXTURES/upload" | tr '\n' '|')"
    failures=$((failures + 1))
    return
  fi

  if ! grep -q "^POST /uploads/releases/.*name=structure.sql" <<< "$log"; then
    printf '  FAIL %s (did not upload the asset)\n' "$description"
    printf '       requests: %s\n' "${log//$'\n'/ | }"
    failures=$((failures + 1))
    return
  fi

  # The upload must be idempotent: an asset of the same name left behind by an
  # earlier run is replaced instead of collided with.
  if grep -q "structure.sql" <<< "$attached_assets"; then
    if ! grep -q "^DELETE /repos/owner/repo/releases/assets/" <<< "$log"; then
      printf '  FAIL %s (did not replace the existing asset)\n' "$description"
      printf '       requests: %s\n' "${log//$'\n'/ | }"
      failures=$((failures + 1))
      return
    fi
  fi

  # The regression guard: mutating the release is what GitHub rejects.
  if grep -qE "^(POST /repos/owner/repo/releases |PATCH )" <<< "$log"; then
    printf '  FAIL %s (mutates the release; already_exists risk)\n' "$description"
    printf '       requests: %s\n' "${log//$'\n'/ | }"
    failures=$((failures + 1))
    return
  fi

  printf '  ok   %s\n' "$description"
}

# create-release cuts the release before any artifact job runs, so a missing
# release means the run is misconfigured. Failing loudly beats publishing a
# release with an identity this script would have to invent.
assert_fails_without_release() {
  local description="$1" tag="$2"
  local log
  log=$(run_step "refs/tags/$tag" false "$FIXTURES/upload")
  local output
  output=$(output_of "$FIXTURES/upload")

  if [ "$(status_of "$FIXTURES/upload")" -eq 0 ]; then
    printf '  FAIL %s (step succeeded with no release present)\n' "$description"
    printf '       requests: %s\n' "${log//$'\n'/ | }"
    failures=$((failures + 1))
    return
  fi

  if grep -qE "^POST /repos/owner/repo/releases " <<< "$log"; then
    printf '  FAIL %s (created a release; create-release owns creation)\n' "$description"
    printf '       requests: %s\n' "${log//$'\n'/ | }"
    failures=$((failures + 1))
    return
  fi

  if grep -q "^POST /uploads/" <<< "$log"; then
    printf '  FAIL %s (attempted upload with no release present)\n' "$description"
    printf '       requests: %s\n' "${log//$'\n'/ | }"
    failures=$((failures + 1))
    return
  fi

  # Same line, not merely the same log: only annotation text reaches the run
  # summary and the checks UI.
  if ! grep -q "^::error::No release exists for $tag, or it is still a draft" <<< "$output"; then
    printf '  FAIL %s (missing release not reported inside the ::error:: annotation)\n' \
      "$description"
    printf '       output: %s\n' "${output//$'\n'/ | }"
    failures=$((failures + 1))
    return
  fi

  printf '  ok   %s\n' "$description"
}

# RELEASE_TAG takes precedence over GITHUB_REF_NAME, so the release the step
# looks up is the one named explicitly rather than whatever ref the run is on.
assert_attaches_to_release_tag() {
  local description="$1" github_ref="$2" release_tag="$3"
  local log
  log=$(run_step "$github_ref" true "$FIXTURES/upload" "" "$release_tag")
  local output
  output=$(output_of "$FIXTURES/upload")

  if [ "$(status_of "$FIXTURES/upload")" -ne 0 ]; then
    printf '  FAIL %s (step exited %s)\n' "$description" "$(status_of "$FIXTURES/upload")"
    printf '       output: %s\n' "$(output_of "$FIXTURES/upload" | tr '\n' '|')"
    failures=$((failures + 1))
    return
  fi

  if ! grep -q "^GET /repos/owner/repo/releases/tags/$release_tag" <<< "$log"; then
    printf '  FAIL %s (looked up a release other than %s)\n' "$description" "$release_tag"
    printf '       requests: %s\n' "${log//$'\n'/ | }"
    failures=$((failures + 1))
    return
  fi

  if ! grep -q "^POST /uploads/releases/.*name=structure.sql" <<< "$log"; then
    printf '  FAIL %s (did not upload the asset)\n' "$description"
    printf '       requests: %s\n' "${log//$'\n'/ | }"
    failures=$((failures + 1))
    return
  fi

  if ! grep -q "attached to release $release_tag" <<< "$output"; then
    printf '  FAIL %s (did not report the named tag)\n' "$description"
    printf '       output: %s\n' "${output//$'\n'/ | }"
    failures=$((failures + 1))
    return
  fi

  printf '  ok   %s\n' "$description"
}

# The step no longer carries the tag requirement in its `if:`, because a
# skipped step is green. With no tag to resolve the run must fail instead.
assert_refuses_without_a_tag() {
  local description="$1" github_ref="$2"
  local log output
  log=$(run_step "$github_ref" true "$FIXTURES/upload")
  output=$(output_of "$FIXTURES/upload")

  if [ "$(status_of "$FIXTURES/upload")" -eq 0 ]; then
    printf '  FAIL %s (step succeeded with no tag to attach to)\n' "$description"
    failures=$((failures + 1))
    return
  fi

  if grep -q "^POST /uploads/" <<< "$log"; then
    printf '  FAIL %s (uploaded somewhere despite having no tag)\n' "$description"
    printf '       requests: %s\n' "${log//$'\n'/ | }"
    failures=$((failures + 1))
    return
  fi

  # Same line, not merely the same log: only annotation text reaches the run
  # summary and the checks UI.
  if ! grep -q "^::error::upload_to_release is true but no tag could be resolved" \
    <<< "$output"; then
    printf '  FAIL %s (missing tag not reported inside the ::error:: annotation)\n' \
      "$description"
    printf '       output: %s\n' "${output//$'\n'/ | }"
    failures=$((failures + 1))
    return
  fi

  printf '  ok   %s\n' "$description"
}

# A tag condition in the `if:` makes a tagless dispatched run skip green, which
# no request log can observe.
assert_upload_gate_is_unconditional() {
  local description="$1" condition
  condition=$(awk '/name: Upload to GitHub Release/,/shell: bash/' "$ACTION" \
    | sed -n 's/^ *if: //p')

  if [ "$condition" != "\${{ inputs.upload_to_release == 'true' }}" ]; then
    printf '  FAIL %s (the upload gate is `%s`)\n' "$description" "$condition"
    failures=$((failures + 1))
    return
  fi

  printf '  ok   %s\n' "$description"
}

echo "Upload to GitHub Release"

# The release already exists, which create-release guarantees on every push.
# A re-run finds its own earlier asset and must replace it.
assert_uploads_idempotently "existing release, no asset yet"      "v37.0-rc.1" ""
assert_uploads_idempotently "existing release, replaces its own"  "v37.0" "structure.sql"
assert_uploads_idempotently "existing release, other assets"      "v37.0" "checksums.txt"

echo
echo "Missing release"
assert_fails_without_release "fails when the release does not exist" "v38.0-rc.1"
assert_fails_without_release "fails for a final tag too"             "v38.0"

# A dispatched run checks out an arbitrary tag while GITHUB_REF_NAME names the
# branch it was launched from, so the tag travels in RELEASE_TAG instead.
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
assert_upload_gate_is_unconditional \
  "the upload gate does not skip a dispatched run with no tag ref"

if [ "$failures" -gt 0 ]; then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi

echo
echo "all assertions passed"
