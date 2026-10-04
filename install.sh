#!/usr/bin/env bash
set -euo pipefail

SOURCE_URL="${TUNLET_SOURCE_URL:-https://codeload.github.com/PiktCai/tunlet-mac/tar.gz/refs/heads/main}"
TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_ROOT="${TEMP_ROOT%/}"
TEMP_DIR=""

fail() {
  echo "Install failed: $*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${TEMP_DIR}" && "${TEMP_DIR}" == "${TEMP_ROOT}/tunlet-bootstrap."* ]]; then
    rm -rf -- "${TEMP_DIR}"
  fi
}
trap cleanup EXIT INT TERM

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS is required."
[[ "$(uname -m)" == "arm64" ]] || fail "Apple silicon is required."
command -v curl >/dev/null 2>&1 || fail "curl is required."
command -v tar >/dev/null 2>&1 || fail "tar is required."

TEMP_DIR="$(mktemp -d "${TEMP_ROOT}/tunlet-bootstrap.XXXXXX")"
archive_path="${TEMP_DIR}/source.tar.gz"

echo "Downloading Tunlet..."
curl --fail --location --retry 3 --progress-bar \
  "${SOURCE_URL}" --output "${archive_path}"
tar -xzf "${archive_path}" -C "${TEMP_DIR}"

source_dir="$(find "${TEMP_DIR}" -mindepth 1 -maxdepth 1 -type d -name 'tunlet-mac-*' -print -quit)"
[[ -n "${source_dir}" && -x "${source_dir}/tunlet" ]] || \
  fail "The downloaded archive is not a valid Tunlet source package."

"${source_dir}/tunlet" install "$@"

echo "Temporary installer files were removed."
