#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"
TMP="$TEST_TMP_ROOT/containers"; mkdir -p "$TMP/mockbin" "$TMP/docker-root" "$TMP/proc/111" "$TMP/proc/222" "$TMP/cgroup/docker/c1" "$TMP/cgroup/docker/c2"
truncate -s 1048576 "$TMP/web.log"
truncate -s 115343360 "$TMP/worker.log"
printf '0::/docker/c1\n' > "$TMP/proc/111/cgroup"
printf '0::/docker/c2\n' > "$TMP/proc/222/cgroup"
printf 'nr_periods 10\nnr_throttled 1\nthrottled_usec 1000\n' > "$TMP/cgroup/docker/c1/cpu.stat"
printf 'nr_periods 10\nnr_throttled 0\nthrottled_usec 0\n' > "$TMP/cgroup/docker/c2/cpu.stat"

cat > "$TMP/mockbin/docker" <<MOCK
#!/usr/bin/env bash
case "\${1:-}" in
  context)
    if [[ "\${2:-}" == show ]]; then echo default; exit 0; fi
    if [[ "\${2:-}" == inspect ]]; then echo 'unix:///var/run/docker.sock'; exit 0; fi ;;
  info)
    echo '28.0.1|$TMP/docker-root|overlay2|json-file|systemd|2'; exit 0 ;;
  ps)
    printf 'c1\nc2\nc3\n'; exit 0 ;;
  inspect)
    cat <<'OUT'
c1|/web|example/web:1|running|0|false|111|0|healthy|1073741824|1000000000|0|0|false|bridge|unless-stopped|json-file|$TMP/web.log|/srv/web=>/data,
c2|/worker|example/worker:1|restarting|1|false|222|25|unhealthy|536870912|1000000000|0|0|false|bridge|always|json-file|$TMP/worker.log|/var/run/docker.sock=>/var/run/docker.sock,
c3|/batch|example/batch:1|exited|137|true|0|2|none|1073741824|0|0|0|true|host|no|json-file||
OUT
    exit 0 ;;
  logs)
    if [[ "\${CONTAINER_TEST_LOGS_FAIL:-0}" == 1 ]]; then
      printf 'Error response from daemon: connection refused token=runtime-secret\n' >&2
      exit 1
    fi
    case "\${3:-}" in
      c1) printf '2026-08-31T08:00:00Z service started\n' ;;
      c2) printf '2026-08-31T08:01:00Z ERROR database connection failed: connection refused token=supersecret\n2026-08-31T08:01:01Z permission denied opening /data/state\n' ;;
      c3) printf '2026-08-31T08:02:00Z fatal error: cannot allocate memory\n' ;;
    esac
    exit 0 ;;
  stats)
    printf 'nr_periods 20\nnr_throttled 7\nthrottled_usec 9000\n' > '$TMP/cgroup/docker/c1/cpu.stat'
    printf 'nr_periods 20\nnr_throttled 0\nthrottled_usec 0\n' > '$TMP/cgroup/docker/c2/cpu.stat'
    cat <<'OUT'
c1|web|95.0%|92.0%|988MiB / 1GiB|1MB / 2MB|8
c2|worker|10.0%|50.0%|256MiB / 512MiB|1MB / 1MB|4
OUT
    exit 0 ;;
  volume) printf 'v1\nv2\n'; exit 0 ;;
  network) printf 'n1\nn2\nn3\n'; exit 0 ;;
  image) printf 'i1\ni2\ni2\n'; exit 0 ;;
esac
exit 1
MOCK
# Expand test paths inside inspect output.
sed -i "s|\$TMP|$TMP|g" "$TMP/mockbin/docker"
chmod +x "$TMP/mockbin/docker"

