#!/usr/bin/env bash
# Validates the base-override inputs and composes the image tags for
# build-image. Sourced by build-image/test-build-image.sh, so the tests
# exercise the shipped logic rather than a copy of it.
#
# Inputs (environment): BASE_IMAGE BUILDER_IMAGE RELEASE_CANDIDATE_TAG
#   SECURITY_PATCH TAG_SUFFIX REF_TAG GIT_SHA GIT_SHORT_SHA DOCKERFILE
# Emits KEY=value lines on stdout: sha, short, long, tag.
# Exits 1 with a ::error:: message when an input combination is rejected.

set -uo pipefail

# An ARG only reaches a FROM line when it is declared before the first FROM.
# Anything after that is stage-local and silently ignored by FROM, which is
# the failure this check exists to catch -- so match position, not presence.
declares_arg_before_first_from() {
  local name=$1 file=$2
  awk -v arg="$name" '
    /^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]/ { exit }
    $0 ~ "^[[:space:]]*[Aa][Rr][Gg][[:space:]]+" arg "([[:space:]]|=|$)" { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

compose_tags() {
  local base_image=${BASE_IMAGE:-}
  local builder_image=${BUILDER_IMAGE:-}
  local release_candidate_tag=${RELEASE_CANDIDATE_TAG:-}
  local security_patch=${SECURITY_PATCH:-}
  local tag_suffix=${TAG_SUFFIX:-}
  local ref_tag=${REF_TAG:-}
  local dockerfile=${DOCKERFILE:-Dockerfile}

  if [ -n "$base_image" ] || [ -n "$builder_image" ]; then
    if [ -z "$tag_suffix" ]; then
      echo "::error::base_image/builder_image require tag_suffix. Without it this build would reuse the tag of a default-base build of the same commit, and skip-if-exists may skip the build entirely." >&2
      return 1
    fi
    # A release-candidate finalization retags an existing image; it never
    # builds. Combining the two would tag that image as if it carried the
    # overridden base.
    if [ -n "$release_candidate_tag" ]; then
      echo "::error::base_image/builder_image cannot be combined with release_candidate_tag: that path retags an existing image instead of building one." >&2
      return 1
    fi
    # Each input is checked against its own ARG. base and base-builder come
    # from separate repositories and their ARGs land in the app repos as
    # separate changes, so one declared and the other not is an expected
    # intermediate state.
    local input arg
    for input in base_image builder_image; do
      case $input in
        base_image)    [ -n "$base_image" ]    || continue; arg=BASE_IMAGE ;;
        builder_image) [ -n "$builder_image" ] || continue; arg=BUILDER_IMAGE ;;
      esac
      if ! declares_arg_before_first_from "$arg" "$dockerfile"; then
        echo "::error::${input} was passed but ${dockerfile} declares no ARG ${arg} before its first FROM, so the override would be silently ignored." >&2
        return 1
      fi
    done
  fi

  # Keeps the sha- prefix: BUOY_SLUG_COMMIT is consumed by the REQ-084
  # labeling lookup, which strips exactly that prefix. Only the build
  # suffixes are excluded, so the commit stays resolvable.
  local sha short long tag
  sha="sha-${GIT_SHA}"
  short="sha-${GIT_SHORT_SHA}"
  long="${sha}"
  tag="$ref_tag"

  if [ "$security_patch" == "true" ]; then
    local date_suffix="security-patch-${SECURITY_PATCH_TIMESTAMP:-$(date +%Y%m%d%H%M%S)}"
    short="${short}-${date_suffix}"
    long="${long}-${date_suffix}"
  fi

  if [ -n "$tag_suffix" ]; then
    short="${short}${tag_suffix}"
    long="${long}${tag_suffix}"
  fi

  # An overridden-base build must not claim the canonical release tag.
  if [ -n "$tag" ] && [ -n "$tag_suffix" ]; then
    tag="${tag}${tag_suffix}"
  fi

  printf 'sha=%s\nshort=%s\nlong=%s\ntag=%s\n' "$sha" "$short" "$long" "$tag"
}

# Only run when executed; sourcing gets the functions alone.
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
  compose_tags
fi
