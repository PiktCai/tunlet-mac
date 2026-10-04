#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: build-image.sh <aTrustInstaller_arm64.deb> [image-tag]

Builds the local Tunlet arm64 image with Apple's container CLI.
The upstream installer and build sources are copied into a temporary build
context and removed after the build finishes.
USAGE
}

fail() {
  echo "build-image: $*" >&2
  exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || {
  usage >&2
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATRUST_DEB="$1"
IMAGE_TAG="${2:-tunlet-runtime:local-arm64}"
TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_ROOT="${TEMP_ROOT%/}"
BUILD_CONTEXT=""

[[ -f "${ATRUST_DEB}" ]] || fail "installer not found: ${ATRUST_DEB}"
command -v container >/dev/null 2>&1 || fail "Apple container CLI is not installed"

cleanup() {
  if [[ -n "${BUILD_CONTEXT}" && \
        "${BUILD_CONTEXT}" == "${TEMP_ROOT}/tunlet-build."* ]]; then
    rm -rf -- "${BUILD_CONTEXT}"
  fi
}
trap cleanup EXIT INT TERM

BUILD_CONTEXT="$(mktemp -d "${TEMP_ROOT}/tunlet-build.XXXXXX")"
mkdir -p "${BUILD_CONTEXT}/.local" "${BUILD_CONTEXT}/scripts"
cp -f "${ATRUST_DEB}" "${BUILD_CONTEXT}/.local/aTrustInstaller_arm64.deb"
cp -f "${SCRIPT_DIR}/Containerfile" "${BUILD_CONTEXT}/Containerfile"
for source_file in init-runtime.sh build-supervisor.sh supervisor.rs fake-getlogin.c; do
  cp -f "${SCRIPT_DIR}/${source_file}" "${BUILD_CONTEXT}/scripts/${source_file}"
done

container build \
  --arch arm64 \
  --file "${BUILD_CONTEXT}/Containerfile" \
  --tag "${IMAGE_TAG}" \
  "${BUILD_CONTEXT}"

container image list | awk -v tag="${IMAGE_TAG}" 'NR == 1 || index($0, tag) == 1'
