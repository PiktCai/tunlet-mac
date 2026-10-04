#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${ROOT_DIR}/.local"
CONTAINER_NAME="atrust-lite"
IMAGE_NAME="atrust-lite-runtime:local-arm64"
DRY_RUN=0
ASSUME_YES=0
INCLUDE_BUILDER=0

usage() {
  cat <<'USAGE'
用法：./scripts/uninstall.sh [选项]

删除本项目创建的容器、镜像、本地状态和遗留临时文件。

选项：
  --dry-run          只显示将要删除的内容
  --yes              不再询问确认
  --include-builder  同时删除 Apple Container 共享构建器缓存
  -h, --help         显示帮助
USAGE
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    --include-builder) INCLUDE_BUILDER=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知选项：$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

[[ "$(uname -s)" == "Darwin" ]] || {
  echo "此脚本只支持 macOS。" >&2
  exit 1
}

echo "将清理以下内容："
echo "  - 容器：${CONTAINER_NAME}"
echo "  - 镜像：${IMAGE_NAME}"
echo "  - 本地状态：${STATE_DIR}"
echo "  - 本项目遗留在系统临时目录中的文件"
if [[ "${INCLUDE_BUILDER}" == 1 ]]; then
  echo "  - Apple Container 共享构建器缓存"
  echo
  echo "注意：共享构建器可能也被其他项目使用，删除后需要重新创建。"
fi
echo
echo "不会卸载 Apple Container，也不会删除其他容器或镜像。"

if [[ "${DRY_RUN}" == 1 ]]; then
  echo
  echo "当前为预览模式，没有删除任何内容。"
  exit 0
fi

if [[ "${ASSUME_YES}" != 1 ]]; then
  read -r -p "确认继续？请输入 DELETE：" confirmation
  [[ "${confirmation}" == "DELETE" ]] || {
    echo "已取消。"
    exit 0
  }
fi

cleanup_temp_root() {
  local temp_root="$1"
  local candidate

  [[ -d "${temp_root}" ]] || return 0
  while IFS= read -r -d '' candidate; do
    case "${candidate}" in
      "${temp_root}"/atrust-lite.*|"${temp_root}"/atrust-lite-setup.*)
        rm -rf -- "${candidate}"
        ;;
    esac
  done < <(
    find "${temp_root}" -mindepth 1 -maxdepth 1 -type d \
      \( -name 'atrust-lite.*' -o -name 'atrust-lite-setup.*' \) \
      -print0 2>/dev/null
  )
}

if command -v container >/dev/null 2>&1; then
  container_ready=1
  if ! container system status >/dev/null 2>&1; then
    if ! container system start >/dev/null; then
      container_ready=0
      echo "Apple Container 无法启动，跳过容器和镜像清理。" >&2
    fi
  fi

  if [[ "${container_ready}" == 1 ]]; then
    container stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    container delete --force "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    container image delete --force "${IMAGE_NAME}" >/dev/null 2>&1 || true

    if [[ "${INCLUDE_BUILDER}" == 1 ]]; then
      container builder delete --force >/dev/null 2>&1 || true
    fi

    if [[ "$(container list --format json 2>/dev/null || true)" == "[]" ]]; then
      container system stop >/dev/null 2>&1 || true
    fi
  fi
else
  echo "未找到 Apple Container，跳过容器和镜像清理。"
fi

if [[ "${STATE_DIR}" == "${ROOT_DIR}/.local" ]]; then
  rm -rf -- "${STATE_DIR}"
fi

temp_root="${TMPDIR:-/tmp}"
temp_root="${temp_root%/}"
cleanup_temp_root "${temp_root}"
if [[ "${temp_root}" != "/tmp" ]]; then
  cleanup_temp_root "/tmp"
fi

echo "清理完成。项目源码和 Apple Container 程序仍然保留。"
