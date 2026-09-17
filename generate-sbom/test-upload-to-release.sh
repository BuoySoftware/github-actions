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
ACTION_DIR="$SCRIPT_DIR"
HARNESS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES=$(mktemp -d)
trap 'rm -rf "$FIXTURES"' EXIT

ASSET="sbom.spdx.json"
failures=0

# The SBOM path is declared three times in action.yml: once as the generator's
# `output-file`, once as the verify step's SBOM_PATH, and once as the upload
# step's ASSET_PATH. They must be one expression, or a step reads a file
# another step never wrote. Echoes that single expression; a disagreement is
# fatal, because every later assertion resolves the path from here.
declared_sbom_path() {
  local declarations unique
  declarations=$(sed -n \
    -e 's/^ *output-file: //p' \
    -e 's/^ *SBOM_PATH: //p' \
    -e 's/^ *ASSET_PATH: //p' "$ACTION")
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

asset_path_for() {
  mkdir -p "$1/temp"
  resolve_sbom_path "temp"
}

write_asset() {
  printf '{"spdxVersion":"SPDX-2.3","packages":[{"name":"example"}]}\n' > "$1/$2"
}

source "$SCRIPT_DIR/../lib/upload_harness.sh"

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
