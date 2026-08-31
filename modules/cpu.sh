calculate_cpu_metrics() {
  local a="$1" b="$2"
  [[ -n "$a" && -n "$b" ]] || return 1

  local au an as ai aw airq asirq asteal agu agn
  local bu bn bs bi bw birq bsirq bsteal bgu bgn
  read -r _ au an as ai aw airq asirq asteal agu agn <<<"$a"
  read -r _ bu bn bs bi bw birq bsirq bsteal bgu bgn <<<"$b"

  au=${au:-0}; an=${an:-0}; as=${as:-0}; ai=${ai:-0}; aw=${aw:-0}; airq=${airq:-0}; asirq=${asirq:-0}; asteal=${asteal:-0}
  bu=${bu:-0}; bn=${bn:-0}; bs=${bs:-0}; bi=${bi:-0}; bw=${bw:-0}; birq=${birq:-0}; bsirq=${bsirq:-0}; bsteal=${bsteal:-0}

  # guest y guest_nice ya están incluidos en user/nice en /proc/stat; no se suman.
  local total_a=$((au+an+as+ai+aw+airq+asirq+asteal))
  local total_b=$((bu+bn+bs+bi+bw+birq+bsirq+bsteal))
  local totald=$((total_b-total_a))
  local idled=$((bi-ai)) waitd=$((bw-aw)) userd=$((bu-au)) niced=$((bn-an))
  local systemd=$((bs-as)) irqd=$((birq-airq)) sirqd=$((bsirq-asirq)) steald=$((bsteal-asteal))

  (( totald > 0 )) || return 1
  CPU_IDLE_PCT="$(awk -v x="$idled" -v t="$totald" 'BEGIN{printf "%.2f",100*x/t}')"
  CPU_IOWAIT_PCT="$(awk -v x="$waitd" -v t="$totald" 'BEGIN{printf "%.2f",100*x/t}')"
  CPU_USER_PCT="$(awk -v x="$userd" -v n="$niced" -v t="$totald" 'BEGIN{printf "%.2f",100*(x+n)/t}')"
  CPU_SYSTEM_PCT="$(awk -v x="$systemd" -v i="$irqd" -v s="$sirqd" -v t="$totald" 'BEGIN{printf "%.2f",100*(x+i+s)/t}')"
  CPU_STEAL_PCT="$(awk -v x="$steald" -v t="$totald" 'BEGIN{printf "%.2f",100*x/t}')"
  CPU_BUSY_PCT="$(awk -v i="$CPU_IDLE_PCT" -v w="$CPU_IOWAIT_PCT" 'BEGIN{x=100-i-w;if(x<0)x=0;printf "%.2f",x}')"
}

collect_cpu() {
  read -r LOAD1 LOAD5 LOAD15 _ _ < /proc/loadavg
  ensure_shared_sample 0
  calculate_cpu_metrics "${SAMPLE_CPU_A:-}" "${SAMPLE_CPU_B:-}" || true

  CPU_IDLE_PCT="${CPU_IDLE_PCT:-0}"
  CPU_IOWAIT_PCT="${CPU_IOWAIT_PCT:-0}"
  CPU_USER_PCT="${CPU_USER_PCT:-0}"
  CPU_SYSTEM_PCT="${CPU_SYSTEM_PCT:-0}"
  CPU_STEAL_PCT="${CPU_STEAL_PCT:-0}"
  CPU_BUSY_PCT="${CPU_BUSY_PCT:-0}"
  LOAD_RATIO="$(awk -v l="$LOAD1" -v c="${CPU_COUNT:-1}" 'BEGIN{if(c>0) printf "%.2f",l/c;else print 0}')"
}

