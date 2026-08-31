declare -A SCORE
declare -A IMPACT
declare -A FINDING_SEEN
declare -A DOMAIN_SEEN
declare -A DOMAIN_COUNT
declare -A NEXT_STEP_SEEN
declare -a EVIDENCE
declare -a NEXT_STEPS
declare -a NEXT_COMMANDS
declare -a LIMITATIONS

init_scoring() {
  local cat
  for cat in cpu io memory processes filesystem network logging systemd boot containers kubernetes; do
    SCORE[$cat]=0
    IMPACT[$cat]=0
    DOMAIN_COUNT[$cat]=0
  done
  FINDING_SEEN=()
  DOMAIN_SEEN=()
  NEXT_STEP_SEEN=()
  EVIDENCE=()
  NEXT_STEPS=()
  NEXT_COMMANDS=()
  LIMITATIONS=()
}

impact_value() {
  case "${1,,}" in
    low|bajo) echo 1 ;;
    medium|medio) echo 2 ;;
    high|alto) echo 3 ;;
    critical|critico|crítico) echo 4 ;;
    *) echo 0 ;;
  esac
}

impact_label() {
  case "${1:-0}" in
    1) echo "BAJO" ;;
    2) echo "MEDIO" ;;
    3) echo "ALTO" ;;
    4) echo "CRÍTICO" ;;
    *) echo "SIN IMPACTO ESTIMADO" ;;
  esac
}

# Finding = evidencia deduplicable y explicable.
# id: identificador estable; domain: origen independiente de evidencia.
add_finding() {
  local id="$1" category="$2" domain="$3" points="$4" impact="$5" message="$6"
  [[ -n "${FINDING_SEEN[$id]:-}" ]] && return 0
  FINDING_SEEN[$id]=1

  SCORE[$category]=$(( ${SCORE[$category]:-0} + points ))
  local iv
  iv="$(impact_value "$impact")"
  (( iv > ${IMPACT[$category]:-0} )) && IMPACT[$category]="$iv"

  local dkey="${category}|${domain}"
  if [[ -z "${DOMAIN_SEEN[$dkey]:-}" ]]; then
    DOMAIN_SEEN[$dkey]=1
    DOMAIN_COUNT[$category]=$(( ${DOMAIN_COUNT[$category]:-0} + 1 ))
  fi

  EVIDENCE+=("$id|$category|$domain|$points|$iv|$message")
}

# Compatibilidad para módulos antiguos/terceros. Las versiones nuevas deben
# preferir add_finding para evitar doble conteo de señales correlacionadas.
add_evidence() {
  local category="$1" points="$2" message="$3"
  local id="legacy_${category}_${#EVIDENCE[@]}"
  add_finding "$id" "$category" "legacy" "$points" low "$message"
}

add_limitation() {
  local msg="$*" x
  for x in "${LIMITATIONS[@]:-}"; do [[ "$x" == "$msg" ]] && return; done
  LIMITATIONS+=("$msg")
}

add_next_step() {
  local description="$1"
  shift || true
  [[ -n "${NEXT_STEP_SEEN[$description]:-}" ]] && return 0
  NEXT_STEP_SEEN[$description]=1

  local commands="" cmd
  declare -A seen_cmd=()
  for cmd in "$@"; do
    [[ -n "$cmd" ]] || continue
    [[ -n "${seen_cmd[$cmd]:-}" ]] && continue
    seen_cmd[$cmd]=1
    commands+="${cmd}"$'\n'
  done
  commands="${commands%$'\n'}"
  [[ -n "$commands" ]] || commands="Revisar manualmente según el contexto; SYSdiag no propone una orden automática para este punto."

  NEXT_STEPS+=("$description")
  NEXT_COMMANDS+=("$commands")
}

confidence_for_category() {
  local category="$1"
  local score="${SCORE[$category]:-0}" domains="${DOMAIN_COUNT[$category]:-0}"
  if (( score >= 8 || (score >= 6 && domains >= 3) )); then echo "ALTA"
  elif (( score >= 4 || domains >= 2 )); then echo "MEDIA"
  elif (( score >= 1 )); then echo "BAJA"
  else echo "SIN INDICIOS"; fi
}

# Se mantiene para tests/compatibilidad, aunque el resumen usa categoría+dominios.
confidence_for_score() {
  local score="${1:-0}"
  if (( score >= 8 )); then echo "ALTA"
  elif (( score >= 4 )); then echo "MEDIA"
  elif (( score >= 1 )); then echo "BAJA"
  else echo "SIN INDICIOS"; fi
}

