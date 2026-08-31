collect_cpu_topology() {
  CPU_LOGICAL_COUNT="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  CPU_PHYSICAL_CORES=""; CPU_SOCKETS=""; CPU_THREADS_PER_CORE=""; CPU_SMT_EXTRA=0; CPU_TOPOLOGY_SOURCE="fallback"

  if have_cmd lscpu; then
    local topo
    topo="$(run_with_timeout 3 env LC_ALL=C lscpu -p=CPU,CORE,SOCKET,ONLINE 2>/dev/null \
      | awk -F, '$1 !~ /^#/ && ($4=="Y" || $4=="") {print $1","$2","$3}' || true)"
    if [[ -n "$topo" ]]; then
      CPU_PHYSICAL_CORES="$(awk -F, '!seen[$3":"$2]++{c++}END{print c+0}' <<<"$topo")"
      CPU_SOCKETS="$(awk -F, '!seen[$3]++{c++}END{print c+0}' <<<"$topo")"
      local topo_logical
      topo_logical="$(sed '/^[[:space:]]*$/d' <<<"$topo" | wc -l | tr -d ' ')"
      if (( CPU_PHYSICAL_CORES > 0 )); then CPU_THREADS_PER_CORE="$(awk -v l="$topo_logical" -v c="$CPU_PHYSICAL_CORES" 'BEGIN{printf "%.2g",l/c}')"; fi
      CPU_TOPOLOGY_SOURCE="lscpu/kernel"
    fi
  fi

  if [[ -z "$CPU_PHYSICAL_CORES" || "$CPU_PHYSICAL_CORES" == "0" ]] && [[ -r /proc/cpuinfo ]]; then
    CPU_PHYSICAL_CORES="$(awk '
      /^physical id[[:space:]]*:/ {phys=$NF;hp=1}
      /^core id[[:space:]]*:/ {core=$NF;if(hp)seen[phys":"core]=1}
      END{for(k in seen)c++;print c+0}' /proc/cpuinfo 2>/dev/null)"
    [[ "$CPU_PHYSICAL_CORES" == "0" ]] && CPU_PHYSICAL_CORES="$CPU_LOGICAL_COUNT"
    CPU_SOCKETS="$(awk '/^physical id[[:space:]]*:/{seen[$NF]=1}END{for(k in seen)c++;print c+0}' /proc/cpuinfo 2>/dev/null)"
    [[ "$CPU_SOCKETS" == "0" ]] && CPU_SOCKETS=1
    CPU_THREADS_PER_CORE="$(awk -v l="$CPU_LOGICAL_COUNT" -v c="$CPU_PHYSICAL_CORES" 'BEGIN{if(c>0)printf "%.2g",l/c;else print "n/d"}')"
    CPU_TOPOLOGY_SOURCE="/proc/cpuinfo"
  fi

  CPU_PHYSICAL_CORES="${CPU_PHYSICAL_CORES:-$CPU_LOGICAL_COUNT}"; CPU_SOCKETS="${CPU_SOCKETS:-1}"; CPU_THREADS_PER_CORE="${CPU_THREADS_PER_CORE:-1}"
  if [[ "$CPU_LOGICAL_COUNT" =~ ^[0-9]+$ && "$CPU_PHYSICAL_CORES" =~ ^[0-9]+$ ]] && ((CPU_LOGICAL_COUNT>CPU_PHYSICAL_CORES)); then
    CPU_SMT_EXTRA=$((CPU_LOGICAL_COUNT-CPU_PHYSICAL_CORES))
  fi
  CPU_COUNT="$CPU_LOGICAL_COUNT"
}

collect_system() {
  local rc=0
  HOSTNAME_FQDN="$(run_with_timeout 3 hostname -f 2>/dev/null)" || rc=$?
  if (( rc == 124 )); then add_limitation "El comando hostname -f no respondió en 3s; se usa hostname corto."; HOSTNAME_FQDN="$(hostname 2>/dev/null || echo unknown)"; fi
  [[ -n "$HOSTNAME_FQDN" ]] || HOSTNAME_FQDN="$(hostname 2>/dev/null || echo unknown)"
  KERNEL="$(uname -srmo 2>/dev/null || uname -a)"; UPTIME_PRETTY="$(uptime -p 2>/dev/null || true)"
  collect_cpu_topology
  OS_PRETTY="unknown"
  if [[ -r /etc/os-release ]]; then source /etc/os-release; OS_PRETTY="${PRETTY_NAME:-${NAME:-unknown}}"; fi
  VIRT="unknown"
  if have_cmd systemd-detect-virt; then VIRT="$(run_with_timeout 3 systemd-detect-virt 2>/dev/null || true)"; [[ -n "$VIRT" ]] || VIRT="none"; fi
}

print_system() {
  section "SISTEMA"
  kv "Hostname:" "$HOSTNAME_FQDN"; kv "SO:" "$OS_PRETTY"; kv "Kernel:" "$KERNEL"; kv "Uptime:" "${UPTIME_PRETTY:-unknown}"
  kv "Núcleos físicos:" "$CPU_PHYSICAL_CORES"; kv "CPUs lógicas (hilos):" "$CPU_LOGICAL_COUNT"; kv "Hilos por núcleo:" "$CPU_THREADS_PER_CORE"; kv "Sockets:" "$CPU_SOCKETS"
  ((CPU_SMT_EXTRA>0)) && kv "Hilos SMT adicionales:" "$CPU_SMT_EXTRA"
  kv "Virtualización:" "$VIRT"
  if (( ${EXPLAIN:-0} == 1 )); then
    printf '\n  Explicación CPU:\n'
    printf '    - Núcleos físicos son cores; CPUs lógicas son hilos que Linux puede planificar.\n'
    printf '    - Con SMT/Hyper-Threading puede haber más CPUs lógicas que cores físicos.\n'
    printf '    - En una VM solo puede mostrarse la topología presentada por el hipervisor. Fuente: %s.\n' "$CPU_TOPOLOGY_SOURCE"
  fi
}
