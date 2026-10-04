#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${TUNLET_STATE_DIR:-${ROOT_DIR}/.local}"
OUTPUT_DIR="${STATE_DIR}/bin"
OUTPUT_PATH="${OUTPUT_DIR}/tunlet-credentials"
HASH_PATH="${OUTPUT_DIR}/tunlet-credentials.sha256"
SOURCE_PATH="${ROOT_DIR}/Sources/TunletCredentials/main.swift"
TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_ROOT="${TEMP_ROOT%/}"

fail() {
  echo "build-credentials: $*" >&2
  exit 1
}

command -v shasum >/dev/null 2>&1 || fail "shasum is required"

source_hash="$(
  shasum -a 256 "${SOURCE_PATH}" "$0" \
    | shasum -a 256 \
    | awk '{print $1}'
)"
if [[ -x "${OUTPUT_PATH}" && -f "${HASH_PATH}" ]] &&
   [[ "$(<"${HASH_PATH}")" == "${source_hash}" ]]; then
  echo "Credential helper is up to date."
  exit 0
fi

command -v swiftc >/dev/null 2>&1 || \
  fail "Swift is required. Install Xcode Command Line Tools with: xcode-select --install"
command -v codesign >/dev/null 2>&1 || fail "codesign is required"

scratch_dir="$(mktemp -d "${TEMP_ROOT}/tunlet-swift.XXXXXX")"
cleanup() {
  if [[ "${scratch_dir}" == "${TEMP_ROOT}/tunlet-swift."* ]]; then
    rm -rf -- "${scratch_dir}"
  fi
}
trap cleanup EXIT INT TERM

swiftc \
  -parse-as-library \
  -O \
  -framework Security \
  -framework LocalAuthentication \
  "${SOURCE_PATH}" \
  -o "${scratch_dir}/tunlet-credentials"

mkdir -p "${OUTPUT_DIR}"
install -m 0755 "${scratch_dir}/tunlet-credentials" "${OUTPUT_PATH}"
codesign --force --sign - \
  --identifier io.github.piktcai.tunlet.credentials \
  "${OUTPUT_PATH}"
printf '%s\n' "${source_hash}" >"${HASH_PATH}"
chmod 600 "${HASH_PATH}"

echo "Built ${OUTPUT_PATH}"
