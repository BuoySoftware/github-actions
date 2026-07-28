#!/usr/bin/env bash
#
# Tests the "Detect Yarn Berry" step in action.yml.
#
# Choosing the wrong branch is silent and costly: a Yarn Berry repo routed down
# the Classic path runs `yarn --frozen-lockfile`, which a Berry lockfile can
# never satisfy. The Classic install is additionally guarded by a node_modules
# cache hit, so the failure only surfaces on a cache miss.
#
# The conditional is extracted from action.yml rather than restated here, so the
# test exercises the shipped logic instead of a copy that can drift.
#
# Usage: ./setup-node/test-detect-yarn-berry.sh

set -uo pipefail

ACTION="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/action.yml"
FIXTURES=$(mktemp -d)
trap 'rm -rf "$FIXTURES"' EXIT

failures=0

# Extract the `run:` body of the Detect Yarn Berry step and substitute the two
# input expressions the way the Actions runner would.
extract_step() {
  local enable_corepack="$1" working_directory="$2"
  awk '/name: Detect Yarn Berry/,/shell: bash/' "$ACTION" \
    | sed -n '/run: |/,/shell: bash/p' \
    | sed '1d;$d' \
    | sed 's/^        //' \
    | sed -e "s|\${{ inputs.working-directory }}|$working_directory|g" \
          -e "s|\${{ inputs.enable-corepack }}|$enable_corepack|g"
}

# Runs the real step against a fixture tree and echoes the resolved is_berry.
detect() {
  local enable_corepack="$1" working_directory="$2" fixture="$3"
  local step output
  step=$(extract_step "$enable_corepack" "$working_directory")
  if [ -z "$step" ]; then
    echo "FATAL: could not extract Detect Yarn Berry step from $ACTION" >&2
    exit 2
  fi
  output="$fixture/github_output"
  : > "$output"
  ( cd "$fixture" && GITHUB_OUTPUT="$output" bash -c "$step" >/dev/null 2>&1 )
  sed -n 's/^is_berry=//p' "$output"
}

assert_detects() {
  local description="$1" expected="$2" enable_corepack="$3" working_directory="$4" fixture="$5"
  local actual
  actual=$(detect "$enable_corepack" "$working_directory" "$fixture")
  if [ "$actual" == "$expected" ]; then
    printf '  ok   %s\n' "$description"
  else
    printf '  FAIL %s (expected is_berry=%s, got %s)\n' "$description" "$expected" "${actual:-<empty>}"
    failures=$((failures + 1))
  fi
}

# A Berry repo: .yarnrc.yml at the checkout root, and in a nested package.
berry="$FIXTURES/berry"
mkdir -p "$berry/packages/web"
: > "$berry/.yarnrc.yml"
: > "$berry/packages/web/.yarnrc.yml"

# A Classic repo: no .yarnrc.yml anywhere.
classic="$FIXTURES/classic"
mkdir -p "$classic/packages/web"

echo "Detect Yarn Berry"

# The regression. Callers that omit working-directory get the "" default, which
# must still resolve to the checkout root -- not the filesystem root.
assert_detects "Berry repo, working-directory omitted"     true  false "" "$berry"
assert_detects "Berry repo, working-directory '.'"         true  false "." "$berry"
assert_detects "Berry repo, nested working-directory"      true  false "packages/web" "$berry"

# enable-corepack forces Berry regardless of what is on disk.
assert_detects "enable-corepack overrides detection"       true  true  "" "$classic"

# Classic repos must keep taking the Classic path.
assert_detects "Classic repo, working-directory omitted"   false false "" "$classic"
assert_detects "Classic repo, nested working-directory"    false false "packages/web" "$classic"

if [ "$failures" -gt 0 ]; then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi

echo "all assertions passed"
