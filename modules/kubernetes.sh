# Kubernetes/OpenShift diagnostics through the API and existing cluster observability.
# Read-only by design: no apply/create/delete/patch/edit/exec/debug/port-forward/rollout actions.

K8S_MODE="${K8S_MODE:-deep}"
K8S_SCOPE="${K8S_SCOPE:-cluster}"
K8S_TARGET_NODE="${K8S_TARGET_NODE:-}"
K8S_TARGET_NAMESPACE="${K8S_TARGET_NAMESPACE:-}"
K8S_TARGET_POD="${K8S_TARGET_POD:-}"
K8S_CONTEXT="${K8S_CONTEXT:-}"
K8S_KUBECONFIG="${K8S_KUBECONFIG:-}"
K8S_AUTH_PROMPT="${K8S_AUTH_PROMPT:-1}"
K8S_INTERACTIVE_CONFIG="${K8S_INTERACTIVE_CONFIG:-0}"
K8S_DETAIL_LIMIT=200
K8S_EVENT_LIMIT=250
K8S_EVENT_RECENT_MINUTES="${K8S_EVENT_RECENT_MINUTES:-120}"

K8S_CLI=""
K8S_CLIENT_VERSION="n/d"
K8S_ACCESS="no disponible"
K8S_CONTEXT_EFFECTIVE="n/d"
K8S_SERVER="n/d"
K8S_USER="n/d"
K8S_PLATFORM="Kubernetes"
K8S_SERVER_VERSION="n/d"
K8S_OPENSHIFT_VERSION="n/d"
K8S_EFFECTIVE_KUBECONFIG=""
K8S_PERMISSION_DENIED=0
K8S_PERMISSION_CHECKED=0
K8S_NODE_COUNT=0
K8S_NODE_NOTREADY_COUNT=0
K8S_NODE_MEMORY_PRESSURE_COUNT=0
K8S_NODE_DISK_PRESSURE_COUNT=0
K8S_NODE_PID_PRESSURE_COUNT=0
K8S_POD_COUNT=0
K8S_POD_PENDING_COUNT=0
K8S_POD_FAILED_COUNT=0
K8S_POD_NOTREADY_COUNT=0
K8S_POD_HIGH_RESTART_COUNT=0
K8S_POD_OOMKILLED_COUNT=0
K8S_POD_CRASHLOOP_COUNT=0
K8S_POD_IMAGEPULL_COUNT=0
K8S_POD_EVICTED_COUNT=0
K8S_SERVICE_COUNT=0
K8S_SERVICE_NO_ENDPOINT_COUNT=0
K8S_SERVICE_NO_READY_ENDPOINT_COUNT=0
K8S_PVC_COUNT=0
K8S_PVC_PENDING_COUNT=0
K8S_WORKLOAD_DEGRADED_COUNT=0
K8S_WARNING_EVENT_COUNT=0
K8S_WARNING_EVENT_RECENT_COUNT=0
K8S_WARNING_EVENT_STALE_COUNT=0
K8S_WARNING_EVENT_UNKNOWN_TIME_COUNT=0
K8S_FAILED_SCHEDULING_COUNT=0
K8S_PROBE_FAILURE_COUNT=0
K8S_FAILED_MOUNT_COUNT=0
K8S_FAILED_ATTACH_COUNT=0
K8S_STORAGE_PROVISION_FAILURE_COUNT=0
K8S_METRICS_AVAILABLE=0
K8S_KUBELET_STATS_OK_COUNT=0
K8S_KUBELET_STATS_FAIL_COUNT=0
K8S_OPENSHIFT_DEGRADED_OPERATORS=0
K8S_OPENSHIFT_UNAVAILABLE_OPERATORS=0
K8S_OPENSHIFT_MACHINE_FAILED_COUNT=0
K8S_OPENSHIFT_NODE_LOG_HINT_COUNT=0
K8S_STORAGECLASS_LIST_AVAILABLE=0
K8S_ENDPOINTSLICE_LIST_AVAILABLE=0

declare -a K8S_NODE_DETAILS K8S_POD_ISSUES K8S_SERVICE_ISSUES K8S_PVC_ISSUES K8S_WORKLOAD_ISSUES K8S_WARNING_EVENTS K8S_OPENSHIFT_ISSUES K8S_NODE_METRICS
declare -a K8S_SUSPECT_NODES
declare -A K8S_NODE_SUSPECT_SEEN K8S_EP_TOTAL K8S_EP_READY K8S_STORAGECLASS_SEEN
K8S_NODE_DETAILS=(); K8S_POD_ISSUES=(); K8S_SERVICE_ISSUES=(); K8S_PVC_ISSUES=(); K8S_WORKLOAD_ISSUES=(); K8S_WARNING_EVENTS=(); K8S_OPENSHIFT_ISSUES=(); K8S_NODE_METRICS=(); K8S_SUSPECT_NODES=()

_k8s_clean() {
  if (($#)); then
    printf '%s' "${1-}" | sanitize_terminal_text | tr '|' '/' | head -c 600
  else
    sanitize_terminal_text | tr '|' '/' | head -c 600
  fi
}

_k8s_id() {
  printf '%s' "${1-}" | LC_ALL=C tr -c '[:alnum:]_-' '_' | cut -c1-100
}

_k8s_yaml_sq() {
  local x="${1-}"
  x="${x//\'/\'\'}"
  printf "'%s'" "$x"
}

_k8s_sum_ints() {
  local raw="${1-}"
  awk 'BEGIN{s=0} {gsub(/[^0-9]+/," "); for(i=1;i<=NF;i++) s+=$i} END{print s+0}' <<<"$raw"
}

_k8s_count_tokens() {
  local raw="${1-}"
  [[ -n "$raw" && "$raw" != "<none>" ]] || { printf '0'; return; }
  awk 'BEGIN{n=0} {gsub(/[,[:space:]]+/," "); for(i=1;i<=NF;i++) if($i!="<none>" && $i!="") n++} END{print n+0}' <<<"$raw"
}

_k8s_count_true() {
  local raw="${1-}" total="${2:-0}"
  if [[ -z "$raw" || "$raw" == "<none>" ]]; then printf '%s' "$total"; return; fi
  awk 'BEGIN{n=0} {gsub(/[,[:space:]]+/," "); for(i=1;i<=NF;i++) if(tolower($i)=="true" || $i=="<none>") n++} END{print n+0}' <<<"$raw"
}

_k8s_event_is_recent() {
  local ts="${1-}" now epoch age max_age
  [[ -n "$ts" && "$ts" != "<none>" && "$ts" != "n/d" ]] || return 2
  have_cmd date || return 2
  epoch="$(date -d "$ts" +%s 2>/dev/null || true)"
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 2
  now="$(date +%s)"
  [[ "$now" =~ ^[0-9]+$ ]] || return 2
  age=$((now - epoch)); max_age=$((K8S_EVENT_RECENT_MINUTES * 60))
  # Tolera hasta cinco minutos de desfase de reloj entre cliente y cluster.
  (( age >= -300 && age <= max_age ))
}

_k8s_capture() {
  local seconds="$1"; shift
  local -a cmd=("$K8S_CLI")
  [[ -n "$K8S_EFFECTIVE_KUBECONFIG" ]] && cmd+=(--kubeconfig "$K8S_EFFECTIVE_KUBECONFIG")
  [[ -n "$K8S_CONTEXT" ]] && cmd+=(--context "$K8S_CONTEXT")
  cmd+=("$@")
  run_with_timeout "$seconds" "${cmd[@]}"
}

_k8s_scope_args() {
  case "$K8S_SCOPE" in
    namespace|pod) printf '%s\n' -n "$K8S_TARGET_NAMESPACE" ;;
    *) printf '%s\n' -A ;;
  esac
}

_k8s_add_suspect_node() {
  local node="${1-}"
  [[ -n "$node" && "$node" != "<none>" ]] || return 0
  [[ -n "${K8S_NODE_SUSPECT_SEEN[$node]:-}" ]] && return 0
  K8S_NODE_SUSPECT_SEEN[$node]=1
  K8S_SUSPECT_NODES+=("$node")
}

