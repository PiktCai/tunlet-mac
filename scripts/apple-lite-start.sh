#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${ROOT_DIR}/.local"
TOKEN_FILE="${STATE_DIR}/helper-token"
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
  echo "aTrust Lite 已经在运行。请先双击“停止校园网.command”，再重新启动。"
  exit 0
fi

rm -f "${TOKEN_FILE}"

server_default="${ATRUST_SERVER_DEFAULT:-https://vpn.whu.edu.cn}"
read -r -p "校园网地址 [${server_default}]: " server
server="${server:-${server_default}}"
read -r -p "账号: " username
read -r -s -p "密码（输入时不会显示）: " password
echo

if [[ -z "${username}" || -z "${password}" ]]; then
  echo "账号和密码不能为空。"
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

echo "正在启动 aTrust Lite…"
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
  echo "aTrust Lite 没有按时启动，最近日志如下："
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
    echo "验证码应为 4–8 位数字。"
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
  echo
  echo "连接成功。FlClash 校园网出口：127.0.0.1:11080"
  echo "正在验证武汉大学中文系网页…"
  http_code="$(curl --silent --show-error --location \
    --max-time 30 \
    --socks5-hostname "${HOST_SOCKS}" \
    --output /dev/null \
    --write-out '%{http_code}' \
    'https://chinese.whu.edu.cn/cont_news.jsp?urltype=news.NewsContentUrl&wbtreeid=1060&wbnewsid=34191' || true)"
  echo "目标网页 HTTP 状态：${http_code:-连接失败}"
  echo "请在 FlClash 中切换到“校园网”配置。"
  echo "用完后请双击“停止校园网.command”。"
else
  echo
  echo "尚未连通。容器会保留，便于查看日志和继续排查。"
  echo "最近日志："
  container logs -n 60 "${CONTAINER_NAME}" 2>/dev/null || true
  exit 1
fi
