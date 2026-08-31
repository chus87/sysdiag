#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"
TMP="$TEST_TMP_ROOT/standalone"; mkdir -p "$TMP"

before="$(sha256sum "$BASE_DIR/sysdiag-standalone.sh" | awk '{print $1}')"
"$BASE_DIR/build-standalone.sh" > "$TMP/build.txt"
after="$(sha256sum "$BASE_DIR/sysdiag-standalone.sh" | awk '{print $1}')"
[[ "$before" == "$after" ]] || fail 'standalone no es reproducible'
assert_grep 'Generado SYSdiag 0.14.2' "$TMP/build.txt"
(cd "$BASE_DIR" && sha256sum -c SHA256SUMS >/dev/null) || fail 'SHA256SUMS inválido'

"$BASE_DIR/sysdiag-standalone.sh" --section cpu --sample 1 --no-color > "$TMP/cpu.txt"
assert_grep 'CPU idle real:' "$TMP/cpu.txt"
assert_grep '^ANÁLISIS Y PRIORIZACIÓN$' "$TMP/cpu.txt"
"$BASE_DIR/sysdiag-standalone.sh" --section logging --no-color > "$TMP/logging.txt"
assert_grep '^LOGS Y JOURNAL$' "$TMP/logging.txt"
"$BASE_DIR/sysdiag-standalone.sh" --recent-errors --no-color > "$TMP/recent.txt"
assert_grep '^WARNINGS Y ERRORES RECIENTES$' "$TMP/recent.txt"
"$BASE_DIR/sysdiag-standalone.sh" --section systemd --no-color > "$TMP/systemd.txt"
assert_grep '^SYSTEMD / SERVICIOS$' "$TMP/systemd.txt"
"$BASE_DIR/sysdiag-standalone.sh" --section boot --no-color > "$TMP/boot.txt"
assert_grep '^BOOT / ARRANQUE$' "$TMP/boot.txt"
"$BASE_DIR/sysdiag-standalone.sh" --section containers --no-color > "$TMP/containers.txt"
assert_grep '^CONTENEDORES$' "$TMP/containers.txt"
"$BASE_DIR/sysdiag-standalone.sh" --guide --no-color > "$TMP/guide.txt"
assert_grep '^GUÍA TÉCNICA DE DIAGNÓSTICO Y COMANDOS$' "$TMP/guide.txt"
"$BASE_DIR/sysdiag-standalone.sh" --help | grep -q -- '--recent-errors'
"$BASE_DIR/sysdiag-standalone.sh" --help | grep -q -- '--guide'
"$BASE_DIR/sysdiag-standalone.sh" --help | grep -q -- '--json'
"$BASE_DIR/sysdiag-standalone.sh" --all --json > "$TMP/all.json"
python3 -m json.tool "$TMP/all.json" >/dev/null 

pass standalone
