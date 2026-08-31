# Container runtime diagnostics (Docker/Podman + lightweight CRI visibility).
# Read-only by design: no start/stop/restart/rm/prune/pull/exec actions.

CONTAINER_DETAIL_LIMIT_NORMAL=40
CONTAINER_DETAIL_LIMIT_VERBOSE=80
CONTAINER_LOG_WARN_BYTES=$((100*1024*1024))
CONTAINER_LOG_CRIT_BYTES=$((1024*1024*1024))
CONTAINER_DEEP_LOG_TIMEOUT_SECONDS="${CONTAINER_DEEP_LOG_TIMEOUT_SECONDS:-120}"

declare -a CONTAINER_DETAILS CONTAINER_STATS_DETAILS CONTAINER_DEEP_ISSUES
declare -A CONTAINER_STATUS_BY_KEY CONTAINER_HEALTH_BY_KEY CONTAINER_RESTARTS_BY_KEY CONTAINER_EXIT_BY_KEY CONTAINER_OOM_BY_KEY
declare -A CONTAINER_MEM_LIMIT_BY_KEY CONTAINER_CPU_LIMIT_BY_KEY CONTAINER_PID_BY_KEY
declare -A CONTAINER_CG_PATH_BY_KEY CONTAINER_CG_PERIODS_BEFORE CONTAINER_CG_THROTTLED_BEFORE
declare -A CONTAINER_CG_PERIODS_AFTER CONTAINER_CG_THROTTLED_AFTER

_container_clean_field() {
  local x
  x="$(printf '%s' "${1-}" | sanitize_terminal_text | tr '|' '/')"
  trim "$x"
}

_container_count_lines() {
  sed '/^[[:space:]]*$/d' | wc -l | tr -d ' '
}

_container_redact_log_sample() {
  printf '%s' "${1-}" | sed -E \
    -e 's/([Aa]uthorization:[[:space:]]*[Bb]earer[[:space:]]+)[^[:space:]]+/\1<redacted>/g' \
    -e 's/((password|passwd|pwd|token|api[_-]?key|secret)[[:space:]]*[:=][[:space:]]*)[^ ,;]+/\1<redacted>/Ig'
}

_container_is_remote_endpoint() {
  local ep="${1:-}"
  case "$ep" in
    tcp://*|http://*|https://*|ssh://*) return 0 ;;
    *) return 1 ;;
  esac
}

_container_path_fstype() {
  local path="$1" fs=""
  if have_cmd findmnt; then
    fs="$(run_with_timeout 2 findmnt -rn -T "$path" -o FSTYPE 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$fs" && -r /proc/self/mountinfo ]]; then
    # Longest mountpoint prefix wins; field after '-' is fstype.
    fs="$(awk -v p="$path" '
      function unesc(s){gsub(/\\040/," ",s);gsub(/\\011/,"\t",s);gsub(/\\012/,"\n",s);gsub(/\\134/,"\\",s);return s}
      {
        mp=unesc($5); if (p==mp || index(p,mp "/")==1) {
          for(i=6;i<=NF;i++) if($i=="-"){t=$(i+1); break}
          if(length(mp)>best){best=length(mp);fst=t}
        }
      } END{print fst}' /proc/self/mountinfo 2>/dev/null)"
  fi
  printf '%s' "$fs"
}

_container_remote_fstype() {
  case "${1,,}" in
    nfs|nfs4|cifs|smb3|ceph|ceph-fuse|glusterfs|fuse.glusterfs|sshfs|fuse.sshfs|9p|afs|lustre) return 0 ;;
    *) return 1 ;;
  esac
}

_container_storage_usage() {
  local runtime="$1" root="$2" fs="" raw="" pct="" rc=0
  CONTAINER_STORAGE_USAGE_RESULT=""
  [[ -n "$root" && "$root" != "n/d" && -e "$root" ]] || return 1
  fs="$(_container_path_fstype "$root")"
  if _container_remote_fstype "$fs"; then
    add_limitation "El storage de $runtime está sobre ${fs:-un filesystem remoto}; se omite df automático para evitar bloquear el diagnóstico."
    return 2
  fi
  raw="$(run_with_timeout 3 df -P "$root" 2>/dev/null)" || rc=$?
  if (( rc == 124 )); then
    add_limitation "La consulta de espacio del storage de $runtime superó 3s; se omite su uso."
    return 3
  elif (( rc != 0 )); then
    add_limitation "No se pudo consultar el uso del filesystem que contiene el storage de $runtime."
    return 1
  fi
  pct="$(awk 'NR==2{gsub(/%/,"",$5); print $5}' <<<"$raw")"
  [[ "$pct" =~ ^[0-9]+$ ]] || return 1
  CONTAINER_STORAGE_USAGE_RESULT="$pct"
  return 0
}

_container_cgroup2_mount() {
  if [[ -n "${CONTAINER_CGROUP2_MOUNT_OVERRIDE:-}" ]]; then printf '%s' "$CONTAINER_CGROUP2_MOUNT_OVERRIDE"; return 0; fi
  local mp=""
  if have_cmd findmnt; then mp="$(findmnt -rn -t cgroup2 -o TARGET 2>/dev/null | head -n1)"; fi
  if [[ -z "$mp" && -r /proc/self/mountinfo ]]; then
    mp="$(awk '$0 ~ / - cgroup2 / {print $5; exit}' /proc/self/mountinfo 2>/dev/null)"
  fi
  printf '%s' "$mp"
}

_container_cgroup_path_for_pid() {
  local pid="$1" rel="" proc_root="${CONTAINER_PROC_ROOT:-/proc}"
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 && -r "$proc_root/$pid/cgroup" ]] || return 1
  rel="$(awk -F: '$1=="0" && $2=="" {print $3; exit}' "$proc_root/$pid/cgroup" 2>/dev/null)"
  [[ -n "$rel" ]] || return 1
  printf '%s' "$rel"
}

_container_cg_cpu_values() {
  local file="$1" periods throttled
  [[ -r "$file" ]] || return 1
  periods="$(awk '$1=="nr_periods"{print $2}' "$file" 2>/dev/null)"
  throttled="$(awk '$1=="nr_throttled"{print $2}' "$file" 2>/dev/null)"
  [[ "$periods" =~ ^[0-9]+$ && "$throttled" =~ ^[0-9]+$ ]] || return 1
  printf '%s %s' "$periods" "$throttled"
}

_container_snapshot_cgroups() {
  local phase="$1" cgroot="$CONTAINER_CGROUP2_MOUNT" key pid rel vals p t
  [[ -n "$cgroot" ]] || return 0
  for key in "${!CONTAINER_PID_BY_KEY[@]}"; do
    pid="${CONTAINER_PID_BY_KEY[$key]:-0}"
    rel="$(_container_cgroup_path_for_pid "$pid" || true)"
    [[ -n "$rel" ]] || continue
    CONTAINER_CG_PATH_BY_KEY[$key]="$rel"
    vals="$(_container_cg_cpu_values "$cgroot$rel/cpu.stat" || true)"
    read -r p t <<<"$vals"
    [[ "$p" =~ ^[0-9]+$ && "$t" =~ ^[0-9]+$ ]] || continue
    if [[ "$phase" == before ]]; then
      CONTAINER_CG_PERIODS_BEFORE[$key]="$p"; CONTAINER_CG_THROTTLED_BEFORE[$key]="$t"
    else
      CONTAINER_CG_PERIODS_AFTER[$key]="$p"; CONTAINER_CG_THROTTLED_AFTER[$key]="$t"
    fi
  done
}

