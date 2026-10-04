#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${1:-tunlet-runtime:local-arm64}"

container run --rm \
  --cap-add NET_ADMIN \
  --entrypoint /bin/sh \
  "${IMAGE_NAME}" \
  -c '
    set -eu
    test ! -e /usr/share/sangfor/aTrust/resources/lib/libstdc++.so.6
    test -e /usr/lib/aarch64-linux-gnu/libstdc++.so.6
    test -e /usr/local/lib/fake-getlogin.so
    cd /usr/share/sangfor/aTrust/resources/bin
    FAKE_LOGIN=sangfor \
      LD_PRELOAD=/usr/local/lib/fake-getlogin.so \
      LD_LIBRARY_PATH=/usr/share/sangfor/aTrust:/usr/share/sangfor/aTrust/resources/bin \
      ./aTrustAgent --plugin plugins/aTrustCore --enable-http --enable-event-center \
        >/tmp/core-smoke.log 2>&1 &
    core_pid=$!
    sleep 3
    kill -0 "${core_pid}"
    kill "${core_pid}"
    wait "${core_pid}" 2>/dev/null || true
  '

echo "Tunlet runtime regression test passed"
