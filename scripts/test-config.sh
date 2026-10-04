#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_PATH="${1:-${SCRIPT_DIR}/../tunlet.yaml}"

[[ -f "${CONFIG_PATH}" ]] || {
  echo "Config not found: ${CONFIG_PATH}" >&2
  exit 1
}

proxy_names="$({
  awk '
    /^proxies:/ { section = "proxies"; next }
    /^proxy-groups:/ { section = "groups"; next }
    /^[^[:space:]]/ { section = "" }
    section == "proxies" && /^  - name:/ {
      sub(/^  - name:[[:space:]]*/, "")
      print
    }
  ' "${CONFIG_PATH}"
} || true)"

group_names="$({
  awk '
    /^proxy-groups:/ { section = "groups"; next }
    /^[^[:space:]]/ { section = "" }
    section == "groups" && /^  - name:/ {
      sub(/^  - name:[[:space:]]*/, "")
      print
    }
  ' "${CONFIG_PATH}"
} || true)"

while IFS= read -r group_name; do
  [[ -n "${group_name}" ]] || continue
  if printf '%s\n' "${proxy_names}" | grep -Fxq -- "${group_name}"; then
    echo "Proxy and proxy group share the name '${group_name}'." >&2
    exit 1
  fi
done <<EOF
${group_names}
EOF

awk '
  /^proxy-groups:/ { in_groups = 1; next }
  in_groups && /^[^[:space:]]/ { in_groups = 0; in_members = 0 }
  in_groups && /^  - name:/ {
    group = $0
    sub(/^  - name:[[:space:]]*/, "", group)
    in_members = 0
    next
  }
  in_groups && /^    proxies:/ { in_members = 1; next }
  in_groups && in_members && /^      - / {
    member = $0
    sub(/^      -[[:space:]]*/, "", member)
    if (member == group) {
      printf "Proxy group '%s' references itself.\n", group > "/dev/stderr"
      failed = 1
    }
    next
  }
  in_groups && in_members && /^[[:space:]]{4}[^[:space:]]/ { in_members = 0 }
  END { exit failed }
' "${CONFIG_PATH}"

echo "Tunlet config regression test passed."
