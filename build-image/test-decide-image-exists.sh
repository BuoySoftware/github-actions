#!/usr/bin/env bash
# Exercises build-image/decide-image-exists.sh -- the same file action.yml
# runs, so these assertions hold against what ships rather than a copy.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/decide-image-exists.sh"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'NOT OK %s%s\n' "$1" "${2:+ - $2}"; }

run() {
  SECURITY_PATCH="$1" SHORT_IMAGE_EXISTS="$2" decide_image_exists
}

expect() {
  local desc=$1 want=$2; shift 2
  local got
  got="$("$@")"
  if [ "$got" == "$want" ]; then
    ok "$desc"
  else
    fail "$desc" "want '$want', got '$got'"
  fi
}

# The existence key is the composed SHORT_SHA_TAG. tag_suffix is already
# baked into that tag by compose-tags.sh, so this decision must not care
# whether a suffix was set.
expect "unsuffixed miss builds" "image_exists=false" \
  run false no
expect "unsuffixed hit skips" "image_exists=true" \
  run false yes
expect "composed suffixed tag present skips" "image_exists=true" \
  run false yes
expect "composed suffixed tag absent builds" "image_exists=false" \
  run false no

# A security_patch tag includes a timestamp, so a skip would never match
# the tag about to be pushed. Always build.
expect "security_patch builds even when a tag exists" "image_exists=false" \
  run true yes
expect "security_patch builds when no tag exists" "image_exists=false" \
  run true no

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
