#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"
TMP="$TEST_TMP_ROOT/shellcheck-helper"; mkdir -p "$TMP/mockbin"
: > "$TMP/calls"
cat > "$TMP/mockbin/apt-get" <<MOCK
#!/bin/bash
printf 'apt-get %s\n' "\$*" >> '$TMP/calls'
if [[ "\${1:-}" == install ]]; then
  /bin/cat > '$TMP/mockbin/shellcheck' <<'INNER'
#!/bin/bash
exit 0
INNER
  /bin/chmod +x '$TMP/mockbin/shellcheck'
fi
exit 0
MOCK
chmod +x "$TMP/mockbin/apt-get"

# Explicit opt-in may install; this helper is development tooling, not SYSdiag runtime.
PATH="$TMP/mockbin" SYSDIAG_SHELLCHECK_INSTALL=1 /bin/bash "$BASE_DIR/tests/ensure-shellcheck.sh"
assert_grep '^apt-get update$' "$TMP/calls"
assert_grep '^apt-get install -y shellcheck$' "$TMP/calls"
[[ -x "$TMP/mockbin/shellcheck" ]] || fail "El helper no dejó shellcheck disponible"
pass shellcheck-helper
