#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"
TMP="$TEST_TMP_ROOT/cli"; mkdir -p "$TMP/mockbin"

"$BASE_DIR/sysdiag.sh" --section network --no-color > "$TMP/network.txt"
for p in '^SYSdiag 0.14.1' '^RESUMEN PRIORIZADO$' '^DATOS RELEVANTES$' '^HALLAZGOS$' 'Ámbito: network'; do assert_grep "$p" "$TMP/network.txt"; done
if LC_ALL=C grep -q $'\033\[' "$TMP/network.txt"; then fail 'ANSI con --no-color'; fi

REPORT="$TMP/report.txt"
"$BASE_DIR/sysdiag.sh" --section network --report "$REPORT" >/dev/null
assert_grep '^SYSdiag 0.14.1' "$REPORT"; assert_grep '^RESUMEN PRIORIZADO$' "$REPORT"
if LC_ALL=C grep -q $'\033\[' "$REPORT"; then fail 'ANSI en report'; fi
if stat -c '%a' "$REPORT" >/dev/null 2>&1; then [[ "$(stat -c '%a' "$REPORT")" == 600 ]] || fail 'permisos inseguros en report humano'; fi

JSON_REPORT="$TMP/report.json"
"$BASE_DIR/sysdiag.sh" --section network --json --report "$JSON_REPORT" >/dev/null
python3 -m json.tool "$JSON_REPORT" >/dev/null
if stat -c '%a' "$JSON_REPORT" >/dev/null 2>&1; then [[ "$(stat -c '%a' "$JSON_REPORT")" == 600 ]] || fail 'permisos inseguros en report JSON'; fi

ln -s "$TMP/symlink-target" "$TMP/report-link"
set +e; "$BASE_DIR/sysdiag.sh" --section network --report "$TMP/report-link" >/dev/null 2>"$TMP/report-link.err"; rc=$?; set -e
(( rc != 0 )) || fail 'se aceptó un symlink como destino de report'; assert_grep 'enlace simbólico' "$TMP/report-link.err"

# Un destino especial tampoco puede bloquear/truncar la ejecución.
if command -v mkfifo >/dev/null 2>&1; then
  mkfifo "$TMP/report-fifo"
  set +e; timeout 5 "$BASE_DIR/sysdiag.sh" --section network --report "$TMP/report-fifo" >/dev/null 2>"$TMP/report-fifo.err"; rc=$?; set -e
  (( rc != 0 && rc != 124 )) || fail 'destino FIFO aceptado o provocó bloqueo'
  assert_grep 'no es un fichero regular' "$TMP/report-fifo.err"
fi
printf 'contenido anterior\n' > "$TMP/report-existing"
"$BASE_DIR/sysdiag.sh" --section network --report "$TMP/report-existing" >/dev/null
assert_grep '^SYSdiag 0.14.1' "$TMP/report-existing"

"$BASE_DIR/sysdiag.sh" --summary --no-color > "$TMP/summary.txt"
assert_grep '^RESUMEN PRIORIZADO$' "$TMP/summary.txt"; assert_no_grep '^DATOS RELEVANTES$' "$TMP/summary.txt"

printf '6\n' | "$BASE_DIR/sysdiag.sh" --menu --no-color > "$TMP/menu-network.txt"
assert_grep 'SYSdiag — ¿Qué quieres analizar?' "$TMP/menu-network.txt"; assert_grep 'Ámbito: network' "$TMP/menu-network.txt"
MENU_REPORT="$TMP/menu-report.txt"; printf '6\n' | "$BASE_DIR/sysdiag.sh" --menu --no-color --report "$MENU_REPORT" >/dev/null
assert_grep 'Ámbito: network' "$MENU_REPORT"; assert_no_grep '¿Qué quieres analizar?' "$MENU_REPORT"

printf '5,6,7,8,9,10\n' | "$BASE_DIR/sysdiag.sh" --menu --no-color > "$TMP/menu-multi.txt"
for p in 'Filesystem / espacio / inodos' 'Red / TCP / sockets' 'Logs / capacidad de diagnóstico' 'Systemd / servicios' 'Boot / arranque'; do assert_grep "$p" "$TMP/menu-multi.txt"; done
printf '1\n' | "$BASE_DIR/sysdiag.sh" --menu --no-color > "$TMP/menu-summary.txt"; assert_grep '^RESUMEN PRIORIZADO$' "$TMP/menu-summary.txt"

# Invalid iostat data must remain LIMITED in the Go summary.
cat > "$TMP/mockbin/iostat" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$TMP/mockbin/iostat"
export SYSDIAG_TRUSTED_PATH="$TMP/mockbin:/usr/bin:/bin"
PATH="$TMP/mockbin:$PATH" "$BASE_DIR/sysdiag.sh" --summary --no-color > "$TMP/summary-invalid-iostat.txt"
assert_grep 'LIMITADO.*I/O / almacenamiento' "$TMP/summary-invalid-iostat.txt"
unset SYSDIAG_TRUSTED_PATH

