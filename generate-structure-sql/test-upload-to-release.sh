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
# the test exercises the shipped logic instead of a copy that can drift. `gh`
# is stubbed on PATH to record the commands each step would issue.
#
# Usage: ./generate-structure-sql/test-upload-to-release.sh

set -uo pipefail

ACTION="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/action.yml"
FIXTURES=$(mktemp -d)
trap 'rm -rf "$FIXTURES"' EXIT

failures=0

# Extract a step's `run:` body and substitute the input expressions the way the
# Actions runner would. The awk range restarts on each `name:` line, so it lands
# on the named step regardless of step order.
extract_step() {
  local step_name="$1" structure_sql_path="$2"
  awk "/name: $step_name/,/shell: bash/" "$ACTION" \
    | sed -n '/run: |/,/shell: bash/p' \
    | sed '1d;$d' \
    | sed 's/^        //' \
    | sed -e "s|\${{ inputs.structure_sql_path }}|$structure_sql_path|g"
}

# Runs the real step with a stubbed `gh` and echoes the commands it invoked, one
# per line. Records the step's exit code for `status_of`.
# `create_fails` controls how `gh release create` behaves: `false` succeeds,
# `true`/`race` models another job cutting the release in the window between the
# existence check and the create call, so the create is rejected and a re-check
# then finds the release present, and `hard` fails with no release appearing.
run_step() {
  local tag="$1" release_exists="$2" fixture="$3"
  local step_name="${4:-Upload to GitHub Release}" attached_assets="${5:-}"
  local create_fails="${6:-false}"
  local step
  step=$(extract_step "$step_name" "db/structure.sql")
  rm -rf "$fixture"
  mkdir -p "$fixture/db" "$fixture/bin"

  if [ -z "$step" ]; then
    # No `run:` body to extract -- the step is a `uses:` action, or was renamed.
    echo 2 > "$fixture/status"
    return
  fi

  echo "-- schema" > "$fixture/db/structure.sql"

  # Stub `gh`: logs every invocation, reports whether the release exists so the
  # step can branch on it, and answers the asset query the verify step makes.
  cat > "$fixture/bin/gh" <<STUB
#!/usr/bin/env bash
echo "gh \$*" >> "$fixture/gh.log"
if [ "\$1 \$2" == "release create" ]; then
  case "$create_fails" in
    true|race)
      # Losing the race leaves the release present for the re-check that follows.
      touch "$fixture/release_appeared"
      echo "HTTP 422: Validation Failed" >&2
      echo "Release.tag_name already exists" >&2
      exit 1
      ;;
    hard)
      echo "HTTP 403: Resource not accessible by integration" >&2
      exit 1
      ;;
  esac
  exit 0
fi
if [ "\$1 \$2" == "release view" ]; then
  if [ "$release_exists" != "true" ] && [ ! -f "$fixture/release_appeared" ]; then
    exit 1
  fi
  # The verify step asks for attached asset names via --json assets.
  case "\$*" in
    *--json?assets*) printf '%s\n' $attached_assets ;;
  esac
  exit 0
fi
exit 0
STUB
  chmod +x "$fixture/bin/gh"

  (
    cd "$fixture" || exit 2
    # `shell: bash` runs the body with `-e`, so mirror that here.
    # Step output goes to a file so stdout stays free for the gh call log.
    PATH="$fixture/bin:$PATH" GITHUB_REF_NAME="$tag" GH_TOKEN="stub" \
      bash -e -c "$step" > "$fixture/output" 2>&1
  )
  # Callers capture stdout via command substitution, so the status has to travel
  # through the filesystem rather than a variable the subshell would discard.
  echo $? > "$fixture/status"
  cat "$fixture/gh.log" 2>/dev/null
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
  local description="$1" tag="$2" release_exists="$3"
  local log
  log=$(run_step "$tag" "$release_exists" "$FIXTURES/upload")

  if [ "$(status_of "$FIXTURES/upload")" -ne 0 ]; then
    printf '  FAIL %s (step exited %s)\n' "$description" "$(status_of "$FIXTURES/upload")"
    failures=$((failures + 1))
    return
  fi

  # The upload must be idempotent: --clobber replaces an asset of the same name
  # left behind by an earlier run instead of colliding with it.
  if ! grep -q -- "release upload $tag .*--clobber" <<< "$log"; then
    # shellcheck disable=SC2016  # backticks are prose in the message, not a subshell
    printf '  FAIL %s (no idempotent `release upload ... --clobber`)\n' "$description"
    printf '       gh calls: %s\n' "${log//$'\n'/ | }"
    failures=$((failures + 1))
    return
  fi

  # The regression guard: mutating the release is what GitHub rejects.
  if grep -qE "release (edit|create) " <<< "$log"; then
    printf '  FAIL %s (mutates the release; already_exists risk)\n' "$description"
    printf '       gh calls: %s\n' "${log//$'\n'/ | }"
    failures=$((failures + 1))
    return
  fi

  printf '  ok   %s\n' "$description"
}

