#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"
TMP="$TEST_TMP_ROOT/logging"; mkdir -p "$TMP/mockbin"

(
  source "$BASE_DIR/lib/common.sh"; source "$BASE_DIR/lib/scoring.sh"; source "$BASE_DIR/modules/logging.sh"
  [[ "$(parse_journald_storage $'# x\nStorage=auto\n# Storage=persistent\nStorage=volatile')" == volatile ]]
  read -r c d ct cr pr <<<"$(parse_logrotate_directives $'compress\ndelaycompress\ncopytruncate\ncreate 0640 root adm\npostrotate\n  echo x\nendscript')"
  [[ "$c $d $ct $cr $pr" == "1 1 1 1 1" ]]
  _logging_remote_fstype nfs; _logging_remote_fstype cifs; _logging_remote_fstype ceph
  ! _logging_remote_fstype ext4

  init_scoring
  JOURNALD_FAILED=failed; JOURNALD_STORAGE_CONFIG=volatile; RSYSLOG_FAILED=failed; LOGROTATE_SERVICE_FAILED=failed
  VAR_LOG_USE_PCT=90; LOGROTATE_COPYTRUNCATE_COUNT=1
  analyze_logging
  (( SCORE[logging] >= 8 )); [[ "$(confidence_for_category logging)" == ALTA ]]
  printf '%s\n' "${EVIDENCE[@]}" | grep -q LOG_JOURNALD_FAILED
  printf '%s\n' "${LIMITATIONS[@]}" | grep -q volatile
  printf '%s\n' "${NEXT_COMMANDS[@]}" | grep -q 'lsof -nP +L1'
)

"$BASE_DIR/sysdiag-legacy.sh" --section logging --no-color > "$TMP/logging.txt"
for pattern in '^LOGS Y JOURNAL$' 'Boots visibles en journal:' 'copytruncate / create:' 'journalctl -k -b -1 --no-pager' '^ANÁLISIS Y PRIORIZACIÓN$'; do
  assert_grep "$pattern" "$TMP/logging.txt"
done

# /var/log on a known remote FS must not trigger df or find traversal.
cat > "$TMP/mockbin/findmnt" <<EOF_M
#!/usr/bin/env bash
if [[ "\$*" == *'-T /var/log'* ]]; then echo 'server:/logs nfs'; exit 0; fi
exec "$(command -v findmnt)" "\$@"
EOF_M
cat > "$TMP/mockbin/df" <<EOF_M
#!/usr/bin/env bash
if [[ "\$*" == *'/var/log'* ]]; then echo df-var-log >> "$TMP/calls"; fi
exec "$(command -v df)" "\$@"
EOF_M
cat > "$TMP/mockbin/find" <<EOF_M
#!/usr/bin/env bash
if [[ "\$*" == '/var/log -xdev -maxdepth 2 '* ]]; then echo find-var-log >> "$TMP/calls"; fi
exec "$(command -v find)" "\$@"
EOF_M
chmod +x "$TMP/mockbin"/*
: > "$TMP/calls"
PATH="$TMP/mockbin:$PATH" bash -c '
  source "$0/lib/common.sh"; source "$0/lib/scoring.sh"; source "$0/modules/logging.sh"
  init_scoring; collect_logging
  [[ "$VAR_LOG_REMOTE" == 1 ]]
  [[ "$VAR_LOG_TOP_SCAN" == omitido* ]]
' "$BASE_DIR"
[[ ! -s "$TMP/calls" ]] || fail "se accedió automáticamente a /var/log remoto: $(cat "$TMP/calls")"

# Recent events: cap, severity split, dmesg dedup and terminal sanitization.
cat > "$TMP/mockbin/journalctl" <<'MOCK'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *'-k '* && "$args" == *'-o cat'* ]]; then
  echo 'duplicate kernel'
  exit 0
fi
if [[ "$args" == *'-p 0..3'* ]]; then
  for i in $(seq 1 21); do printf '2026-08-24T10:00:%02d+00:00 host app: error-%02d\n' "$((i%60))" "$i"; done
  exit 0
fi
if [[ "$args" == *'-p 4..4'* ]]; then
  printf '2026-08-24T10:10:00+00:00 host app: warn-\033[31minjected\033[0m\n'
  exit 0
fi
exit 0
MOCK
cat > "$TMP/mockbin/dmesg" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *'--help'* ]]; then
  echo '--since --level --time-format --notime'; exit 0
fi
if [[ "$*" == *'--level=emerg,alert,crit,err'* ]]; then
  if [[ "$*" == *'--notime'* ]]; then
    printf 'duplicate kernel\nunique kernel error\n'
  else
    printf '2026-08-24T10:11:00+00:00 duplicate kernel\n2026-08-24T10:12:00+00:00 unique kernel error\n'
  fi
  exit 0
fi
if [[ "$*" == *'--level=warn'* ]]; then
  if [[ "$*" == *'--notime'* ]]; then echo 'unique kernel warn'; else echo '2026-08-24T10:13:00+00:00 unique kernel warn'; fi
  exit 0
fi
exit 0
MOCK
chmod +x "$TMP/mockbin/journalctl" "$TMP/mockbin/dmesg"
PATH="$TMP/mockbin:$PATH" "$BASE_DIR/sysdiag-legacy.sh" --recent-errors --no-color > "$TMP/recent.txt"
assert_grep '^WARNINGS Y ERRORES RECIENTES$' "$TMP/recent.txt"
assert_grep 'JOURNAL — ERROR / CRITICAL' "$TMP/recent.txt"
assert_grep 'Se muestran solo los 20 eventos más recientes' "$TMP/recent.txt"
assert_grep 'Duplicados ya vistos en journal:.*1' "$TMP/recent.txt"
assert_grep 'unique kernel error' "$TMP/recent.txt"
assert_no_grep 'duplicate kernel$' "$TMP/recent.txt"
assert_no_grep $'\033' "$TMP/recent.txt"
assert_grep 'warn-injected' "$TMP/recent.txt"
assert_grep 'no convierte automáticamente estas líneas en findings' "$TMP/recent.txt"


# Regression: a failed --list-boots query is unknown, never "0 boots".
mkdir -p "$TMP/mockfail"
cat > "$TMP/mockfail/journalctl" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  '--list-boots --no-pager') exit 1 ;;
  '--disk-usage --no-pager') echo 'Archived and active journals take up 1M.'; exit 0 ;;
  *) exit 0 ;;
esac
MOCK
cat > "$TMP/mockfail/systemctl" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
cat > "$TMP/mockfail/systemd-analyze" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
chmod +x "$TMP/mockfail"/*
(
  export PATH="$TMP/mockfail:$PATH"
  source "$BASE_DIR/lib/common.sh"; source "$BASE_DIR/lib/scoring.sh"; source "$BASE_DIR/modules/logging.sh"
  init_scoring; collect_logging
  [[ "$JOURNAL_BOOT_QUERY_VALID" == 0 ]]
  [[ "$JOURNAL_BOOT_COUNT" == n/d ]]
  printf '%s\n' "${LIMITATIONS[@]}" | grep -q 'no se asume que haya 0 boots'
)

pass logging
