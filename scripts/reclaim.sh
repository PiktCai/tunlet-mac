#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${TUNLET_STATE_DIR:-${ROOT_DIR}/.local}"
if [[ -n "${TUNLET_INSTALL_ROOT:-}" ]]; then
  RESTORE_COMMAND="tunlet install"
else
  RESTORE_COMMAND="./tunlet setup"
fi
CONTAINER_NAME="tunlet"
IMAGE_NAME="tunlet-runtime:local-arm64"
DRY_RUN=0
ASSUME_YES=0

usage() {
  cat <<'USAGE'
Usage: tunlet reclaim [options]

Remove the Tunlet runtime image and transient data while preserving the
installed command, server, username, and Keychain credentials.

Options:
  --dry-run   Show what would be removed
  --yes       Skip confirmation
  -h, --help  Show this help
USAGE
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
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

echo "The following Tunlet runtime data will be removed:"
echo "  - Container: ${CONTAINER_NAME}"
echo "  - Image: ${IMAGE_NAME}"
echo "  - Session token and Tunlet temporary files"
echo
echo "The command, saved server and username, and Keychain passwords will remain."

if [[ "${DRY_RUN}" == 1 ]]; then
  echo
  echo "Dry run only. Nothing was removed."
  exit 0
fi

if [[ "${ASSUME_YES}" != 1 ]]; then
  read -r -p "Type RECLAIM to continue: " confirmation
  [[ "${confirmation}" == "RECLAIM" ]] || {
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
      "${temp_root}"/tunlet.*|"${temp_root}"/tunlet-setup.*|\
      "${temp_root}"/tunlet-build.*|"${temp_root}"/tunlet-swift.*|\
      "${temp_root}"/tunlet-bootstrap.*)
        rm -rf -- "${candidate}"
        ;;
    esac
  done < <(
    find "${temp_root}" -mindepth 1 -maxdepth 1 -type d \
      \( -name 'tunlet.*' -o -name 'tunlet-setup.*' \
         -o -name 'tunlet-build.*' -o -name 'tunlet-swift.*' \
         -o -name 'tunlet-bootstrap.*' \) -print0 2>/dev/null
  )
}

if command -v container >/dev/null 2>&1; then
  container_ready=1
  if ! container system status >/dev/null 2>&1; then
    if ! container system start >/dev/null; then
      container_ready=0
      echo "Apple Container could not start. Skipping runtime cleanup." >&2
    fi
  fi

  if [[ "${container_ready}" == 1 ]]; then
    container stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    container delete --force "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    container image delete --force "${IMAGE_NAME}" || true
    if [[ "$(container list --format json 2>/dev/null || true)" == "[]" ]]; then
      container system stop >/dev/null 2>&1 || true
    fi
  fi
else
  echo "Apple Container was not found. Skipping runtime cleanup."
fi

rm -f -- "${STATE_DIR}/helper-token"
temp_root="${TMPDIR:-/tmp}"
temp_root="${temp_root%/}"
cleanup_temp_root "${temp_root}"
if [[ "${temp_root}" != "/tmp" ]]; then
  cleanup_temp_root "/tmp"
fi

echo "Runtime space reclaimed. Run '${RESTORE_COMMAND}' before the next connection."