analyze_cpu() {
  if num_ge "$LOAD_RATIO" 1.0; then
    add_finding CPU_LOAD_HIGH cpu scheduler_load 1 medium \
      "Load 1m (${LOAD1}) supera el número de CPUs lógicas (${CPU_COUNT})."
  fi

  if num_ge "$CPU_BUSY_PCT" 85 && (( ${PROC_R:-0} > ${CPU_COUNT:-1} )); then
    add_finding CPU_CONTENTION cpu runnable_pressure 5 high \
      "CPU activa muy alta y más procesos R que CPUs: posible contención de CPU."
    add_next_step \
      "Identificar procesos con mayor consumo de CPU y comprobar si el aumento coincide con el inicio del problema." \
      "ps -eo pid,ppid,user,stat,%cpu,%mem,comm --sort=-%cpu | head -n 20" \
      "pidstat 1"
  fi

  if num_ge "$CPU_IOWAIT_PCT" 30; then
    add_finding IO_CPU_IOWAIT io cpu_iowait 4 high "Iowait muy elevado: $(fmt_pct "$CPU_IOWAIT_PCT")."
    add_next_step \
      "Medir latencia y colas de almacenamiento e identificar procesos en espera I/O." \
      "iostat -xz 1" \
      "ps -eo pid,ppid,state,comm,wchan:32 | awk '\$3 ~ /^D/'"
  elif num_ge "$CPU_IOWAIT_PCT" 15; then
    add_finding IO_CPU_IOWAIT io cpu_iowait 2 medium "Iowait elevado: $(fmt_pct "$CPU_IOWAIT_PCT")."
    add_next_step \
      "Medir latencia y colas de almacenamiento e identificar procesos en espera I/O." \
      "iostat -xz 1" \
      "ps -eo pid,ppid,state,comm,wchan:32 | awk '\$3 ~ /^D/'"
  fi

  if num_ge "$LOAD_RATIO" 0.50 \
     && num_gt "$LOAD1" "$(awk -v x="$LOAD5" 'BEGIN{print x*1.25}')" \
     && num_gt "$LOAD5" "$LOAD15"; then
    add_finding PROC_LOAD_TREND processes load_trend 1 low \
      "El load está creciendo con rapidez (1m > 5m > 15m) y ya es significativo respecto a las CPUs."
    add_next_step \
      "Buscar qué cambió aproximadamente cuando comenzó a subir el load: despliegues, backups, cron, batch o fallos." \
      "journalctl --since '-30 min'" \
      "systemctl list-timers --all" \
      "ps -eo lstart,pid,ppid,stat,comm --sort=lstart | tail -n 30"
  fi
}

print_cpu() {
  section "CPU Y LOAD"
  kv "Periodo de muestra:" "${SAMPLE_SECONDS}s"
  kv "Load 1m / 5m / 15m:" "$LOAD1 / $LOAD5 / $LOAD15"
  kv "Load 1m / CPUs lógicas:" "${LOAD_RATIO}x"
  kv "CPU user+nice:" "$(fmt_pct "$CPU_USER_PCT")"
  kv "CPU system+irq:" "$(fmt_pct "$CPU_SYSTEM_PCT")"
  kv "CPU iowait:" "$(fmt_pct "$CPU_IOWAIT_PCT")"
  kv "CPU steal:" "$(fmt_pct "$CPU_STEAL_PCT")"
  kv "CPU idle real:" "$(fmt_pct "$CPU_IDLE_PCT")"
  kv "CPU activa (sin iowait):" "$(fmt_pct "$CPU_BUSY_PCT")"

  if (( ${EXPLAIN:-0} == 1 )); then
    printf '\n  Explicación:\n'
    printf '    - Load no es un porcentaje. Se interpreta junto con el número de CPUs lógicas disponibles.\n'
    printf '    - Load incluye tareas ejecutables (R) y determinadas esperas ininterrumpibles (D).\n'
    printf '    - CPU idle e iowait se muestran separados: iowait NO se suma a idle.\n'
    printf '    - CPU activa excluye tanto idle como iowait para no presentar espera de I/O como trabajo útil de CPU.\n'
    printf '    - Load alto con mucha CPU idle obliga a investigar por qué esas tareas no están usando CPU.\n'
  fi
}
