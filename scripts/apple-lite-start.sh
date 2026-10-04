#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${ROOT_DIR}/.local"
TOKEN_FILE="${STATE_DIR}/helper-token"
SERVER_FILE="${STATE_DIR}/server"
USERNAME_FILE="${STATE_DIR}/username"
CONTAINER_NAME="atrust-lite"
IMAGE_NAME="atrust-lite-runtime:local-arm64"
HOST_HELPER_URL="http://127.0.0.1:54680"
HOST_SOCKS="127.0.0.1:11080"

for command_name in container curl openssl; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "缺少命令：${command_name}"
    exit 1
  }
done

mkdir -p "${STATE_DIR}"
chmod 700 "${STATE_DIR}"

container system status >/dev/null 2>&1 || container system start

if container list --all --format json | grep -q '"id":"atrust-lite"'; then
  echo "Tunlet 已经在运行。请先停止现有连接，再重新启动。"
  exit 0
fi

rm -f "${TOKEN_FILE}"

server_default="${ATRUST_SERVER_DEFAULT:-}"
if [[ -z "${server_default}" && -f "${SERVER_FILE}" ]]; then
  IFS= read -r server_default <"${SERVER_FILE}"
fi
if [[ -n "${server_default}" ]]; then
  read -r -p "aTrust 服务器 [${server_default}]: " server
  server="${server:-${server_default}}"
else
  read -r -p "aTrust 服务器: " server
fi
username_default="${ATRUST_USERNAME_DEFAULT:-}"
if [[ -z "${username_default}" && -f "${USERNAME_FILE}" ]]; then
  IFS= read -r username_default <"${USERNAME_FILE}"
fi
if [[ -n "${username_default}" ]]; then
  read -r -p "账号 [${username_default}]: " username
  username="${username:-${username_default}}"
else
  read -r -p "账号: " username
fi
read -r -s -p "密码（输入时不会显示）: " password
echo

if [[ -z "${server}" || -z "${username}" || -z "${password}" ]]; then
  echo "服务器地址、账号和密码不能为空。"
  exit 1
fi

helper_token="$(openssl rand -hex 24)"
secret_dir="$(mktemp -d "${TMPDIR:-/tmp}/atrust-lite.XXXXXX")"
cleanup_secret() {
  rm -f "${secret_dir}/helper.env"
  rmdir "${secret_dir}" 2>/dev/null || true
}
trap cleanup_secret EXIT INT TERM

umask 077
{
  printf 'ATRUST_SERVER=%s\n' "${server}"
  printf 'ATRUST_USERNAME=%s\n' "${username}"
  printf 'ATRUST_PASSWORD=%s\n' "${password}"
  printf 'ATRUST_HELPER_TOKEN=%s\n' "${helper_token}"
} >"${secret_dir}/helper.env"

echo "正在启动 Tunlet…"
container run --detach --rm \
  --name "${CONTAINER_NAME}" \
  --cap-add NET_ADMIN \
  --cpus 2 \
  --memory 2G \
  --mount "type=bind,source=${secret_dir},target=/run/atrust-secrets,readonly" \
  --env ATRUST_HELPER_ENV_FILE=/run/atrust-secrets/helper.env \
  --env ATRUST_HELPER_BIND=0.0.0.0 \
  --publish "127.0.0.1:54680:54680" \
  --publish "127.0.0.1:11080:1080" \
  "${IMAGE_NAME}" >/dev/null

ready=0
for _ in $(seq 1 30); do
  if curl --fail --silent \
    --header "Authorization: Bearer ${helper_token}" \
    "${HOST_HELPER_URL}/status" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done

if [[ "${ready}" != 1 ]]; then
  echo "Tunlet 没有按时启动，最近日志如下："
  container logs -n 80 "${CONTAINER_NAME}" 2>/dev/null || true
  container stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  exit 1
fi

# The supervisor has loaded the credentials into memory. Remove the temporary
# host file before any login request is sent; nothing is saved in the project.
cleanup_secret
unset password
printf '%s\n' "${helper_token}" >"${TOKEN_FILE}"
chmod 600 "${TOKEN_FILE}"

echo "正在登录…"
response="$(curl --fail --silent --show-error \
  --request POST \
  --header "Authorization: Bearer ${helper_token}" \
  "${HOST_HELPER_URL}/connect")"
printf '%s\n' "${response}"

if [[ "${response}" == *'"pendingSms":true'* ]]; then
  read -r -p "短信验证码: " sms_code
  if [[ ! "${sms_code}" =~ ^[0-9]{4,8}$ ]]; then
    echo "验证码应为 4 至 8 位数字。"
    exit 1
  fi
  response="$(curl --fail --silent --show-error \
    --request POST \
    --header "Authorization: Bearer ${helper_token}" \
    --header 'Content-Type: application/json' \
    --data "{\"smsCode\":\"${sms_code}\"}" \
    "${HOST_HELPER_URL}/submit-sms")"
  printf '%s\n' "${response}"
fi

if [[ "${response}" == *'"connected":true'* ]]; then
  printf '%s\n' "${server}" >"${SERVER_FILE}"
  printf '%s\n' "${username}" >"${USERNAME_FILE}"
  chmod 600 "${SERVER_FILE}" "${USERNAME_FILE}"
  echo
  echo "连接成功。SOCKS5 代理：${HOST_SOCKS}"
else
  echo
  echo "尚未连通。容器会保留，便于查看日志和继续排查。"
  echo "最近日志："
  container logs -n 60 "${CONTAINER_NAME}" 2>/dev/null || true
  exit 1
fi
