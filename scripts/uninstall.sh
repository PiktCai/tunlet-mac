#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${ROOT_DIR}/.local"
CONTAINER_NAME="tunlet"
IMAGE_NAME="tunlet-runtime:local-arm64"
CREDENTIAL_HELPER="${STATE_DIR}/bin/tunlet-credentials"
CREDENTIAL_SERVICE="io.github.piktcai.tunlet.credentials"
DRY_RUN=0
ASSUME_YES=0
INCLUDE_BUILDER=0

usage() {
  cat <<'USAGE'
Usage: ./scripts/uninstall.sh [options]

Remove the container, image, local state, and temporary files created by Tunlet.

Options:
  --dry-run          Show what would be removed
  --yes              Skip confirmation
  --include-builder  Also remove the shared Apple Container builder
  -h, --help         Show this help
USAGE
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    --include-builder) INCLUDE_BUILDER=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

[[ "$(uname -s)" == "Darwin" ]] || {
  echo "This script requires macOS." >&2
  exit 1
}

echo "The following items will be removed:"
echo "  - Container: ${CONTAINER_NAME}"
echo "  - Image: ${IMAGE_NAME}"
echo "  - Local state: ${STATE_DIR}"
echo "  - Passwords saved by Tunlet in macOS Keychain"
echo "  - Tunlet temporary files"
if [[ "${INCLUDE_BUILDER}" == 1 ]]; then
  echo "  - Shared Apple Container builder cache"
  echo
  echo "Warning: other projects may use the shared builder. It will need to be recreated."
fi
echo
echo "Apple Container and unrelated containers or images will not be removed."

if [[ "${DRY_RUN}" == 1 ]]; then
  echo
  echo "Dry run only. Nothing was removed."
  exit 0
fi

if [[ "${ASSUME_YES}" != 1 ]]; then
  read -r -p "Type DELETE to continue: " confirmation
  [[ "${confirmation}" == "DELETE" ]] || {
    echo "Cancelled."
    exit 0
  }
fi

cleanup_temp_root() {
  local temp_root="$1"
  local candidate

  [[ -d "${temp_root}" ]] || return 0
  while IFS= read -r -d '' candidate; do
    case "${candidate}" in
      "${temp_root}"/tunlet.*|"${temp_root}"/tunlet-setup.*)
        rm -rf -- "${candidate}"
        ;;
    esac
  done < <(
    find "${temp_root}" -mindepth 1 -maxdepth 1 -type d \
      \( -name 'tunlet.*' -o -name 'tunlet-setup.*' \) \
      -print0 2>/dev/null
  )
}

if command -v container >/dev/null 2>&1; then
  container_ready=1
  if ! container system status >/dev/null 2>&1; then
    if ! container system start >/dev/null; then
      container_ready=0
      echo "Apple Container could not start. Skipping container and image cleanup." >&2
    fi
  fi

  if [[ "${container_ready}" == 1 ]]; then
    container stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    container delete --force "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    container image delete --force "${IMAGE_NAME}" >/dev/null 2>&1 || true

    if [[ "${INCLUDE_BUILDER}" == 1 ]]; then
      container builder delete --force >/dev/null 2>&1 || true
    fi

    if [[ "$(container list --format json 2>/dev/null || true)" == "[]" ]]; then
      container system stop >/dev/null 2>&1 || true
    fi
  fi
else
  echo "Apple Container was not found. Skipping container and image cleanup."
fi

if [[ -x "${CREDENTIAL_HELPER}" ]]; then
  if ! "${CREDENTIAL_HELPER}" delete-all; then
    echo "Warning: Tunlet could not remove its saved Keychain passwords." >&2
  fi
elif command -v security >/dev/null 2>&1; then
  while security delete-generic-password \
    -s "${CREDENTIAL_SERVICE}" >/dev/null 2>&1; do
    :
  done
fi

if [[ "${STATE_DIR}" == "${ROOT_DIR}/.local" ]]; then
  rm -rf -- "${STATE_DIR}"
fi

temp_root="${TMPDIR:-/tmp}"
temp_root="${temp_root%/}"
cleanup_temp_root "${temp_root}"
if [[ "${temp_root}" != "/tmp" ]]; then
  cleanup_temp_root "/tmp"
fi

echo "Cleanup complete. The source tree and Apple Container remain installed."