category_title() {
  case "$1" in
    cpu) echo "CPU / planificación" ;;
    io) echo "I/O / almacenamiento / esperas kernel" ;;
    memory) echo "Memoria" ;;
    processes) echo "Procesos" ;;
    filesystem) echo "Filesystem / espacio / inodos" ;;
    network) echo "Red / TCP / sockets" ;;
    logging) echo "Logs / capacidad de diagnóstico" ;;
    systemd) echo "Systemd / servicios" ;;
    boot) echo "Boot / arranque" ;;
    containers) echo "Contenedores / runtime" ;;
    kubernetes) echo "Kubernetes / OpenShift" ;;
    *) echo "$1" ;;
  esac
}

analyze_cross_signals() {
  local cpu_count=${CPU_COUNT:-1} load1=${LOAD1:-0} idle=${CPU_IDLE_PCT:-0} d=${PROC_D:-0}

  if num_gt "$load1" "$cpu_count" && num_gt "$idle" 40 && (( d > 0 )); then
    add_finding "IO_CROSS_LOAD_IDLE_D" io cross_correlation 3 high \
      "Load superior a CPUs con bastante CPU idle y procesos D: el load no parece explicarse por CPU."
    add_next_step \
      "Correlacionar los procesos D con wchan/stack y con los ficheros o recursos que están usando." \
      "ps -eo pid,ppid,user,stat,comm,wchan:32 | awk '\$4 ~ /^D/'" \
      "cat /proc/<PID>/wchan" \
      "sudo cat /proc/<PID>/stack" \
      "lsof -p <PID>"
  fi
}

print_score_explanation() {
  printf '\n  Cómo leer la priorización:\n'
  printf '    - Puntuación: peso acumulado de findings deduplicados. No es un porcentaje ni una probabilidad.\n'
  printf '    - Señales independientes: tipos de evidencia distintos (por ejemplo procesos D, await y correlación load/idle).\n'
  printf '    - Confianza: BAJA/MEDIA/ALTA según fuerza total y variedad de señales; una evidencia directa fuerte también puede dar ALTA.\n'
  printf '    - Impacto: efecto potencial observado/estimado sobre el host. Es independiente de la confianza.\n'
}

print_command_list() {
  local commands="$1" line
  printf '       Comandos sugeridos:\n'
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '         $ %s\n' "$line"
  done <<<"$commands"
}

