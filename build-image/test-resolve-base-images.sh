#!/usr/bin/env bash
# Exercises build-image/resolve-base-images.sh with the registry lookup
# replaced by a fixed table, so no network or credentials are needed.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/resolve-base-images.sh"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'NOT OK %s%s\n' "$1" "${2:+ - $2}"; }

FAKE_BASE_DIGEST=sha256:1111111111111111111111111111111111111111111111111111111111111111
FAKE_BUILDER_DIGEST=sha256:2222222222222222222222222222222222222222222222222222222222222222
CANDIDATE_DIGEST=sha256:3333333333333333333333333333333333333333333333333333333333333333

fake_digest() {
  case $1 in
    registry.example/base:latest)    printf '%s' "$FAKE_BASE_DIGEST" ;;
    registry.example/builder:latest) printf '%s' "$FAKE_BUILDER_DIGEST" ;;
    registry.example/base:candidate) printf '%s' "$CANDIDATE_DIGEST" ;;
    *) return 1 ;;
  esac
}
export RESOLVE_DIGEST=fake_digest

TMP="$(mktemp -d)"
trap 'test -d "$TMP" && command ''rm'' -r -- "$TMP"' EXIT

# The $VAR text is literal Dockerfile content, not shell expansion.
# shellcheck disable=SC2016
printf 'ARG BUILDER_IMAGE=registry.example/builder:latest\nARG BASE_IMAGE=registry.example/base:latest\nFROM $BUILDER_IMAGE AS builder\nFROM $BASE_IMAGE\n' > "$TMP/both"
# shellcheck disable=SC2016
printf 'ARG BASE_IMAGE="registry.example/base:latest"\nFROM $BASE_IMAGE\n' > "$TMP/quoted"
printf 'FROM registry.example/base:latest\n' > "$TMP/none"
# shellcheck disable=SC2016
printf 'FROM scratch\nARG BASE_IMAGE=registry.example/base:latest\n' > "$TMP/after-from"
# shellcheck disable=SC2016
printf 'ARG REGISTRY=registry.example\nARG BASE_IMAGE=${REGISTRY}/base:latest\nFROM $BASE_IMAGE\n' > "$TMP/variable"
# shellcheck disable=SC2016
printf 'ARG BASE_IMAGE=registry.example/missing:latest\nFROM $BASE_IMAGE\n' > "$TMP/missing"
# shellcheck disable=SC2016
printf 'ARG BUILDER_IMAGE=registry.example/builder:latest\nARG BASE_IMAGE=registry.example/base\nFROM $BUILDER_IMAGE AS builder\nFROM ${BASE_IMAGE}:latest\n' > "$TMP/longer-tag"
# shellcheck disable=SC2016
printf 'ARG BASE_IMAGE=registry.example/base\nFROM $BASE_IMAGE-slim\n' > "$TMP/longer-suffix"
# shellcheck disable=SC2016
printf 'ARG BASE_IMAGE=registry.example/base:latest\nARG BASE_IMAGE_TAG=1\nFROM --platform=$BUILDPLATFORM ${BASE_IMAGE} AS app\nRUN echo $BASE_IMAGE_TAG\n' > "$TMP/platform"
# shellcheck disable=SC2016
printf 'ARG BASE_IMAGE=registry.example/base:latest\nFROM registry.example/base:latest\n' > "$TMP/unused"

# run <dockerfile> <base_input> <builder_input> [build_args]
run() {
  DOCKERFILE="$1" BASE_IMAGE="$2" BUILDER_IMAGE="$3" BUILD_ARGS="${4:-}" \
    resolve_base_images 2>"$TMP/stderr"
}

expect_field() {
  local desc=$1 field=$2 want=$3 out=$4 got
  got="$(printf '%s\n' "$out" | sed -n "s/^${field}=//p")"
  if [ "$got" == "$want" ]; then
    ok "$desc"
  else
    fail "$desc" "$field: want '$want', got '$got'"
  fi
}

expect_warning() {
  local desc=$1 needle=$2
  if grep -q "::warning::.*$needle" "$TMP/stderr"; then
    ok "$desc"
  else
    fail "$desc" "no warning mentioning '$needle': $(cat "$TMP/stderr")"
  fi
}

out="$(run "$TMP/both" "" "")"
expect_field "default base name comes from the ARG" base_name registry.example/base:latest "$out"
expect_field "default base digest is resolved" base_digest "$FAKE_BASE_DIGEST" "$out"
expect_field "default builder name comes from the ARG" builder_name registry.example/builder:latest "$out"
expect_field "default builder digest is resolved" builder_digest "$FAKE_BUILDER_DIGEST" "$out"

out="$(run "$TMP/both" registry.example/base:candidate "")"
expect_field "base input wins over the ARG default" base_name registry.example/base:candidate "$out"
expect_field "base input digest is resolved" base_digest "$CANDIDATE_DIGEST" "$out"
expect_field "builder keeps its default when only base is overridden" builder_digest "$FAKE_BUILDER_DIGEST" "$out"

out="$(run "$TMP/both" "registry.example/base:candidate@$FAKE_BASE_DIGEST" "")"
expect_field "a pinned input keeps its digest without a lookup" base_digest "$FAKE_BASE_DIGEST" "$out"
expect_field "a pinned input's name drops the digest" base_name registry.example/base:candidate "$out"

out="$(run "$TMP/quoted" "" "")"
expect_field "quotes around the ARG default are removed" base_name registry.example/base:latest "$out"