_container_add_detail() {
  local runtime="$1" raw="$2"
  local id name image status exitcode oom pid restarts health memlimit nanocpus cpuquota cpuperiod privileged netmode restartpolicy logdriver logpath mounts
  IFS='|' read -r id name image status exitcode oom pid restarts health memlimit nanocpus cpuquota cpuperiod privileged netmode restartpolicy logdriver logpath mounts <<<"$raw"
  id="$(_container_clean_field "$id")"; name="$(_container_clean_field "$name")"; name="${name#/}"
  image="$(_container_clean_field "$image")"; status="${status,,}"; health="${health,,}"
  [[ -n "$name" ]] || name="${id:0:12}"
  [[ "$exitcode" =~ ^-?[0-9]+$ ]] || exitcode=0
  [[ "$pid" =~ ^[0-9]+$ ]] || pid=0
  [[ "$restarts" =~ ^[0-9]+$ ]] || restarts=0
  [[ "$memlimit" =~ ^[0-9]+$ ]] || memlimit=0
  [[ "$nanocpus" =~ ^-?[0-9]+$ ]] || nanocpus=0
  [[ "$cpuquota" =~ ^-?[0-9]+$ ]] || cpuquota=0
  [[ "$cpuperiod" =~ ^[0-9]+$ ]] || cpuperiod=0
  local key="$runtime|$name" cpulimited=0
  (( nanocpus > 0 || cpuquota > 0 )) && cpulimited=1
  CONTAINER_MEM_LIMIT_BY_KEY[$key]="$memlimit"
  CONTAINER_STATUS_BY_KEY[$key]="$status"; CONTAINER_HEALTH_BY_KEY[$key]="${health:-none}"; CONTAINER_RESTARTS_BY_KEY[$key]="$restarts"; CONTAINER_EXIT_BY_KEY[$key]="$exitcode"; CONTAINER_OOM_BY_KEY[$key]="${oom,,}"
  CONTAINER_CPU_LIMIT_BY_KEY[$key]="$cpulimited"
  (( pid > 0 )) && CONTAINER_PID_BY_KEY[$key]="$pid"

  ((CONTAINER_INSPECTED_COUNT+=1))
  case "$status" in
    running) ((CONTAINER_RUNNING_COUNT+=1)) ;;
    restarting) ((CONTAINER_RESTARTING_COUNT+=1)) ;;
    exited|stopped) ((CONTAINER_EXITED_COUNT+=1)) ;;
    paused) ((CONTAINER_PAUSED_COUNT+=1)) ;;
    created|configured) ((CONTAINER_CREATED_COUNT+=1)) ;;
    dead|unknown) ((CONTAINER_DEAD_COUNT+=1)) ;;
  esac
  case "$health" in
    healthy) ((CONTAINER_HEALTHY_COUNT+=1)) ;;
    unhealthy) ((CONTAINER_UNHEALTHY_COUNT+=1)) ;;
    starting) ((CONTAINER_HEALTH_STARTING_COUNT+=1)) ;;
    none|""|"<no value>") ((CONTAINER_NO_HEALTHCHECK_COUNT+=1)) ;;
  esac
  [[ "${oom,,}" == true ]] && ((CONTAINER_OOMKILLED_COUNT+=1))
  if (( exitcode == 137 )); then
    ((CONTAINER_EXIT137_COUNT+=1)); [[ "${oom,,}" != true ]] && ((CONTAINER_EXIT137_NONOOM_COUNT+=1))
  fi
  if [[ "$status" == exited || "$status" == stopped ]] && (( exitcode != 0 )); then ((CONTAINER_EXIT_NONZERO_COUNT+=1)); fi
  (( restarts >= 10 )) && ((CONTAINER_HIGH_RESTART_COUNT+=1))
  (( memlimit > 0 )) && ((CONTAINER_MEMORY_LIMITED_COUNT+=1))
  (( cpulimited == 1 )) && ((CONTAINER_CPU_LIMITED_COUNT+=1))
  [[ "${privileged,,}" == true ]] && ((CONTAINER_PRIVILEGED_COUNT+=1))
  [[ "$netmode" == host ]] && ((CONTAINER_HOST_NETWORK_COUNT+=1))
  if [[ "$mounts" == *"/var/run/docker.sock"* || "$mounts" == *"/run/docker.sock"* ]]; then ((CONTAINER_DOCKER_SOCKET_MOUNT_COUNT+=1)); fi

  local logbytes=0
  local storage_remote=0
  [[ "$runtime" == docker && "${DOCKER_STORAGE_REMOTE:-0}" == 1 ]] && storage_remote=1
  [[ "$runtime" == podman && "${PODMAN_STORAGE_REMOTE:-0}" == 1 ]] && storage_remote=1
  if (( storage_remote == 0 )) && [[ -n "$logpath" && "$logpath" != "<no value>" && -f "$logpath" && -r "$logpath" ]]; then
    logbytes="$(run_with_timeout 2 stat -c '%s' "$logpath" 2>/dev/null || echo 0)"
    [[ "$logbytes" =~ ^[0-9]+$ ]] || logbytes=0
    CONTAINER_LOG_TOTAL_BYTES=$((CONTAINER_LOG_TOTAL_BYTES+logbytes))
    (( logbytes > CONTAINER_LOG_MAX_BYTES )) && { CONTAINER_LOG_MAX_BYTES=$logbytes; CONTAINER_LOG_MAX_NAME="$runtime/$name"; }
  fi

  CONTAINER_DETAILS+=("$runtime|$id|$name|$image|$status|$exitcode|${oom,,}|$pid|$restarts|${health:-none}|$memlimit|$cpulimited|${privileged,,}|$netmode|$restartpolicy|$logdriver|$logbytes|$mounts")
}

