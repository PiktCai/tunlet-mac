#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: build-atrust-lite-supervisor.sh --output <path> [options]

Options:
  --runtime-root <dir>  Link against the runtime root's glibc compatibility baseline.
  --source <path>       Rust source path. Defaults to atrust-lite-supervisor.rs beside this script.
USAGE
}

fail() {
  echo "build-atrust-lite-supervisor: $*" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="${SCRIPT_DIR}/atrust-lite-supervisor.rs"
OUTPUT=""
RUNTIME_ROOT=""

detect_target_libdir() {
  if command -v dpkg-architecture >/dev/null 2>&1; then
    dpkg-architecture -qDEB_HOST_MULTIARCH
    return
  fi
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' x86_64-linux-gnu ;;
    aarch64|arm64) printf '%s\n' aarch64-linux-gnu ;;
    *) fail "unsupported build architecture: $(uname -m)" ;;
  esac
}

TARGET_LIBDIR="${ATRUST_SUPERVISOR_TARGET_LIBDIR:-$(detect_target_libdir)}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || fail "--output requires a path"
      OUTPUT="$2"
      shift 2
      ;;
    --runtime-root)
      [[ $# -ge 2 ]] || fail "--runtime-root requires a path"
      RUNTIME_ROOT="$2"
      shift 2
      ;;
    --source)
      [[ $# -ge 2 ]] || fail "--source requires a path"
      SOURCE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "${OUTPUT}" ]] || fail "--output is required"
[[ -f "${SOURCE}" ]] || fail "Rust source not found: ${SOURCE}"
command -v rustc >/dev/null 2>&1 || fail "rustc is required"

link_args=()
link_dir=""
runtime_libc=""

find_runtime_library() {
  local name="$1"
  local candidate
  for candidate in \
    "${RUNTIME_ROOT}/lib/${TARGET_LIBDIR}/${name}" \
    "${RUNTIME_ROOT}/usr/lib/${TARGET_LIBDIR}/${name}"; do
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

link_runtime_library() {
  local link_name="$1"
  local runtime_name="$2"
  local required="${3:-0}"
  local target
  target="$(find_runtime_library "${runtime_name}" || true)"
  if [[ -z "${target}" ]]; then
    [[ "${required}" == "0" ]] || fail "runtime library not found: ${runtime_name}"
    return 0
  fi
  ln -s "${target}" "${link_dir}/${link_name}"
}

glibc_max() {
  strings "$1" 2>/dev/null \
    | sed -n 's/^GLIBC_//p' \
    | grep -E '^[0-9]+([.][0-9]+)*$' \
    | sort -V \
    | tail -1 || true
}

version_gt() {
  local left="$1"
  local right="$2"
  local highest
  highest="$(printf '%s\n%s\n' "${left}" "${right}" | sort -V | tail -1)"
  [[ "${left}" != "${right}" && "${highest}" == "${left}" ]]
}

if [[ -n "${RUNTIME_ROOT}" ]]; then
  [[ -d "${RUNTIME_ROOT}" ]] || fail "runtime root not found: ${RUNTIME_ROOT}"
  link_dir="$(mktemp -d "${TMPDIR:-/tmp}/atrust-supervisor-link.XXXXXX")"
  trap 'rm -rf "${link_dir}"' EXIT

  runtime_libc="$(find_runtime_library libc.so.6 || true)"
  [[ -n "${runtime_libc}" ]] || fail "runtime libc.so.6 not found under ${RUNTIME_ROOT}"
  link_runtime_library libc.so libc.so.6 1
  link_runtime_library libm.so libm.so.6
  link_runtime_library libdl.so libdl.so.2
  link_runtime_library libpthread.so libpthread.so.0
  link_runtime_library librt.so librt.so.1
  link_runtime_library libutil.so libutil.so.1
  link_args=(-L "native=${link_dir}")
fi

mkdir -p "$(dirname "${OUTPUT}")"
rustc --edition=2021 -C opt-level=z -C strip=symbols \
  "${link_args[@]}" \
  -o "${OUTPUT}" \
  "${SOURCE}"

if [[ -n "${runtime_libc}" ]]; then
  binary_glibc="$(glibc_max "${OUTPUT}")"
  runtime_glibc="$(glibc_max "${runtime_libc}")"
  [[ -n "${binary_glibc}" ]] || fail "could not determine supervisor GLIBC requirement"
  [[ -n "${runtime_glibc}" ]] || fail "could not determine runtime GLIBC version"
  if version_gt "${binary_glibc}" "${runtime_glibc}"; then
    fail "compiled supervisor requires GLIBC_${binary_glibc}, runtime provides GLIBC_${runtime_glibc}"
  fi
  echo "built ${OUTPUT} for runtime GLIBC_${runtime_glibc} (requires GLIBC_${binary_glibc})"
else
  echo "built ${OUTPUT}"
fi
