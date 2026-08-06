#!/usr/bin/env bash
#
# Tests the shell-owned surface of action.yml: the "Create or update release"
# step, the wiring from the identity script to step outputs, and the invariants
# the file itself must hold.
#
# The release-identity rules (notes base, prerelease, latest, paging) are unit
# tested in test_resolve_release_identity.py against the script directly; they
# are not restated here. What only this suite covers: the step bodies as
# shipped, extracted from action.yml and run under the runner's shell flags, so
# a change to the wiring or the API calls is exercised rather than a copy that
# can drift.
#
# When the release already exists, correcting its flags by a call that also
# names the tag is rejected outright and takes any attached asset down with it.
# The create/edit split, the race with a concurrent job, and failure reporting
# all live in bash and are covered only here.
#
# `gh` is stubbed on PATH: it serves the tag listing a page at a time,
# newest-first as the API does, and records the commands each step would issue.
#
# Usage: ./create-release/test-create-release.sh

set -uo pipefail

ACTION="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/action.yml"
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

# Writes the `gh` stub into a fixture directory.
#
# `tags` is a newline-separated tag list. A tag may carry its commit as
# `tag:sha`; without one it gets a commit derived from its own name, which keeps
# every tag on a distinct commit unless a test deliberately co-locates two.
#
# `release_exists`: whether `gh release view` finds the release initially.
# `create_result`: `ok`, `race` (rejected, release then present), or `hard`.
# `edit_fails`: whether `gh release edit` fails.
# `tags_api_fails`: whether the tag listing errors.
write_stubs() {
  local fixture="$1" tags="$2" release_exists="$3"
  local create_result="$4" edit_fails="$5" tags_api_fails="${6:-false}"

  mkdir -p "$fixture/bin"
  printf '%s\n' "$tags" | sed '/^$/d' > "$fixture/tags"

  # Stub `gh`: serves the tag listing, logs every invocation, and reports
  # whether the release exists so the step can branch on it.
  #
  # The listing is served in REVERSE fixture order, mimicking the API's
  # newest-first order, which is not version order. A step that trusts the
  # order it receives instead of ranking the tags itself fails here.
  cat > "$fixture/bin/gh" <<STUB
#!/usr/bin/env bash
echo "gh \$*" >> "$fixture/gh.log"
if [ "\$1" == "api" ]; then
  case "\$2" in
    *"/tags"*)
      if [ "$tags_api_fails" == "true" ]; then
        echo "gh: HTTP 502: Bad gateway" >&2
        exit 1
      fi
      page=1
      case "\$2" in *page=*) page="\${2##*page=}"; page="\${page%%&*}" ;; esac
      if [ "\$page" -gt 1 ]; then
        exit 0
      fi
      # Each row is the tag and the commit it names, tab-separated, as the
      # step's \`--jq\` asks for. A fixture written as \`tag:sha\` pins the
      # commit so two tags can be co-located; without one the commit is derived
      # from the name.
      #
      # awk reverses the list the same way everywhere; \`tail -r\` is BSD-only
      # and \`tac\` is GNU-only, so either one passes on one platform and fails
      # on the other.
      awk -F: '{ name = \$1; sha = (\$2 == "" ? "sha-" \$1 : \$2)
                 line[NR] = name "\t" sha }
               END { for (i = NR; i > 0; i--) print line[i] }' "$fixture/tags"
      exit 0
      ;;
  esac
  exit 0
fi
if [ "\$1 \$2" == "release create" ]; then
  case "$create_result" in
    race)
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
  exit 0
fi
if [ "\$1 \$2" == "release edit" ]; then
  if [ "$edit_fails" == "true" ]; then
    echo "HTTP 422: Validation Failed" >&2
    exit 1
  fi
  exit 0
fi
exit 0
STUB
  chmod +x "$fixture/bin/gh"
}

