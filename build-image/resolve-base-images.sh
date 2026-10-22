#!/usr/bin/env bash
# Resolves the image each of BASE_IMAGE and BUILDER_IMAGE will build from,
# and the digest it points at right now. Sourced by
# build-image/test-resolve-base-images.sh.
#
# Inputs (environment): BASE_IMAGE BUILDER_IMAGE BUILD_ARGS DOCKERFILE
# Emits KEY=value lines on stdout: base_ref, base_name, base_digest,
# builder_ref, builder_name, builder_digest. A pair stays empty when the action cannot tell which image
# the build will use or cannot read its digest; a ::warning:: on stderr says
# which.

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
      value = $0
    }
    END { if (value != "") print value }
  ' "$file"
}

# Prints whole, partial, or nothing when no FROM mentions the ARG.
from_usage() {
  local name=$1 file=$2
  awk -v arg="$name" '
    toupper($1) == "FROM" {
      image = ""
      for (i = 2; i <= NF; i++) if ($i !~ /^--/) { image = $i; break }
      if (image == "$" arg || image == "${" arg "}") { whole = 1; next }
      for (i = 2; i <= NF; i++)
        if ($i ~ ("\\$(" arg "([^A-Za-z0-9_]|$)|\\{" arg "[}:])")) partial = 1
    }
    END { if (partial) print "partial"; else if (whole) print "whole" }
  ' "$file"
}

final_from_uses() {
  awk -v arg="$1" '
    toupper($1) == "FROM" {
      image = ""
      for (i = 2; i <= NF; i++) if ($i !~ /^--/) { image = $i; break }
    }
    END { exit !(image == "$" arg || image == "${" arg "}") }
  ' "$2"
}

syntax_directive() {
  awk -v bom="$(printf '\357\273\277')" '
    NR == 1 { sub("^" bom, "") }
    /^[[:space:]]*$/ { next }
    !/^#/ { exit }
    tolower($0) ~ /^#[[:space:]]*syntax[[:space:]]*=/ {
      sub(/^#[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit
    }
  ' "$1"
}

# Named build contexts need Dockerfile frontend 1.4 or later; an older
# pinned frontend fails the whole build.
frontend_supports_contexts() {
  local syntax directive major minor
  syntax="$(syntax_directive "$1")"
  directive=$syntax
  syntax=${syntax%%@*}
  [ -z "$syntax" ] && return 0
  case $syntax in
    docker/dockerfile | docker.io/docker/dockerfile) [ "$syntax" = "$directive" ]; return ;;
    docker/dockerfile:* | docker.io/docker/dockerfile:*) ;;
    *) return 1 ;;
  esac
  syntax=${syntax##*:}
  case $syntax in latest | labs) return 0 ;; esac
  syntax=${syntax%%-*}
  major=${syntax%%.*}
  minor=${syntax#"$major"}
  minor=${minor#.}
  minor=${minor%%.*}
  [[ "$major" =~ ^[0-9]+$ ]] || return 1
  [ "$major" -gt 1 ] && return 0
  [ "$major" -eq 1 ] || return 1
  [ -z "$minor" ] && return 0
  [[ "$minor" =~ ^[0-9]+$ ]] && [ "$minor" -ge 4 ]
}

builder_supports_contexts() {
  [ "${DOCKER_BUILDKIT:-}" != 0 ] &&
    docker build --help 2>/dev/null | grep -q -- '--build-context'
}

build_args_select_target() {
  local word words
  [[ "$1" == *[![:space:]]* ]] || return 1
  read -r -d "" -a words <<<"$1" || true
  for word in "${words[@]}"; do
    case $word in --target | --target=*) return 0 ;; esac
  done
  return 1
}

# BUILD_ARGS reaches docker build word-split, so it is read as words here.
build_args_select_file() {
  local word words
  [[ "$1" == *[![:space:]]* ]] || return 1
  read -r -d "" -a words <<<"$1" || true
  for word in "${words[@]}"; do
    case $word in
      -f | -f?* | --file | --file=*) return 0 ;;
    esac
  done
  return 1
}

build_args_set() {
  local arg=$1 word words
  [[ "$2" == *[![:space:]]* ]] || return 1
  read -r -d "" -a words <<<"$2" || true
  for word in "${words[@]}"; do
    case $word in
      "$arg" | "$arg="* | "--build-arg=$arg" | "--build-arg=$arg="*) return 0 ;;
    esac
  done
  return 1
}

resolve_digest() {
  docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}' 2>/dev/null
}

empty_pair() {
  printf '%s_ref=\n%s_name=\n%s_digest=\n' "$1" "$1" "$1"
}

pins_anything() {
  local arg=$1 input=$2 dockerfile=$3 build_args=$4
  [ -n "$input" ] && return 0
  build_args_set "$arg" "$build_args" && return 0
  [ -n "$(arg_default "$arg" "$dockerfile")" ] &&
    [ -n "$(from_usage "$arg" "$dockerfile")" ]
}

