#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
[[ "$(cat /proc/1/comm 2>/dev/null)" == systemd ]] || { echo 'SKIP: PID 1 no es systemd'; exit 77; }

TMP="$(mktemp -d)"
cleanup() {
  systemctl stop sysdiag-ci-fail.service sysdiag-ci-restart.service >/dev/null 2>&1 || true
  systemctl reset-failed sysdiag-ci-fail.service sysdiag-ci-restart.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/sysdiag-ci-fail.service /etc/systemd/system/sysdiag-ci-restart.service
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

cat >/etc/systemd/system/sysdiag-ci-fail.service <<'UNIT'
[Unit]
Description=SYSdiag CI intentional failure
[Service]
Type=oneshot
ExecStart=/bin/false
UNIT

cat >/etc/systemd/system/sysdiag-ci-restart.service <<'UNIT'
[Unit]
Description=SYSdiag CI intentional restart loop
StartLimitIntervalSec=30
StartLimitBurst=3
[Service]
Type=simple
ExecStart=/bin/false
Restart=on-failure
RestartSec=1
UNIT

systemctl daemon-reload
systemctl start sysdiag-ci-fail.service >/dev/null 2>&1 || true
systemctl start sysdiag-ci-restart.service >/dev/null 2>&1 || true
sleep 5

"$BASE_DIR/sysdiag.sh" --section systemd --verbose --explain --no-color >"$TMP/systemd.txt"
grep -q '^SYSTEMD / SERVICIOS$' "$TMP/systemd.txt"
grep -q 'sysdiag-ci-fail.service' "$TMP/systemd.txt"
grep -Eq 'start-limit|repeated too quickly|restart' "$TMP/systemd.txt"

"$BASE_DIR/sysdiag.sh" --section boot --verbose --explain --no-color >"$TMP/boot.txt"
grep -q '^BOOT / ARRANQUE$' "$TMP/boot.txt"
grep -q 'systemd-analyze disponible:.*sí' "$TMP/boot.txt"
grep -q 'Lectura de fstab:.*sí' "$TMP/boot.txt"

"$BASE_DIR/sysdiag.sh" --all --json >"$TMP/all.json"
python3 - "$TMP/all.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1],encoding='utf-8'))
assert x['metrics']['systemd']['pid1_is_systemd'] is True
assert x['metrics']['systemd']['failed_units'] >= 1
assert x['metrics']['boot']['representative_of_host'] is True
PY

echo "PASS: live systemd integration on $(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")"
