#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export TEST_TMP_ROOT="$TMP"

for test in \
  test_core.sh \
  test_filesystem.sh \
  test_network.sh \
  test_logging.sh \
  test_systemd.sh \
  test_boot.sh \
  test_containers.sh \
  test_kubernetes.sh \
  test_json.sh \
  test_readonly.sh \
  test_cli.sh \
  test_standalone.sh \
  test_shellcheck_helper.sh \
  test_go_core.sh \
  test_go_isolation.sh \
  test_security_adversarial.sh \
  test_schema.sh \
  test_public_release.sh \
  test_static.sh; do
  printf '\n== %s ==\n' "$test"
  "$BASE_DIR/tests/$test"
done
printf '\nOK: test suite SYSdiag 0.14.2\n'