out="$(run "$TMP/none" "" "")"
expect_field "no ARG and no input: base is left empty" base_name "" "$out"
expect_field "no ARG and no input: builder is left empty" builder_digest "" "$out"

out="$(run "$TMP/after-from" "" "")"
expect_field "an ARG after the first FROM is not a base" base_name "" "$out"

out="$(run "$TMP/variable" "" "")"
expect_field "a default built from another ARG is left empty" base_digest "" "$out"
expect_warning "a default built from another ARG warns" "cannot expand"

out="$(run "$TMP/missing" "" "")"
expect_field "an unreadable digest leaves the pair empty" base_name "" "$out"
expect_warning "an unreadable digest warns" "Could not read the digest"

out="$(run "$TMP/both" "" "" "--build-arg TOKEN=x --build-arg BASE_IMAGE=registry.example/base:candidate")"
expect_field "BASE_IMAGE set in build_args leaves the base empty" base_name "" "$out"
expect_warning "BASE_IMAGE set in build_args warns" "build_args sets BASE_IMAGE"
expect_field "BASE_IMAGE set in build_args still resolves the builder" builder_digest "$FAKE_BUILDER_DIGEST" "$out"

out="$(run "$TMP/both" "" "" "--build-arg=BUILDER_IMAGE=registry.example/builder:candidate")"
expect_field "--build-arg=BUILDER_IMAGE= leaves the builder empty" builder_name "" "$out"
expect_field "--build-arg=BUILDER_IMAGE= still resolves the base" base_digest "$FAKE_BASE_DIGEST" "$out"

out="$(run "$TMP/both" "" "" "--build-arg TOKEN=x")"
expect_field "other build_args do not stop the base resolving" base_digest "$FAKE_BASE_DIGEST" "$out"

for file_flag in "-f docker/prod.Dockerfile" "--file docker/prod.Dockerfile" "--file=docker/prod.Dockerfile" "-fdocker/prod.Dockerfile"; do
  out="$(run "$TMP/both" "" "" "--build-arg TOKEN=x $file_flag")"
  expect_field "build_args '$file_flag' leaves the base empty" base_name "" "$out"
  expect_field "build_args '$file_flag' leaves the builder empty" builder_name "" "$out"
  expect_warning "build_args '$file_flag' warns" "build_args selects the Dockerfile"
done

out="$(run "$TMP/longer-tag" "" "")"
expect_field "FROM \${BASE_IMAGE}:tag leaves the base empty" base_name "" "$out"
expect_warning "FROM \${BASE_IMAGE}:tag warns" "whole image reference"
expect_field "FROM \${BASE_IMAGE}:tag still resolves the builder" builder_digest "$FAKE_BUILDER_DIGEST" "$out"

out="$(run "$TMP/longer-suffix" "" "")"
expect_field "FROM \$BASE_IMAGE-slim leaves the base empty" base_name "" "$out"

out="$(run "$TMP/platform" "" "")"
expect_field "FROM --platform=... \${BASE_IMAGE} AS app resolves" base_digest "$FAKE_BASE_DIGEST" "$out"

out="$(run "$TMP/unused" "" "")"
expect_field "an ARG no FROM uses leaves the base empty" base_name "" "$out"

expect_args() {
  local desc=$1 want=$2 got
  got="$(base_build_args)"
  if [ "$got" == "$want" ]; then
    ok "$desc"
  else
    fail "$desc" "want '$want', got '$got'"
  fi
}

BASE_NAME=registry.example/base:latest BASE_DIGEST=$FAKE_BASE_DIGEST \
BUILDER_NAME=registry.example/builder:latest BUILDER_DIGEST=$FAKE_BUILDER_DIGEST \
BASE_IMAGE="" BUILDER_IMAGE="" \
  expect_args "resolved defaults are pinned by build context, not by ARG, and labelled" \
  " --build-context registry.example/base:latest=docker-image://registry.example/base:latest@$FAKE_BASE_DIGEST --label org.opencontainers.image.base.name=registry.example/base:latest --label org.opencontainers.image.base.digest=$FAKE_BASE_DIGEST --build-context registry.example/builder:latest=docker-image://registry.example/builder:latest@$FAKE_BUILDER_DIGEST --label com.buoysoftware.image.builder.name=registry.example/builder:latest --label com.buoysoftware.image.builder.digest=$FAKE_BUILDER_DIGEST"

BASE_NAME=registry.example/base:candidate BASE_DIGEST=$CANDIDATE_DIGEST \
BUILDER_NAME="" BUILDER_DIGEST="" \
BASE_IMAGE=registry.example/base:candidate BUILDER_IMAGE="" \
  expect_args "a resolved override passes the ARG as written and pins it by build context" \
  " --build-arg BASE_IMAGE=registry.example/base:candidate --build-context registry.example/base:candidate=docker-image://registry.example/base:candidate@$CANDIDATE_DIGEST --label org.opencontainers.image.base.name=registry.example/base:candidate --label org.opencontainers.image.base.digest=$CANDIDATE_DIGEST"

BASE_NAME="" BASE_DIGEST="" BUILDER_NAME="" BUILDER_DIGEST="" \
BASE_IMAGE=registry.example/base:candidate BUILDER_IMAGE="" \
  expect_args "an unresolved override still reaches the build, unlabelled" \
  " --build-arg BASE_IMAGE=registry.example/base:candidate"

BASE_NAME="" BASE_DIGEST="" BUILDER_NAME="" BUILDER_DIGEST="" \
BASE_IMAGE="" BUILDER_IMAGE="" \
  expect_args "nothing resolved and no override adds no arguments" ""

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
