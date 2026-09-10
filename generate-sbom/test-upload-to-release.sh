#!/usr/bin/env bash
#
# Tests the "Upload to GitHub Release" step in action.yml.
#
# Two silent failures are what this guards. A dispatched run that names no tag
# used to skip the step and finish green with nothing attached, so the absent
# tag must now be a hard failure. And an SBOM that was never written must not
# pass for an attached one.
#
# The step body is extracted from action.yml rather than restated here, so the
# test exercises the shipped logic instead of a copy that can drift. It runs
# against a local stand-in GitHub API, with assertions on the requests it
# actually makes. Nothing is stubbed on PATH.
#
# Usage: ./generate-sbom/test-upload-to-release.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="$SCRIPT_DIR/action.yml"
FIXTURES=$(mktemp -d)
trap 'rm -rf "$FIXTURES"' EXIT

ASSET="sbom.spdx.json"
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

# Runs the step against a fresh stand-in API serving the given fixture, and
# echoes the requests it made, one per line. Records the exit code for
# `status_of` and the step's own output for `output_of`.
#
# `sbom_written` false leaves the SBOM absent, standing in for a generator that
# produced nothing.
run_step() {
  local github_ref="$1" release_exists="$2" fixture="$3"
  local attached_assets="${4:-}" release_tag="${5:-}" sbom_written="${6:-true}"
  local step
  step=$(extract_step "Upload to GitHub Release")
  rm -rf "${fixture:?}"
  mkdir -p "$fixture/temp"

  if [ -z "$step" ]; then
    # No `run:` body to extract -- the step is a `uses:` action, or was renamed.
    echo 2 > "$fixture/status"
    return
  fi

  if [ "$sbom_written" = true ]; then
    printf '{"spdxVersion":"SPDX-2.3","packages":[{"name":"example"}]}\n' \
      > "$fixture/temp/$ASSET"
  fi
  echo "$release_exists" > "$fixture/release_exists"
  echo "$attached_assets" > "$fixture/attached_assets"
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
      GITHUB_REF="$github_ref" GITHUB_REF_NAME="${github_ref##*/}" \
      GH_TOKEN="stub" \
      GITHUB_ACTION_PATH="$SCRIPT_DIR" \
      GITHUB_REPOSITORY="owner/repo" \
      RELEASE_TAG="$release_tag" \
      SBOM_PATH="temp/$ASSET" \
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

fail() {
  printf '  FAIL %s (%s)\n' "$1" "$2"
  failures=$((failures + 1))
}

assert_attaches() {
  local description="$1" github_ref="$2" release_tag="$3" tag="$4"
  local attached_assets="${5:-}"
  local log output
  log=$(run_step "$github_ref" true "$FIXTURES/upload" "$attached_assets" "$release_tag")
  output=$(output_of "$FIXTURES/upload")

  if [ "$(status_of "$FIXTURES/upload")" -ne 0 ]; then
    fail "$description" "step exited $(status_of "$FIXTURES/upload"): ${output//$'\n'/ | }"
    return
  fi

  if ! grep -q "^GET /repos/owner/repo/releases/tags/$tag" <<< "$log"; then
    fail "$description" "looked up a release other than $tag: ${log//$'\n'/ | }"
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

  if ! grep -q "attached to release $tag" <<< "$output"; then
    fail "$description" "did not report the tag it attached to: ${output//$'\n'/ | }"
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
    fail "$description" "step succeeded with no tag to attach to"
    return
  fi

  if grep -q "^POST /uploads/" <<< "$log"; then
    fail "$description" "uploaded somewhere despite having no tag: ${log//$'\n'/ | }"
    return
  fi

  # Same line, not merely the same log: only annotation text reaches the run
  # summary and the checks UI.
  if ! grep -q "^::error::upload_to_release is true but no tag could be resolved" \
    <<< "$output"; then
    fail "$description" \
      "the missing tag is not reported inside the ::error:: annotation: ${output//$'\n'/ | }"
    return
  fi

  printf '  ok   %s\n' "$description"
}

# The generator writes the SBOM to a path this step only reads. An absent file
# must stop the run rather than leave the release without its asset.
assert_refuses_a_missing_sbom() {
  local description="$1"
  local log output
  log=$(run_step "refs/tags/v37.0" true "$FIXTURES/upload" "" "" false)
  output=$(output_of "$FIXTURES/upload")

  if [ "$(status_of "$FIXTURES/upload")" -eq 0 ]; then
    fail "$description" "step succeeded with no SBOM on disk"
    return
  fi

  if grep -q "^POST /uploads/" <<< "$log"; then
    fail "$description" "uploaded with no SBOM on disk: ${log//$'\n'/ | }"
    return
  fi

  if ! grep -q "^::error::No non-empty file matches temp/$ASSET" <<< "$output"; then
    fail "$description" \
      "the missing SBOM is not reported inside the ::error:: annotation: ${output//$'\n'/ | }"
    return
  fi

  printf '  ok   %s\n' "$description"
}

# sbom-action writes output-file with a bare writeFileSync, so a path under a
# subdirectory of runner.temp fails with ENOENT unless something creates it.
# The generator is a `uses:` step with no body to run, so this is asserted by
# resolving the shipped path against a real directory.
assert_output_file_is_writable() {
  local description="the generated SBOM path needs no directory nobody creates"
  local output_file temp resolved
  output_file=$(sed -n 's/^ *output-file: //p' "$ACTION")

  if [ -z "$output_file" ]; then
    fail "$description" "action.yml declares no output-file"
    return
  fi

  if grep -qE '^ *(run|shell): .*mkdir' "$ACTION"; then
    printf '  ok   %s (a step creates it)\n' "$description"
    return
  fi

  temp="$FIXTURES/runner-temp"
  rm -rf "${temp:?}"
  mkdir -p "$temp"
  resolved="${output_file//\$\{\{ runner.temp \}\}/$temp}"
  resolved="${resolved//\$\{\{ inputs.asset_name \}\}/$ASSET}"

  if ! echo "{}" > "$resolved" 2>/dev/null; then
    fail "$description" "writing $output_file fails; nothing creates its directory"
    return
  fi

  printf '  ok   %s\n' "$description"
}

echo "Generated SBOM path"
assert_output_file_is_writable

echo
echo "Upload to GitHub Release"

# A dispatched run checks out an arbitrary tag while the ref names the branch
# it was launched from, so the tag travels in RELEASE_TAG instead.
assert_attaches "attaches to the named tag, not the launch branch" \
  "refs/heads/main" "v36.1" "v36.1"
assert_attaches "the named tag wins over a tag ref" \
  "refs/tags/v38.0-rc.1" "v36.1" "v36.1"
assert_attaches "a tag push falls back to the pushed tag" \
  "refs/tags/v37.0-rc.1" "" "v37.0-rc.1"
assert_attaches "replaces its own asset from an earlier run" \
  "refs/tags/v37.0" "" "v37.0" "$ASSET"

echo
echo "Refusals"
assert_refuses_without_a_tag "fails on a branch push with no named tag" \
  "refs/heads/main"
assert_refuses_without_a_tag "fails when there is no ref at all" ""
assert_refuses_a_missing_sbom "fails when the SBOM was never written"

if [ "$failures" -gt 0 ]; then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi

echo
echo "all assertions passed"
