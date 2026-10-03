#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  init-atrust-runtime.sh --output-root <dir> --atrust-deb <aTrustInstaller.deb> --accept-upstream-license [--sha256 <hex>]
  init-atrust-runtime.sh --output-root <dir> --atrust-url <https-url> --accept-upstream-license [--sha256 <hex>]

This script runs only on the user's build/install host. It extracts the
licensed upstream aTrust .deb locally and creates an atrust-lite runtime root.
The project does not redistribute Sangfor aTrust binaries or prebuilt images
containing them.

Use --skip-dependency-check only when a later packaging layer, such as the slim
Dockerfile, will provide distro shared libraries.
USAGE
}

fail() {
  echo "init-atrust-runtime: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

validate_sha256_arg() {
  [[ "$1" =~ ^[0-9a-fA-F]{64}$ ]] || fail "--sha256 must be a 64-character hex digest"
}

require_runtime_file() {
  local path="$1"
  [[ -f "${path}" ]] || fail "extracted aTrust runtime is missing file: ${path#${OUTPUT_ROOT}}"
}

require_runtime_executable() {
  local path="$1"
  [[ -x "${path}" ]] || fail "extracted aTrust runtime is missing executable: ${path#${OUTPUT_ROOT}}"
}

require_runtime_dir() {
  local path="$1"
  [[ -d "${path}" ]] || fail "extracted aTrust runtime is missing directory: ${path#${OUTPUT_ROOT}}"
}

ATRUST_DEB=""
ATRUST_URL=""
SHA256=""
OUTPUT_ROOT=""
ACCEPT_LICENSE=0
KEEP_TEMP=0
SKIP_DEPENDENCY_CHECK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --atrust-deb)
      [[ $# -ge 2 ]] || fail "--atrust-deb requires a path"
      ATRUST_DEB="$2"
      shift 2
      ;;
    --atrust-url)
      [[ $# -ge 2 ]] || fail "--atrust-url requires a URL"
      ATRUST_URL="$2"
      shift 2
      ;;
    --sha256)
      [[ $# -ge 2 ]] || fail "--sha256 requires a hex digest"
      SHA256="$2"
      shift 2
      ;;
    --output-root)
      [[ $# -ge 2 ]] || fail "--output-root requires a directory"
      OUTPUT_ROOT="$2"
      shift 2
      ;;
    --accept-upstream-license)
      ACCEPT_LICENSE=1
      shift
      ;;
    --keep-temp)
      KEEP_TEMP=1
      shift
      ;;
    --skip-dependency-check)
      SKIP_DEPENDENCY_CHECK=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ "${ACCEPT_LICENSE}" == "1" ]] || fail "pass --accept-upstream-license after confirming your aTrust license permits local extraction"
[[ -n "${OUTPUT_ROOT}" ]] || fail "--output-root is required"
if [[ -n "${ATRUST_DEB}" && -n "${ATRUST_URL}" ]]; then
  fail "use only one of --atrust-deb or --atrust-url"
fi
if [[ -z "${ATRUST_DEB}" && -z "${ATRUST_URL}" ]]; then
  fail "one of --atrust-deb or --atrust-url is required"
fi

need_cmd awk
need_cmd cp
need_cmd find
need_cmd install
need_cmd ldd
need_cmd readlink
need_cmd rm
need_cmd sed
need_cmd sha256sum
need_cmd sort
need_cmd tr

OUTPUT_ROOT="$(readlink -m "${OUTPUT_ROOT}")"
case "${OUTPUT_ROOT}" in
  /|"")
    fail "refusing to initialize unsafe output root: ${OUTPUT_ROOT}"
    ;;
esac

WORK_DIR="$(mktemp -d)"
if [[ "${KEEP_TEMP}" == "1" ]]; then
  echo "init-atrust-runtime: keeping temp directory ${WORK_DIR}" >&2
else
  trap 'rm -rf "${WORK_DIR}"' EXIT
fi

DEB_PATH="${WORK_DIR}/atrust-upstream.deb"
EXTRACT_ROOT="${WORK_DIR}/extract"

