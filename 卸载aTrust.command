#!/usr/bin/env bash
cd "$(dirname "$0")" || exit 1
status=0
./scripts/uninstall.sh || status=$?
echo
read -r -p "按回车关闭窗口…" _
exit "${status}"
