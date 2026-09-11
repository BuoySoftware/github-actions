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

# The SBOM path is declared three times in action.yml: once as the generator's
# `output-file`, and once per step that reads it back as SBOM_PATH. They must
# be one expression, or a step reads a file another step never wrote. Echoes
# that single expression; a disagreement is fatal, because every later
# assertion resolves the path from here.
declared_sbom_path() {
  local declarations unique
  declarations=$(sed -n -e 's/^ *output-file: //p' -e 's/^ *SBOM_PATH: //p' "$ACTION")
  unique=$(sort -u <<< "$declarations")

  if [ "$(grep -c . <<< "$declarations")" -lt 3 ]; then
    echo "action.yml declares the SBOM path fewer than three times" >&2
    return 1
  fi

  if [ "$(grep -c . <<< "$unique")" -ne 1 ]; then
    echo "the SBOM path declarations disagree: ${unique//$'\n'/ | }" >&2
    return 1
  fi

  echo "$unique"
}

# The declared expression with the runner's values substituted in, so the
# harness reads and writes wherever action.yml currently points.
resolve_sbom_path() {
  local temp="$1" resolved
  resolved="${SBOM_PATH_EXPRESSION//\$\{\{ runner.temp \}\}/$temp}"
  echo "${resolved//\$\{\{ inputs.asset_name \}\}/$ASSET}"
}

if ! SBOM_PATH_EXPRESSION=$(declared_sbom_path); then
  echo "FAIL the SBOM path is not declared consistently in action.yml"
  exit 1
fi

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
  local sbom_path
  sbom_path=$(resolve_sbom_path "temp")

  if [ -z "$step" ]; then
    # No `run:` body to extract -- the step is a `uses:` action, or was renamed.
    echo 2 > "$fixture/status"
    return
  fi

  if [ "$sbom_written" = true ]; then
    printf '{"spdxVersion":"SPDX-2.3","packages":[{"name":"example"}]}\n' \
      > "$fixture/$sbom_path"
  fi
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
      GITHUB_REF="$github_ref" GITHUB_REF_NAME="${github_ref##*/}" \
      GH_TOKEN="stub" \
      GITHUB_ACTION_PATH="$SCRIPT_DIR" \
      GITHUB_REPOSITORY="owner/repo" \
      RELEASE_TAG="$release_tag" \
      SBOM_PATH="$sbom_path" \
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

  if ! grep -q "^::error::No non-empty file matches $(resolve_sbom_path temp)" \
    <<< "$output"; then
    fail "$description" \
      "the missing SBOM is not reported inside the ::error:: annotation: ${output//$'\n'/ | }"
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
    fail "$description" \
      "the upload gate is \`$condition\`, not the bare upload_to_release check"
    return
  fi

  printf '  ok   %s\n' "$description"
}

# An SBOM with an empty package list is still a non-empty file.
assert_verifies_packages() {
  local description="$1" sbom_json="$2" expect_ok="$3" expect_error="${4:-}"
  local step fixture status output
  step=$(extract_step "Verify SBOM")
  fixture="$FIXTURES/verify"
  rm -rf "${fixture:?}"
  mkdir -p "$fixture"

  if [ -z "$step" ]; then
    fail "$description" "no Verify SBOM step body to extract"
    return
  fi

  if [ -n "$sbom_json" ]; then
    printf '%s\n' "$sbom_json" > "$fixture/$ASSET"
  fi

  output=$(cd "$fixture" && env SBOM_PATH="$ASSET" \
    GITHUB_ACTION_PATH="$SCRIPT_DIR" \
    bash --noprofile --norc -e -o pipefail -c "$step" 2>&1)
  status=$?

  if [ "$expect_ok" = true ]; then
    if [ "$status" -ne 0 ]; then
      fail "$description" "step exited $status: ${output//$'\n'/ | }"
      return
    fi
  else
    if [ "$status" -eq 0 ]; then
      fail "$description" "step accepted an SBOM it must refuse"
      return
    fi

    if ! grep -q "^::error::$expect_error" <<< "$output"; then
      fail "$description" \
        "the refusal is not reported inside the ::error:: annotation: ${output//$'\n'/ | }"
      return
    fi
  fi

  printf '  ok   %s\n' "$description"
}

# sbom-action writes output-file with a bare writeFileSync, so a path under a
# subdirectory of runner.temp fails with ENOENT unless something creates it.
# The generator is a `uses:` step with no body to run, so this is asserted by
# resolving the shipped path against a real directory.
assert_output_file_is_writable() {
  local description="the generated SBOM path needs no directory nobody creates"
  local temp resolved

  if grep -qE '^ *(run|shell): .*mkdir' "$ACTION"; then
    printf '  ok   %s (a step creates it)\n' "$description"
    return
  fi

  temp="$FIXTURES/runner-temp"
  rm -rf "${temp:?}"
  mkdir -p "$temp"
  resolved=$(resolve_sbom_path "$temp")

  if ! echo "{}" > "$resolved" 2>/dev/null; then
    fail "$description" \
      "writing $SBOM_PATH_EXPRESSION fails; nothing creates its directory"
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
echo "Verify SBOM"
assert_verifies_packages "accepts an SBOM that lists a package" \
  '{"spdxVersion":"SPDX-2.3","packages":[{"name":"example"}]}' true
assert_verifies_packages "refuses an SBOM with no packages" \
  '{"spdxVersion":"SPDX-2.3","packages":[]}' false "SBOM lists no packages"
assert_verifies_packages "refuses an absent SBOM" \
  "" false "SBOM is empty or missing"
# Malformed output is a different failure from an empty scan, and reporting it
# as "no packages" sends the operator after the wrong cause.
assert_verifies_packages "names malformed JSON as such, not as an empty scan" \
  '{"spdxVersion": truncated' false "SBOM is not valid JSON"

echo
echo "Refusals"
assert_refuses_without_a_tag "fails on a branch push with no named tag" \
  "refs/heads/main"
assert_refuses_without_a_tag "fails when there is no ref at all" ""
assert_refuses_a_missing_sbom "fails when the SBOM was never written"
assert_upload_gate_is_unconditional \
  "the upload gate does not skip a dispatched run with no tag ref"

if [ "$failures" -gt 0 ]; then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi

echo
echo "all assertions passed"
