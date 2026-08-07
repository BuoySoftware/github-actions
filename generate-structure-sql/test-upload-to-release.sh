#!/usr/bin/env bash
#
# Tests the "Upload to GitHub Release" and "Verify release asset" steps in
# action.yml.
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
  local tag="$1" release_exists="$2" fixture="$3"
  local step_name="${4:-Upload to GitHub Release}" attached_assets="${5:-}"
  local create_result="${6:-ok}" view_fails="${7:-false}"
  local step
  step=$(extract_step "$step_name")
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
  echo "$create_result" > "$fixture/create_result"
  echo "$view_fails" > "$fixture/view_fails"
  : > "$fixture/requests.log"

  python3 "$SCRIPT_DIR/fake_github.py" "$fixture" &
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
      GITHUB_REF_NAME="$tag" TAG="$tag" GH_TOKEN="stub" \
      GITHUB_ACTION_PATH="$SCRIPT_DIR" \
      GITHUB_REPOSITORY="owner/repo" \
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
  log=$(run_step "$tag" true "$FIXTURES/upload" "Upload to GitHub Release" \
    "$attached_assets")

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
  log=$(run_step "$tag" false "$FIXTURES/upload")
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
  if ! grep -q "^::error::No release exists for $tag" <<< "$output"; then
    printf '  FAIL %s (missing release not reported inside the ::error:: annotation)\n' \
      "$description"
    printf '       output: %s\n' "${output//$'\n'/ | }"
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

assert_verify() {
  local description="$1" expected="$2" attached_assets="$3"
  local view_fails="${4:-false}"
  run_step "v37.0-rc.1" true "$FIXTURES/verify" "Verify release asset" \
    "$attached_assets" ok "$view_fails" > /dev/null

  local actual="pass"
  [ "$(status_of "$FIXTURES/verify")" -ne 0 ] && actual="fail"

  if [ "$actual" == "$expected" ]; then
    printf '  ok   %s\n' "$description"
  else
    printf '  FAIL %s (expected the step to %s, it %sed)\n' \
      "$description" "$expected" "$actual"
    printf '       output: %s\n' "$(output_of "$FIXTURES/verify" | tr '\n' '|')"
    failures=$((failures + 1))
  fi
}

echo
echo "Verify release asset"

assert_verify "passes when structure.sql is attached"     pass "structure.sql"
assert_verify "passes among other assets"                 pass "checksums.txt structure.sql"
# The original bug: the release exists but the asset never landed.
assert_verify "fails when no assets are attached"         fail ""
assert_verify "fails when only other assets are attached" fail "checksums.txt"
# Guards against a substring match letting a near-miss name through.
assert_verify "fails on a partial name match"             fail "structure.sql.gz"
# A failed read is not a verified asset.
assert_verify "fails when the release cannot be read"     fail "structure.sql" true

if [ "$failures" -gt 0 ]; then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi

echo
echo "all assertions passed"
