#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"
VERSION="$(sed -n 's/^SYS_DIAG_VERSION="\([^"]*\)"/\1/p' lib/version.sh | head -n1)"
OUT_DIR="${1:-$BASE_DIR/dist}"
EPOCH="${SOURCE_DATE_EPOCH:-315532800}" # 1980-01-01 UTC, válido para ZIP.
case "$EPOCH" in ''|*[!0-9]*) echo 'SOURCE_DATE_EPOCH debe ser entero.' >&2; exit 2;; esac
mkdir -p "$OUT_DIR"

if [[ "${SYSDIAG_RELEASE_SKIP_PRECHECK:-0}" != "1" ]]; then
  make release-check
fi

STAGE="$(mktemp -d)"
VALIDATE="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$VALIDATE"' EXIT
ROOT="$STAGE/sysdiag-v$VERSION"
mkdir -p "$ROOT"

items=(
  .github .go-version .gitignore .gitattributes .editorconfig
  LICENSE NOTICE AUTHORS COMANDOS.md COMPILACION.md CONTRIBUTING.md SECURITY.md
  CHANGELOG.md Makefile README.md SHA256SUMS BUILDINFO.txt SBOM.spdx.json
  build-info.sh build-sbom.sh build-standalone.sh release.sh go.mod
  cmd docs internal lib modules tests scripts bin sysdiag.sh sysdiag-legacy.sh sysdiag-standalone.sh
)
for item in "${items[@]}"; do
  [[ -e "$item" ]] || { printf 'Falta artefacto requerido para release: %s\n' "$item" >&2; exit 1; }
  cp -a "$item" "$ROOT/"
done

# Congela permisos/mtime de forma determinista sin alterar el árbol de trabajo.
find "$ROOT" -type d -exec chmod 0755 {} +
find "$ROOT" -type f -exec chmod 0644 {} +
chmod 0755 "$ROOT/sysdiag.sh" "$ROOT/sysdiag-legacy.sh" "$ROOT/sysdiag-standalone.sh" \
  "$ROOT/build-info.sh" "$ROOT/build-sbom.sh" "$ROOT/build-standalone.sh" "$ROOT/release.sh" \
  "$ROOT/bin/sysdiag-linux-amd64" "$ROOT/bin/sysdiag-linux-arm64" "$ROOT"/tests/*.sh \
  "$ROOT"/tests/integration/*.sh "$ROOT"/tests/vm/*.sh "$ROOT"/scripts/*.sh
find "$ROOT" -exec touch -h -d "@$EPOCH" {} +

TAR="$OUT_DIR/sysdiag-v$VERSION.tar.gz"
ZIP="$OUT_DIR/sysdiag-v$VERSION.zip"
STANDALONE="$OUT_DIR/sysdiag-v$VERSION-standalone.sh"
AMD64="$OUT_DIR/sysdiag-v$VERSION-linux-amd64"
ARM64="$OUT_DIR/sysdiag-v$VERSION-linux-arm64"
SUMS="$OUT_DIR/sysdiag-v$VERSION-SHA256SUMS.txt"
SBOM="$OUT_DIR/sysdiag-v$VERSION-SBOM.spdx.json"
BUILDINFO="$OUT_DIR/sysdiag-v$VERSION-BUILDINFO.txt"
LICENSE_OUT="$OUT_DIR/sysdiag-v$VERSION-LICENSE.txt"
NOTICE_OUT="$OUT_DIR/sysdiag-v$VERSION-NOTICE.txt"
AUTHORS_OUT="$OUT_DIR/sysdiag-v$VERSION-AUTHORS.txt"
rm -f "$TAR" "$ZIP" "$STANDALONE" "$AMD64" "$ARM64" "$SUMS" "$SBOM" "$BUILDINFO" "$LICENSE_OUT" "$NOTICE_OUT" "$AUTHORS_OUT"

tar --sort=name --mtime="@$EPOCH" --owner=0 --group=0 --numeric-owner -C "$STAGE" -cf - "sysdiag-v$VERSION" | gzip -n > "$TAR"
python3 - "$ROOT" "$ZIP" "$EPOCH" <<'PY'
import os,sys,zipfile,datetime,pathlib
root=pathlib.Path(sys.argv[1]); out=sys.argv[2]; epoch=max(int(sys.argv[3]),315532800)
dt=datetime.datetime.fromtimestamp(epoch,datetime.timezone.utc)
stamp=(dt.year,dt.month,dt.day,dt.hour,dt.minute,dt.second)
base=root.parent
with zipfile.ZipFile(out,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
    for p in sorted(root.rglob('*')):
        rel=p.relative_to(base).as_posix()
        if p.is_dir():
            zi=zipfile.ZipInfo(rel+'/',stamp); zi.external_attr=(0o40755 << 16); z.writestr(zi,b''); continue
        zi=zipfile.ZipInfo(rel,stamp); zi.compress_type=zipfile.ZIP_DEFLATED
        zi.external_attr=((0o100755 if os.access(p,os.X_OK) else 0o100644) << 16)
        z.writestr(zi,p.read_bytes())
PY
cp "$ROOT/sysdiag-standalone.sh" "$STANDALONE"
cp "$ROOT/bin/sysdiag-linux-amd64" "$AMD64"
cp "$ROOT/bin/sysdiag-linux-arm64" "$ARM64"
cp "$ROOT/SBOM.spdx.json" "$SBOM"
cp "$ROOT/BUILDINFO.txt" "$BUILDINFO"
cp "$ROOT/LICENSE" "$LICENSE_OUT"
cp "$ROOT/NOTICE" "$NOTICE_OUT"
cp "$ROOT/AUTHORS" "$AUTHORS_OUT"
chmod 0755 "$STANDALONE" "$AMD64" "$ARM64"
chmod 0644 "$SBOM" "$BUILDINFO" "$LICENSE_OUT" "$NOTICE_OUT" "$AUTHORS_OUT"

# Segunda construcción: exige reproducibilidad byte a byte.
TAR2="$VALIDATE/repro.tar.gz"; ZIP2="$VALIDATE/repro.zip"
tar --sort=name --mtime="@$EPOCH" --owner=0 --group=0 --numeric-owner -C "$STAGE" -cf - "sysdiag-v$VERSION" | gzip -n > "$TAR2"
python3 - "$ROOT" "$ZIP2" "$EPOCH" <<'PY'
import os,sys,zipfile,datetime,pathlib
root=pathlib.Path(sys.argv[1]); out=sys.argv[2]; epoch=max(int(sys.argv[3]),315532800)
dt=datetime.datetime.fromtimestamp(epoch,datetime.timezone.utc); stamp=(dt.year,dt.month,dt.day,dt.hour,dt.minute,dt.second); base=root.parent
with zipfile.ZipFile(out,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
    for p in sorted(root.rglob('*')):
        rel=p.relative_to(base).as_posix()
        if p.is_dir():
            zi=zipfile.ZipInfo(rel+'/',stamp); zi.external_attr=(0o40755 << 16); z.writestr(zi,b''); continue
        zi=zipfile.ZipInfo(rel,stamp); zi.compress_type=zipfile.ZIP_DEFLATED
        zi.external_attr=((0o100755 if os.access(p,os.X_OK) else 0o100644) << 16); z.writestr(zi,p.read_bytes())
PY
cmp -s "$TAR" "$TAR2" || { echo 'TAR.GZ no reproducible' >&2; exit 1; }
cmp -s "$ZIP" "$ZIP2" || { echo 'ZIP no reproducible' >&2; exit 1; }

(cd "$OUT_DIR" && sha256sum \
  "$(basename "$ZIP")" "$(basename "$TAR")" "$(basename "$STANDALONE")" \
  "$(basename "$AMD64")" "$(basename "$ARM64")" "$(basename "$SBOM")" \
  "$(basename "$BUILDINFO")" "$(basename "$LICENSE_OUT")" "$(basename "$NOTICE_OUT")" \
  "$(basename "$AUTHORS_OUT")" > "$(basename "$SUMS")")

mkdir -p "$VALIDATE/tar" "$VALIDATE/zip"
tar -xzf "$TAR" -C "$VALIDATE/tar"
python3 - "$ZIP" "$VALIDATE/zip" <<'PY'
import os,sys,zipfile,pathlib
out=pathlib.Path(sys.argv[2])
with zipfile.ZipFile(sys.argv[1]) as z:
    for info in z.infolist():
        target=out/info.filename
        if info.is_dir(): target.mkdir(parents=True,exist_ok=True)
        else:
            target.parent.mkdir(parents=True,exist_ok=True)
            with z.open(info) as src, open(target,'wb') as dst: dst.write(src.read())
        mode=(info.external_attr >> 16) & 0o7777
        if mode: os.chmod(target,mode)
PY
A="$VALIDATE/tar/sysdiag-v$VERSION"; B="$VALIDATE/zip/sysdiag-v$VERSION"
( cd "$A" && sha256sum -c SHA256SUMS >/dev/null && tests/test_release_tree.sh >/dev/null )
( cd "$B" && sha256sum -c SHA256SUMS >/dev/null && tests/test_release_tree.sh >/dev/null )
python3 - "$A" "$B" <<'PY'
import hashlib,pathlib,sys
def tree(root):
    root=pathlib.Path(root); out={}
    for p in root.rglob('*'):
        if p.is_file(): out[p.relative_to(root).as_posix()]=hashlib.sha256(p.read_bytes()).hexdigest()
    return out
a,b=tree(sys.argv[1]),tree(sys.argv[2])
assert a==b, f'ZIP/TAR difieren: {set(a)^set(b)}'
PY
"$A/sysdiag.sh" --version >/dev/null
"$A/sysdiag.sh" --section memory --json > "$VALIDATE/report.json"
python3 - "$A/docs/sysdiag-json-schema-v1.1.json" "$VALIDATE/report.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[2])); assert x['engine']=='go-core' and x['read_only'] is True and x['schema_version']=='1.1' and x['build']['author']=='Chus (GitHub: chus87)' and x['build']['license']=='Apache-2.0'
try: import jsonschema
except Exception: raise SystemExit(0)
jsonschema.Draft202012Validator(json.load(open(sys.argv[1])),format_checker=jsonschema.FormatChecker()).validate(x)
PY
"$A/sysdiag-standalone.sh" --section memory --json | python3 -m json.tool >/dev/null
case "$(uname -m)" in x86_64|amd64) (cd / && "$AMD64" --section memory --json | python3 -m json.tool >/dev/null);; esac

printf 'Release SYSdiag %s validada en %s\n' "$VERSION" "$OUT_DIR"