context_problem() {
  local dockerfile=$1 build_args=$2
  if ! builder_supports_contexts; then
    echo "The Docker builder does not support named build contexts"
  elif build_args_set BUILDKIT_SYNTAX "$build_args" || ! frontend_supports_contexts "$dockerfile"; then
    echo "The frontend selected by build_args or ${dockerfile} is unknown or older than 1.4"
  fi
}

resolve_one() {
  local key=$1 arg=$2 input=$3 dockerfile=$4 build_args=$5 problem=$6
  local ref name digest usage

  if build_args_set "$arg" "$build_args"; then
    echo "::warning::build_args sets ${arg}, so the build is not pinned to a digest and the image carries no ${key} labels. Pass it as the ${key}_image input instead." >&2
    empty_pair "$key"
    return
  fi

  ref=${input:-$(arg_default "$arg" "$dockerfile")}
  if [ -z "$ref" ]; then
    empty_pair "$key"
    return
  fi
  if [[ "$ref" == *'$'* ]]; then
    echo "::warning::${arg} resolves to '${ref}', which this action cannot expand, so the build is not pinned to a digest." >&2
    empty_pair "$key"
    return
  fi

  usage="$(from_usage "$arg" "$dockerfile")"
  if [ "$usage" != whole ]; then
    echo "::warning::No FROM in ${dockerfile} uses \$${arg} as its whole image reference, so the build is not pinned to a digest and the image carries no ${key} labels." >&2
    empty_pair "$key"
    return
  fi
  if [ "$key" = base ] && ! final_from_uses "$arg" "$dockerfile"; then
    echo "::warning::The final FROM does not directly use \$${arg}, so the build carries no base pin or labels." >&2
    empty_pair "$key"
    return
  fi

  name=${ref%%@*}
  if [[ "$ref" == *@sha256:* ]]; then
    digest=${ref#*@}
  elif [ -n "$problem" ]; then
    echo "::warning::${problem}, so ${ref} is not pinned to a digest and the image carries no ${key} labels." >&2
    empty_pair "$key"
    return
  else
    digest="$(resolve_digest "$ref")"
  fi

  if [[ "$digest" != sha256:* ]]; then
    echo "::warning::Could not read the digest of ${ref}, so the build is not pinned to a digest and the image carries no ${key} labels." >&2
    empty_pair "$key"
    return
  fi

  printf '%s_ref=%s\n%s_name=%s\n%s_digest=%s\n' "$key" "$ref" "$key" "$name" "$key" "$digest"
}

resolve_base_images() {
  local dockerfile=${DOCKERFILE:-Dockerfile} build_args=${BUILD_ARGS:-} problem
  if [ ! -f "$dockerfile" ] ||
    ! { pins_anything BASE_IMAGE "${BASE_IMAGE:-}" "$dockerfile" "$build_args" ||
      pins_anything BUILDER_IMAGE "${BUILDER_IMAGE:-}" "$dockerfile" "$build_args"; }; then
    empty_pair base
    empty_pair builder
    return
  fi
  if build_args_select_file "$build_args"; then
    echo "::warning::build_args selects the Dockerfile, so the build is not pinned to a digest and the image carries no base or builder labels." >&2
    empty_pair base
    empty_pair builder
    return
  fi
  if build_args_select_target "$build_args"; then
    echo "::warning::build_args selects a target stage, so the build is not pinned to a digest and the image carries no base or builder labels." >&2
    empty_pair base
    empty_pair builder
    return
  fi
  problem="$(context_problem "$dockerfile" "$build_args")"
  resolve_one base BASE_IMAGE "${BASE_IMAGE:-}" "$dockerfile" "$build_args" "$problem"
  resolve_one builder BUILDER_IMAGE "${BUILDER_IMAGE:-}" "$dockerfile" "$build_args" "$problem"
}

# The pin goes through a named build context, not the ARG, so every use of
# the ARG inside the Dockerfile still sees the reference as written.
pin_args() {
  local arg=$1 ref=$2 name=$3 digest=$4 input=$5 label_prefix=$6
  if [ -n "$input" ]; then
    printf ' --build-arg %s=%s' "$arg" "$input"
  fi
  if [ -n "$digest" ]; then
    if [[ -n "$ref" && "$ref" != *@* ]]; then
      printf ' --build-context %s=docker-image://%s@%s' "$ref" "$ref" "$digest"
    fi
    printf ' --label %s.name=%s --label %s.digest=%s' "$label_prefix" "$name" "$label_prefix" "$digest"
  fi
}

# Inputs (environment): BASE_REF BASE_NAME BASE_DIGEST BASE_IMAGE BUILDER_REF
#   BUILDER_NAME BUILDER_DIGEST BUILDER_IMAGE. Emits the docker build arguments.
base_build_args() {
  pin_args BASE_IMAGE "${BASE_REF:-}" "${BASE_NAME:-}" "${BASE_DIGEST:-}" "${BASE_IMAGE:-}" org.opencontainers.image.base
  pin_args BUILDER_IMAGE "${BUILDER_REF:-}" "${BUILDER_NAME:-}" "${BUILDER_DIGEST:-}" "${BUILDER_IMAGE:-}" com.buoysoftware.image.builder
}

if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
  case ${1:-} in
    build-args) base_build_args ;;
    *) resolve_base_images ;;
  esac
fi
