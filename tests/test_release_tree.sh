#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"
required=(
  sysdiag.sh sysdiag-legacy.sh sysdiag-standalone.sh Makefile README.md CHANGELOG.md go.mod .go-version
  LICENSE NOTICE AUTHORS COMANDOS.md COMPILACION.md CONTRIBUTING.md SECURITY.md
  .gitignore .gitattributes .editorconfig .github/dependabot.yml .github/CODEOWNERS .github/workflows/release.yml
  docs/ARCHITECTURE.md docs/JSON.md docs/SECURITY.md docs/SUPPORT.md docs/RELEASING.md docs/sysdiag-json-schema-v1.1.json
  scripts/update-go-version.sh bin/sysdiag-linux-amd64 bin/sysdiag-linux-arm64 internal/assets/sysdiag-standalone.sh
)
for f in "${required[@]}"; do [[ -f "$BASE_DIR/$f" ]] || fail "falta fichero requerido de release: $f"; done
cmp -s "$BASE_DIR/sysdiag-standalone.sh" "$BASE_DIR/internal/assets/sysdiag-standalone.sh" || fail 'collector embebido desincronizado'
if find "$BASE_DIR" -path "$BASE_DIR/.git" -prune -o -type l -print -quit | grep -q .; then fail 'la release contiene enlaces simbólicos'; fi
if find "$BASE_DIR" -path "$BASE_DIR/.git" -prune -o \( -type p -o -type s -o -type b -o -type c \) -print -quit | grep -q .; then fail 'la release contiene ficheros especiales'; fi
if find "$BASE_DIR" -path "$BASE_DIR/.git" -prune -o -type f -perm /6000 -print -quit | grep -q .; then fail 'la release contiene setuid/setgid'; fi
if find "$BASE_DIR" -path "$BASE_DIR/.git" -prune -o -type f \( -name '*.tmp' -o -name '*.bak' -o -name '*.orig' -o -name '*.rej' -o -name '*~' -o -name '.DS_Store' -o -name '*.pyc' -o -name '*.swp' -o -name '*.swo' \) -print -quit | grep -q .; then fail 'la release contiene basura de desarrollo'; fi
if find "$BASE_DIR" \( -type d -name '__pycache__' -o -type d -name '.pytest_cache' -o -type d -name '.mypy_cache' \) -print -quit | grep -q .; then fail 'la release contiene caches'; fi
if grep -RIlE '/mnt/data|/home/oai|sandbox:|ChatGPT|OpenAI' "$BASE_DIR/cmd" "$BASE_DIR/internal" "$BASE_DIR/lib" "$BASE_DIR/modules" "$BASE_DIR/README.md" "$BASE_DIR/docs" 2>/dev/null | grep -q .; then fail 'la release contiene referencias al entorno de construcción'; fi
python3 - "$BASE_DIR/bin/sysdiag-linux-amd64" "$BASE_DIR/bin/sysdiag-linux-arm64" <<'PY'
import sys
for p in sys.argv[1:]:
    with open(p,'rb') as f: assert f.read(4)==b'\x7fELF', f'binario no ELF: {p}'
PY
[[ -x "$BASE_DIR/sysdiag.sh" && -x "$BASE_DIR/sysdiag-standalone.sh" && -x "$BASE_DIR/scripts/update-go-version.sh" ]] || fail 'launchers/scripts no ejecutables'
assert_grep 'Apache License' "$BASE_DIR/LICENSE"
assert_grep 'Copyright 2026 Chus' "$BASE_DIR/NOTICE"
assert_grep 'Chus' "$BASE_DIR/AUTHORS"
pass release-tree