# Tags are pushed without a release being cut first, so a missing release must be
# created rather than failing the run. The asset is the point of the job; a tag
# with no release still needs its schema dump attached.
assert_creates_release_then_attaches() {
  local description="$1" tag="$2" expected_prerelease="$3"
  local log
  log=$(run_step "$tag" false "$FIXTURES/upload")

  if [ "$(status_of "$FIXTURES/upload")" -ne 0 ]; then
    printf '  FAIL %s (step exited %s with no release present)\n' \
      "$description" "$(status_of "$FIXTURES/upload")"
    printf '       gh calls: %s\n' "${log//$'\n'/ | }"
    failures=$((failures + 1))
    return
  fi

  if ! grep -q "release create $tag" <<< "$log"; then
    printf '  FAIL %s (did not create the missing release)\n' "$description"
    printf '       gh calls: %s\n' "${log//$'\n'/ | }"
    failures=$((failures + 1))
    return
  fi

  # A prerelease tag must not be published as a final release, and vice versa.
  local create_line
  create_line=$(grep "release create $tag" <<< "$log")
  if [ "$expected_prerelease" == "true" ]; then
    if ! grep -q -- "--prerelease" <<< "$create_line"; then
      printf '  FAIL %s (RC tag not marked --prerelease)\n' "$description"
      printf '       create call: %s\n' "$create_line"
      failures=$((failures + 1))
      return
    fi
  elif grep -q -- "--prerelease" <<< "$create_line"; then
    printf '  FAIL %s (final tag marked --prerelease)\n' "$description"
    printf '       create call: %s\n' "$create_line"
    failures=$((failures + 1))
    return
  fi

  if ! grep -q -- "release upload $tag .*--clobber" <<< "$log"; then
    # shellcheck disable=SC2016  # backticks are prose in the message, not a subshell
    printf '  FAIL %s (no idempotent `release upload ... --clobber` after create)\n' "$description"
    printf '       gh calls: %s\n' "${log//$'\n'/ | }"
    failures=$((failures + 1))
    return
  fi

  printf '  ok   %s\n' "$description"
}

echo "Upload to GitHub Release"

# The release already exists, which is the only case that occurs in practice.
assert_uploads_idempotently "existing release, RC tag"      "v37.0-rc.1" true
assert_uploads_idempotently "existing release, final tag"   "v37.0"      true

assert_creates_release_then_attaches "missing release, RC tag"        "v38.0-rc.1" true
assert_creates_release_then_attaches "missing release, final tag"     "v38.0"      false
# Tags observed in the wild that the release-cutting step never got to.
assert_creates_release_then_attaches "missing release, patch tag"     "v36.1"      false
# `-rc1` without a dot is still a release candidate.
assert_creates_release_then_attaches "missing release, dotless RC"    "v1.0-rc1"   true

# Two jobs racing to cut the same release must not fail the run: the asset still
# has somewhere to land.
assert_survives_concurrent_create() {
  local description="$1" tag="$2"
  local log
  log=$(run_step "$tag" false "$FIXTURES/upload" "Upload to GitHub Release" "" true)

  if [ "$(status_of "$FIXTURES/upload")" -ne 0 ]; then
    printf '  FAIL %s (step exited %s after losing the create race)\n' \
      "$description" "$(status_of "$FIXTURES/upload")"
    printf '       gh calls: %s\n' "${log//$'\n'/ | }"
    failures=$((failures + 1))
    return
  fi

  if ! grep -q -- "release upload $tag .*--clobber" <<< "$log"; then
    printf '  FAIL %s (did not attach after losing the create race)\n' "$description"
    printf '       gh calls: %s\n' "${log//$'\n'/ | }"
    failures=$((failures + 1))
    return
  fi

  printf '  ok   %s\n' "$description"
}

echo
echo "Concurrent release creation"
assert_survives_concurrent_create "another job cut the release first" "v38.1-rc.1"

# A create that fails for any reason other than the race ends the run, and the
# reason `gh` gave has to reach the log. A re-check only reports "release not
# found", so the create output is what makes the failure diagnosable.
assert_reports_create_failure() {
  local description="$1" tag="$2"
  local log
  log=$(run_step "$tag" false "$FIXTURES/upload" "Upload to GitHub Release" "" hard)
  local output
  output=$(output_of "$FIXTURES/upload")

  if [ "$(status_of "$FIXTURES/upload")" -eq 0 ]; then
    printf '  FAIL %s (step succeeded despite no release)\n' "$description"
    printf '       gh calls: %s\n' "${log//$'\n'/ | }"
    failures=$((failures + 1))
    return
  fi

  if grep -q "release upload " <<< "$log"; then
    printf '  FAIL %s (attempted upload with no release present)\n' "$description"
    printf '       gh calls: %s\n' "${log//$'\n'/ | }"
    failures=$((failures + 1))
    return
  fi

  # The reason has to sit inside the annotation, not merely somewhere in the log:
  # only the annotation text reaches the run summary and the checks UI. Anchoring
  # to `^::error::` on the same line also pins the exact `::error::` prefix, which
  # a trailing space in the workflow-command form would break.
  if ! grep -q "^::error::.*Resource not accessible by integration" <<< "$output"; then
    printf '  FAIL %s (create failure reason not inside the ::error:: annotation)\n' \
      "$description"
    printf '       output: %s\n' "${output//$'\n'/ | }"
    failures=$((failures + 1))
    return
  fi

  printf '  ok   %s\n' "$description"
}

echo
echo "Unrecoverable create failure"
assert_reports_create_failure "reports why the create failed" "v38.2"

assert_verify() {
  local description="$1" expected="$2" attached_assets="$3"
  run_step "v37.0-rc.1" true "$FIXTURES/verify" "Verify release asset" \
    "$attached_assets" > /dev/null

  local actual="pass"
  [ "$(status_of "$FIXTURES/verify")" -ne 0 ] && actual="fail"

  if [ "$actual" == "$expected" ]; then
    printf '  ok   %s\n' "$description"
  else
    printf '  FAIL %s (expected the step to %s, it %sed)\n' \
      "$description" "$expected" "$actual"
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

if [ "$failures" -gt 0 ]; then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi

echo
echo "all assertions passed"
