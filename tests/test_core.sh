#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"
TMP="$TEST_TMP_ROOT/core"; mkdir -p "$TMP"

bash -n "$BASE_DIR/sysdiag.sh"; bash -n "$BASE_DIR/sysdiag-standalone.sh"; bash -n "$BASE_DIR/build-standalone.sh"
for f in "$BASE_DIR"/lib/*.sh "$BASE_DIR"/modules/*.sh "$BASE_DIR"/tests/*.sh; do bash -n "$f"; done

# Single version source: launcher/builder should not hardcode the release.
[[ "$(grep -RIl '^SYS_DIAG_VERSION=' "$BASE_DIR/lib" "$BASE_DIR/modules" "$BASE_DIR/sysdiag.sh" "$BASE_DIR/build-standalone.sh" | wc -l)" == 1 ]] || fail "la versión no tiene una única fuente"
assert_grep 'SYS_DIAG_VERSION="0.14.2"' "$BASE_DIR/lib/version.sh"

# The Go renderer must expose stable structured system data; alignment is no longer
# tested by scraping the legacy table layout.
"$BASE_DIR/sysdiag.sh" --section system --json > "$TMP/system.json"
python3 - "$TMP/system.json" <<'PY_SYS'
import json,sys
x=json.load(open(sys.argv[1],encoding='utf-8'))
assert x['sysdiag_version']=='0.14.2' and x['schema_version']=='1.1'
assert 'system' in x['metrics'] and x['read_only'] is True
PY_SYS

# CPU idle and iowait stay independent.
(
  source "$BASE_DIR/lib/common.sh"; source "$BASE_DIR/modules/cpu.sh"
  calculate_cpu_metrics 'cpu 100 0 50 1000 100 10 20 0 0 0' 'cpu 200 0 100 1200 200 20 40 0 0 0'
  awk -v v="$CPU_IDLE_PCT" 'BEGIN{exit !(v>41 && v<42)}'
  awk -v v="$CPU_IOWAIT_PCT" 'BEGIN{exit !(v>20 && v<22)}'
  awk -v v="$CPU_BUSY_PCT" 'BEGIN{exit !(v>37 && v<38)}'
)

# Findings/recommendations deduplicate.
(
  source "$BASE_DIR/lib/common.sh"; source "$BASE_DIR/lib/scoring.sh"
  init_scoring
  add_finding TEST_A io device_latency 3 medium x; add_finding TEST_A io device_latency 3 medium x
  [[ "${SCORE[io]}" == 3 && "${DOMAIN_COUNT[io]}" == 1 ]]
  add_next_step Paso cmd1 cmd1 cmd2; add_next_step Paso cmd3
  [[ ${#NEXT_STEPS[@]} -eq 1 && "${NEXT_COMMANDS[0]}" == $'cmd1\ncmd2' ]]
)

# Counter reader does not shift columns when a metric is absent.
(
  source "$BASE_DIR/lib/common.sh"; source "$BASE_DIR/lib/sampler.sh"
  cat > "$TMP/mib" <<'MIB'
TcpExt: Foo Bar
TcpExt: 10 20
MIB
  [[ "$(_sampler_tcp_value "$TMP/mib" TcpExt Foo)" == 10 ]]
  [[ "$(_sampler_tcp_value "$TMP/mib" TcpExt MissingCounter)" == 0 ]]
)

# Shared sampling is reused and late iostat request is explicitly limited.
(
  source "$BASE_DIR/lib/common.sh"; source "$BASE_DIR/lib/scoring.sh"; source "$BASE_DIR/lib/sampler.sh"
  init_scoring; SAMPLE_SECONDS=1; SHARED_SAMPLE_READY=0; SHARED_SAMPLE_IOSTAT_REQUESTED=0; RUNTIME_DIR="$TMP"
  ensure_shared_sample 0; first="$SAMPLE_EPOCH_A"; ensure_shared_sample 0
  [[ "$SAMPLE_EPOCH_A" == "$first" && "$SHARED_SAMPLE_READY" == 1 ]]
  ensure_shared_sample 1
  printf '%s\n' "${LIMITATIONS[@]}" | grep -q 'ya se tomó sin iostat'
)

# Untrusted terminal text must lose ESC/control bytes.
printf $'ok\033[31mBAD\033[0m\n' | ( source "$BASE_DIR/lib/common.sh"; sanitize_terminal_text ) > "$TMP/sanitize.txt"
assert_no_grep $'\033' "$TMP/sanitize.txt"
assert_grep 'okBAD' "$TMP/sanitize.txt"

pass core