_collect_docker() {
  DOCKER_AVAILABLE=0; DOCKER_ACCESS="no disponible"; DOCKER_REMOTE=0; DOCKER_VERSION="n/d"; DOCKER_ENDPOINT="n/d"
  DOCKER_ROOT_DIR="n/d"; DOCKER_STORAGE_DRIVER="n/d"; DOCKER_LOGGING_DRIVER="n/d"; DOCKER_CGROUP_DRIVER="n/d"; DOCKER_CGROUP_VERSION="n/d"
  DOCKER_CONTAINER_COUNT=0; DOCKER_VOLUME_COUNT="n/d"; DOCKER_NETWORK_COUNT="n/d"; DOCKER_IMAGE_COUNT="n/d"; DOCKER_STORAGE_USE_PCT="n/d"; DOCKER_STORAGE_REMOTE=0
  have_cmd docker || return 0
  DOCKER_AVAILABLE=1

  if [[ -n "${DOCKER_HOST:-}" ]]; then
    DOCKER_ENDPOINT="$DOCKER_HOST"
  else
    local ctx="" rc=0
    ctx="$(run_with_timeout 2 docker context show 2>/dev/null)" || rc=$?
    if (( rc == 0 )) && [[ -n "$ctx" ]]; then
      DOCKER_ENDPOINT="$(run_with_timeout 2 docker context inspect --format '{{.Endpoints.docker.Host}}' "$ctx" 2>/dev/null || true)"
    fi
    [[ -n "$DOCKER_ENDPOINT" ]] || DOCKER_ENDPOINT="unix:///var/run/docker.sock"
  fi
  if _container_is_remote_endpoint "$DOCKER_ENDPOINT"; then
    DOCKER_REMOTE=1; DOCKER_ACCESS="remoto (omitido)"
    add_limitation "Docker apunta a un endpoint remoto ($DOCKER_ENDPOINT); SYSdiag omite su diagnóstico profundo para no correlacionarlo con el host local."
    return 0
  fi

  local info="" rc=0
  info="$(run_with_timeout 5 docker info --format '{{.ServerVersion}}|{{.DockerRootDir}}|{{.Driver}}|{{.LoggingDriver}}|{{.CgroupDriver}}|{{.CgroupVersion}}' 2>/dev/null)" || rc=$?
  if (( rc == 124 )); then
    DOCKER_ACCESS="timeout"; add_limitation "Docker info superó 5s; se corta el análisis Docker para no encadenar esperas."; return 0
  elif (( rc != 0 )) || [[ -z "$info" ]]; then
    DOCKER_ACCESS="sin acceso"; add_limitation "Docker está instalado pero el daemon/socket no es accesible con el usuario actual."; return 0
  fi
  DOCKER_ACCESS="disponible"
  IFS='|' read -r DOCKER_VERSION DOCKER_ROOT_DIR DOCKER_STORAGE_DRIVER DOCKER_LOGGING_DRIVER DOCKER_CGROUP_DRIVER DOCKER_CGROUP_VERSION <<<"$info"
  local docker_fs=""; docker_fs="$(_container_path_fstype "$DOCKER_ROOT_DIR")"
  if _container_remote_fstype "$docker_fs"; then
    DOCKER_STORAGE_REMOTE=1; add_limitation "El storage de Docker está sobre ${docker_fs:-un filesystem remoto}; se omiten df y stat de logs automáticos."
  else
    _container_storage_usage Docker "$DOCKER_ROOT_DIR" || true; DOCKER_STORAGE_USE_PCT="${CONTAINER_STORAGE_USAGE_RESULT:-n/d}"
  fi

  local ids=""; rc=0
  ids="$(run_with_timeout 5 docker ps -aq --no-trunc 2>/dev/null)" || rc=$?
  if (( rc != 0 )); then add_limitation "Docker ps no pudo completarse; inventario de contenedores limitado."; return 0; fi
  DOCKER_CONTAINER_COUNT="$(printf '%s\n' "$ids" | _container_count_lines)"
  local max="$CONTAINER_DETAIL_LIMIT_NORMAL"; (( ${VERBOSE:-0} == 1 )) && max="$CONTAINER_DETAIL_LIMIT_VERBOSE"
  [[ "${CONTAINER_MODE:-normal}" == deep ]] && max="$DOCKER_CONTAINER_COUNT"
  local -a arr=(); mapfile -t arr < <(printf '%s\n' "$ids" | sed '/^[[:space:]]*$/d' | head -n "$max")
  if (( DOCKER_CONTAINER_COUNT > max )); then add_limitation "Docker tiene $DOCKER_CONTAINER_COUNT contenedores; el detalle automático se limita a $max."; fi
  if ((${#arr[@]})); then
    local fmt='{{.Id}}|{{.Name}}|{{.Config.Image}}|{{.State.Status}}|{{.State.ExitCode}}|{{.State.OOMKilled}}|{{.State.Pid}}|{{.RestartCount}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.HostConfig.Memory}}|{{.HostConfig.NanoCpus}}|{{.HostConfig.CpuQuota}}|{{.HostConfig.CpuPeriod}}|{{.HostConfig.Privileged}}|{{.HostConfig.NetworkMode}}|{{.HostConfig.RestartPolicy.Name}}|{{.HostConfig.LogConfig.Type}}|{{.LogPath}}|{{range .Mounts}}{{.Source}}=>{{.Destination}},{{end}}'
    local details=""
    local inspect_timeout=8; [[ "${CONTAINER_MODE:-normal}" == deep ]] && inspect_timeout=60
    rc=0; details="$(run_with_timeout "$inspect_timeout" docker inspect --format "$fmt" "${arr[@]}" 2>/dev/null)" || rc=$?
    if (( rc == 124 )); then add_limitation "Docker inspect superó ${inspect_timeout}s; detalle de contenedores omitido."
    elif (( rc != 0 )); then add_limitation "Docker inspect no pudo completar el detalle de contenedores."
    else while IFS= read -r line; do [[ -n "$line" ]] && _container_add_detail docker "$line"; done <<<"$details"; fi
  fi
  DOCKER_VOLUME_COUNT="$(run_with_timeout 3 docker volume ls -q 2>/dev/null | _container_count_lines || echo n/d)"
  DOCKER_NETWORK_COUNT="$(run_with_timeout 3 docker network ls -q 2>/dev/null | _container_count_lines || echo n/d)"
  DOCKER_IMAGE_COUNT="$(run_with_timeout 4 docker image ls -q --no-trunc 2>/dev/null | sort -u | _container_count_lines || echo n/d)"
}

_collect_podman() {
  PODMAN_AVAILABLE=0; PODMAN_ACCESS="no disponible"; PODMAN_REMOTE=0; PODMAN_VERSION="n/d"; PODMAN_ROOTLESS="n/d"
  PODMAN_ROOT_DIR="n/d"; PODMAN_STORAGE_DRIVER="n/d"; PODMAN_CGROUP_MANAGER="n/d"; PODMAN_CGROUP_VERSION="n/d"
  PODMAN_CONTAINER_COUNT=0; PODMAN_VOLUME_COUNT="n/d"; PODMAN_NETWORK_COUNT="n/d"; PODMAN_IMAGE_COUNT="n/d"; PODMAN_STORAGE_USE_PCT="n/d"; PODMAN_STORAGE_REMOTE=0
  have_cmd podman || return 0
  PODMAN_AVAILABLE=1
  if [[ -n "${CONTAINER_HOST:-}${CONTAINER_CONNECTION:-}" ]]; then
    PODMAN_REMOTE=1; PODMAN_ACCESS="remoto (omitido)"
    add_limitation "Podman tiene configurada una conexión remota; SYSdiag omite su diagnóstico profundo para no correlacionarla con el host local."
    return 0
  fi
  local info="" rc=0
  info="$(run_with_timeout 5 podman info --format '{{.Version.Version}}|{{.Store.GraphRoot}}|{{.Store.GraphDriverName}}|{{.Host.CgroupManager}}|{{.Host.CgroupVersion}}|{{.Host.Security.Rootless}}' 2>/dev/null)" || rc=$?
  if (( rc == 124 )); then PODMAN_ACCESS="timeout"; add_limitation "Podman info superó 5s; se corta el análisis Podman."; return 0
  elif (( rc != 0 )) || [[ -z "$info" ]]; then PODMAN_ACCESS="sin acceso"; add_limitation "Podman está instalado pero no puede consultarse con el usuario actual."; return 0; fi
  PODMAN_ACCESS="disponible"
  IFS='|' read -r PODMAN_VERSION PODMAN_ROOT_DIR PODMAN_STORAGE_DRIVER PODMAN_CGROUP_MANAGER PODMAN_CGROUP_VERSION PODMAN_ROOTLESS <<<"$info"
  if [[ "${PODMAN_ROOTLESS,,}" == true ]]; then
    add_limitation "Podman se consulta en contexto rootless del usuario actual; contenedores de otros usuarios pueden no ser visibles y algunas métricas de red pueden no estar disponibles."
  fi
  local podman_fs=""; podman_fs="$(_container_path_fstype "$PODMAN_ROOT_DIR")"
  if _container_remote_fstype "$podman_fs"; then
    PODMAN_STORAGE_REMOTE=1; add_limitation "El storage de Podman está sobre ${podman_fs:-un filesystem remoto}; se omiten df y stat de logs automáticos."
  else
    _container_storage_usage Podman "$PODMAN_ROOT_DIR" || true; PODMAN_STORAGE_USE_PCT="${CONTAINER_STORAGE_USAGE_RESULT:-n/d}"
  fi

  local ids=""; rc=0
  ids="$(run_with_timeout 5 podman ps -aq --no-trunc 2>/dev/null)" || rc=$?
  if (( rc != 0 )); then add_limitation "Podman ps no pudo completarse; inventario limitado."; return 0; fi
  PODMAN_CONTAINER_COUNT="$(printf '%s\n' "$ids" | _container_count_lines)"
  local max="$CONTAINER_DETAIL_LIMIT_NORMAL"; (( ${VERBOSE:-0} == 1 )) && max="$CONTAINER_DETAIL_LIMIT_VERBOSE"
  [[ "${CONTAINER_MODE:-normal}" == deep ]] && max="$PODMAN_CONTAINER_COUNT"
  local -a arr=(); mapfile -t arr < <(printf '%s\n' "$ids" | sed '/^[[:space:]]*$/d' | head -n "$max")
  (( PODMAN_CONTAINER_COUNT > max )) && add_limitation "Podman tiene $PODMAN_CONTAINER_COUNT contenedores; el detalle automático se limita a $max."
  if ((${#arr[@]})); then
    local fmt='{{.Id}}|{{.Name}}|{{.ImageName}}|{{.State.Status}}|{{.State.ExitCode}}|{{.State.OOMKilled}}|{{.State.Pid}}|{{.RestartCount}}|{{.State.Healthcheck.Status}}|{{.HostConfig.Memory}}|{{.HostConfig.NanoCpus}}|{{.HostConfig.CpuQuota}}|{{.HostConfig.CpuPeriod}}|{{.HostConfig.Privileged}}|{{.HostConfig.NetworkMode}}|{{.HostConfig.RestartPolicy.Name}}|{{.HostConfig.LogConfig.Type}}|{{.LogPath}}|{{range .Mounts}}{{.Source}}=>{{.Destination}},{{end}}'
    local details=""
    local inspect_timeout=8; [[ "${CONTAINER_MODE:-normal}" == deep ]] && inspect_timeout=60
    rc=0; details="$(run_with_timeout "$inspect_timeout" podman inspect --type container --format "$fmt" "${arr[@]}" 2>/dev/null)" || rc=$?
    if (( rc == 124 )); then add_limitation "Podman inspect superó ${inspect_timeout}s; detalle omitido."
    elif (( rc != 0 )); then
      add_limitation "Podman inspect no pudo obtener todos los campos avanzados; se mantiene el inventario básico."
      local basic=""; basic="$(run_with_timeout 5 podman ps -a --no-trunc --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.State}}|0|false|0|{{.Restarts}}|none|0|0|0|0|false|||none||' 2>/dev/null || true)"
      while IFS= read -r line; do [[ -n "$line" ]] && _container_add_detail podman "$line"; done <<<"$basic"
    else while IFS= read -r line; do [[ -n "$line" ]] && _container_add_detail podman "$line"; done <<<"$details"; fi
  fi
  PODMAN_VOLUME_COUNT="$(run_with_timeout 3 podman volume ls -q 2>/dev/null | _container_count_lines || echo n/d)"
  PODMAN_NETWORK_COUNT="$(run_with_timeout 3 podman network ls -q 2>/dev/null | _container_count_lines || echo n/d)"
  PODMAN_IMAGE_COUNT="$(run_with_timeout 4 podman image ls -q --no-trunc 2>/dev/null | sort -u | _container_count_lines || echo n/d)"
}

_collect_cri_visibility() {
  CRICTL_AVAILABLE=0; CRICTL_ACCESS="no disponible"; CRICTL_CONTAINER_COUNT="n/d"
  have_cmd crictl || return 0
  CRICTL_AVAILABLE=1
  local out="" rc=0
  out="$(run_with_timeout 4 crictl ps -a -q 2>/dev/null)" || rc=$?
  if (( rc == 124 )); then CRICTL_ACCESS="timeout"; add_limitation "Crictl ps superó 4s; visibilidad CRI omitida."
  elif (( rc != 0 )); then CRICTL_ACCESS="sin acceso"
  else CRICTL_ACCESS="disponible"; CRICTL_CONTAINER_COUNT="$(printf '%s\n' "$out" | _container_count_lines)"; fi
}

_collect_container_stats_runtime() {
  local runtime="$1" out="" rc=0
  if [[ "$runtime" == docker ]]; then
    [[ "$DOCKER_ACCESS" == disponible ]] || return 0
    rc=0; out="$(run_with_timeout 8 docker stats --no-stream --no-trunc --format '{{.ID}}|{{.Name}}|{{.CPUPerc}}|{{.MemPerc}}|{{.MemUsage}}|{{.BlockIO}}|{{.PIDs}}' 2>/dev/null)" || rc=$?
  else
    [[ "$PODMAN_ACCESS" == disponible ]] || return 0
    rc=0; out="$(run_with_timeout 8 podman stats --no-stream --no-trunc --format '{{.ContainerID}}|{{.Name}}|{{.CPUPerc}}|{{.MemPerc}}|{{.MemUsage}}|{{.BlockIO}}|{{.PIDs}}' 2>/dev/null)" || rc=$?
  fi
  if (( rc == 124 )); then add_limitation "${runtime^} stats superó 8s; presión de CPU/memoria no medida."; return 0
  elif (( rc != 0 )); then add_limitation "${runtime^} stats no pudo obtener una muestra de recursos."; return 0; fi
  [[ -n "$out" ]] || return 0
  ((CONTAINER_STATS_VALID_COUNT+=1))
  local id name cpu memperc memusage blockio pids cp mem key limit cpulimited
  while IFS='|' read -r id name cpu memperc memusage blockio pids; do
    [[ -n "$name" ]] || continue
    name="$(_container_clean_field "$name")"; key="$runtime|$name"
    cp="${cpu%%%}"; cp="${cp//,/\.}"; mem="${memperc%%%}"; mem="${mem//,/\.}"
    [[ "$cp" =~ ^[0-9]+([.][0-9]+)?$ ]] || cp=""
    [[ "$mem" =~ ^[0-9]+([.][0-9]+)?$ ]] || mem=""
    if [[ -n "$cp" ]] && num_gt "$cp" "$CONTAINER_MAX_CPU_PCT"; then CONTAINER_MAX_CPU_PCT="$cp"; CONTAINER_MAX_CPU_NAME="$runtime/$name"; fi
    if [[ -n "$mem" ]] && num_gt "$mem" "$CONTAINER_MAX_MEM_PCT"; then CONTAINER_MAX_MEM_PCT="$mem"; CONTAINER_MAX_MEM_NAME="$runtime/$name"; fi
    limit="${CONTAINER_MEM_LIMIT_BY_KEY[$key]:-0}"; cpulimited="${CONTAINER_CPU_LIMIT_BY_KEY[$key]:-0}"
    if [[ -n "$mem" && "$limit" =~ ^[0-9]+$ && "$limit" -gt 0 ]] && num_ge "$mem" 90; then ((CONTAINER_MEMORY_NEAR_LIMIT_COUNT+=1)); fi
    if [[ -n "$cp" && "$cpulimited" == 1 ]] && num_ge "$cp" 90; then ((CONTAINER_CPU_NEAR_LIMIT_COUNT+=1)); fi
    CONTAINER_STATS_DETAILS+=("$runtime|$name|${cp:-n/d}|${mem:-n/d}|$(_container_clean_field "$memusage")|$(_container_clean_field "$blockio")|$(_container_clean_field "$pids")")
  done <<<"$out"
}

_analyze_container_cgroup_throttle() {
  local key p0 t0 p1 t1 dp dt ratio
  for key in "${!CONTAINER_CG_PERIODS_BEFORE[@]}"; do
    p0="${CONTAINER_CG_PERIODS_BEFORE[$key]}"; t0="${CONTAINER_CG_THROTTLED_BEFORE[$key]}"
    p1="${CONTAINER_CG_PERIODS_AFTER[$key]:-$p0}"; t1="${CONTAINER_CG_THROTTLED_AFTER[$key]:-$t0}"
    (( p1 >= p0 )) && dp=$((p1-p0)) || dp=0
    (( t1 >= t0 )) && dt=$((t1-t0)) || dt=0
    (( dp >= 3 && dt > 0 )) || continue
    ratio="$(awk -v t="$dt" -v p="$dp" 'BEGIN{printf "%.1f",100*t/p}')"
    if num_ge "$ratio" 20; then
      ((CONTAINER_CPU_THROTTLED_COUNT+=1))
      if num_gt "$ratio" "$CONTAINER_MAX_THROTTLE_PCT"; then CONTAINER_MAX_THROTTLE_PCT="$ratio"; CONTAINER_MAX_THROTTLE_NAME="$key"; fi
    fi
  done
}

_container_deep_category_text() {
  case "$1" in
    memory) printf '%s|%s' "Indicios de presión o fallo de memoria en los logs." "Comparar OOMKilled, límite/uso de memoria y memory.events; si se confirma, corregir fuga/consumo o dimensionar el límite manualmente." ;;
    storage) printf '%s|%s' "Indicios de falta de espacio o cuota en almacenamiento." "Comprobar filesystem del host, logs, writable layer y volúmenes; liberar o ampliar capacidad sólo tras identificar qué crece." ;;
    permission) printf '%s|%s' "Indicios de permisos insuficientes al acceder a un recurso." "Comprobar UID/GID, permisos del bind mount/volumen, modo rootless y contexto de seguridad; corregir permisos/configuración manualmente." ;;
    refused) printf '%s|%s' "Hay conexiones rechazadas por un destino alcanzable que no acepta la conexión." "Identificar host/puerto de destino y comprobar que la dependencia escucha y que la configuración apunta al endpoint correcto." ;;
    timeout) printf '%s|%s' "Hay timeouts de conexión o de operaciones externas." "Distinguir saturación de la dependencia, ruta/firewall, latencia y timeout de aplicación mediante pruebas al destino concreto." ;;
    dns) printf '%s|%s' "Hay errores de resolución de nombres." "Comprobar DNS del contenedor, resolv.conf, nombre configurado y reachability del resolver antes de investigar la aplicación." ;;
    tls) printf '%s|%s' "Hay errores TLS/certificado." "Comprobar expiración, CA de confianza, nombre/SAN, hora del sistema y cadena presentada por el peer." ;;
    auth) printf '%s|%s' "Hay errores de autenticación o autorización." "Comprobar credenciales, secretos/configuración y permisos del servicio remoto sin mostrar ni almacenar secretos en SYSdiag." ;;
    readonly) printf '%s|%s' "La aplicación intenta escribir sobre un filesystem o mount de solo lectura." "Identificar la ruta y comprobar flags del mount, volumen/bind y diseño de persistencia antes de cambiar permisos." ;;
    port) printf '%s|%s' "Hay indicios de conflicto al enlazar un puerto o socket." "Comprobar qué proceso/servicio usa el puerto y la configuración de bind; cambiar puerto o eliminar el conflicto sólo de forma manual." ;;
    fd) printf '%s|%s' "Hay indicios de agotamiento de descriptores de fichero." "Comparar uso real de FDs, límites del contenedor/proceso y posible fuga antes de aumentar límites." ;;
    missing) printf '%s|%s' "Hay rutas o ficheros requeridos que no existen." "Comprobar configuración, imagen y mounts esperados; restaurar/proveer el recurso correcto en vez de crear rutas a ciegas." ;;
    panic) printf '%s|%s' "Los logs contienen señales de fallo grave de aplicación, panic, segfault o traceback." "Correlacionar la última señal con exit code, restart policy y logs inmediatamente anteriores; corregir la causa en la aplicación/dependencia." ;;
    database) printf '%s|%s' "Hay errores que apuntan a una dependencia de base de datos." "Comprobar nombre/puerto, reachability, autenticación y estado de la base de datos antes de reiniciar el contenedor consumidor." ;;
    io) printf '%s|%s' "Hay errores de I/O en operaciones de la aplicación." "Correlacionar con filesystem, dispositivo, volumen y kernel del host para distinguir storage local, volumen y backend remoto." ;;
    generic_error) printf '%s|%s' "Los logs contienen mensajes ERROR/FATAL/EXCEPTION no clasificados con mayor precisión." "Revisar las muestras en su contexto temporal y correlacionarlas con estado, reinicios y dependencias; un error histórico aislado no demuestra una incidencia actual." ;;
    *) printf '%s|%s' "Hay evidencia adicional en logs." "Revisar la muestra y correlacionarla con el estado actual antes de realizar cambios." ;;
  esac
}

