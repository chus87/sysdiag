#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"
TMP="$TEST_TMP_ROOT/systemd"; mkdir -p "$TMP/mockbin" "$TMP/proc/1"
printf 'systemd\n' > "$TMP/proc/1/comm"

cat > "$TMP/mockbin/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSTEMD_TEST_CALLS:?}"
case "$*" in
  '--version')
    printf 'systemd 255 (255.7-test)\n+PAM +AUDIT\n'; exit 0 ;;
  'is-system-running')
    echo degraded; exit 1 ;;
  'get-default')
    echo multi-user.target; exit 0 ;;
  '--failed --no-legend --plain --no-pager')
    cat <<'OUT'
api.service loaded failed failed API service
backup.timer loaded failed failed Backup timer
OUT
    exit 0 ;;
  'list-timers --all --no-legend --plain --no-pager')
    printf 'Mon 2026-08-24 22:00:00 CEST 10min - - a.timer a.service\n'
    printf 'Tue 2026-08-25 00:00:00 CEST 2h - - b.timer b.service\n'
    exit 0 ;;
  show*api.service)
    printf 'Id=api.service\nDescription=API \033[31mred\033[0m | production\n'
    cat <<'OUT'
LoadState=loaded
ActiveState=failed
SubState=failed
UnitFileState=enabled
Result=start-limit-hit
MainPID=0
ExecMainCode=1
ExecMainStatus=1
Restart=on-failure
NRestarts=4
FragmentPath=/etc/systemd/system/api.service
OUT
    exit 0 ;;
  show*backup.timer)
    cat <<'OUT'
Id=backup.timer
Description=Backup timer
LoadState=loaded
ActiveState=failed
SubState=failed
UnitFileState=enabled
Result=resources
MainPID=0
ExecMainCode=0
ExecMainStatus=0
Restart=no
NRestarts=0
FragmentPath=/usr/lib/systemd/system/backup.timer
OUT
    exit 0 ;;
  *)
    echo "unexpected systemctl args: $*" >&2; exit 2 ;;
esac
MOCK

cat > "$TMP/mockbin/journalctl" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  *'_PID=1'*)
    cat <<'OUT'
api.service: Scheduled restart job, restart counter is at 3.
api.service: Scheduled restart job, restart counter is at 4.
api.service: Scheduled restart job, restart counter is at 5.
api.service: Scheduled restart job, restart counter is at 6.
api.service: Start request repeated too quickly.
Dependency failed for worker.service.
OUT
    exit 0 ;;
  *'-u api.service'*)
    printf '2026-08-24T20:00:00+00:00 host api[100]: bind: address already in use\n'; exit 0 ;;
  *'-u backup.timer'*)
    printf '2026-08-24T20:01:00+00:00 host systemd[1]: backup.timer failed\n'; exit 0 ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "$TMP/mockbin/systemctl" "$TMP/mockbin/journalctl"
: > "$TMP/calls"

(
  export PATH="$TMP/mockbin:$PATH" SYSTEMD_PROC_ROOT="$TMP/proc" SYSTEMD_TEST_CALLS="$TMP/calls"
  source "$BASE_DIR/lib/common.sh"; source "$BASE_DIR/lib/scoring.sh"; source "$BASE_DIR/modules/systemd_services.sh"
  init_scoring; collect_systemd_services; analyze_systemd_services
  [[ "$SYSTEMD_PID1" == 1 ]]
  [[ "$SYSTEMD_SYSTEM_STATE" == degraded ]]
  [[ "$SYSTEMD_DEFAULT_TARGET" == multi-user.target ]]
  [[ "$SYSTEMD_FAILED_UNITS_COUNT" == 2 && "$SYSTEMD_FAILED_SERVICES_COUNT" == 1 ]]
  [[ "$SYSTEMD_FAILED_QUERY_VALID" == 1 ]]
  [[ "$SYSTEMD_TIMER_COUNT" == 2 && "$SYSTEMD_TIMER_QUERY_VALID" == 1 ]]
  [[ "$SYSTEMD_MANAGER_JOURNAL_VALID" == 1 ]]
  [[ "$SYSTEMD_START_LIMIT_HITS" == 1 ]]
  [[ "$SYSTEMD_RESTART_HINTS" == 4 ]]
  [[ "$SYSTEMD_DEPENDENCY_FAILURES" == 1 ]]
  (( SCORE[systemd] >= 9 ))
  [[ "$(confidence_for_category systemd)" == ALTA ]]
  printf '%s\n' "${EVIDENCE[@]}" | grep -q SYSTEMD_FAILED_UNITS
  printf '%s\n' "${EVIDENCE[@]}" | grep -q SYSTEMD_START_LIMIT
  printf '%s\n' "${EVIDENCE[@]}" | grep -q SYSTEMD_DEPENDENCY_FAILURE
  [[ "${SYSTEMD_FAILED_DETAILS[0]}" == *'API red ¦ production'* ]]
  [[ -z "${SYSTEMD_FAILED_LOGS[0]:-}" ]]  # per-unit journal is verbose-only
)