"$BASE_DIR/sysdiag.sh" --section recent --no-color > "$TMP/recent-section.txt"
"$BASE_DIR/sysdiag.sh" --recent-errors --no-color > "$TMP/recent-alias.txt"
assert_grep 'Ámbito: recent' "$TMP/recent-section.txt"; assert_grep 'Ámbito: recent' "$TMP/recent-alias.txt"

"$BASE_DIR/sysdiag.sh" --version > "$TMP/version.txt"
for p in '^SYSdiag 0.14.1$' '^Engine: go-core$' '^Schema: 1.1$'; do assert_grep "$p" "$TMP/version.txt"; done
grep -Eq '^Collector SHA256: [0-9a-f]{64}$' "$TMP/version.txt" || fail "Collector SHA256 inválido en --version"
"$BASE_DIR/sysdiag.sh" --help > "$TMP/help.txt"
for p in '--container-mode' '--containers-deep' '--color auto' '--timeout'; do assert_grep "$p" "$TMP/help.txt"; done
"$BASE_DIR/sysdiag.sh" </dev/null > "$TMP/non-tty.txt"; assert_no_grep '¿Qué quieres analizar?' "$TMP/non-tty.txt"; assert_grep '^RESUMEN PRIORIZADO$' "$TMP/non-tty.txt"

# Explicit color and NO_COLOR contract.
"$BASE_DIR/sysdiag.sh" --section memory --color always > "$TMP/color.txt"
LC_ALL=C grep -q $'\033\[' "$TMP/color.txt" || fail 'color always no emitió ANSI'
NO_COLOR=1 "$BASE_DIR/sysdiag.sh" --section memory --color always > "$TMP/no-color-env.txt"
if LC_ALL=C grep -q $'\033\[' "$TMP/no-color-env.txt"; then fail 'NO_COLOR no fue respetado'; fi

if command -v script >/dev/null 2>&1; then
  printf '0\n' | script -qfec "$BASE_DIR/sysdiag.sh" /dev/null > "$TMP/menu-auto-tty.txt"; assert_grep '¿Qué quieres analizar?' "$TMP/menu-auto-tty.txt"
  printf '11\n2\n' | script -qfec "$BASE_DIR/sysdiag.sh --menu --no-color" /dev/null > "$TMP/menu-containers-deep.txt"; assert_grep 'Modo de contenedores' "$TMP/menu-containers-deep.txt"
fi

"$BASE_DIR/sysdiag.sh" --guide --no-color > "$TMP/guide.txt"
for p in '^GUÍA TÉCNICA DE DIAGNÓSTICO Y COMANDOS$' 'Datos → hipótesis → prueba que discrimina' 'KUBERNETES / OPENSHIFT'; do assert_grep "$p" "$TMP/guide.txt"; done
printf '13\n' | "$BASE_DIR/sysdiag.sh" --menu --no-color > "$TMP/menu-guide.txt"; assert_grep '^GUÍA TÉCNICA DE DIAGNÓSTICO Y COMANDOS$' "$TMP/menu-guide.txt"
"$BASE_DIR/sysdiag.sh" --section guide --no-color > "$TMP/guide-section.txt"; assert_grep '^GUÍA TÉCNICA DE DIAGNÓSTICO Y COMANDOS$' "$TMP/guide-section.txt"
printf '14\n' | "$BASE_DIR/sysdiag.sh" --menu --no-color > "$TMP/menu-all.txt"; assert_grep 'Ámbito: all' "$TMP/menu-all.txt"

set +e; "$BASE_DIR/sysdiag.sh" --menu --json >"$TMP/menu-json.out" 2>"$TMP/menu-json.err"; rc=$?; set -e; (( rc == 2 )) || fail '--menu --json debía fallar'; assert_grep 'no es compatible con --json' "$TMP/menu-json.err"
set +e; "$BASE_DIR/sysdiag.sh" --section guide --json >"$TMP/guide-json.out" 2>"$TMP/guide-json.err"; rc=$?; set -e; (( rc == 2 )) || fail '--guide --json debía fallar'; assert_grep 'no es compatible con --json' "$TMP/guide-json.err"
K8S_CLI_OVERRIDE=definitely-no "$BASE_DIR/sysdiag.sh" --section all --json > "$TMP/section-all.json"
python3 - "$TMP/section-all.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); assert x['scope']==['all'] and x['engine']=='go-core' and x['read_only'] is True
PY

pass cli
