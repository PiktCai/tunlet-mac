#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE_NAME="atrust-lite-runtime:local-arm64"
ATRUST_VERSION="2.5.16.20"
ATRUST_URL="https://atrustcdn.sangfor.com/standard/linux/${ATRUST_VERSION}/uos/arm64/aTrustInstaller_arm64.deb"
ATRUST_SHA256="c8c0c0add77c21abb72ae912b1ac01c2cad6cf0fc439a4b64545100153b0cf31"
TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_ROOT="${TEMP_ROOT%/}"
TEMP_DIR=""
STARTED_SYSTEM=0
BUILD_STARTED=0
PACKAGE_PATH=""

fail() {
  echo "安装失败：$*" >&2
  exit 1
}

cleanup() {
  if [[ "${BUILD_STARTED}" == 1 ]]; then
    container builder stop >/dev/null 2>&1 || true
    container builder delete >/dev/null 2>&1 || true
  fi
  if [[ "${STARTED_SYSTEM}" == 1 ]] &&
     [[ "$(container list --format json 2>/dev/null || true)" == "[]" ]]; then
    container system stop >/dev/null 2>&1 || true
  fi
  if [[ -n "${TEMP_DIR}" && "${TEMP_DIR}" == "${TEMP_ROOT}/atrust-lite-setup."* ]]; then
    rm -rf "${TEMP_DIR}"
  fi
}
trap cleanup EXIT INT TERM

[[ "$(uname -s)" == "Darwin" ]] || fail "只支持 macOS。"
[[ "$(uname -m)" == "arm64" ]] || fail "只支持 Apple Silicon Mac。"

for command_name in container curl shasum; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    if [[ "${command_name}" == "container" ]]; then
      fail "缺少 Apple Container，请先安装：https://github.com/apple/container/releases/latest"
    fi
    fail "缺少命令：${command_name}"
  }
done

download_official_package() {
  local output="$1"
  echo "正在从深信服官方 CDN 下载 aTrust ${ATRUST_VERSION} ARM64…"
  if ! curl --fail --location --retry 3 --progress-bar \
    "${ATRUST_URL}" --output "${output}"; then
    if [[ "${http_proxy:-}${https_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}" == *"127.0.0.1"* ]]; then
      echo "本机代理不可用，尝试直连下载…"
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
    fail "安装包校验失败，已删除下载文件。"
  }
  echo "安装包校验通过。"
}

select_local_package() {
  local selected
  read -r -p "请把 ARM64 的 .deb 或 .zip 文件拖到这里，然后按回车：" selected
  selected="${selected#\'}"
  selected="${selected%\'}"
  selected="${selected#\"}"
  selected="${selected%\"}"
  selected="${selected//\\ / }"
  printf '%s\n' "${selected}"
}

prepare_package() {
  local source="$1"
  [[ -f "${source}" ]] || fail "找不到安装包：${source}"

  case "${source}" in
    *.zip|*.ZIP)
      command -v unzip >/dev/null 2>&1 || fail "缺少 unzip，无法解压安装包。"
      [[ -n "${TEMP_DIR}" ]] || TEMP_DIR="$(mktemp -d "${TEMP_ROOT}/atrust-lite-setup.XXXXXX")"
      unzip -q "${source}" -d "${TEMP_DIR}/package"
      local extracted
      extracted="$(find "${TEMP_DIR}/package" -type f -name 'aTrustInstaller_arm64.deb' -print -quit)"
      [[ -n "${extracted}" ]] || fail "压缩包中没有 aTrustInstaller_arm64.deb。"
      PACKAGE_PATH="${extracted}"
      ;;
    *.deb|*.DEB)
      PACKAGE_PATH="${source}"
      ;;
    *)
      fail "安装包必须是 ARM64 .deb，或包含该文件的 .zip。"
      ;;
  esac
}

[[ "$#" -le 1 ]] || fail "用法：./scripts/setup.sh [ARM64 安装包路径]"

package_source="${1:-}"
if [[ -z "${package_source}" ]]; then
  echo "请选择安装包来源："
  echo "  1. 从深信服官方 CDN 下载已验证版本 ${ATRUST_VERSION}"
  echo "  2. 使用本地安装包"
  read -r -p "选择 [1]：" choice
  choice="${choice:-1}"
  case "${choice}" in
    1)
      TEMP_DIR="$(mktemp -d "${TEMP_ROOT}/atrust-lite-setup.XXXXXX")"
      package_source="${TEMP_DIR}/aTrustInstaller_arm64.deb"
      download_official_package "${package_source}"
      ;;
    2)
      package_source="$(select_local_package)"
      ;;
    *)
      fail "无效选择。"
      ;;
  esac
fi

prepare_package "${package_source}"

if ! container system status >/dev/null 2>&1; then
  container system start
  STARTED_SYSTEM=1
fi

if container image list | awk \
  '$1 == "atrust-lite-runtime" && $2 == "local-arm64" { found = 1 } END { exit !found }'; then
  read -r -p "本机已有 Tunlet 镜像，是否重新构建？[y/N] " rebuild
  case "${rebuild:-n}" in
    y|Y|yes|YES) ;;
    *)
      echo "保留现有镜像，未做修改。"
      exit 0
      ;;
  esac
fi

BUILD_STARTED=1
"${ROOT_DIR}/scripts/build-apple-arm64.sh" "${PACKAGE_PATH}"
"${ROOT_DIR}/scripts/test-apple-arm64-runtime.sh"

echo
echo "安装完成。运行 ./tunlet start 即可连接。"
