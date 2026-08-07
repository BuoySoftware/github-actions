#!/usr/bin/env bash
#
# Tests the shipped step bodies in action.yml, plus the invariants the file
# itself must hold.
#
# The release-identity rules are unit tested against the scripts directly and
# are not restated here. This suite covers what only it can: the step bodies
# as shipped, extracted from action.yml and run under the runner's shell flags
# against a local stand-in GitHub API, with assertions on the requests they
# actually make. Nothing is stubbed on PATH.
#
# Usage: ./create-release/test-create-release.sh

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
# extracted from there. Both forms are read out of action.yml rather than
# restated, so a step that changes shape is still the step under test.
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
# echoes the requests the step made, one per line. Records the exit code for
# `status_of` and the step's own output for `output_of`. Step outputs written
# to $GITHUB_OUTPUT land in `outputs`.
#
# `tags` is a newline-separated list, one `name` or `name:sha` per line; a
# pinned sha lets a test co-locate two tags on one commit.
run_step() {
  local step_name="$1" tag="$2" tags="$3" fixture="$4"
  local release_exists="${5:-false}" create_result="${6:-ok}"
  local edit_fails="${7:-false}" step_env="${8:-}" tags_api_fails="${9:-false}"
  local step
  step=$(extract_step "$step_name")
  rm -rf "$fixture"
  mkdir -p "$fixture"

  if [ -z "$step" ]; then
    # No `run:` body to extract -- the step is a `uses:` action, or was renamed.
    echo 2 > "$fixture/status"
    return
  fi

  printf '%s\n' "$tags" | sed '/^$/d' > "$fixture/tags"
  echo "$release_exists" > "$fixture/release_exists"
  echo "$create_result" > "$fixture/create_result"
  echo "$edit_fails" > "$fixture/edit_fails"
  echo "$tags_api_fails" > "$fixture/tags_api_fails"
  : > "$fixture/requests.log"
  : > "$fixture/outputs"

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
    # shellcheck disable=SC2086  # step_env is a deliberate list of assignments
    env GITHUB_API_URL="http://127.0.0.1:$(cat "$fixture/port")" \
      GITHUB_REF_NAME="$tag" GH_TOKEN="stub" \
      GITHUB_OUTPUT="$fixture/outputs" TAG="$tag" \
      GITHUB_ACTION_PATH="$SCRIPT_DIR" \
      GITHUB_REPOSITORY="owner/repo" MAX_PAGES="20" \
      $step_env \
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

status_of() {
  cat "$1/status" 2>/dev/null || echo 2
}

output_of() {
  cat "$1/output" 2>/dev/null
}

# Reads a value the step wrote to $GITHUB_OUTPUT.
step_output() {
  local fixture="$1" key="$2"
  sed -n "s/^${key}=//p" "$fixture/outputs" 2>/dev/null | tail -1
}

fail() {
  local description="$1"
  shift
  printf '  FAIL %s\n' "$description"
  local detail
  for detail in "$@"; do
    printf '       %s\n' "$detail"
  done
  failures=$((failures + 1))
}

# ---------------------------------------------------------------------------
# Resolve release identity: wiring
#
# The rules themselves are unit tested. What the step adds is wiring: the env
# the runner passes, the shipped script invoked via GITHUB_ACTION_PATH, the
# listing fetched over HTTP, and the three outputs landing in $GITHUB_OUTPUT.
# One run per identity shape proves that path end to end.
# ---------------------------------------------------------------------------

assert_identity() {
  local description="$1" tag="$2" tags="$3"
  local notes_start="$4" prerelease="$5" latest="$6"
  run_step "Resolve release identity" "$tag" "$tags" "$FIXTURES/identity" > /dev/null

  if [ "$(status_of "$FIXTURES/identity")" -ne 0 ]; then
    fail "$description" "step exited $(status_of "$FIXTURES/identity")" \
      "output: $(output_of "$FIXTURES/identity" | tr '\n' '|')"
    return
  fi

  local key expected actual
  for key in notes_start prerelease latest; do
    case "$key" in
      notes_start) expected="$notes_start" ;;
      prerelease) expected="$prerelease" ;;
      latest) expected="$latest" ;;
    esac
    actual=$(step_output "$FIXTURES/identity" "$key")
    if [ "$actual" != "$expected" ]; then
      fail "$description" "expected $key='${expected:-<none>}', got '${actual:-<unset>}'"
      return
    fi
  done

  printf '  ok   %s\n' "$description"
}

