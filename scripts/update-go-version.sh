#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$BASE_DIR"
version="${1:-}"
[[ "$version" =~ ^1\.[0-9]+\.[0-9]+$ ]] || { echo 'Uso: scripts/update-go-version.sh 1.27.0' >&2; exit 2; }
printf '%s\n' "$version" > .go-version
python3 - "$version" <<'PY'
from pathlib import Path
import re,sys
v=sys.argv[1]
p=Path('go.mod')
s=p.read_text()
s=re.sub(r'^go\s+\S+', f'go {v}', s, count=1, flags=re.M)
s=re.sub(r'^toolchain\s+go\S+\s*\n?', '', s, count=1, flags=re.M)
p.write_text(s)
PY
printf 'Go fijado en %s. Ejecuta make release-check antes de integrar el cambio.\n' "$version"