_k8s_prompt_configuration() {
  (( K8S_INTERACTIVE_CONFIG == 1 )) || return 0
  [[ -t 0 && -t 1 ]] || return 0
  local input
  printf '\n  Profundidad Kubernetes/OpenShift:\n'
  printf '    1) Rápido\n    2) Profundo\n    3) Exhaustivo\n'
  printf '  Selecciona [2]: '
  IFS= read -r input || true
  case "${input:-2}" in 1) K8S_MODE=quick ;; 3) K8S_MODE=exhaustive ;; *) K8S_MODE=deep ;; esac
  printf '\n  Ámbito:\n'
  printf '    1) Cluster completo\n    2) Nodo\n    3) Namespace\n    4) Pod\n'
  printf '  Selecciona [1]: '
  IFS= read -r input || true
  case "${input:-1}" in
    2) K8S_SCOPE=node; printf '  Nodo: '; IFS= read -r K8S_TARGET_NODE || true ;;
    3) K8S_SCOPE=namespace; printf '  Namespace: '; IFS= read -r K8S_TARGET_NAMESPACE || true ;;
    4) K8S_SCOPE=pod; printf '  Namespace: '; IFS= read -r K8S_TARGET_NAMESPACE || true; printf '  Pod: '; IFS= read -r K8S_TARGET_POD || true ;;
    *) K8S_SCOPE=cluster ;;
  esac
}

_k8s_validate_scope() {
  case "$K8S_MODE" in quick|deep|exhaustive) ;; *) add_limitation "El modo Kubernetes '$K8S_MODE' no es válido; se usa deep."; K8S_MODE=deep ;; esac
  case "$K8S_SCOPE" in
    cluster) ;;
    node) [[ -n "$K8S_TARGET_NODE" ]] || { add_limitation "El ámbito node requiere un nombre de nodo; se usa cluster."; K8S_SCOPE=cluster; } ;;
    namespace) [[ -n "$K8S_TARGET_NAMESPACE" ]] || { add_limitation "El ámbito namespace requiere un namespace; se usa cluster."; K8S_SCOPE=cluster; } ;;
    pod) [[ -n "$K8S_TARGET_NAMESPACE" && -n "$K8S_TARGET_POD" ]] || { add_limitation "El ámbito pod requiere namespace y nombre; se usa cluster."; K8S_SCOPE=cluster; } ;;
    *) add_limitation "El ámbito Kubernetes '$K8S_SCOPE' no es válido; se usa cluster."; K8S_SCOPE=cluster ;;
  esac
  case "$K8S_MODE" in quick) K8S_DETAIL_LIMIT=80; K8S_EVENT_LIMIT=100 ;; deep) K8S_DETAIL_LIMIT=250; K8S_EVENT_LIMIT=300 ;; exhaustive) K8S_DETAIL_LIMIT=1000; K8S_EVENT_LIMIT=1000 ;; esac
}

_k8s_write_temp_kubeconfig() {
  local server="$1" method="$2" user="$3" secret="$4" file="$RUNTIME_DIR/kubeconfig-sysdiag"
  [[ "$server" != *$'\n'* && "$user" != *$'\n'* && "$secret" != *$'\n'* ]] || return 1
  umask 077
  {
    printf 'apiVersion: v1\nkind: Config\nclusters:\n- name: sysdiag\n  cluster:\n    server: '; _k8s_yaml_sq "$server"; printf '\n'
    printf 'users:\n- name: sysdiag\n  user:\n'
    if [[ "$method" == token ]]; then printf '    token: '; _k8s_yaml_sq "$secret"; printf '\n'; else printf '    username: '; _k8s_yaml_sq "$user"; printf '\n    password: '; _k8s_yaml_sq "$secret"; printf '\n'; fi
    printf 'contexts:\n- name: sysdiag\n  context:\n    cluster: sysdiag\n    user: sysdiag\ncurrent-context: sysdiag\n'
  } > "$file" || return 1
  chmod 600 "$file" 2>/dev/null || true
  K8S_EFFECTIVE_KUBECONFIG="$file"
  K8S_CONTEXT=""
}

_k8s_try_interactive_auth() {
  (( K8S_AUTH_PROMPT == 1 )) || return 1
  local machine_interactive="${SYSDIAG_MACHINE_INTERACTIVE:-0}" prompt_fd=1
  [[ -t 0 && ( -t 1 || "$machine_interactive" == 1 ) ]] || return 1
  if (( JSON_OUTPUT == 1 )) && [[ "$machine_interactive" != 1 ]]; then return 1; fi
  [[ "$machine_interactive" == 1 ]] && prompt_fd=2
  local server="" method="" user="" secret="" input="" tmp="$RUNTIME_DIR/kubeconfig-sysdiag"
  printf '\n  No existe una sesión válida contra el cluster.\n' >&"$prompt_fd"
  printf '  API URL: ' >&"$prompt_fd"
  IFS= read -r server || return 1
  [[ -n "$server" ]] || return 1
  printf '    1) Token\n    2) Usuario y contraseña\n    3) Omitir Kubernetes/OpenShift\n' >&"$prompt_fd"
  printf '  Método [1]: ' >&"$prompt_fd"
  IFS= read -r input || true
  case "${input:-1}" in
    1)
      method=token; printf '  Token: ' >&"$prompt_fd"; IFS= read -rs secret || return 1; printf '\n' >&"$prompt_fd"
      _k8s_write_temp_kubeconfig "$server" token "" "$secret" || return 1
      ;;
    2)
      printf '  Usuario: ' >&"$prompt_fd"; IFS= read -r user || return 1
      if [[ "$K8S_CLI" == oc ]]; then
        rm -f -- "$tmp" 2>/dev/null || true
        printf '  OpenShift solicitará la contraseña directamente; SYSdiag no la leerá ni la pasará en argv.\n' >&"$prompt_fd"
        if [[ "$machine_interactive" == 1 ]]; then
          if ! run_with_timeout 60 oc login "$server" -u "$user" --kubeconfig="$tmp" >&2; then
            add_limitation "La autenticación OpenShift con usuario/contraseña no fue aceptada. No se ha modificado el kubeconfig habitual."
            return 1
          fi
        elif ! run_with_timeout 60 oc login "$server" -u "$user" --kubeconfig="$tmp"; then
          add_limitation "La autenticación OpenShift con usuario/contraseña no fue aceptada. No se ha modificado el kubeconfig habitual."
          return 1
        fi
        chmod 600 "$tmp" 2>/dev/null || true
        K8S_EFFECTIVE_KUBECONFIG="$tmp"; K8S_CONTEXT=""
      else
        printf '  Contraseña: ' >&"$prompt_fd"; IFS= read -rs secret || return 1; printf '\n' >&"$prompt_fd"
        _k8s_write_temp_kubeconfig "$server" basic "$user" "$secret" || return 1
      fi
      ;;
    *) return 1 ;;
  esac
  secret=""; unset secret
  return 0
}

