#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
./scripts/apple-lite-start.sh
echo
read -r -p "按回车关闭窗口…" _
