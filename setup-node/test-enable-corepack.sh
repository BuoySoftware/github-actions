#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/enable-corepack.sh"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'NOT OK %s%s\n' "$1" "${2:+ - $2}"; }

BASH_BIN="$(command -v bash)"
CP_BIN="$(command -v cp)"

# Stubs record each call in $bin/calls. The stub npm installs a stub corepack,
# as a real global install would. PATH holds only the stub directory, so a
# corepack on the machine running the tests cannot leak in.
make_bin() {
  local bin
  bin="$(mktemp -d)"
  printf '#!%s\nprintf "corepack %%s\\n" "$*" >> %s/calls\n' \
    "$BASH_BIN" "$bin" > "$bin/corepack.stub"
  printf '#!%s\nprintf "npm %%s\\n" "$*" >> %s/calls\n[ -n "${NPM_FAILS:-}" ] && exit 1\n%s %s/corepack.stub %s/corepack\n' \
    "$BASH_BIN" "$bin" "$CP_BIN" "$bin" "$bin" > "$bin/npm"
  chmod +x "$bin/npm" "$bin/corepack.stub"
  printf '%s' "$bin"
}

# Prints the recorded calls, then the exit status.
run() {
  local bin=$1 status
  (PATH="$bin" COREPACK_VERSION=0.36.0 enable_corepack) > /dev/null 2>&1
  status=$?
  cat "$bin/calls" 2>/dev/null
  printf 'exit %s\n' "$status"
}

expect() {
  local desc=$1 want=$2 got=$3
  if [ "$got" == "$want" ]; then
    ok "$desc"
  else
    fail "$desc" "want '$want', got '$got'"
  fi
}

bin="$(make_bin)"
cp "$bin/corepack.stub" "$bin/corepack"
expect "bundled corepack is enabled without installing" \
  "$(printf 'corepack enable\nexit 0')" "$(run "$bin")"

bin="$(make_bin)"
expect "missing corepack is installed at the pinned version, then enabled" \
  "$(printf 'npm install -g corepack@0.36.0\ncorepack enable\nexit 0')" "$(run "$bin")"

bin="$(make_bin)"
expect "failed install stops before enabling" \
  "$(printf 'npm install -g corepack@0.36.0\nexit 1')" "$(NPM_FAILS=1 run "$bin")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
