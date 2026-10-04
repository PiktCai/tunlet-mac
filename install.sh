#!/usr/bin/env bash
set -euo pipefail

SOURCE_URL="${TUNLET_SOURCE_URL:-https://codeload.github.com/PiktCai/tunlet-mac/tar.gz/refs/heads/main}"
TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_ROOT="${TEMP_ROOT%/}"
TEMP_DIR=""
if [[ -n "${TUNLET_LANG:-}" ]]; then
  TUNLET_LANG_EXPLICIT=1
else
  TUNLET_LANG_EXPLICIT=0
  language_file="${HOME}/Library/Application Support/Tunlet/state/language"
  if [[ -f "${language_file}" ]]; then
    IFS= read -r TUNLET_LANG <"${language_file}"
  else
    TUNLET_LANG="zh"
  fi
fi
if [[ "${1:-}" == "--lang" ]]; then
  [[ "$#" -ge 2 ]] || {
    echo "--lang requires zh or en." >&2
    exit 2
  }
  TUNLET_LANG="$2"
  TUNLET_LANG_EXPLICIT=1
  shift 2
fi
case "${TUNLET_LANG}" in
  zh|en) ;;
  *)
    echo "Language must be zh or en." >&2
    exit 2
    ;;
esac
export TUNLET_LANG
export TUNLET_LANG_EXPLICIT

text() {
  if [[ "${TUNLET_LANG}" == "en" ]]; then
    printf '%s' "$2"
  else
    printf '%s' "$1"
  fi
}

fail() {
  printf '%s%s\n' "$(text '安装失败：' 'Install failed: ')" "$1" >&2
  exit 1
}

cleanup() {
  if [[ -n "${TEMP_DIR}" && "${TEMP_DIR}" == "${TEMP_ROOT}/tunlet-bootstrap."* ]]; then
    rm -rf -- "${TEMP_DIR}"
  fi
}
trap cleanup EXIT INT TERM

[[ "$(uname -s)" == "Darwin" ]] || fail "$(text '需要 macOS。' 'macOS is required.')"
[[ "$(uname -m)" == "arm64" ]] || fail "$(text '需要 Apple 芯片。' 'Apple silicon is required.')"
command -v curl >/dev/null 2>&1 || fail "$(text '缺少 curl。' 'curl is required.')"
command -v tar >/dev/null 2>&1 || fail "$(text '缺少 tar。' 'tar is required.')"

TEMP_DIR="$(mktemp -d "${TEMP_ROOT}/tunlet-bootstrap.XXXXXX")"
archive_path="${TEMP_DIR}/source.tar.gz"

printf '%s\n' "$(text '正在下载 Tunlet…' 'Downloading Tunlet...')"
curl --fail --location --retry 3 --progress-bar \
  "${SOURCE_URL}" --output "${archive_path}"
tar -xzf "${archive_path}" -C "${TEMP_DIR}"

source_dir="$(find "${TEMP_DIR}" -mindepth 1 -maxdepth 1 -type d -name 'tunlet-mac-*' -print -quit)"
[[ -n "${source_dir}" && -x "${source_dir}/tunlet" ]] || \
  fail "$(text '下载的文件不是有效的 Tunlet 源码包。' 'The downloaded archive is not a valid Tunlet source package.')"

"${source_dir}/tunlet" install "$@"

printf '%s\n' "$(text '临时安装文件已清理。' 'Temporary installer files were removed.')"