_k8s_detect_access() {
  if [[ -n "${K8S_CLI_OVERRIDE:-}" ]]; then
    K8S_CLI="$K8S_CLI_OVERRIDE"
    if ! have_cmd "$K8S_CLI"; then
      add_limitation "El cliente Kubernetes/OpenShift configurado no puede ejecutarse; el diagnóstico Kubernetes/OpenShift no puede continuar."
      return 1
    fi
  elif have_cmd oc; then
    K8S_CLI=oc
  elif have_cmd kubectl; then
    K8S_CLI=kubectl
  else
    add_limitation "No se encontró kubectl ni oc; el diagnóstico Kubernetes/OpenShift no puede ejecutarse."
    return 1
  fi

  K8S_EFFECTIVE_KUBECONFIG="$K8S_KUBECONFIG"
  K8S_CLIENT_VERSION="$(_k8s_capture 4 version --client --output=yaml 2>/dev/null | awk -F': ' '/gitVersion:/{print $2; exit}' || true)"
  [[ -n "$K8S_CLIENT_VERSION" ]] || K8S_CLIENT_VERSION="$(_k8s_capture 4 version --client 2>/dev/null | head -n1 | _k8s_clean || true)"
  [[ -n "$K8S_CLIENT_VERSION" ]] || K8S_CLIENT_VERSION="n/d"

  if ! _k8s_capture 8 get --raw=/version >/dev/null 2>&1; then
    _k8s_try_interactive_auth || true
  fi
  if ! _k8s_capture 8 get --raw=/version >/dev/null 2>&1; then
    add_limitation "El cliente Kubernetes/OpenShift está disponible, pero no hay una sesión válida o el API Server no responde."
    return 1
  fi
  K8S_ACCESS="disponible"
  if [[ -n "$K8S_CONTEXT" ]]; then
    K8S_CONTEXT_EFFECTIVE="$(_k8s_clean "$K8S_CONTEXT")"
  else
    K8S_CONTEXT_EFFECTIVE="$(_k8s_capture 3 config current-context 2>/dev/null | head -n1 | _k8s_clean || true)"
    [[ -n "$K8S_CONTEXT_EFFECTIVE" ]] || K8S_CONTEXT_EFFECTIVE="temporal/directo"
  fi
  K8S_SERVER="$(_k8s_capture 3 config view --minify -o 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null | _k8s_clean || true)"
  [[ -n "$K8S_SERVER" ]] || K8S_SERVER="n/d"
  K8S_USER="$(_k8s_capture 4 auth whoami -o name 2>/dev/null | head -n1 | _k8s_clean || true)"
  [[ -n "$K8S_USER" ]] || K8S_USER="$(_k8s_capture 3 config view --minify -o 'jsonpath={.contexts[0].context.user}' 2>/dev/null | _k8s_clean || true)"
  [[ -n "$K8S_USER" ]] || K8S_USER="n/d"
  K8S_SERVER_VERSION="$(_k8s_capture 5 version --output=yaml 2>/dev/null | awk -F': ' '/serverVersion:/{p=1;next} p&&/gitVersion:/{print $2; exit}' || true)"
  [[ -n "$K8S_SERVER_VERSION" ]] || K8S_SERVER_VERSION="n/d"

  local apis
  apis="$(_k8s_capture 6 api-resources --api-group=config.openshift.io -o name 2>/dev/null || true)"
  if grep -q 'clusterversions' <<<"$apis"; then
    K8S_PLATFORM="OpenShift"
    K8S_OPENSHIFT_VERSION="$(_k8s_capture 5 get clusterversion version -o 'jsonpath={.status.desired.version}' 2>/dev/null | _k8s_clean || true)"
    [[ -n "$K8S_OPENSHIFT_VERSION" ]] || K8S_OPENSHIFT_VERSION="n/d"
  fi
  return 0
}

_k8s_check_permissions() {
  local check desc
  local -a checks=(
    'list nodes|Nodes'
    'list pods --all-namespaces|Pods'
    'list services --all-namespaces|Services'
    'list endpointslices.discovery.k8s.io --all-namespaces|EndpointSlices'
    'list persistentvolumeclaims --all-namespaces|PVC'
    'list storageclasses.storage.k8s.io|StorageClass'
    'list events --all-namespaces|Events'
  )
  for check in "${checks[@]}"; do
    local args="${check%%|*}"; desc="${check#*|}"; ((K8S_PERMISSION_CHECKED+=1))
    # shellcheck disable=SC2086
    if [[ "$(_k8s_capture 5 auth can-i $args 2>/dev/null | head -n1)" != yes ]]; then
      ((K8S_PERMISSION_DENIED+=1)); add_limitation "El usuario actual no puede listar $desc; esa parte del diagnóstico quedará limitada."
    fi
  done
}

_k8s_collect_nodes() {
  local raw="" line name ready mem disk pid unsched cpu memalloc
  local -a args=(get nodes --no-headers -o 'custom-columns=NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,MEMORY:.status.conditions[?(@.type=="MemoryPressure")].status,DISK:.status.conditions[?(@.type=="DiskPressure")].status,PID:.status.conditions[?(@.type=="PIDPressure")].status,UNSCHED:.spec.unschedulable,CPU:.status.allocatable.cpu,MEMALLOC:.status.allocatable.memory')
  [[ "$K8S_SCOPE" == node ]] && args+=(--field-selector "metadata.name=$K8S_TARGET_NODE")
  raw="$(_k8s_capture 12 "${args[@]}" 2>/dev/null || true)"
  [[ -n "$raw" ]] || { add_limitation "No se pudo obtener el inventario de nodos."; return 0; }
  while IFS=$'\t' read -r name ready mem disk pid unsched cpu memalloc; do
    [[ -n "$name" ]] || continue
    ((K8S_NODE_COUNT+=1))
    name="$(_k8s_clean "$name")"; ready="$(_k8s_clean "$ready")"; mem="$(_k8s_clean "$mem")"; disk="$(_k8s_clean "$disk")"; pid="$(_k8s_clean "$pid")"
    K8S_NODE_DETAILS+=("$name|$ready|$mem|$disk|$pid|${unsched:-false}|${cpu:-n/d}|${memalloc:-n/d}")
    if [[ "$ready" != True ]]; then
      ((K8S_NODE_NOTREADY_COUNT+=1)); _k8s_add_suspect_node "$name"
      add_finding "K8S_NODE_NOTREADY_$(_k8s_id "$name")" kubernetes node_condition 5 high "El nodo $name no está Ready. NotReady es un síntoma; se requiere correlación con kubelet, runtime, red o Linux."
    fi
    if [[ "$mem" == True ]]; then
      ((K8S_NODE_MEMORY_PRESSURE_COUNT+=1)); _k8s_add_suspect_node "$name"
      add_finding "K8S_NODE_MEMORY_$(_k8s_id "$name")" kubernetes node_pressure 4 high "El nodo $name informa MemoryPressure=True; se observa presión global de memoria a nivel de nodo."
    fi
    if [[ "$disk" == True ]]; then
      ((K8S_NODE_DISK_PRESSURE_COUNT+=1)); _k8s_add_suspect_node "$name"
      add_finding "K8S_NODE_DISK_$(_k8s_id "$name")" kubernetes node_pressure 4 high "El nodo $name informa DiskPressure=True; se observa presión de almacenamiento a nivel de nodo."
    fi
    if [[ "$pid" == True ]]; then
      ((K8S_NODE_PID_PRESSURE_COUNT+=1)); _k8s_add_suspect_node "$name"
      add_finding "K8S_NODE_PID_$(_k8s_id "$name")" kubernetes node_pressure 4 high "El nodo $name informa PIDPressure=True; se observa presión de PIDs a nivel de nodo."
    fi
  done <<<"$raw"
}

_k8s_pod_args() {
  case "$K8S_SCOPE" in
    cluster) printf '%s\n' -A ;;
    namespace) printf '%s\n' -n "$K8S_TARGET_NAMESPACE" ;;
    node) printf '%s\n' -A --field-selector "spec.nodeName=$K8S_TARGET_NODE" ;;
    pod) printf '%s\n' -n "$K8S_TARGET_NAMESPACE" "$K8S_TARGET_POD" ;;
  esac
}

