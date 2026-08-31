#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(awk '/^VERSION :=/{print $3; exit}' "$BASE_DIR/Makefile")"
OUT_DIR="${1:-$BASE_DIR/dist-source}"
EPOCH="${SOURCE_DATE_EPOCH:-315532800}" # 1980-01-01, compatible con ZIP.
ROOT="sysdiag-v${VERSION}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT_DIR" "$WORK/$ROOT"

# Lista explícita: el paquete fuente nunca incorpora binarios ni metadata
# generada por una build local.
items=(
  .editorconfig .gitattributes .github .gitignore .go-version
  AUTHORS CHANGELOG.md COMANDOS.md COMPILACION.md CONTRIBUTING.md LICENSE Makefile NOTICE README.md SECURITY.md
  build-info.sh build-sbom.sh build-standalone.sh cmd docs go.mod internal lib modules release.sh scripts
  sysdiag-legacy.sh sysdiag-standalone.sh sysdiag.sh tests
)
for item in "${items[@]}"; do
  [[ -e "$BASE_DIR/$item" ]] || { echo "Falta elemento fuente requerido: $item" >&2; exit 1; }
  cp -a "$BASE_DIR/$item" "$WORK/$ROOT/"
done

# Nunca empaquetar el propio generador dentro de scripts con artefactos temporales
# fuera de la lista; sí se conserva scripts/source-archive.sh por ser parte del repo.
find "$WORK/$ROOT" -type l -print -quit | grep -q . && { echo 'No se permiten symlinks en el paquete fuente.' >&2; exit 1; }
find "$WORK/$ROOT" \( -name '*.tmp' -o -name '*.bak' -o -name '*.orig' -o -name '*.rej' -o -name '*~' -o -name '__pycache__' \) -print -quit | grep -q . && { echo 'Se detectó basura de desarrollo en el paquete fuente.' >&2; exit 1; }

find "$WORK/$ROOT" -type d -exec chmod 0755 {} +
find "$WORK/$ROOT" -type f -exec chmod 0644 {} +
find "$WORK/$ROOT" -type f -name '*.sh' -exec chmod 0755 {} +
chmod 0755 "$WORK/$ROOT/sysdiag.sh" "$WORK/$ROOT/sysdiag-legacy.sh" "$WORK/$ROOT/sysdiag-standalone.sh" "$WORK/$ROOT/release.sh" "$WORK/$ROOT/build-standalone.sh" "$WORK/$ROOT/build-sbom.sh" "$WORK/$ROOT/build-info.sh"
find "$WORK/$ROOT" -exec touch -h -d "@$EPOCH" {} +

zip_path="$OUT_DIR/${ROOT}-source.zip"
tar_path="$OUT_DIR/${ROOT}-source.tar.gz"
rm -f "$zip_path" "$tar_path" "$OUT_DIR/${ROOT}-source-SHA256SUMS.txt"
(
  cd "$WORK"
  find "$ROOT" -type f -o -type d | LC_ALL=C sort | zip -X -q "$zip_path" -@
  tar --sort=name --mtime="@$EPOCH" --owner=0 --group=0 --numeric-owner -cf - "$ROOT" | gzip -n > "$tar_path"
)
sha256sum "$zip_path" "$tar_path" > "$OUT_DIR/${ROOT}-source-SHA256SUMS.txt"

# Validación posterior de ambos formatos.
for archive in "$zip_path" "$tar_path"; do
  check="$(mktemp -d)"
  if [[ "$archive" == *.zip ]]; then
    unzip -q "$archive" -d "$check"
  else
    tar -xzf "$archive" -C "$check"
  fi
  test -f "$check/$ROOT/COMANDOS.md"
  test -f "$check/$ROOT/COMPILACION.md"
  test -f "$check/$ROOT/LICENSE"
  test -f "$check/$ROOT/NOTICE"
  test "$(cat "$check/$ROOT/.go-version")" = '1.27.0'
  bash "$check/$ROOT/tests/test_public_release.sh"
  rm -rf "$check"
done

echo "Paquete fuente generado: $zip_path"
echo "Paquete fuente generado: $tar_path"