if [[ -n "${ATRUST_URL}" ]]; then
  case "${ATRUST_URL}" in
    https://*) ;;
    *) fail "--atrust-url must use https" ;;
  esac
  if command -v curl >/dev/null 2>&1; then
    curl --fail --location --proto '=https' --tlsv1.2 --output "${DEB_PATH}" "${ATRUST_URL}"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "${DEB_PATH}" "${ATRUST_URL}"
  else
    fail "curl or wget is required for --atrust-url"
  fi
else
  [[ -f "${ATRUST_DEB}" ]] || fail "aTrust deb not found: ${ATRUST_DEB}"
  cp -f "${ATRUST_DEB}" "${DEB_PATH}"
fi

if [[ -n "${SHA256}" ]]; then
  validate_sha256_arg "${SHA256}"
  actual_sha256="$(sha256sum "${DEB_PATH}" | awk '{print $1}')"
  if [[ "${actual_sha256,,}" != "${SHA256,,}" ]]; then
    fail "sha256 mismatch: expected ${SHA256}, got ${actual_sha256}"
  fi
fi

extract_deb() {
  local deb="$1"
  local out="$2"
  install -d -m 0755 "${out}"
  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -R "${deb}" "${out}"
    return
  fi

  need_cmd ar
  local ar_dir data_tar
  ar_dir="${WORK_DIR}/ar"
  install -d -m 0755 "${ar_dir}"
  (cd "${ar_dir}" && ar x "${deb}")
  data_tar="$(find "${ar_dir}" -maxdepth 1 -type f -name 'data.tar.*' | sort | head -n 1)"
  [[ -n "${data_tar}" ]] || fail "could not find data.tar.* in deb"
  case "${data_tar}" in
    *.tar.xz) tar -xJf "${data_tar}" -C "${out}" ;;
    *.tar.gz) tar -xzf "${data_tar}" -C "${out}" ;;
    *.tar.zst) tar --use-compress-program=unzstd -xf "${data_tar}" -C "${out}" ;;
    *) fail "unsupported deb data archive: ${data_tar}" ;;
  esac
}

extract_deb "${DEB_PATH}" "${EXTRACT_ROOT}"

ATRUST_ROOT="${EXTRACT_ROOT}/usr/share/sangfor/aTrust"
ATRUST_BIN="${ATRUST_ROOT}/resources/bin"
ATRUST_LIB="${ATRUST_ROOT}/resources/lib"
[[ -d "${ATRUST_ROOT}" ]] || fail "upstream package does not contain /usr/share/sangfor/aTrust"
[[ -d "${ATRUST_BIN}" ]] || fail "upstream package does not contain aTrust resources/bin"

rm -rf "${OUTPUT_ROOT}"
install -d -m 0755 "${OUTPUT_ROOT}"

