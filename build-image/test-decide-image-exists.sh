#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/decide-image-exists.sh"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'NOT OK %s%s\n' "$1" "${2:+ - $2}"; }

run() {
  SHORT_SHA_TAG_EXISTS="$1" decide_image_exists
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

expect "composed tag absent builds" "image_exists=false" run no
expect "composed tag present skips" "image_exists=true" run yes
expect "uninspected tag builds" "image_exists=false" run ""

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
