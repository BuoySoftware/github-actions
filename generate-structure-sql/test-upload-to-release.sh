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
run_step() {
  local tag="$1" release_exists="$2" fixture="$3"
  local step_name="${4:-Upload to GitHub Release}" attached_assets="${5:-}"
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
if [ "\$1 \$2" == "release view" ]; then
  if [ "$release_exists" != "true" ]; then exit 1; fi
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
    PATH="$fixture/bin:$PATH" GITHUB_REF_NAME="$tag" GH_TOKEN="stub" \
      bash -e -c "$step" >/dev/null 2>&1
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

# An auto-created release would carry empty notes and a guessed prerelease flag,
# so a missing one must fail rather than be created.
assert_fails_loudly_when_release_missing() {
  local description="$1" tag="$2"
  local log
  log=$(run_step "$tag" false "$FIXTURES/upload")

  if grep -qE "release (create|edit) " <<< "$log"; then
    printf '  FAIL %s (created the release instead of failing)\n' "$description"
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

  if [ "$(status_of "$FIXTURES/upload")" -eq 0 ]; then
    printf '  FAIL %s (succeeded with no release present)\n' "$description"
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

assert_fails_loudly_when_release_missing "missing release, RC tag"    "v38.0-rc.1"
assert_fails_loudly_when_release_missing "missing release, final tag" "v38.0"

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