# Runs a step with the stubbed `gh` and echoes the commands it invoked, one per
# line. Records the exit code for `status_of` and the step's own output for
# `output_of`. Step outputs written to $GITHUB_OUTPUT land in `outputs`.
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

  write_stubs "$fixture" "$tags" "$release_exists" "$create_result" \
    "$edit_fails" "$tags_api_fails"
  : > "$fixture/outputs"

  (
    cd "$fixture" || exit 2
    # The runner invokes `shell: bash` as `bash --noprofile --norc -e -o
    # pipefail`; without pipefail a failing stub upstream of a pipe passes here
    # and fails in CI. Step output goes to a file so stdout stays free for the
    # call log.
    # GITHUB_ACTION_PATH is the action's own directory, so a step invoking a
    # script there runs the shipped copy rather than one staged for the test.
    # shellcheck disable=SC2086  # step_env is a deliberate list of assignments
    env PATH="$fixture/bin:$PATH" GITHUB_REF_NAME="$tag" GH_TOKEN="stub" \
      GITHUB_OUTPUT="$fixture/outputs" TAG="$tag" \
      GITHUB_ACTION_PATH="$(dirname "$ACTION")" \
      GITHUB_REPOSITORY="owner/repo" MAX_PAGES="20" \
      $step_env \
      bash --noprofile --norc -e -o pipefail -c "$step" \
      > "$fixture/output" 2>&1
  )
  # Callers capture stdout via command substitution, so the status has to travel
  # through the filesystem rather than a variable the subshell would discard.
  echo $? > "$fixture/status"
  cat "$fixture/gh.log" 2>/dev/null
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
# The rules themselves are unit tested in Python. What the step adds is wiring:
# the env the runner passes, the shipped script invoked via GITHUB_ACTION_PATH,
# and the three outputs landing in $GITHUB_OUTPUT. One run per identity shape
# proves that path end to end.
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
      "gh calls: ${log//$'\n'/ | }" \
      "output: $(output_of "$FIXTURES/create" | tr '\n' '|')"
    return
  fi

  local create_line
  create_line=$(grep "release create $tag" <<< "$log")
  if [ -z "$create_line" ]; then
    fail "$description" "did not create the release" "gh calls: ${log//$'\n'/ | }"
    return
  fi

  local expected
  for expected in "$@"; do
    if ! grep -q -- "$expected" <<< "$create_line"; then
      fail "$description" "create call missing '$expected'" "create: $create_line"
      return
    fi
  done

  printf '  ok   %s\n' "$description"
}

# Latest is three-state on the create call, so it is passed as an explicit
# value rather than as a bare flag that can only mean "true".
assert_creates_with "final release passes its notes base and claims latest" \
  "v37.0" "v36.1" false true \
  "release create v37.0" "--notes-start-tag v36.1" "--latest=true"
assert_creates_with "candidate is marked prerelease and declines latest" \
  "v38.0-rc.1" "v37.0" true false \
  "--prerelease" "--notes-start-tag v37.0" "--latest=false"

