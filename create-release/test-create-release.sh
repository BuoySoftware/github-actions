#!/usr/bin/env bash
#
# Tests the "Resolve release identity" and "Create or update release" steps in
# action.yml.
#
# Release identity is easy to get wrong in ways that look green. Notes generated
# from the wrong base silently describe the wrong range of commits -- often
# hundreds of them. A final release that declines "Latest" leaves consumers
# pointing at an older version, and a candidate that claims it misdirects
# everyone. When the release already exists, correcting its flags by a call that
# also names the tag is rejected outright and takes any attached asset down with
# it.
#
# The step bodies are extracted from action.yml rather than restated here, so the
# test exercises the shipped logic instead of a copy that can drift. `git` and
# `gh` are stubbed on PATH: `gh` serves the tag listing a page at a time and
# records the commands each step would issue, and `git` answers the commit a tag
# names. The listing is served newest-first, as the API does, so a step that
# trusts the order it receives fails here.
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
extract_step() {
  local step_name="$1"
  awk "/name: $step_name/,/shell: bash/" "$ACTION" \
    | sed -n '/run: |/,/shell: bash/p' \
    | sed '1d;$d' \
    | sed 's/^        //'
}

# Writes the `git` and `gh` stubs into a fixture directory.
#
# `tags` is a newline-separated tag list. A tag may carry its commit as
# `tag:sha`; without one it gets a commit derived from its own name, which keeps
# every tag on a distinct commit unless a test deliberately co-locates two.
#
# A tag whose commit is given as `tag:!` cannot be resolved, standing in for a
# tag object a partial fetch left behind.
#
# `release_exists`: whether `gh release view` finds the release initially.
# `create_result`: `ok`, `race` (rejected, release then present), or `hard`.
# `edit_fails`: whether `gh release edit` fails.
# `tags_per_page`: page size for the tag listing, so paging can be exercised
# with small fixtures.
# `tags_api_fails`: whether the tag listing errors.
write_stubs() {
  local fixture="$1" tags="$2" release_exists="$3"
  local create_result="$4" edit_fails="$5"
  local tags_per_page="${6:-100}" tags_api_fails="${7:-false}"

  mkdir -p "$fixture/bin"
  printf '%s\n' "$tags" | sed '/^$/d' > "$fixture/tags"

  # Stub `git`: answers the per-tag commit lookup. The tag listing comes from the
  # API stub below, so a step that reaches for `git tag` here gets nothing and
  # the assertion fails rather than quietly passing on local state.
  cat > "$fixture/bin/git" <<STUB
#!/usr/bin/env bash
echo "git \$*" >> "$fixture/git.log"
if [ "\$1" == "rev-list" ] || [ "\$1" == "rev-parse" ]; then
  # The commit a tag names. \`tag:sha\` in the fixture pins it; otherwise it is
  # derived from the tag name so each tag sits on its own commit.
  ref="\${@: -1}"
  ref="\${ref%^{commit\}}"
  ref="\${ref%^{\}}"
  line=\$(grep -m1 "^\${ref}:" "$fixture/tags")
  if [ "\${line#*:}" == "!" ]; then
    echo "fatal: bad revision '\$ref'" >&2
    exit 128
  fi
  if [ -n "\$line" ]; then
    echo "\${line#*:}"
  else
    echo "sha-\$ref"
  fi
  exit 0
fi
exit 0
STUB
  chmod +x "$fixture/bin/git"

  # Stub `gh`: serves the tag listing a page at a time, logs every invocation,
  # and reports whether the release exists so the step can branch on it.
  #
  # Pages are served in REVERSE fixture order, mimicking the API's newest-first
  # listing, which is not version order. Any step that trusts the order it
  # receives instead of ranking the tags itself fails here.
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
      per_page=$tags_per_page
      start=\$(( (page - 1) * per_page + 1 ))
      # awk reverses the list the same way everywhere; \`tail -r\` is BSD-only and
      # \`tac\` is GNU-only, so either one passes on one platform and fails on the other.
      cut -d: -f1 "$fixture/tags" \
        | awk '{ line[NR] = \$0 } END { for (i = NR; i > 0; i--) print line[i] }' \
        | sed -n "\${start},\$((start + per_page - 1))p"
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

# Runs a step with stubbed `git`/`gh` and echoes the commands it invoked, one per
# line. Records the exit code for `status_of` and the step's own output for
# `output_of`. Step outputs written to $GITHUB_OUTPUT land in `outputs`.
run_step() {
  local step_name="$1" tag="$2" tags="$3" fixture="$4"
  local release_exists="${5:-false}" create_result="${6:-ok}"
  local edit_fails="${7:-false}" step_env="${8:-}"
  local tags_per_page="${9:-100}" tags_api_fails="${10:-false}"
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
    "$edit_fails" "$tags_per_page" "$tags_api_fails"
  : > "$fixture/outputs"

  (
    cd "$fixture" || exit 2
    # The runner invokes `shell: bash` as `bash --noprofile --norc -e -o
    # pipefail`; without pipefail a failing stub upstream of a pipe passes here
    # and fails in CI. Step output goes to a file so stdout stays free for the
    # call log.
    # shellcheck disable=SC2086  # step_env is a deliberate list of assignments
    env PATH="$fixture/bin:$PATH" GITHUB_REF_NAME="$tag" GH_TOKEN="stub" \
      GITHUB_OUTPUT="$fixture/outputs" TAG="$tag" \
      GITHUB_REPOSITORY="owner/repo" MAX_PAGES="${MAX_PAGES_OVERRIDE:-20}" \
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
# The tag population every notes-base case resolves against.
#
# Mirrors the shapes the real repositories carry: two- and three-part versions,
# dotted and dotless candidate ordinals, trailing suffixes, a version line with
# no candidates, a sparse gap where a minor was never cut, and a line whose final
# sits on a later commit than its last candidate.
# ---------------------------------------------------------------------------
TAGS_MAIN=$(cat <<'EOF'
v35.3
v36.0-rc.1
v36.0-rc.6-mega
v36.0-rc.7-mega
v36.0
v36.1
v37.0-rc.1
v37.0-rc.3
v37.0-rc.4
EOF
)

# A line whose final names the same commit as its tip: the final is the better
# base because it is the published boundary of that line.
TAGS_COLOCATED=$(cat <<'EOF'
v2.1.0-rc.1:sha-tip
v2.1.0:sha-tip
v2.1.1-rc.1
v2.1.1-rc.2
EOF
)

assert_notes_start() {
  local description="$1" tag="$2" tags="$3" expected="$4"
  run_step "Resolve release identity" "$tag" "$tags" "$FIXTURES/identity" > /dev/null

  if [ "$(status_of "$FIXTURES/identity")" -ne 0 ]; then
    fail "$description" "step exited $(status_of "$FIXTURES/identity")" \
      "output: $(output_of "$FIXTURES/identity" | tr '\n' '|')"
    return
  fi

  local actual
  actual=$(step_output "$FIXTURES/identity" notes_start)
  if [ "$actual" != "$expected" ]; then
    fail "$description" "expected notes base '${expected:-<none>}', got '${actual:-<none>}'"
    return
  fi

  # Ordering must come from the parsed version, so the step must never ask for a
  # tag date to decide it.
  if grep -qE 'for-each-ref|creatordate|taggerdate|--sort=-?committerdate' \
    "$FIXTURES/identity/git.log" 2>/dev/null; then
    fail "$description" "ordered tags by date rather than by parsed version"
    return
  fi

  # Ancestry is not consulted: most release tags are unreachable from the default
  # branch, so a merge-base or ancestry check would silently drop candidates.
  if grep -qE 'merge-base|--is-ancestor|rev-list .*\.\.' \
    "$FIXTURES/identity/git.log" 2>/dev/null; then
    fail "$description" "consulted commit ancestry to pick the notes base"
    return
  fi

  printf '  ok   %s\n' "$description"
}

echo "Notes base: candidate within its own line"

# The common case: each candidate documents only what changed since the previous
# candidate of the same version.
assert_notes_start "candidate bases on the previous candidate" \
  "v37.0-rc.4" "$TAGS_MAIN" "v37.0-rc.3"
# Not rc.1: the highest lower candidate, not the lowest.
assert_notes_start "candidate skips over a gap in ordinals" \
  "v37.0-rc.3" "$TAGS_MAIN" "v37.0-rc.1"
# A trailing suffix is a collision-avoidance marker, not a separate line.
assert_notes_start "trailing suffix does not split the line" \
  "v36.0-rc.7-mega" "$TAGS_MAIN" "v36.0-rc.6-mega"
# Dotless and dotted ordinals are both in use and order together.
assert_notes_start "dotless ordinal orders with dotted ones" \
  "v1.0-rc2" "$(printf 'v0.9\nv1.0-rc1\nv1.0-rc2\n')" "v1.0-rc1"

echo
echo "Notes base: reaching back to the previous line"

# The first candidate of a line has nothing below it in its own line, so it
# reaches back -- and the previous line's final is the published boundary.
assert_notes_start "first candidate reaches the previous line" \
  "v36.0-rc.1" "$TAGS_MAIN" "v35.3"
# Sparse numbering: v35.4 was never cut, so the highest lower line is v35.3.
assert_notes_start "sparse numbering finds the highest lower line" \
  "v35.5-rc.1" "$TAGS_MAIN" "v35.3"
# A final has no candidates below it by definition, so it reaches back too.
assert_notes_start "final reaches the previous line" \
  "v2.2" "$(printf 'v2.1.0\nv2.1.1\nv2.2\n')" "v2.1.1"
# The ordinary shape: the previous line's final was cut at the tip of its own
# candidates, so it is the boundary. Reaching past it to a candidate would
# re-describe commits that final already published.
assert_notes_start "prefers the previous line's final over its last candidate" \
  "v2.2" "$(printf 'v2.1.1-rc.1\nv2.1.1-rc.2:sha-211\nv2.1.1:sha-211\nv2.2\n')" "v2.1.1"
# The line's final is preferred only when it names the same commit as the tip.
assert_notes_start "prefers the previous line's final when co-located with its tip" \
  "v2.1.1-rc.1" "$TAGS_COLOCATED" "v2.1.0"
# v36.0 was cut before v36.0-rc.7-mega, so basing on the final would re-describe
# everything the later candidates already covered.
assert_notes_start "falls back to the tip when the final is stranded behind it" \
  "v36.1" "$TAGS_MAIN" "v36.0-rc.7-mega"

echo
echo "Notes base: no lower line"

# Omitted, not empty and not the tag itself: an empty boundary would make the
# release API generate notes from the whole history.
assert_notes_start "omits the base when nothing is below" \
  "v1.0-rc.1" "$(printf 'v1.0-rc.1\n')" ""
assert_notes_start "omits the base for the very first release" \
  "v1.0" "$(printf 'v1.0\n')" ""
# Only the pushed tag's own line exists, and reaching back must not find it.
assert_notes_start "omits the base when only the same line exists" \
  "v3.0-rc.2" "$(printf 'v3.0-rc.1\nv3.0-rc.2\n')" "v3.0-rc.1"

echo
echo "Notes base: two-part and three-part forms are one line"

# v2.2 and v2.2.0 name the same version, so a candidate for one bases on the
# other rather than reaching past it.
assert_notes_start "three-part candidate bases on its two-part line-mate" \
  "v2.2.0-rc.2" "$(printf 'v2.1.0\nv2.2-rc.1\nv2.2.0-rc.2\n')" "v2.2-rc.1"
assert_notes_start "two-part final does not treat its three-part form as a lower line" \
  "v2.2" "$(printf 'v2.1.0\nv2.2.0-rc.1\nv2.2\n')" "v2.2.0-rc.1"

echo
echo "Notes base: no tags are excluded from the pool"

# Test and personal tags are ordinary members of the population. Excluding them
# would make the base depend on who cut the tag.
assert_notes_start "a suffixed personal tag is a valid base" \
  "v99.0-rc.2-someone_test" \
  "$(printf 'v98.0\nv99.0-rc.1-someone_test\nv99.0-rc.2-someone_test\n')" \
  "v99.0-rc.1-someone_test"
assert_notes_start "a suffixed final participates in line ordering" \
  "v11.1-pltf" "$(printf 'v11.0\nv11.1-pltf\n')" "v11.0"
# A tag whose object cannot be resolved must not end the run: the comparison it
# feeds has a defined answer without it, and the version ordering is unaffected.
# Both sides of that comparison are covered, since each is looked up separately.
assert_notes_start "an unresolvable candidate object does not end the run" \
  "v36.1" "$(printf 'v36.0-rc.7:!\nv36.0:sha-early\nv36.1\n')" "v36.0-rc.7"
assert_notes_start "an unresolvable final object does not end the run" \
  "v36.1" "$(printf 'v36.0-rc.7:sha-late\nv36.0:!\nv36.1\n')" "v36.0-rc.7"

# Tags that are not versions are ignored rather than ordered.
assert_notes_start "non-version tags are ignored, not ordered" \
  "v2.1.0" "$(printf 'latest\nnightly\nrelease-please--branches--main\nv2.0.0\nv2.1.0\n')" \
  "v2.0.0"
# A retired YYYYMMDD.N scheme parses as a version with a very high major, so
# without the required `v` those tags outrank every real release.
assert_notes_start "a retired date-numbered scheme is not a version line" \
  "v36.0-rc.1" "$(printf 'v35.3\n20250116.1\n20250116.0\nv36.0-rc.1\n')" "v35.3"

# ---------------------------------------------------------------------------
# Tag listing: bounded paging over the API
# ---------------------------------------------------------------------------

# Runs the resolve step with a page size small enough to force paging, and
# reports the notes base together with how many pages were requested.
assert_paging() {
  local description="$1" tag="$2" tags="$3" per_page="$4"
  local expected_base="$5" expected_pages="$6"
  run_step "Resolve release identity" "$tag" "$tags" "$FIXTURES/paging" \
    false ok false "" "$per_page" > /dev/null

  if [ "$(status_of "$FIXTURES/paging")" -ne 0 ]; then
    fail "$description" "step exited $(status_of "$FIXTURES/paging")" \
      "output: $(output_of "$FIXTURES/paging" | tr '\n' '|')"
    return
  fi

  local base pages
  base=$(step_output "$FIXTURES/paging" notes_start)
  pages=$(grep -c 'api .*tags' "$FIXTURES/paging/gh.log" 2>/dev/null || echo 0)

  if [ "$base" != "$expected_base" ]; then
    fail "$description" "expected base '${expected_base:-<none>}', got '${base:-<none>}'"
    return
  fi
  if [ "$pages" != "$expected_pages" ]; then
    fail "$description" "expected $expected_pages page request(s), made $pages"
    return
  fi
  printf '  ok   %s\n' "$description"
}

echo
echo "Tag listing: bounded paging"

# A page containing a version below the pushed tag's settles the answer.
assert_paging "stops once a lower version is on the page" \
  "v9.0-rc.2" \
  "$(printf 'v1.0\nv2.0\nv3.0\nv4.0\nv5.0\nv8.0\nv9.0-rc.1\nv9.0-rc.2\n')" \
  3 "v9.0-rc.1" 1
# The listing is newest-first, so a version with only same-line company at the
# head takes another page before a lower one appears.
assert_paging "pages until a lower version appears" \
  "v9.0" \
  "$(printf 'v1.0\nv8.0\nv9.0-rc.1\nv9.0-rc.2\nv9.0\n')" \
  2 "v9.0-rc.2" 2
# Exhausting the listing with no lower version is the "nothing below" case. The
# empty page that ends the listing is a request too.
assert_paging "exhausting the listing with no lower version omits the base" \
  "v1.0-rc.1" "$(printf 'v1.0-rc.1\n')" 100 "" 2

# A partial tag list must not produce a notes base.
assert_page_cap_fails_loudly() {
  local description="$1"
  # Every tag within reach of the cap is in the pushed tag's own version, so no
  # page the run is allowed to fetch settles the answer.
  local many
  many=$(for i in $(seq 8 -1 1); do printf 'v9.0-rc.%d\n' "$i"; done)
  MAX_PAGES_OVERRIDE=2 run_step "Resolve release identity" "v9.0" \
    "$(printf 'v1.0\n%s\nv9.0\n' "$many")" "$FIXTURES/cap" false ok false "" 1 > /dev/null

  if [ "$(status_of "$FIXTURES/cap")" -eq 0 ]; then
    fail "$description" "step succeeded on a partial tag list" \
      "base: $(step_output "$FIXTURES/cap" notes_start)"
    return
  fi
  if ! grep -q "^::error::.*limit" "$FIXTURES/cap/output" 2>/dev/null; then
    fail "$description" "no ::error:: annotation naming the limit" \
      "output: $(output_of "$FIXTURES/cap" | tr '\n' '|')"
    return
  fi
  printf '  ok   %s\n' "$description"
}

assert_page_cap_fails_loudly "hitting the page limit fails instead of guessing"

# A failed listing is not an empty repository.
assert_listing_failure_fails() {
  local description="$1"
  run_step "Resolve release identity" "v37.0" "$(printf 'v36.0\nv37.0\n')" \
    "$FIXTURES/apifail" false ok false "" 100 true > /dev/null

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

assert_listing_failure_fails "a failed tag listing fails the run"

# Reading tags locally would make identity depend on fetch depth.
echo
echo "Tag listing: no checkout required"
if grep -qE '^\s+git tag' "$ACTION"; then
  fail "tags come from the API, not the local repository" \
    "action.yml lists tags with 'git tag', which requires a full-depth checkout"
else
  printf '  ok   %s\n' "tags come from the API, not the local repository"
fi

# ---------------------------------------------------------------------------
# Prerelease
# ---------------------------------------------------------------------------

assert_prerelease() {
  local description="$1" tag="$2" expected="$3"
  run_step "Resolve release identity" "$tag" "$(printf '%s\n' "$tag")" \
    "$FIXTURES/identity" > /dev/null

  if [ "$(status_of "$FIXTURES/identity")" -ne 0 ]; then
    fail "$description" "step exited $(status_of "$FIXTURES/identity")" \
      "output: $(output_of "$FIXTURES/identity" | tr '\n' '|')"
    return
  fi

  local actual
  actual=$(step_output "$FIXTURES/identity" prerelease)
  if [ "$actual" != "$expected" ]; then
    fail "$description" "expected prerelease=$expected, got '${actual:-<unset>}'"
    return
  fi

  printf '  ok   %s\n' "$description"
}

echo
echo "Prerelease flag"

assert_prerelease "dotted ordinal is a prerelease"          "v37.0-rc.4"            true
assert_prerelease "dotless ordinal is a prerelease"          "v1.0-rc1"              true
assert_prerelease "suffixed candidate is a prerelease"       "v36.0-rc.7-mega"       true
assert_prerelease "personal suffixed candidate"              "v99.0-rc.1-someone_test"  true
assert_prerelease "three-part candidate is a prerelease"     "v2.1.1-rc.2"           true
assert_prerelease "two-part final is not a prerelease"       "v37.0"                 false
assert_prerelease "three-part final is not a prerelease"     "v2.1.1"                false
assert_prerelease "suffixed final is not a prerelease"       "v11.1-pltf"            false
# The pattern is anchored on an ordinal: a branch-name suffix that merely
# contains "rc" is not a release candidate.
assert_prerelease "an rc marker with no ordinal is not a prerelease" \
  "v27.1-rc.pen-test-fixes" false
assert_prerelease "rc inside an unrelated word does not match"  "v4.0-arch"          false

# The flag is decided from the tag, not by the caller: no input may override it.
# Reporting the resolved value as an output is fine, so only the inputs block is
# examined.
echo
echo "Prerelease is not caller-overridable"
declared_inputs=$(sed -n '/^inputs:/,/^[a-z]/p' "$ACTION" | grep -E '^  [a-z_]+:')
if grep -qiE '(prerelease|is_prerelease|latest|notes)' <<< "$declared_inputs"; then
  fail "no caller override input for the release flags" \
    "inputs declare an identity override: ${declared_inputs//$'\n'/ }"
else
  printf '  ok   %s\n' "no caller override input for the release flags"
fi

# ---------------------------------------------------------------------------
# Latest
# ---------------------------------------------------------------------------

assert_latest() {
  local description="$1" tag="$2" tags="$3" expected="$4"
  run_step "Resolve release identity" "$tag" "$tags" "$FIXTURES/identity" > /dev/null

  if [ "$(status_of "$FIXTURES/identity")" -ne 0 ]; then
    fail "$description" "step exited $(status_of "$FIXTURES/identity")" \
      "output: $(output_of "$FIXTURES/identity" | tr '\n' '|')"
    return
  fi

  local actual
  actual=$(step_output "$FIXTURES/identity" latest)
  if [ -z "$actual" ]; then
    # Omitting the flag lets the API fall back to publish order, which is what
    # put the wrong release under "Latest" in the first place.
    fail "$description" "latest was not set at all; it must always be explicit"
    return
  fi
  if [ "$actual" != "$expected" ]; then
    fail "$description" "expected latest=$expected, got '$actual'"
    return
  fi

  printf '  ok   %s\n' "$description"
}

echo
echo "Latest flag"

# A final with nothing final above it is the newest release of the product.
assert_latest "newest final claims latest" \
  "v37.0" "$(printf 'v36.0\nv36.1\nv37.0\n')" true
# Re-cutting an older patch must not drag "Latest" backwards.
assert_latest "older final declines latest" \
  "v36.1" "$(printf 'v36.0\nv36.1\nv37.0\n')" false
# A candidate is never the latest release, even when it sorts above every final.
assert_latest "candidate above every final still declines" \
  "v38.0-rc.1" "$(printf 'v37.0\nv38.0-rc.1\n')" false
assert_latest "candidate declines even as the only tag" \
  "v1.0-rc.1" "$(printf 'v1.0-rc.1\n')" false
# The first final of a repository is the latest by definition.
assert_latest "first final claims latest" \
  "v1.0" "$(printf 'v1.0\n')" true
# Candidates above it are not finals, so they do not block the claim.
assert_latest "candidates above a final do not block its claim" \
  "v37.0" "$(printf 'v37.0\nv38.0-rc.1\n')" true
# A patch on the newest line is the newest final.
assert_latest "newest patch claims latest" \
  "v37.1" "$(printf 'v37.0\nv37.1\n')" true
# Suffixed finals are ordinary finals for this comparison.
assert_latest "a suffixed final blocks a lower final's claim" \
  "v11.0" "$(printf 'v11.0\nv11.1-pltf\n')" false
# Read as versions, the retired scheme's tags sit above every real release.
assert_latest "a retired date-numbered scheme does not block the claim" \
  "v36.1" "$(printf 'v36.0\nv36.1\n20250116.1\n')" true

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
