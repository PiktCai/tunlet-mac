#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT_DIR}/scripts/lib/ui.sh"
STATE_DIR="${TUNLET_STATE_DIR:-${ROOT_DIR}/.local}"
if [[ -n "${TUNLET_INSTALL_ROOT:-}" ]]; then
  TUNLET_COMMAND="tunlet"
else
  TUNLET_COMMAND="./tunlet"
fi
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
    tunlet_ui_error "缺少命令：${command_name}" "Missing command: ${command_name}"
    exit 1
  }
done

tunlet_ui_title "连接" "Connect"
mkdir -p "${STATE_DIR}"
chmod 700 "${STATE_DIR}"

container system status >/dev/null 2>&1 || container system start

if container list --all --format json | grep -q '"id":"tunlet"'; then
  tunlet_ui_warn "Tunlet 已在运行。请先停止当前会话。" \
    "Tunlet is already running. Stop it before starting a new session."
  exit 0
fi

rm -f "${TOKEN_FILE}"

server_default="${ATRUST_SERVER_DEFAULT:-}"
if [[ -z "${server_default}" && -f "${SERVER_FILE}" ]]; then
  IFS= read -r server_default <"${SERVER_FILE}"
fi
if [[ -n "${server_default}" ]]; then
  read -r -p "$(tunlet_ui_prompt "服务器地址 [${server_default}]：" "Server [${server_default}]: ")" server
  server="${server:-${server_default}}"
else
  tunlet_ui_note "示例：https://vpn.example.edu.cn" "Example: https://vpn.example.edu.cn"
  read -r -p "$(tunlet_ui_prompt '服务器地址：' 'Server: ')" server
fi
server_input="${server}"
if ! server="$(tunlet_normalize_server "${server_input}")"; then
  tunlet_ui_error "服务器地址无效，请输入域名或 HTTP(S) URL。" \
    "Invalid server. Enter a hostname or an HTTP(S) URL."
  exit 1