echo "Resolve release identity: script wiring"

# A candidate whose line reaches back to a final co-located with its own tip:
# exercises the commit field of the listing through the shipped script, and all
# three outputs at once.
assert_identity "candidate outputs land in GITHUB_OUTPUT" \
  "v2.1.1-rc.1" \
  "$(printf 'v2.1.0-rc.1:sha-tip\nv2.1.0:sha-tip\nv2.1.1-rc.1\n')" \
  "v2.1.0" true false

# The newest final: the other side of every flag.
assert_identity "final outputs land in GITHUB_OUTPUT" \
  "v2.2" "$(printf 'v2.1.0\nv2.2\n')" "v2.1.0" false true

# A failed listing is not an empty repository, and the script's exit code and
# annotation must both survive the step wiring.
assert_listing_failure_fails() {
  local description="$1"
  run_step "Resolve release identity" "v37.0" "$(printf 'v36.0\nv37.0\n')" \
    "$FIXTURES/apifail" false ok false "" true > /dev/null

  if [ "$(status_of "$FIXTURES/apifail")" -eq 0 ]; then
    fail "$description" "step succeeded despite the tag listing failing" \
      "base: $(step_output "$FIXTURES/apifail" notes_start)"
    return
  fi
  if ! grep -q '^::error::' "$FIXTURES/apifail/output" 2>/dev/null; then
    fail "$description" "listing failure produced no ::error:: annotation"
    return
  fi
  printf '  ok   %s\n' "$description"
}

assert_listing_failure_fails "a failed tag listing fails the step"

# Reading tags locally would make identity depend on fetch depth.
echo
echo "Tag listing: no checkout required"
if grep -qE '^\s+git tag' "$ACTION"; then
  fail "tags come from the API, not the local repository" \
    "action.yml lists tags with 'git tag', which requires a full-depth checkout"
else
  printf '  ok   %s\n' "tags come from the API, not the local repository"
fi

# The flags are decided from the tag, not by the caller: no input may override
# them. Reporting the resolved values as outputs is fine, so only the inputs
# block is examined.
echo
echo "Identity is not caller-overridable"
declared_inputs=$(sed -n '/^inputs:/,/^[a-z]/p' "$ACTION" | grep -E '^  [a-z_]+:')
if grep -qiE '(prerelease|is_prerelease|latest|notes)' <<< "$declared_inputs"; then
  fail "no caller override input for the release flags" \
    "inputs declare an identity override: ${declared_inputs//$'\n'/ }"
else
  printf '  ok   %s\n' "no caller override input for the release flags"
fi

# ---------------------------------------------------------------------------
# Create or update release
# ---------------------------------------------------------------------------

# Runs the create/update step with identity values the resolve step would have
# produced.
run_create() {
  local tag="$1" release_exists="$2" notes_start="$3" prerelease="$4"
  local latest="$5" create_result="${6:-ok}" edit_fails="${7:-false}"
  run_step "Create or update release" "$tag" "$(printf '%s\n' "$tag")" \
    "$FIXTURES/create" "$release_exists" "$create_result" "$edit_fails" \
    "NOTES_START=$notes_start PRERELEASE=$prerelease LATEST=$latest"
}

echo
echo "Create or update: creating a new release"

assert_creates_with() {
  local description="$1" tag="$2" notes_start="$3" prerelease="$4" latest="$5"
  shift 5
  local log
  log=$(run_create "$tag" false "$notes_start" "$prerelease" "$latest")

  if [ "$(status_of "$FIXTURES/create")" -ne 0 ]; then
    fail "$description" "step exited $(status_of "$FIXTURES/create")" \
      "requests: ${log//$'\n'/ | }" \
      "output: $(output_of "$FIXTURES/create" | tr '\n' '|')"
    return
  fi

  local create_line
  create_line=$(grep -E "^POST /repos/owner/repo/releases " <<< "$log")
  if [ -z "$create_line" ]; then
    fail "$description" "did not create the release" "requests: ${log//$'\n'/ | }"
    return
  fi

  local expected
  for expected in "$@"; do
    if ! grep -q -- "$expected" <<< "$create_line"; then
      fail "$description" "create request missing '$expected'" "create: $create_line"
      return
    fi
  done

  printf '  ok   %s\n' "$description"
}