# With no lower line there is no boundary to pass, and an empty one would widen
# the notes to the entire history.
assert_omits_notes_start() {
  local description="$1" tag="$2"
  local log
  log=$(run_create "$tag" false "" false true)

  if [ "$(status_of "$FIXTURES/create")" -ne 0 ]; then
    fail "$description" "step exited $(status_of "$FIXTURES/create")" \
      "gh calls: ${log//$'\n'/ | }"
    return
  fi
  if grep -q -- "--notes-start-tag" <<< "$log"; then
    fail "$description" "passed a notes boundary when there was none" \
      "gh calls: ${log//$'\n'/ | }"
    return
  fi
  # Notes are still generated; only the lower boundary is absent.
  if ! grep -q -- "--generate-notes" <<< "$log"; then
    fail "$description" "did not generate notes" "gh calls: ${log//$'\n'/ | }"
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
      "gh calls: ${log//$'\n'/ | }" \
      "output: $(output_of "$FIXTURES/create" | tr '\n' '|')"
    return
  fi

  # Creating again would be rejected; the existing release is edited instead.
  if grep -q "release create " <<< "$log"; then
    fail "$description" "tried to create a release that already exists" \
      "gh calls: ${log//$'\n'/ | }"
    return
  fi

  local edit_line
  edit_line=$(grep "release edit $tag" <<< "$log")
  if [ -z "$edit_line" ]; then
    fail "$description" "did not correct the existing release's flags" \
      "gh calls: ${log//$'\n'/ | }"
    return
  fi

  # Both flags are reconciled, not just the one that happens to be wrong.
  if ! grep -q -- "--prerelease=$prerelease" <<< "$edit_line"; then
    fail "$description" "edit did not set --prerelease=$prerelease" "edit: $edit_line"
    return
  fi
  if ! grep -q -- "--latest=$latest" <<< "$edit_line"; then
    fail "$description" "edit did not set --latest=$latest" "edit: $edit_line"
    return
  fi

  # Naming the tag is exactly what gets the call rejected and destroys the asset.
  if grep -qE -- '--tag[= ]' <<< "$edit_line"; then
    fail "$description" "edit named the tag; that is rejected as already_exists" \
      "edit: $edit_line"
    return
  fi

  # Fields the edit must leave alone. Passing any of them would overwrite notes
  # a human may have edited, or retarget the release at another commit.
  local forbidden
  for forbidden in "--notes" "--generate-notes" "--notes-start-tag" "--title" \
    "--target" "--notes-file" "--discussion-category"; do
    if grep -q -- "$forbidden" <<< "$edit_line"; then
      fail "$description" "edit passed $forbidden, overwriting existing content" \
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

# Every call must be scoped to the pushed tag. A call naming another release
# would move "Latest" off a release this run has no business touching.
assert_touches_only_pushed_tag() {
  local description="$1" tag="$2" release_exists="$3"
  local log
  log=$(run_create "$tag" "$release_exists" "v36.1" false true)
  local other
  other=$(grep -E "^gh release (create|edit|view|upload|delete) " <<< "$log" \
    | awk '{print $4}' | grep -v "^${tag}$" | head -1)

  if [ -n "$other" ]; then
    fail "$description" "a call targeted '$other' instead of the pushed tag" \
      "gh calls: ${log//$'\n'/ | }"
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
      "gh calls: ${log//$'\n'/ | }" \
      "output: $(output_of "$FIXTURES/create" | tr '\n' '|')"
    return
  fi

  # Having lost the race, it must reconcile the release the winner created.
  if ! grep -q "release edit $tag" <<< "$log"; then
    fail "$description" "did not reconcile the release the other job created" \
      "gh calls: ${log//$'\n'/ | }"
    return
  fi
  printf '  ok   %s\n' "$description"
}

assert_survives_concurrent_create "another job cut the release first" "v38.1-rc.1"

echo
echo "Create or update: unrecoverable failure"

# A create that fails for any reason other than the race ends the run, and the
# reason the CLI gave has to reach the annotation -- only annotation text shows
# up in the run summary and the checks UI.
assert_reports_create_failure() {
  local description="$1" tag="$2"
  local log
  log=$(run_create "$tag" false "v36.1" false true hard)
  local output
  output=$(output_of "$FIXTURES/create")

  if [ "$(status_of "$FIXTURES/create")" -eq 0 ]; then
    fail "$description" "step succeeded despite no release" \
      "gh calls: ${log//$'\n'/ | }"
    return
  fi

  # Nothing may be uploaded to a release that does not exist.
  if grep -q "release upload " <<< "$log"; then
    fail "$description" "attempted an upload with no release present" \
      "gh calls: ${log//$'\n'/ | }"
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
      "gh calls: ${log//$'\n'/ | }"
    return
  fi
  printf '  ok   %s\n' "$description"
}

assert_reports_edit_failure "fails when the flags cannot be corrected" "v38.3-rc.1"

# ---------------------------------------------------------------------------
# The action this one is being carved out of keeps creating releases until every
# caller reaches creation through this one.
# ---------------------------------------------------------------------------

echo
echo "generate-structure-sql is untouched"
SIBLING="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/generate-structure-sql/action.yml"
if ! grep -q "name: Upload to GitHub Release" "$SIBLING" 2>/dev/null; then
  fail "generate-structure-sql still creates releases" \
    "its Upload to GitHub Release step is gone; nothing is cutting releases yet"
elif ! grep -q "gh release create" "$SIBLING" 2>/dev/null; then
  fail "generate-structure-sql still creates releases" \
    "it no longer creates a missing release"
else
  printf '  ok   %s\n' "generate-structure-sql still creates releases"
fi

if [ "$failures" -gt 0 ]; then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi

echo
echo "all assertions passed"
