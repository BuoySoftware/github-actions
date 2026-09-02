#!/usr/bin/env bash
# Exercises the tag-composition and guard logic from build-image/action.yml.
# The logic under test is extracted from the action's "Read current git details"
# step; keep the two in sync.

set -uo pipefail

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'NOT OK %s%s\n' "$1" "${2:+ — $2}"; }

SHA_FULL=0123456789abcdef0123456789abcdef01234567
SHA_SHORT=0123456

# Mirrors the action's step. Emits: sha, short, long, tag — or exits non-zero
# with the guard message.
compose_tags() {
  local SECURITY_PATCH=$1 TAG_SUFFIX=$2 BASE_IMAGE=$3 BUILDER_IMAGE=$4 REF=$5

  if [ -z "$TAG_SUFFIX" ] && { [ -n "$BASE_IMAGE" ] || [ -n "$BUILDER_IMAGE" ]; }; then
    echo "GUARD_TRIPPED"
    return 1
  fi

  local sha short long tag
  sha="sha-$SHA_FULL"
  short="sha-$SHA_SHORT"
  long="${sha}"
  tag=""

  if [ "$SECURITY_PATCH" == "true" ]; then
    local date_suffix="security-patch-20260828120000"
    short="${short}-${date_suffix}"
    long="${long}-${date_suffix}"
  fi

  if [ -n "$TAG_SUFFIX" ]; then
    short="${short}${TAG_SUFFIX}"
    long="${long}${TAG_SUFFIX}"
  fi

  if [ -n "$REF" ]; then
    tag="tag-${REF}"
  fi

  if [ -n "$tag" ] && [ -n "$TAG_SUFFIX" ]; then
    tag="${tag}${TAG_SUFFIX}"
  fi

  printf 'sha=%s\nshort=%s\nlong=%s\ntag=%s\n' "$sha" "$short" "$long" "$tag"
}

########################################
# Tag composition: the four cases
########################################

out=$(compose_tags false "" "" "" "")
if grep -qx "short=sha-$SHA_SHORT" <<<"$out" && grep -qx "long=sha-$SHA_FULL" <<<"$out"; then
  ok "bare build: unsuffixed sha tags"
else
  fail "bare build" "$out"
fi

out=$(compose_tags true "" "" "" "")
if grep -q "^short=sha-$SHA_SHORT-security-patch-" <<<"$out"; then
  ok "security_patch: date suffix applied"
else
  fail "security_patch" "$out"
fi

out=$(compose_tags false "-base-pr40" "" "" "")
if grep -qx "short=sha-$SHA_SHORT-base-pr40" <<<"$out"; then
  ok "tag_suffix: appended verbatim"
else
  fail "tag_suffix" "$out"
fi

out=$(compose_tags true "-base-pr40" "" "" "")
if grep -qx "short=sha-$SHA_SHORT-security-patch-20260828120000-base-pr40" <<<"$out"; then
  ok "both: security_patch first, then tag_suffix"
else
  fail "suffix ordering" "$out"
fi

########################################
# Guard: a base override without tag_suffix must fail loudly
########################################

for desc in "base_image" "builder_image"; do
  if [ "$desc" = "base_image" ]; then
    out=$(compose_tags false "" "ecr/base:pr-40" "" ""); rc=$?
  else
    out=$(compose_tags false "" "" "ecr/base-builder:pr-40" ""); rc=$?
  fi
  if [ $rc -ne 0 ] && grep -q GUARD_TRIPPED <<<"$out"; then
    ok "$desc without tag_suffix fails loudly"
  else
    fail "$desc guard" "rc=$rc $out"
  fi
done

out=$(compose_tags false "-base-pr40" "ecr/base:pr-40" "ecr/base-builder:pr-40" ""); rc=$?
if [ $rc -eq 0 ]; then
  ok "base override with tag_suffix is accepted"
else
  fail "base override accepted" "rc=$rc"
fi

########################################
# CURR_GIT_SHA keeps the sha- prefix and drops build suffixes.
# BUOY_SLUG_COMMIT feeds the REQ-084 labeling lookup, which strips "sha-"
# and matches the remainder against a 40-hex commit column. A suffix here
# silently falls back to the most recent software version.
########################################

out=$(compose_tags true "-base-pr40" "" "" "")
if grep -qx "sha=sha-$SHA_FULL" <<<"$out"; then
  ok "commit value keeps sha- prefix, unaffected by either suffix"
else
  fail "commit value" "$out"
fi

sha_line=$(grep '^sha=' <<<"$out"); stripped="${sha_line#sha=}"; stripped="${stripped#sha-}"
if [[ "$stripped" =~ ^[0-9a-f]{40}$ ]]; then
  ok "REQ-084: value resolves to a bare 40-hex commit after prefix strip"
else
  fail "REQ-084 resolvability" "got '$stripped'"
fi

########################################
# REF_TAG cannot claim the canonical release tag
########################################

out=$(compose_tags false "" "" "" "v29.0")
if grep -qx "tag=tag-v29.0" <<<"$out"; then
  ok "unsuffixed tag build keeps the canonical ref tag"
else
  fail "canonical ref tag" "$out"
fi

out=$(compose_tags false "-base-pr40" "ecr/base:pr-40" "" "v29.0")
if grep -qx "tag=tag-v29.0-base-pr40" <<<"$out"; then
  ok "suffixed tag build cannot overwrite the release image"
else
  fail "ref tag suffixing" "$out"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
