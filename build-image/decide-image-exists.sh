#!/usr/bin/env bash
set -uo pipefail

decide_image_exists() {
  if [ "${SHORT_SHA_TAG_EXISTS:-}" == "yes" ]; then
    printf 'image_exists=true\n'
    return
  fi
  printf 'image_exists=false\n'
}

if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
  decide_image_exists
fi