copy_to_root() {
  local src="$1"
  local dst="${2:-$1}"
  [[ -e "${src}" || -L "${src}" ]] || return 0
  install -d -m 0755 "${OUTPUT_ROOT}$(dirname "${dst}")"
  cp -a "${src}" "${OUTPUT_ROOT}${dst}"
  if [[ -L "${src}" ]]; then
    local target link_value target_dst
    target="$(readlink -f "${src}" 2>/dev/null || true)"
    if [[ -n "${target}" ]]; then
      link_value="$(readlink "${src}")"
      if [[ "${link_value}" = /* ]]; then
        target_dst="${link_value}"
      else
        target_dst="$(readlink -m "$(dirname "${dst}")/${link_value}")"
      fi
      copy_to_root "${target}" "${target_dst}"
    fi
  fi
}

copy_from_extract() {
  local rel="$1"
  copy_to_root "${EXTRACT_ROOT}${rel}" "${rel}"
}

copy_dep() {
  local dep="$1"
  [[ -n "${dep}" ]] || return 0
  case "${dep}" in
    "${EXTRACT_ROOT}"/*)
      copy_to_root "${dep}" "${dep#${EXTRACT_ROOT}}"
      ;;
    /*)
      copy_to_root "${dep}" "${dep}"
      ;;
  esac
}

copy_elf_deps() {
  local elf="$1"
  [[ -e "${elf}" ]] || return 0
  LD_LIBRARY_PATH="${ATRUST_BIN}:${ATRUST_LIB:-}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    ldd "${elf}" 2>/dev/null | \
    awk '/=> \// { print $3 } /^\// { print $1 }' | \
    sort -u | \
    while IFS= read -r dep; do
      copy_dep "${dep}"
    done
}

copy_host_bin() {
  local bin="$1"
  [[ -e "${bin}" || -L "${bin}" ]] || return 0
  copy_to_root "${bin}" "${bin}"
  local resolved
  resolved="$(readlink -f "${bin}" 2>/dev/null || true)"
  if [[ -n "${resolved}" ]]; then
    copy_elf_deps "${resolved}"
  else
    copy_elf_deps "${bin}"
  fi
}

copy_from_extract /usr/share/sangfor/aTrust/resources/bin
if [[ -d "${ATRUST_LIB}" ]]; then
  copy_from_extract /usr/share/sangfor/aTrust/resources/lib
fi

while IFS= read -r elf; do
  copy_elf_deps "${elf}" || true
done < <(
  find "${ATRUST_BIN}" "${ATRUST_LIB}" \
    -type f \( -perm /111 -o -name '*.so' -o -name '*.so.*' \) -print 2>/dev/null || true
)

for bin in \
  /bin/sh \
  /usr/bin/awk \
  /usr/bin/basename \
  /usr/bin/cat \
  /usr/bin/chmod \
  /usr/bin/cp \
  /usr/bin/date \
  /usr/bin/dirname \
  /usr/bin/dpkg-query \
  /usr/bin/env \
  /usr/bin/expr \
  /usr/bin/getent \
  /usr/bin/grep \
  /usr/bin/head \
  /usr/bin/hostname \
  /usr/bin/id \
  /usr/bin/kill \
  /usr/bin/ln \
  /usr/bin/mkdir \
  /usr/bin/mktemp \
  /usr/bin/pkill \
  /usr/bin/pgrep \
  /usr/bin/ps \
  /usr/bin/readlink \
  /usr/bin/rm \
  /usr/bin/sed \
  /usr/bin/sleep \
  /usr/bin/sort \
  /usr/bin/stat \
  /usr/bin/tail \
  /usr/bin/touch \
  /usr/bin/tr \
  /usr/bin/true \
  /usr/bin/uname \
  /usr/bin/wc \
  /usr/bin/xargs \
  /usr/sbin/ip \
  /usr/sbin/iptables \
  /usr/sbin/iptables-save \
  /usr/sbin/iptables-restore \
  /usr/sbin/xtables-legacy-multi \
  /usr/sbin/xtables-nft-multi; do
  copy_host_bin "${bin}"
done

sysctl_bin="$(readlink -f /usr/sbin/sysctl 2>/dev/null || true)"
if [[ -n "${sysctl_bin}" ]]; then
  copy_to_root "${sysctl_bin}" /usr/sbin/sysctl.real
  copy_elf_deps "${sysctl_bin}"
fi

copy_to_root /etc/nsswitch.conf
copy_to_root /etc/ssl/certs
if command -v dpkg-architecture >/dev/null 2>&1; then
  host_multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
else
  case "$(uname -m)" in
    x86_64|amd64) host_multiarch=x86_64-linux-gnu ;;
    aarch64|arm64) host_multiarch=aarch64-linux-gnu ;;
    *) fail "unsupported build architecture: $(uname -m)" ;;
  esac
fi

copy_to_root "/usr/lib/${host_multiarch}/gconv"
copy_to_root /usr/lib/locale/C.utf8
copy_to_root "/usr/lib/${host_multiarch}/libstdc++.so.6"
for loader in \
  /lib64/ld-linux-x86-64.so.2 \
  /lib/ld-linux-aarch64.so.1 \
  "/lib/${host_multiarch}/ld-linux-x86-64.so.2" \
  "/lib/${host_multiarch}/ld-linux-aarch64.so.1"; do
  copy_to_root "${loader}"
done

install -d -m 0755 \
  "${OUTPUT_ROOT}/dev" \
  "${OUTPUT_ROOT}/etc" \
  "${OUTPUT_ROOT}/home/sangfor" \
  "${OUTPUT_ROOT}/opt/atrust-lite" \
  "${OUTPUT_ROOT}/proc" \
  "${OUTPUT_ROOT}/root/.atrust-lite" \
  "${OUTPUT_ROOT}/run" \
  "${OUTPUT_ROOT}/sys" \
  "${OUTPUT_ROOT}/tmp" \
  "${OUTPUT_ROOT}/usr/bin" \
  "${OUTPUT_ROOT}/usr/local/bin" \
  "${OUTPUT_ROOT}/usr/sbin" \
  "${OUTPUT_ROOT}/var/lib/dbus"
chmod 1777 "${OUTPUT_ROOT}/tmp"

printf '0123456789abcdef0123456789abcdef\n' >"${OUTPUT_ROOT}/etc/machine-id"
cp "${OUTPUT_ROOT}/etc/machine-id" "${OUTPUT_ROOT}/var/lib/dbus/machine-id"
printf 'root:x:0:0:root:/root:/bin/sh\nsangfor:x:1234:1234:sangfor:/home/sangfor:/bin/sh\n' >"${OUTPUT_ROOT}/etc/passwd"
printf 'root:x:0:\nsangfor:x:1234:\n' >"${OUTPUT_ROOT}/etc/group"
printf 'localhost\n' >"${OUTPUT_ROOT}/etc/hostname"
printf '127.0.0.1 localhost\n' >"${OUTPUT_ROOT}/etc/hosts"
printf 'legacy\n' >"${OUTPUT_ROOT}/etc/iptables-type"
chown -R 1234:1234 "${OUTPUT_ROOT}/home/sangfor" 2>/dev/null || true

cat >"${OUTPUT_ROOT}/usr/bin/loginctl" <<'EOF'
#!/bin/sh
if [ "$*" = "--no-legend list-sessions" ]; then
  echo 10644 1234 sangfor seat0
  exit 0
fi
if [ "$1" = show-session ]; then
  cat <<SESSION
Id=10644
User=1234
Name=sangfor
Timestamp=Mon 2023-03-06 14:52:44 CST
TimestampMonotonic=1097012996679
VTNr=7
Seat=seat0
Display=:1
Remote=no
Service=sddm
Desktop=KDE
Scope=session-10644.scope
Leader=2268286
Audit=10644
Type=x11
Class=user
Active=yes
State=active
IdleHint=no
IdleSinceHint=0
IdleSinceHintMonotonic=0
LockedHint=no
SESSION
  exit 0
fi
exit 1
EOF
chmod 0755 "${OUTPUT_ROOT}/usr/bin/loginctl"

cat >"${OUTPUT_ROOT}/usr/bin/systemctl" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 "${OUTPUT_ROOT}/usr/bin/systemctl"

cat >"${OUTPUT_ROOT}/usr/local/bin/detect-iptables.sh" <<'EOF'
#!/bin/sh
set -eu
iptables_type=legacy
if [ -z "${IPTABLES_LEGACY:-}" ] &&
   [ -z "$(xtables-legacy-multi iptables-save 2>/dev/null || true)" ] &&
   xtables-nft-multi iptables-save >/dev/null 2>&1 &&
   xtables-nft-multi iptables -A INPUT -j ACCEPT >/dev/null 2>&1 &&
   xtables-nft-multi iptables -D INPUT -j ACCEPT >/dev/null 2>&1; then
  iptables_type=nft
fi
echo "$iptables_type" >/etc/iptables-type
for exec in \
  /usr/sbin/iptables /usr/sbin/iptables-legacy /usr/sbin/iptables-nft \
  /usr/sbin/iptables-save /usr/sbin/iptables-legacy-save /usr/sbin/iptables-nft-save \
  /usr/sbin/iptables-restore /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-nft-restore; do
  ln -sf /usr/sbin/xtables-echook-multi "$exec"
done
echo "export ECHACK_NOWARN=1"
EOF
chmod 0755 "${OUTPUT_ROOT}/usr/local/bin/detect-iptables.sh"

cat >"${OUTPUT_ROOT}/usr/local/bin/detect-route.sh" <<'EOF'
#!/bin/sh
set -eu
if command -v ip >/dev/null 2>&1; then
  ip route flush table 2 >/dev/null 2>&1 || true
  ip route show | while IFS= read -r route; do
    [ -n "$route" ] && ip route add $route table 2 >/dev/null 2>&1 || true
  done
  if [ -n "${VPN_TUN:-}" ]; then
    ip rule add iif "$VPN_TUN" table 2 >/dev/null 2>&1 || true
  fi
  ip rule add iif lo table 2 sport 1080 >/dev/null 2>&1 || true
  if ip rule show iif lo table 2 2>/dev/null | grep sport >/dev/null 2>&1; then
    echo 'open_port() { ip rule add iif lo table 2 sport "$1" >/dev/null 2>&1 || true; }'
    echo 'close_port() { ip rule del iif lo table 2 sport "$1" >/dev/null 2>&1 || true; }'
    ip rule del iif lo sport 1080 table 2 >/dev/null 2>&1 || true
    exit 0
  fi
fi
echo 'open_port() { true; }'
echo 'close_port() { true; }'
EOF
chmod 0755 "${OUTPUT_ROOT}/usr/local/bin/detect-route.sh"

cat >"${OUTPUT_ROOT}/usr/sbin/xtables-echook-multi" <<'EOF'
#!/bin/sh
name="$(basename "$0")"
iptables_type="$(cat /etc/iptables-type 2>/dev/null || echo legacy)"
xtables_multi="xtables-${iptables_type}-multi"

if [ -z "${ECHACK_NOWARN:-}" ]; then
  echo "# warning: using ${iptables_type} iptables through aTrust lite hook" >&2
fi

case "$name" in
  iptables|iptables-legacy|iptables-nft)
    [ "$*" = "-t filter -A SANGFOR_VIRTUAL -j DROP" ] && exit 0
    subcommand=iptables
    ;;
  iptables-save|iptables-nft-save|iptables-legacy-save)
    subcommand=iptables-save
    ;;
  iptables-restore|iptables-nft-restore|iptables-legacy-restore)
    sed -E 's/ -j DNAT --to-destination 127\.0\.0\.1:4440$/ -j REDIRECT --to-ports 4440/' | "$xtables_multi" iptables-restore "$@"
    exit $?
    ;;
  *)
    echo "unknown xtables hook subcommand: $name" >&2
    exit 1
    ;;
esac

exec "$xtables_multi" "$subcommand" "$@"
EOF
chmod 0755 "${OUTPUT_ROOT}/usr/sbin/xtables-echook-multi"

cat >"${OUTPUT_ROOT}/usr/sbin/sysctl-hook" <<'EOF'
#!/bin/sh
if [ "x$*" = "x-w net.ipv4.conf.utun7.route_localnet=1" ]; then
  if [ "$(/usr/sbin/sysctl.real -n net.ipv4.conf.utun7.route_localnet 2>/dev/null || echo 0)" = "1" ] ||
     /usr/sbin/sysctl.real "$@"; then
    exit 0
  fi
  exit 1
fi
exec /usr/sbin/sysctl.real "$@"
EOF
chmod 0755 "${OUTPUT_ROOT}/usr/sbin/sysctl-hook"

ln -sf /usr/sbin/sysctl-hook "${OUTPUT_ROOT}/usr/sbin/sysctl"
for exec in \
  /usr/sbin/iptables /usr/sbin/iptables-legacy /usr/sbin/iptables-nft \
  /usr/sbin/iptables-save /usr/sbin/iptables-legacy-save /usr/sbin/iptables-nft-save \
  /usr/sbin/iptables-restore /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-nft-restore; do
  ln -sf /usr/sbin/xtables-echook-multi "${OUTPUT_ROOT}${exec}"
done
for exec in \
  /usr/sbin/ip6tables /usr/sbin/ip6tables-legacy /usr/sbin/ip6tables-save \
  /usr/sbin/ip6tables-legacy-save /usr/sbin/ip6tables-restore \
  /usr/sbin/ip6tables-legacy-restore; do
  ln -sf /usr/sbin/xtables-legacy-multi "${OUTPUT_ROOT}${exec}"
done
for exec in \
  /usr/sbin/ip6tables-nft /usr/sbin/ip6tables-nft-save /usr/sbin/ip6tables-nft-restore; do
  ln -sf /usr/sbin/xtables-nft-multi "${OUTPUT_ROOT}${exec}"
done

find "${OUTPUT_ROOT}/usr/share/sangfor/aTrust" -type d -name app -prune -exec rm -rf {} + 2>/dev/null || true
find "${OUTPUT_ROOT}/usr/share/sangfor/aTrust" -type d -name shell -prune -exec rm -rf {} + 2>/dev/null || true
find "${OUTPUT_ROOT}/usr/share/sangfor/aTrust" -type d -name uem -prune -exec rm -rf {} + 2>/dev/null || true
rm -rf \
  "${OUTPUT_ROOT}/usr/share/sangfor/aTrust/locales" \
  "${OUTPUT_ROOT}/usr/share/sangfor/aTrust/swiftshader" \
  "${OUTPUT_ROOT}/usr/share/sangfor/aTrust/resources/app" \
  "${OUTPUT_ROOT}/usr/share/sangfor/aTrust/resources/shell" \
  "${OUTPUT_ROOT}/usr/share/sangfor/aTrust/resources/lib/libstdc++.so.6"

# Debian bookworm uses a merged-/usr layout. Recreate it in the scratch image
# so relative links such as /bin/sh -> dash and /lib/.../*.so -> *.so.X keep
# resolving after files are copied out of the builder stage.
for top_dir in bin lib sbin; do
  if [[ -d "${OUTPUT_ROOT}/${top_dir}" && ! -L "${OUTPUT_ROOT}/${top_dir}" ]]; then
    install -d -m 0755 "${OUTPUT_ROOT}/usr/${top_dir}"
    cp -a "${OUTPUT_ROOT}/${top_dir}/." "${OUTPUT_ROOT}/usr/${top_dir}/"
    rm -rf "${OUTPUT_ROOT:?}/${top_dir}"
    ln -s "usr/${top_dir}" "${OUTPUT_ROOT}/${top_dir}"
  fi
done

require_runtime_executable "${OUTPUT_ROOT}/usr/share/sangfor/aTrust/resources/bin/aTrustAgent"
require_runtime_executable "${OUTPUT_ROOT}/usr/share/sangfor/aTrust/resources/bin/aTrustXtunnel-64"
require_runtime_file "${OUTPUT_ROOT}/usr/share/sangfor/aTrust/resources/bin/libaTrustSDK.so"
require_runtime_file "${OUTPUT_ROOT}/usr/share/sangfor/aTrust/resources/bin/plugins/aTrustCore/libaTrustCore.so"
require_runtime_dir "${OUTPUT_ROOT}/usr/share/sangfor/aTrust/resources/bin/plugins/aTrustCore"

verify_runtime_deps() {
  local runtime_ld_path missing
  runtime_ld_path="${OUTPUT_ROOT}/usr/share/sangfor/aTrust:${OUTPUT_ROOT}/usr/share/sangfor/aTrust/resources/bin:${OUTPUT_ROOT}/usr/share/sangfor/aTrust/resources/lib"
  missing="$(
    LD_LIBRARY_PATH="${runtime_ld_path}" \
      ldd \
        "${OUTPUT_ROOT}/usr/share/sangfor/aTrust/resources/bin/libaTrustSDK.so" \
        "${OUTPUT_ROOT}/usr/share/sangfor/aTrust/resources/bin/plugins/aTrustCore/libaTrustCore.so" \
        "${OUTPUT_ROOT}/usr/share/sangfor/aTrust/resources/bin/aTrustAgent" \
        "${OUTPUT_ROOT}/usr/share/sangfor/aTrust/resources/bin/aTrustXtunnel-64" \
        2>/dev/null | \
        awk '$2 == "=>" && $3 == "not" && $4 == "found" { print $1 }' | \
        sort -u
  )"
  if [[ -n "${missing}" ]]; then
    cat >&2 <<EOF
init-atrust-runtime: missing shared libraries after extraction:
${missing}

Install the distro runtime libraries on this build host and run this script
again so they can be copied into the runtime root. Common Debian/Ubuntu package
names for recent aTrust builds:
  libx11-6 libxtst6 libproxy1v5 libharfbuzz0b libgl1

For the slim Docker image path, the Dockerfile provides these libraries; pass
--skip-dependency-check only for that packaging layer.
EOF
    exit 1
  fi
}

if [[ "${SKIP_DEPENDENCY_CHECK}" != "1" ]]; then
  verify_runtime_deps
fi

echo "created local aTrust lite runtime root: ${OUTPUT_ROOT}"