CONTAINER_PROC_ROOT="$TMP/proc" CONTAINER_CGROUP2_MOUNT_OVERRIDE="$TMP/cgroup" PATH="$TMP/mockbin:$PATH" "$BASE_DIR/sysdiag-legacy.sh" --section containers --verbose --explain --no-color > "$TMP/docker.txt"
for pat in '^CONTENEDORES$' 'Docker:.*disponible' 'Running / restarting:.*1 / 1' 'Healthy / unhealthy / starting:.*1 / 1' \
  'OOMKilled / exit 137:.*1 / 1' 'RestartCount >=10:.*1' 'Memoria >=90% del límite:.*1' 'Privileged / docker.sock:.*1 / 1' 'CPU cerca de cuota / throttled:.*1 / 1' \
  'CONTAINER_RESTARTING' 'CONTAINER_UNHEALTHY' 'CONTAINER_OOMKILLED' 'CONTAINER_MEMORY_PRESSURE' 'CONTAINER_CPU_THROTTLE' 'CONTAINER_LOG_GROWTH'; do
  assert_grep "$pat" "$TMP/docker.txt"
done
assert_grep 'web' "$TMP/docker.txt"; assert_grep 'worker' "$TMP/docker.txt"

CONTAINER_PROC_ROOT="$TMP/proc" CONTAINER_CGROUP2_MOUNT_OVERRIDE="$TMP/cgroup" printf 'nr_periods 10\nnr_throttled 1\nthrottled_usec 1000\n' > "$TMP/cgroup/docker/c1/cpu.stat"
printf 'nr_periods 10\nnr_throttled 0\nthrottled_usec 0\n' > "$TMP/cgroup/docker/c2/cpu.stat"
CONTAINER_PROC_ROOT="$TMP/proc" CONTAINER_CGROUP2_MOUNT_OVERRIDE="$TMP/cgroup" PATH="$TMP/mockbin:$PATH" "$BASE_DIR/sysdiag-legacy.sh" --section containers --json > "$TMP/docker.json"
python3 - "$TMP/docker.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1],encoding='utf-8'))
c=x['metrics']['containers']
assert x['sysdiag_version']=='0.14.1'
assert c['docker_available'] is True and c['docker_access']=='disponible'
assert c['total']==3 and c['restarting']==1 and c['unhealthy']==1 and c['oomkilled']==1
assert c['memory_near_limit']==1 and c['cpu_throttled']==1 and c['privileged']==1 and c['docker_socket_mounts']==1
assert len(c['details'])==3 and len(c['stats'])==2
assert any(d['name']=='worker' and d['restart_count']==25 for d in c['details'])
assert 'containers' in {s['category'] for s in x['summary']}
PY

# Deep mode must inspect every visible container and scan the complete log stream
# without printing the raw log history.
CONTAINER_PROC_ROOT="$TMP/proc" CONTAINER_CGROUP2_MOUNT_OVERRIDE="$TMP/cgroup" PATH="$TMP/mockbin:$PATH" "$BASE_DIR/sysdiag-legacy.sh" --section containers --container-mode deep --verbose --no-color > "$TMP/deep.txt"
assert_grep 'Modo de análisis:.*deep' "$TMP/deep.txt"
assert_grep 'ANÁLISIS PROFUNDO DE CONTENEDORES Y LOGS' "$TMP/deep.txt"
assert_grep 'Contenedores analizados:.*3' "$TMP/deep.txt"
assert_grep 'refused' "$TMP/deep.txt"
assert_grep 'permission' "$TMP/deep.txt"
assert_grep 'memory' "$TMP/deep.txt"
assert_grep 'Posible resolución manual:' "$TMP/deep.txt"
assert_grep 'token=<redacted>' "$TMP/deep.txt"
assert_no_grep 'supersecret' "$TMP/deep.txt"
assert_grep 'CONTAINER_DEEP_LOG_CORRELATION' "$TMP/deep.txt"

