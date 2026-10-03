#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOKEN_FILE="${ROOT_DIR}/.local/helper-token"
CONTAINER_NAME="atrust-lite"

if [[ -f "${TOKEN_FILE}" ]]; then
  helper_token="$(cat "${TOKEN_FILE}")"
  curl --silent --max-time 5 \
    --request POST \
    --header "Authorization: Bearer ${helper_token}" \
    "http://127.0.0.1:54680/disconnect" >/dev/null 2>&1 || true
fi

container stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
rm -f "${TOKEN_FILE}"

if [[ "$(container list --format json 2>/dev/null)" == "[]" ]]; then
  container system stop >/dev/null 2>&1 || true
fi
echo "aTrust Lite 已停止。Clash 没有被修改。"
