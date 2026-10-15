#!/usr/bin/env bash
# Resolves the image each of BASE_IMAGE and BUILDER_IMAGE will build from,
# and the digest it points at right now. Sourced by
# build-image/test-resolve-base-images.sh.
#
# Inputs (environment): BASE_IMAGE BUILDER_IMAGE DOCKERFILE
# Emits KEY=value lines on stdout: base_name, base_digest, builder_name,
# builder_digest. A pair stays empty when the image cannot be named or its
# digest cannot be read; a ::warning:: on stderr says which.

set -uo pipefail

arg_default() {
  local name=$1 file=$2
  awk -v arg="$name" -v quotes="[\"']" '
    /^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]/ { exit }
    $0 ~ "^[[:space:]]*[Aa][Rr][Gg][[:space:]]+" arg "=" {
      sub("^[[:space:]]*[Aa][Rr][Gg][[:space:]]+" arg "=", "")
      sub("[[:space:]]+$", "")
      sub("^" quotes, "")
      sub(quotes "$", "")
      print
      exit
    }
  ' "$file"
}

resolve_digest() {
  docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}' 2>/dev/null
}

resolve_one() {
  local key=$1 arg=$2 input=$3 dockerfile=$4
  local ref name digest
  ref=${input:-$(arg_default "$arg" "$dockerfile")}

  if [ -z "$ref" ]; then
    printf '%s_name=\n%s_digest=\n' "$key" "$key"
    return
  fi
  if [[ "$ref" == *'$'* ]]; then
    echo "::warning::${arg} resolves to '${ref}', which this action cannot expand, so the build is not pinned to a digest." >&2
    printf '%s_name=\n%s_digest=\n' "$key" "$key"
    return
  fi

  name=${ref%%@*}
  if [[ "$ref" == *@sha256:* ]]; then
    digest=${ref#*@}
  else
    digest="$(${RESOLVE_DIGEST:-resolve_digest} "$ref")"
  fi

  if [[ "$digest" != sha256:* ]]; then
    echo "::warning::Could not read the digest of ${ref}, so the build is not pinned to a digest and the image carries no ${key} labels." >&2
    printf '%s_name=\n%s_digest=\n' "$key" "$key"
    return
  fi

  printf '%s_name=%s\n%s_digest=%s\n' "$key" "$name" "$key" "$digest"
}

resolve_base_images() {
  local dockerfile=${DOCKERFILE:-Dockerfile}
  resolve_one base BASE_IMAGE "${BASE_IMAGE:-}" "$dockerfile"
  resolve_one builder BUILDER_IMAGE "${BUILDER_IMAGE:-}" "$dockerfile"
}

if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
  resolve_base_images
fi
