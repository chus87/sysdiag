#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"
TMP="$TEST_TMP_ROOT/schema"; mkdir -p "$TMP"
if ! python3 - <<'PY' >/dev/null 2>&1
import jsonschema
PY
then
  printf 'SKIP: python jsonschema no está disponible; usa make schema-check para validación estricta de release.\n'
  exit 0
fi
"$BASE_DIR/sysdiag.sh" --section memory --json > "$TMP/memory.json"
"$BASE_DIR/sysdiag.sh" --section network --json > "$TMP/network.json"
python3 - "$BASE_DIR/docs/sysdiag-json-schema-v1.1.json" "$TMP/memory.json" "$TMP/network.json" <<'PY'
import json,sys,jsonschema
schema=json.load(open(sys.argv[1],encoding='utf-8'))
validator=jsonschema.Draft202012Validator(schema, format_checker=jsonschema.FormatChecker())
for path in sys.argv[2:]:
    obj=json.load(open(path,encoding='utf-8'))
    errs=sorted(validator.iter_errors(obj), key=lambda e:list(e.path))
    if errs:
        for e in errs[:20]:
            print(f"{path}: {list(e.path)}: {e.message}", file=sys.stderr)
        raise SystemExit(1)
PY
pass schema
