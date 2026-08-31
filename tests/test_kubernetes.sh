#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"
TMP="$TEST_TMP_ROOT/kubernetes"; mkdir -p "$TMP/mockbin"

cat > "$TMP/mockbin/kubectl" <<'MOCK'
#!/usr/bin/env bash
args="$*"
case "$args" in
  "version --client --output=yaml") printf 'clientVersion:\n  gitVersion: v1.37.0\n'; exit 0 ;;
  "get --raw=/version") printf '{"gitVersion":"v1.37.0"}\n'; exit 0 ;;
  "config current-context") echo prod; exit 0 ;;
  "config view --minify -o jsonpath={.clusters[0].cluster.server}") echo -n https://api.example:6443; exit 0 ;;
  "config view --minify -o jsonpath={.contexts[0].context.user}") echo -n fallback-user; exit 0 ;;
  "auth whoami -o name") echo alice; exit 0 ;;
  auth\ can-i*) echo yes; exit 0 ;;
  "api-resources --api-group=config.openshift.io -o name") exit 0 ;;
  "version --output=yaml") printf 'serverVersion:\n  gitVersion: v1.31.9\n'; exit 0 ;;
esac

if [[ "$args" == get\ nodes* ]]; then
  printf 'worker-01\tTrue\tFalse\tFalse\tFalse\tfalse\t4\t8Gi\n'
  printf 'worker-02\tTrue\tTrue\tFalse\tFalse\tfalse\t8\t16Gi\n'
  exit 0
fi
if [[ "$args" == *"get pods -n store -l app=api"* ]]; then
  printf 'False\n'; exit 0
fi
if [[ "$args" == get\ pods* ]]; then
  printf 'store\tapi-abc\tRunning\tFalse\tworker-02\t18\t<none>\tOOMKilled\t137\t<none>\n'
  printf 'store\tpostgres-0\tPending\tFalse\t<none>\t0\t<none>\t<none>\t<none>\t<none>\n'
  exit 0
fi
if [[ "$args" == get\ events* ]]; then
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'store\tWarning\tUnhealthy\tPod\tapi-abc\tReadiness probe failed: HTTP probe failed with statuscode: 503\t%s\t<none>\t<none>\t%s\n' "$ts" "$ts"
  printf 'store\tWarning\tUnhealthy\tPod\tapi-abc\tLiveness probe failed: HTTP probe failed with statuscode: 503\t%s\t<none>\t<none>\t%s\n' "$ts" "$ts"
  printf 'store\tWarning\tKilling\tPod\tapi-abc\tContainer api failed liveness probe, will be restarted\t%s\t<none>\t<none>\t%s\n' "$ts" "$ts"
  printf 'store\tWarning\tFailedScheduling\tPod\tpostgres-0\tpod has unbound immediate PersistentVolumeClaims\t%s\t<none>\t<none>\t%s\n' "$ts" "$ts"
  printf 'store\tWarning\tFailedMount\tPod\told-pod\tMountVolume.SetUp failed: historical event\t2000-01-01T00:00:00Z\t<none>\t<none>\t2000-01-01T00:00:00Z\n'
  exit 0
