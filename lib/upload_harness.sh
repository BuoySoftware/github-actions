# Shared helpers for the actions' "Upload to GitHub Release" harnesses.
#
# Sourced, never run: the file name sits outside the `*/test-*.sh` glob CI
# runs, and sourcing it defines functions without executing a test.
#
# A harness sets these before sourcing:
#   ACTION           path to the action.yml under test
#   ACTION_DIR       the action directory, used as GITHUB_ACTION_PATH
#   HARNESS_ROOT     the repository root
#   FIXTURES         the temporary fixture directory
# and defines two functions:
#   asset_path_for   echoes the step's asset path, relative to the fixture it
#                    is given
#   write_asset      writes the asset, given the fixture and the resolved path
# It owns `failures` and its own action-specific assertions.

# Extract a step's `run:` body. The awk range restarts on each `name:` line, so
# it lands on the named step regardless of step order. Steps take their values
# from `env:`, so there are no `${{ }}` expressions left in the body to
# substitute -- `extract_step_env` resolves the step's own `env:` block instead.
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

# Extract the step's `env:` block as `NAME=value` lines, with the `${{ }}`
# expressions the runner would evaluate replaced by the harness's own values.
#
# The wiring under test lives in that block, so it is read from action.yml
# rather than injected: deleting `RELEASE_TAG: ${{ inputs.release_tag }}` leaves
# the variable unset for the shipped `run:` body, exactly as a dispatched run
# would see it.
#
# Expressions this does not know are left unresolved, so a step that starts
# depending on a new one fails loudly instead of running with an empty value.
extract_step_env() {
  local step_name="$1" asset_path="$2" github_ref="$3" release_tag="$4"

  awk "/name: $step_name/,/shell: bash/" "$ACTION" \
    | sed -n '/^ *env:/,/^ *run:/p' \
    | sed -n 's/^ *\([A-Z_][A-Z0-9_]*\): \(.*\)$/\1=\2/p' \
    | sed \
      -e "s|\${{ inputs.release_tag }}|$release_tag|g" \
      -e "s|\${{ github.ref }}|$github_ref|g" \
      -e "s|\${{ github.token }}|stub|g" \
      -e "s|^\(ASSET_PATH\)=.*|\1=$asset_path|"
}

# Runs the upload step against a fresh stand-in API serving the given fixture,
# and echoes the requests it made, one per line. Records the exit code for
# `status_of` and the step's own output for `output_of`.
#
# `asset_written` false leaves the asset absent, standing in for a generator
# that produced nothing.
run_step() {
  local github_ref="$1" release_exists="$2" fixture="$3"
  local attached_assets="${4:-}" release_tag="${5:-}" asset_written="${6:-true}"
  local step asset_path
  local -a step_env
  step=$(extract_step "Upload to GitHub Release")
  rm -rf "${fixture:?}"
  mkdir -p "$fixture"
  asset_path=$(asset_path_for "$fixture")

  if [ -z "$step" ]; then
    # No `run:` body to extract -- the step is a `uses:` action, or was renamed.
    echo 2 > "$fixture/status"
    return
  fi

  if [ "$asset_written" = true ]; then
    write_asset "$fixture" "$asset_path"
  fi
  mapfile -t step_env < <(extract_step_env "Upload to GitHub Release" \
    "$asset_path" "$github_ref" "$release_tag")
  echo "$release_exists" > "$fixture/release_exists"
  echo "$attached_assets" > "$fixture/attached_assets"
  : > "$fixture/requests.log"

  python3 "$HARNESS_ROOT/lib/fake_github.py" "$fixture" &
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
    # GITHUB_* below are the runner's own context. Everything the step needs
    # beyond that comes from its `env:` block in action.yml, unmodified.
    env GITHUB_API_URL="http://127.0.0.1:$(cat "$fixture/port")" \
      GITHUB_REF_NAME="${github_ref##*/}" \
      GITHUB_ACTION_PATH="$ACTION_DIR" \
      GITHUB_REPOSITORY="owner/repo" \
      "${step_env[@]}" \
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
