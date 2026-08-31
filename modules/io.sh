io_device_profile() {
  local dev="$1" rota="" type="" model=""
  if have_cmd lsblk && [[ -e "/dev/$dev" ]]; then
    read -r rota type model < <(lsblk -dn -o ROTA,TYPE,MODEL "/dev/$dev" 2>/dev/null | head -n1)
  fi
  IO_DEVICE_ROTA="${rota:-n/d}"; IO_DEVICE_TYPE="${type:-n/d}"; IO_DEVICE_MODEL="${model:-n/d}"
  if [[ "$IO_DEVICE_ROTA" == "1" ]]; then IO_DEVICE_CLASS="rotacional"
  elif [[ "$IO_DEVICE_ROTA" == "0" ]]; then IO_DEVICE_CLASS="no rotacional"
  else IO_DEVICE_CLASS="desconocido"; fi
}

collect_io() {
  IOSTAT_AVAILABLE=0; IOSTAT_DATA_VALID=0; IO_MAX_AWAIT=0; IO_MAX_UTIL=0; IO_MAX_AQU=0
  IO_WORST_AWAIT_DEV=""; IO_WORST_UTIL_DEV=""; IO_WORST_AQU_DEV=""; IOSTAT_TABLE=""
  IO_DEVICE_CLASS="desconocido"; IO_DEVICE_TYPE="n/d"; IO_DEVICE_MODEL="n/d"

  if ! have_cmd iostat; then return 0; fi
  IOSTAT_AVAILABLE=1
  ensure_shared_sample 1
  local raw=""
  [[ -n "${SAMPLE_IOSTAT_FILE:-}" && -r "$SAMPLE_IOSTAT_FILE" ]] && raw="$(cat "$SAMPLE_IOSTAT_FILE" 2>/dev/null)"
  [[ -n "$raw" ]] || { add_limitation "Iostat no produjo datos durante la muestra; análisis I/O limitado."; return 0; }

  IOSTAT_TABLE="$(awk '/^Device/{block++;if(block==2){print;next}} block==2&&NF>1{print}' <<<"$raw")"
  if [[ -z "$IOSTAT_TABLE" ]] || ! awk 'NR>1 && NF>1{found=1} END{exit !found}' <<<"$IOSTAT_TABLE"; then
    IOSTAT_TABLE=""
    add_limitation "Iostat respondió, pero no devolvió una tabla de dispositivos válida; análisis I/O limitado."
    return 0
  fi

  read -r IO_MAX_AWAIT IO_WORST_AWAIT_DEV IO_MAX_UTIL IO_WORST_UTIL_DEV IO_MAX_AQU IO_WORST_AQU_DEV < <(
    awk '
      /^Device/ {block++; if(block==2){for(i=1;i<=NF;i++){h=$i;if(h=="await")ia=i;if(h=="r_await")ir=i;if(h=="w_await")iw=i;if(h=="%util")iu=i;if(h=="aqu-sz"||h=="avgqu-sz")iq=i}}; next}
      block==2 && NF>1 {
        dev=$1; if(dev ~ /^loop[0-9]+$/) next;
        wait=0; util=0; q=0;
        if(ia) wait=$(ia); else {r=ir?$(ir):0;w=iw?$(iw):0;wait=(r>w?r:w)}
        if(iu)util=$(iu); if(iq)q=$(iq);
        if(wait+0>mw+0){mw=wait;mwd=dev} if(util+0>mu+0){mu=util;mud=dev} if(q+0>mq+0){mq=q;mqd=dev}
      }
      END{printf "%.2f %s %.2f %s %.2f %s\n",mw+0,mwd,mu+0,mud,mq+0,mqd}
    ' <<<"$raw"
  )
  if [[ -z "$IO_WORST_AWAIT_DEV" && -z "$IO_WORST_UTIL_DEV" && -z "$IO_WORST_AQU_DEV" ]]; then
    add_limitation "Iostat no proporcionó métricas utilizables para ningún dispositivo; análisis I/O limitado."
    return 0
  fi
  IOSTAT_DATA_VALID=1
  [[ -n "$IO_WORST_AWAIT_DEV" ]] && io_device_profile "$IO_WORST_AWAIT_DEV"
}

