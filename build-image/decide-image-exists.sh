#!/usr/bin/env bash
# Decides whether build-image should skip the docker build.
# Sourced by build-image/test-decide-image-exists.sh so the tests
# exercise the shipped logic rather than a copy of it.
#
# Inputs (environment):
#   SECURITY_PATCH       "true" forces a build (timestamped tags never collide)
#   SHORT_IMAGE_EXISTS   "yes" when the composed SHORT_SHA_TAG is already in
#                        the registry. That tag already includes tag_suffix,
#                        so a suffixed rebuild of the same commit is a no-op.
# Emits image_exists=true|false on stdout.

set -uo pipefail

decide_image_exists() {
  if [ "${SECURITY_PATCH:-}" == "true" ]; then
    printf 'image_exists=false\n'
    return
  fi
  if [ "${SHORT_IMAGE_EXISTS:-}" == "yes" ]; then
    printf 'image_exists=true\n'
    return
  fi
  printf 'image_exists=false\n'
}

if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
  decide_image_exists
fi