_k8s_collect_pods() {
  local -a scope_args=(); mapfile -t scope_args < <(_k8s_pod_args)
  local raw="" ns name phase ready node restarts waiting last exitcode reason total_restarts issue=0
  raw="$(_k8s_capture 20 get pods "${scope_args[@]}" --no-headers -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,READY:.status.conditions[?(@.type=="Ready")].status,NODE:.spec.nodeName,RESTARTS:.status.containerStatuses[*].restartCount,WAITING:.status.containerStatuses[*].state.waiting.reason,LAST:.status.containerStatuses[*].lastState.terminated.reason,EXIT:.status.containerStatuses[*].lastState.terminated.exitCode,REASON:.status.reason' 2>/dev/null || true)"
  [[ -n "$raw" ]] || { add_limitation "No se pudo obtener el inventario de Pods para el ámbito solicitado."; return 0; }
  while IFS=$'\t' read -r ns name phase ready node restarts waiting last exitcode reason; do
    [[ -n "$name" ]] || continue
    ((K8S_POD_COUNT+=1)); issue=0; total_restarts="$(_k8s_sum_ints "$restarts")"
    ns="$(_k8s_clean "$ns")"; name="$(_k8s_clean "$name")"; phase="$(_k8s_clean "$phase")"; ready="$(_k8s_clean "$ready")"; node="$(_k8s_clean "$node")"; waiting="$(_k8s_clean "$waiting")"; last="$(_k8s_clean "$last")"; reason="$(_k8s_clean "$reason")"
    [[ "$phase" == Pending ]] && { ((K8S_POD_PENDING_COUNT+=1)); issue=1; add_finding "K8S_POD_PENDING_$(_k8s_id "$ns-$name")" kubernetes pod_state 1 medium "El Pod $ns/$name está Pending; el estado por sí solo no identifica si la causa es scheduling, PVC u otra dependencia."; }
    [[ "$phase" == Failed ]] && { ((K8S_POD_FAILED_COUNT+=1)); issue=1; }
    if [[ "$phase" == Running && "$ready" != True ]]; then
      ((K8S_POD_NOTREADY_COUNT+=1)); issue=1
      add_finding "K8S_POD_NOTREADY_$(_k8s_id "$ns-$name")" kubernetes readiness 2 medium "El Pod $ns/$name está Running pero no Ready; se debe investigar readiness, aplicación y dependencias antes de asumir un fallo de red."
    fi
    if (( total_restarts >= 10 )); then
      ((K8S_POD_HIGH_RESTART_COUNT+=1)); issue=1
      add_finding "K8S_POD_RESTARTS_$(_k8s_id "$ns-$name")" kubernetes restart_history 2 medium "El Pod $ns/$name acumula $total_restarts reinicios; el contador no demuestra que la aplicación haya terminado espontáneamente."
    fi
    if [[ "$waiting" == *CrashLoopBackOff* ]]; then
      ((K8S_POD_CRASHLOOP_COUNT+=1)); issue=1
      add_finding "K8S_POD_CRASHLOOP_$(_k8s_id "$ns-$name")" kubernetes pod_state 4 high "El Pod $ns/$name presenta CrashLoopBackOff; es un patrón de reintentos, no una causa raíz."
    fi
    if [[ "$waiting" == *ImagePullBackOff* || "$waiting" == *ErrImagePull* ]]; then
      ((K8S_POD_IMAGEPULL_COUNT+=1)); issue=1
      add_finding "K8S_POD_IMAGEPULL_$(_k8s_id "$ns-$name")" kubernetes image_pull 3 high "El Pod $ns/$name no puede obtener una imagen; revisar referencia, registry, credenciales y conectividad hacia el registro."
    fi
    if [[ "$last" == *OOMKilled* ]]; then
      ((K8S_POD_OOMKILLED_COUNT+=1)); issue=1
      add_finding "K8S_POD_OOM_$(_k8s_id "$ns-$name")" kubernetes cgroup_memory 4 high "Un contenedor de $ns/$name terminó con OOMKilled. Esto puede ser un OOM del cgroup aunque el nodo no tenga MemoryPressure."
    fi
    if [[ "$reason" == Evicted ]]; then
      ((K8S_POD_EVICTED_COUNT+=1)); issue=1
      add_finding "K8S_POD_EVICTED_$(_k8s_id "$ns-$name")" kubernetes eviction 3 high "El Pod $ns/$name fue Evicted; correlacionar el motivo con presión de nodo, cuotas o almacenamiento efímero."
    fi
    (( issue == 1 )) && K8S_POD_ISSUES+=("$ns|$name|$phase|$ready|$total_restarts|${waiting:-n/d}|${last:-n/d}|${reason:-n/d}|${node:-n/d}")
  done <<<"$raw"
}

_k8s_collect_events() {
  local -a scope_args=()
  local selector="type=Warning"
  case "$K8S_SCOPE" in
    cluster) scope_args=(-A) ;;
    namespace) scope_args=(-n "$K8S_TARGET_NAMESPACE") ;;
    node) scope_args=(-A); selector="type=Warning,involvedObject.kind=Node,involvedObject.name=$K8S_TARGET_NODE" ;;
    pod) scope_args=(-n "$K8S_TARGET_NAMESPACE"); selector="type=Warning,involvedObject.kind=Pod,involvedObject.name=$K8S_TARGET_POD" ;;
  esac
  local raw="" ns type reason kind name message series_time event_time legacy_time created_time last id rc
  raw="$(_k8s_capture 20 get events "${scope_args[@]}" --field-selector "$selector" --no-headers -o 'custom-columns=NS:.metadata.namespace,TYPE:.type,REASON:.reason,KIND:.involvedObject.kind,NAME:.involvedObject.name,MESSAGE:.message,SERIES:.series.lastObservedTime,EVENTTIME:.eventTime,LAST:.lastTimestamp,CREATED:.metadata.creationTimestamp' 2>/dev/null || true)"
  [[ -n "$raw" ]] || return 0
  while IFS=$'\t' read -r ns type reason kind name message series_time event_time legacy_time created_time; do
    [[ -n "$reason" ]] || continue
    ((K8S_WARNING_EVENT_COUNT+=1)); (( K8S_WARNING_EVENT_COUNT > K8S_EVENT_LIMIT )) && continue
    ns="$(_k8s_clean "$ns")"; reason="$(_k8s_clean "$reason")"; kind="$(_k8s_clean "$kind")"; name="$(_k8s_clean "$name")"; message="$(_k8s_clean "$message")"
    series_time="$(_k8s_clean "$series_time")"; event_time="$(_k8s_clean "$event_time")"; legacy_time="$(_k8s_clean "$legacy_time")"; created_time="$(_k8s_clean "$created_time")"
    last="$series_time"
    [[ -n "$last" && "$last" != "<none>" ]] || last="$event_time"
    [[ -n "$last" && "$last" != "<none>" ]] || last="$legacy_time"
    [[ -n "$last" && "$last" != "<none>" ]] || last="$created_time"
    id="$(_k8s_id "$ns-$kind-$name")"
    K8S_WARNING_EVENTS+=("$ns|$reason|$kind|$name|$message|${last:-n/d}")
    if _k8s_event_is_recent "$last"; then
      ((K8S_WARNING_EVENT_RECENT_COUNT+=1))
    else
      rc=$?
      if (( rc == 1 )); then
        ((K8S_WARNING_EVENT_STALE_COUNT+=1))
      else
        ((K8S_WARNING_EVENT_UNKNOWN_TIME_COUNT+=1))
      fi
      continue
    fi
    case "$reason|$message" in
      FailedScheduling*|*FailedScheduling*)
        ((K8S_FAILED_SCHEDULING_COUNT+=1))
        if [[ "$message" == *"Insufficient memory"* ]]; then
          add_finding "K8S_SCHED_MEM_$id" kubernetes scheduling 5 high "El scheduler informa Insufficient memory para $ns/$name. La decisión se basa en requests y Allocatable, no en MemAvailable instantánea del host."
        elif [[ "$message" == *"Insufficient cpu"* ]]; then
          add_finding "K8S_SCHED_CPU_$id" kubernetes scheduling 4 high "El scheduler informa Insufficient cpu para $ns/$name; revisar requests comprometidos y nodos elegibles."
        elif [[ "$message" == *"untolerated taint"* || "$message" == *"taint"* ]]; then
          add_finding "K8S_SCHED_TAINT_$id" kubernetes scheduling 3 high "El scheduler descarta nodos por taints/tolerations para $ns/$name."
        elif [[ "$message" == *"unbound immediate PersistentVolumeClaims"* ]]; then
          add_finding "K8S_SCHED_PVC_$id" kubernetes storage 4 high "El Pod $ns/$name no puede avanzar porque tiene PVC inmediatos sin enlazar; investigar el almacenamiento antes de culpar al scheduler."
        else
          add_finding "K8S_SCHED_GENERIC_$id" kubernetes scheduling 2 medium "Se observa FailedScheduling para $ns/$name; revisar el mensaje del scheduler para discriminar recursos, afinidad, taints o almacenamiento."
        fi
        ;;
      Unhealthy*|*"probe failed"*)
        ((K8S_PROBE_FAILURE_COUNT+=1))
        if [[ "$message" == *"Readiness probe failed"* ]]; then
          add_finding "K8S_READINESS_$id" kubernetes readiness 3 high "La readiness probe de $ns/$name está fallando; el Pod puede seguir Running y dejar de ser un backend Ready del Service."
        elif [[ "$message" == *"Liveness probe failed"* ]]; then
          add_finding "K8S_LIVENESS_$id" kubernetes liveness 3 high "La liveness probe de $ns/$name está fallando; kubelet puede reiniciar el contenedor si se supera el umbral configurado."
        elif [[ "$message" == *"Startup probe failed"* ]]; then
          add_finding "K8S_STARTUP_$id" kubernetes startup_probe 2 medium "La startup probe de $ns/$name está fallando; revisar tiempo real de arranque y umbrales antes de interpretar otros healthchecks."
        fi
        ;;
      FailedMount*|*"MountVolume.SetUp failed"*)
        ((K8S_FAILED_MOUNT_COUNT+=1)); add_finding "K8S_MOUNT_$id" kubernetes storage_mount 4 high "Se observa FailedMount en $ns/$name; investigar kubelet, CSI node plugin, filesystem, dispositivo y opciones de montaje del nodo." ;;
      FailedAttachVolume*|FailedAttach*|*"AttachVolume.Attach failed"*)
        ((K8S_FAILED_ATTACH_COUNT+=1)); add_finding "K8S_ATTACH_$id" kubernetes storage_attach 4 high "Se observa FailedAttach en $ns/$name; investigar CSI controller, backend y la operación de attach hacia el nodo." ;;
      ProvisioningFailed*|*"failed to provision volume"*)
        ((K8S_STORAGE_PROVISION_FAILURE_COUNT+=1)); add_finding "K8S_PROVISION_$id" kubernetes storage_provision 4 high "Se observa un fallo de aprovisionamiento de almacenamiento para $ns/$name; revisar StorageClass, CSI provisioner y backend según la evidencia." ;;
      Killing*|*"failed liveness probe"*)
        if [[ "$message" == *liveness* || "$message" == *Liveness* ]]; then
          add_finding "K8S_LIVENESS_KILL_$id" kubernetes liveness_restart 4 high "Kubelet está matando contenedores de $ns/$name tras fallos de liveness; los reinicios no deben interpretarse automáticamente como crashes espontáneos."
        fi
        ;;
    esac
  done <<<"$raw"
  (( K8S_WARNING_EVENT_COUNT > K8S_EVENT_LIMIT )) && add_limitation "Se detectaron más de $K8S_EVENT_LIMIT eventos Warning; el detalle mostrado se ha acotado para evitar ruido."
  (( K8S_WARNING_EVENT_STALE_COUNT > 0 )) && add_limitation "Se observaron $K8S_WARNING_EVENT_STALE_COUNT eventos Warning fuera de la ventana reciente de ${K8S_EVENT_RECENT_MINUTES} minutos; se muestran como contexto, pero no puntúan ni se presentan como causa actual."
  (( K8S_WARNING_EVENT_UNKNOWN_TIME_COUNT > 0 )) && add_limitation "No se pudo validar la antigüedad de $K8S_WARNING_EVENT_UNKNOWN_TIME_COUNT eventos Warning; se muestran como contexto, pero no puntúan."
}