_container_deep_scan_logs() {
  local runtime="$1" id="$2" name="$3" idx="$4" summary="$RUNTIME_DIR/container-log-scan-${idx}.txt"
  local timeout_s="$CONTAINER_DEEP_LOG_TIMEOUT_SECONDS" rc=0 key="$runtime|$name"
  [[ "$timeout_s" =~ ^[0-9]+$ ]] || timeout_s=120
  (( timeout_s < 10 )) && timeout_s=10
  (( timeout_s > 600 )) && timeout_s=600

  local awk_program='\
function hit(k, line) { c[k]++; if (!(k in sample)) sample[k]=line }\
{\
  total++; low=tolower($0); specific=0;\
  if (low ~ /(out of memory|oomkilled|cannot allocate memory|memory allocation failed)/) { hit("memory",$0); specific=1 }\
  if (low ~ /(no space left on device|disk quota exceeded|filesystem full)/) { hit("storage",$0); specific=1 }\
  if (low ~ /(permission denied|operation not permitted|access denied)/) { hit("permission",$0); specific=1 }\
  if (low ~ /(connection refused|connect: refused|actively refused)/) { hit("refused",$0); specific=1 }\
  if (low ~ /(connection timed out|connect timeout|i\/o timeout|context deadline exceeded|request timed out)/) { hit("timeout",$0); specific=1 }\
  if (low ~ /(temporary failure in name resolution|name or service not known|no such host|dns.*fail|could not resolve|server misbehaving)/) { hit("dns",$0); specific=1 }\
  if (low ~ /(x509:|certificate.*(expired|invalid|unknown)|tls handshake|ssl.*(error|fail)|certificate verify failed)/) { hit("tls",$0); specific=1 }\
  if (low ~ /(unauthorized|forbidden|authentication failed|invalid credentials|access token.*(invalid|expired))/) { hit("auth",$0); specific=1 }\
  if (low ~ /(read-only file system|filesystem is read-only)/) { hit("readonly",$0); specific=1 }\
  if (low ~ /(address already in use|bind.*failed|cannot assign requested address)/) { hit("port",$0); specific=1 }\
  if (low ~ /(too many open files|file descriptor.*(limit|exhaust))/) { hit("fd",$0); specific=1 }\
  if (low ~ /(no such file or directory|file not found|cannot find.*file)/) { hit("missing",$0); specific=1 }\
  if (low ~ /(segmentation fault|segfault|panic:|fatal error|traceback \(most recent call last\)|unhandled exception)/) { hit("panic",$0); specific=1 }\
  if (low ~ /(database.*(unavailable|failed|error)|sql.*(connection|connect).*(failed|refused|timeout)|postgres.*(refused|failed|timeout)|mysql.*(refused|failed|timeout))/) { hit("database",$0); specific=1 }\
  if (low ~ /(input\/output error|i\/o error|stale file handle)/) { hit("io",$0); specific=1 }\
  if (!specific && low ~ /(^|[^a-z])(error|fatal|exception)([^a-z]|$)/) hit("generic_error",$0);\
}\
END {\
  print "META|" total;\
  order[1]="memory";order[2]="storage";order[3]="permission";order[4]="refused";order[5]="timeout";order[6]="dns";order[7]="tls";order[8]="auth";order[9]="readonly";order[10]="port";order[11]="fd";order[12]="missing";order[13]="panic";order[14]="database";order[15]="io";order[16]="generic_error";\
  for(i=1;i<=16;i++){k=order[i]; if(c[k]>0){gsub(/[|]/,"/",sample[k]); print k "|" c[k] "|" sample[k]}}\
}'

  if [[ "$runtime" == docker ]]; then
    if have_cmd timeout; then timeout --signal=TERM --kill-after=1 "${timeout_s}s" docker logs --timestamps "$id" 2>&1 | awk "$awk_program" >"$summary"; rc=${PIPESTATUS[0]};
    else docker logs --timestamps "$id" 2>&1 | awk "$awk_program" >"$summary"; rc=${PIPESTATUS[0]}; fi
  else
    if have_cmd timeout; then timeout --signal=TERM --kill-after=1 "${timeout_s}s" podman logs --timestamps "$id" 2>&1 | awk "$awk_program" >"$summary"; rc=${PIPESTATUS[0]};
    else podman logs --timestamps "$id" 2>&1 | awk "$awk_program" >"$summary"; rc=${PIPESTATUS[0]}; fi
  fi

  local scan_state="completo" total=0 line category count sample interpretation resolution text
  if (( rc == 124 || rc == 137 )); then
    scan_state="timeout"; ((CONTAINER_DEEP_LOG_TIMEOUT_COUNT+=1))
    add_limitation "El análisis completo de logs de $runtime/$name superó ${timeout_s}s; sus patrones se consideran parciales."
  elif (( rc != 0 )); then
    scan_state="no disponible"; ((CONTAINER_DEEP_LOG_ERROR_COUNT+=1))
    add_limitation "No se pudieron leer los logs de $runtime/$name; la salida de error del runtime no se interpretará como log de aplicación."
    CONTAINER_DEEP_ISSUES+=("$runtime|$name|$scan_state|0|logs|0|Sin muestra|No se pudieron analizar los logs.|Comprobar acceso al logging driver/runtime.")
    return 0
  fi
  [[ -r "$summary" ]] || { CONTAINER_DEEP_ISSUES+=("$runtime|$name|$scan_state|0|logs|0|Sin muestra|No se pudieron analizar los logs.|Comprobar acceso al logging driver/runtime."); return 0; }

  while IFS='|' read -r category count sample; do
    if [[ "$category" == META ]]; then total="${count:-0}"; continue; fi
    [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || continue
    text="$(_container_deep_category_text "$category")"; IFS='|' read -r interpretation resolution <<<"$text"
    sample="$(_container_clean_field "$sample")"; sample="$(_container_redact_log_sample "$sample")"
    CONTAINER_DEEP_ISSUES+=("$runtime|$name|$scan_state|$total|$category|$count|$sample|$interpretation|$resolution")
    ((CONTAINER_DEEP_PATTERN_COUNT+=count))
    case "$category" in
      memory) ((CONTAINER_DEEP_MEMORY_COUNT+=count)) ;;
      storage|io|readonly) ((CONTAINER_DEEP_STORAGE_COUNT+=count)) ;;
      refused|timeout|dns) ((CONTAINER_DEEP_NETWORK_COUNT+=count)) ;;
      permission|auth) ((CONTAINER_DEEP_ACCESS_COUNT+=count)) ;;
      panic) ((CONTAINER_DEEP_CRASH_COUNT+=count)) ;;
    esac
  done <"$summary"
  CONTAINER_DEEP_LOG_LINES=$((CONTAINER_DEEP_LOG_LINES+total))

  local status="${CONTAINER_STATUS_BY_KEY[$key]:-unknown}" health="${CONTAINER_HEALTH_BY_KEY[$key]:-none}" restarts="${CONTAINER_RESTARTS_BY_KEY[$key]:-0}" exitcode="${CONTAINER_EXIT_BY_KEY[$key]:-0}" oom="${CONTAINER_OOM_BY_KEY[$key]:-false}"
  if [[ "$status" == restarting || "$status" == dead || "$health" == unhealthy || "$oom" == true ]] || { [[ "$status" == exited ]] && (( exitcode != 0 )); } || (( restarts >= 10 )); then
    if grep -qv '^META|' "$summary" 2>/dev/null; then ((CONTAINER_DEEP_CORRELATED_CONTAINER_COUNT+=1)); fi
  fi
}

