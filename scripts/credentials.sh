#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT_DIR}/scripts/lib/ui.sh"
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
  if [[ "${TUNLET_LANG}" == "en" ]]; then
    cat <<'USAGE'
Usage: tunlet credentials <command>

Commands:
  status  Show whether the current account has a saved password
  forget  Delete every password saved by Tunlet
USAGE
  else
    cat <<'USAGE'
用法：tunlet credentials <命令>

命令：
  status  查看当前账号是否保存了密码
  forget  删除 Tunlet 保存的全部密码
USAGE
  fi
}

[[ -x "${HELPER}" ]] || {
  tunlet_ui_error "Tunlet 钥匙串辅助程序尚未安装。" \
    "The Tunlet credential helper is not installed."
  tunlet_ui_note "请运行：${SETUP_COMMAND}" "Run: ${SETUP_COMMAND}"
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
      tunlet_ui_note "尚未配置 Tunlet 账号。" "No Tunlet account is configured."
      exit 0
    fi
    IFS= read -r server <"${SERVER_FILE}"
    IFS= read -r username <"${USERNAME_FILE}"
    if credential_mode="$("${HELPER}" mode --server "${server}" --username "${username}")"; then
      tunlet_ui_title "凭据" "Credentials"
      printf '%s\n' "$(tunlet_text '已保存密码：是' 'Saved password: yes')"
      printf '%s\n' "$(tunlet_text "账号：${username}" "Account: ${username}")"
      printf '%s\n' "$(tunlet_text "服务器：${server}" "Server: ${server}")"
      case "${credential_mode}" in
        touch-id) printf '%s\n' "$(tunlet_text '认证方式：Touch ID' 'Authentication: Touch ID')" ;;
        automatic) printf '%s\n' "$(tunlet_text '认证方式：自动读取' 'Authentication: automatic')" ;;
        *) printf '%s\n' "$(tunlet_text '认证方式：未知' 'Authentication: unknown')" ;;
      esac
    else
      tunlet_ui_note "已保存密码：否" "Saved password: no"
    fi
    ;;
  forget)
    "${HELPER}" delete-all
    tunlet_ui_ok "已删除 Tunlet 保存的密码。" "Deleted passwords saved by Tunlet."
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    tunlet_ui_error "未知的 credentials 命令：${command_name}" \
      "Unknown credentials command: ${command_name}"
    usage >&2
    exit 2
    ;;
esac