_k8s_collect_storageclasses() {
  K8S_STORAGECLASS_SEEN=()
  K8S_STORAGECLASS_LIST_AVAILABLE=0
  local raw sc
  if ! raw="$(_k8s_capture 8 get storageclass --no-headers -o 'custom-columns=NAME:.metadata.name' 2>/dev/null)"; then
    add_limitation "No se pudieron listar las StorageClass; SYSdiag no interpretará una clase no visible como inexistente."
    return 1
  fi
  K8S_STORAGECLASS_LIST_AVAILABLE=1
  while IFS= read -r sc; do [[ -n "$sc" ]] && K8S_STORAGECLASS_SEEN[$sc]=1; done <<<"$raw"
  return 0
}
_k8s_collect_pvcs() {
  local -a scope_args=()
  case "$K8S_SCOPE" in
    namespace|pod) scope_args=(-n "$K8S_TARGET_NAMESPACE") ;;
    *) scope_args=(-A) ;;
  esac
  local raw ns name status volume sc id
  raw="$(_k8s_capture 15 get pvc "${scope_args[@]}" --no-headers -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,VOLUME:.spec.volumeName,SC:.spec.storageClassName' 2>/dev/null || true)"
  [[ -n "$raw" ]] || return 0
  _k8s_collect_storageclasses
  while IFS=$'\t' read -r ns name status volume sc; do
    [[ -n "$name" ]] || continue
    ((K8S_PVC_COUNT+=1)); ns="$(_k8s_clean "$ns")"; name="$(_k8s_clean "$name")"; status="$(_k8s_clean "$status")"; sc="$(_k8s_clean "$sc")"; id="$(_k8s_id "$ns-$name")"
    if [[ "$status" == Pending ]]; then
      ((K8S_PVC_PENDING_COUNT+=1)); K8S_PVC_ISSUES+=("$ns|$name|$status|${volume:-n/d}|${sc:-n/d}")
      if [[ -n "$sc" && "$sc" != "<none>" && "$K8S_STORAGECLASS_LIST_AVAILABLE" == 1 && -z "${K8S_STORAGECLASS_SEEN[$sc]:-}" ]]; then
        add_finding "K8S_PVC_SC_$id" kubernetes storage_config 5 high "El PVC $ns/$name solicita la StorageClass '$sc', que no aparece entre las StorageClass visibles del cluster."
      else
        add_finding "K8S_PVC_PENDING_$id" kubernetes storage_provision 3 high "El PVC $ns/$name está Pending; revisar eventos, PV compatibles, StorageClass, CSI y capacidad del backend antes de atribuirlo al scheduler."
      fi
    fi
  done <<<"$raw"
}

_k8s_endpoint_scope_args() {
  case "$K8S_SCOPE" in namespace|pod) printf '%s\n' -n "$K8S_TARGET_NAMESPACE" ;; *) printf '%s\n' -A ;; esac
}

_k8s_collect_endpointslices() {
  local -a scope_args=(); mapfile -t scope_args < <(_k8s_endpoint_scope_args)
  local raw ns svc addresses ready total ready_count key
  K8S_ENDPOINTSLICE_LIST_AVAILABLE=0
  if ! raw="$(_k8s_capture 15 get endpointslices.discovery.k8s.io "${scope_args[@]}" --no-headers -o 'custom-columns=NS:.metadata.namespace,SVC:.metadata.labels.kubernetes\.io/service-name,ADDR:.endpoints[*].addresses,READY:.endpoints[*].conditions.ready' 2>/dev/null)"; then
    add_limitation "No se pudieron listar EndpointSlices; SYSdiag no interpretará su ausencia como un Service sin backends."
    return 1
  fi
  K8S_ENDPOINTSLICE_LIST_AVAILABLE=1
  while IFS=$'\t' read -r ns svc addresses ready; do
    [[ -n "$svc" && "$svc" != "<none>" ]] || continue
    key="$ns|$svc"; total="$(_k8s_count_tokens "$addresses")"; ready_count="$(_k8s_count_true "$ready" "$total")"
    K8S_EP_TOTAL[$key]=$(( ${K8S_EP_TOTAL[$key]:-0} + total ))
    K8S_EP_READY[$key]=$(( ${K8S_EP_READY[$key]:-0} + ready_count ))
  done <<<"$raw"
  return 0
}
_k8s_service_selector() {
  local ns="$1" name="$2"
  _k8s_capture 6 get service -n "$ns" "$name" -o 'go-template={{range $k,$v := .spec.selector}}{{$k}}={{$v}},{{end}}' 2>/dev/null | sed 's/,$//' | _k8s_clean
}