# make_latest is three-state on the API, so it is always stated as an explicit
# value; the fallback for an omitted flag is publish order. The notes body in
# the create request proves the boundary flowed through notes generation.
assert_creates_with "final release passes its notes base and claims latest" \
  "v37.0" "v36.1" false true \
  '"tag_name": "v37.0"' '"prerelease": false' '"make_latest": "true"' \
  '"body": "notes from v36.1"'
assert_creates_with "candidate is marked prerelease and declines latest" \
  "v38.0-rc.1" "v37.0" true false \
  '"prerelease": true' '"make_latest": "false"' '"body": "notes from v37.0"'

# With no lower line there is no boundary to pass, and an empty one would widen
# the notes to the entire history -- generation is asked for instead.
assert_omits_notes_start() {
  local description="$1" tag="$2"
  local log
  log=$(run_create "$tag" false "" false true)

  if [ "$(status_of "$FIXTURES/create")" -ne 0 ]; then
    fail "$description" "step exited $(status_of "$FIXTURES/create")" \
      "requests: ${log//$'\n'/ | }"
    return
  fi
  if grep -q "generate-notes" <<< "$log"; then
    fail "$description" "generated notes from a boundary when there was none" \
      "requests: ${log//$'\n'/ | }"
    return
  fi
  if ! grep -q -- '"generate_release_notes": true' <<< "$log"; then
    fail "$description" "did not ask for generated notes" \
      "requests: ${log//$'\n'/ | }"
    return
  fi
  printf '  ok   %s\n' "$description"
}

assert_omits_notes_start "omits the boundary entirely when there is none" "v1.0"

echo
echo "Create or update: the release already exists"

# The failure this step exists to prevent: correcting flags by a call that also
# names the tag is rejected with `already_exists`, and the rejection takes any
# attached asset with it. A field-scoped edit patches only what it names.
assert_corrects_existing() {
  local description="$1" tag="$2" prerelease="$3" latest="$4"
  local log
  log=$(run_create "$tag" true "v36.1" "$prerelease" "$latest")

  if [ "$(status_of "$FIXTURES/create")" -ne 0 ]; then
    fail "$description" "step exited $(status_of "$FIXTURES/create")" \
      "requests: ${log//$'\n'/ | }" \
      "output: $(output_of "$FIXTURES/create" | tr '\n' '|')"
    return
  fi

  # Creating again would be rejected; the existing release is edited instead.
  if grep -qE "^POST /repos/owner/repo/releases " <<< "$log"; then
    fail "$description" "tried to create a release that already exists" \
      "requests: ${log//$'\n'/ | }"
    return
  fi

  local edit_line
  edit_line=$(grep -E "^PATCH /repos/owner/repo/releases/[0-9]+ " <<< "$log")
  if [ -z "$edit_line" ]; then
    fail "$description" "did not correct the existing release's flags" \
      "requests: ${log//$'\n'/ | }"
    return
  fi

  # Both flags are reconciled, not just the one that happens to be wrong.
  if ! grep -q -- "\"prerelease\": $prerelease" <<< "$edit_line"; then
    fail "$description" "edit did not set prerelease=$prerelease" "edit: $edit_line"
    return
  fi
  if ! grep -q -- "\"make_latest\": \"$latest\"" <<< "$edit_line"; then
    fail "$description" "edit did not set make_latest=$latest" "edit: $edit_line"
    return
  fi

  # The edit is addressed by id and names only the two flags. Naming the tag is
  # exactly what gets a correction rejected, and any other field it carried
  # would overwrite content -- notes a human edited, the title, the target.
  local field
  for field in tag_name name body draft target_commitish discussion_category_name; do
    if grep -q -- "\"$field\"" <<< "$edit_line"; then
      fail "$description" "edit named '$field', which it must leave alone" \
        "edit: $edit_line"
      return
    fi
  done

  printf '  ok   %s\n' "$description"
}

assert_corrects_existing "corrects a candidate wrongly published as final" \
  "v38.0-rc.1" true false
assert_corrects_existing "corrects a final left marked prerelease" \
  "v37.0" false true

# Every request must be scoped to the pushed tag. A call naming another release
# would move "Latest" off a release this run has no business touching.
assert_touches_only_pushed_tag() {
  local description="$1" tag="$2" release_exists="$3"
  local log
  log=$(run_create "$tag" "$release_exists" "v36.1" false true)
  local other
  other=$(grep -oE '"tag_name": "[^"]+"|/releases/tags/[^ ]+' <<< "$log" \
    | grep -oE 'v[0-9][^" ]*' | grep -v "^${tag}$" | head -1)

  if [ -n "$other" ]; then
    fail "$description" "a request targeted '$other' instead of the pushed tag" \
      "requests: ${log//$'\n'/ | }"
    return
  fi
  printf '  ok   %s\n' "$description"
}

