#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: build-apple-arm64.sh <aTrustInstaller_arm64.deb> [image-tag]

Builds the local Tunlet arm64 image with Apple's container CLI.
The upstream installer is copied into a temporary, git-ignored build input
directory and removed after the build finishes.
USAGE
}

fail() {
  echo "build-apple-arm64: $*" >&2
  exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || {
  usage >&2
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ATRUST_DEB="$1"
IMAGE_TAG="${2:-atrust-lite-runtime:local-arm64}"
LOCAL_DIR="${REPO_ROOT}/.local"
LOCAL_DEB="${LOCAL_DIR}/aTrustInstaller_arm64.deb"

[[ -f "${ATRUST_DEB}" ]] || fail "installer not found: ${ATRUST_DEB}"
command -v container >/dev/null 2>&1 || fail "Apple container CLI is not installed"

mkdir -p "${LOCAL_DIR}"
trap 'rm -f "${LOCAL_DEB}"' EXIT
cp -f "${ATRUST_DEB}" "${LOCAL_DEB}"

container build \
  --arch arm64 \
  --file "${SCRIPT_DIR}/Dockerfile.apple-arm64" \
  --tag "${IMAGE_TAG}" \
  "${REPO_ROOT}"

container image list | awk -v tag="${IMAGE_TAG}" 'NR == 1 || index($0, tag) == 1'
