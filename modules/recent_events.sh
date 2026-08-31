# Recent warning/error triage from journald and dmesg.
# Generic log severity is evidence only: it never becomes a finding by itself.

_recent_sanitize() {
  sanitize_terminal_text
}
_recent_count_lines() {
  sed '/^[[:space:]]*$/d; /^-- No entries --$/d' | wc -l | tr -d ' '
}

_recent_limit_text() {
  local raw="$1" limit="$2"
  printf '%s\n' "$raw" | sed '/^[[:space:]]*$/d; /^-- No entries --$/d' | tail -n "$limit"
}

_recent_capture_journal() {
  local range="$1" out_var="$2" count_var="$3" truncated_var="$4"
  local raw="" rc=0 total=0 request_limit=$((RECENT_EVENT_LIMIT+1))
  raw="$(run_with_timeout 6 journalctl --since "-${RECENT_MINUTES} min" -p "$range" -n "$request_limit" --no-pager -q -o short-iso-precise 2>/dev/null)" || rc=$?
  if (( rc == 124 )); then
    RECENT_LIMITATIONS+=("journalctl superó 6s al consultar prioridad ${range}; esa lista se omite.")
    printf -v "$out_var" '%s' ""
    printf -v "$count_var" '%s' "0"
    printf -v "$truncated_var" '%s' "0"
    return 0
  elif (( rc != 0 )); then
    RECENT_LIMITATIONS+=("journalctl no pudo consultar prioridad ${range}; revisa permisos/compatibilidad.")
    printf -v "$out_var" '%s' ""
    printf -v "$count_var" '%s' "0"
    printf -v "$truncated_var" '%s' "0"
    return 0
  fi

  raw="$(printf '%s\n' "$raw" | _recent_sanitize | sed '/^[[:space:]]*$/d; /^-- No entries --$/d')"
  total="$(printf '%s\n' "$raw" | _recent_count_lines)"
  if (( total > RECENT_EVENT_LIMIT )); then
    printf -v "$truncated_var" '%s' "1"
  else
    printf -v "$truncated_var" '%s' "0"
  fi
  printf -v "$out_var" '%s' "$(_recent_limit_text "$raw" "$RECENT_EVENT_LIMIT")"
  if (( total > RECENT_EVENT_LIMIT )); then total=$RECENT_EVENT_LIMIT; fi
  printf -v "$count_var" '%s' "$total"
}

_recent_journal_kernel_messages() {
  local raw="" rc=0
  raw="$(run_with_timeout 5 journalctl -k --since "-${RECENT_MINUTES} min" -p 0..4 -n 200 --no-pager -q -o cat 2>/dev/null)" || rc=$?
  (( rc == 0 )) || return 0
  printf '%s\n' "$raw" | _recent_sanitize | sed '/^[[:space:]]*$/d; /^-- No entries --$/d'
}

_recent_dmesg_supported() {
  local help=""
  help="$(run_with_timeout 2 dmesg --help 2>&1 || true)"
  grep -q -- '--since' <<<"$help" && grep -q -- '--level' <<<"$help" && grep -q -- '--time-format' <<<"$help" && grep -q -- '--notime' <<<"$help"
}