print_analysis_summary() {
  section "ANÁLISIS Y PRIORIZACIÓN"

  local -a requested=("$@") categories=() all_categories=(cpu io memory processes filesystem network logging systemd boot containers kubernetes)
  local cat
  declare -A seen_categories=()

  # If no explicit scope was supplied, preserve the full diagnostic view.
  if ((${#requested[@]} == 0)); then
    requested=("${all_categories[@]}")
  fi

  # Keep requested areas plus any category that actually received a finding.
  # This matters for cross-domain evidence: e.g. CPU iowait can legitimately
  # create an I/O finding even when the user selected the CPU section.
  for cat in "${requested[@]}"; do
    [[ -n "${seen_categories[$cat]:-}" ]] && continue
    seen_categories[$cat]=1; categories+=("$cat")
  done
  for cat in "${all_categories[@]}"; do
    (( ${SCORE[$cat]:-0} > 0 )) || continue
    [[ -n "${seen_categories[$cat]:-}" ]] && continue
    seen_categories[$cat]=1; categories+=("$cat")
  done

  local best_cat="" best_score=-1 best_impact=-1 score impact
  for cat in "${categories[@]}"; do
    score=${SCORE[$cat]:-0}; impact=${IMPACT[$cat]:-0}
    if (( score > best_score || (score == best_score && impact > best_impact) )); then
      best_score=$score; best_impact=$impact; best_cat=$cat
    fi
  done

  if (( best_score <= 0 )); then
    printf '  No se han detectado señales fuertes con las comprobaciones seleccionadas en v%s.\n' "$SYS_DIAG_VERSION"
    printf '  Esto NO demuestra que el sistema esté sano; solo que estas métricas no muestran un patrón claro.\n'
  else
    kv "Hipótesis prioritaria:" "$(category_title "$best_cat")"
    kv "Puntuación:" "$best_score"
    kv "Señales independientes:" "${DOMAIN_COUNT[$best_cat]:-0}"
    kv "Confianza:" "$(confidence_for_category "$best_cat")"
    kv "Impacto estimado:" "$(impact_label "${IMPACT[$best_cat]:-0}")"
  fi

  print_score_explanation

  if (( ${VERBOSE:-0} == 1 )); then
    printf '\n  Estado por categoría relevante:\n'
    for cat in "${categories[@]}"; do
      printf '    %-42s score=%-3s señales=%-2s confianza=%-5s impacto=%s\n' \
        "$(category_title "$cat")" "${SCORE[$cat]:-0}" "${DOMAIN_COUNT[$cat]:-0}" \
        "$(confidence_for_category "$cat")" "$(impact_label "${IMPACT[$cat]:-0}")"
    done
  fi

  if (( ${VERBOSE:-0} == 1 )) && ((${#EVIDENCE[@]})); then
    printf '\n  Findings:\n'
    local e id c domain p iv m
    for e in "${EVIDENCE[@]}"; do
      IFS='|' read -r id c domain p iv m <<<"$e"
      # Findings outside the explicit scope are still displayed when they were
      # generated by cross-domain analysis and therefore have a non-zero score.
      printf '    - [%s] [%s +%s | %s | impacto %s] %s\n' \
        "$id" "$(category_title "$c")" "$p" "$domain" "$(impact_label "$iv")" "$m"
    done
  fi

  if ((${#LIMITATIONS[@]})); then
    printf '\n  Limitaciones durante la ejecución:\n'
    local l
    for l in "${LIMITATIONS[@]}"; do printf '    - %s\n' "$l"; done
  fi

  printf '\n  QUÉ MIRARÍA AHORA\n'
  printf '  ────────────────────────────────────────────────────────\n'
  if ((${#NEXT_STEPS[@]})); then
    local i
    for ((i=0; i<${#NEXT_STEPS[@]}; i++)); do
      printf '    %d. %s\n' "$((i+1))" "${NEXT_STEPS[$i]}"
      print_command_list "${NEXT_COMMANDS[$i]}"
      printf '\n'
    done
  else
    printf '    1. Correlacionar cualquier síntoma con cambios recientes y logs del periodo afectado.\n'
    print_command_list $'journalctl --since "-30 min"\nsystemctl --failed\nsystemctl list-timers --all'
    printf '\n'
    printf '    2. Repetir las métricas relevantes durante el periodo exacto de lentitud si el problema es intermitente.\n'
    print_command_list $'uptime\nvmstat 1\niostat -xz 1\nps -eo pid,ppid,stat,%cpu,%mem,comm --sort=-%cpu'
  fi

  printf '\n  Importante: SYSdiag propone hipótesis; no sustituye la investigación del administrador.\n'
}

summary_status_for() {
  local score="${1:-0}" impact="${2:-0}"
  if (( impact >= 4 )); then
    echo "CRITICAL"
  elif (( score >= 4 || impact >= 3 )); then
    echo "WARNING"
  elif (( score >= 1 )); then
    echo "INFO"
  else
    echo "OK"
  fi
}

summary_category_is_limited() {
  case "$1" in
    io) [[ "${IOSTAT_AVAILABLE:-0}" != "1" || "${IOSTAT_DATA_VALID:-0}" != "1" ]] ;;
    filesystem) [[ "${FINDMNT_AVAILABLE:-0}" != "1" || "${LSOF_AVAILABLE:-0}" != "1" ]] ;;
    network) [[ "${NETWORK_AVAILABLE:-0}" != "1" || "${IP_AVAILABLE:-0}" != "1" || "${SS_AVAILABLE:-0}" != "1" ]] ;;
    logging) [[ "${JOURNALCTL_AVAILABLE:-0}" != "1" || "${JOURNAL_BOOT_QUERY_VALID:-0}" != "1" || "${JOURNALD_ACTIVE:-unknown}" == "unknown" || "${JOURNALD_ACTIVE:-n/d}" == "n/d" ]] ;;
    systemd) [[ "${SYSTEMCTL_AVAILABLE:-0}" != "1" || "${SYSTEMD_PID1:-0}" != "1" || "${SYSTEMD_ACCESS:-n/d}" != "disponible" || "${SYSTEMD_FAILED_QUERY_VALID:-0}" != "1" || "${SYSTEMD_MANAGER_JOURNAL_VALID:-0}" != "1" ]] ;;
    boot) [[ "${BOOT_COLLECTED:-0}" != "1" || "${BOOT_CONTEXT_REPRESENTATIVE:-0}" != "1" || "${BOOT_FSTAB_PRESENT:-0}" != "1" ]] ;;
    kubernetes) [[ "${K8S_ACCESS:-no disponible}" != "disponible" || "${K8S_CLI:-}" == "" ]] ;;
    containers)
      if [[ "${DOCKER_AVAILABLE:-0}" == "1" && "${DOCKER_REMOTE:-0}" != "1" && "${DOCKER_ACCESS:-n/d}" != "disponible" ]]; then return 0; fi
      if [[ "${PODMAN_AVAILABLE:-0}" == "1" && "${PODMAN_REMOTE:-0}" != "1" && "${PODMAN_ACCESS:-n/d}" != "disponible" ]]; then return 0; fi
      return 1 ;;
    *) return 1 ;;
  esac
}

summary_status_rank() {
  case "$1" in
    CRITICAL) echo 4 ;;
    WARNING) echo 3 ;;
    INFO) echo 2 ;;
    LIMITED) echo 1 ;;
    *) echo 0 ;;
  esac
}

summary_combined_status() {
  local best="OK" best_rank=0 cat status rank
  for cat in "$@"; do
    status="$(summary_status_for "${SCORE[$cat]:-0}" "${IMPACT[$cat]:-0}")"
    if [[ "$status" == "OK" ]] && summary_category_is_limited "$cat"; then status="LIMITED"; fi
    rank="$(summary_status_rank "$status")"
    if (( rank > best_rank )); then best="$status"; best_rank="$rank"; fi
  done
  echo "$best"
}

print_quick_summary_row() {
  local label="$1" command="$2"; shift 2
  local status
  status="$(summary_combined_status "$@")"
  printf '  %-22s %s' "$label" "$(status_label "$status")"
  [[ "$status" != "OK" ]] && printf '    → %s' "$command"
  printf '\n'
}

print_quick_summary() {
  section "RESUMEN GENERAL"
  printf '  Vista compacta. OK no demuestra ausencia de problemas; LIMITADO indica que faltó alguna comprobación relevante.\n\n'
  print_quick_summary_row "CPU y procesos" "menú opción 2" cpu processes
  print_quick_summary_row "Memoria" "--section memory --verbose" memory
  print_quick_summary_row "I/O y almacenamiento" "--section io --verbose" io
  print_quick_summary_row "Filesystems" "--section filesystem --verbose" filesystem
  print_quick_summary_row "Red" "--section network --verbose" network
  print_quick_summary_row "Logs / journald" "--section logging --verbose" logging
  print_quick_summary_row "Systemd / servicios" "--section systemd --verbose --explain" systemd
  print_quick_summary_row "Boot / arranque" "--section boot --verbose --explain" boot
  print_quick_summary_row "Contenedores" "--section containers --verbose --explain" containers
  print_quick_summary_row "Kubernetes / OpenShift" "--section kubernetes --k8s-mode deep --verbose --explain" kubernetes

  printf '\n  Findings observados: %s | Limitaciones adicionales: %s\n' "${#EVIDENCE[@]}" "${#LIMITATIONS[@]}"

  local best_cat="" best_score=-1 best_impact=-1 cat score impact
  for cat in cpu io memory processes filesystem network logging systemd boot containers kubernetes; do
    score=${SCORE[$cat]:-0}; impact=${IMPACT[$cat]:-0}
    if (( score > best_score || (score == best_score && impact > best_impact) )); then
      best_score=$score; best_impact=$impact; best_cat=$cat
    fi
  done

  if (( best_score > 0 )); then
    printf '\n  Prioridad actual:\n'
    kv "Área:" "$(category_title "$best_cat")"
    kv "Confianza:" "$(confidence_for_category "$best_cat")"
    kv "Impacto estimado:" "$(impact_label "${IMPACT[$best_cat]:-0}")"
    printf '\n  Para profundizar, ejecuta la sección indicada o usa el menú.\n'
  else
    printf '\n  No se han detectado señales fuertes con las comprobaciones disponibles.\n'
    printf '  Si una fila aparece LIMITADO, revisa esa sección antes de dar el área por sana.\n'
  fi
}
