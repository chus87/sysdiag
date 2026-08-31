# systemd / services diagnostics.
# Read-only: only status/show/list/journal queries are executed.

SYSTEMD_FAILED_DETAIL_LIMIT_DEFAULT=5
SYSTEMD_FAILED_DETAIL_LIMIT_VERBOSE=10
SYSTEMD_FAILED_LIST_PRINT_LIMIT_DEFAULT=20
SYSTEMD_RECENT_LOG_LIMIT_DEFAULT=8

_systemd_read_property() {
  local raw="$1" key="$2"
  awk -F= -v key="$key" '$1==key {sub(/^[^=]*=/,""); print; exit}' <<<"$raw"
}

_systemd_sanitize_value() {
  printf '%s\n' "$1" | sanitize_terminal_text | head -n 1
}

_systemd_sanitize_field() {
  _systemd_sanitize_value "$1" | sed 's/|/¦/g'
}

_systemd_pid1_name() {
  local proc_root="${SYSTEMD_PROC_ROOT:-/proc}"
  [[ -r "$proc_root/1/comm" ]] && tr -d '\n' <"$proc_root/1/comm" 2>/dev/null
}

collect_systemd_services() {
  SYSTEMCTL_AVAILABLE=0; SYSTEMD_PID1=0; SYSTEMD_PID1_NAME="unknown"; SYSTEMD_VERSION="n/d"
  SYSTEMD_SYSTEM_STATE="n/d"; SYSTEMD_DEFAULT_TARGET="n/d"; SYSTEMD_ACCESS="n/d"
  SYSTEMD_FAILED_UNITS_COUNT=0; SYSTEMD_FAILED_SERVICES_COUNT=0; SYSTEMD_TIMER_COUNT="n/d"
  SYSTEMD_FAILED_QUERY_VALID=0; SYSTEMD_TIMER_QUERY_VALID=0; SYSTEMD_MANAGER_JOURNAL_VALID=0
  SYSTEMD_START_LIMIT_HITS=0; SYSTEMD_RESTART_HINTS=0; SYSTEMD_DEPENDENCY_FAILURES=0; SYSTEMD_FAILED_START_LIMIT_RESULTS=0; SYSTEMD_HIGH_NRESTART_UNITS=0
  if [[ -z "${SYSTEMD_FAILED_DETAIL_LIMIT+x}" ]]; then
    if (( ${VERBOSE:-0} == 1 )); then SYSTEMD_FAILED_DETAIL_LIMIT="$SYSTEMD_FAILED_DETAIL_LIMIT_VERBOSE"; else SYSTEMD_FAILED_DETAIL_LIMIT="$SYSTEMD_FAILED_DETAIL_LIMIT_DEFAULT"; fi
  fi
  SYSTEMD_FAILED_LIST_PRINT_LIMIT="${SYSTEMD_FAILED_LIST_PRINT_LIMIT:-$SYSTEMD_FAILED_LIST_PRINT_LIMIT_DEFAULT}"
  SYSTEMD_RECENT_LOG_LIMIT="${SYSTEMD_RECENT_LOG_LIMIT:-$SYSTEMD_RECENT_LOG_LIMIT_DEFAULT}"
  [[ "$SYSTEMD_FAILED_DETAIL_LIMIT" =~ ^[0-9]+$ ]] && (( SYSTEMD_FAILED_DETAIL_LIMIT >= 1 && SYSTEMD_FAILED_DETAIL_LIMIT <= 50 )) || SYSTEMD_FAILED_DETAIL_LIMIT="$SYSTEMD_FAILED_DETAIL_LIMIT_DEFAULT"
  [[ "$SYSTEMD_FAILED_LIST_PRINT_LIMIT" =~ ^[0-9]+$ ]] && (( SYSTEMD_FAILED_LIST_PRINT_LIMIT >= 1 && SYSTEMD_FAILED_LIST_PRINT_LIMIT <= 200 )) || SYSTEMD_FAILED_LIST_PRINT_LIMIT="$SYSTEMD_FAILED_LIST_PRINT_LIMIT_DEFAULT"
  [[ "$SYSTEMD_RECENT_LOG_LIMIT" =~ ^[0-9]+$ ]] && (( SYSTEMD_RECENT_LOG_LIMIT >= 1 && SYSTEMD_RECENT_LOG_LIMIT <= 50 )) || SYSTEMD_RECENT_LOG_LIMIT="$SYSTEMD_RECENT_LOG_LIMIT_DEFAULT"
  SYSTEMD_MANAGER_RECENT=""
  SYSTEMD_FAILED_UNITS_LIST=(); SYSTEMD_FAILED_DETAILS=(); SYSTEMD_FAILED_LOGS=()

  SYSTEMD_PID1_NAME="$(_systemd_pid1_name || true)"; [[ -n "$SYSTEMD_PID1_NAME" ]] || SYSTEMD_PID1_NAME="unknown"
  [[ "$SYSTEMD_PID1_NAME" == systemd ]] && SYSTEMD_PID1=1

  if have_cmd systemctl; then
    SYSTEMCTL_AVAILABLE=1
    SYSTEMD_VERSION="$(run_with_timeout 3 env LC_ALL=C systemctl --version 2>/dev/null | head -n 1 || true)"
    SYSTEMD_VERSION="$(_systemd_sanitize_value "${SYSTEMD_VERSION:-n/d}")"
  else
    add_limitation "Systemctl no está disponible; análisis de systemd/servicios limitado."
    return 0
  fi

  if (( SYSTEMD_PID1 != 1 )); then
    add_limitation "PID 1 es '${SYSTEMD_PID1_NAME}', no systemd; se omiten consultas al system manager para evitar resultados engañosos."
    SYSTEMD_ACCESS="no aplicable"
    return 0
  fi

  local raw="" rc=0
  rc=0; raw="$(run_with_timeout 4 env LC_ALL=C systemctl is-system-running 2>/dev/null)" || rc=$?
  if (( rc == 124 )); then
    SYSTEMD_ACCESS="timeout"
    add_limitation "La consulta systemctl is-system-running superó 4s; se omiten más consultas al manager para no agravar la incidencia."
    return 0
  elif [[ -z "$raw" ]]; then
    SYSTEMD_ACCESS="inaccesible"
    add_limitation "Systemctl no pudo consultar el estado del system manager; se omiten consultas adicionales."
    return 0
  else
    SYSTEMD_SYSTEM_STATE="$(_systemd_sanitize_value "$raw")"
    SYSTEMD_ACCESS="disponible"
  fi

  rc=0; raw="$(run_with_timeout 4 env LC_ALL=C systemctl get-default 2>/dev/null)" || rc=$?
  if (( rc == 124 )); then
    add_limitation "La consulta systemctl get-default superó 4s."
  elif [[ -n "$raw" ]]; then
    SYSTEMD_DEFAULT_TARGET="$(_systemd_sanitize_value "$raw")"
  fi

  rc=0; raw="$(run_with_timeout 5 env LC_ALL=C systemctl --failed --no-legend --plain --no-pager 2>/dev/null)" || rc=$?
  if (( rc == 124 )); then
    add_limitation "La consulta systemctl --failed superó 5s; unidades fallidas no determinadas."
  elif (( rc != 0 )); then
    add_limitation "La consulta systemctl --failed no pudo completarse; no se asume que haya 0 unidades fallidas."
  else
    SYSTEMD_FAILED_QUERY_VALID=1
    while IFS= read -r line; do
      [[ -n "${line//[[:space:]]/}" ]] || continue
      local unit
      unit="$(awk '{print $1}' <<<"$line")"
      [[ -n "$unit" ]] || continue
      SYSTEMD_FAILED_UNITS_LIST+=("$unit")
      ((SYSTEMD_FAILED_UNITS_COUNT+=1))
      [[ "$unit" == *.service ]] && ((SYSTEMD_FAILED_SERVICES_COUNT+=1))
    done <<<"$raw"
  fi

  rc=0; raw="$(run_with_timeout 5 env LC_ALL=C systemctl list-timers --all --no-legend --plain --no-pager 2>/dev/null)" || rc=$?
  if (( rc == 124 )); then
    add_limitation "La consulta systemctl list-timers superó 5s; timers no contabilizados."
  elif (( rc != 0 )); then
    add_limitation "La consulta systemctl list-timers no pudo completarse; timers no contabilizados."
  else
    SYSTEMD_TIMER_QUERY_VALID=1
    SYSTEMD_TIMER_COUNT="$(printf '%s\n' "$raw" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  fi

  # Bounded manager journal: only recent PID 1 messages, useful for start-limit
  # and dependency failures. Failure to read it is a limitation, never a finding.
  if have_cmd journalctl; then
    rc=0; raw="$(run_with_timeout 5 journalctl -b _PID=1 --since '-1 hour' -n 250 --no-pager -o cat 2>/dev/null)" || rc=$?
    if (( rc == 124 )); then
      add_limitation "La consulta journalctl de systemd (última hora) superó 5s."
    elif (( rc != 0 )); then
      add_limitation "Journalctl no pudo consultar los eventos recientes de PID 1; análisis de restart/dependencias limitado."
    else
      SYSTEMD_MANAGER_JOURNAL_VALID=1
      SYSTEMD_MANAGER_RECENT="$(printf '%s\n' "$raw" | sanitize_terminal_text | sed '/^[[:space:]]*$/d; /^-- No entries --$/d')"
      SYSTEMD_START_LIMIT_HITS="$(grep -Eic 'start request repeated too quickly|start-limit-hit|start limit hit' <<<"$SYSTEMD_MANAGER_RECENT" || true)"
      SYSTEMD_RESTART_HINTS="$(grep -Eic 'scheduled restart job|restart counter is at|restarting' <<<"$SYSTEMD_MANAGER_RECENT" || true)"
      SYSTEMD_DEPENDENCY_FAILURES="$(grep -Eic 'dependency failed for|dependency failed' <<<"$SYSTEMD_MANAGER_RECENT" || true)"
    fi
  else
    add_limitation "Journalctl no está disponible; no se puede correlacionar systemd con eventos recientes."
  fi

  # Inspect only a bounded number of failed units. systemctl show is metadata,
  # not an active operation. Journal excerpts are also bounded and sanitized.
  local idx=0 unit props logs id description load active sub unitfile result mainpid code status restart nrestarts fragment
  for unit in "${SYSTEMD_FAILED_UNITS_LIST[@]}"; do
    (( idx >= SYSTEMD_FAILED_DETAIL_LIMIT )) && break
    rc=0; props="$(run_with_timeout 4 env LC_ALL=C systemctl show --no-pager \
      -p Id -p Description -p LoadState -p ActiveState -p SubState -p UnitFileState \
      -p Result -p MainPID -p ExecMainCode -p ExecMainStatus -p Restart -p NRestarts -p FragmentPath -- "$unit" 2>/dev/null)" || rc=$?
    if (( rc == 124 )); then
      add_limitation "La consulta systemctl show $unit superó 4s; detalle omitido."
      continue
    elif (( rc != 0 )); then
      add_limitation "La consulta systemctl show $unit no pudo completarse; detalle omitido."
      continue
    fi
    id="$(_systemd_read_property "$props" Id)"; [[ -n "$id" ]] || id="$unit"
    description="$(_systemd_read_property "$props" Description)"
    load="$(_systemd_read_property "$props" LoadState)"; active="$(_systemd_read_property "$props" ActiveState)"; sub="$(_systemd_read_property "$props" SubState)"
    unitfile="$(_systemd_read_property "$props" UnitFileState)"; result="$(_systemd_read_property "$props" Result)"; mainpid="$(_systemd_read_property "$props" MainPID)"
    code="$(_systemd_read_property "$props" ExecMainCode)"; status="$(_systemd_read_property "$props" ExecMainStatus)"; restart="$(_systemd_read_property "$props" Restart)"
    nrestarts="$(_systemd_read_property "$props" NRestarts)"; fragment="$(_systemd_read_property "$props" FragmentPath)"

    description="$(_systemd_sanitize_field "$description")"; fragment="$(_systemd_sanitize_field "$fragment")"
    SYSTEMD_FAILED_DETAILS+=("${id}|${description}|${load:-n/d}|${active:-n/d}|${sub:-n/d}|${unitfile:-n/d}|${result:-n/d}|${mainpid:-0}|${code:-n/d}|${status:-n/d}|${restart:-n/d}|${nrestarts:-0}|${fragment:-n/d}")
    [[ "$result" == "start-limit-hit" ]] && ((SYSTEMD_FAILED_START_LIMIT_RESULTS+=1))
    if [[ "$nrestarts" =~ ^[0-9]+$ ]] && (( nrestarts >= 3 )); then ((SYSTEMD_HIGH_NRESTART_UNITS+=1)); fi

    logs=""
    if (( ${VERBOSE:-0} == 1 )) && have_cmd journalctl; then
      rc=0; logs="$(run_with_timeout 4 journalctl -b -u "$unit" --since '-1 hour' -n "$SYSTEMD_RECENT_LOG_LIMIT" --no-pager -o short-iso 2>/dev/null)" || rc=$?
      if (( rc == 124 )); then
        add_limitation "La consulta journalctl -u $unit superó 4s; extracto reciente omitido."
        logs=""
      elif (( rc != 0 )); then
        add_limitation "La consulta journalctl -u $unit no pudo completarse; extracto reciente omitido."
        logs=""
      else
        logs="$(printf '%s\n' "$logs" | sanitize_terminal_text | sed '/^[[:space:]]*$/d; /^-- No entries --$/d')"
      fi
    fi
    SYSTEMD_FAILED_LOGS+=("$logs")
    ((idx+=1))
  done

  (( SYSTEMD_FAILED_UNITS_COUNT > SYSTEMD_FAILED_DETAIL_LIMIT )) && \
    add_limitation "Hay $SYSTEMD_FAILED_UNITS_COUNT unidades fallidas; el detalle automático se limita a las primeras $SYSTEMD_FAILED_DETAIL_LIMIT."
  return 0
}

