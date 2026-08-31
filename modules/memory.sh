meminfo_kb() { awk -v key="$1" '$1==key":"{print $2;exit}' /proc/meminfo 2>/dev/null; }

collect_oom_events() {
  OOM_EVENTS=""; OOM_SOURCE="no disponible"; OOM_EVENTS_COUNT=0
  OOM_LAST_AGE_SEC=-1; OOM_RECENCY="no detectado"
  local pattern='Out of memory|Killed process [0-9]+|oom-kill|Memory cgroup out of memory'
  local raw rc=0 now latest

  if have_cmd journalctl; then
    raw="$(run_with_timeout 6 journalctl -k --since '-24 hours' --no-pager -o short-unix 2>/dev/null)" || rc=$?
    if (( rc == 124 )); then
      add_limitation "La consulta journalctl -k no respondió en 6s; análisis OOM incompleto."
    else
      OOM_EVENTS="$(grep -Ei "$pattern" <<<"$raw" | tail -n 20 || true)"
      if [[ -n "$OOM_EVENTS" ]]; then
        OOM_SOURCE="journalctl -k (últimas 24 h)"
        latest="$(awk 'NF{v=$1} END{sub(/\..*/,"",v);print v+0}' <<<"$OOM_EVENTS")"
        now="$(date +%s 2>/dev/null || echo 0)"
        if (( latest > 0 && now >= latest )); then OOM_LAST_AGE_SEC=$((now-latest)); fi
      fi
    fi
  fi

  if [[ -z "$OOM_EVENTS" ]] && have_cmd dmesg; then
    rc=0
    raw="$(run_with_timeout 5 dmesg 2>/dev/null)" || rc=$?
    if (( rc == 124 )); then
      add_limitation "La consulta dmesg no respondió en 5s; análisis OOM incompleto."
    else
      OOM_EVENTS="$(grep -Ei "$pattern" <<<"$raw" | tail -n 20 || true)"
      [[ -n "$OOM_EVENTS" ]] && OOM_SOURCE="dmesg (desde el arranque; antigüedad no determinada)"
    fi
  fi

  if [[ -n "$OOM_EVENTS" ]]; then
    OOM_EVENTS_COUNT="$(printf '%s\n' "$OOM_EVENTS" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
    if (( OOM_LAST_AGE_SEC >= 0 && OOM_LAST_AGE_SEC <= 900 )); then OOM_RECENCY="<=15 min"
    elif (( OOM_LAST_AGE_SEC >= 0 && OOM_LAST_AGE_SEC <= 7200 )); then OOM_RECENCY="<=2 h"
    elif (( OOM_LAST_AGE_SEC >= 0 )); then OOM_RECENCY="<=24 h (histórico)"
    else OOM_RECENCY="antigüedad desconocida"; fi
  fi
}

collect_memory() {
  MEM_TOTAL_KB="$(meminfo_kb MemTotal)"; MEM_FREE_KB="$(meminfo_kb MemFree)"; MEM_AVAIL_KB="$(meminfo_kb MemAvailable)"
  MEM_CACHED_KB="$(meminfo_kb Cached)"; MEM_BUFFERS_KB="$(meminfo_kb Buffers)"
  SWAP_TOTAL_KB="$(meminfo_kb SwapTotal)"; SWAP_FREE_KB="$(meminfo_kb SwapFree)"; SWAP_CACHED_KB="$(meminfo_kb SwapCached)"
  MEM_TOTAL_KB=${MEM_TOTAL_KB:-0}; MEM_FREE_KB=${MEM_FREE_KB:-0}; MEM_CACHED_KB=${MEM_CACHED_KB:-0}; MEM_BUFFERS_KB=${MEM_BUFFERS_KB:-0}
  SWAP_TOTAL_KB=${SWAP_TOTAL_KB:-0}; SWAP_FREE_KB=${SWAP_FREE_KB:-0}; SWAP_CACHED_KB=${SWAP_CACHED_KB:-0}

  MEM_AVAIL_ESTIMATED=0
  if [[ -z "${MEM_AVAIL_KB:-}" ]]; then
    MEM_AVAIL_KB=$((MEM_FREE_KB+MEM_CACHED_KB+MEM_BUFFERS_KB)); MEM_AVAIL_ESTIMATED=1
  fi
  MEM_AVAIL_PCT="$(awk -v a="$MEM_AVAIL_KB" -v t="$MEM_TOTAL_KB" 'BEGIN{if(t>0)printf "%.2f",100*a/t;else print 0}')"
  MEM_FREE_PCT="$(awk -v a="$MEM_FREE_KB" -v t="$MEM_TOTAL_KB" 'BEGIN{if(t>0)printf "%.2f",100*a/t;else print 0}')"

  SWAP_USED_KB=$((SWAP_TOTAL_KB-SWAP_FREE_KB)); ((SWAP_USED_KB<0)) && SWAP_USED_KB=0
  SWAP_USED_PCT="$(awk -v u="$SWAP_USED_KB" -v t="$SWAP_TOTAL_KB" 'BEGIN{if(t>0)printf "%.2f",100*u/t;else print 0}')"

  ensure_shared_sample 0
  local pin1 pout1 pin2 pout2 page_bytes page_kb
  read -r pin1 pout1 <<<"${SAMPLE_SWAP_A:-0 0}"; read -r pin2 pout2 <<<"${SAMPLE_SWAP_B:-0 0}"
  page_bytes="$(getconf PAGESIZE 2>/dev/null || echo 4096)"; [[ "$page_bytes" =~ ^[0-9]+$ ]] || page_bytes=4096
  page_kb=$((page_bytes/1024)); ((page_kb<1)) && page_kb=4
  local seconds=${SAMPLE_SECONDS:-1}; ((seconds<1)) && seconds=1
  SWAP_IN_PAGES_S=$(( $(count_delta "$pin1" "$pin2") / seconds ))
  SWAP_OUT_PAGES_S=$(( $(count_delta "$pout1" "$pout2") / seconds ))
  SWAP_IN_KBPS=$((SWAP_IN_PAGES_S*page_kb)); SWAP_OUT_KBPS=$((SWAP_OUT_PAGES_S*page_kb)); SWAP_IO_KBPS=$((SWAP_IN_KBPS+SWAP_OUT_KBPS))

  TOP_MEMORY_PROCS="$(ps -eo pid=,ppid=,user=,rss=,%mem=,comm= --sort=-rss 2>/dev/null | head -n 10)"
  collect_oom_events
}

