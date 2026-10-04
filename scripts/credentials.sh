#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${TUNLET_STATE_DIR:-${ROOT_DIR}/.local}"
if [[ -n "${TUNLET_INSTALL_ROOT:-}" ]]; then
  SETUP_COMMAND="tunlet install"
else
  SETUP_COMMAND="./tunlet setup"
fi
HELPER="${STATE_DIR}/bin/tunlet-credentials"
SERVER_FILE="${STATE_DIR}/server"
USERNAME_FILE="${STATE_DIR}/username"

usage() {
  cat <<'USAGE'
Usage: tunlet credentials <command>

Commands:
  status  Show whether the current account has a saved password
  forget  Delete every password saved by Tunlet
USAGE
}

[[ -x "${HELPER}" ]] || {
  echo "The Tunlet credential helper is not installed." >&2
  echo "Run '${SETUP_COMMAND}' to build it." >&2
  exit 1
}

command_name="${1:-status}"
shift || true
[[ "$#" == 0 ]] || {
  usage >&2
  exit 2
}

case "${command_name}" in
  status)
    if [[ ! -f "${SERVER_FILE}" || ! -f "${USERNAME_FILE}" ]]; then
      echo "No current Tunlet account is configured."
      exit 0
    fi
    IFS= read -r server <"${SERVER_FILE}"
    IFS= read -r username <"${USERNAME_FILE}"
    if credential_mode="$("${HELPER}" mode --server "${server}" --username "${username}")"; then
      echo "Saved password: yes"
      echo "Account: ${username}"
      echo "Server: ${server}"
      case "${credential_mode}" in
        touch-id) echo "Authentication: Touch ID" ;;
        automatic) echo "Authentication: automatic" ;;
        *) echo "Authentication: unknown" ;;
      esac
    else
      echo "Saved password: no"
    fi
    ;;
  forget)
    "${HELPER}" delete-all
    echo "Deleted passwords saved by Tunlet."
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    echo "Unknown credentials command: ${command_name}" >&2
    usage >&2
    exit 2
    ;;
esac