CONTAINER_PROC_ROOT="$TMP/proc" CONTAINER_CGROUP2_MOUNT_OVERRIDE="$TMP/cgroup" PATH="$TMP/mockbin:$PATH" "$BASE_DIR/sysdiag-legacy.sh" --section containers --container-mode deep --json > "$TMP/deep.json"
python3 - "$TMP/deep.json" <<'PY_DEEP'
import json,sys
x=json.load(open(sys.argv[1],encoding='utf-8'))
c=x['metrics']['containers']
assert c['mode']=='deep'
assert c['deep_scanned_containers']==3
assert c['deep_pattern_matches'] >= 3
assert c['deep_correlated_containers'] >= 1
cats={i['category'] for i in c['deep_issues']}
assert {'refused','permission','memory'} <= cats
PY_DEEP

# Runtime errors from `docker logs` are not application logs and must not be classified.
CONTAINER_PROC_ROOT="$TMP/proc" CONTAINER_CGROUP2_MOUNT_OVERRIDE="$TMP/cgroup" CONTAINER_TEST_LOGS_FAIL=1 PATH="$TMP/mockbin:$PATH" \
  "$BASE_DIR/sysdiag-legacy.sh" --section containers --container-mode deep --json > "$TMP/deep-log-fail.json"
python3 - "$TMP/deep-log-fail.json" <<'PY_LOGFAIL'
import json,sys
x=json.load(open(sys.argv[1],encoding='utf-8'))
c=x['metrics']['containers']
assert c['deep_pattern_matches']==0, c['deep_pattern_matches']
assert {i['category'] for i in c['deep_issues']} == {'logs'}
assert any('no se interpretará como log de aplicación' in l for l in x['limitations'])
assert not any(f['id']=='CONTAINER_DEEP_LOG_CORRELATION' for f in x['findings'])
PY_LOGFAIL

# A remote Docker endpoint must be skipped before daemon/info queries.
cat > "$TMP/mockbin/docker" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$TMP/docker-remote-calls'
[[ "\${1:-}" == context ]] && { echo default; exit 0; }
[[ "\${1:-}" == info ]] && exit 99
exit 1
MOCK
chmod +x "$TMP/mockbin/docker"; : > "$TMP/docker-remote-calls"
DOCKER_HOST='tcp://docker.example:2376' PATH="$TMP/mockbin:$PATH" "$BASE_DIR/sysdiag-legacy.sh" --section containers --no-color > "$TMP/remote.txt"
assert_grep 'Docker:.*remoto (omitido)' "$TMP/remote.txt"
assert_no_grep '^info' "$TMP/docker-remote-calls"
assert_grep 'endpoint remoto' "$TMP/remote.txt"

# Podman fallback: advanced inspect may fail but basic inventory must survive.
rm -f "$TMP/mockbin/docker"
cat > "$TMP/mockbin/podman" <<MOCK
#!/usr/bin/env bash
case "\${1:-}" in
  info) echo '5.5.2|$TMP/podman-root|overlay|systemd|v2|true'; exit 0 ;;
  ps)
    if [[ "\$*" == *'-aq'* ]]; then printf 'p1\np2\n'; else
      printf 'p1|api|example/api:1|running|0|false|0|12|none|0|0|0|0|false|||none||\n'
      printf 'p2|job|example/job:1|exited|0|false|0|0|none|0|0|0|0|false|||none||\n'
    fi
    exit 0 ;;
  inspect) exit 1 ;;
  stats) printf 'p1|api|2.0%%|10.0%%|100MiB / 1GiB|0B / 0B|3\n'; exit 0 ;;
  volume|network|image) exit 0 ;;
esac
exit 1
MOCK
mkdir -p "$TMP/podman-root"; chmod +x "$TMP/mockbin/podman"
PATH="$TMP/mockbin:$PATH" "$BASE_DIR/sysdiag-legacy.sh" --section containers --verbose --no-color > "$TMP/podman.txt"
assert_grep 'Podman:.*disponible' "$TMP/podman.txt"
assert_grep 'Podman inspect no pudo obtener todos los campos avanzados' "$TMP/podman.txt"
assert_grep 'Contenedores Docker/Podman:.*2' "$TMP/podman.txt"
assert_grep 'RestartCount >=10:.*1' "$TMP/podman.txt"


pass containers
