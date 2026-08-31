#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"

# Bash syntax is mandatory and dependency-free.
while IFS= read -r -d '' f; do bash -n "$f"; done < <(find "$BASE_DIR" -type f -name '*.sh' -print0)

# Production-facing text must not refer to the development/learning process.
if grep -RniE '\b(curso|temario|estudiado|estudiados|estudiada|estudiadas|aprendido|aprendidos)\b|conceptos ya|comandos estudiados|course guide' \
  "$BASE_DIR/lib" "$BASE_DIR/modules" "$BASE_DIR/cmd" "$BASE_DIR/internal" "$BASE_DIR/README.md" >/tmp/sysdiag-static-forbidden.txt 2>/dev/null; then
  cat /tmp/sysdiag-static-forbidden.txt >&2
  fail "La interfaz/documentación contiene referencias al proceso de desarrollo o aprendizaje"
fi

# Diagnostic prose should start with an uppercase letter. Commands/identifiers are
# excluded by inspecting only the human-facing message argument of the helpers.
python3 - "$BASE_DIR" <<'PY_CAP'
import pathlib,re,sys
base=pathlib.Path(sys.argv[1])
errors=[]
for path in list((base/'modules').glob('*.sh'))+list((base/'lib').glob('*.sh')):
    for lineno,line in enumerate(path.read_text(encoding='utf-8').splitlines(),1):
        messages=[]
        m=re.search(r'\b(?:warn|info|add_limitation|add_next_step)\s+"([^"]*)"', line)
        if m: messages.append(m.group(1))
        m=re.search(r'\badd_finding\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+"([^"]*)"', line)
        if m: messages.append(m.group(1))
        for msg in messages:
            msg=msg.lstrip()
            if msg and msg[0].isalpha() and msg[0].islower():
                errors.append(f'{path.relative_to(base)}:{lineno}: {msg}')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    raise SystemExit(1)
PY_CAP


# Go core must be formatted and pass vet/tests when Go is available.
if command -v go >/dev/null 2>&1; then
  [[ -z "$(gofmt -l "$BASE_DIR/cmd" "$BASE_DIR/internal")" ]] || fail "gofmt pendiente"
  (cd "$BASE_DIR" && go vet ./... && go test ./...)
else
  printf 'SKIP: Go no está disponible; core Go no validado localmente.\n'
fi

# Formal JSON schema must at least be syntactically valid JSON.
python3 -m json.tool "$BASE_DIR/docs/sysdiag-json-schema-v1.1.json" >/dev/null

if ! command -v shellcheck >/dev/null 2>&1; then
  if "$BASE_DIR/tests/ensure-shellcheck.sh"; then :; else
    rc=$?
    if (( rc == 2 )); then printf 'SKIP: shellcheck no está instalado; instalación no autorizada o ejecución no interactiva.\n'; fi
  fi
fi
if command -v shellcheck >/dev/null 2>&1; then
  # The generated standalone contains the complete runtime in one file, which
  # avoids false positives caused by checking sourced modules in isolation.
  shellcheck --severity=error -x \
    "$BASE_DIR/sysdiag-standalone.sh" "$BASE_DIR/build-standalone.sh" \
    "$BASE_DIR"/tests/integration/*.sh "$BASE_DIR"/tests/vm/*.sh
  pass shellcheck
fi

if command -v ruby >/dev/null 2>&1; then
  ruby -c "$BASE_DIR/tests/vm/Vagrantfile" >/dev/null
else
  printf 'SKIP: ruby no está disponible; Vagrantfile no validado sintácticamente.\n'
fi

if python3 - <<'PY' >/dev/null 2>&1
import yaml
PY
then
  python3 - "$BASE_DIR" <<'PY'
import pathlib,sys,yaml
base=pathlib.Path(sys.argv[1])
for p in (base/'.github/workflows').glob('*.yml'):
    yaml.safe_load(p.read_text(encoding='utf-8'))
PY
else
  printf 'SKIP: PyYAML no está disponible; workflows no validados por parser local.\n'
fi

pass static
