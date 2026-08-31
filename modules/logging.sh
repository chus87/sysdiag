# Logging diagnostics: journald, rsyslog and logrotate.
# Read-only by design. Heavy recursive scans and active remediation are avoided.

parse_journald_storage() {
  local raw="$1"
  awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*Storage[[:space:]]*=/ {
      line=$0
      sub(/^[[:space:]]*Storage[[:space:]]*=[[:space:]]*/, "", line)
      sub(/[[:space:]]*#.*/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line != "") value=line
    }
    END {print value}
  ' <<<"$raw"
}

parse_logrotate_directives() {
  local raw="$1" key
  for key in compress delaycompress copytruncate create postrotate; do
    awk -v key="$key" '
      /^[[:space:]]*#/ {next}
      {
        line=$0
        sub(/[[:space:]]*#.*/, "", line)
        if (line ~ "^[[:space:]]*" key "([[:space:]]|$)") count++
      }
      END {print count+0}
    ' <<<"$raw"
  done | paste -sd' ' -
}

_logging_read_config_files() {
  local files=() f
  [[ -r /etc/rsyslog.conf ]] && files+=(/etc/rsyslog.conf)
  for f in /etc/rsyslog.d/*.conf; do [[ -r "$f" ]] && files+=("$f"); done
  ((${#files[@]})) && cat -- "${files[@]}" 2>/dev/null || true
}

_logrotate_read_config_files() {
  local files=() f
  [[ -r /etc/logrotate.conf ]] && files+=(/etc/logrotate.conf)
  for f in /etc/logrotate.d/*; do [[ -f "$f" && -r "$f" ]] && files+=("$f"); done
  ((${#files[@]})) && cat -- "${files[@]}" 2>/dev/null || true
}

_logging_remote_fstype() {
  case "${1,,}" in
    nfs|nfs4|cifs|smbfs|smb3|ceph|glusterfs|fuse.sshfs|sshfs|9p|afs|lustre) return 0 ;;
    *) return 1 ;;
  esac
}

_logging_mount_info_for_var_log() {
  local raw="" rc=0
  if have_cmd findmnt; then
    raw="$(run_with_timeout 3 findmnt -T /var/log -n -o SOURCE,FSTYPE 2>/dev/null)" || rc=$?
    if (( rc == 0 )) && [[ -n "$raw" ]]; then
      printf '%s\n' "$raw"
      return 0
    elif (( rc == 124 )); then
      return 124
    fi
  fi

  # Fallback without touching the mounted filesystem: read the kernel's mount
  # table and choose the deepest mountpoint containing /var/log.
  [[ -r /proc/self/mountinfo ]] || return 1
  awk -v target="/var/log" '
    {
      sep=0; for(i=1;i<=NF;i++) if($i=="-"){sep=i;break}
      if(!sep || sep+2>NF) next
      mp=$5; gsub(/\\040/," ",mp); gsub(/\\011/,"\t",mp); gsub(/\\134/,"\\",mp)
      if(target==mp || (mp!="/" && index(target,mp "/")==1) || mp=="/"){
        if(length(mp)>best){best=length(mp); fs=$(sep+1); src=$(sep+2)}
      }
    }
    END{if(best>0) print src,fs; else exit 1}
  ' /proc/self/mountinfo
}

collect_logging() {
  LOGGING_COLLECTED=1
  JOURNALCTL_AVAILABLE=0; JOURNALD_ACTIVE="n/d"; JOURNALD_FAILED="n/d"; JOURNALD_STORAGE_CONFIG="n/d"
  JOURNAL_PERSISTENT_STORE=0; JOURNAL_VOLATILE_STORE=0; JOURNAL_BOOT_COUNT="n/d"; JOURNAL_BOOT_QUERY_VALID=0; JOURNAL_PREVIOUS_BOOT_AVAILABLE=0
  JOURNAL_DISK_USAGE="n/d"; JOURNAL_RECENT_SAMPLE_COUNT=0; JOURNAL_RECENT_SAMPLE=""; JOURNAL_ACCESS="n/d"
  DMESG_AVAILABLE=0; DMESG_READABLE="n/d"

  RSYSLOG_AVAILABLE=0; RSYSLOG_ACTIVE="n/d"; RSYSLOG_FAILED="n/d"; RSYSLOG_CONFIG_PRESENT=0; RSYSLOG_REMOTE_HINT=0
  LOGROTATE_AVAILABLE=0; LOGROTATE_CONFIG_PRESENT=0; LOGROTATE_SERVICE_FAILED="n/d"; LOGROTATE_TIMER_ACTIVE="n/d"
  LOGROTATE_STATE_FILE=""; LOGROTATE_LAST_STATE_DATE="n/d"; LOGROTATE_COMPRESS_COUNT=0; LOGROTATE_DELAYCOMPRESS_COUNT=0
  LOGROTATE_COPYTRUNCATE_COUNT=0; LOGROTATE_CREATE_COUNT=0; LOGROTATE_POSTROTATE_COUNT=0
  VAR_LOG_USE_PCT="n/d"; VAR_LOG_SOURCE="n/d"; VAR_LOG_FSTYPE="n/d"; VAR_LOG_REMOTE=0; VAR_LOG_TOP_FILES=""; VAR_LOG_TOP_SCAN="n/d"

  local rc=0 raw="" storage=""
  if have_cmd journalctl; then
    JOURNALCTL_AVAILABLE=1

    rc=0; raw="$(run_with_timeout 4 journalctl --list-boots --no-pager 2>/dev/null)" || rc=$?
    if ((rc==124)); then
      add_limitation "La consulta journalctl --list-boots superó 4s; historial de boots no determinado."
    elif ((rc!=0)); then
      add_limitation "La consulta journalctl --list-boots no pudo completarse; no se asume que haya 0 boots disponibles."
    else
      JOURNAL_BOOT_QUERY_VALID=1
      JOURNAL_BOOT_COUNT="$(printf '%s\n' "$raw" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
      ((JOURNAL_BOOT_COUNT>1)) && JOURNAL_PREVIOUS_BOOT_AVAILABLE=1
      JOURNAL_ACCESS="disponible"
    fi

    rc=0; raw="$(run_with_timeout 4 journalctl --disk-usage --no-pager 2>/dev/null)" || rc=$?
    if ((rc==124)); then
      add_limitation "La consulta journalctl --disk-usage superó 4s; uso del journal no determinado."
    elif [[ -n "$raw" ]]; then
      JOURNAL_DISK_USAGE="$(trim "$raw")"
    fi

    # Muestra acotada: no se interpreta el número de WARNING/ERROR como causa.
    rc=0; raw="$(run_with_timeout 5 journalctl --since '-30 min' -p warning -n 100 --no-pager -o short-iso 2>/dev/null)" || rc=$?
    if ((rc==124)); then
      add_limitation "La consulta journalctl de los últimos 30 min superó 5s; muestra reciente omitida."
    else
      JOURNAL_RECENT_SAMPLE="$(printf '%s\n' "$raw" | sanitize_terminal_text | sed '/^[[:space:]]*$/d; /^-- No entries --$/d')"
      JOURNAL_RECENT_SAMPLE_COUNT="$(printf '%s\n' "$JOURNAL_RECENT_SAMPLE" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
    fi
  else
    add_limitation "Journalctl no está disponible; análisis de journald limitado."
  fi

  if [[ -d /var/log/journal ]] && run_shell_with_timeout 2 'find /var/log/journal -maxdepth 3 -type f -name "*.journal" -print -quit 2>/dev/null | grep -q .'; then JOURNAL_PERSISTENT_STORE=1; fi
  if [[ -d /run/log/journal ]] && run_shell_with_timeout 2 'find /run/log/journal -maxdepth 3 -type f -name "*.journal" -print -quit 2>/dev/null | grep -q .'; then JOURNAL_VOLATILE_STORE=1; fi

  if have_cmd systemd-analyze; then
    rc=0; raw="$(run_with_timeout 4 systemd-analyze cat-config systemd/journald.conf 2>/dev/null)" || rc=$?
    if ((rc!=124)) && [[ -n "$raw" ]]; then
      storage="$(parse_journald_storage "$raw")"
      [[ -n "$storage" ]] && JOURNALD_STORAGE_CONFIG="$storage"
    fi
  elif [[ -r /etc/systemd/journald.conf ]]; then
    storage="$(parse_journald_storage "$(cat /etc/systemd/journald.conf 2>/dev/null || true)")"
    [[ -n "$storage" ]] && JOURNALD_STORAGE_CONFIG="$storage"
  fi

  if have_cmd systemctl; then
    JOURNALD_ACTIVE="$(run_with_timeout 3 systemctl is-active systemd-journald.service 2>/dev/null || true)"; [[ -n "$JOURNALD_ACTIVE" ]] || JOURNALD_ACTIVE="unknown"
    JOURNALD_FAILED="$(run_with_timeout 3 systemctl is-failed systemd-journald.service 2>/dev/null || true)"; [[ -n "$JOURNALD_FAILED" ]] || JOURNALD_FAILED="unknown"
  fi

  if have_cmd dmesg; then
    DMESG_AVAILABLE=1; rc=0
    run_shell_with_timeout 3 'set -o pipefail; dmesg 2>/dev/null | head -n 1 >/dev/null' || rc=$?
    if ((rc==0)); then DMESG_READABLE="sí"; elif ((rc==124)); then DMESG_READABLE="timeout"; else DMESG_READABLE="no/restringido"; fi
  fi

  local rsyslog_raw=""
  if have_cmd rsyslogd; then RSYSLOG_AVAILABLE=1; fi
  [[ -r /etc/rsyslog.conf || -d /etc/rsyslog.d ]] && RSYSLOG_CONFIG_PRESENT=1
  if ((RSYSLOG_CONFIG_PRESENT)); then
    rsyslog_raw="$(_logging_read_config_files)"
    if printf '%s\n' "$rsyslog_raw" | sed '/^[[:space:]]*#/d' | grep -Eq '(^|[[:space:]])@@?[^[:space:];]+|omfwd'; then RSYSLOG_REMOTE_HINT=1; fi
  fi
  if have_cmd systemctl; then
    RSYSLOG_ACTIVE="$(run_with_timeout 3 systemctl is-active rsyslog.service 2>/dev/null || true)"; [[ -n "$RSYSLOG_ACTIVE" ]] || RSYSLOG_ACTIVE="unknown"
    RSYSLOG_FAILED="$(run_with_timeout 3 systemctl is-failed rsyslog.service 2>/dev/null || true)"; [[ -n "$RSYSLOG_FAILED" ]] || RSYSLOG_FAILED="unknown"
  fi

  local lr_raw="" state_file=""
  have_cmd logrotate && LOGROTATE_AVAILABLE=1
  [[ -r /etc/logrotate.conf || -d /etc/logrotate.d ]] && LOGROTATE_CONFIG_PRESENT=1
  if ((LOGROTATE_CONFIG_PRESENT)); then
    lr_raw="$(_logrotate_read_config_files)"
    read -r LOGROTATE_COMPRESS_COUNT LOGROTATE_DELAYCOMPRESS_COUNT LOGROTATE_COPYTRUNCATE_COUNT LOGROTATE_CREATE_COUNT LOGROTATE_POSTROTATE_COUNT \
      <<<"$(parse_logrotate_directives "$lr_raw")"
  fi
  for state_file in /var/lib/logrotate/status /var/lib/logrotate/logrotate.status; do
    if [[ -r "$state_file" ]]; then LOGROTATE_STATE_FILE="$state_file"; break; fi
  done
  if [[ -n "$LOGROTATE_STATE_FILE" ]]; then
    LOGROTATE_LAST_STATE_DATE="$(awk 'match($0,/[0-9]{4}-[0-9]{2}-[0-9]{2}(-[0-9]{2}:[0-9]{2}:[0-9]{2})?/){v=substr($0,RSTART,RLENGTH); if(v>max)max=v} END{if(max!="")print max}' "$LOGROTATE_STATE_FILE" 2>/dev/null)"
    [[ -n "$LOGROTATE_LAST_STATE_DATE" ]] || LOGROTATE_LAST_STATE_DATE="n/d"
  fi
  if have_cmd systemctl; then
    LOGROTATE_SERVICE_FAILED="$(run_with_timeout 3 systemctl is-failed logrotate.service 2>/dev/null || true)"; [[ -n "$LOGROTATE_SERVICE_FAILED" ]] || LOGROTATE_SERVICE_FAILED="unknown"
    LOGROTATE_TIMER_ACTIVE="$(run_with_timeout 3 systemctl is-active logrotate.timer 2>/dev/null || true)"; [[ -n "$LOGROTATE_TIMER_ACTIVE" ]] || LOGROTATE_TIMER_ACTIVE="unknown"
  fi

  # /var/log: primero detecta el tipo de filesystem usando la tabla de mounts.
  # Si es remoto/distribuido conocido, se evita incluso el listado superficial: un
  # diagnóstico no debe agravar un servidor bloqueándose sobre NFS/CIFS/etc.
  if [[ -d /var/log ]]; then
    rc=0; raw="$(_logging_mount_info_for_var_log)" || rc=$?
    if ((rc==0)) && [[ -n "$raw" ]]; then
      read -r VAR_LOG_SOURCE VAR_LOG_FSTYPE <<<"$raw"
    elif ((rc==124)); then
      add_limitation "La consulta findmnt -T /var/log superó 3s; se intentó evitar acceso adicional hasta conocer el tipo de filesystem."
    fi

    if _logging_remote_fstype "$VAR_LOG_FSTYPE"; then
      VAR_LOG_REMOTE=1
      VAR_LOG_TOP_SCAN="omitido (filesystem remoto: ${VAR_LOG_FSTYPE})"
      add_limitation "Se omiten df/find automáticos sobre /var/log porque reside en ${VAR_LOG_FSTYPE}; evita bloquear SYSdiag sobre almacenamiento remoto degradado."
    else
      rc=0; raw="$(run_with_timeout 4 df -P /var/log 2>/dev/null)" || rc=$?
      if ((rc==0)); then
        read -r _df_source VAR_LOG_USE_PCT < <(awk 'NR==2{gsub(/%/,"",$5); print $1,$5}' <<<"$raw")
        [[ "$VAR_LOG_USE_PCT" =~ ^[0-9]+$ ]] || VAR_LOG_USE_PCT="n/d"
        [[ "$VAR_LOG_SOURCE" != "n/d" && -n "$VAR_LOG_SOURCE" ]] || VAR_LOG_SOURCE="${_df_source:-n/d}"
      elif ((rc==124)); then add_limitation "La consulta df /var/log superó 4s; ocupación del filesystem no determinada."; fi

      rc=0
      VAR_LOG_TOP_FILES="$(run_shell_with_timeout 4 'find /var/log -xdev -maxdepth 2 -type f -printf "%s\t%p\n" 2>/dev/null | sort -nr | head -n 10')" || rc=$?
      VAR_LOG_TOP_FILES="$(printf '%s\n' "$VAR_LOG_TOP_FILES" | sanitize_terminal_text)"
      if ((rc==0)); then VAR_LOG_TOP_SCAN="ok (profundidad <=2)"; elif ((rc==124)); then VAR_LOG_TOP_SCAN="timeout (omitido)"; VAR_LOG_TOP_FILES=""; add_limitation "Listado superficial de /var/log superó 4s; no se hizo recorrido más profundo."; else VAR_LOG_TOP_SCAN="no disponible"; fi
    fi
  fi
}

analyze_logging() {
  if [[ "${JOURNALD_FAILED:-}" == "failed" ]]; then
    add_finding LOG_JOURNALD_FAILED logging journal_service 5 high "Systemd-journald.service aparece en estado failed."
    add_next_step "Revisar por qué journald está failed sin reiniciarlo automáticamente." \
      "systemctl status systemd-journald.service" \
      "journalctl -u systemd-journald.service -b --no-pager" \
      "systemctl cat systemd-journald.service"
  fi

  case "${JOURNALD_STORAGE_CONFIG:-n/d}" in
    volatile)
      add_limitation "Journald está configurado como volatile: un reboot puede eliminar evidencia local del boot anterior."
      add_next_step "Confirmar si la falta de persistencia local del journal es intencionada y si existe centralización remota." \
        "systemd-analyze cat-config systemd/journald.conf" \
        "journalctl --list-boots" \
        "ls -ld /var/log/journal /run/log/journal 2>/dev/null"
      ;;
    none)
      add_limitation "Journald tiene Storage=none: la capacidad de análisis histórico local puede ser muy limitada."
      add_next_step "Confirmar la estrategia de logging cuando journald no conserva eventos localmente." \
        "systemd-analyze cat-config systemd/journald.conf" \
        "journalctl --list-boots" \
        "grep -R '^[^#].*omfwd\|@@' /etc/rsyslog.conf /etc/rsyslog.d 2>/dev/null"
      ;;
  esac

  if [[ "${RSYSLOG_FAILED:-}" == "failed" ]]; then
    add_finding LOG_RSYSLOG_FAILED logging syslog_transport 3 medium "Rsyslog.service aparece en estado failed; el procesamiento/reenvío syslog puede estar afectado."
    add_next_step "Revisar el fallo de rsyslog y si se están perdiendo escrituras o reenvíos." \
      "systemctl status rsyslog.service" \
      "journalctl -u rsyslog.service -b --no-pager" \
      "rsyslogd -N1"
  fi

  if [[ "${LOGROTATE_SERVICE_FAILED:-}" == "failed" ]]; then
    add_finding LOG_LOGROTATE_FAILED logging rotation 3 medium "Logrotate.service aparece en estado failed; alguna rotación puede no haberse completado."
    add_next_step "Revisar el último fallo de logrotate antes de forzar una rotación." \
      "systemctl status logrotate.service" \
      "journalctl -u logrotate.service -b --no-pager" \
      "logrotate -d /etc/logrotate.conf"
  fi

  if [[ "${VAR_LOG_USE_PCT:-n/d}" =~ ^[0-9]+$ ]] && ((VAR_LOG_USE_PCT>=85)); then
    add_next_step "El filesystem que contiene /var/log está al ${VAR_LOG_USE_PCT}%; revisar crecimiento, rotación y deleted-open sin hacer borrados a ciegas." \
      "df -hT /var/log" \
      "find /var/log -xdev -maxdepth 2 -type f -printf '%s %p\\n' 2>/dev/null | sort -n | tail -n 30" \
      "lsof -nP +L1" \
      "systemctl status logrotate.service logrotate.timer"
  fi

  if [[ "${LOGROTATE_COPYTRUNCATE_COUNT:-0}" =~ ^[0-9]+$ ]] && ((LOGROTATE_COPYTRUNCATE_COUNT>0)); then
    add_next_step "Hay reglas copytruncate (${LOGROTATE_COPYTRUNCATE_COUNT}); si faltan líneas alrededor de la rotación, revisar si la aplicación soporta rename + reopen." \
      "grep -Rni '^[[:space:]]*copytruncate' /etc/logrotate.conf /etc/logrotate.d 2>/dev/null" \
      "grep -Rni 'postrotate\|create\|copytruncate' /etc/logrotate.conf /etc/logrotate.d 2>/dev/null"
  fi
}

print_logging() {
  section "LOGS Y JOURNAL"

  subsection "journald / kernel"
  kv_at 4 38 "Disponibilidad de journalctl:" "$([[ ${JOURNALCTL_AVAILABLE:-0} -eq 1 ]] && echo sí || echo no)"
  kv_at 4 38 "Estado de systemd-journald:" "${JOURNALD_ACTIVE:-n/d}"
  kv_at 4 38 "Storage= efectivo/configurado:" "${JOURNALD_STORAGE_CONFIG:-n/d}"
  kv_at 4 38 "Store persistente observado:" "$([[ ${JOURNAL_PERSISTENT_STORE:-0} -eq 1 ]] && echo sí || echo no)"
  kv_at 4 38 "Store volátil observado:" "$([[ ${JOURNAL_VOLATILE_STORE:-0} -eq 1 ]] && echo sí || echo no)"
  kv_at 4 38 "Boots visibles en journal:" "${JOURNAL_BOOT_COUNT:-n/d}"
  kv_at 4 38 "Boot anterior consultable:" "$([[ ${JOURNAL_PREVIOUS_BOOT_AVAILABLE:-0} -eq 1 ]] && echo sí || echo no)"
  kv_at 4 38 "Uso del journal:" "${JOURNAL_DISK_USAGE:-n/d}"
  kv_at 4 38 "WARNING+ recientes (muestra):" "${JOURNAL_RECENT_SAMPLE_COUNT:-0} (máx. 100 / 30 min; no implica causa)"
  kv_at 4 38 "Disponibilidad/lectura de dmesg:" "$([[ ${DMESG_AVAILABLE:-0} -eq 1 ]] && echo "sí / ${DMESG_READABLE:-n/d}" || echo no)"

  subsection "rsyslog"
  kv_at 4 38 "Disponibilidad de rsyslogd:" "$([[ ${RSYSLOG_AVAILABLE:-0} -eq 1 ]] && echo sí || echo no)"
  kv_at 4 38 "Estado de rsyslog.service:" "${RSYSLOG_ACTIVE:-n/d}"
  kv_at 4 38 "Configuración local detectada:" "$([[ ${RSYSLOG_CONFIG_PRESENT:-0} -eq 1 ]] && echo sí || echo no)"
  kv_at 4 38 "Indicio de forwarding remoto:" "$([[ ${RSYSLOG_REMOTE_HINT:-0} -eq 1 ]] && echo sí || echo no/no detectado)"

  subsection "logrotate / /var/log"
  kv_at 4 38 "Disponibilidad de logrotate:" "$([[ ${LOGROTATE_AVAILABLE:-0} -eq 1 ]] && echo sí || echo no)"
  kv_at 4 38 "Configuración detectada:" "$([[ ${LOGROTATE_CONFIG_PRESENT:-0} -eq 1 ]] && echo sí || echo no)"
  kv_at 4 38 "Estado de logrotate.timer:" "${LOGROTATE_TIMER_ACTIVE:-n/d}"
  kv_at 4 38 "Fallo de logrotate.service:" "${LOGROTATE_SERVICE_FAILED:-n/d}"
  kv_at 4 38 "Último estado registrado:" "${LOGROTATE_LAST_STATE_DATE:-n/d}"
  kv_at 4 38 "Directivas compress / delaycompress:" "${LOGROTATE_COMPRESS_COUNT:-0} / ${LOGROTATE_DELAYCOMPRESS_COUNT:-0}"
  kv_at 4 38 "Directivas copytruncate / create:" "${LOGROTATE_COPYTRUNCATE_COUNT:-0} / ${LOGROTATE_CREATE_COUNT:-0}"
  kv_at 4 38 "Directiva postrotate:" "${LOGROTATE_POSTROTATE_COUNT:-0}"
  kv_at 4 38 "FS de /var/log:" "${VAR_LOG_SOURCE:-n/d} (${VAR_LOG_FSTYPE:-n/d}; uso ${VAR_LOG_USE_PCT:-n/d}%)"
  kv_at 4 38 "Filesystem remoto:" "$([[ ${VAR_LOG_REMOTE:-0} -eq 1 ]] && echo sí || echo no/no detectado)"
  kv_at 4 38 "Escaneo superficial logs:" "${VAR_LOG_TOP_SCAN:-n/d}"

  if (( ${VERBOSE:-0} == 1 )); then
    if [[ -n "${JOURNAL_RECENT_SAMPLE:-}" ]]; then
      subsection "WARNING+ recientes del journal (máx. 100)"
      while IFS= read -r line; do [[ -n "$line" ]] && printf '    %s\n' "$line"; done <<<"$JOURNAL_RECENT_SAMPLE"
    fi
    if [[ -n "${VAR_LOG_TOP_FILES:-}" ]]; then
      subsection "Ficheros más grandes bajo /var/log (profundidad <=2)"
      local size path
      while IFS=$'\t' read -r size path; do
        [[ "$size" =~ ^[0-9]+$ ]] || continue
        printf '    %-12s %s\n' "$(bytes_to_human "$size")" "$path"
      done <<<"$VAR_LOG_TOP_FILES"
    fi
  fi

  subsection "Comandos de comprobación manual"
  printf '    Ventana temporal:\n      $ journalctl --since "<inicio>" --until "<fin>" --no-pager\n'
  printf '    Servicio:\n      $ journalctl -u <servicio> --since "-30 min" --no-pager\n      $ journalctl -u <servicio> -f\n'
  printf '    Kernel / boots:\n      $ journalctl -k -b -1 --no-pager\n      $ journalctl --list-boots\n      $ dmesg -T\n'
  printf '    Logs rotados:\n      $ zgrep -i "<patrón>" /var/log/<log>*.gz\n      $ less /var/log/<log>\n'
  printf '    Rotación / deleted-open:\n      $ systemctl status logrotate.service logrotate.timer\n      $ logrotate -d /etc/logrotate.conf\n      $ lsof -nP +L1\n'

  if (( ${EXPLAIN:-0} == 1 )); then
    printf '\n  Explicación:\n'
    printf '    - Un log es evidencia; una prioridad ERROR/WARNING no demuestra causalidad.\n'
    printf '    - dmesg consulta el ring buffer actual; journalctl puede filtrar por tiempo, unidad y boot si el journal conserva esos datos.\n'
    printf '    - Storage=volatile puede hacer que un reboot elimine evidencia local del boot anterior.\n'
    printf '    - rsyslog puede filtrar, escribir y reenviar syslog; su ausencia no implica fallo si el sistema usa otra estrategia.\n'
    printf '    - copytruncate evita la reapertura, pero introduce una ventana de carrera; rename + reopen es preferible cuando la aplicación lo soporta.\n'
    printf '    - SYSdiag no ejecuta rotaciones, reloads, borrados ni recorridos du recursivos automáticamente.\n'
  fi
}
