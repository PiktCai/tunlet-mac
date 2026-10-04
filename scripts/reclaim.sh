#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT_DIR}/scripts/lib/ui.sh"
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
  if [[ "${TUNLET_LANG}" == "en" ]]; then
    cat <<'USAGE'
Usage: tunlet reclaim [options]

Remove the Tunlet runtime image and transient data while preserving the
installed command, server, username, and Keychain credentials.

Options:
  --dry-run   Show what would be removed
  --yes       Skip confirmation
  -h, --help  Show this help
USAGE
  else
    cat <<'USAGE'
用法：tunlet reclaim [选项]

删除 Tunlet 运行镜像和临时数据，保留命令、服务器、账号和钥匙串密码。

选项：
  --dry-run   仅显示清理范围
  --yes       跳过确认
  -h, --help  显示帮助
USAGE
  fi
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
      tunlet_ui_error "未知选项：$1" "Unknown option: $1"
      usage >&2
      exit 2
      ;;
  esac
  shift
done

tunlet_ui_title "清理运行空间" "Reclaim runtime space"
printf '%s\n' "$(tunlet_text '将删除以下 Tunlet 运行数据：' 'The following Tunlet runtime data will be removed:')"
printf '%s\n' "$(tunlet_text "  - 容器：${CONTAINER_NAME}" "  - Container: ${CONTAINER_NAME}")"
printf '%s\n' "$(tunlet_text "  - 镜像：${IMAGE_NAME}" "  - Image: ${IMAGE_NAME}")"
printf '%s\n' "$(tunlet_text '  - 会话令牌和 Tunlet 临时文件' '  - Session token and Tunlet temporary files')"
echo
tunlet_ui_note "命令、服务器、账号和钥匙串密码将保留。" \
  "The command, server, username, and Keychain passwords will remain."

if [[ "${DRY_RUN}" == 1 ]]; then
  echo
  tunlet_ui_note "当前仅为预览，没有删除任何内容。" \
    "Dry run only. Nothing was removed."
  exit 0
fi

if [[ "${ASSUME_YES}" != 1 ]]; then
  read -r -p "$(tunlet_ui_prompt '输入 RECLAIM 继续：' 'Type RECLAIM to continue: ')" confirmation
  [[ "${confirmation}" == "RECLAIM" ]] || {
    tunlet_ui_note "已取消。" "Cancelled."
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
      tunlet_ui_warn "Apple Container 无法启动，跳过运行数据清理。" \
        "Apple Container could not start. Skipping runtime cleanup."
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
  tunlet_ui_warn "未找到 Apple Container，跳过运行数据清理。" \
    "Apple Container was not found. Skipping runtime cleanup."
fi

rm -f -- "${STATE_DIR}/helper-token"
temp_root="${TMPDIR:-/tmp}"
temp_root="${temp_root%/}"
cleanup_temp_root "${temp_root}"
if [[ "${temp_root}" != "/tmp" ]]; then
  cleanup_temp_root "/tmp"
fi

tunlet_ui_ok "运行空间已清理。" "Runtime space reclaimed."
tunlet_ui_note "下次连接前请运行：${RESTORE_COMMAND}" \
  "Before the next connection, run: ${RESTORE_COMMAND}"