_collect_container_deep_analysis() {
  [[ "${CONTAINER_MODE:-normal}" == deep ]] || return 0
  local row runtime id name rest idx=0
  for row in "${CONTAINER_DETAILS[@]:-}"; do
    [[ -n "$row" ]] || continue
    IFS='|' read -r runtime id name rest <<<"$row"
    [[ "$runtime" == docker || "$runtime" == podman ]] || continue
    ((idx+=1)); ((CONTAINER_DEEP_SCANNED_COUNT+=1))
    _container_deep_scan_logs "$runtime" "$id" "$name" "$idx"
  done
}

collect_containers() {
  CONTAINER_DETAILS=(); CONTAINER_STATS_DETAILS=(); CONTAINER_DEEP_ISSUES=(); CONTAINER_MEM_LIMIT_BY_KEY=(); CONTAINER_CPU_LIMIT_BY_KEY=(); CONTAINER_PID_BY_KEY=()
  CONTAINER_STATUS_BY_KEY=(); CONTAINER_HEALTH_BY_KEY=(); CONTAINER_RESTARTS_BY_KEY=(); CONTAINER_EXIT_BY_KEY=(); CONTAINER_OOM_BY_KEY=()
  CONTAINER_CG_PATH_BY_KEY=(); CONTAINER_CG_PERIODS_BEFORE=(); CONTAINER_CG_THROTTLED_BEFORE=(); CONTAINER_CG_PERIODS_AFTER=(); CONTAINER_CG_THROTTLED_AFTER=()
  CONTAINER_INSPECTED_COUNT=0; CONTAINER_RUNNING_COUNT=0; CONTAINER_EXITED_COUNT=0; CONTAINER_RESTARTING_COUNT=0; CONTAINER_PAUSED_COUNT=0; CONTAINER_CREATED_COUNT=0; CONTAINER_DEAD_COUNT=0
  CONTAINER_HEALTHY_COUNT=0; CONTAINER_UNHEALTHY_COUNT=0; CONTAINER_HEALTH_STARTING_COUNT=0; CONTAINER_NO_HEALTHCHECK_COUNT=0; CONTAINER_OOMKILLED_COUNT=0; CONTAINER_HIGH_RESTART_COUNT=0
  CONTAINER_EXIT137_COUNT=0; CONTAINER_EXIT137_NONOOM_COUNT=0; CONTAINER_EXIT_NONZERO_COUNT=0
  CONTAINER_MEMORY_LIMITED_COUNT=0; CONTAINER_CPU_LIMITED_COUNT=0; CONTAINER_MEMORY_NEAR_LIMIT_COUNT=0; CONTAINER_CPU_NEAR_LIMIT_COUNT=0; CONTAINER_CPU_THROTTLED_COUNT=0
  CONTAINER_PRIVILEGED_COUNT=0; CONTAINER_DOCKER_SOCKET_MOUNT_COUNT=0; CONTAINER_HOST_NETWORK_COUNT=0
  CONTAINER_LOG_TOTAL_BYTES=0; CONTAINER_LOG_MAX_BYTES=0; CONTAINER_LOG_MAX_NAME="n/d"
  CONTAINER_MAX_CPU_PCT=0; CONTAINER_MAX_CPU_NAME="n/d"; CONTAINER_MAX_MEM_PCT=0; CONTAINER_MAX_MEM_NAME="n/d"; CONTAINER_MAX_THROTTLE_PCT=0; CONTAINER_MAX_THROTTLE_NAME="n/d"
  CONTAINER_STATS_VALID_COUNT=0; CONTAINER_CGROUP2_MOUNT="$(_container_cgroup2_mount)"
  CONTAINER_DEEP_SCANNED_COUNT=0; CONTAINER_DEEP_LOG_LINES=0; CONTAINER_DEEP_PATTERN_COUNT=0; CONTAINER_DEEP_LOG_TIMEOUT_COUNT=0; CONTAINER_DEEP_LOG_ERROR_COUNT=0; CONTAINER_DEEP_CORRELATED_CONTAINER_COUNT=0
  CONTAINER_DEEP_MEMORY_COUNT=0; CONTAINER_DEEP_STORAGE_COUNT=0; CONTAINER_DEEP_NETWORK_COUNT=0; CONTAINER_DEEP_ACCESS_COUNT=0; CONTAINER_DEEP_CRASH_COUNT=0

  _collect_docker
  _collect_podman
  _collect_cri_visibility
  _container_snapshot_cgroups before
  _collect_container_stats_runtime docker
  _collect_container_stats_runtime podman
  _container_snapshot_cgroups after
  _analyze_container_cgroup_throttle
  _collect_container_deep_analysis

  CONTAINER_RUNTIME_COUNT=0
  (( DOCKER_AVAILABLE == 1 )) && ((CONTAINER_RUNTIME_COUNT+=1))
  (( PODMAN_AVAILABLE == 1 )) && ((CONTAINER_RUNTIME_COUNT+=1))
  CONTAINER_TOTAL_COUNT=$(( ${DOCKER_CONTAINER_COUNT:-0} + ${PODMAN_CONTAINER_COUNT:-0} ))
  CONTAINER_MAX_STORAGE_PCT=0; CONTAINER_MAX_STORAGE_RUNTIME="n/d"
  if [[ "${DOCKER_STORAGE_USE_PCT:-}" =~ ^[0-9]+$ ]] && (( DOCKER_STORAGE_USE_PCT > CONTAINER_MAX_STORAGE_PCT )); then CONTAINER_MAX_STORAGE_PCT="$DOCKER_STORAGE_USE_PCT"; CONTAINER_MAX_STORAGE_RUNTIME="Docker"; fi
  if [[ "${PODMAN_STORAGE_USE_PCT:-}" =~ ^[0-9]+$ ]] && (( PODMAN_STORAGE_USE_PCT > CONTAINER_MAX_STORAGE_PCT )); then CONTAINER_MAX_STORAGE_PCT="$PODMAN_STORAGE_USE_PCT"; CONTAINER_MAX_STORAGE_RUNTIME="Podman"; fi
  CONTAINERS_COLLECTED=1
}

