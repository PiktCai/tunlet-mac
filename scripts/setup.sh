#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE_NAME="tunlet-runtime:local-arm64"
BUILD_BASE_IMAGE="rust:1-bookworm"
ATRUST_VERSION="2.5.16.20"
ATRUST_URL="https://atrustcdn.sangfor.com/standard/linux/${ATRUST_VERSION}/uos/arm64/aTrustInstaller_arm64.deb"
ATRUST_SHA256="c8c0c0add77c21abb72ae912b1ac01c2cad6cf0fc439a4b64545100153b0cf31"
TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_ROOT="${TEMP_ROOT%/}"
TEMP_DIR=""
STARTED_SYSTEM=0
BUILD_STARTED=0
BUILD_BASE_IMAGE_PRESENT=0
PACKAGE_PATH=""
if [[ -n "${TUNLET_INSTALL_ROOT:-}" ]]; then
  SETUP_COMMAND="tunlet install"
else
  SETUP_COMMAND="./tunlet setup"
fi

fail() {
  echo "Setup failed: $*" >&2
  exit 1
}

print_completion() {
  echo
  if [[ -n "${TUNLET_INSTALL_ROOT:-}" ]]; then
    echo "Setup complete. Run 'tunlet start' to connect."
  else
    echo "Setup complete. Run './tunlet start' to connect."
  fi
}

cleanup() {
  if [[ "${BUILD_STARTED}" == 1 ]]; then
    container builder stop >/dev/null 2>&1 || true
    container builder delete >/dev/null 2>&1 || true
    if [[ "${BUILD_BASE_IMAGE_PRESENT}" == 0 ]]; then
      container image delete --force "${BUILD_BASE_IMAGE}" >/dev/null 2>&1 || true
    fi
  fi
  if [[ "${STARTED_SYSTEM}" == 1 ]] &&
     [[ "$(container list --format json 2>/dev/null || true)" == "[]" ]]; then
    container system stop >/dev/null 2>&1 || true
  fi
  if [[ -n "${TEMP_DIR}" && "${TEMP_DIR}" == "${TEMP_ROOT}/tunlet-setup."* ]]; then
    rm -rf "${TEMP_DIR}"
  fi
}
trap cleanup EXIT INT TERM

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS is required."
[[ "$(uname -m)" == "arm64" ]] || fail "Apple silicon is required."
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
[[ "${macos_major}" =~ ^[0-9]+$ && "${macos_major}" -ge 26 ]] || \
  fail "macOS 26 or later is required."

for command_name in container curl shasum; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    if [[ "${command_name}" == "container" ]]; then
      fail "Apple Container is missing. Install it from https://github.com/apple/container/releases/latest"
    fi
    fail "Missing command: ${command_name}"
  }
done

if ! "${ROOT_DIR}/scripts/build-credentials.sh"; then
  echo "Warning: Keychain integration could not be installed."
  echo "Install Xcode Command Line Tools with: xcode-select --install"
fi

download_official_package() {
  local output="$1"
  echo "Downloading aTrust ${ATRUST_VERSION} ARM64 from Sangfor's official CDN..."
  if ! curl --fail --location --retry 3 --progress-bar \
    "${ATRUST_URL}" --output "${output}"; then
    if [[ "${http_proxy:-}${https_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}" == *"127.0.0.1"* ]]; then
      echo "The configured local proxy is unavailable. Retrying without it..."
      rm -f "${output}"
      env -u http_proxy -u https_proxy -u all_proxy \
        -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
        curl --fail --location --retry 3 --progress-bar \
          "${ATRUST_URL}" --output "${output}"
    else
      return 1
    fi
  fi

  local actual_sha256
  actual_sha256="$(shasum -a 256 "${output}" | awk '{print $1}')"
  [[ "${actual_sha256}" == "${ATRUST_SHA256}" ]] || {
    rm -f "${output}"
    fail "Package checksum mismatch. The downloaded file was removed."
  }
  echo "Package checksum verified."
}

select_local_package() {
  local selected
  read -r -p "Drag an ARM64 .deb or .zip file here, then press Enter: " selected
  selected="${selected#\'}"
  selected="${selected%\'}"
  selected="${selected#\"}"
  selected="${selected%\"}"
  selected="${selected//\\ / }"
  printf '%s\n' "${selected}"
}

prepare_package() {
  local source="$1"
  [[ -f "${source}" ]] || fail "Package not found: ${source}"

  case "${source}" in
    *.zip|*.ZIP)
      command -v unzip >/dev/null 2>&1 || fail "unzip is required for .zip packages."
      [[ -n "${TEMP_DIR}" ]] || TEMP_DIR="$(mktemp -d "${TEMP_ROOT}/tunlet-setup.XXXXXX")"
      unzip -q "${source}" -d "${TEMP_DIR}/package"
      local extracted
      extracted="$(find "${TEMP_DIR}/package" -type f -name 'aTrustInstaller_arm64.deb' -print -quit)"
      [[ -n "${extracted}" ]] || fail "The archive does not contain aTrustInstaller_arm64.deb."
      PACKAGE_PATH="${extracted}"
      ;;
    *.deb|*.DEB)
      PACKAGE_PATH="${source}"
      ;;
    *)
      fail "The package must be an ARM64 .deb or a .zip containing it."
      ;;
  esac
}

[[ "$#" -le 1 ]] || fail "Usage: ${SETUP_COMMAND} [ARM64 package path]"

if ! container system status >/dev/null 2>&1; then
  container system start
  STARTED_SYSTEM=1
fi

if container image list | awk \
  '$1 == "tunlet-runtime" && $2 == "local-arm64" { found = 1 } END { exit !found }'; then
  read -r -p "A Tunlet image already exists. Rebuild it? [y/N] " rebuild
  case "${rebuild:-n}" in
    y|Y|yes|YES) ;;
    *)
      echo "Kept the existing image."
      print_completion
      exit 0
      ;;
  esac
fi

package_source="${1:-}"
if [[ -z "${package_source}" ]]; then
  echo "Select a package source:"
  echo "  1. Download verified version ${ATRUST_VERSION} from Sangfor's official CDN"
  echo "  2. Use a local package"
  read -r -p "Choice [1]: " choice
  choice="${choice:-1}"
  case "${choice}" in
    1)
      TEMP_DIR="$(mktemp -d "${TEMP_ROOT}/tunlet-setup.XXXXXX")"
      package_source="${TEMP_DIR}/aTrustInstaller_arm64.deb"
      download_official_package "${package_source}"
      ;;
    2)
      package_source="$(select_local_package)"
      ;;
    *)
      fail "Invalid choice."
      ;;
  esac
fi

prepare_package "${package_source}"

if container image list | awk \
  '$1 == "rust" && $2 == "1-bookworm" { found = 1 } END { exit !found }'; then
  BUILD_BASE_IMAGE_PRESENT=1
fi

BUILD_STARTED=1
"${ROOT_DIR}/scripts/build-image.sh" "${PACKAGE_PATH}"
"${ROOT_DIR}/scripts/test-runtime.sh"

print_completion