analyze_systemd_services() {
  if (( SYSTEMCTL_AVAILABLE != 1 )); then
    add_next_step \
      "Confirmar qué init/service manager gestiona el host antes de aplicar comandos de systemd." \
      "ps -p 1 -o pid,comm,args" \
      "cat /proc/1/comm"
    return 0
  fi

  if (( SYSTEMD_PID1 != 1 )); then
    add_next_step \
      "Este entorno no usa systemd como PID 1; identificar el supervisor real antes de interpretar systemctl." \
      "ps -p 1 -o pid,comm,args" \
      "cat /proc/1/comm"
    return 0
  fi

  if [[ "${SYSTEMD_ACCESS:-n/d}" != "disponible" ]]; then
    add_next_step \
      "El system manager no respondió de forma fiable; evitar repetir consultas agresivamente y revisar PID 1/journal local." \
      "ps -p 1 -o pid,comm,args" \
      "journalctl -b _PID=1 -n 100 --no-pager"
    return 0
  fi

  case "${SYSTEMD_SYSTEM_STATE:-unknown}" in
    maintenance|emergency)
      add_finding "SYSTEMD_SYSTEM_STATE" systemd manager_state 3 high \
        "El system manager informa estado '${SYSTEMD_SYSTEM_STATE}'; confirmar si es intencional y qué unidad/objetivo lo provoca."
      add_next_step \
        "Revisar el estado global y las unidades que impiden alcanzar el objetivo normal." \
        "systemctl is-system-running" \
        "systemctl --failed --no-pager" \
        "journalctl -b _PID=1 --no-pager"
      ;;
  esac

  if (( SYSTEMD_FAILED_UNITS_COUNT > 0 )); then
    add_finding "SYSTEMD_FAILED_UNITS" systemd unit_state 3 medium \
      "systemd mantiene ${SYSTEMD_FAILED_UNITS_COUNT} unidad(es) en estado failed (${SYSTEMD_FAILED_SERVICES_COUNT} service)."
    add_next_step \
      "Priorizar las unidades failed por impacto y reconstruir el primer fallo antes de reiniciarlas." \
      "systemctl --failed --no-pager" \
      "systemctl status <unidad> --no-pager -l" \
      "systemctl cat <unidad>" \
      "journalctl -b -u <unidad> --since \"-1 hour\" --no-pager"
  fi

  if (( SYSTEMD_START_LIMIT_HITS > 0 || SYSTEMD_FAILED_START_LIMIT_RESULTS > 0 )); then
    add_finding "SYSTEMD_START_LIMIT" systemd restart_control 4 high \
      "Hay evidencia de start-limit/reintentos demasiado rápidos (journal=${SYSTEMD_START_LIMIT_HITS}, unidades failed con Result=start-limit-hit=${SYSTEMD_FAILED_START_LIMIT_RESULTS})."
    add_next_step \
      "Buscar el primer error que precede al start-limit; el límite de reinicios suele ser consecuencia, no causa." \
      "journalctl -b _PID=1 --since \"-1 hour\" --no-pager" \
      "systemctl show <unidad> -p Result -p Restart -p NRestarts -p ExecMainCode -p ExecMainStatus" \
      "journalctl -b -u <unidad> --since \"-1 hour\" --no-pager"
  elif (( SYSTEMD_RESTART_HINTS >= 3 || SYSTEMD_HIGH_NRESTART_UNITS > 0 )); then
    add_finding "SYSTEMD_RESTART_LOOP_HINT" systemd restart_history 2 medium \
      "Hay indicios de reinicios repetidos (mensajes recientes=${SYSTEMD_RESTART_HINTS}, unidades failed con NRestarts>=3=${SYSTEMD_HIGH_NRESTART_UNITS}); confirmar la causa del primer fallo."
    add_next_step \
      "Identificar qué unidad se reinicia y por qué termina antes de asumir un fallo de systemd." \
      "journalctl -b _PID=1 --since \"-1 hour\" --no-pager" \
      "systemctl show <unidad> -p Restart -p NRestarts -p Result"
  fi

  if (( SYSTEMD_DEPENDENCY_FAILURES > 0 )); then
    add_finding "SYSTEMD_DEPENDENCY_FAILURE" systemd dependencies 2 medium \
      "systemd registró ${SYSTEMD_DEPENDENCY_FAILURES} fallo(s) reciente(s) de dependencia."
    add_next_step \
      "Distinguir dependencia de orden y localizar la unidad que realmente falló aguas arriba." \
      "systemctl list-dependencies --all <unidad>" \
      "systemctl cat <unidad>" \
      "journalctl -b -u <unidad> --since \"-1 hour\" --no-pager"
  fi

  return 0
}

