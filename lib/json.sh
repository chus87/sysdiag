# Structured JSON output for automation/comparison.
# No external JSON encoder is required at runtime.
SYS_DIAG_JSON_SCHEMA_VERSION="1.1"

json_escape() {
  local s="${1-}"
  # Strip terminal-control bytes first; JSON remains data, not terminal control.
  s="$(printf '%s' "$s" | sanitize_terminal_text)"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

json_q() { printf '"%s"' "$(json_escape "${1-}")"; }
json_bool() { [[ "${1:-0}" == 1 || "${1,,}" == true || "${1,,}" == yes || "${1,,}" == sí ]] && printf 'true' || printf 'false'; }
json_num_or_null() { [[ "${1-}" =~ ^-?[0-9]+([.][0-9]+)?$ ]] && printf '%s' "$1" || printf 'null'; }

_json_array_strings() {
  local first=1 x
  printf '['
  for x in "$@"; do
    [[ -n "$x" ]] || continue
    (( first )) || printf ','; first=0; json_q "$x"
  done
  printf ']'
}

_json_multiline_array() {
  local text="${1-}" first=1 line
  printf '['
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    (( first )) || printf ','; first=0; json_q "$line"
  done <<<"$text"
  printf ']'
}

_json_commands_array() {
  local text="$1" first=1 line
  printf '['
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    (( first )) || printf ','; first=0; json_q "$line"
  done <<<"$text"
  printf ']'
}

_json_container_details_array() {
  local first=1 row runtime id name image status exitcode oom pid restarts health memlimit cpulimited privileged netmode restartpolicy logdriver logbytes mounts
  printf '['
  for row in "${CONTAINER_DETAILS[@]:-}"; do
    [[ -n "$row" ]] || continue
    IFS='|' read -r runtime id name image status exitcode oom pid restarts health memlimit cpulimited privileged netmode restartpolicy logdriver logbytes mounts <<<"$row"
    (( first )) || printf ','; first=0
    printf '{"runtime":'; json_q "$runtime"; printf ',"id":'; json_q "$id"; printf ',"name":'; json_q "$name"; printf ',"image":'; json_q "$image"
    printf ',"status":'; json_q "$status"; printf ',"exit_code":'; json_num_or_null "$exitcode"; printf ',"oom_killed":'; json_bool "$oom"
    printf ',"pid":'; json_num_or_null "$pid"; printf ',"restart_count":'; json_num_or_null "$restarts"; printf ',"health":'; json_q "$health"
    printf ',"memory_limit_bytes":'; json_num_or_null "$memlimit"; printf ',"cpu_limited":'; json_bool "$cpulimited"; printf ',"privileged":'; json_bool "$privileged"
    printf ',"network_mode":'; json_q "$netmode"; printf ',"restart_policy":'; json_q "$restartpolicy"; printf ',"log_driver":'; json_q "$logdriver"
    printf ',"local_log_bytes":'; json_num_or_null "$logbytes"; printf ',"mounts":'; json_q "$mounts"; printf '}'
  done
  printf ']'
}

_json_container_stats_array() {
  local first=1 row runtime name cpu mem memusage blockio pids
  printf '['
  for row in "${CONTAINER_STATS_DETAILS[@]:-}"; do
    [[ -n "$row" ]] || continue
    IFS='|' read -r runtime name cpu mem memusage blockio pids <<<"$row"
    (( first )) || printf ','; first=0
    printf '{"runtime":'; json_q "$runtime"; printf ',"name":'; json_q "$name"; printf ',"cpu_pct":'; json_num_or_null "$cpu"
    printf ',"memory_pct":'; json_num_or_null "$mem"; printf ',"memory_usage":'; json_q "$memusage"; printf ',"block_io":'; json_q "$blockio"; printf ',"pids":'; json_num_or_null "$pids"; printf '}'
  done
  printf ']'
}


_json_container_deep_issues_array() {
  local first=1 row runtime name scan_state lines category count sample interpretation resolution
  printf '['
  for row in "${CONTAINER_DEEP_ISSUES[@]:-}"; do
    [[ -n "$row" ]] || continue
    IFS='|' read -r runtime name scan_state lines category count sample interpretation resolution <<<"$row"
    (( first )) || printf ','; first=0
    printf '{"runtime":'; json_q "$runtime"; printf ',"name":'; json_q "$name"; printf ',"scan_state":'; json_q "$scan_state"
    printf ',"log_lines":'; json_num_or_null "$lines"; printf ',"category":'; json_q "$category"; printf ',"matches":'; json_num_or_null "$count"
    printf ',"sample":'; json_q "$sample"; printf ',"interpretation":'; json_q "$interpretation"; printf ',"manual_resolution":'; json_q "$resolution"; printf '}'
  done
  printf ']'
}


_json_k8s_nodes_array() {
  local row first=1 a b c d e f g h
  printf '['
  for row in "${K8S_NODE_DETAILS[@]:-}"; do
    [[ -n "$row" ]] || continue; (( first )) || printf ','; first=0
    IFS='|' read -r a b c d e f g h <<<"$row"
    printf '{"name":'; json_q "$a"; printf ',"ready":'; json_q "$b"; printf ',"memory_pressure":'; json_q "$c"; printf ',"disk_pressure":'; json_q "$d"; printf ',"pid_pressure":'; json_q "$e"; printf ',"unschedulable":'; json_q "$f"; printf ',"allocatable_cpu":'; json_q "$g"; printf ',"allocatable_memory":'; json_q "$h"; printf '}'
  done
  printf ']'
}

_json_k8s_pod_issues_array() {
  local row first=1 a b c d e f g h i
  printf '['
  for row in "${K8S_POD_ISSUES[@]:-}"; do
    [[ -n "$row" ]] || continue; (( first )) || printf ','; first=0
    IFS='|' read -r a b c d e f g h i <<<"$row"
    printf '{"namespace":'; json_q "$a"; printf ',"name":'; json_q "$b"; printf ',"phase":'; json_q "$c"; printf ',"ready":'; json_q "$d"; printf ',"restarts":'; json_num_or_null "$e"; printf ',"waiting_reason":'; json_q "$f"; printf ',"last_reason":'; json_q "$g"; printf ',"status_reason":'; json_q "$h"; printf ',"node":'; json_q "$i"; printf '}'
  done
  printf ']'
}

_json_k8s_service_issues_array() {
  local row first=1 a b c d e f
  printf '['
  for row in "${K8S_SERVICE_ISSUES[@]:-}"; do
    [[ -n "$row" ]] || continue; (( first )) || printf ','; first=0
    IFS='|' read -r a b c d e f <<<"$row"
    printf '{"namespace":'; json_q "$a"; printf ',"name":'; json_q "$b"; printf ',"type":'; json_q "$c"; printf ',"endpoints":'; json_num_or_null "$d"; printf ',"ready_endpoints":'; json_num_or_null "$e"; printf ',"reason":'; json_q "$f"; printf '}'
  done
  printf ']'
}

_json_k8s_pvc_issues_array() {
  local row first=1 a b c d e
  printf '['
  for row in "${K8S_PVC_ISSUES[@]:-}"; do
    [[ -n "$row" ]] || continue; (( first )) || printf ','; first=0
    IFS='|' read -r a b c d e <<<"$row"
    printf '{"namespace":'; json_q "$a"; printf ',"name":'; json_q "$b"; printf ',"status":'; json_q "$c"; printf ',"volume":'; json_q "$d"; printf ',"storage_class":'; json_q "$e"; printf '}'
  done
  printf ']'
}

_json_k8s_workload_issues_array() {
  local row first=1 a b c d e
  printf '['
  for row in "${K8S_WORKLOAD_ISSUES[@]:-}"; do
    [[ -n "$row" ]] || continue; (( first )) || printf ','; first=0
    IFS='|' read -r a b c d e <<<"$row"
    printf '{"kind":'; json_q "$a"; printf ',"namespace":'; json_q "$b"; printf ',"name":'; json_q "$c"; printf ',"desired":'; json_num_or_null "$d"; printf ',"available_or_ready":'; json_num_or_null "$e"; printf '}'
  done
  printf ']'
}

_json_k8s_warning_events_array() {
  local row first=1 a b c d e f
  printf '['
  for row in "${K8S_WARNING_EVENTS[@]:-}"; do
    [[ -n "$row" ]] || continue; (( first )) || printf ','; first=0
    IFS='|' read -r a b c d e f <<<"$row"
    printf '{"namespace":'; json_q "$a"; printf ',"reason":'; json_q "$b"; printf ',"kind":'; json_q "$c"; printf ',"name":'; json_q "$d"; printf ',"message":'; json_q "$e"; printf ',"last_timestamp":'; json_q "$f"; printf '}'
  done
  printf ']'
}

_json_category_status() {
  local cat="$1" status
  status="$(summary_status_for "${SCORE[$cat]:-0}" "${IMPACT[$cat]:-0}")"
  if [[ "$status" == OK ]] && summary_category_is_limited "$cat"; then status=LIMITED; fi
  printf '%s' "$status"
}

_json_metrics_object() {
  printf '{'
  printf '"system":{'
  printf '"hostname":'; json_q "${HOSTNAME_FQDN:-n/d}"; printf ','
  printf '"os":'; json_q "${OS_PRETTY:-n/d}"; printf ','
  printf '"kernel":'; json_q "${KERNEL:-$(uname -sr 2>/dev/null || echo n/d)}"; printf ','
  printf '"uptime":'; json_q "${UPTIME_PRETTY:-n/d}"; printf ','
  printf '"virtualization":'; json_q "${VIRT:-n/d}"; printf ','
  printf '"cpu_logical":'; json_num_or_null "${CPU_LOGICAL_COUNT:-}"; printf ','
  printf '"cpu_physical_cores":'; json_num_or_null "${CPU_PHYSICAL_CORES:-}"
  printf '},'

  printf '"cpu":{'
  printf '"load1":'; json_num_or_null "${LOAD1:-}"; printf ','
  printf '"idle_pct":'; json_num_or_null "${CPU_IDLE_PCT:-}"; printf ','
  printf '"iowait_pct":'; json_num_or_null "${CPU_IOWAIT_PCT:-}"
  printf '},'

  printf '"processes":{'
  printf '"running":'; json_num_or_null "${PROC_R:-}"; printf ','
  printf '"sleeping":'; json_num_or_null "${PROC_S:-}"; printf ','
  printf '"uninterruptible":'; json_num_or_null "${PROC_D:-}"; printf ','
  printf '"zombies":'; json_num_or_null "${PROC_Z:-}"
  printf '},'

  printf '"memory":{'
  printf '"available_kb":'; json_num_or_null "${MEM_AVAIL_KB:-}"; printf ','
  printf '"free_kb":'; json_num_or_null "${MEM_FREE_KB:-}"; printf ','
  printf '"swap_used_kb":'; json_num_or_null "${SWAP_USED_KB:-}"; printf ','
  printf '"swap_in_delta":'; json_num_or_null "${SWAP_IN_PAGES_S:-}"; printf ','
  printf '"swap_out_delta":'; json_num_or_null "${SWAP_OUT_PAGES_S:-}"
  printf '},'

  printf '"io":{'
  printf '"iostat_available":'; json_bool "${IOSTAT_AVAILABLE:-0}"; printf ','
  printf '"sample_valid":'; json_bool "${IOSTAT_DATA_VALID:-0}"; printf ','
  printf '"max_await_ms":'; json_num_or_null "${IO_MAX_AWAIT:-}"; printf ','
  printf '"max_queue":'; json_num_or_null "${IO_MAX_AQU:-}"; printf ','
  printf '"max_util_pct":'; json_num_or_null "${IO_MAX_UTIL:-}"
  printf '},'

  printf '"filesystem":{'
  printf '"max_space_pct":'; json_num_or_null "${FS_MAX_USE:-}"; printf ','
  printf '"max_inode_pct":'; json_num_or_null "${FS_MAX_INODE_USE:-}"; printf ','
  printf '"deleted_open_bytes":'; json_num_or_null "${DELETED_OPEN_RETAINED_BYTES:-}"
  printf '},'

  printf '"network":{'
  printf '"tcp_retrans_delta":'; json_num_or_null "${NET_TCP_RETRANS_DELTA:-}"; printf ','
  printf '"close_wait":'; json_num_or_null "${TCP_CLOSE_WAIT:-}"; printf ','
  printf '"syn_sent":'; json_num_or_null "${TCP_SYN_SENT:-}"; printf ','
  printf '"conntrack_pct":'; json_num_or_null "${CONNTRACK_PCT:-}"
  printf '},'

  printf '"logging":{'
  printf '"journal_access":'; json_q "${JOURNAL_ACCESS:-n/d}"; printf ','
  printf '"persistent_store":'; json_bool "${JOURNAL_PERSISTENT_STORE:-0}"; printf ','
  printf '"boot_count":'; json_num_or_null "${JOURNAL_BOOT_COUNT:-}"; printf ','
  printf '"previous_boot_available":'; json_bool "${JOURNAL_PREVIOUS_BOOT_AVAILABLE:-0}"; printf ','
  printf '"rsyslog_active":'; json_q "${RSYSLOG_ACTIVE:-n/d}"; printf ','
  printf '"logrotate_available":'; json_bool "${LOGROTATE_AVAILABLE:-0}"
  printf '},'

  printf '"recent_events":{'
  printf '"window_minutes":'; json_num_or_null "${RECENT_MINUTES:-60}"; printf ','
  printf '"journal_error_count":'; json_num_or_null "${RECENT_JOURNAL_ERROR_COUNT:-}"; printf ','
  printf '"journal_warning_count":'; json_num_or_null "${RECENT_JOURNAL_WARNING_COUNT:-}"; printf ','
  printf '"dmesg_error_count":'; json_num_or_null "${RECENT_DMESG_ERROR_COUNT:-}"; printf ','
  printf '"dmesg_warning_count":'; json_num_or_null "${RECENT_DMESG_WARNING_COUNT:-}"; printf ','
  printf '"dmesg_deduplicated":'; json_num_or_null "${RECENT_DMESG_DEDUP_COUNT:-}"; printf ','
  printf '"journal_errors":'; _json_multiline_array "${RECENT_JOURNAL_ERRORS:-}"; printf ','
  printf '"journal_warnings":'; _json_multiline_array "${RECENT_JOURNAL_WARNINGS:-}"; printf ','
  printf '"dmesg_errors":'; _json_multiline_array "${RECENT_DMESG_ERRORS:-}"; printf ','
  printf '"dmesg_warnings":'; _json_multiline_array "${RECENT_DMESG_WARNINGS:-}"
  printf '},'

  printf '"systemd":{'
  printf '"pid1_is_systemd":'; json_bool "${SYSTEMD_PID1:-0}"; printf ','
  printf '"access":'; json_q "${SYSTEMD_ACCESS:-n/d}"; printf ','
  printf '"state":'; json_q "${SYSTEMD_SYSTEM_STATE:-n/d}"; printf ','
  printf '"default_target":'; json_q "${SYSTEMD_DEFAULT_TARGET:-n/d}"; printf ','
  printf '"failed_units":'; json_num_or_null "${SYSTEMD_FAILED_UNITS_COUNT:-}"; printf ','
  printf '"start_limit_hints":'; json_num_or_null "${SYSTEMD_START_LIMIT_HITS:-}"; printf ','
  printf '"restart_hints":'; json_num_or_null "${SYSTEMD_RESTART_HINTS:-}"
  printf '},'

  printf '"boot":{'
  printf '"context":'; json_q "${BOOT_CONTEXT:-n/d}"; printf ','
  printf '"representative_of_host":'; json_bool "${BOOT_CONTEXT_REPRESENTATIVE:-0}"; printf ','
  printf '"kernel":'; json_q "${BOOT_KERNEL:-n/d}"; printf ','
  printf '"root_arg":'; json_q "${BOOT_ROOT_ARG:-n/d}"; printf ','
  printf '"root_source":'; json_q "${BOOT_ROOT_SOURCE:-n/d}"; printf ','
  printf '"root_fstype":'; json_q "${BOOT_ROOT_FSTYPE:-n/d}"; printf ','
  printf '"initramfs_style":'; json_q "${BOOT_INITRAMFS_STYLE:-n/d}"; printf ','
  printf '"fstab_invalid":'; json_num_or_null "${BOOT_FSTAB_INVALID_COUNT:-}"; printf ','
  printf '"fstab_missing_required":'; json_num_or_null "${BOOT_FSTAB_MISSING_REQUIRED:-}"; printf ','
  printf '"failed_mount_units":'; json_num_or_null "${BOOT_FAILED_MOUNTS_COUNT:-}"; printf ','
  printf '"emergency_hints":'; json_num_or_null "${BOOT_EMERGENCY_HINTS:-}"; printf ','
  printf '"device_timeout_hints":'; json_num_or_null "${BOOT_DEVICE_TIMEOUT_HINTS:-}"; printf ','
  printf '"fsck_hints":'; json_num_or_null "${BOOT_FSCK_HINTS:-}"; printf ','
  printf '"kernel_storage_hints":'; json_num_or_null "${BOOT_IO_KERNEL_HINTS:-}"; printf ','
  printf '"journal_boot_count":'; json_num_or_null "${BOOT_JOURNAL_BOOT_COUNT:-}"
  printf '},'

  printf '"containers":{'
  printf '"docker_available":'; json_bool "${DOCKER_AVAILABLE:-0}"; printf ','
  printf '"docker_access":'; json_q "${DOCKER_ACCESS:-n/d}"; printf ','
  printf '"docker_remote":'; json_bool "${DOCKER_REMOTE:-0}"; printf ','
  printf '"docker_version":'; json_q "${DOCKER_VERSION:-n/d}"; printf ','
  printf '"docker_root":'; json_q "${DOCKER_ROOT_DIR:-n/d}"; printf ','
  printf '"docker_storage_driver":'; json_q "${DOCKER_STORAGE_DRIVER:-n/d}"; printf ','
  printf '"docker_storage_pct":'; json_num_or_null "${DOCKER_STORAGE_USE_PCT:-}"; printf ','
  printf '"podman_available":'; json_bool "${PODMAN_AVAILABLE:-0}"; printf ','
  printf '"podman_access":'; json_q "${PODMAN_ACCESS:-n/d}"; printf ','
  printf '"podman_remote":'; json_bool "${PODMAN_REMOTE:-0}"; printf ','
  printf '"podman_version":'; json_q "${PODMAN_VERSION:-n/d}"; printf ','
  printf '"podman_rootless":'; json_q "${PODMAN_ROOTLESS:-n/d}"; printf ','
  printf '"podman_root":'; json_q "${PODMAN_ROOT_DIR:-n/d}"; printf ','
  printf '"podman_storage_driver":'; json_q "${PODMAN_STORAGE_DRIVER:-n/d}"; printf ','
  printf '"podman_storage_pct":'; json_num_or_null "${PODMAN_STORAGE_USE_PCT:-}"; printf ','
  printf '"crictl_available":'; json_bool "${CRICTL_AVAILABLE:-0}"; printf ','
  printf '"crictl_access":'; json_q "${CRICTL_ACCESS:-n/d}"; printf ','
  printf '"total":'; json_num_or_null "${CONTAINER_TOTAL_COUNT:-}"; printf ','
  printf '"inspected":'; json_num_or_null "${CONTAINER_INSPECTED_COUNT:-}"; printf ','
  printf '"running":'; json_num_or_null "${CONTAINER_RUNNING_COUNT:-}"; printf ','
  printf '"restarting":'; json_num_or_null "${CONTAINER_RESTARTING_COUNT:-}"; printf ','
  printf '"exited":'; json_num_or_null "${CONTAINER_EXITED_COUNT:-}"; printf ','
  printf '"unhealthy":'; json_num_or_null "${CONTAINER_UNHEALTHY_COUNT:-}"; printf ','
  printf '"oomkilled":'; json_num_or_null "${CONTAINER_OOMKILLED_COUNT:-}"; printf ','
  printf '"restart_count_high":'; json_num_or_null "${CONTAINER_HIGH_RESTART_COUNT:-}"; printf ','
  printf '"memory_limited":'; json_num_or_null "${CONTAINER_MEMORY_LIMITED_COUNT:-}"; printf ','
  printf '"cpu_limited":'; json_num_or_null "${CONTAINER_CPU_LIMITED_COUNT:-}"; printf ','
  printf '"memory_near_limit":'; json_num_or_null "${CONTAINER_MEMORY_NEAR_LIMIT_COUNT:-}"; printf ','
  printf '"cpu_near_limit":'; json_num_or_null "${CONTAINER_CPU_NEAR_LIMIT_COUNT:-}"; printf ','
  printf '"cpu_throttled":'; json_num_or_null "${CONTAINER_CPU_THROTTLED_COUNT:-}"; printf ','
  printf '"max_cpu_pct":'; json_num_or_null "${CONTAINER_MAX_CPU_PCT:-}"; printf ','
  printf '"max_memory_pct":'; json_num_or_null "${CONTAINER_MAX_MEM_PCT:-}"; printf ','
  printf '"max_storage_pct":'; json_num_or_null "${CONTAINER_MAX_STORAGE_PCT:-}"; printf ','
  printf '"max_local_log_bytes":'; json_num_or_null "${CONTAINER_LOG_MAX_BYTES:-}"; printf ','
  printf '"privileged":'; json_num_or_null "${CONTAINER_PRIVILEGED_COUNT:-}"; printf ','
  printf '"docker_socket_mounts":'; json_num_or_null "${CONTAINER_DOCKER_SOCKET_MOUNT_COUNT:-}"; printf ','
  printf '"mode":'; json_q "${CONTAINER_MODE:-normal}"; printf ','
  printf '"deep_scanned_containers":'; json_num_or_null "${CONTAINER_DEEP_SCANNED_COUNT:-0}"; printf ','
  printf '"deep_log_lines":'; json_num_or_null "${CONTAINER_DEEP_LOG_LINES:-0}"; printf ','
  printf '"deep_pattern_matches":'; json_num_or_null "${CONTAINER_DEEP_PATTERN_COUNT:-0}"; printf ','
  printf '"deep_correlated_containers":'; json_num_or_null "${CONTAINER_DEEP_CORRELATED_CONTAINER_COUNT:-0}"; printf ','
  printf '"deep_issues":'; _json_container_deep_issues_array; printf ','
  printf '"details":'; _json_container_details_array; printf ','
  printf '"stats":'; _json_container_stats_array
  printf '},'

  printf '"kubernetes":{'
  printf '"client":'; json_q "${K8S_CLI:-n/d}"; printf ','
  printf '"client_version":'; json_q "${K8S_CLIENT_VERSION:-n/d}"; printf ','
  printf '"access":'; json_q "${K8S_ACCESS:-no disponible}"; printf ','
  printf '"context":'; json_q "${K8S_CONTEXT_EFFECTIVE:-n/d}"; printf ','
  printf '"server":'; json_q "${K8S_SERVER:-n/d}"; printf ','
  printf '"user":'; json_q "${K8S_USER:-n/d}"; printf ','
  printf '"platform":'; json_q "${K8S_PLATFORM:-Kubernetes}"; printf ','
  printf '"server_version":'; json_q "${K8S_SERVER_VERSION:-n/d}"; printf ','
  printf '"openshift_version":'; json_q "${K8S_OPENSHIFT_VERSION:-n/d}"; printf ','
  printf '"mode":'; json_q "${K8S_MODE:-deep}"; printf ','
  printf '"scope":'; json_q "${K8S_SCOPE:-cluster}"; printf ','
  printf '"permission_denied":'; json_num_or_null "${K8S_PERMISSION_DENIED:-0}"; printf ','
  printf '"nodes":'; json_num_or_null "${K8S_NODE_COUNT:-0}"; printf ','
  printf '"nodes_not_ready":'; json_num_or_null "${K8S_NODE_NOTREADY_COUNT:-0}"; printf ','
  printf '"memory_pressure_nodes":'; json_num_or_null "${K8S_NODE_MEMORY_PRESSURE_COUNT:-0}"; printf ','
  printf '"disk_pressure_nodes":'; json_num_or_null "${K8S_NODE_DISK_PRESSURE_COUNT:-0}"; printf ','
  printf '"pid_pressure_nodes":'; json_num_or_null "${K8S_NODE_PID_PRESSURE_COUNT:-0}"; printf ','
  printf '"pods":'; json_num_or_null "${K8S_POD_COUNT:-0}"; printf ','
  printf '"pods_pending":'; json_num_or_null "${K8S_POD_PENDING_COUNT:-0}"; printf ','
  printf '"pods_not_ready":'; json_num_or_null "${K8S_POD_NOTREADY_COUNT:-0}"; printf ','
  printf '"pods_crashloop":'; json_num_or_null "${K8S_POD_CRASHLOOP_COUNT:-0}"; printf ','
  printf '"pods_imagepull":'; json_num_or_null "${K8S_POD_IMAGEPULL_COUNT:-0}"; printf ','
  printf '"pods_oomkilled":'; json_num_or_null "${K8S_POD_OOMKILLED_COUNT:-0}"; printf ','
  printf '"pods_evicted":'; json_num_or_null "${K8S_POD_EVICTED_COUNT:-0}"; printf ','
  printf '"services_no_endpoints":'; json_num_or_null "${K8S_SERVICE_NO_ENDPOINT_COUNT:-0}"; printf ','
  printf '"services_no_ready_endpoints":'; json_num_or_null "${K8S_SERVICE_NO_READY_ENDPOINT_COUNT:-0}"; printf ','
  printf '"pvc_pending":'; json_num_or_null "${K8S_PVC_PENDING_COUNT:-0}"; printf ','
  printf '"failed_scheduling":'; json_num_or_null "${K8S_FAILED_SCHEDULING_COUNT:-0}"; printf ','
  printf '"probe_failures":'; json_num_or_null "${K8S_PROBE_FAILURE_COUNT:-0}"; printf ','
  printf '"failed_attach":'; json_num_or_null "${K8S_FAILED_ATTACH_COUNT:-0}"; printf ','
  printf '"failed_mount":'; json_num_or_null "${K8S_FAILED_MOUNT_COUNT:-0}"; printf ','
  printf '"storage_provision_failures":'; json_num_or_null "${K8S_STORAGE_PROVISION_FAILURE_COUNT:-0}"; printf ','
  printf '"workloads_degraded":'; json_num_or_null "${K8S_WORKLOAD_DEGRADED_COUNT:-0}"; printf ','
  printf '"warning_events":'; json_num_or_null "${K8S_WARNING_EVENT_COUNT:-0}"; printf ','
  printf '"warning_events_recent":'; json_num_or_null "${K8S_WARNING_EVENT_RECENT_COUNT:-0}"; printf ','
  printf '"warning_events_stale":'; json_num_or_null "${K8S_WARNING_EVENT_STALE_COUNT:-0}"; printf ','
  printf '"warning_events_unknown_time":'; json_num_or_null "${K8S_WARNING_EVENT_UNKNOWN_TIME_COUNT:-0}"; printf ','
  printf '"metrics_available":'; json_bool "${K8S_METRICS_AVAILABLE:-0}"; printf ','
  printf '"kubelet_stats_ok":'; json_num_or_null "${K8S_KUBELET_STATS_OK_COUNT:-0}"; printf ','
  printf '"kubelet_stats_failed":'; json_num_or_null "${K8S_KUBELET_STATS_FAIL_COUNT:-0}"; printf ','
  printf '"openshift_degraded_operators":'; json_num_or_null "${K8S_OPENSHIFT_DEGRADED_OPERATORS:-0}"; printf ','
  printf '"openshift_unavailable_operators":'; json_num_or_null "${K8S_OPENSHIFT_UNAVAILABLE_OPERATORS:-0}"; printf ','
  printf '"nodes_detail":'; _json_k8s_nodes_array; printf ','
  printf '"pod_issues":'; _json_k8s_pod_issues_array; printf ','
  printf '"service_issues":'; _json_k8s_service_issues_array; printf ','
  printf '"pvc_issues":'; _json_k8s_pvc_issues_array; printf ','
  printf '"workload_issues":'; _json_k8s_workload_issues_array; printf ','
  printf '"warning_event_details":'; _json_k8s_warning_events_array
  printf '}'
  printf '}'
}

print_json_report() {
  local -a scope=("$@") categories=()
  ((${#scope[@]})) || scope=(all)
  if [[ "${scope[0]}" == all ]]; then
    categories=(cpu processes memory io filesystem network logging systemd boot containers kubernetes)
  else
    local sc
    for sc in "${scope[@]}"; do
      case "$sc" in cpu|processes|memory|io|filesystem|network|logging|systemd|boot|containers|kubernetes) categories+=("$sc") ;; esac
    done
  fi
  local generated host first cat status e id c domain points iv msg i
  generated="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
  host="${HOSTNAME_FQDN:-$(hostname 2>/dev/null || echo unknown)}"

  printf '{\n'
  printf '  "schema_version":'; json_q "$SYS_DIAG_JSON_SCHEMA_VERSION"; printf ',\n'
  printf '  "sysdiag_version":'; json_q "$SYS_DIAG_VERSION"; printf ',\n'
  printf '  "generated_at":'; json_q "$generated"; printf ',\n'
  printf '  "read_only":true,\n'
  printf '  "scope":'; _json_array_strings "${scope[@]}"; printf ',\n'
  printf '  "host":'; json_q "$host"; printf ',\n'

  printf '  "summary":['
  first=1
  for cat in "${categories[@]}"; do
    status="$(_json_category_status "$cat")"
    (( first )) || printf ','; first=0
    printf '{"category":'; json_q "$cat"; printf ',"title":'; json_q "$(category_title "$cat")"; printf ',"status":'; json_q "$status";
    printf ',"score":%s,"signals":%s,"confidence":' "${SCORE[$cat]:-0}" "${DOMAIN_COUNT[$cat]:-0}"; json_q "$(confidence_for_category "$cat")";
    printf ',"impact":'; json_q "$(impact_label "${IMPACT[$cat]:-0}")"; printf '}'
  done
  printf '],\n'

  printf '  "findings":['
  first=1
  for e in "${EVIDENCE[@]:-}"; do
    [[ -n "$e" ]] || continue
    IFS='|' read -r id c domain points iv msg <<<"$e"
    (( first )) || printf ','; first=0
    printf '{"id":'; json_q "$id"; printf ',"category":'; json_q "$c"; printf ',"domain":'; json_q "$domain";
    printf ',"points":%s,"impact":' "${points:-0}"; json_q "$(impact_label "${iv:-0}")"; printf ',"message":'; json_q "$msg"; printf '}'
  done
  printf '],\n'

  printf '  "limitations":'; _json_array_strings "${LIMITATIONS[@]:-}"; printf ',\n'
  printf '  "next_steps":['
  first=1
  for ((i=0; i<${#NEXT_STEPS[@]}; i++)); do
    (( first )) || printf ','; first=0
    printf '{"description":'; json_q "${NEXT_STEPS[$i]}"; printf ',"commands":'; _json_commands_array "${NEXT_COMMANDS[$i]}"; printf '}'
  done
  printf '],\n'
  printf '  "metrics":'; _json_metrics_object; printf '\n'
  printf '}\n'
}
