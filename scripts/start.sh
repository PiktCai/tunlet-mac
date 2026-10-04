#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${TUNLET_STATE_DIR:-${ROOT_DIR}/.local}"
TOKEN_FILE="${STATE_DIR}/helper-token"
SERVER_FILE="${STATE_DIR}/server"
USERNAME_FILE="${STATE_DIR}/username"
CREDENTIAL_HELPER="${STATE_DIR}/bin/tunlet-credentials"
CONTAINER_NAME="tunlet"
IMAGE_NAME="tunlet-runtime:local-arm64"
HOST_HELPER_URL="http://127.0.0.1:54680"
HOST_SOCKS="127.0.0.1:11080"

for command_name in container curl openssl; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "Missing command: ${command_name}"
    exit 1
  }
done

mkdir -p "${STATE_DIR}"
chmod 700 "${STATE_DIR}"

container system status >/dev/null 2>&1 || container system start

if container list --all --format json | grep -q '"id":"tunlet"'; then
  echo "Tunlet is already running. Stop it before starting a new session."
  exit 0
fi

rm -f "${TOKEN_FILE}"

server_default="${ATRUST_SERVER_DEFAULT:-}"
if [[ -z "${server_default}" && -f "${SERVER_FILE}" ]]; then
  IFS= read -r server_default <"${SERVER_FILE}"
fi
if [[ -n "${server_default}" ]]; then
  read -r -p "aTrust server [${server_default}]: " server
  server="${server:-${server_default}}"
else
  read -r -p "aTrust server: " server
fi
username_default="${ATRUST_USERNAME_DEFAULT:-}"
if [[ -z "${username_default}" && -f "${USERNAME_FILE}" ]]; then
  IFS= read -r username_default <"${USERNAME_FILE}"
fi
if [[ -n "${username_default}" ]]; then
  read -r -p "Username [${username_default}]: " username
  username="${username:-${username_default}}"
else
  read -r -p "Username: " username
fi

password=""
password_source="manual"
if [[ -x "${CREDENTIAL_HELPER}" ]]; then
  echo "Checking macOS Keychain for a saved password..."
  if password="$("${CREDENTIAL_HELPER}" read \
    --server "${server}" \
    --username "${username}")"; then
    password_source="keychain"
    echo "Loaded the saved password."
  else
    echo "Using manual password entry."
  fi
fi

if [[ "${password_source}" == "manual" ]]; then
  read -r -s -p "Password (input hidden): " password
  echo
fi

if [[ -z "${server}" || -z "${username}" || -z "${password}" ]]; then
  echo "Server, username, and password are required."
  exit 1
fi

helper_token="$(openssl rand -hex 24)"
secret_dir="$(mktemp -d "${TMPDIR:-/tmp}/tunlet.XXXXXX")"
cleanup_secret() {
  rm -f "${secret_dir}/helper.env"
  rmdir "${secret_dir}" 2>/dev/null || true
}
trap cleanup_secret EXIT INT TERM

umask 077
{
  printf 'ATRUST_SERVER=%s\n' "${server}"
  printf 'ATRUST_USERNAME=%s\n' "${username}"
  printf 'ATRUST_PASSWORD=%s\n' "${password}"
  printf 'TUNLET_HELPER_TOKEN=%s\n' "${helper_token}"
} >"${secret_dir}/helper.env"

echo "Starting Tunlet..."
container run --detach --rm \
  --name "${CONTAINER_NAME}" \
  --cap-add NET_ADMIN \
  --cpus 2 \
  --memory 2G \
  --mount "type=bind,source=${secret_dir},target=/run/tunlet-secrets,readonly" \
  --env TUNLET_HELPER_ENV_FILE=/run/tunlet-secrets/helper.env \
  --env TUNLET_HELPER_BIND=0.0.0.0 \
  --publish "127.0.0.1:54680:54680" \
  --publish "127.0.0.1:11080:1080" \
  "${IMAGE_NAME}" >/dev/null

ready=0
for _ in $(seq 1 30); do
  if curl --fail --silent \
    --header "Authorization: Bearer ${helper_token}" \
    "${HOST_HELPER_URL}/status" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done

if [[ "${ready}" != 1 ]]; then
  echo "Tunlet did not become ready in time. Recent logs:"
  container logs -n 80 "${CONTAINER_NAME}" 2>/dev/null || true
  container stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  exit 1
fi

# The supervisor has loaded the credentials into memory. Remove the temporary
# host file before any login request is sent; nothing is saved in the project.
cleanup_secret
printf '%s\n' "${helper_token}" >"${TOKEN_FILE}"
chmod 600 "${TOKEN_FILE}"

echo "Signing in..."
response="$(curl --fail --silent --show-error \
  --request POST \
  --header "Authorization: Bearer ${helper_token}" \
  "${HOST_HELPER_URL}/connect")"
printf '%s\n' "${response}"

if [[ "${response}" == *'"pendingSms":true'* ]]; then
  read -r -p "SMS code: " sms_code
  if [[ ! "${sms_code}" =~ ^[0-9]{4,8}$ ]]; then
    echo "The SMS code must contain 4 to 8 digits."
    exit 1
  fi
  response="$(curl --fail --silent --show-error \
    --request POST \
    --header "Authorization: Bearer ${helper_token}" \
    --header 'Content-Type: application/json' \
    --data "{\"smsCode\":\"${sms_code}\"}" \
    "${HOST_HELPER_URL}/submit-sms")"
  printf '%s\n' "${response}"
fi

if [[ "${response}" == *'"connected":true'* ]]; then
  printf '%s\n' "${server}" >"${SERVER_FILE}"
  printf '%s\n' "${username}" >"${USERNAME_FILE}"
  chmod 600 "${SERVER_FILE}" "${USERNAME_FILE}"

  if [[ "${password_source}" == "manual" && -x "${CREDENTIAL_HELPER}" ]]; then
    echo
    echo "Save this password in macOS Keychain?"
    echo "  1. Require Touch ID each time (recommended)"
    echo "  2. Load automatically without confirmation"
    echo "  3. Do not save"
    read -r -p "Choice [1]: " save_choice
    save_choice="${save_choice:-1}"
    credential_mode=""
    case "${save_choice}" in
      1) credential_mode="touch-id" ;;
      2) credential_mode="automatic" ;;
      3) ;;
      *) echo "Invalid choice. The password was not saved." ;;
    esac

    if [[ -n "${credential_mode}" ]]; then
      if printf '%s' "${password}" | "${CREDENTIAL_HELPER}" save \
        --server "${server}" \
        --username "${username}" \
        --mode "${credential_mode}"; then
        if [[ "${credential_mode}" == "touch-id" ]]; then
          echo "Saved the password. Touch ID will be required on the next start."
        else
          echo "Saved the password for automatic use."
        fi
      else
        echo "Could not save the password in macOS Keychain." >&2
      fi
    fi
  fi
  unset password
  echo
  echo "Connected. SOCKS5 proxy: ${HOST_SOCKS}"
else
  unset password
  echo
  echo "Not connected. The container remains available for troubleshooting."
  if [[ "${password_source}" == "keychain" ]]; then
    echo "If the saved password has changed, run: tunlet credentials forget"
  fi
  echo "Recent logs:"
  container logs -n 60 "${CONTAINER_NAME}" 2>/dev/null || true
  exit 1
fi
