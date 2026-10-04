#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT_DIR}/scripts/lib/ui.sh"
STATE_DIR="${TUNLET_STATE_DIR:-${ROOT_DIR}/.local}"
EXPECTED_INSTALL_ROOT="${HOME}/Library/Application Support/Tunlet"
INSTALL_ROOT="${TUNLET_INSTALL_ROOT:-}"
LAUNCHER_PATH="${HOME}/.local/bin/tunlet"
INSTALLED_MODE=0
if [[ "${INSTALL_ROOT}" == "${EXPECTED_INSTALL_ROOT}" && \
      "${ROOT_DIR}" == "${EXPECTED_INSTALL_ROOT}/app" && \
      "${STATE_DIR}" == "${EXPECTED_INSTALL_ROOT}/state" ]]; then
  INSTALLED_MODE=1
fi
CONTAINER_NAME="tunlet"
IMAGE_NAME="tunlet-runtime:local-arm64"
CREDENTIAL_HELPER="${STATE_DIR}/bin/tunlet-credentials"
CREDENTIAL_SERVICE="io.github.piktcai.tunlet.credentials"
DRY_RUN=0
ASSUME_YES=0
INCLUDE_BUILDER=0

usage() {
  if [[ "${TUNLET_LANG}" == "en" ]]; then
    cat <<'USAGE'
Usage: tunlet uninstall [options]

Remove Tunlet's command, application, runtime, local state, and temporary files.

Options:
  --dry-run          Show what would be removed
  --yes              Skip confirmation
  --include-builder  Also remove the shared Apple Container builder
  -h, --help         Show this help
USAGE
  else
    cat <<'USAGE'
用法：tunlet uninstall [选项]

删除 Tunlet 命令、程序、运行镜像、本地状态和临时文件。

选项：
  --dry-run          仅显示卸载范围
  --yes              跳过确认
  --include-builder  同时删除共享的 Apple Container builder
  -h, --help         显示帮助
USAGE
  fi
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
      tunlet_ui_error "未知选项：$1" "Unknown option: $1"
      usage >&2
      exit 2
      ;;
  esac
  shift
done

[[ "$(uname -s)" == "Darwin" ]] || {
  tunlet_ui_error "该脚本需要 macOS。" "This script requires macOS."
  exit 1
}

tunlet_ui_title "卸载" "Uninstall"
printf '%s\n' "$(tunlet_text '将删除以下内容：' 'The following items will be removed:')"
printf '%s\n' "$(tunlet_text "  - 容器：${CONTAINER_NAME}" "  - Container: ${CONTAINER_NAME}")"
printf '%s\n' "$(tunlet_text "  - 镜像：${IMAGE_NAME}" "  - Image: ${IMAGE_NAME}")"
printf '%s\n' "$(tunlet_text "  - 本地状态：${STATE_DIR}" "  - Local state: ${STATE_DIR}")"
printf '%s\n' "$(tunlet_text '  - Tunlet 保存到 macOS 钥匙串的密码' '  - Passwords saved by Tunlet in macOS Keychain')"
printf '%s\n' "$(tunlet_text '  - Tunlet 临时文件' '  - Tunlet temporary files')"
if [[ "${INSTALLED_MODE}" == 1 ]]; then
  printf '%s\n' "$(tunlet_text "  - 已安装程序：${INSTALL_ROOT}" "  - Installed application: ${INSTALL_ROOT}")"
  printf '%s\n' "$(tunlet_text "  - 命令：${LAUNCHER_PATH}" "  - Command: ${LAUNCHER_PATH}")"
fi
if [[ "${INCLUDE_BUILDER}" == 1 ]]; then
  printf '%s\n' "$(tunlet_text '  - 共享的 Apple Container builder 缓存' '  - Shared Apple Container builder cache')"
  echo
  tunlet_ui_warn "其他项目可能使用共享 builder，删除后需要重新创建。" \
    "Other projects may use the shared builder. It will need to be recreated."
fi
echo
tunlet_ui_note "Apple Container 和无关的容器、镜像不会被删除。" \
  "Apple Container and unrelated containers or images will not be removed."

if [[ "${DRY_RUN}" == 1 ]]; then
  echo
  tunlet_ui_note "当前仅为预览，没有删除任何内容。" \
    "Dry run only. Nothing was removed."
  exit 0
fi

if [[ "${ASSUME_YES}" != 1 ]]; then
  read -r -p "$(tunlet_ui_prompt '输入 DELETE 继续：' 'Type DELETE to continue: ')" confirmation
  [[ "${confirmation}" == "DELETE" ]] || {
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
      tunlet_ui_warn "Apple Container 无法启动，跳过容器和镜像清理。" \
        "Apple Container could not start. Skipping container and image cleanup."
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
  tunlet_ui_warn "未找到 Apple Container，跳过容器和镜像清理。" \
    "Apple Container was not found. Skipping container and image cleanup."
fi

if [[ -x "${CREDENTIAL_HELPER}" ]]; then
  if ! "${CREDENTIAL_HELPER}" delete-all; then
    tunlet_ui_warn "无法删除 Tunlet 保存的钥匙串密码。" \
      "Tunlet could not remove its saved Keychain passwords."
  fi
elif command -v security >/dev/null 2>&1; then
  while security delete-generic-password \
    -s "${CREDENTIAL_SERVICE}" >/dev/null 2>&1; do
    :
  done
fi

if [[ "${STATE_DIR}" == "${ROOT_DIR}/.local" || \
      ( "${INSTALLED_MODE}" == 1 && "${STATE_DIR}" == "${INSTALL_ROOT}/state" ) ]]; then
  rm -rf -- "${STATE_DIR}"
fi

temp_root="${TMPDIR:-/tmp}"
temp_root="${temp_root%/}"
cleanup_temp_root "${temp_root}"
if [[ "${temp_root}" != "/tmp" ]]; then
  cleanup_temp_root "/tmp"
fi

if [[ "${INSTALLED_MODE}" == 1 ]]; then
  if [[ -f "${LAUNCHER_PATH}" ]] && \
     grep -Fqx '# Managed by Tunlet' "${LAUNCHER_PATH}"; then
    rm -f -- "${LAUNCHER_PATH}"
  fi
  cd "${HOME}"
  rm -rf -- "${INSTALL_ROOT}"
  tunlet_ui_ok "Tunlet 已卸载。" "Tunlet was removed."
  tunlet_ui_note "Apple Container 和无关数据仍然保留。" \
    "Apple Container and unrelated data remain installed."
else
  tunlet_ui_ok "运行数据已删除。" "Runtime data was removed."
  tunlet_ui_note "源码目录和 Apple Container 仍然保留。" \
    "The source tree and Apple Container remain installed."
fi