analyze_memory() {
  if num_lt "$MEM_AVAIL_PCT" 5; then
    add_finding MEM_AVAILABLE_LOW memory available 5 high "MemAvailable por debajo del 5% ($(fmt_pct "$MEM_AVAIL_PCT")): reserva muy reducida."
    add_next_step "Comprobar tendencia de MemAvailable y qué procesos concentran RSS; no asumir que 'free' bajo sea la causa." \
      "watch -n 2 free -h" "ps -eo pid,ppid,user,rss,%mem,comm --sort=-rss | head -n 20" "vmstat 1"
  elif num_lt "$MEM_AVAIL_PCT" 10; then
    add_finding MEM_AVAILABLE_LOW memory available 4 medium "MemAvailable por debajo del 10% ($(fmt_pct "$MEM_AVAIL_PCT"))."
    add_next_step "Investigar qué procesos consumen memoria y si MemAvailable continúa descendiendo." \
      "free -h" "ps -eo pid,ppid,user,rss,%mem,comm --sort=-rss | head -n 20" "vmstat 1"
  elif num_lt "$MEM_AVAIL_PCT" 20; then
    add_finding MEM_AVAILABLE_LOW memory available 2 low "MemAvailable por debajo del 20% ($(fmt_pct "$MEM_AVAIL_PCT"))."
  fi

  if (( SWAP_TOTAL_KB > 0 )) && num_ge "$SWAP_USED_PCT" 80; then
    add_finding MEM_SWAP_OCCUPIED memory swap_occupancy 1 low "Swap al $(fmt_pct "$SWAP_USED_PCT"); por sí sola no demuestra presión actual."
  fi

  if (( SWAP_IO_KBPS >= 10240 )); then
    add_finding MEM_SWAP_ACTIVITY memory swap_activity 5 high "Actividad intensa de swap: ~${SWAP_IO_KBPS} KiB/s combinados."
    add_next_step "Correlacionar swap con latencia de aplicación e I/O; comprobar si existe thrashing." \
      "vmstat 1" "free -h" "iostat -xz 1" "sar -W 1 10"
  elif (( SWAP_IO_KBPS >= 1024 )); then
    add_finding MEM_SWAP_ACTIVITY memory swap_activity 3 medium "Actividad sostenida de swap: ~${SWAP_IO_KBPS} KiB/s combinados."
    add_next_step "Observar vmstat durante más tiempo para confirmar swap-in/swap-out continuos." \
      "vmstat 1 30" "free -h" "swapon --show"
  elif (( SWAP_IO_KBPS > 0 )); then
    add_finding MEM_SWAP_ACTIVITY memory swap_activity 1 low "Se observó actividad de swap (~${SWAP_IO_KBPS} KiB/s) durante la muestra."
  fi

  if (( SWAP_TOTAL_KB == 0 )) && num_lt "$MEM_AVAIL_PCT" 5; then
    add_finding MEM_NO_SWAP_LOW memory no_swap_margin 2 medium "No hay swap y MemAvailable es muy baja; poco margen ante un pico adicional."
    add_next_step "Confirmar si la ausencia de swap es intencionada para esta carga." \
      "swapon --show" "cat /proc/swaps" "free -h" "sysctl vm.swappiness"
  fi

  if (( OOM_EVENTS_COUNT > 0 )); then
    if [[ "$OOM_RECENCY" == "<=15 min" ]]; then
      add_finding MEM_OOM_RECENT memory kernel_oom 8 critical "OOM reciente detectado (${OOM_RECENCY}; fuente: ${OOM_SOURCE})."
    elif [[ "$OOM_RECENCY" == "<=2 h" ]]; then
      add_finding MEM_OOM_RECENT memory kernel_oom 6 high "OOM detectado en las últimas 2 h (fuente: ${OOM_SOURCE})."
    else
      add_finding MEM_OOM_HISTORY memory kernel_oom_history 1 low "Hay evidencia OOM histórica (${OOM_RECENCY}); no se asume relacionada con el síntoma actual."
    fi
    add_next_step "Identificar proceso/cgroup víctima del OOM y correlacionar la hora con la caída de la aplicación." \
      "journalctl -k --since '-2 hours' | grep -Ei 'oom|out of memory|killed process'" \
      "dmesg | grep -Ei 'oom|out of memory|killed process'" \
      "ps -eo pid,ppid,rss,%mem,comm --sort=-rss | head"
  fi

  if num_lt "$MEM_AVAIL_PCT" 10 && (( SWAP_IO_KBPS >= 1024 )); then
    add_finding MEM_PRESSURE_CORRELATED memory pressure_correlation 3 high "MemAvailable baja junto con swap activa: patrón compatible con presión actual."
  fi
}