_k8s_service_pod_state() {
  local ns="$1" selector="$2" raw total=0 ready=0 line
  [[ -n "$selector" ]] || { printf '0 0'; return 0; }
  if ! raw="$(_k8s_capture 8 get pods -n "$ns" -l "$selector" --no-headers -o 'custom-columns=READY:.status.conditions[?(@.type=="Ready")].status' 2>/dev/null)"; then
    return 1
  fi
  while IFS= read -r line; do [[ -n "$line" ]] || continue; ((total+=1)); [[ "$line" == *True* ]] && ((ready+=1)); done <<<"$raw"
  printf '%s %s' "$total" "$ready"
}
_k8s_collect_services() {
  local -a scope_args=(); mapfile -t scope_args < <(_k8s_endpoint_scope_args)
  _k8s_collect_endpointslices || true
  local raw ns name type selector publish key total ready sel podstate pods podsready reason id
  raw="$(_k8s_capture 15 get services "${scope_args[@]}" --no-headers -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type,SELECTOR:.spec.selector,PUBLISH:.spec.publishNotReadyAddresses' 2>/dev/null || true)"
  [[ -n "$raw" ]] || return 0
  while IFS=$'\t' read -r ns name type selector publish; do
    [[ -n "$name" ]] || continue; ((K8S_SERVICE_COUNT+=1))
    [[ "$type" == ExternalName ]] && continue
    [[ -n "$selector" && "$selector" != "<none>" && "$selector" != "map[]" ]] || continue
    key="$ns|$name"; total="${K8S_EP_TOTAL[$key]:-0}"; ready="${K8S_EP_READY[$key]:-0}"; reason=""; id="$(_k8s_id "$ns-$name")"
    if (( K8S_ENDPOINTSLICE_LIST_AVAILABLE == 0 )); then
      continue
    fi
    if (( total == 0 )); then
      ((K8S_SERVICE_NO_ENDPOINT_COUNT+=1)); reason="Sin endpoints"
      if [[ "$K8S_MODE" != quick ]]; then
        if ! sel="$(_k8s_service_selector "$ns" "$name")" || [[ -z "$sel" ]]; then
          reason="Sin endpoints; selector no verificable"
          add_limitation "No se pudo verificar el selector de $ns/$name; no se atribuye la ausencia de endpoints a labels o readiness."
          add_finding "K8S_SVC_ENDPOINT_$id" kubernetes service_endpoints 2 medium "El Service $ns/$name no tiene endpoints observables; no se pudo verificar de forma fiable selector, labels y readiness."
        elif ! podstate="$(_k8s_service_pod_state "$ns" "$sel")"; then
          reason="Sin endpoints; Pods no verificables"
          add_limitation "No se pudieron listar los Pods seleccionados por $ns/$name; no se atribuye la ausencia de endpoints a selector o readiness."
          add_finding "K8S_SVC_ENDPOINT_$id" kubernetes service_endpoints 2 medium "El Service $ns/$name no tiene endpoints observables; la visibilidad de los Pods seleccionados es insuficiente para precisar la causa."
        else
          read -r pods podsready <<<"$podstate"
          if (( pods == 0 )); then
            reason="Selector sin Pods coincidentes"
            add_finding "K8S_SVC_SELECTOR_$id" kubernetes service_selector 4 high "El Service $ns/$name tiene selector pero no tiene endpoints ni Pods coincidentes; comparar selector y labels antes de investigar CNI."
          elif (( podsready == 0 )); then
            reason="Pods seleccionados no Ready"
            add_finding "K8S_SVC_READINESS_$id" kubernetes service_readiness 4 high "El Service $ns/$name selecciona Pods, pero ninguno está Ready; investigar readiness y aplicación antes de culpar al dataplane de red."
          else
            add_finding "K8S_SVC_ENDPOINT_$id" kubernetes service_endpoints 3 high "El Service $ns/$name tiene Pods Ready seleccionables pero no aparecen endpoints; revisar EndpointSlices/controladores y configuración del Service."
          fi
        fi
      else
        add_finding "K8S_SVC_ENDPOINT_$id" kubernetes service_endpoints 2 medium "El Service $ns/$name no tiene endpoints observables; revisar selector, labels y readiness antes de investigar networking."
      fi
      K8S_SERVICE_ISSUES+=("$ns|$name|$type|$total|$ready|$reason")
    elif (( ready == 0 )) && [[ "${publish,,}" != true ]]; then
      ((K8S_SERVICE_NO_READY_ENDPOINT_COUNT+=1)); reason="Endpoints no Ready"
      K8S_SERVICE_ISSUES+=("$ns|$name|$type|$total|$ready|$reason")
      add_finding "K8S_SVC_NOREADY_$id" kubernetes service_readiness 3 high "El Service $ns/$name tiene endpoints, pero ninguno aparece Ready; correlacionar con readiness probes y estado de los Pods."
    fi
  done <<<"$raw"
}

_k8s_collect_workloads() {
  [[ "$K8S_MODE" == quick || "$K8S_SCOPE" == pod ]] && return 0
  local -a scope_args=(); case "$K8S_SCOPE" in namespace) scope_args=(-n "$K8S_TARGET_NAMESPACE") ;; *) scope_args=(-A) ;; esac
  local raw ns name desired available updated ready id
  raw="$(_k8s_capture 15 get deployments.apps "${scope_args[@]}" --no-headers -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,DESIRED:.spec.replicas,AVAILABLE:.status.availableReplicas,UPDATED:.status.updatedReplicas' 2>/dev/null || true)"
  while IFS=$'\t' read -r ns name desired available updated; do
    [[ "$desired" =~ ^[0-9]+$ ]] || continue; [[ "$available" =~ ^[0-9]+$ ]] || available=0
    if (( available < desired )); then
      ((K8S_WORKLOAD_DEGRADED_COUNT+=1)); K8S_WORKLOAD_ISSUES+=("Deployment|$ns|$name|$desired|$available")
      id="$(_k8s_id "$ns-$name")"; add_finding "K8S_DEPLOY_$id" kubernetes workload 2 high "El Deployment $ns/$name dispone de $available/$desired réplicas disponibles; seguir los Pods y eventos asociados para localizar la causa."
    fi
  done <<<"$raw"
  raw="$(_k8s_capture 15 get statefulsets.apps "${scope_args[@]}" --no-headers -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas' 2>/dev/null || true)"
  while IFS=$'\t' read -r ns name desired ready; do
    [[ "$desired" =~ ^[0-9]+$ ]] || continue; [[ "$ready" =~ ^[0-9]+$ ]] || ready=0
    if (( ready < desired )); then
      ((K8S_WORKLOAD_DEGRADED_COUNT+=1)); K8S_WORKLOAD_ISSUES+=("StatefulSet|$ns|$name|$desired|$ready")
      id="$(_k8s_id "$ns-$name")"; add_finding "K8S_STS_$id" kubernetes workload 2 high "El StatefulSet $ns/$name tiene $ready/$desired réplicas Ready; revisar Pods, PVC y eventos asociados."
    fi
  done <<<"$raw"
  raw="$(_k8s_capture 15 get daemonsets.apps "${scope_args[@]}" --no-headers -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,DESIRED:.status.desiredNumberScheduled,READY:.status.numberReady' 2>/dev/null || true)"
  while IFS=$'\t' read -r ns name desired ready; do
    [[ "$desired" =~ ^[0-9]+$ ]] || continue; [[ "$ready" =~ ^[0-9]+$ ]] || ready=0
    if (( ready < desired )); then
      ((K8S_WORKLOAD_DEGRADED_COUNT+=1)); K8S_WORKLOAD_ISSUES+=("DaemonSet|$ns|$name|$desired|$ready")
      id="$(_k8s_id "$ns-$name")"; add_finding "K8S_DS_$id" kubernetes workload 2 high "El DaemonSet $ns/$name tiene $ready/$desired instancias Ready; revisar nodos excluidos y Pods asociados."
    fi
  done <<<"$raw"
}

_k8s_collect_metrics() {
  [[ "$K8S_MODE" == quick ]] && return 0
  local raw
  if [[ "$K8S_SCOPE" == node ]]; then raw="$(_k8s_capture 8 top node "$K8S_TARGET_NODE" --no-headers 2>/dev/null || true)"; else raw="$(_k8s_capture 10 top nodes --no-headers 2>/dev/null || true)"; fi
  if [[ -n "$raw" ]]; then
    K8S_METRICS_AVAILABLE=1
    while IFS= read -r line; do [[ -n "$line" ]] && K8S_NODE_METRICS+=("$(_k8s_clean "$line")"); done <<<"$raw"
  else
    add_limitation "No se pudieron obtener métricas de 'top nodes'; metrics-server o los permisos pueden no estar disponibles."
  fi
}

