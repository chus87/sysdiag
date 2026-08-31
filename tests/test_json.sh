#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"
TMP="$TEST_TMP_ROOT/json"; mkdir -p "$TMP"

"$BASE_DIR/sysdiag.sh" --section boot --json > "$TMP/boot.json"
python3 - "$TMP/boot.json" <<'PY'
import json,sys
p=sys.argv[1]
d=json.load(open(p,encoding='utf-8'))
assert d['schema_version']=='1.1'
assert d['sysdiag_version']=='0.14.1'
assert d['read_only'] is True
assert d['scope']==['boot']
assert [x['category'] for x in d['summary']]==['boot']
assert 'metrics' in d and 'boot' in d['metrics']
assert isinstance(d['findings'],list)
assert isinstance(d['limitations'],list)
assert isinstance(d['next_steps'],list)
assert isinstance(d.get('collectors',[]),list)
assert d['engine']=='go-core'
PY
assert_no_grep $'\033' "$TMP/boot.json"

"$BASE_DIR/sysdiag.sh" --recent-errors --json > "$TMP/recent.json"
python3 - "$TMP/recent.json" <<'PY2'
import json,sys
x=json.load(open(sys.argv[1],encoding='utf-8'))
r=x['metrics']['recent_events']
for k in ('journal_errors','journal_warnings','dmesg_errors','dmesg_warnings'):
    assert isinstance(r[k],list),k
PY2

"$BASE_DIR/sysdiag.sh" --all --json > "$TMP/all.json"
python3 - "$TMP/all.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1],encoding='utf-8'))
cats={i['category'] for i in x['summary']}
for c in ('cpu','processes','memory','io','filesystem','network','logging','systemd','boot','containers','kubernetes'):
    assert c in cats,c
for k in ('system','cpu','processes','memory','io','filesystem','network','logging','recent_events','systemd','boot','containers','kubernetes'):
    assert k in x['metrics'],k
for f in x['findings']:
    assert {'id','category','domain','points','impact','message'} <= set(f)
for n in x['next_steps']:
    assert isinstance(n.get('commands',[]),list)
    assert isinstance(n.get('actions',[]),list)
    for a in n.get('actions',[]): assert a['safety'] in ('read_only','mutating','unknown')
PY

# --report with JSON must contain JSON only and use .json in auto mode.
(cd "$TMP" && "$BASE_DIR/sysdiag.sh" --section network --json --report >/dev/null)
report="$(find "$TMP" -maxdepth 1 -type f -name 'sysdiag-*.json' | head -n1)"
[[ -n "$report" ]] || fail 'no se generó report JSON automático'
python3 -m json.tool "$report" >/dev/null

# Guide is intentionally human-only.
if "$BASE_DIR/sysdiag.sh" --guide --json >"$TMP/guide.out" 2>"$TMP/guide.err"; then fail '--guide --json debería fallar'; fi
assert_grep 'no es compatible' "$TMP/guide.err"

if python3 -c 'import jsonschema' >/dev/null 2>&1; then
  python3 - "$BASE_DIR/docs/sysdiag-json-schema-v1.1.json" "$TMP/all.json" <<'PY_SCHEMA'
import json,jsonschema,sys
schema=json.load(open(sys.argv[1])); data=json.load(open(sys.argv[2])); jsonschema.Draft202012Validator(schema,format_checker=jsonschema.FormatChecker()).validate(data)
PY_SCHEMA
else
  printf 'SKIP: python jsonschema no disponible.\n'
fi

pass json
