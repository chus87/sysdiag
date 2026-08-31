#!/usr/bin/env bash
set -euo pipefail
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends bash coreutils util-linux procps iproute2 sysstat lsof jq python3 shellcheck
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y bash coreutils util-linux procps-ng iproute sysstat lsof jq python3 || true
  dnf install -y ShellCheck || dnf install -y shellcheck || true
fi
chmod +x /opt/sysdiag/sysdiag.sh /opt/sysdiag/build-standalone.sh /opt/sysdiag/tests/*.sh /opt/sysdiag/tests/integration/*.sh
cd /opt/sysdiag
find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
./tests/run.sh