_k8s_collect_kubelet_stats() {
  [[ "$K8S_MODE" == quick ]] && return 0
  local -a nodes=() row node raw
  if [[ "$K8S_SCOPE" == node ]]; then
    nodes=("$K8S_TARGET_NODE")
  elif [[ "$K8S_MODE" == exhaustive ]]; then
    for row in "${K8S_NODE_DETAILS[@]:-}"; do IFS='|' read -r node _ <<<"$row"; [[ -n "$node" ]] && nodes+=("$node"); done
  else
    nodes=("${K8S_SUSPECT_NODES[@]:-}")
  fi
  ((${#nodes[@]})) || return 0
  for node in "${nodes[@]}"; do
    raw="$(_k8s_capture 8 get --raw="/api/v1/nodes/$node/proxy/stats/summary" 2>/dev/null | head -c 200 || true)"
    if [[ "$raw" == *'"node"'* || "$raw" == *'"pods"'* ]]; then ((K8S_KUBELET_STATS_OK_COUNT+=1)); else ((K8S_KUBELET_STATS_FAIL_COUNT+=1)); fi
  done
  (( K8S_KUBELET_STATS_FAIL_COUNT > 0 )) && add_limitation "No se pudo consultar stats/summary del kubelet en $K8S_KUBELET_STATS_FAIL_COUNT nodo(s); puede faltar permiso nodes/proxy o el kubelet no responder."
}

_k8s_collect_openshift() {
  [[ "$K8S_PLATFORM" == OpenShift && "$K8S_MODE" != quick ]] || return 0
  local raw name avail prog degr message phase id
  raw="$(_k8s_capture 15 get clusteroperators.config.openshift.io --no-headers -o 'custom-columns=NAME:.metadata.name,AVAILABLE:.status.conditions[?(@.type=="Available")].status,PROGRESSING:.status.conditions[?(@.type=="Progressing")].status,DEGRADED:.status.conditions[?(@.type=="Degraded")].status,MESSAGE:.status.conditions[?(@.type=="Degraded")].message' 2>/dev/null || true)"
  if [[ -z "$raw" ]]; then add_limitation "OpenShift detectado, pero no se pudieron consultar ClusterOperators."; else
    while IFS=$'\t' read -r name avail prog degr message; do
      [[ -n "$name" ]] || continue; id="$(_k8s_id "$name")"
      if [[ "$degr" == True ]]; then
        ((K8S_OPENSHIFT_DEGRADED_OPERATORS+=1)); K8S_OPENSHIFT_ISSUES+=("ClusterOperator|$name|Degraded|$(_k8s_clean "$message")")
        add_finding "OCP_OPERATOR_DEGRADED_$id" kubernetes openshift_operator 5 high "El ClusterOperator $name está Degraded=True; revisar su mensaje y recursos relacionados antes de atribuir el síntoma a una capa inferior."
      elif [[ "$avail" != True ]]; then
        ((K8S_OPENSHIFT_UNAVAILABLE_OPERATORS+=1)); K8S_OPENSHIFT_ISSUES+=("ClusterOperator|$name|Available=$avail|$(_k8s_clean "$message")")
        add_finding "OCP_OPERATOR_UNAVAILABLE_$id" kubernetes openshift_operator 4 high "El ClusterOperator $name no está Available=True."
      fi
    done <<<"$raw"
  fi
  [[ "$K8S_MODE" == exhaustive ]] || return 0
  raw="$(_k8s_capture 15 get machines.machine.openshift.io -A --no-headers -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,NODE:.status.nodeRef.name' 2>/dev/null || true)"
  while IFS=$'\t' read -r ns name phase node; do
    [[ -n "$name" ]] || continue
    if [[ "$phase" == Failed ]]; then
      ((K8S_OPENSHIFT_MACHINE_FAILED_COUNT+=1)); K8S_OPENSHIFT_ISSUES+=("Machine|$ns/$name|Failed|${node:-n/d}")
      add_finding "OCP_MACHINE_FAILED_$(_k8s_id "$ns-$name")" kubernetes openshift_machine 4 high "La Machine $ns/$name está en fase Failed; correlacionar con el Node y Machine API."
    fi
  done <<<"$raw"

  # Only suspicious nodes are sampled. node-logs is a read-only OpenShift API operation.
  if [[ "$K8S_CLI" == oc && ${#K8S_SUSPECT_NODES[@]} -gt 0 ]]; then
    for node in "${K8S_SUSPECT_NODES[@]}"; do
      local -a oc_args=(oc)
      [[ -n "$K8S_EFFECTIVE_KUBECONFIG" ]] && oc_args+=(--kubeconfig "$K8S_EFFECTIVE_KUBECONFIG")
      [[ -n "$K8S_CONTEXT" ]] && oc_args+=(--context "$K8S_CONTEXT")
      oc_args+=(adm node-logs "$node" -u kubelet --since=10m)
      message="$(run_with_timeout 8 "${oc_args[@]}" 2>/dev/null | grep -Ei 'error|failed|notready|not ready|runtime|pleg|evict|pressure' | tail -n 5 | sanitize_terminal_text || true)"
      if [[ -n "$message" ]]; then
        ((K8S_OPENSHIFT_NODE_LOG_HINT_COUNT+=1)); K8S_OPENSHIFT_ISSUES+=("NodeLog|$node|kubelet|$(_k8s_clean "$message")")
      fi
    done
  fi
}

collect_kubernetes() {
  _k8s_prompt_configuration
  _k8s_validate_scope
  _k8s_detect_access || return 0
  _k8s_check_permissions
  _k8s_collect_nodes
  _k8s_collect_pods
  _k8s_collect_events
  _k8s_collect_pvcs
  _k8s_collect_services
  _k8s_collect_workloads
  _k8s_collect_metrics
  _k8s_collect_kubelet_stats
  _k8s_collect_openshift
}

analyze_kubernetes() {
  [[ "$K8S_ACCESS" == disponible ]] || return 0
  if (( K8S_PERMISSION_DENIED > 0 )); then
    add_finding "K8S_RBAC_LIMITED" kubernetes rbac 1 medium "El diagnóstico está limitado por RBAC en $K8S_PERMISSION_DENIED de $K8S_PERMISSION_CHECKED comprobaciones básicas."
  fi
  add_next_step "Revisar el contexto y permisos de solo lectura utilizados por SYSdiag." \
    "$K8S_CLI config current-context" \
    "$K8S_CLI auth whoami" \
    "$K8S_CLI auth can-i --list"
  if (( K8S_NODE_NOTREADY_COUNT + K8S_NODE_MEMORY_PRESSURE_COUNT + K8S_NODE_DISK_PRESSURE_COUNT + K8S_NODE_PID_PRESSURE_COUNT > 0 )); then
    add_next_step "Correlacionar Node Conditions con kubelet/runtime/Linux sin tratar NotReady o Pressure como causa raíz." \
      "$K8S_CLI get nodes" \
      "$K8S_CLI describe node <nodo>" \
      "$K8S_CLI get events -A --field-selector involvedObject.kind=Node,involvedObject.name=<nodo>"
  fi
  if (( K8S_POD_PENDING_COUNT + K8S_POD_CRASHLOOP_COUNT + K8S_POD_OOMKILLED_COUNT + K8S_POD_HIGH_RESTART_COUNT > 0 )); then
    add_next_step "Inspeccionar Pods problemáticos con estado previo, eventos y límites antes de concluir la causa." \
      "$K8S_CLI describe pod -n <namespace> <pod>" \
      "$K8S_CLI logs -n <namespace> <pod> --all-containers --tail=100" \
      "$K8S_CLI logs -n <namespace> <pod> --all-containers --previous --tail=100"
  fi
  if (( K8S_SERVICE_NO_ENDPOINT_COUNT + K8S_SERVICE_NO_READY_ENDPOINT_COUNT > 0 )); then
    add_next_step "Seguir la cadena DNS → Service → EndpointSlice → Pod IP/puerto → aplicación y localizar el primer salto que falla." \
      "$K8S_CLI get svc -n <namespace> <service> -o yaml" \
      "$K8S_CLI get endpointslices.discovery.k8s.io -n <namespace> -l kubernetes.io/service-name=<service>" \
      "$K8S_CLI get pods -n <namespace> --show-labels"
  fi
  if (( K8S_PVC_PENDING_COUNT + K8S_FAILED_MOUNT_COUNT + K8S_FAILED_ATTACH_COUNT + K8S_STORAGE_PROVISION_FAILURE_COUNT > 0 )); then
    add_next_step "Separar provisioning, attach y mount antes de bajar a CSI o al almacenamiento externo." \
      "$K8S_CLI get pvc,pv,storageclass -A" \
      "$K8S_CLI describe pvc -n <namespace> <pvc>" \
      "$K8S_CLI get events -n <namespace> --field-selector type=Warning"
  fi
}

print_kubernetes() {
  section "KUBERNETES / OPENSHIFT"
  kv "Cliente:" "${K8S_CLI:-no disponible} ${K8S_CLIENT_VERSION:-}"
  kv "Acceso API:" "$K8S_ACCESS"
  kv "Contexto:" "$K8S_CONTEXT_EFFECTIVE"
  kv "API Server:" "$K8S_SERVER"
  kv "Usuario:" "$K8S_USER"
  local platform_text="$K8S_PLATFORM"
  [[ "$K8S_PLATFORM" == OpenShift && "$K8S_OPENSHIFT_VERSION" != "n/d" ]] && platform_text+=" $K8S_OPENSHIFT_VERSION"
  kv "Plataforma:" "$platform_text"
  kv "Versión servidor:" "$K8S_SERVER_VERSION"
  kv "Modo / ámbito:" "$K8S_MODE / $K8S_SCOPE"
  [[ "$K8S_SCOPE" == node ]] && kv "Nodo objetivo:" "$K8S_TARGET_NODE"
  [[ "$K8S_SCOPE" == namespace || "$K8S_SCOPE" == pod ]] && kv "Namespace objetivo:" "$K8S_TARGET_NAMESPACE"
  [[ "$K8S_SCOPE" == pod ]] && kv "Pod objetivo:" "$K8S_TARGET_POD"
  [[ "$K8S_ACCESS" == disponible ]] || { printf '\n  No hay evidencia suficiente para analizar el cluster desde esta ejecución.\n'; return 0; }

  subsection "RESUMEN"
  kv "Nodos / NotReady:" "$K8S_NODE_COUNT / $K8S_NODE_NOTREADY_COUNT"
  kv "Memory/Disk/PID Pressure:" "$K8S_NODE_MEMORY_PRESSURE_COUNT / $K8S_NODE_DISK_PRESSURE_COUNT / $K8S_NODE_PID_PRESSURE_COUNT"
  kv "Pods inspeccionados:" "$K8S_POD_COUNT"
  kv "Pending / NotReady / Failed:" "$K8S_POD_PENDING_COUNT / $K8S_POD_NOTREADY_COUNT / $K8S_POD_FAILED_COUNT"
  kv "CrashLoop / ImagePull / OOMKilled:" "$K8S_POD_CRASHLOOP_COUNT / $K8S_POD_IMAGEPULL_COUNT / $K8S_POD_OOMKILLED_COUNT"
  kv "RestartCount >=10 / Evicted:" "$K8S_POD_HIGH_RESTART_COUNT / $K8S_POD_EVICTED_COUNT"
  kv "Services sin endpoint / sin Ready:" "$K8S_SERVICE_NO_ENDPOINT_COUNT / $K8S_SERVICE_NO_READY_ENDPOINT_COUNT"
  kv "PVC Pending:" "$K8S_PVC_PENDING_COUNT"
  kv "FailedScheduling / probes:" "$K8S_FAILED_SCHEDULING_COUNT / $K8S_PROBE_FAILURE_COUNT"
  kv "FailedAttach / FailedMount:" "$K8S_FAILED_ATTACH_COUNT / $K8S_FAILED_MOUNT_COUNT"
  kv "Workloads degradados:" "$K8S_WORKLOAD_DEGRADED_COUNT"
  kv "Eventos Warning observados:" "$K8S_WARNING_EVENT_COUNT"
  kv "Warning recientes / históricos / sin fecha:" "$K8S_WARNING_EVENT_RECENT_COUNT / $K8S_WARNING_EVENT_STALE_COUNT / $K8S_WARNING_EVENT_UNKNOWN_TIME_COUNT"
  kv "Métricas de nodos:" "$([[ $K8S_METRICS_AVAILABLE == 1 ]] && echo disponibles || echo no disponibles)"
  kv "Kubelet stats OK / fallo:" "$K8S_KUBELET_STATS_OK_COUNT / $K8S_KUBELET_STATS_FAIL_COUNT"
  if [[ "$K8S_PLATFORM" == OpenShift ]]; then
    kv "Operators degraded / unavailable:" "$K8S_OPENSHIFT_DEGRADED_OPERATORS / $K8S_OPENSHIFT_UNAVAILABLE_OPERATORS"
    kv "Machines Failed:" "$K8S_OPENSHIFT_MACHINE_FAILED_COUNT"
  fi

  if (( ${VERBOSE:-0} == 1 )); then
    local row a b c d e f g h i
    if ((${#K8S_NODE_DETAILS[@]})); then
      subsection "NODOS"
      printf '    %-28s %-8s %-8s %-8s %-8s %-12s %-8s %s\n' "Nodo" "Ready" "Memory" "Disk" "PID" "Unsched" "CPU" "Mem alloc"
      for row in "${K8S_NODE_DETAILS[@]}"; do IFS='|' read -r a b c d e f g h <<<"$row"; printf '    %-28.28s %-8s %-8s %-8s %-8s %-12s %-8s %s\n' "$a" "$b" "$c" "$d" "$e" "$f" "$g" "$h"; done
    fi
    if ((${#K8S_POD_ISSUES[@]})); then
      subsection "PODS CON SEÑALES"
      printf '    %-20s %-34s %-12s %-7s %-9s %-18s %-14s %s\n' "Namespace" "Pod" "Phase" "Ready" "Restarts" "Waiting" "Last" "Nodo"
      local n=0
      for row in "${K8S_POD_ISSUES[@]}"; do ((n+=1)); (( n > K8S_DETAIL_LIMIT )) && break; IFS='|' read -r a b c d e f g h i <<<"$row"; printf '    %-20.20s %-34.34s %-12.12s %-7s %-9s %-18.18s %-14.14s %s\n' "$a" "$b" "$c" "$d" "$e" "$f" "$g" "$i"; done
    fi
    if ((${#K8S_SERVICE_ISSUES[@]})); then
      subsection "SERVICES / ENDPOINTSLICES"
      for row in "${K8S_SERVICE_ISSUES[@]}"; do IFS='|' read -r a b c d e f <<<"$row"; printf '    - %s/%s: %s (endpoints=%s, ready=%s)\n' "$a" "$b" "$f" "$d" "$e"; done
    fi
    if ((${#K8S_PVC_ISSUES[@]})); then
      subsection "PVC"
      for row in "${K8S_PVC_ISSUES[@]}"; do IFS='|' read -r a b c d e <<<"$row"; printf '    - %s/%s: %s, volume=%s, StorageClass=%s\n' "$a" "$b" "$c" "$d" "$e"; done
    fi
    if ((${#K8S_WORKLOAD_ISSUES[@]})); then
      subsection "WORKLOADS"
      for row in "${K8S_WORKLOAD_ISSUES[@]}"; do IFS='|' read -r a b c d e <<<"$row"; printf '    - %s %s/%s: disponibles/ready=%s de %s\n' "$a" "$b" "$c" "$e" "$d"; done
    fi
    if ((${#K8S_OPENSHIFT_ISSUES[@]})); then
      subsection "OPENSHIFT"
      for row in "${K8S_OPENSHIFT_ISSUES[@]}"; do printf '    - %s\n' "${row//|/ | }"; done
    fi
  fi

  if (( ${EXPLAIN:-0} == 1 )); then
    subsection "CÓMO INTERPRETARLO"
    printf '    - Pending, CrashLoopBackOff, NotReady y Evicted son estados/síntomas; no se presentan como causa por sí solos.\n'
    printf '    - Scheduling usa requests y Allocatable; MemAvailable Linux no representa capacidad libre para scheduling.\n'
    printf '    - OOMKilled de un contenedor no implica MemoryPressure del nodo.\n'
    printf '    - Readiness falla → Pod puede seguir Running pero dejar de recibir tráfico; liveness puede provocar reinicios.\n'
    printf '    - DNS → Service → EndpointSlice → Pod IP/puerto → aplicación: SYSdiag intenta localizar el primer salto roto antes de culpar al CNI.\n'
    printf '    - PVC Pending, FailedAttach y FailedMount pertenecen a fases distintas; Bound no significa attached ni mounted.\n'
    printf '    - El análisis remoto usa la API, metrics y kubelet proxy cuando están disponibles; no instala agentes ni crea Pods de diagnóstico.\n'
    printf '    - SYSdiag no ejecuta apply, create, delete, patch, edit, exec, debug, port-forward ni acciones correctivas.\n'
  fi
}
