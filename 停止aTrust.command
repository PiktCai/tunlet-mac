#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
./scripts/apple-lite-stop.sh
echo
read -r -p "按回车关闭窗口…" _
