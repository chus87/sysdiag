#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"
TMP="$TEST_TMP_ROOT/go-isolation"; mkdir -p "$TMP/mockbin"; : > "$TMP/calls"
for cmd in docker podman kubectl oc crictl; do cat > "$TMP/mockbin/$cmd" <<MOCK
#!/usr/bin/env bash
printf '%s %s\n' '$cmd' "\$*" >> '$TMP/calls'
exit 99
MOCK
chmod +x "$TMP/mockbin/$cmd"; done
export SYSDIAG_TRUSTED_PATH="$TMP/mockbin:/usr/bin:/bin"
PATH="$TMP/mockbin:$PATH" "$BASE_DIR/sysdiag.sh" --section memory --json > "$TMP/memory.json"
[[ ! -s "$TMP/calls" ]] || fail "sección host invocó capas ajenas: $(cat "$TMP/calls")"
python3 - "$TMP/memory.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); assert x['scope']==['memory'] and 'memory' in x['metrics']
PY
: > "$TMP/calls"
PATH="$TMP/mockbin:$PATH" "$BASE_DIR/sysdiag-legacy.sh" --host-only --json > "$TMP/host.json"
[[ ! -s "$TMP/calls" ]] || fail "host-only legacy invocó capas ajenas: $(cat "$TMP/calls")"
pass go-isolation