_recent_capture_dmesg_level() {
  local levels="$1" out_var="$2" count_var="$3" truncated_var="$4"
  local shown="" plain="" rc=0 i msg display total=0 dedup=0
  local -a shown_lines=() plain_lines=() kept=()

  shown="$(run_with_timeout 5 dmesg --since "${RECENT_MINUTES} minutes ago" --level="$levels" --time-format iso 2>/dev/null)" || rc=$?
  if (( rc == 124 )); then
    RECENT_LIMITATIONS+=("dmesg superó 5s al consultar niveles ${levels}; esa lista se omite.")
    printf -v "$out_var" '%s' ""; printf -v "$count_var" '%s' "0"; printf -v "$truncated_var" '%s' "0"
    return 0
  elif (( rc != 0 )); then
    RECENT_DMESG_READABLE=0
    RECENT_LIMITATIONS+=("dmesg no es legible con los permisos actuales o rechazó la consulta temporal.")
    printf -v "$out_var" '%s' ""; printf -v "$count_var" '%s' "0"; printf -v "$truncated_var" '%s' "0"
    return 0
  fi

  plain="$(run_with_timeout 5 dmesg --since "${RECENT_MINUTES} minutes ago" --level="$levels" --notime 2>/dev/null || true)"
  shown="$(printf '%s\n' "$shown" | _recent_sanitize | sed '/^[[:space:]]*$/d')"
  plain="$(printf '%s\n' "$plain" | _recent_sanitize | sed '/^[[:space:]]*$/d')"
  mapfile -t shown_lines <<<"$shown"
  mapfile -t plain_lines <<<"$plain"

  for ((i=0; i<${#shown_lines[@]}; i++)); do
    display="${shown_lines[$i]}"
    msg="${plain_lines[$i]:-${shown_lines[$i]}}"
    [[ -n "$display" ]] || continue
    if [[ -n "$RECENT_JOURNAL_KERNEL_MESSAGES" ]] && grep -Fqx -- "$msg" <<<"$RECENT_JOURNAL_KERNEL_MESSAGES"; then
      ((dedup++)) || true
      continue
    fi
    kept+=("$display")
  done

  RECENT_DMESG_DEDUP_COUNT=$((RECENT_DMESG_DEDUP_COUNT+dedup))
  total=${#kept[@]}
  if (( total > RECENT_EVENT_LIMIT )); then
    printf -v "$truncated_var" '%s' "1"
    kept=("${kept[@]:total-RECENT_EVENT_LIMIT:RECENT_EVENT_LIMIT}")
    total=$RECENT_EVENT_LIMIT
  else
    printf -v "$truncated_var" '%s' "0"
  fi
  printf -v "$out_var" '%s' "$(printf '%s\n' "${kept[@]}")"
  printf -v "$count_var" '%s' "$total"
}

collect_recent_events() {
  RECENT_JOURNAL_AVAILABLE=0; RECENT_DMESG_AVAILABLE=0; RECENT_DMESG_READABLE=1
  RECENT_JOURNAL_ERRORS=""; RECENT_JOURNAL_WARNINGS=""
  RECENT_JOURNAL_ERROR_COUNT=0; RECENT_JOURNAL_WARNING_COUNT=0
  RECENT_JOURNAL_ERRORS_TRUNCATED=0; RECENT_JOURNAL_WARNINGS_TRUNCATED=0
  RECENT_JOURNAL_KERNEL_MESSAGES=""
  RECENT_DMESG_ERRORS=""; RECENT_DMESG_WARNINGS=""
  RECENT_DMESG_ERROR_COUNT=0; RECENT_DMESG_WARNING_COUNT=0
  RECENT_DMESG_ERRORS_TRUNCATED=0; RECENT_DMESG_WARNINGS_TRUNCATED=0
  RECENT_DMESG_DEDUP_COUNT=0; RECENT_DMESG_MODE="no disponible"
  RECENT_LIMITATIONS=()

  if have_cmd journalctl; then
    RECENT_JOURNAL_AVAILABLE=1
    # 0..3 = emerg/alert/crit/err; 4..4 = warning only.
    _recent_capture_journal '0..3' RECENT_JOURNAL_ERRORS RECENT_JOURNAL_ERROR_COUNT RECENT_JOURNAL_ERRORS_TRUNCATED
    _recent_capture_journal '4..4' RECENT_JOURNAL_WARNINGS RECENT_JOURNAL_WARNING_COUNT RECENT_JOURNAL_WARNINGS_TRUNCATED
    RECENT_JOURNAL_KERNEL_MESSAGES="$(_recent_journal_kernel_messages)"
  else
    RECENT_LIMITATIONS+=("journalctl no está disponible; la vista se limita a dmesg si puede consultarse.")
  fi

  if have_cmd dmesg; then
    RECENT_DMESG_AVAILABLE=1
    if _recent_dmesg_supported; then
      RECENT_DMESG_MODE="ventana temporal nativa"
      _recent_capture_dmesg_level 'emerg,alert,crit,err' RECENT_DMESG_ERRORS RECENT_DMESG_ERROR_COUNT RECENT_DMESG_ERRORS_TRUNCATED
      if (( RECENT_DMESG_READABLE )); then
        _recent_capture_dmesg_level 'warn' RECENT_DMESG_WARNINGS RECENT_DMESG_WARNING_COUNT RECENT_DMESG_WARNINGS_TRUNCATED
      fi
    else
      RECENT_DMESG_MODE="omitido: util-linux sin filtros temporales requeridos"
      RECENT_LIMITATIONS+=("dmesg no soporta los filtros temporales necesarios; SYSdiag evita volcar un ring buffer completo sin acotar.")
    fi
  else
    RECENT_LIMITATIONS+=("Dmesg no está disponible.")
  fi
}

_recent_print_block() {
  local title="$1" text="$2" count="$3" truncated="$4"
  subsection "$title"
  if [[ -n "$text" ]]; then
    while IFS= read -r line; do [[ -n "$line" ]] && printf '    %s\n' "$line"; done <<<"$text"
    if (( truncated )); then
      note "Se muestran solo los ${RECENT_EVENT_LIMIT} eventos más recientes de esta categoría; hay más dentro de la ventana."
    else
      printf '    (%s eventos mostrados)\n' "$count"
    fi
  else
    printf '    Sin eventos visibles en esta categoría durante la ventana consultada.\n'
  fi
}

print_recent_events() {
  section "WARNINGS Y ERRORES RECIENTES"
  kv "Ventana analizada:" "últimos ${RECENT_MINUTES} minutos"
  kv "Límite por categoría:" "${RECENT_EVENT_LIMIT} eventos más recientes"
  printf '\n  Esta vista sirve para triaje. ERROR/WARNING indica prioridad del productor del log; no demuestra causalidad.\n'

  if (( RECENT_JOURNAL_AVAILABLE )); then
    _recent_print_block "JOURNAL — ERROR / CRITICAL" "$RECENT_JOURNAL_ERRORS" "$RECENT_JOURNAL_ERROR_COUNT" "$RECENT_JOURNAL_ERRORS_TRUNCATED"
    _recent_print_block "JOURNAL — WARNING" "$RECENT_JOURNAL_WARNINGS" "$RECENT_JOURNAL_WARNING_COUNT" "$RECENT_JOURNAL_WARNINGS_TRUNCATED"
  else
    subsection "JOURNAL"
    warn "Journalctl no está disponible."
  fi

  subsection "DMESG — EVENTOS ADICIONALES"
  kv_at 4 34 "Modo:" "$RECENT_DMESG_MODE"
  kv_at 4 34 "Duplicados ya vistos en journal:" "$RECENT_DMESG_DEDUP_COUNT"
  if (( RECENT_DMESG_AVAILABLE == 0 )); then
    warn "Dmesg no está disponible."
  elif (( RECENT_DMESG_READABLE == 0 )); then
    warn "Dmesg no puede leerse con los permisos actuales; no se eleva privilegio automáticamente."
  elif [[ "$RECENT_DMESG_MODE" == omitido:* ]]; then
    note "$RECENT_DMESG_MODE"
  else
    printf '\n    ERROR/CRITICAL adicionales:\n'
    if [[ -n "$RECENT_DMESG_ERRORS" ]]; then sed 's/^/      /' <<<"$RECENT_DMESG_ERRORS"; else printf '      Ninguno no duplicado.\n'; fi
    (( RECENT_DMESG_ERRORS_TRUNCATED )) && note "Lista dmesg ERROR/CRITICAL truncada a ${RECENT_EVENT_LIMIT}."
    printf '\n    WARNING adicionales:\n'
    if [[ -n "$RECENT_DMESG_WARNINGS" ]]; then sed 's/^/      /' <<<"$RECENT_DMESG_WARNINGS"; else printf '      Ninguno no duplicado.\n'; fi
    (( RECENT_DMESG_WARNINGS_TRUNCATED )) && note "Lista dmesg WARNING truncada a ${RECENT_EVENT_LIMIT}."
  fi

  if ((${#RECENT_LIMITATIONS[@]})); then
    subsection "Limitaciones de esta consulta"
    local l
    for l in "${RECENT_LIMITATIONS[@]}"; do printf '    - %s\n' "$l"; done
  fi

  subsection "Comandos para ampliar la investigación"
  printf '    Journal completo de la ventana:\n      $ journalctl --since "-1 hour" --no-pager\n'
  printf '    Solo ERROR o más grave:\n      $ journalctl --since "-1 hour" -p err --no-pager\n'
  printf '    Kernel:\n      $ journalctl -k --since "-1 hour" -p warning --no-pager\n'
  printf '    Seguir un servicio en vivo:\n      $ journalctl -u <servicio> -f\n'

  printf '\n  Importante: SYSdiag no convierte automáticamente estas líneas en findings. Correlación temporal y semántica deben confirmar la hipótesis.\n'
}