print_systemd_services() {
  section "SYSTEMD / SERVICIOS"
  kv "PID 1:" "${SYSTEMD_PID1_NAME:-unknown}"
  kv "Disponibilidad de systemctl:" "$([[ ${SYSTEMCTL_AVAILABLE:-0} == 1 ]] && echo sí || echo no)"
  [[ -n "${SYSTEMD_VERSION:-}" && "${SYSTEMD_VERSION:-n/d}" != "n/d" ]] && kv "Versión:" "$SYSTEMD_VERSION"

  if (( ${SYSTEMD_PID1:-0} != 1 )); then
    note "PID 1 no es systemd; no se presentan estados del system manager como si fueran válidos."
    return 0
  fi

  kv "Estado del sistema:" "${SYSTEMD_SYSTEM_STATE:-n/d}"
  kv "Target por defecto:" "${SYSTEMD_DEFAULT_TARGET:-n/d}"
  if (( ${SYSTEMD_FAILED_QUERY_VALID:-0} == 1 )); then
    kv "Unidades failed:" "${SYSTEMD_FAILED_UNITS_COUNT:-0}"
    kv "Services failed:" "${SYSTEMD_FAILED_SERVICES_COUNT:-0}"
  else
    kv "Unidades failed:" "n/d (consulta limitada)"
    kv "Services failed:" "n/d"
  fi
  kv "Timers conocidos:" "${SYSTEMD_TIMER_COUNT:-n/d}"
  kv "Start-limit última hora:" "${SYSTEMD_START_LIMIT_HITS:-0}"
  kv "Failed con start-limit-hit:" "${SYSTEMD_FAILED_START_LIMIT_RESULTS:-0}"
  kv "Indicios de restart última hora:" "${SYSTEMD_RESTART_HINTS:-0}"
  kv "Failed con NRestarts>=3:" "${SYSTEMD_HIGH_NRESTART_UNITS:-0}"
  kv "Fallos de dependencia última hora:" "${SYSTEMD_DEPENDENCY_FAILURES:-0}"

  if ((${#SYSTEMD_FAILED_UNITS_LIST[@]})); then
    subsection "UNIDADES FALLIDAS"
    local unit shown=0
    for unit in "${SYSTEMD_FAILED_UNITS_LIST[@]}"; do
      (( shown >= SYSTEMD_FAILED_LIST_PRINT_LIMIT )) && break
      printf '    - %s\n' "$unit"; ((shown+=1))
    done
    (( SYSTEMD_FAILED_UNITS_COUNT > SYSTEMD_FAILED_LIST_PRINT_LIMIT )) &&       printf '    ... %s unidad(es) adicional(es) no mostradas.\n' "$((SYSTEMD_FAILED_UNITS_COUNT-SYSTEMD_FAILED_LIST_PRINT_LIMIT))"
  fi

  if ((${#SYSTEMD_FAILED_DETAILS[@]})); then
    subsection "DETALLE ACOTADO"
    local i row id description load active sub unitfile result mainpid code status restart nrestarts fragment logs
    for ((i=0; i<${#SYSTEMD_FAILED_DETAILS[@]}; i++)); do
      row="${SYSTEMD_FAILED_DETAILS[$i]}"
      IFS='|' read -r id description load active sub unitfile result mainpid code status restart nrestarts fragment <<<"$row"
      printf '    %s%s%s\n' "$C_BOLD" "$id" "$C_RESET"
      [[ -n "$description" ]] && printf '      Descripción:       %s\n' "$description"
      printf '      Estado:            %s/%s\n' "$active" "$sub"
      printf '      Load state:        %s\n' "$load"
      printf '      Unit file:         %s\n' "$unitfile"
      printf '      Resultado:         %s\n' "$result"
      printf '      MainPID:           %s\n' "$mainpid"
      printf '      Exec code/status:  %s / %s\n' "$code" "$status"
      printf '      Restart/NRestarts: %s / %s\n' "$restart" "$nrestarts"
      printf '      Unidad efectiva:   %s\n' "$fragment"
      logs="${SYSTEMD_FAILED_LOGS[$i]:-}"
      if (( ${VERBOSE:-0} == 1 )) && [[ -n "$logs" ]]; then
        printf '      Journal reciente:\n'
        while IFS= read -r line; do printf '        %s\n' "$line"; done <<<"$logs"
      fi
      printf '\n'
    done
  fi

  if (( ${EXPLAIN:-0} == 1 )); then
    subsection "CÓMO INTERPRETARLO"
    printf '    - loaded no significa running; solo que systemd conoce/cargó la unit.\n'
    printf '    - active (running) no garantiza readiness funcional de la aplicación.\n'
    printf '    - After=/Before= expresan orden; Wants=/Requires= expresan dependencias.\n'
    printf '    - Start request repeated too quickly suele ser la consecuencia de fallos repetidos.\n'
    printf '    - Un exit status describe cómo terminó el proceso; hay que buscar el primer error que lo provocó.\n'
  fi
}