fi
trimmed_server="$(printf '%s' "${server_input}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
if [[ "${trimmed_server}" != [Hh][Tt][Tt][Pp]://* && \
      "${trimmed_server}" != [Hh][Tt][Tt][Pp][Ss]://* ]]; then
  tunlet_ui_note "已自动补全为：${server}" "Added HTTPS automatically: ${server}"
elif [[ "${server}" != "${server_input}" ]]; then
  tunlet_ui_note "已使用：${server}" "Using: ${server}"
fi
username_default="${ATRUST_USERNAME_DEFAULT:-}"
if [[ -z "${username_default}" && -f "${USERNAME_FILE}" ]]; then
  IFS= read -r username_default <"${USERNAME_FILE}"
fi
if [[ -n "${username_default}" ]]; then
  read -r -p "$(tunlet_ui_prompt "账号 [${username_default}]：" "Username [${username_default}]: ")" username
  username="${username:-${username_default}}"
else
  read -r -p "$(tunlet_ui_prompt '账号：' 'Username: ')" username
fi

password=""
password_source="manual"
if [[ -x "${CREDENTIAL_HELPER}" ]]; then
  tunlet_ui_step "正在检查 macOS 钥匙串…" "Checking macOS Keychain..."
  if password="$("${CREDENTIAL_HELPER}" read \
    --server "${server}" \
    --username "${username}")"; then
    password_source="keychain"
    tunlet_ui_ok "已读取保存的密码。" "Loaded the saved password."
  else
    tunlet_ui_note "未找到可用密码，请手动输入。" "No saved password is available."
  fi
fi

if [[ "${password_source}" == "manual" ]]; then
  read -r -s -p "$(tunlet_ui_prompt '密码（输入不会显示）：' 'Password (input hidden): ')" password
  echo
fi

if [[ -z "${server}" || -z "${username}" || -z "${password}" ]]; then
  tunlet_ui_error "服务器、账号和密码不能为空。" \
    "Server, username, and password are required."
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

tunlet_ui_step "正在启动 Tunlet…" "Starting Tunlet..."
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
  tunlet_ui_error "Tunlet 未能及时就绪。" "Tunlet did not become ready in time."
  tunlet_ui_note "最近的日志：" "Recent logs:"
  container logs -n 80 "${CONTAINER_NAME}" 2>/dev/null || true
  container stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  exit 1
fi

# The supervisor has loaded the credentials into memory. Remove the temporary
# host file before any login request is sent; nothing is saved in the project.
cleanup_secret
printf '%s\n' "${helper_token}" >"${TOKEN_FILE}"
chmod 600 "${TOKEN_FILE}"

tunlet_ui_step "正在登录 aTrust…" "Signing in to aTrust..."
response="$(curl --fail --silent --show-error \
  --request POST \
  --header "Authorization: Bearer ${helper_token}" \
  "${HOST_HELPER_URL}/connect")"

if [[ "${response}" == *'"pendingSms":true'* ]]; then
  tunlet_ui_ok "短信验证码已发送。" "SMS verification code sent."
  read -r -p "$(tunlet_ui_prompt '短信验证码：' 'SMS code: ')" sms_code
  if [[ ! "${sms_code}" =~ ^[0-9]{4,8}$ ]]; then
    tunlet_ui_error "短信验证码必须是 4 到 8 位数字。" \
      "The SMS code must contain 4 to 8 digits."
    exit 1
  fi
  response="$(curl --fail --silent --show-error \
    --request POST \
    --header "Authorization: Bearer ${helper_token}" \
    --header 'Content-Type: application/json' \
    --data "{\"smsCode\":\"${sms_code}\"}" \
    "${HOST_HELPER_URL}/submit-sms")"
fi

if [[ "${response}" == *'"connected":true'* ]]; then
  printf '%s\n' "${server}" >"${SERVER_FILE}"
  printf '%s\n' "${username}" >"${USERNAME_FILE}"
  chmod 600 "${SERVER_FILE}" "${USERNAME_FILE}"

  if [[ "${password_source}" == "manual" && -x "${CREDENTIAL_HELPER}" ]]; then
    echo
    printf '%s\n' "$(tunlet_text '是否将密码保存到 macOS 钥匙串？' 'Save this password in macOS Keychain?')"
    printf '%s\n' "$(tunlet_text '  1. 每次使用 Touch ID 确认（推荐）' '  1. Require Touch ID each time (recommended)')"
    printf '%s\n' "$(tunlet_text '  2. 自动读取，不再确认' '  2. Load automatically without confirmation')"
    printf '%s\n' "$(tunlet_text '  3. 不保存' '  3. Do not save')"
    read -r -p "$(tunlet_ui_prompt '选择 [1]：' 'Choice [1]: ')" save_choice
    save_choice="${save_choice:-1}"
    credential_mode=""
    case "${save_choice}" in
      1) credential_mode="touch-id" ;;
      2) credential_mode="automatic" ;;
      3) ;;
      *) tunlet_ui_warn "选项无效，密码没有保存。" "Invalid choice. The password was not saved." ;;
    esac

    if [[ -n "${credential_mode}" ]]; then
      if printf '%s' "${password}" | "${CREDENTIAL_HELPER}" save \
        --server "${server}" \
        --username "${username}" \
        --mode "${credential_mode}"; then
        if [[ "${credential_mode}" == "touch-id" ]]; then
          tunlet_ui_ok "密码已保存，下次连接时需要 Touch ID。" \
            "Password saved. Touch ID will be required next time."
        else
          tunlet_ui_ok "密码已保存，后续将自动读取。" \
            "Password saved for automatic use."
        fi
      else
        tunlet_ui_error "无法将密码保存到 macOS 钥匙串。" \
          "Could not save the password in macOS Keychain."
      fi
    fi
  fi
  unset password
  echo
  tunlet_ui_ok "已连接。" "Connected."
  tunlet_ui_note "SOCKS5 代理：${HOST_SOCKS}" "SOCKS5 proxy: ${HOST_SOCKS}"
else
  unset password
  echo
  sdk_code="$(printf '%s' "${response}" | sed -n 's/.*"sdkCode":\(-*[0-9][0-9]*\).*/\1/p')"
  tunlet_ui_error "登录失败。请检查服务器地址、账号和密码。" \
    "Login failed. Check the server, username, and password."
  tunlet_ui_note "服务器：${server}" "Server: ${server}"
  if [[ -n "${sdk_code}" ]]; then
    tunlet_ui_note "SDK 错误码：${sdk_code}" "SDK error code: ${sdk_code}"
  fi
  tunlet_ui_note "容器仍在运行，可用于排障。" \
    "The container remains available for troubleshooting."
  if [[ "${password_source}" == "keychain" ]]; then
    tunlet_ui_note "如果密码已更改，请运行：${TUNLET_COMMAND} credentials forget" \
      "If the saved password changed, run: ${TUNLET_COMMAND} credentials forget"
  fi
  tunlet_ui_note "最近的日志：" "Recent logs:"
  container logs -n 60 "${CONTAINER_NAME}" 2>/dev/null || true
  exit 1
fi
