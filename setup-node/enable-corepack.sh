#!/usr/bin/env bash
set -uo pipefail

# Node 25 and later no longer bundle corepack, so install it before enabling.
enable_corepack() {
  if ! command -v corepack > /dev/null 2>&1; then
    npm install -g "corepack@${COREPACK_VERSION:?}" || return
  fi
  corepack enable
}

if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
  enable_corepack
fi
