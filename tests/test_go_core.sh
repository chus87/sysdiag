#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"
TMP="$TEST_TMP_ROOT/go-core"; mkdir -p "$TMP"
command -v go >/dev/null 2>&1 || { printf 'SKIP: Go no está disponible.\n'; exit 0; }

[[ -z "$(gofmt -l "$BASE_DIR/cmd" "$BASE_DIR/internal")" ]] || fail 'hay ficheros Go sin gofmt'
(cd "$BASE_DIR" && go vet ./... && go test ./... && go test -race ./...)

LDFLAGS='-s -w -buildid= -X github.com/chus87/sysdiag/internal/version.Commit=unknown'
(cd "$BASE_DIR" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -buildvcs=false -trimpath -ldflags="$LDFLAGS" -o "$TMP/sysdiag-amd64" ./cmd/sysdiag)
(cd "$BASE_DIR" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -buildvcs=false -trimpath -ldflags="$LDFLAGS" -o "$TMP/sysdiag-arm64" ./cmd/sysdiag)
[[ -s "$TMP/sysdiag-amd64" && -s "$TMP/sysdiag-arm64" ]] || fail 'binarios Go vacíos'
(cd "$BASE_DIR" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -buildvcs=false -trimpath -ldflags="$LDFLAGS" -o "$TMP/sysdiag-amd64-2" ./cmd/sysdiag)
(cd "$BASE_DIR" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -buildvcs=false -trimpath -ldflags="$LDFLAGS" -o "$TMP/sysdiag-arm64-2" ./cmd/sysdiag)
cmp -s "$TMP/sysdiag-amd64" "$TMP/sysdiag-amd64-2" || fail 'binario amd64 no reproducible'; cmp -s "$TMP/sysdiag-arm64" "$TMP/sysdiag-arm64-2" || fail 'binario arm64 no reproducible'

# Portable binary: source tree not required.
mkdir -p "$TMP/bare"; cp "$TMP/sysdiag-amd64" "$TMP/bare/sysdiag"
(cd / && "$TMP/bare/sysdiag" --section memory --json > "$TMP/bare.json")
python3 - "$TMP/bare.json" <<'PY'
import json,sys,re
x=json.load(open(sys.argv[1])); assert x['engine']=='go-core' and x['scope']==['memory'] and x['read_only'] is True
assert x['schema_version']=='1.1' and x['sysdiag_version']=='0.14.2'
assert x['collectors'][0]['name']=='memory' and x['collectors'][0]['duration_ms']>=0
assert re.fullmatch(r'[0-9a-f]{64}',x['build']['collector_sha256'])
PY

# P0 regression: a collector in CWD is never auto-discovered/executed.
mkdir -p "$TMP/hostile-cwd"; cat > "$TMP/hostile-cwd/sysdiag-legacy.sh" <<MOCK
#!/usr/bin/env bash
echo PWNED > '$TMP/cwd-executed'
MOCK
chmod +x "$TMP/hostile-cwd/sysdiag-legacy.sh"
(cd "$TMP/hostile-cwd" && "$TMP/bare/sysdiag" --section memory --json >/dev/null)
[[ ! -e "$TMP/cwd-executed" ]] || fail 'el binario ejecutó un collector encontrado en CWD'

# Shell startup injection must be removed from the collector environment.
cat > "$TMP/evil-bash-env" <<MOCK
echo INJECTED > '$TMP/bash-env-executed'
MOCK
(export BASH_ENV="$TMP/evil-bash-env" ENV="$TMP/evil-bash-env"; cd /; "$TMP/bare/sysdiag" --section memory --json >/dev/null)
[[ ! -e "$TMP/bash-env-executed" ]] || fail 'BASH_ENV/ENV se propagó al collector'

cmp -s "$BASE_DIR/sysdiag-standalone.sh" "$BASE_DIR/internal/assets/sysdiag-standalone.sh" || fail 'backend Bash embebido desincronizado'
collector_sha="$(sha256sum "$BASE_DIR/sysdiag-standalone.sh" | awk '{print $1}')"
"$TMP/bare/sysdiag" --version > "$TMP/version.txt"; assert_grep "Collector SHA256: $collector_sha" "$TMP/version.txt"

"$BASE_DIR/sysdiag.sh" --section boot --json > "$TMP/go.json"; "$BASE_DIR/sysdiag-legacy.sh" --section boot --json > "$TMP/legacy.json"
python3 - "$TMP/go.json" "$TMP/legacy.json" <<'PY'
import json,sys
g,l=map(lambda p:json.load(open(p,encoding='utf-8')),sys.argv[1:])
assert g['sysdiag_version']==l['sysdiag_version']=='0.14.2'; assert g['schema_version']==l['schema_version']=='1.1'; assert g['engine']=='go-core'; assert g['read_only'] is l['read_only'] is True
assert g['scope']==l['scope']==['boot']; assert set(g['metrics']['boot'])==set(l['metrics']['boot'])
assert isinstance(g['coverage'],list) and isinstance(g['summary'],list)
PY

"$BASE_DIR/sysdiag.sh" --all --json > "$TMP/all.json"
python3 - "$TMP/all.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); assert x['engine']=='go-core' and x['read_only'] is True
for k in ('system','cpu','processes','memory','io','filesystem','network','logging','recent_events','systemd','boot','containers','kubernetes'): assert k in x['metrics'],k
assert isinstance(x.get('evidence',[]),list); assert isinstance(x.get('conclusions',[]),list); assert len(x.get('collectors',[]))==3
assert x['started_at'] and x['completed_at'] and x['duration_ms']>=0
PY

if grep -RniE 'oc[[:space:]]+login[^\n]*([[:space:]]-p[[:space:]]|--password=)' "$BASE_DIR/modules" "$BASE_DIR/internal" "$BASE_DIR/cmd" >"$TMP/password-argv"; then cat "$TMP/password-argv" >&2; fail 'password OpenShift en argv'; fi
pass go-core
