#!/usr/bin/env bash
# Exercises build-image/compose-tags.sh -- the same file action.yml runs, so
# these assertions hold against what ships rather than against a copy.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/compose-tags.sh"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'NOT OK %s%s\n' "$1" "${2:+ - $2}"; }

export GIT_SHA=0123456789abcdef0123456789abcdef01234567
export GIT_SHORT_SHA=0123456
export SECURITY_PATCH_TIMESTAMP=20260828120000

TMP="$(mktemp -d)"
trap 'test -d "$TMP" && command ''rm'' -r -- "$TMP"' EXIT

# Dockerfile fixtures: which ARGs are declared, and where. The $VAR text is
# literal Dockerfile content, not shell expansion.
# shellcheck disable=SC2016
printf 'FROM scratch\n'                             > "$TMP/none"
# shellcheck disable=SC2016
printf 'ARG BASE_IMAGE=a\nFROM $BASE_IMAGE\n'       > "$TMP/base-only"
# shellcheck disable=SC2016
printf 'ARG BUILDER_IMAGE=b\nFROM $BUILDER_IMAGE\n' > "$TMP/builder-only"
# shellcheck disable=SC2016
printf 'ARG BASE_IMAGE=a\nARG BUILDER_IMAGE=b\nFROM $BUILDER_IMAGE\nFROM $BASE_IMAGE\n' > "$TMP/both"
# shellcheck disable=SC2016
printf 'FROM scratch\nARG BASE_IMAGE=a\n'           > "$TMP/base-after-from"

# run <dockerfile> <security_patch> <tag_suffix> <base> <builder> <ref_tag> [rc_tag]
run() {
  DOCKERFILE="$1" SECURITY_PATCH="$2" TAG_SUFFIX="$3" \
  BASE_IMAGE="$4" BUILDER_IMAGE="$5" REF_TAG="$6" \
  RELEASE_CANDIDATE_TAG="${7:-}" \
    compose_tags 2>&1
}

expect_field() {
  local desc=$1 field=$2 want=$3 out=$4 got
  got="$(printf '%s\n' "$out" | sed -n "s/^${field}=//p")"
  if [ "$got" == "$want" ]; then
    ok "$desc"
  else
    fail "$desc" "$field: want '$want', got '$got'"
  fi
}

expect_rejected() {
  local desc=$1 needle=$2; shift 2
  local out rc
  out="$("$@")"; rc=$?
  if [ $rc -eq 0 ]; then
    fail "$desc" "expected non-zero exit"
  elif ! printf '%s' "$out" | grep -q "$needle"; then
    fail "$desc" "message did not mention '$needle': $out"
  else
    ok "$desc"
  fi
}

# --- tag composition -------------------------------------------------------
out="$(run "$TMP/none" false "" "" "" "")"
expect_field "bare build: long is the raw sha tag" long "sha-$GIT_SHA" "$out"
expect_field "bare build: short is the short sha tag" short "sha-$GIT_SHORT_SHA" "$out"
expect_field "bare build: no ref tag" tag "" "$out"

out="$(run "$TMP/none" true "" "" "" "")"
expect_field "security_patch appends the date suffix" \
  long "sha-$GIT_SHA-security-patch-20260828120000" "$out"

out="$(run "$TMP/both" false -base-pr40 img:a img:b "")"
expect_field "tag_suffix appends to long" long "sha-$GIT_SHA-base-pr40" "$out"
expect_field "tag_suffix appends to short" short "sha-$GIT_SHORT_SHA-base-pr40" "$out"

out="$(run "$TMP/both" true -base-pr40 img:a img:b "")"
expect_field "security_patch precedes tag_suffix" \
  long "sha-$GIT_SHA-security-patch-20260828120000-base-pr40" "$out"

# --- sha output is never suffixed ------------------------------------------
out="$(run "$TMP/both" true -base-pr40 img:a img:b "")"
expect_field "sha output stays a raw commit regardless of suffixes" \
  sha "sha-$GIT_SHA" "$out"

# --- ref tag ---------------------------------------------------------------
out="$(run "$TMP/none" false "" "" "" tag-v29.0)"
expect_field "unsuffixed build keeps the canonical release tag" tag tag-v29.0 "$out"

out="$(run "$TMP/both" false -base-pr40 img:a img:b tag-v29.0)"
expect_field "suffixed build cannot claim the canonical release tag" \
  tag tag-v29.0-base-pr40 "$out"

# --- guards ----------------------------------------------------------------
expect_rejected "base override without tag_suffix is rejected" \
  "require tag_suffix" run "$TMP/both" false "" img:a "" ""
expect_rejected "builder override without tag_suffix is rejected" \
  "require tag_suffix" run "$TMP/both" false "" "" img:b ""
expect_rejected "base override with release_candidate_tag is rejected" \
  "cannot be combined with release_candidate_tag" \
  run "$TMP/both" false -base-pr40 img:a "" tag-v29.0 v29.0-rc.1

# Per-input ARG checks: one declared and the other not is the expected
# intermediate state while the app repos adopt the two ARGs separately.
expect_rejected "base override rejected when no ARG BASE_IMAGE" \
  "base_image was passed" run "$TMP/none" false -base-pr40 img:a "" ""
expect_rejected "builder override rejected when no ARG BUILDER_IMAGE" \
  "builder_image was passed" run "$TMP/none" false -base-pr40 "" img:b ""
expect_rejected "builder override rejected when only BASE_IMAGE is declared" \
  "builder_image was passed" run "$TMP/base-only" false -base-pr40 "" img:b ""
expect_rejected "both overrides rejected when only BASE_IMAGE is declared" \
  "builder_image was passed" run "$TMP/base-only" false -base-pr40 img:a img:b ""
expect_rejected "base override rejected when only BUILDER_IMAGE is declared" \
  "base_image was passed" run "$TMP/builder-only" false -base-pr40 img:a "" ""

out="$(run "$TMP/base-only" false -base-pr40 img:a "" "")"
expect_field "base override accepted when ARG BASE_IMAGE is declared" \
  long "sha-$GIT_SHA-base-pr40" "$out"
out="$(run "$TMP/both" false -base-pr40 img:a img:b "")"
expect_field "both overrides accepted when both ARGs are declared" \
  long "sha-$GIT_SHA-base-pr40" "$out"

# An ARG after the first FROM cannot reach a FROM line, so presence alone
# is not enough -- the check is positional.
expect_rejected "ARG declared after the first FROM is rejected" \
  "before its first FROM" run "$TMP/base-after-from" false -base-pr40 img:a "" ""

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