fi
if [[ "$args" == get\ storageclass* ]]; then [[ -f "__TMP__/storageclass.fail" ]] && exit 1; printf 'standard\nfast\n'; exit 0; fi
if [[ "$args" == get\ pvc* ]]; then printf 'store\tpostgres-data\tPending\t<none>\tpremium-db\n'; exit 0; fi
if [[ "$args" == get\ endpointslices.discovery.k8s.io* ]]; then [[ -f "__TMP__/endpointslice.fail" ]] && exit 1; exit 0; fi
if [[ "$args" == get\ services* ]]; then printf 'store\tapi\tClusterIP\tmap[app:api]\tfalse\n'; exit 0; fi
if [[ "$args" == *"get service -n store api -o go-template="* ]]; then printf 'app=api'; exit 0; fi
if [[ "$args" == get\ deployments.apps* ]]; then printf 'store\tapi\t2\t0\t2\n'; exit 0; fi
if [[ "$args" == get\ statefulsets.apps* ]]; then printf 'store\tpostgres\t1\t0\n'; exit 0; fi
if [[ "$args" == get\ daemonsets.apps* ]]; then exit 0; fi
if [[ "$args" == "top nodes --no-headers" ]]; then printf 'worker-01 100m 2%% 1Gi 12%%\nworker-02 250m 3%% 4Gi 25%%\n'; exit 0; fi
if [[ "$args" == get\ --raw=/api/v1/nodes/*/proxy/stats/summary ]]; then printf '{"node":{"nodeName":"worker-02"},"pods":[]}\n'; exit 0; fi
printf 'unexpected kubectl args: %s\n' "$args" >&2
exit 1
MOCK
sed -i "s|__TMP__|$TMP|g" "$TMP/mockbin/kubectl"
chmod +x "$TMP/mockbin/kubectl"
export SYSDIAG_TRUSTED_PATH="$TMP/mockbin:/usr/bin:/bin"

PATH="$TMP/mockbin:$PATH" K8S_CLI_OVERRIDE=kubectl "$BASE_DIR/sysdiag-legacy.sh" --section kubernetes --k8s-mode deep --verbose --explain --no-color > "$TMP/out.txt"
for pat in '^KUBERNETES / OPENSHIFT$' 'Acceso API:.*disponible' 'Memory/Disk/PID Pressure:.*1 / 0 / 0' \
  'Pods inspeccionados:.*2' 'PVC Pending:.*1' 'Services sin endpoint / sin Ready:.*1 / 0' \
  'K8S_POD_OOM' 'K8S_READINESS' 'K8S_LIVENESS' 'K8S_PVC_SC' 'K8S_SVC_READINESS' 'premium-db' \
  'DNS → Service → EndpointSlice → Pod IP/puerto → aplicación'; do assert_grep "$pat" "$TMP/out.txt"; done
assert_no_grep 'problema de CNI' "$TMP/out.txt"
assert_no_grep 'K8S_MOUNT_' "$TMP/out.txt"

PATH="$TMP/mockbin:$PATH" K8S_CLI_OVERRIDE=kubectl "$BASE_DIR/sysdiag.sh" --section kubernetes --k8s-mode deep --json > "$TMP/out.json"
python3 - "$TMP/out.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1],encoding='utf-8'))
k=x['metrics']['kubernetes']
assert x['sysdiag_version']=='0.14.1'
assert k['access']=='disponible'
assert k['nodes']==2 and k['memory_pressure_nodes']==1
assert k['pods']==2 and k['pods_oomkilled']==1 and k['pods_pending']==1
assert k['pvc_pending']==1 and k['services_no_endpoints']==1
assert k['warning_events']==5 and k['warning_events_recent']==4 and k['warning_events_stale']==1
assert k['failed_mount']==0
assert any(i['reason']=='Pods seleccionados no Ready' for i in k['service_issues'])
assert 'kubernetes' in {s['category'] for s in x['summary']}
ids={c['id'] for c in x.get('conclusions',[])}
assert any(i.startswith('corr-liveness-restarts-') for i in ids), ids
assert any(i.startswith('corr-k8s-storageclass-pvc-') for i in ids), ids
assert any(i.startswith('corr-service-readiness-') for i in ids), ids
assert not any(i.startswith('corr-k8s-cgroup-oom-') for i in ids), ids  # OOM está en worker-02, que tiene MemoryPressure=True
PY

# Missing visibility must become a limitation, never a synthetic absence.
touch "$TMP/storageclass.fail" "$TMP/endpointslice.fail"
PATH="$TMP/mockbin:$PATH" K8S_CLI_OVERRIDE=kubectl \
  "$BASE_DIR/sysdiag.sh" --section kubernetes --k8s-mode deep --json > "$TMP/limited-visibility.json"
rm -f "$TMP/storageclass.fail" "$TMP/endpointslice.fail"
python3 - "$TMP/limited-visibility.json" <<'PY_LIMITED'
import json,sys
x=json.load(open(sys.argv[1],encoding='utf-8'))
ids={f['id'] for f in x['findings']}
conclusions={c['id'] for c in x.get('conclusions',[])}
k=x['metrics']['kubernetes']
assert not any(i.startswith('K8S_PVC_SC_') for i in ids), ids
assert any(i.startswith('K8S_PVC_PENDING_') for i in ids), ids
assert not any(i.startswith('K8S_SVC_SELECTOR_') or i.startswith('K8S_SVC_READINESS_') for i in ids), ids
assert not any(i.startswith('corr-k8s-storageclass-pvc-') for i in conclusions), conclusions
assert k['services_no_endpoints']==0, k['services_no_endpoints']
assert any('StorageClass' in l and 'no interpretará' in l for l in x['limitations']), x['limitations']
assert any('EndpointSlices' in l and 'no interpretará' in l for l in x['limitations']), x['limitations']
PY_LIMITED

# Missing client must be LIMITED rather than healthy.
PATH="/usr/bin:/bin" K8S_CLI_OVERRIDE=definitely-not-a-command "$BASE_DIR/sysdiag.sh" --section kubernetes --no-color > "$TMP/no-client.txt" || true
assert_grep 'No se encontró kubectl ni oc\|no hay una sesión válida\|no puede ejecutarse' "$TMP/no-client.txt"

pass kubernetes