analyze_io() {
  if (( IOSTAT_AVAILABLE == 0 )); then
    add_next_step "Iostat no está disponible. Verificar sysstat cuando la política del servidor lo permita; SYSdiag no instala paquetes." \
      "command -v iostat" "apt-cache policy sysstat 2>/dev/null" "dnf info sysstat 2>/dev/null"
    return 0
  fi

  if (( ${IOSTAT_DATA_VALID:-0} == 0 )); then
    add_next_step "Iostat está instalado pero la muestra no fue válida. Repetir la medición manualmente durante el síntoma." \
      "iostat -xz 1" "iostat -dx 1 2"
    return 0
  fi

  local warn_await=20 crit_await=100
  case "$IO_DEVICE_CLASS" in
    "no rotacional") warn_await=10; crit_await=50 ;;
    rotacional) warn_await=30; crit_await=100 ;;
  esac

  if num_ge "$IO_MAX_AWAIT" "$crit_await"; then
    add_finding IO_DEVICE_LATENCY io device_latency 5 high \
      "${IO_WORST_AWAIT_DEV:-dispositivo} (${IO_DEVICE_CLASS}) muestra await muy alto: ${IO_MAX_AWAIT} ms."
  elif num_ge "$IO_MAX_AWAIT" "$warn_await"; then
    add_finding IO_DEVICE_LATENCY io device_latency 3 medium \
      "${IO_WORST_AWAIT_DEV:-dispositivo} (${IO_DEVICE_CLASS}) muestra await elevado: ${IO_MAX_AWAIT} ms."
  fi
  if num_ge "$IO_MAX_AWAIT" "$warn_await"; then
    add_next_step "Correlacionar latencia de ${IO_WORST_AWAIT_DEV:-storage} con procesos D y carga de aplicación." \
      "iostat -xz 1" "ps -eo pid,ppid,state,comm,wchan:32 | awk '\$3 ~ /^D/'" "lsblk -o NAME,TYPE,ROTA,SIZE,FSTYPE,MOUNTPOINTS,MODEL"
  fi

  if num_ge "$IO_MAX_AQU" 4; then
    add_finding IO_DEVICE_QUEUE io device_queue 2 medium "Cola de I/O elevada (aqu-sz máx. ${IO_MAX_AQU} en ${IO_WORST_AQU_DEV:-n/d})."
  fi
  if num_ge "$IO_MAX_UTIL" 95; then
    add_finding IO_DEVICE_UTIL io device_util 1 medium "${IO_WORST_UTIL_DEV:-Un dispositivo} presenta %util elevado (${IO_MAX_UTIL}%); se interpreta junto con latencia/cola."
  fi
}

print_io() {
  section "I/O"
  if (( IOSTAT_AVAILABLE == 0 )); then
    warn "Iostat no está disponible. El análisis de I/O queda limitado."
    printf '  Sugerencia: iostat suele venir en sysstat. SYSdiag no instala nada automáticamente.\n'
    return 0
  fi
  if (( ${IOSTAT_DATA_VALID:-0} == 0 )); then
    warn "Iostat está disponible, pero no se obtuvo una muestra válida. No se muestran ceros como si fueran datos reales."
    return 0
  fi
  kv "Periodo de muestra:" "${SAMPLE_SECONDS}s (compartido con CPU/red/swap)"
  kv "Mayor await:" "${IO_MAX_AWAIT} ms (${IO_WORST_AWAIT_DEV:-n/d})"
  kv "Tipo dispositivo await:" "$IO_DEVICE_CLASS / ${IO_DEVICE_TYPE}"
  [[ "$IO_DEVICE_MODEL" != "n/d" ]] && kv "Modelo:" "$IO_DEVICE_MODEL"
  kv "Mayor aqu-sz:" "${IO_MAX_AQU} (${IO_WORST_AQU_DEV:-n/d})"
  kv "Mayor %util:" "${IO_MAX_UTIL}% (${IO_WORST_UTIL_DEV:-n/d})"

  if (( ${VERBOSE:-0} == 1 )) && [[ -n "$IOSTAT_TABLE" ]]; then
    printf '\n  Muestreo de iostat alineado con la ventana común:\n'
    while IFS= read -r line; do printf '    %s\n' "$line"; done <<<"$IOSTAT_TABLE"
  fi
  if (( ${EXPLAIN:-0} == 1 )); then
    printf '\n  Explicación:\n'
    printf '    - await mide latencia observada por operaciones; los umbrales son orientativos y dependen del tipo de storage.\n'
    printf '    - aqu-sz ayuda a ver si se acumulan operaciones en cola.\n'
    printf '    - %%util por sí solo no demuestra saturación, especialmente en NVMe/dispositivos paralelos.\n'
    printf '    - SYSdiag excluye loop devices de la selección del peor dispositivo para evitar ruido de Snap/AppImage.\n'
  fi
}