SYSTEMD_PROC_ROOT="$TMP/proc" SYSTEMD_TEST_CALLS="$TMP/calls" PATH="$TMP/mockbin:$PATH" \
  "$BASE_DIR/sysdiag-legacy.sh" --section systemd --no-color --verbose --explain > "$TMP/systemd.txt"
for pattern in '^SYSTEMD / SERVICIOS$' 'API red ¦ production' 'Estado del sistema:.*degraded' 'Unidades failed:.*2' \
  'api.service' 'bind: address already in use' 'start-limit' '^ANÁLISIS Y PRIORIZACIÓN$' 'After=/Before= expresan orden' \
  'systemctl cat <unidad>' 'journalctl -b -u <unidad>'; do
  assert_grep "$pattern" "$TMP/systemd.txt"
done
assert_no_grep $'\033' "$TMP/systemd.txt"

# No command that mutates systemd state may be executed by the collector.
if grep -Eq '(^| )(start|stop|restart|reload|enable|disable|mask|unmask|reset-failed|daemon-reload)( |$)' "$TMP/calls"; then
  fail "systemd collector ejecutó una acción de cambio: $(cat "$TMP/calls")"
fi

# Non-systemd PID1 must become LIMITED and must not query the system manager.
mkdir -p "$TMP/proc-other/1"; printf 'supervisord\n' > "$TMP/proc-other/1/comm"
: > "$TMP/calls-other"
SYSTEMD_PROC_ROOT="$TMP/proc-other" SYSTEMD_TEST_CALLS="$TMP/calls-other" PATH="$TMP/mockbin:$PATH" \
  "$BASE_DIR/sysdiag-legacy.sh" --section systemd --no-color > "$TMP/non-systemd.txt"
assert_grep "PID 1 no es systemd" "$TMP/non-systemd.txt"
assert_grep 'identificar el supervisor real' "$TMP/non-systemd.txt"
# --version is permitted before PID1 is checked; no manager operations should occur.
assert_no_grep '^is-system-running$' "$TMP/calls-other"
assert_no_grep '^--failed ' "$TMP/calls-other"



# A failed --failed query is not equivalent to zero failed units.
mkdir -p "$TMP/mockfail"
cat > "$TMP/mockfail/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  '--version') echo 'systemd 255 (test)'; exit 0 ;;
  'is-system-running') echo running; exit 0 ;;
  'get-default') echo multi-user.target; exit 0 ;;
  '--failed --no-legend --plain --no-pager') exit 1 ;;
  'list-timers --all --no-legend --plain --no-pager') exit 0 ;;
  *) exit 0 ;;
esac
MOCK
cp "$TMP/mockbin/journalctl" "$TMP/mockfail/journalctl"
chmod +x "$TMP/mockfail/systemctl" "$TMP/mockfail/journalctl"
(
  export PATH="$TMP/mockfail:$PATH" SYSTEMD_PROC_ROOT="$TMP/proc" SYSTEMD_TEST_CALLS="$TMP/calls"
  source "$BASE_DIR/lib/common.sh"; source "$BASE_DIR/lib/scoring.sh"; source "$BASE_DIR/modules/systemd_services.sh"
  init_scoring; collect_systemd_services; analyze_systemd_services
  [[ "$SYSTEMD_FAILED_QUERY_VALID" == 0 ]]
  [[ "$SYSTEMD_FAILED_UNITS_COUNT" == 0 ]]
  summary_category_is_limited systemd
  printf '%s\n' "${LIMITATIONS[@]}" | grep -q 'no se asume que haya 0 unidades fallidas'
)

# A blocked system manager must fail fast after the first timed-out probe.
mkdir -p "$TMP/mocktimeout"
cat > "$TMP/mocktimeout/timeout" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *'systemctl is-system-running'* ]]; then exit 124; fi
exec /usr/bin/timeout "$@"
MOCK
chmod +x "$TMP/mocktimeout/timeout"
: > "$TMP/calls-timeout"
(
  export PATH="$TMP/mocktimeout:$TMP/mockbin:$PATH" SYSTEMD_PROC_ROOT="$TMP/proc" SYSTEMD_TEST_CALLS="$TMP/calls-timeout"
  source "$BASE_DIR/lib/common.sh"; source "$BASE_DIR/lib/scoring.sh"; source "$BASE_DIR/modules/systemd_services.sh"
  init_scoring; collect_systemd_services; analyze_systemd_services
  [[ "$SYSTEMD_ACCESS" == timeout ]]
  printf '%s\n' "${LIMITATIONS[@]}" | grep -q 'se omiten más consultas al manager'
  printf '%s\n' "${NEXT_STEPS[@]}" | grep -q 'no respondió de forma fiable'
)
assert_no_grep '^--failed ' "$TMP/calls-timeout"
assert_no_grep '^get-default$' "$TMP/calls-timeout"

pass systemd