print_memory() {
  section "MEMORIA Y SWAP"
  kv "Total:" "$(kb_to_human "$MEM_TOTAL_KB")"
  kv "Free:" "$(kb_to_human "$MEM_FREE_KB") ($(fmt_pct "$MEM_FREE_PCT"))"
  if (( MEM_AVAIL_ESTIMATED )); then kv "Available (estimado):" "$(kb_to_human "$MEM_AVAIL_KB") ($(fmt_pct "$MEM_AVAIL_PCT"))"
  else kv "Available:" "$(kb_to_human "$MEM_AVAIL_KB") ($(fmt_pct "$MEM_AVAIL_PCT"))"; fi
  kv "Cached:" "$(kb_to_human "$MEM_CACHED_KB")"; kv "Buffers:" "$(kb_to_human "$MEM_BUFFERS_KB")"
  printf '\n'
  if (( SWAP_TOTAL_KB > 0 )); then
    kv "Swap total:" "$(kb_to_human "$SWAP_TOTAL_KB")"; kv "Swap usada:" "$(kb_to_human "$SWAP_USED_KB") ($(fmt_pct "$SWAP_USED_PCT"))"
    kv "Swap cached:" "$(kb_to_human "$SWAP_CACHED_KB")"; kv "Swap-in (${SAMPLE_SECONDS}s):" "${SWAP_IN_KBPS} KiB/s"
    kv "Swap-out (${SAMPLE_SECONDS}s):" "${SWAP_OUT_KBPS} KiB/s"
  else kv "Swap:" "no configurada"; fi
  kv "Evidencias OOM:" "$OOM_EVENTS_COUNT"; ((OOM_EVENTS_COUNT>0)) && kv "Último OOM / relevancia:" "$OOM_RECENCY"
  ((OOM_EVENTS_COUNT>0)) && kv "Fuente OOM:" "$OOM_SOURCE"

  if (( ${VERBOSE:-0} == 1 )); then
    printf '\n  Procesos con mayor RSS (máx. 10):\n'
    printf '    %-7s %-7s %-12s %-10s %-7s %s\n' PID PPID USER RSS_KiB %MEM COMMAND
    while IFS= read -r line; do [[ -n "$line" ]] && printf '    %s\n' "$line"; done <<<"$TOP_MEMORY_PROCS"
    if ((OOM_EVENTS_COUNT>0)); then
      printf '\n  Evidencias OOM del kernel (máx. 20 líneas):\n'
      while IFS= read -r line; do [[ -n "$line" ]] && printf '    %s\n' "$line"; done <<<"$OOM_EVENTS"
    fi
  fi

  if (( ${EXPLAIN:-0} == 1 )); then
    printf '\n  Explicación:\n'
    printf '    - Free es RAM completamente sin usar; Available es mucho más útil para valorar margen real.\n'
    printf '    - Swap ocupada puede ser histórica; SYSdiag da más peso a actividad swap durante la misma ventana temporal que CPU/red.\n'
    printf '    - Un OOM reciente pesa mucho más que uno de hace muchas horas.\n'
    printf '    - Un contenedor puede sufrir OOM por cgroup aunque al host le sobre RAM.\n'
  fi
}