analyze_containers() {
  (( ${CONTAINERS_COLLECTED:-0} == 1 )) || return 0
  if (( ${CONTAINER_RUNTIME_COUNT:-0} == 0 && ${CRICTL_AVAILABLE:-0} == 0 )); then
    add_next_step "No se detectó Docker, Podman ni crictl. Si este host debería ejecutar contenedores, confirmar runtime y PATH del usuario."       "command -v docker" "command -v podman" "command -v crictl"
    return 0
  fi
  if (( CONTAINER_RESTARTING_COUNT > 0 )); then
    add_finding "CONTAINER_RESTARTING" containers lifecycle 5 high "Hay ${CONTAINER_RESTARTING_COUNT} contenedor(es) en estado restarting; investigar el primer fallo antes de reiniciar el runtime."
    add_next_step "Identificar exit code, OOM, health y logs del contenedor que se reinicia." \
      "docker ps -a --no-trunc" "docker inspect <contenedor>" "docker logs --tail 100 <contenedor>" "podman ps -a --no-trunc" "podman inspect <contenedor>" "podman logs --tail 100 <contenedor>"
  elif (( CONTAINER_HIGH_RESTART_COUNT > 0 )); then
    add_finding "CONTAINER_RESTART_HISTORY" containers lifecycle 2 medium "${CONTAINER_HIGH_RESTART_COUNT} contenedor(es) inspeccionado(s) acumulan al menos 10 reinicios; confirmar si corresponden a un restart loop actual o histórico."
  fi

  if (( CONTAINER_UNHEALTHY_COUNT > 0 )); then
    add_finding "CONTAINER_UNHEALTHY" containers health 4 high "Hay ${CONTAINER_UNHEALTHY_COUNT} contenedor(es) running/unhealthy según su healthcheck; healthy/unhealthy refleja la prueba definida, no toda la disponibilidad funcional."
    add_next_step "Revisar qué comprueba realmente el healthcheck y correlacionarlo con logs y dependencias." \
      "docker inspect <contenedor> --format '{{json .State.Health}}'" "docker logs --tail 100 <contenedor>" "podman inspect <contenedor>"
  fi

  if (( CONTAINER_OOMKILLED_COUNT > 0 )); then
    add_finding "CONTAINER_OOMKILLED" containers memory_cgroup 5 high "${CONTAINER_OOMKILLED_COUNT} contenedor(es) muestran OOMKilled=true; esto puede ser OOM del cgroup aunque el host conserve memoria disponible."
    add_next_step "Comparar límite/uso de memoria del contenedor con eventos de cgroup y OOM del host." \
      "docker inspect <contenedor> --format '{{.State.OOMKilled}} {{.HostConfig.Memory}}'" "docker stats --no-stream <contenedor>" "cat /sys/fs/cgroup/<cgroup>/memory.events" "journalctl -k --since '-1 hour' | grep -Ei 'oom|out of memory|killed process'"
  fi

  if (( CONTAINER_EXIT137_NONOOM_COUNT > 0 )); then
    add_next_step "Hay ${CONTAINER_EXIT137_NONOOM_COUNT} contenedor(es) con exit 137 sin OOMKilled=true; 137 indica SIGKILL, no demuestra por sí solo un OOM."       "docker inspect <contenedor> --format '{{.State.ExitCode}} {{.State.OOMKilled}} {{.State.Error}}'" "podman inspect <contenedor>" "journalctl -k --since '-1 hour'"
  fi

  if (( CONTAINER_MEMORY_NEAR_LIMIT_COUNT > 0 )); then
    add_finding "CONTAINER_MEMORY_PRESSURE" containers resource_limits 3 high "${CONTAINER_MEMORY_NEAR_LIMIT_COUNT} contenedor(es) con límite de memoria están al 90% o más en la muestra; existe riesgo de OOM del cgroup si la presión continúa."
  fi
  if (( CONTAINER_CPU_THROTTLED_COUNT > 0 )); then
    add_finding "CONTAINER_CPU_THROTTLE" containers cpu_cgroup 3 medium "${CONTAINER_CPU_THROTTLED_COUNT} contenedor(es) muestran throttling de CPU durante la ventana observada; máximo ${CONTAINER_MAX_THROTTLE_PCT}% (${CONTAINER_MAX_THROTTLE_NAME})."
    add_next_step "Confirmar si el límite CPU está introduciendo latencia y compararlo con CPU libre del host." \
      "docker stats --no-stream" "podman stats --no-stream" "cat /sys/fs/cgroup/<cgroup>/cpu.stat"
  elif (( CONTAINER_CPU_NEAR_LIMIT_COUNT > 0 )); then
    add_finding "CONTAINER_CPU_LIMIT_PRESSURE" containers resource_limits 2 medium "${CONTAINER_CPU_NEAR_LIMIT_COUNT} contenedor(es) con cuota CPU muestran uso alto en la muestra; comprobar throttling antes de atribuir la lentitud al host."
  fi

  if (( CONTAINER_MAX_STORAGE_PCT >= 95 )); then
    add_finding "CONTAINER_STORAGE_CRITICAL" containers runtime_storage 5 critical "El filesystem que contiene el storage de ${CONTAINER_MAX_STORAGE_RUNTIME} está al ${CONTAINER_MAX_STORAGE_PCT}%; el runtime y otros contenedores pueden verse afectados."
    add_next_step "Determinar qué parte del storage del runtime crece antes de borrar o ejecutar prune." \
      "df -hT" "docker system df -v" "docker ps -a --size" "podman system df -v" "podman ps -a --size"
  elif (( CONTAINER_MAX_STORAGE_PCT >= 85 )); then
    add_finding "CONTAINER_STORAGE_HIGH" containers runtime_storage 2 medium "El filesystem que contiene el storage de ${CONTAINER_MAX_STORAGE_RUNTIME} está al ${CONTAINER_MAX_STORAGE_PCT}%; revisar crecimiento de layers, imágenes, logs y volúmenes."
  fi

  if (( CONTAINER_LOG_MAX_BYTES >= CONTAINER_LOG_CRIT_BYTES )); then
    add_finding "CONTAINER_LOG_LARGE" containers runtime_logs 3 high "Se ha observado al menos un log local de runtime >=1 GiB; máximo $(bytes_to_human "$CONTAINER_LOG_MAX_BYTES") en ${CONTAINER_LOG_MAX_NAME}."
    add_next_step "Revisar logging driver, rotación y causa del volumen de logs antes de truncar/borrar ficheros manualmente." \
      "docker inspect <contenedor> --format '{{.HostConfig.LogConfig.Type}} {{.LogPath}}'" "docker logs --tail 100 <contenedor>" "podman inspect <contenedor>"
  elif (( CONTAINER_LOG_MAX_BYTES >= CONTAINER_LOG_WARN_BYTES )); then
    add_finding "CONTAINER_LOG_GROWTH" containers runtime_logs 1 medium "Hay un log local de runtime >=100 MiB; máximo $(bytes_to_human "$CONTAINER_LOG_MAX_BYTES") en ${CONTAINER_LOG_MAX_NAME}."
  fi

  if (( CONTAINER_DOCKER_SOCKET_MOUNT_COUNT > 0 )); then
    add_next_step "${CONTAINER_DOCKER_SOCKET_MOUNT_COUNT} contenedor(es) tienen montado docker.sock; validar que ese nivel de control del daemon/host sea realmente necesario." \
      "docker inspect <contenedor> --format '{{json .Mounts}}'"
  fi
  if (( CONTAINER_PRIVILEGED_COUNT > 0 )); then
    add_next_step "${CONTAINER_PRIVILEGED_COUNT} contenedor(es) están en modo privileged; revisar si pueden sustituirse por permisos/capabilities mínimos." \
      "docker inspect <contenedor> --format '{{.HostConfig.Privileged}} {{json .HostConfig.CapAdd}}'" "podman inspect <contenedor>"
  fi

  if [[ "${CONTAINER_MODE:-normal}" == deep ]] && (( CONTAINER_DEEP_CORRELATED_CONTAINER_COUNT > 0 )); then
    add_finding "CONTAINER_DEEP_LOG_CORRELATION" containers deep_logs 2 medium "El análisis completo de logs encontró patrones de error en ${CONTAINER_DEEP_CORRELATED_CONTAINER_COUNT} contenedor(es) que además presentan estado, health, OOM o reinicios anómalos; los logs son evidencia de apoyo, no causalidad automática."
  fi
  if [[ "${CONTAINER_MODE:-normal}" == deep ]] && (( CONTAINER_DEEP_PATTERN_COUNT > 0 )); then
    add_next_step "Revisar las correlaciones del análisis profundo por contenedor y validar la hipótesis contra estado actual, dependencias y timestamps antes de aplicar cambios." \
      "docker inspect <contenedor>" "docker logs --timestamps <contenedor>" "podman inspect <contenedor>" "podman logs --timestamps <contenedor>"
  fi

  if (( ${SCORE[io]:-0} > 0 && CONTAINER_MAX_STORAGE_PCT >= 85 )); then
    add_finding "CONTAINER_HOST_STORAGE_CORRELATION" containers host_correlation 3 high "La presión de storage del runtime coincide con señales de I/O del host; priorizar la capa de almacenamiento antes de culpar a la aplicación containerizada."
  fi

  if (( DOCKER_AVAILABLE == 1 && DOCKER_REMOTE == 0 )) && [[ "$DOCKER_ACCESS" != "disponible" ]]; then
    add_next_step "Docker está instalado pero no se pudo consultar de forma fiable; comprobar daemon/socket y permisos sin reiniciar a ciegas." \
      "docker info" "systemctl status docker --no-pager -l" "ls -l /var/run/docker.sock"
  fi
  if (( PODMAN_AVAILABLE == 1 && PODMAN_REMOTE == 0 )) && [[ "$PODMAN_ACCESS" != "disponible" ]]; then
    add_next_step "Podman está instalado pero no se pudo consultar de forma fiable; comprobar contexto rootless/storage/runtime." \
      "podman info" "podman system connection list"
  fi
}

