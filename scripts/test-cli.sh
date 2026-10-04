#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/ui.sh"

assert_equal() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "${label}: expected '${expected}', got '${actual}'" >&2
    exit 1
  fi
}

assert_equal \
  "https://vpn.example.edu.cn" \
  "$(tunlet_normalize_server 'vpn.example.edu.cn')" \
  "missing scheme"
assert_equal \
  "https://vpn.example.edu.cn" \
  "$(tunlet_normalize_server ' https://vpn.example.edu.cn ')" \
  "existing HTTPS scheme"
assert_equal \
  "http://vpn.example.edu.cn:8080" \
  "$(tunlet_normalize_server 'http://vpn.example.edu.cn:8080')" \
  "existing HTTP scheme"
assert_equal \
  "https://vpn.example.edu.cn" \
  "$(tunlet_normalize_server 'HTTPS://vpn.example.edu.cn')" \
  "uppercase HTTPS scheme"

if tunlet_normalize_server 'ftp://vpn.example.edu.cn' >/dev/null; then
  echo "unsupported scheme was accepted" >&2
  exit 1
fi
if tunlet_normalize_server '   ' >/dev/null; then
  echo "empty server was accepted" >&2
  exit 1
fi

TUNLET_LANG=zh
tunlet_init_language
assert_equal "连接" "$(tunlet_text '连接' 'Connect')" "Chinese language"
TUNLET_LANG=en
tunlet_init_language
assert_equal "Connect" "$(tunlet_text '连接' 'Connect')" "English language"

test_temp_root="${TMPDIR:-/tmp}"
test_temp_root="${test_temp_root%/}"
test_state="$(mktemp -d "${test_temp_root}/tunlet-cli-test.XXXXXX")"
cleanup() {
  case "${test_state}" in
    "${test_temp_root}"/tunlet-cli-test.*) rm -rf -- "${test_state}" ;;
  esac
}
trap cleanup EXIT INT TERM

unset TUNLET_LANG TUNLET_LANG_EXPLICIT
chinese_help="$(TUNLET_STATE_DIR="${test_state}" "${ROOT_DIR}/tunlet" help)"
[[ "${chinese_help}" == *'用法：tunlet'* ]] || {
  echo "default help is not Chinese" >&2
  exit 1
}

TUNLET_STATE_DIR="${test_state}" "${ROOT_DIR}/tunlet" language en >/dev/null
english_help="$(TUNLET_STATE_DIR="${test_state}" "${ROOT_DIR}/tunlet" help)"
[[ "${english_help}" == *'Usage: tunlet'* ]] || {
  echo "saved English language was not applied" >&2
  exit 1
}

chinese_override="$(TUNLET_STATE_DIR="${test_state}" "${ROOT_DIR}/tunlet" --lang zh help)"
[[ "${chinese_override}" == *'用法：tunlet'* ]] || {
  echo "Chinese language override was not applied" >&2
  exit 1
}

echo "Tunlet CLI regression test passed."
