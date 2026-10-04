#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${SOURCE_ROOT}/scripts/lib/ui.sh"
INSTALL_ROOT="${HOME}/Library/Application Support/Tunlet"
APP_DIR="${INSTALL_ROOT}/app"
STATE_DIR="${INSTALL_ROOT}/state"
LAUNCHER_DIR="${HOME}/.local/bin"
LAUNCHER_PATH="${LAUNCHER_DIR}/tunlet"
STAGED_APP=""
PREVIOUS_APP="${INSTALL_ROOT}/.app.previous"

fail() {
  tunlet_ui_error "安装失败：$*" "Install failed: $*"
  exit 1
}

cleanup() {
  if [[ -n "${STAGED_APP}" && -d "${STAGED_APP}" ]]; then
    rm -rf -- "${STAGED_APP}"
  fi
}
trap cleanup EXIT INT TERM

[[ "$(uname -s)" == "Darwin" ]] || fail "$(tunlet_text '需要 macOS。' 'macOS is required.')"
[[ "$(uname -m)" == "arm64" ]] || fail "$(tunlet_text '需要 Apple 芯片。' 'Apple silicon is required.')"
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
[[ "${macos_major}" =~ ^[0-9]+$ && "${macos_major}" -ge 26 ]] || \
  fail "$(tunlet_text '需要 macOS 26 或更高版本。' 'macOS 26 or later is required.')"
[[ "$#" -le 1 ]] || fail "$(tunlet_text '用法：tunlet install [ARM64 安装包路径]' 'Usage: tunlet install [ARM64 package path]')"

tunlet_ui_title "安装" "Install"

package_path="${1:-}"
if [[ -n "${package_path}" ]]; then
  [[ -f "${package_path}" ]] || fail "$(tunlet_text "找不到安装包：${package_path}" "Package not found: ${package_path}")"
  package_path="$(cd "$(dirname "${package_path}")" && pwd)/$(basename "${package_path}")"
fi

mkdir -p "${INSTALL_ROOT}" "${STATE_DIR}" "${LAUNCHER_DIR}"
chmod 700 "${INSTALL_ROOT}" "${STATE_DIR}"
if [[ -f "${STATE_DIR}/language" && "${TUNLET_LANG_EXPLICIT:-0}" != 1 ]]; then
  IFS= read -r TUNLET_LANG <"${STATE_DIR}/language"
  tunlet_init_language
else
  printf '%s\n' "${TUNLET_LANG}" >"${STATE_DIR}/language"
fi
chmod 600 "${STATE_DIR}/language"
for state_file in server username; do
  if [[ -f "${SOURCE_ROOT}/.local/${state_file}" && \
        ! -e "${STATE_DIR}/${state_file}" ]]; then
    install -m 0600 "${SOURCE_ROOT}/.local/${state_file}" \
      "${STATE_DIR}/${state_file}"
  fi
done
if [[ -x "${SOURCE_ROOT}/.local/bin/tunlet-credentials" ]]; then
  mkdir -p "${STATE_DIR}/bin"
  install -m 0755 "${SOURCE_ROOT}/.local/bin/tunlet-credentials" \
    "${STATE_DIR}/bin/tunlet-credentials"
  if [[ -f "${SOURCE_ROOT}/.local/bin/tunlet-credentials.sha256" ]]; then
    install -m 0600 "${SOURCE_ROOT}/.local/bin/tunlet-credentials.sha256" \
      "${STATE_DIR}/bin/tunlet-credentials.sha256"
  fi
fi
STAGED_APP="$(mktemp -d "${INSTALL_ROOT}/.app.XXXXXX")"

for item in tunlet tunlet.yaml LICENSE NOTICE.md scripts Sources; do
  cp -R "${SOURCE_ROOT}/${item}" "${STAGED_APP}/"
done
chmod +x "${STAGED_APP}/tunlet" "${STAGED_APP}"/scripts/*.sh
bash -n "${STAGED_APP}/tunlet" "${STAGED_APP}"/scripts/*.sh \
  "${STAGED_APP}"/scripts/lib/*.sh

rm -rf -- "${PREVIOUS_APP}"
if [[ -d "${APP_DIR}" ]]; then
  mv "${APP_DIR}" "${PREVIOUS_APP}"
fi
if ! mv "${STAGED_APP}" "${APP_DIR}"; then
  [[ -d "${PREVIOUS_APP}" ]] && mv "${PREVIOUS_APP}" "${APP_DIR}"
  fail "$(tunlet_text '无法启用已安装的程序。' 'Could not activate the installed application.')"
fi
STAGED_APP=""
rm -rf -- "${PREVIOUS_APP}"

launcher_temp="${LAUNCHER_PATH}.tmp.$$"
cat >"${launcher_temp}" <<'LAUNCHER'
#!/usr/bin/env bash
# Managed by Tunlet
set -euo pipefail
export TUNLET_INSTALL_ROOT="${HOME}/Library/Application Support/Tunlet"
export TUNLET_STATE_DIR="${TUNLET_INSTALL_ROOT}/state"
exec "${TUNLET_INSTALL_ROOT}/app/tunlet" "$@"
LAUNCHER
chmod 0755 "${launcher_temp}"
mv "${launcher_temp}" "${LAUNCHER_PATH}"

case ":${PATH}:" in
  *":${LAUNCHER_DIR}:"*) ;;
  *)
    tunlet_ui_warn "${LAUNCHER_DIR} 不在 PATH 中。" "${LAUNCHER_DIR} is not in PATH."
    tunlet_ui_note "请将这行加入 Shell 配置：export PATH=\"\$HOME/.local/bin:\$PATH\"" \
      "Add this line to your shell profile: export PATH=\"\$HOME/.local/bin:\$PATH\""
    ;;
esac

tunlet_ui_ok "Tunlet 命令已安装到 ${LAUNCHER_PATH}" \
  "Installed the Tunlet command at ${LAUNCHER_PATH}"
if [[ -n "${package_path}" ]]; then
  TUNLET_INSTALL_ROOT="${INSTALL_ROOT}" \
    TUNLET_STATE_DIR="${STATE_DIR}" \
    "${APP_DIR}/scripts/setup.sh" "${package_path}"
else
  TUNLET_INSTALL_ROOT="${INSTALL_ROOT}" \
    TUNLET_STATE_DIR="${STATE_DIR}" \
    "${APP_DIR}/scripts/setup.sh"
fi

echo
tunlet_ui_ok "Tunlet 已准备完成。" "Tunlet is ready."
tunlet_ui_note "运行：tunlet start" "Run: tunlet start"