print_containers() {
  section "CONTENEDORES"
  kv "Modo de análisis:" "${CONTAINER_MODE:-normal}"
  kv "Docker:" "$([[ ${DOCKER_AVAILABLE:-0} == 1 ]] && printf '%s' "${DOCKER_ACCESS:-n/d}" || printf 'no instalado')"
  (( ${DOCKER_AVAILABLE:-0} == 1 )) && kv "Docker versión/storage:" "${DOCKER_VERSION:-n/d} / ${DOCKER_STORAGE_DRIVER:-n/d}"
  (( ${DOCKER_AVAILABLE:-0} == 1 )) && kv "Docker root / uso FS:" "${DOCKER_ROOT_DIR:-n/d} / ${DOCKER_STORAGE_USE_PCT:-n/d}$([[ ${DOCKER_STORAGE_USE_PCT:-} =~ ^[0-9]+$ ]] && echo '%' || true)"
  kv "Podman:" "$([[ ${PODMAN_AVAILABLE:-0} == 1 ]] && printf '%s' "${PODMAN_ACCESS:-n/d}" || printf 'no instalado')"
  (( ${PODMAN_AVAILABLE:-0} == 1 )) && kv "Podman versión/rootless:" "${PODMAN_VERSION:-n/d} / ${PODMAN_ROOTLESS:-n/d}"
  (( ${PODMAN_AVAILABLE:-0} == 1 )) && kv "Podman root / uso FS:" "${PODMAN_ROOT_DIR:-n/d} / ${PODMAN_STORAGE_USE_PCT:-n/d}$([[ ${PODMAN_STORAGE_USE_PCT:-} =~ ^[0-9]+$ ]] && echo '%' || true)"
  kv "CRI (crictl):" "$([[ ${CRICTL_AVAILABLE:-0} == 1 ]] && printf '%s' "${CRICTL_ACCESS:-n/d}" || printf 'no instalado')"
  (( ${CRICTL_AVAILABLE:-0} == 1 )) && kv "Contenedores visibles CRI:" "${CRICTL_CONTAINER_COUNT:-n/d}"

  subsection "ESTADO AGREGADO"
  kv "Contenedores Docker/Podman:" "${CONTAINER_TOTAL_COUNT:-0} (inspeccionados: ${CONTAINER_INSPECTED_COUNT:-0})"
  kv "Running / restarting:" "${CONTAINER_RUNNING_COUNT:-0} / ${CONTAINER_RESTARTING_COUNT:-0}"
  kv "Exited / paused / dead:" "${CONTAINER_EXITED_COUNT:-0} / ${CONTAINER_PAUSED_COUNT:-0} / ${CONTAINER_DEAD_COUNT:-0}"
  kv "Healthy / unhealthy / starting:" "${CONTAINER_HEALTHY_COUNT:-0} / ${CONTAINER_UNHEALTHY_COUNT:-0} / ${CONTAINER_HEALTH_STARTING_COUNT:-0}"
  kv "Sin healthcheck:" "${CONTAINER_NO_HEALTHCHECK_COUNT:-0}"
  kv "OOMKilled / exit 137:" "${CONTAINER_OOMKILLED_COUNT:-0} / ${CONTAINER_EXIT137_COUNT:-0}"
  kv "Exited con código !=0:" "${CONTAINER_EXIT_NONZERO_COUNT:-0}"
  kv "RestartCount >=10:" "${CONTAINER_HIGH_RESTART_COUNT:-0}"
  kv "Con límite memoria / CPU:" "${CONTAINER_MEMORY_LIMITED_COUNT:-0} / ${CONTAINER_CPU_LIMITED_COUNT:-0}"
  kv "Memoria >=90% del límite:" "${CONTAINER_MEMORY_NEAR_LIMIT_COUNT:-0}"
  kv "CPU cerca de cuota / throttled:" "${CONTAINER_CPU_NEAR_LIMIT_COUNT:-0} / ${CONTAINER_CPU_THROTTLED_COUNT:-0}"
  kv "Privileged / docker.sock:" "${CONTAINER_PRIVILEGED_COUNT:-0} / ${CONTAINER_DOCKER_SOCKET_MOUNT_COUNT:-0}"
  kv "Network mode host:" "${CONTAINER_HOST_NETWORK_COUNT:-0}"
  (( CONTAINER_LOG_MAX_BYTES > 0 )) && kv "Mayor log local observado:" "$(bytes_to_human "$CONTAINER_LOG_MAX_BYTES") (${CONTAINER_LOG_MAX_NAME})"

  if (( ${VERBOSE:-0} == 1 )) && ((${#CONTAINER_DETAILS[@]})); then
    subsection "DETALLE DE CONTENEDORES"
    printf '    %-7s %-24s %-12s %-8s %-8s %-10s %-12s %s\n' "Runtime" "Nombre" "Estado" "Exit" "OOM" "Restarts" "Health" "Imagen"
    local row runtime id name image status exitcode oom pid restarts health memlimit cpulimited privileged netmode restartpolicy logdriver logbytes mounts
    for row in "${CONTAINER_DETAILS[@]}"; do
      IFS='|' read -r runtime id name image status exitcode oom pid restarts health memlimit cpulimited privileged netmode restartpolicy logdriver logbytes mounts <<<"$row"
      printf '    %-7s %-24.24s %-12.12s %-8s %-8s %-10s %-12.12s %s\n' "$runtime" "$name" "$status" "$exitcode" "$oom" "$restarts" "$health" "$image"
    done
  fi

  if (( ${VERBOSE:-0} == 1 )) && ((${#CONTAINER_STATS_DETAILS[@]})); then
    subsection "MUESTRA DE RECURSOS"
    printf '    %-7s %-24s %-9s %-9s %-24s %s\n' "Runtime" "Nombre" "CPU%" "MEM%" "Memoria" "PIDs"
    local row runtime name cpu mem memusage blockio pids
    for row in "${CONTAINER_STATS_DETAILS[@]}"; do
      IFS='|' read -r runtime name cpu mem memusage blockio pids <<<"$row"
      printf '    %-7s %-24.24s %-9s %-9s %-24.24s %s\n' "$runtime" "$name" "$cpu" "$mem" "$memusage" "$pids"
    done
  fi

  if [[ "${CONTAINER_MODE:-normal}" == deep ]]; then
    subsection "ANÁLISIS PROFUNDO DE CONTENEDORES Y LOGS"
    kv "Contenedores analizados:" "${CONTAINER_DEEP_SCANNED_COUNT:-0}"
    kv "Líneas de log examinadas:" "${CONTAINER_DEEP_LOG_LINES:-0}"
    kv "Patrones relevantes:" "${CONTAINER_DEEP_PATTERN_COUNT:-0}"
    kv "Escaneos con timeout/error:" "${CONTAINER_DEEP_LOG_TIMEOUT_COUNT:-0} / ${CONTAINER_DEEP_LOG_ERROR_COUNT:-0}"
    kv "Correlación con estado anómalo:" "${CONTAINER_DEEP_CORRELATED_CONTAINER_COUNT:-0} contenedor(es)"
    if ((${#CONTAINER_DEEP_ISSUES[@]})); then
      local drow druntime dname dstate dlines dcat dcount dsample dinterp dresolution
      for drow in "${CONTAINER_DEEP_ISSUES[@]}"; do
        IFS='|' read -r druntime dname dstate dlines dcat dcount dsample dinterp dresolution <<<"$drow"
        printf '\n    [%s/%s] %s (%s coincidencia(s), logs: %s)\n' "$druntime" "$dname" "$dcat" "$dcount" "$dstate"
        printf '      Interpretación: %s\n' "$dinterp"
        printf '      Evidencia: %s\n' "$dsample"
        printf '      Posible resolución manual: %s\n' "$dresolution"
      done
    else
      printf '    No se han encontrado patrones de error reconocibles en los logs accesibles. Esto no demuestra que las aplicaciones estén sanas.\n'
    fi
    printf '\n    Nota: El modo profundo lee el histórico completo accesible sin usar --tail/--since, pero no lo vuelca en pantalla. Los timeouts se declaran como limitación.\n'
  fi

  if (( ${EXPLAIN:-0} == 1 )); then
    subsection "CÓMO INTERPRETARLO"
    printf '    - Un contenedor es un conjunto de procesos Linux aislados; el host y sus cgroups siguen siendo parte del diagnóstico.\n'
    printf '    - Running no implica healthy ni readiness funcional. RestartCount alto requiere contexto temporal.\n'
    printf '    - OOMKilled puede ser un OOM del cgroup aunque el host tenga memoria disponible.\n'
    printf '    - CPU libre en el host no descarta throttling por cuota del contenedor.\n'
    printf '    - El storage del runtime vive sobre un filesystem del host; layers/logs/volúmenes pueden llenarlo.\n'
    printf '    - SYSdiag no ejecuta prune, restart, rm ni ninguna otra acción mutante sobre contenedores.\n'
  fi
}