echo
echo "Create or update: scope"
assert_touches_only_pushed_tag "touches only the pushed tag when creating" "v37.0" false
assert_touches_only_pushed_tag "touches only the pushed tag when editing"  "v37.0" true

echo
echo "Create or update: concurrent creation"

# Two tag-triggered jobs can race. Losing the race is not a failure: the release
# the other job created is the one this run wanted.
assert_survives_concurrent_create() {
  local description="$1" tag="$2"
  local log
  log=$(run_create "$tag" false "v36.1" true false race)

  if [ "$(status_of "$FIXTURES/create")" -ne 0 ]; then
    fail "$description" "step exited $(status_of "$FIXTURES/create") after losing the race" \
      "requests: ${log//$'\n'/ | }" \
      "output: $(output_of "$FIXTURES/create" | tr '\n' '|')"
    return
  fi

  # Having lost the race, it must reconcile the release the winner created.
  if ! grep -qE "^PATCH /repos/owner/repo/releases/[0-9]+ " <<< "$log"; then
    fail "$description" "did not reconcile the release the other job created" \
      "requests: ${log//$'\n'/ | }"
    return
  fi
  printf '  ok   %s\n' "$description"
}

assert_survives_concurrent_create "another job cut the release first" "v38.1-rc.1"

echo
echo "Create or update: unrecoverable failure"

# A create that fails for any reason other than the race ends the run, and the
# reason the API gave has to reach the annotation -- only annotation text shows
# up in the run summary and the checks UI.
assert_reports_create_failure() {
  local description="$1" tag="$2"
  local log
  log=$(run_create "$tag" false "v36.1" false true hard)
  local output
  output=$(output_of "$FIXTURES/create")

  if [ "$(status_of "$FIXTURES/create")" -eq 0 ]; then
    fail "$description" "step succeeded despite no release" \
      "requests: ${log//$'\n'/ | }"
    return
  fi

  # Nothing may be corrected on a release that does not exist.
  if grep -q "^PATCH " <<< "$log"; then
    fail "$description" "patched a release that was never created" \
      "requests: ${log//$'\n'/ | }"
    return
  fi

  if ! grep -q "^::error::.*Resource not accessible by integration" <<< "$output"; then
    fail "$description" "create failure reason not inside the ::error:: annotation" \
      "output: ${output//$'\n'/ | }"
    return
  fi
  printf '  ok   %s\n' "$description"
}

assert_reports_create_failure "reports why the create failed" "v38.2"

# A failed reconciliation is a real failure: leaving the flags wrong is the bug
# this action exists to fix, so it must not pass silently.
assert_reports_edit_failure() {
  local description="$1" tag="$2"
  local log
  log=$(run_create "$tag" true "v36.1" true false ok true)

  if [ "$(status_of "$FIXTURES/create")" -eq 0 ]; then
    fail "$description" "step succeeded despite failing to correct the flags" \
      "requests: ${log//$'\n'/ | }"
    return
  fi
  printf '  ok   %s\n' "$description"
}

assert_reports_edit_failure "fails when the flags cannot be corrected" "v38.3-rc.1"

# ---------------------------------------------------------------------------
# Every caller reaches release creation through this action; the sibling only
# attaches, and fails loudly when the release is missing.
# ---------------------------------------------------------------------------

echo
echo "generate-structure-sql is attach-only"
SIBLING_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/generate-structure-sql"
if ! grep -q "name: Upload to GitHub Release" "$SIBLING_DIR/action.yml" 2>/dev/null; then
  fail "generate-structure-sql only attaches" \
    "its Upload to GitHub Release step is gone; nothing attaches the asset"
elif grep -q "def created_release" "$SIBLING_DIR/attach_structure_sql.py" 2>/dev/null; then
  fail "generate-structure-sql only attaches" \
    "it still carries its own release-creation path"
elif ! grep -q "No release exists for" "$SIBLING_DIR/attach_structure_sql.py" 2>/dev/null; then
  fail "generate-structure-sql only attaches" \
    "a missing release is not reported as a hard failure"
else
  printf '  ok   %s\n' "generate-structure-sql only attaches"
fi

if [ "$failures" -gt 0 ]; then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi

echo
echo "all assertions passed"
