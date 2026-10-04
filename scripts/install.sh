#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_ROOT="${HOME}/Library/Application Support/Tunlet"
APP_DIR="${INSTALL_ROOT}/app"
STATE_DIR="${INSTALL_ROOT}/state"
LAUNCHER_DIR="${HOME}/.local/bin"
LAUNCHER_PATH="${LAUNCHER_DIR}/tunlet"
STAGED_APP=""
PREVIOUS_APP="${INSTALL_ROOT}/.app.previous"

fail() {
  echo "Install failed: $*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${STAGED_APP}" && -d "${STAGED_APP}" ]]; then
    rm -rf -- "${STAGED_APP}"
  fi
}
trap cleanup EXIT INT TERM

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS is required."
[[ "$(uname -m)" == "arm64" ]] || fail "Apple silicon is required."
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
[[ "${macos_major}" =~ ^[0-9]+$ && "${macos_major}" -ge 26 ]] || \
  fail "macOS 26 or later is required."
[[ "$#" -le 1 ]] || fail "Usage: tunlet install [ARM64 package path]"

package_path="${1:-}"
if [[ -n "${package_path}" ]]; then
  [[ -f "${package_path}" ]] || fail "Package not found: ${package_path}"
  package_path="$(cd "$(dirname "${package_path}")" && pwd)/$(basename "${package_path}")"
fi

mkdir -p "${INSTALL_ROOT}" "${STATE_DIR}" "${LAUNCHER_DIR}"
chmod 700 "${INSTALL_ROOT}" "${STATE_DIR}"
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
bash -n "${STAGED_APP}/tunlet" "${STAGED_APP}"/scripts/*.sh

rm -rf -- "${PREVIOUS_APP}"
if [[ -d "${APP_DIR}" ]]; then
  mv "${APP_DIR}" "${PREVIOUS_APP}"
fi
if ! mv "${STAGED_APP}" "${APP_DIR}"; then
  [[ -d "${PREVIOUS_APP}" ]] && mv "${PREVIOUS_APP}" "${APP_DIR}"
  fail "Could not activate the installed application."
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
    echo "Warning: ${LAUNCHER_DIR} is not in PATH."
    echo "Add this line to your shell profile: export PATH=\"\$HOME/.local/bin:\$PATH\""
    ;;
esac

echo "Installed the Tunlet command at ${LAUNCHER_PATH}"
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
echo "Tunlet is ready. Run: tunlet start"
