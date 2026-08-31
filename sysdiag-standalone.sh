#!/usr/bin/env bash
set -uo pipefail
BASE_DIR="$(pwd)"


# ===== lib/version.sh =====

SYS_DIAG_VERSION="0.14.2"

# ===== lib/common.sh =====

have_cmd() { command -v "$1" >/dev/null 2>&1; }

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

trim() {
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

num_gt() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{exit !(a>b)}'; }
num_ge() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{exit !(a>=b)}'; }
num_lt() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{exit !(a<b)}'; }
num_le() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{exit !(a<=b)}'; }

fmt_pct() { awk -v v="${1:-0}" 'BEGIN{printf "%.1f%%", v}'; }
fmt_num() { awk -v v="${1:-0}" 'BEGIN{printf "%.2f", v}'; }

kb_to_human() {
  awk -v kb="${1:-0}" 'BEGIN {
    if (kb >= 1073741824) printf "%.2f TiB", kb/1073741824;
    else if (kb >= 1048576) printf "%.2f GiB", kb/1048576;
    else if (kb >= 1024) printf "%.2f MiB", kb/1024;
    else printf "%d KiB", kb;
  }'
}

bytes_to_human() {
  awk -v b="${1:-0}" 'BEGIN {
    if (b >= 1099511627776) printf "%.2f TiB", b/1099511627776;
    else if (b >= 1073741824) printf "%.2f GiB", b/1073741824;
    else if (b >= 1048576) printf "%.2f MiB", b/1048576;
    else if (b >= 1024) printf "%.2f KiB", b/1024;
    else printf "%d B", b;
  }'
}

rate_bytes_human() {
  awk -v bps="${1:-0}" 'BEGIN {
    if (bps >= 125000000) printf "%.2f Gb/s", bps*8/1000000000;
    else if (bps >= 125000) printf "%.2f Mb/s", bps*8/1000000;
    else if (bps >= 125) printf "%.2f Kb/s", bps*8/1000;
    else printf "%.0f b/s", bps*8;
  }'
}

# Logs, process names and file paths are untrusted terminal content. Strip C0
# control bytes (including ESC) while preserving tabs/newlines so a hostile or
# corrupted string cannot inject terminal escape sequences into SYSdiag output.
sanitize_terminal_text() {
  # Remove common CSI escape sequences first so their printable payload does
  # not remain as noise, then strip every remaining C0 control byte/DEL.
  sed $'s/\033\[[0-9;?]*[ -\/]*[@-~]//g' | \
    LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' | \
    awk '{ if (length($0) > 600) print substr($0,1,597) "..."; else print }'
}

safe_read() {
  local file="$1"
  [[ -r "$file" ]] && cat "$file"
}

# Defensa en profundidad read-only para comandos externos lanzados por collectors.
# No intenta ser un parser de shell: run_with_timeout recibe argv ya separado y
# bloquea familias mutantes conocidas antes de llegar al binario real.
readonly_command_guard() {
  (( $# > 0 )) || return 1
  local cmd="${1##*/}" arg
  shift
  # `env KEY=value comando ...` es habitual para fijar locale; valida también
  # el comando real para que el wrapper no sea una vía de escape del guard.
  if [[ "$cmd" == env ]]; then
    local nested=("$@") i=0
    while (( i < ${#nested[@]} )); do
      case "${nested[$i]}" in
        --) ((i++)); break ;;
        -*) return 1 ;; # opciones de env no son necesarias en collectors
        [A-Za-z_][A-Za-z0-9_]*=*) ((i++)); continue ;;
        *) break ;;
      esac
    done
    (( i < ${#nested[@]} )) || return 1
    readonly_command_guard "${nested[@]:$i}"
    return $?
  fi
  case "$cmd" in
    rm|rmdir|mv|chmod|chown|chgrp|truncate|mount|umount|reboot|shutdown|poweroff|halt|kill|pkill|killall|apt|apt-get|dnf|yum|zypper|pacman)
      return 1 ;;
    systemctl)
      for arg in "$@"; do case "$arg" in start|stop|restart|reload|try-restart|reload-or-restart|enable|disable|reenable|mask|unmask|reset-failed|daemon-reload|daemon-reexec|isolate|set-default|edit|revert|preset|preset-all|poweroff|reboot|halt|suspend|hibernate) return 1;; esac; done ;;
    kubectl|oc)
      for arg in "$@"; do case "$arg" in apply|create|delete|patch|edit|replace|exec|debug|port-forward|cp|scale|autoscale|cordon|uncordon|drain|taint|label|annotate|set) return 1;; esac; done
      # `oc adm node-logs` es lectura; otras acciones mutantes conocidas de adm se bloquean.
      local prev=""
      for arg in "$@"; do
        if [[ "$prev" == adm ]]; then case "$arg" in drain|cordon|prune|upgrade|must-gather) return 1;; esac; fi
        prev="$arg"
      done ;;
    docker|podman)
      for arg in "$@"; do case "$arg" in start|stop|restart|kill|rm|rmi|run|create|exec|update|pause|unpause|pull|push|build|commit|rename|prune) return 1;; esac; done ;;
    sysctl)
      for arg in "$@"; do [[ "$arg" == -w || "$arg" == *=* ]] && return 1; done ;;
    ip)
      for arg in "$@"; do case "$arg" in add|delete|del|replace|change|append|set|flush) return 1;; esac; done ;;
    iptables|ip6tables)
      for arg in "$@"; do case "$arg" in -A|-D|-I|-R|-F|-X|-P|-N|-E|--append|--delete|--insert|--replace|--flush|--delete-chain|--policy|--new-chain|--rename-chain) return 1;; esac; done ;;
    nft)
      for arg in "$@"; do case "$arg" in add|delete|insert|replace|flush|reset) return 1;; esac; done ;;
    sed)
      for arg in "$@"; do [[ "$arg" == -i || "$arg" == -i* ]] && return 1; done ;;
    find)
      for arg in "$@"; do [[ "$arg" == -delete ]] && return 1; done ;;
  esac
  return 0
}

# Ejecuta un comando de lectura con timeout si coreutils 'timeout' está disponible.
# Devuelve la salida por stdout y conserva el código de retorno del comando/timeout.
# No usa eval ni shell implícita: los argumentos se pasan tal cual.
run_with_timeout() {
  local seconds="$1"
  shift
  if ! readonly_command_guard "$@"; then
    printf 'SYSdiag: operación bloqueada por política read-only: %q' "$1" >&2
    printf ' %q' "${@:2}" >&2
    printf '\n' >&2
    return 126
  fi
  if have_cmd timeout; then
    timeout --signal=TERM --kill-after=1 "${seconds}s" "$@"
  else
    "$@"
  fi
}

# Variante para comandos que necesitan una pipeline o redirección. El contenido es
# código interno de SYSdiag, nunca texto procedente del usuario. Aun así se aplica
# una defensa conservadora para impedir que una futura edición introduzca una
# mutación silenciosa por este camino.
readonly_shell_guard() {
  local script="${1:-}" normalized
  normalized=" ${script//$'\n'/ } "
  # Redirecciones sólo se permiten hacia /dev/null; el resto podría escribir.
  local without_devnull="$normalized"
  without_devnull="${without_devnull//2>\/dev\/null/}"
  without_devnull="${without_devnull//1>\/dev\/null/}"
  without_devnull="${without_devnull//>\/dev\/null/}"
  [[ "$without_devnull" != *'>'* ]] || return 1
  [[ "$without_devnull" != *'<'* ]] || return 1
  # Sustituciones/ejecución dinámica no son necesarias en los scripts internos.
  [[ "$normalized" != *'`'* && "$normalized" != *'$('* ]] || return 1
  local re='(^|[;&|[:space:]])(rm|rmdir|mv|chmod|chown|chgrp|truncate|mount|umount|reboot|shutdown|poweroff|halt|kill|pkill|killall|apt|apt-get|dnf|yum|zypper|pacman)([;&|[:space:]]|$)'
  [[ ! "$normalized" =~ $re ]] || return 1
  [[ ! "$normalized" =~ (^|[;&|[:space:]])systemctl[[:space:]]+(start|stop|restart|reload|enable|disable|mask|unmask|daemon-reload) ]] || return 1
  [[ ! "$normalized" =~ (^|[;&|[:space:]])(kubectl|oc)[[:space:]]+([^;&|]*[[:space:]])?(apply|create|delete|patch|edit|replace|exec|debug|port-forward|scale|drain|cordon)([;&|[:space:]]|$) ]] || return 1
  [[ ! "$normalized" =~ (^|[;&|[:space:]])(docker|podman)[[:space:]]+([^;&|]*[[:space:]])?(rm|rmi|run|create|exec|restart|stop|kill|prune)([;&|[:space:]]|$) ]] || return 1
  [[ ! "$normalized" =~ [[:space:]]-delete([;&|[:space:]]|$) ]] || return 1
  return 0
}

run_shell_with_timeout() {
  local seconds="$1" script="$2"
  if ! readonly_shell_guard "$script"; then
    printf 'SYSdiag: pipeline bloqueada por política read-only.\n' >&2
    return 126
  fi
  if have_cmd timeout; then
    timeout --signal=TERM --kill-after=1 "${seconds}s" bash --noprofile --norc -c "$script"
  else
    bash --noprofile --norc -c "$script"
  fi
}

# Evita que un contador que se reinicia o desborda produzca deltas negativos.
count_delta() {
  local before="${1:-0}" after="${2:-0}"
  if [[ "$before" =~ ^[0-9]+$ && "$after" =~ ^[0-9]+$ ]] && (( after >= before )); then
    printf '%d' $((after-before))
  else
    printf '0'
  fi
}

# ===== lib/output.sh =====

init_output() {
  if [[ ${NO_COLOR:-0} -eq 1 || ! -t 1 ]]; then
    C_RESET=''; C_BOLD=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_CYAN=''
  else
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m';
    C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_CYAN=$'\033[36m'
  fi

  DISPLAY_UTF8_LOCALE=""
  if have_cmd locale; then
    DISPLAY_UTF8_LOCALE="$(locale -a 2>/dev/null | awk '
      BEGIN{IGNORECASE=1}
      /^C\.UTF-?8$/ || /^C\.utf8$/ {print; exit}
      /UTF-?8$/ || /utf8$/ {print; exit}
    ')"
  fi

  TERM_WIDTH=120
  if [[ -t 1 ]] && have_cmd tput; then
    local cols
    cols="$(tput cols 2>/dev/null || true)"
    [[ "$cols" =~ ^[0-9]+$ ]] && (( cols >= 40 )) && TERM_WIDTH="$cols"
  fi
  (( TERM_WIDTH > 140 )) && TERM_WIDTH=140
  if (( TERM_WIDTH < 96 )); then
    OUTPUT_LAYOUT="compact"
  else
    OUTPUT_LAYOUT="normal"
  fi
}

hr() {
  local width="${1:-$TERM_WIDTH}" line="" i
  (( width > 100 )) && width=100
  (( width < 50 )) && width=50
  for ((i=0; i<width; i++)); do line+="─"; done
  printf '%s\n' "$line"
}

section() {
  printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"
  hr
}

subsection() {
  printf '\n  %s%s%s\n' "$C_BOLD" "$1" "$C_RESET"
  printf '  '
  hr $((TERM_WIDTH-2))
}

_display_len() {
  local text="$1"
  if [[ -n "${DISPLAY_UTF8_LOCALE:-}" ]]; then
    local LC_CTYPE="$DISPLAY_UTF8_LOCALE"
    printf '%d' "${#text}"
  else
    printf '%d' "${#text}"
  fi
}

kv_at() {
  local indent="$1" width="$2" label="$3" value="$4"
  local len pad
  len="$(_display_len "$label")"
  pad=$(( width - len ))
  (( pad < 1 )) && pad=1
  printf '%*s%s%*s%s\n' "$indent" '' "$label" "$pad" '' "$value"
}

kv() { kv_at 2 30 "$1" "$2"; }

status_label() {
  local s="$1"
  case "$s" in
    OK) printf '%sOK%s' "$C_GREEN" "$C_RESET" ;;
    INFO) printf '%sINFO%s' "$C_CYAN" "$C_RESET" ;;
    LIMITED) printf '%sLIMITADO%s' "$C_CYAN" "$C_RESET" ;;
    WARNING) printf '%sWARNING%s' "$C_YELLOW" "$C_RESET" ;;
    CRITICAL) printf '%sCRITICAL%s' "$C_RED" "$C_RESET" ;;
    *) printf '%s' "$s" ;;
  esac
}

print_banner() {
  printf '%sSYSdiag %s%s - Asistente de diagnóstico de sistemas y plataformas de solo lectura\n' "$C_BOLD" "$SYS_DIAG_VERSION" "$C_RESET"
  printf 'Autor: Chus (GitHub: chus87)\n'
  printf 'Fecha: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
  printf 'Muestra temporal: %ss | Salida: %s\n' "${SAMPLE_SECONDS:-1}" "${OUTPUT_LAYOUT:-normal}"
}

note() { printf '  [%s] %s\n' "$(status_label INFO)" "$*"; }
warn() { printf '  [%s] %s\n' "$(status_label WARNING)" "$*"; }
critical() { printf '  [%s] %s\n' "$(status_label CRITICAL)" "$*"; }

# ===== lib/scoring.sh =====

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

# ===== lib/sampler.sh =====

# Shared sampler: CPU, swap, network and TCP counters are measured over the same
# time window. iostat, when available and requested, runs concurrently.

_sampler_cpu_line() { awk '/^cpu /{print; exit}' /proc/stat 2>/dev/null; }
_sampler_swap_line() {
  awk '$1=="pswpin"{a=$2} $1=="pswpout"{b=$2} END{printf "%d %d\n",a+0,b+0}' /proc/vmstat 2>/dev/null
}
_sampler_tcp_value() {
  local file="$1" group="$2" key="$3"
  [[ -r "$file" ]] || { printf '0'; return; }
  awk -v grp="$group" -v key="$key" '
    $1==grp":" && !header {for(i=2;i<=NF;i++) n[i]=$i; header=1; next}
    $1==grp":" && header {for(i=2;i<=NF;i++) if(n[i]==key){print $i; found=1; exit}}
    END{if(!found) print 0}
  ' "$file" 2>/dev/null
}
_sampler_tcp_line() {
  printf '%s %s %s %s\n' \
    "$(_sampler_tcp_value /proc/net/snmp Tcp RetransSegs)" \
    "$(_sampler_tcp_value /proc/net/netstat TcpExt TCPSynRetrans)" \
    "$(_sampler_tcp_value /proc/net/netstat TcpExt ListenOverflows)" \
    "$(_sampler_tcp_value /proc/net/netstat TcpExt ListenDrops)"
}
_sampler_snmp6_value() {
  local key="$1"
  [[ -r /proc/net/snmp6 ]] || { printf '0'; return; }
  awk -v key="$key" '$1==key{print $2; found=1; exit} END{if(!found) print 0}' /proc/net/snmp6 2>/dev/null
}
_sampler_pmtu_line() {
  # Contadores pasivos: SYSdiag no genera tráfico de prueba automáticamente.
  printf '%s %s %s %s %s %s\n' \
    "$(_sampler_tcp_value /proc/net/snmp Ip FragFails)" \
    "$(_sampler_snmp6_value Ip6FragFails)" \
    "$(_sampler_snmp6_value Ip6InTooBigErrors)" \
    "$(_sampler_snmp6_value Icmp6InPktTooBigs)" \
    "$(_sampler_tcp_value /proc/net/netstat TcpExt TCPMTUPFail)" \
    "$(_sampler_tcp_value /proc/net/netstat TcpExt TCPMTUPSuccess)"
}
_sampler_softnet_line() {
  local dropped=0 squeeze=0 line p d s rest
  [[ -r /proc/net/softnet_stat ]] || { printf '0 0'; return; }
  while read -r p d s rest; do
    [[ -n "$d" ]] || continue
    dropped=$(( dropped + 16#${d} ))
    squeeze=$(( squeeze + 16#${s} ))
  done < /proc/net/softnet_stat
  printf '%d %d\n' "$dropped" "$squeeze"
}

_sampler_net_snapshot() {
  local path iface
  [[ -d /sys/class/net ]] || return 0
  for path in /sys/class/net/*; do
    [[ -e "$path" ]] || continue
    iface="${path##*/}"
    [[ "$iface" == "lo" ]] && continue
    printf '%s %s %s %s %s %s %s\n' "$iface" \
      "$(safe_read "$path/statistics/rx_dropped" || echo 0)" \
      "$(safe_read "$path/statistics/tx_dropped" || echo 0)" \
      "$(safe_read "$path/statistics/rx_errors" || echo 0)" \
      "$(safe_read "$path/statistics/tx_errors" || echo 0)" \
      "$(safe_read "$path/statistics/rx_bytes" || echo 0)" \
      "$(safe_read "$path/statistics/tx_bytes" || echo 0)"
  done
}

ensure_shared_sample() {
  local want_iostat="${1:-0}"
  if (( ${SHARED_SAMPLE_READY:-0} )); then
    if (( want_iostat )) && (( ${SHARED_SAMPLE_IOSTAT_REQUESTED:-0} == 0 )); then
      # Do not silently fabricate an aligned iostat sample after the common
      # window has already finished. Callers should plan requirements first.
      add_limitation "La ventana compartida ya se tomó sin iostat; no se remuestrea para evitar mezclar periodos distintos."
    fi
    return 0
  fi
  SHARED_SAMPLE_READY=1
  SHARED_SAMPLE_IOSTAT_REQUESTED=$(( want_iostat ? 1 : 0 ))
  SAMPLE_SECONDS="${SAMPLE_SECONDS:-1}"

  SAMPLE_CPU_A="$(_sampler_cpu_line)"
  SAMPLE_SWAP_A="$(_sampler_swap_line)"
  SAMPLE_TCP_A="$(_sampler_tcp_line)"
  SAMPLE_PMTU_A="$(_sampler_pmtu_line)"
  SAMPLE_SOFTNET_A="$(_sampler_softnet_line)"
  SAMPLE_NET_A="$(_sampler_net_snapshot)"
  SAMPLE_EPOCH_A="$(date +%s 2>/dev/null || echo 0)"

  SAMPLE_IOSTAT_FILE=""
  local iostat_pid=""
  if (( want_iostat )) && have_cmd iostat; then
    SAMPLE_IOSTAT_FILE="${RUNTIME_DIR:-/tmp}/iostat.raw"
    ( run_with_timeout "$((SAMPLE_SECONDS+4))" env LC_ALL=C iostat -dx "$SAMPLE_SECONDS" 2 >"$SAMPLE_IOSTAT_FILE" 2>/dev/null ) &
    iostat_pid=$!
  fi

  sleep "$SAMPLE_SECONDS"

  SAMPLE_CPU_B="$(_sampler_cpu_line)"
  SAMPLE_SWAP_B="$(_sampler_swap_line)"
  SAMPLE_TCP_B="$(_sampler_tcp_line)"
  SAMPLE_PMTU_B="$(_sampler_pmtu_line)"
  SAMPLE_SOFTNET_B="$(_sampler_softnet_line)"
  SAMPLE_NET_B="$(_sampler_net_snapshot)"
  SAMPLE_EPOCH_B="$(date +%s 2>/dev/null || echo 0)"

  if [[ -n "$iostat_pid" ]]; then
    wait "$iostat_pid" 2>/dev/null || true
  fi
}

# ===== modules/system.sh =====

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

# ===== modules/cpu.sh =====

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

# ===== modules/processes.sh =====

collect_process_states() {
  PROC_R=0; PROC_S=0; PROC_D=0; PROC_Z=0; PROC_T=0; PROC_OTHER=0
  local snapshot
  snapshot="$(ps -eo pid=,ppid=,user=,stat=,comm=,wchan:32= 2>/dev/null)"
  while read -r stat; do
    case "${stat:0:1}" in R)((PROC_R++))||true;; S)((PROC_S++))||true;; D)((PROC_D++))||true;; Z)((PROC_Z++))||true;; T|t)((PROC_T++))||true;; *)((PROC_OTHER++))||true;; esac
  done < <(awk '{print $4}' <<<"$snapshot")

  D_DETAILS="$(awk '$4~/^D/{printf "%s|%s|%s|%s|%s|%s\n",$1,$2,$3,$4,$5,$6}' <<<"$snapshot" | head -n 30)"
  Z_DETAILS="$(awk '
    {n++;pid[n]=$1;ppid[n]=$2;user[n]=$3;stat[n]=$4;comm[n]=$5;cmd[$1]=$5}
    END{shown=0;for(i=1;i<=n&&shown<30;i++)if(stat[i]~/^Z/){parent=(cmd[ppid[i]]!=""?cmd[ppid[i]]:"<no-visible>");printf "%s|%s|%s|%s|%s|%s\n",pid[i],ppid[i],user[i],stat[i],comm[i],parent;shown++}}' <<<"$snapshot")"
}

analyze_processes() {
  if (( PROC_D >= 10 )); then
    add_finding IO_BLOCKED_TASKS io blocked_tasks 3 high "Número significativo de procesos D (${PROC_D})."
  elif (( PROC_D > 0 )); then
    add_finding IO_BLOCKED_TASKS io blocked_tasks 1 low "Se han encontrado ${PROC_D} procesos en estado D."
  fi
  if (( PROC_D > 0 )); then
    add_next_step "Revisar procesos D y qué recurso del kernel esperan (wchan/stack)." \
      "ps -eo pid,ppid,user,stat,comm,wchan:32 | awk '\$4 ~ /^D/'" "cat /proc/<PID>/wchan" "sudo cat /proc/<PID>/stack" "lsof -p <PID>"
  fi

  if (( PROC_Z > 0 )); then
    local impact=low points=1
    ((PROC_Z>=100)) && { impact=medium; points=3; }
    add_finding PROC_ZOMBIES processes zombies "$points" "$impact" "Se han encontrado ${PROC_Z} procesos zombie."
    add_next_step "Investigar el padre de cada zombie: el hijo ya terminó; el padre no ha recogido su estado." \
      "ps -eo pid,ppid,user,stat,comm | awk '\$4 ~ /^Z/'" "ps -fp <PPID>" "pstree -sp <PID>"
  fi
}

print_processes() {
  section "PROCESOS"
  kv "R - runnable:" "$PROC_R"; kv "S - sleeping:" "$PROC_S"; kv "D - uninterruptible:" "$PROC_D"; kv "Z - zombie:" "$PROC_Z"; kv "T - stopped:" "$PROC_T"

  if ((PROC_D>0)); then
    printf '\n  Procesos D (máx. 30):\n'
    if [[ "${OUTPUT_LAYOUT:-normal}" == "compact" ]]; then
      printf '    %7s %7s %-5s %-20s %s\n' PID PPID STAT COMMAND WCHAN
      while IFS='|' read -r pid ppid user stat command wchan; do [[ -n "$pid" ]] && printf '    %7s %7s %-5s %-20s %s\n' "$pid" "$ppid" "$stat" "$command" "$wchan"; done <<<"$D_DETAILS"
    else
      printf '    %7s  %7s  %-16s  %-6s  %-24s  %s\n' PID PPID USER STAT COMMAND WCHAN
      while IFS='|' read -r pid ppid user stat command wchan; do [[ -n "$pid" ]] && printf '    %7s  %7s  %-16s  %-6s  %-24s  %s\n' "$pid" "$ppid" "$user" "$stat" "$command" "$wchan"; done <<<"$D_DETAILS"
    fi
  fi

  if ((PROC_Z>0)); then
    printf '\n  Zombies y sus padres (máx. 30):\n'
    if [[ "${OUTPUT_LAYOUT:-normal}" == "compact" ]]; then
      printf '    %7s %7s %-5s %-20s %s\n' PID PPID STAT ZOMBIE PARENT
      while IFS='|' read -r pid ppid user stat zombie parent; do [[ -n "$pid" ]] && printf '    %7s %7s %-5s %-20s %s\n' "$pid" "$ppid" "$stat" "$zombie" "$parent"; done <<<"$Z_DETAILS"
    else
      printf '    %7s  %7s  %-16s  %-6s  %-24s  %s\n' PID PPID USER STAT ZOMBIE PARENT
      while IFS='|' read -r pid ppid user stat zombie parent; do [[ -n "$pid" ]] && printf '    %7s  %7s  %-16s  %-6s  %-24s  %s\n' "$pid" "$ppid" "$user" "$stat" "$zombie" "$parent"; done <<<"$Z_DETAILS"
    fi
  fi

  if (( ${EXPLAIN:-0} == 1 )); then
    printf '\n  Explicación:\n'
    printf '    - R: ejecutándose o preparado para CPU. S: dormido esperando evento.\n'
    printf '    - D: espera no interrumpible; suele justificar revisar I/O/storage/NFS/drivers.\n'
    printf '    - Z: ya terminó; SYSdiag muestra también su PPID y el nombre del padre.\n'
  fi
}

# ===== modules/memory.sh =====

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

# ===== modules/io.sh =====

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

# ===== modules/filesystem.sh =====

is_virtual_fs_type() {
  case "$1" in
    tmpfs|devtmpfs|proc|sysfs|devpts|cgroup|cgroup2|pstore|securityfs|debugfs|tracefs|configfs|fusectl|mqueue|hugetlbfs|rpc_pipefs|nsfs) return 0 ;;
    *) return 1 ;;
  esac
}

is_readonly_image_fs() {
  local source="${1:-}" fstype="${2:-}" mountpoint="${3:-}"
  case "$fstype" in squashfs|fuse.AppImage|fuse.appimage|fuse2.AppImage|fuse2.appimage) return 0;; esac
  case "$source" in *.AppImage|*.appimage) return 0;; esac
  case "$mountpoint" in /tmp/.mount_*|/run/user/*/.mount_*) return 0;; esac
  return 1
}

parse_deleted_open_lsof() {
  local raw="$1"
  DELETED_OPEN_DESCRIPTOR_COUNT=0; DELETED_OPEN_UNIQUE_COUNT=0; DELETED_OPEN_DISK_UNIQUE_COUNT=0
  DELETED_OPEN_EPHEMERAL_UNIQUE_COUNT=0; DELETED_OPEN_RETAINED_BYTES=0; DELETED_OPEN_MAX_BYTES=0
  DELETED_OPEN_DETAILS=""
  [[ -n "$raw" ]] || return 0

  DELETED_OPEN_DETAILS="$(printf '%s\n' "$raw" | head -n 31)"
  read -r DELETED_OPEN_DESCRIPTOR_COUNT DELETED_OPEN_UNIQUE_COUNT DELETED_OPEN_DISK_UNIQUE_COUNT DELETED_OPEN_EPHEMERAL_UNIQUE_COUNT DELETED_OPEN_RETAINED_BYTES DELETED_OPEN_MAX_BYTES < <(
    awk '
      NR==1 {
        for(i=1;i<=NF;i++){if($i=="TYPE")t=i; if($i=="DEVICE")d=i; if($i=="SIZE/OFF")s=i; if($i=="NODE")ino=i; if($i=="NAME")name=i}
        next
      }
      NF {
        desc++
        if(!t||!d||!ino) next
        typ=$t; dev=$d; node=$ino; key=dev":"node":"typ
        nm=""; if(name){for(i=name;i<=NF;i++)nm=nm (i==name?"":" ") $i}
        ephemeral=(nm ~ /(^|\/)memfd:/ || nm ~ /^\/dev\/shm\//)
        if(!(key in seen)){
          seen[key]=1; unique++
          if(ephemeral){ephem++}
          else if(typ=="REG"){
            disk++
            v=(s?$s:0)
            if(v ~ /^[0-9]+$/){total+=v; if(v>max)max=v}
          }
        }
      }
      END{printf "%d %d %d %d %.0f %.0f\n",desc+0,unique+0,disk+0,ephem+0,total+0,max+0}
    ' <<<"$raw"
  )
}

collect_filesystem() {
  FS_SPACE_TABLE="Filesystem Type Size Used Avail Use% Mounted_on"$'\n'; FS_INODE_TABLE="Filesystem Type Inodes IUsed IFree IUse% Mounted_on"$'\n'
  FS_IMAGE_TABLE=""; FS_IGNORED_IMAGE_COUNT=0
  local raw_space raw_inode rc=0
  raw_space="$(run_with_timeout 6 df -PTh 2>/dev/null)" || rc=$?
  if ((rc==124)); then add_limitation "La consulta df -hT superó 6s (posible mount lento/caído); tabla de filesystems puede ser incompleta."; raw_space=""; fi
  rc=0; raw_inode="$(run_with_timeout 6 df -PTi 2>/dev/null)" || rc=$?
  if ((rc==124)); then add_limitation "La consulta df -i superó 6s; análisis de inodos puede ser incompleto."; raw_inode=""; fi

  local source fstype size used avail usep mountpoint
  while read -r source fstype size used avail usep mountpoint; do
    [[ "$source" == "Filesystem" || -z "$source" ]] && continue
    is_virtual_fs_type "$fstype" && continue
    if is_readonly_image_fs "$source" "$fstype" "$mountpoint"; then
      FS_IMAGE_TABLE+="${source} ${fstype} ${size} ${used} ${avail} ${usep} ${mountpoint}"$'\n'; ((FS_IGNORED_IMAGE_COUNT++))||true; continue
    fi
    FS_SPACE_TABLE+="${source} ${fstype} ${size} ${used} ${avail} ${usep} ${mountpoint}"$'\n'
  done <<<"$raw_space"

  local inodes iused ifree iusep
  while read -r source fstype inodes iused ifree iusep mountpoint; do
    [[ "$source" == "Filesystem" || -z "$source" ]] && continue
    is_virtual_fs_type "$fstype" && continue
    is_readonly_image_fs "$source" "$fstype" "$mountpoint" && continue
    FS_INODE_TABLE+="${source} ${fstype} ${inodes} ${iused} ${ifree} ${iusep} ${mountpoint}"$'\n'
  done <<<"$raw_inode"

  FINDMNT_AVAILABLE=0; MOUNT_TABLE=""; REAL_MOUNT_COUNT=0
  if have_cmd findmnt; then
    FINDMNT_AVAILABLE=1; rc=0
    MOUNT_TABLE="$(run_with_timeout 4 findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null)" || rc=$?
    if ((rc==124)); then add_limitation "La consulta findmnt superó 4s; topología de mounts omitida."; MOUNT_TABLE=""; fi
    MOUNT_TABLE="$(awk '$3 !~ /^(proc|sysfs|devtmpfs|tmpfs|devpts|cgroup2?|pstore|securityfs|debugfs|tracefs|configfs|fusectl|mqueue|hugetlbfs|rpc_pipefs|nsfs)$/' <<<"$MOUNT_TABLE")"
    REAL_MOUNT_COUNT="$(printf '%s\n' "$MOUNT_TABLE" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  fi

  FS_MAX_USE=0; FS_MAX_USE_MOUNT=""; FS_MAX_USE_SOURCE=""; FS_HIGH_COUNT=0; FS_CRIT_COUNT=0
  while read -r source fstype size used avail usep mountpoint; do
    [[ "$source" == "Filesystem" || -z "$source" ]] && continue
    local pct=${usep%%%}; [[ "$pct" =~ ^[0-9]+$ ]] || continue
    ((pct>FS_MAX_USE)) && { FS_MAX_USE=$pct; FS_MAX_USE_MOUNT=$mountpoint; FS_MAX_USE_SOURCE=$source; }
    ((pct>=85)) && ((FS_HIGH_COUNT++))||true; ((pct>=95)) && ((FS_CRIT_COUNT++))||true
  done <<<"$FS_SPACE_TABLE"

  FS_MAX_INODE_USE=0; FS_MAX_INODE_MOUNT=""; FS_INODE_HIGH_COUNT=0; FS_INODE_CRIT_COUNT=0
  while read -r source fstype inodes iused ifree iusep mountpoint; do
    [[ "$source" == "Filesystem" || -z "$source" ]] && continue
    local pct=${iusep%%%}; [[ "$pct" =~ ^[0-9]+$ ]] || continue
    ((pct>FS_MAX_INODE_USE)) && { FS_MAX_INODE_USE=$pct; FS_MAX_INODE_MOUNT=$mountpoint; }
    ((pct>=85)) && ((FS_INODE_HIGH_COUNT++))||true; ((pct>=95)) && ((FS_INODE_CRIT_COUNT++))||true
  done <<<"$FS_INODE_TABLE"

  LSOF_AVAILABLE=0; DELETED_OPEN_DETAILS=""; DELETED_OPEN_DESCRIPTOR_COUNT=0; DELETED_OPEN_UNIQUE_COUNT=0; DELETED_OPEN_DISK_UNIQUE_COUNT=0
  DELETED_OPEN_EPHEMERAL_UNIQUE_COUNT=0; DELETED_OPEN_RETAINED_BYTES=0; DELETED_OPEN_MAX_BYTES=0
  if have_cmd lsof; then
    LSOF_AVAILABLE=1; local raw_lsof=""; rc=0
    raw_lsof="$(run_with_timeout 6 lsof -nP +L1 2>/dev/null)" || rc=$?
    if ((rc==124)); then add_limitation "La consulta lsof +L1 superó 6s; comprobación de ficheros borrados omitida."; LSOF_AVAILABLE=2
    else parse_deleted_open_lsof "$raw_lsof"; fi
  fi
}

analyze_filesystem() {
  if ((FS_CRIT_COUNT>0)); then
    local imp=high; ((FS_MAX_USE>=99)) && imp=critical
    add_finding FS_SPACE filesystem space 5 "$imp" "${FS_CRIT_COUNT} filesystem(s) al 95% o más; máximo ${FS_MAX_USE}% en ${FS_MAX_USE_MOUNT}."
    add_next_step "Priorizar ${FS_MAX_USE_MOUNT}: comprobar ocupación y ficheros borrados abiertos antes de borrar a ciegas." \
      "df -hT ${FS_MAX_USE_MOUNT}" "du -xhd1 ${FS_MAX_USE_MOUNT} 2>/dev/null | sort -h" "lsof +L1"
  elif ((FS_HIGH_COUNT>0)); then
    add_finding FS_SPACE filesystem space 2 medium "${FS_HIGH_COUNT} filesystem(s) al 85% o más; máximo ${FS_MAX_USE}% en ${FS_MAX_USE_MOUNT}."
    add_next_step "Revisar crecimiento y contenido de ${FS_MAX_USE_MOUNT}; SYSdiag no ejecuta du recursivo automáticamente." \
      "df -hT ${FS_MAX_USE_MOUNT}" "du -xhd1 ${FS_MAX_USE_MOUNT} 2>/dev/null | sort -h"
  fi

  if ((FS_INODE_CRIT_COUNT>0)); then
    add_finding FS_INODES filesystem inodes 5 high "${FS_INODE_CRIT_COUNT} filesystem(s) con >=95% de inodos; máximo ${FS_MAX_INODE_USE}% en ${FS_MAX_INODE_MOUNT}."
    add_next_step "Localizar zonas con enormes cantidades de ficheros pequeños en ${FS_MAX_INODE_MOUNT}." \
      "df -i ${FS_MAX_INODE_MOUNT}" "find ${FS_MAX_INODE_MOUNT} -xdev -type f -printf '%h\\n' 2>/dev/null | sort | uniq -c | sort -n | tail -n 30"
  elif ((FS_INODE_HIGH_COUNT>0)); then
    add_finding FS_INODES filesystem inodes 2 medium "Uso de inodos elevado: máximo ${FS_MAX_INODE_USE}% en ${FS_MAX_INODE_MOUNT}."
  fi

  if ((LSOF_AVAILABLE==0)); then
    add_next_step "Lsof no está disponible: no puedo comprobar automáticamente ficheros borrados aún abiertos." \
      "command -v lsof" "apt-cache policy lsof 2>/dev/null" "dnf info lsof 2>/dev/null"
  elif ((LSOF_AVAILABLE==1 && DELETED_OPEN_DISK_UNIQUE_COUNT>0)); then
    local points=1 imp=low
    if ((DELETED_OPEN_RETAINED_BYTES>=1073741824)); then points=4; imp=high
    elif ((DELETED_OPEN_RETAINED_BYTES>=104857600)); then points=2; imp=medium; fi
    add_finding FS_DELETED_OPEN filesystem deleted_open "$points" "$imp" \
      "${DELETED_OPEN_DISK_UNIQUE_COUNT} fichero(s) regular(es) únicos borrados siguen abiertos; ~$(bytes_to_human "$DELETED_OPEN_RETAINED_BYTES") retenidos (descriptores: ${DELETED_OPEN_DESCRIPTOR_COUNT})."
    add_next_step "Identificar proceso/fichero borrado. Intentar reload/reopen o cierre controlado antes de reiniciar; no usar kill -9 como primera medida." \
      "lsof -nP +L1" "ps -fp <PID>" "systemctl status <servicio>" "journalctl -u <servicio> --since '-30 min'"
  fi

  if ((FS_MAX_USE>=95 && DELETED_OPEN_RETAINED_BYTES>=104857600)); then
    add_finding FS_SPACE_DELETED_CORR filesystem correlation 3 high "Filesystem casi lleno junto con espacio retenido por ficheros borrados abiertos: posible explicación de df != du."
  fi

  if ((FS_MAX_USE>=85 && FINDMNT_AVAILABLE==1 && REAL_MOUNT_COUNT>1)); then
    add_next_step "Si du no explica df, revisar mounts anidados: puede haber datos ocultos bajo un punto de montaje. SYSdiag no desmonta ni crea mounts." \
      "findmnt" "findmnt -T ${FS_MAX_USE_MOUNT}" "mountpoint ${FS_MAX_USE_MOUNT}" "df -hT ${FS_MAX_USE_MOUNT}"
  fi
}

print_filesystem() {
  section "FILESYSTEMS"
  kv "Mayor uso de espacio:" "${FS_MAX_USE}% (${FS_MAX_USE_MOUNT:-n/d})"; kv "Mayor uso de inodos:" "${FS_MAX_INODE_USE}% (${FS_MAX_INODE_MOUNT:-n/d})"
  kv "FS >=85% / >=95%:" "${FS_HIGH_COUNT} / ${FS_CRIT_COUNT}"; kv "Inodos >=85% / >=95%:" "${FS_INODE_HIGH_COUNT} / ${FS_INODE_CRIT_COUNT}"
  kv "Imágenes RO ignoradas:" "$FS_IGNORED_IMAGE_COUNT (AppImage/SquashFS; 100% puede ser normal)"
  ((FINDMNT_AVAILABLE==1)) && kv "Mounts reales detectados:" "$REAL_MOUNT_COUNT" || kv "Topología de mounts:" "findmnt no disponible"

  if ((LSOF_AVAILABLE==1)); then
    kv "Descriptores deleted/open:" "$DELETED_OPEN_DESCRIPTOR_COUNT"
    kv "Ficheros únicos deleted/open:" "$DELETED_OPEN_UNIQUE_COUNT"
    kv "Regulares en disco:" "$DELETED_OPEN_DISK_UNIQUE_COUNT"
    kv "Temporales/memfd separados:" "$DELETED_OPEN_EPHEMERAL_UNIQUE_COUNT"
    ((DELETED_OPEN_DISK_UNIQUE_COUNT>0)) && kv "Espacio único retenido:" "$(bytes_to_human "$DELETED_OPEN_RETAINED_BYTES")"
    ((DELETED_OPEN_DISK_UNIQUE_COUNT>0)) && kv "Mayor fichero detectado:" "$(bytes_to_human "$DELETED_OPEN_MAX_BYTES")"
  elif ((LSOF_AVAILABLE==2)); then kv "Comprobación lsof +L1:" "timeout (omitida)"
  else kv "Comprobación lsof +L1:" "no disponible (falta lsof)"; fi

  if (( ${VERBOSE:-0} == 1 )); then
    printf '\n  df -h (excluye pseudo-FS e imágenes read-only):\n'; while IFS= read -r line; do [[ -n "$line" ]] && printf '    %s\n' "$line"; done <<<"$FS_SPACE_TABLE"
    printf '\n  df -i (excluye pseudo-FS e imágenes read-only):\n'; while IFS= read -r line; do [[ -n "$line" ]] && printf '    %s\n' "$line"; done <<<"$FS_INODE_TABLE"
    if ((FS_IGNORED_IMAGE_COUNT>0)); then printf '\n  AppImage/SquashFS ignorados para alertas:\n'; while IFS= read -r line; do [[ -n "$line" ]] && printf '    %s\n' "$line"; done <<<"$FS_IMAGE_TABLE"; fi
    if ((FINDMNT_AVAILABLE==1)) && [[ -n "$MOUNT_TABLE" ]]; then printf '\n  Topología de mounts:\n'; while IFS= read -r line; do printf '    %s\n' "$line"; done <<<"$MOUNT_TABLE"; fi
    if ((DELETED_OPEN_DESCRIPTOR_COUNT>0)); then printf '\n  lsof +L1 (máx. 30 entradas):\n'; while IFS= read -r line; do [[ -n "$line" ]] && printf '    %s\n' "$line"; done <<<"$DELETED_OPEN_DETAILS"; fi
  fi

  if (( ${EXPLAIN:-0} == 1 )); then
    printf '\n  Explicación:\n'
    printf '    - df pregunta al filesystem; du recorre ficheros visibles. Un deleted/open puede explicar diferencias.\n'
    printf '    - SYSdiag deduplica lsof por dispositivo+inode para no confundir muchos descriptores con muchos ficheros.\n'
    printf '    - memfd y /dev/shm se separan del espacio regular de disco para reducir falsos positivos.\n'
    printf '    - AppImage/SquashFS read-only se excluyen de las alertas de 100%%.\n'
    printf '    - df/findmnt/lsof tienen timeout para que un mount enfermo no bloquee indefinidamente el diagnóstico.\n'
  fi
}

# ===== modules/network.sh =====

# Network diagnostics. Read-only and based on the common sampling window.

_net_value() { local f="$1" fb="${2:-n/d}"; [[ -r "$f" ]] && cat "$f" 2>/dev/null || printf '%s' "$fb"; }
_net_kind() {
  local iface="$1" ifindex iflink
  [[ "$iface" == lo ]] && { printf 'loopback'; return; }
  ifindex="$(_net_value "/sys/class/net/$iface/ifindex" '')"
  iflink="$(_net_value "/sys/class/net/$iface/iflink" '')"
  # En veth (incluidos contenedores) iflink suele apuntar al peer y difiere de ifindex.
  if [[ "$ifindex" =~ ^[0-9]+$ && "$iflink" =~ ^[0-9]+$ && "$ifindex" != "$iflink" ]]; then
    printf 'virtual'; return
  fi
  [[ -e "/sys/class/net/$iface/device" ]] && printf 'NIC' || printf 'virtual'
}
_net_ipv4() { have_cmd ip && ip -o -4 addr show dev "$1" scope global 2>/dev/null | awk 'NR==1{print $4;exit}'; }
_net_ipv6() { have_cmd ip && ip -o -6 addr show dev "$1" scope global 2>/dev/null | awk 'NR==1{print $4;exit}'; }

collect_network() {
  NETWORK_AVAILABLE=1; [[ -d /sys/class/net ]] || NETWORK_AVAILABLE=0
  IP_AVAILABLE=0; SS_AVAILABLE=0; have_cmd ip && IP_AVAILABLE=1; have_cmd ss && SS_AVAILABLE=1
  ensure_shared_sample 0
  NET_SAMPLE_SECONDS="${SAMPLE_SECONDS:-1}"

  NET_IFACE_COUNT=0; NET_UP_COUNT=0; NET_DEFAULT4=""; NET_DEFAULT6=""; NET_DEFAULT4_IFACE=""; NET_DEFAULT6_IFACE=""; NET_PRIMARY_IFACE=""
  NET_IF_TABLE=""; NET_ADDR_TABLE=""; NET_RX_DROP_TOTAL=0; NET_TX_DROP_TOTAL=0; NET_RX_ERR_TOTAL=0; NET_TX_ERR_TOTAL=0
  NET_RX_DROP_DELTA=0; NET_TX_DROP_DELTA=0; NET_RX_ERR_DELTA=0; NET_TX_ERR_DELTA=0; NET_RX_BYTES_DELTA=0; NET_TX_BYTES_DELTA=0
  NET_PRIMARY_RX_BPS=0; NET_PRIMARY_TX_BPS=0; NET_PRIMARY_RX_UTIL_PCT=0; NET_PRIMARY_TX_UTIL_PCT=0
  NET_UP_MTU_MIN=0; NET_UP_MTU_MAX=0; NET_UP_MTU_VARIANTS=0; NET_LOWER_MTU_IFACES=""
  NET_TCP_MTU_PROBING="$(_net_value /proc/sys/net/ipv4/tcp_mtu_probing n/d)"
  NET_TCP_BASE_MSS="$(_net_value /proc/sys/net/ipv4/tcp_base_mss n/d)"
  NET_FRAG_FAIL_DELTA=0; NET_IP6_FRAG_FAIL_DELTA=0; NET_IP6_TOO_BIG_DELTA=0; NET_ICMP6_PTB_DELTA=0; NET_TCP_MTUP_FAIL_DELTA=0; NET_TCP_MTUP_SUCCESS_DELTA=0

  IP_ROUTE4_TABLE=""; IP_ROUTE6_TABLE=""
  if ((IP_AVAILABLE)); then
    local rc=0
    IP_ROUTE4_TABLE="$(run_with_timeout 3 ip -4 route show 2>/dev/null)" || rc=$?; ((rc==124)) && { add_limitation "La consulta ip -4 route superó 3s."; IP_ROUTE4_TABLE=""; }
    rc=0; IP_ROUTE6_TABLE="$(run_with_timeout 3 ip -6 route show 2>/dev/null)" || rc=$?; ((rc==124)) && { add_limitation "La consulta ip -6 route superó 3s."; IP_ROUTE6_TABLE=""; }
    NET_DEFAULT4="$(awk '$1=="default"{print;exit}' <<<"$IP_ROUTE4_TABLE")"; NET_DEFAULT6="$(awk '$1=="default"{print;exit}' <<<"$IP_ROUTE6_TABLE")"
    NET_DEFAULT4_IFACE="$(awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}' <<<"$NET_DEFAULT4")"
    NET_DEFAULT6_IFACE="$(awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}' <<<"$NET_DEFAULT6")"
    NET_PRIMARY_IFACE="${NET_DEFAULT4_IFACE:-${NET_DEFAULT6_IFACE:-}}"
  fi

  DNS_RESOLV_CONF_TARGET=""; DNS_SERVERS=""; DNS_SEARCH=""; DNS_STUB=0; RESOLVECTL_AVAILABLE=0; DNS_RESOLVECTL=""
  if [[ -e /etc/resolv.conf ]]; then
    DNS_RESOLV_CONF_TARGET="$(readlink -f /etc/resolv.conf 2>/dev/null || printf '/etc/resolv.conf')"
    DNS_SERVERS="$(awk '$1=="nameserver"{print $2}' /etc/resolv.conf 2>/dev/null | paste -sd',' -)"
    DNS_SEARCH="$(awk '$1=="search"||$1=="domain"{$1="";sub(/^[[:space:]]+/,"");print}' /etc/resolv.conf 2>/dev/null | paste -sd';' -)"
    grep -Eq '^[[:space:]]*nameserver[[:space:]]+(127\.0\.0\.53|127\.0\.0\.1|::1)' /etc/resolv.conf 2>/dev/null && DNS_STUB=1
  fi
  if have_cmd resolvectl; then
    RESOLVECTL_AVAILABLE=1; local rc=0
    DNS_RESOLVECTL="$(run_with_timeout 4 resolvectl dns 2>/dev/null)" || rc=$?
    ((rc==124)) && { add_limitation "La consulta resolvectl dns superó 4s; upstream DNS omitidos."; DNS_RESOLVECTL=""; }
  fi

  FIREWALL_TOOLS=""; local fw
  for fw in nft iptables ufw firewall-cmd; do have_cmd "$fw" && FIREWALL_TOOLS+="${FIREWALL_TOOLS:+, }$fw"; done
  FIREWALL_SERVICE_STATE=""
  if have_cmd systemctl; then
    local svc state
    for svc in firewalld ufw nftables; do
      state="$(run_with_timeout 2 systemctl is-active "$svc" 2>/dev/null || true)"
      [[ "$state" == active ]] && FIREWALL_SERVICE_STATE+="${FIREWALL_SERVICE_STATE:+, }${svc}=active"
    done
  fi

  declare -A arxd atxd arxe atxe arxb atxb brxd btxd brxe btxe brxb btxb
  local iface x1 x2 x3 x4 x5 x6
  while read -r iface x1 x2 x3 x4 x5 x6; do [[ -n "$iface" ]] || continue; arxd[$iface]=$x1; atxd[$iface]=$x2; arxe[$iface]=$x3; atxe[$iface]=$x4; arxb[$iface]=$x5; atxb[$iface]=$x6; done <<<"${SAMPLE_NET_A:-}"
  while read -r iface x1 x2 x3 x4 x5 x6; do [[ -n "$iface" ]] || continue; brxd[$iface]=$x1; btxd[$iface]=$x2; brxe[$iface]=$x3; btxe[$iface]=$x4; brxb[$iface]=$x5; btxb[$iface]=$x6; done <<<"${SAMPLE_NET_B:-}"

  local path state carrier mtu speed duplex kind ipv4 ipv6 drxd dtxd drxe dtxe drxb dtxb rxdrop txdrop rxerr txerr sec=${SAMPLE_SECONDS:-1}
  ((sec<1)) && sec=1
  for path in /sys/class/net/*; do
    [[ -e "$path" ]] || continue; iface="${path##*/}"; [[ "$iface" == lo ]] && continue; ((NET_IFACE_COUNT++))||true
    state="$(_net_value "$path/operstate" unknown)"; carrier="$(_net_value "$path/carrier" n/d)"; mtu="$(_net_value "$path/mtu" n/d)"
    speed="$(_net_value "$path/speed" n/d)"; duplex="$(_net_value "$path/duplex" n/d)"; kind="$(_net_kind "$iface")"; [[ "$state" == up ]] && ((NET_UP_COUNT++))||true
    rxdrop=${brxd[$iface]:-0}; txdrop=${btxd[$iface]:-0}; rxerr=${brxe[$iface]:-0}; txerr=${btxe[$iface]:-0}
    drxd="$(count_delta "${arxd[$iface]:-0}" "$rxdrop")"; dtxd="$(count_delta "${atxd[$iface]:-0}" "$txdrop")"
    drxe="$(count_delta "${arxe[$iface]:-0}" "$rxerr")"; dtxe="$(count_delta "${atxe[$iface]:-0}" "$txerr")"
    drxb="$(count_delta "${arxb[$iface]:-0}" "${brxb[$iface]:-0}")"; dtxb="$(count_delta "${atxb[$iface]:-0}" "${btxb[$iface]:-0}")"
    NET_RX_DROP_TOTAL=$((NET_RX_DROP_TOTAL+rxdrop)); NET_TX_DROP_TOTAL=$((NET_TX_DROP_TOTAL+txdrop)); NET_RX_ERR_TOTAL=$((NET_RX_ERR_TOTAL+rxerr)); NET_TX_ERR_TOTAL=$((NET_TX_ERR_TOTAL+txerr))
    NET_RX_DROP_DELTA=$((NET_RX_DROP_DELTA+drxd)); NET_TX_DROP_DELTA=$((NET_TX_DROP_DELTA+dtxd)); NET_RX_ERR_DELTA=$((NET_RX_ERR_DELTA+drxe)); NET_TX_ERR_DELTA=$((NET_TX_ERR_DELTA+dtxe))
    NET_RX_BYTES_DELTA=$((NET_RX_BYTES_DELTA+drxb)); NET_TX_BYTES_DELTA=$((NET_TX_BYTES_DELTA+dtxb))
    ipv4="$(_net_ipv4 "$iface")"; ipv6="$(_net_ipv6 "$iface")"
    NET_ADDR_TABLE+="$iface|${ipv4:-—}|${ipv6:-—}"$'\n'
    NET_IF_TABLE+="$iface|$state|$carrier|$kind|$mtu|$speed|$duplex|$rxdrop|$txdrop|$rxerr|$txerr|$drxd|$dtxd|$drxe|$dtxe|$((drxb/sec))|$((dtxb/sec))"$'\n'
    if [[ -n "$NET_PRIMARY_IFACE" && "$iface" == "$NET_PRIMARY_IFACE" ]]; then
      NET_PRIMARY_STATE="$state"; NET_PRIMARY_CARRIER="$carrier"; NET_PRIMARY_MTU="$mtu"; NET_PRIMARY_SPEED="$speed"; NET_PRIMARY_DUPLEX="$duplex"
      NET_PRIMARY_IPV4="${ipv4:-n/d}"; NET_PRIMARY_IPV6="${ipv6:-n/d}"; NET_PRIMARY_RX_BPS=$((drxb/sec)); NET_PRIMARY_TX_BPS=$((dtxb/sec))
      if [[ "$speed" =~ ^[0-9]+$ ]] && ((speed>0)); then
        NET_PRIMARY_RX_UTIL_PCT="$(awk -v b="$NET_PRIMARY_RX_BPS" -v m="$speed" 'BEGIN{printf "%.2f",100*(b*8)/(m*1000000)}')"
        NET_PRIMARY_TX_UTIL_PCT="$(awk -v b="$NET_PRIMARY_TX_BPS" -v m="$speed" 'BEGIN{printf "%.2f",100*(b*8)/(m*1000000)}')"
      fi
    fi
  done

  # Resume MTU de interfaces activas. Una MTU distinta puede ser totalmente válida
  # (VPN/overlay/VLAN/etc.); por sí sola NO genera un finding.
  declare -A mtu_seen=()
  local mi ms mc mk mmu rest_fields
  while IFS='|' read -r mi ms mc mk mmu rest_fields; do
    [[ -n "$mi" && "$ms" == up && "$mmu" =~ ^[0-9]+$ && "$mmu" -gt 0 ]] || continue
    mtu_seen[$mmu]=1
    if ((NET_UP_MTU_MIN==0 || mmu<NET_UP_MTU_MIN)); then NET_UP_MTU_MIN=$mmu; fi
    if ((mmu>NET_UP_MTU_MAX)); then NET_UP_MTU_MAX=$mmu; fi
  done <<<"$NET_IF_TABLE"
  NET_UP_MTU_VARIANTS=${#mtu_seen[@]}
  if ((NET_UP_MTU_MAX>0)); then
    while IFS='|' read -r mi ms mc mk mmu rest_fields; do
      [[ -n "$mi" && "$ms" == up && "$mmu" =~ ^[0-9]+$ ]] || continue
      ((mmu<NET_UP_MTU_MAX)) && NET_LOWER_MTU_IFACES+="${NET_LOWER_MTU_IFACES:+, }${mi}=${mmu}"
    done <<<"$NET_IF_TABLE"
  fi

  read -r rta sta loa lda <<<"${SAMPLE_TCP_A:-0 0 0 0}"; read -r rtb stb lob ldb <<<"${SAMPLE_TCP_B:-0 0 0 0}"
  NET_TCP_RETRANS_DELTA="$(count_delta "$rta" "$rtb")"; NET_TCP_SYN_RETRANS_DELTA="$(count_delta "$sta" "$stb")"
  NET_LISTEN_OVER_DELTA="$(count_delta "$loa" "$lob")"; NET_LISTEN_DROP_DELTA="$(count_delta "$lda" "$ldb")"
  NET_TCP_RETRANS_TOTAL=${rtb:-0}; NET_TCP_SYN_RETRANS_TOTAL=${stb:-0}

  local ffa i6ffa i6tba i6ptba mtufa mtusa ffb i6ffb i6tbb i6ptbb mtufb mtusb
  read -r ffa i6ffa i6tba i6ptba mtufa mtusa <<<"${SAMPLE_PMTU_A:-0 0 0 0 0 0}"
  read -r ffb i6ffb i6tbb i6ptbb mtufb mtusb <<<"${SAMPLE_PMTU_B:-0 0 0 0 0 0}"
  NET_FRAG_FAIL_DELTA="$(count_delta "$ffa" "$ffb")"
  NET_IP6_FRAG_FAIL_DELTA="$(count_delta "$i6ffa" "$i6ffb")"
  NET_IP6_TOO_BIG_DELTA="$(count_delta "$i6tba" "$i6tbb")"
  NET_ICMP6_PTB_DELTA="$(count_delta "$i6ptba" "$i6ptbb")"
  NET_TCP_MTUP_FAIL_DELTA="$(count_delta "$mtufa" "$mtufb")"
  NET_TCP_MTUP_SUCCESS_DELTA="$(count_delta "$mtusa" "$mtusb")"

  local sda ssa sdb ssb
  read -r sda ssa <<<"${SAMPLE_SOFTNET_A:-0 0}"; read -r sdb ssb <<<"${SAMPLE_SOFTNET_B:-0 0}"
  NET_SOFTNET_DROP_DELTA="$(count_delta "$sda" "$sdb")"; NET_SOFTNET_SQUEEZE_DELTA="$(count_delta "$ssa" "$ssb")"

  TCP_LISTEN=0; TCP_ESTAB=0; TCP_TIME_WAIT=0; TCP_CLOSE_WAIT=0; TCP_SYN_SENT=0; TCP_SYN_RECV=0; TCP_FIN_WAIT1=0; TCP_FIN_WAIT2=0; TCP_LAST_ACK=0; TCP_CLOSING=0
  TCP_SS_ALL=""; TCP_LISTENER_DETAILS=""; TCP_PROBLEM_DETAILS=""
  if ((SS_AVAILABLE)); then
    local rc=0
    TCP_SS_ALL="$(run_with_timeout 5 ss -Htanp 2>/dev/null)" || rc=$?
    if ((rc==124)); then add_limitation "La consulta ss -tanp superó 5s; estados TCP omitidos."; TCP_SS_ALL=""; SS_AVAILABLE=0
    else
      read -r TCP_LISTEN TCP_ESTAB TCP_TIME_WAIT TCP_CLOSE_WAIT TCP_SYN_SENT TCP_SYN_RECV TCP_FIN_WAIT1 TCP_FIN_WAIT2 TCP_LAST_ACK TCP_CLOSING < <(
        awk '{s=$1;c[s]++} END{printf "%d %d %d %d %d %d %d %d %d %d\n",c["LISTEN"]+0,c["ESTAB"]+0,c["TIME-WAIT"]+0,c["CLOSE-WAIT"]+0,c["SYN-SENT"]+0,c["SYN-RECV"]+0,c["FIN-WAIT-1"]+0,c["FIN-WAIT-2"]+0,c["LAST-ACK"]+0,c["CLOSING"]+0}' <<<"$TCP_SS_ALL")
      TCP_LISTENER_DETAILS="$(awk '$1=="LISTEN"{print}' <<<"$TCP_SS_ALL" | head -n 25)"
      TCP_PROBLEM_DETAILS="$(awk '$1=="CLOSE-WAIT"||$1=="SYN-SENT"||$1=="SYN-RECV"{print}' <<<"$TCP_SS_ALL" | head -n 60)"
    fi
  fi

  CONNTRACK_AVAILABLE=0; CONNTRACK_COUNT=0; CONNTRACK_MAX=0; CONNTRACK_PCT=0
  if [[ -r /proc/sys/net/netfilter/nf_conntrack_count && -r /proc/sys/net/netfilter/nf_conntrack_max ]]; then
    CONNTRACK_AVAILABLE=1; CONNTRACK_COUNT="$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)"; CONNTRACK_MAX="$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 0)"
    CONNTRACK_PCT="$(awk -v c="$CONNTRACK_COUNT" -v m="$CONNTRACK_MAX" 'BEGIN{if(m>0)printf "%.1f",100*c/m;else print 0}')"
  fi
  EPHEMERAL_PORT_RANGE="$(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null | xargs 2>/dev/null || true)"
}

analyze_network() {
  ((NETWORK_AVAILABLE)) || return
  local default_state=""
  if [[ -n "${NET_DEFAULT4_IFACE:-}" ]]; then default_state="$(_net_value "/sys/class/net/$NET_DEFAULT4_IFACE/operstate" unknown)"; fi
  if [[ -n "$default_state" && "$default_state" != up && "$default_state" != unknown ]]; then
    add_finding NET_DEFAULT_DOWN network link_state 6 critical "Interfaz de ruta por defecto (${NET_DEFAULT4_IFACE}) no está UP: ${default_state}."
    add_next_step "Comprobar estado físico/lógico de ${NET_DEFAULT4_IFACE} y eventos de enlace." \
      "ip -br link show dev ${NET_DEFAULT4_IFACE}" "ip -s link show dev ${NET_DEFAULT4_IFACE}" "ethtool ${NET_DEFAULT4_IFACE}" "journalctl -k --since '-30 min' | grep -Ei '${NET_DEFAULT4_IFACE}|link|carrier|net'"
  fi

  local active_err=$((NET_RX_ERR_DELTA+NET_TX_ERR_DELTA)) active_drop=$((NET_RX_DROP_DELTA+NET_TX_DROP_DELTA))
  if ((active_err>=100)); then add_finding NET_LINK_ERRORS network interface_errors 5 high "${active_err} errores de interfaz nuevos en ${NET_SAMPLE_SECONDS}s."
  elif ((active_err>0)); then add_finding NET_LINK_ERRORS network interface_errors 2 medium "${active_err} errores de interfaz nuevos en ${NET_SAMPLE_SECONDS}s."; fi
  if ((active_drop>=100)); then add_finding NET_LINK_DROPS network interface_drops 4 high "${active_drop} drops de interfaz nuevos en ${NET_SAMPLE_SECONDS}s."
  elif ((active_drop>0)); then add_finding NET_LINK_DROPS network interface_drops 2 medium "${active_drop} drops de interfaz nuevos en ${NET_SAMPLE_SECONDS}s."; fi
  if ((active_err+active_drop>0)); then
    add_next_step "Localizar interfaz y capa que descarta/errorea; RX dropped no se atribuye automáticamente al firewall." \
      "ip -s link" "ethtool -S <INTERFAZ>" "cat /proc/net/softnet_stat" "sar -n DEV,EDEV 1 10"
  fi

  if ((NET_SOFTNET_DROP_DELTA>0 || NET_SOFTNET_SQUEEZE_DELTA>0)); then
    add_finding NET_SOFTNET network softnet 4 high "Softnet registró drops/time_squeeze nuevos (${NET_SOFTNET_DROP_DELTA}/${NET_SOFTNET_SQUEEZE_DELTA}) durante la muestra."
    add_next_step "Revisar si CPU/softirq/backlog no procesa paquetes al ritmo necesario." \
      "cat /proc/net/softnet_stat" "mpstat -P ALL 1" "sar -n SOFT 1 10" "ethtool -S <INTERFAZ>"
  fi

  if ((NET_LISTEN_OVER_DELTA+NET_LISTEN_DROP_DELTA>0)); then
    add_finding NET_LISTEN_PRESSURE network listen_backlog 5 high "ListenOverflows/ListenDrops nuevos: ${NET_LISTEN_OVER_DELTA}/${NET_LISTEN_DROP_DELTA}."
    add_next_step "Identificar listeners saturados y comparar backlog/tasa de conexiones." "ss -lntp" "ss -s" "nstat -az | grep -E 'ListenOverflows|ListenDrops'"
  fi

  if ((NET_TCP_RETRANS_DELTA>=20)); then add_finding NET_RETRANS network retransmissions 4 high "${NET_TCP_RETRANS_DELTA} retransmisiones TCP nuevas en ${NET_SAMPLE_SECONDS}s."
  elif ((NET_TCP_RETRANS_DELTA>0)); then add_finding NET_RETRANS network retransmissions 2 medium "${NET_TCP_RETRANS_DELTA} retransmisiones TCP nuevas en ${NET_SAMPLE_SECONDS}s."; fi
  if ((NET_TCP_SYN_RETRANS_DELTA>0)); then
    add_finding NET_SYN_RETRANS network syn_retransmissions 2 medium "${NET_TCP_SYN_RETRANS_DELTA} retransmisiones SYN nuevas en ${NET_SAMPLE_SECONDS}s."
  fi

  local frag_fail=${NET_FRAG_FAIL_DELTA:-0} ip6_frag_fail=${NET_IP6_FRAG_FAIL_DELTA:-0} ip6_too_big=${NET_IP6_TOO_BIG_DELTA:-0}
  local icmp6_ptb=${NET_ICMP6_PTB_DELTA:-0} tcp_mtup_fail=${NET_TCP_MTUP_FAIL_DELTA:-0}
  local pmtu_kernel_delta=$((frag_fail+ip6_frag_fail+ip6_too_big+icmp6_ptb+tcp_mtup_fail))
  if ((pmtu_kernel_delta>0)); then
    add_finding NET_PMTU_KERNEL network path_mtu 4 high \
      "Señales kernel relacionadas con MTU/fragmentación durante la muestra: IPv4 FragFails +${frag_fail}, IPv6 FragFails +${ip6_frag_fail}, IPv6 TooBig +${ip6_too_big}, ICMPv6 Packet Too Big +${icmp6_ptb}, TCP MTU-probe fail +${tcp_mtup_fail}."
    add_next_step "Correlacionar las señales MTU con el destino afectado; una MTU local correcta no demuestra la PMTU extremo a extremo." \
      "ip route get <IP_DESTINO>" \
      "tracepath -n <IP_DESTINO>" \
      "ping -4 -M do -s 1472 <IP_DESTINO>" \
      "ss -ti dst <IP_DESTINO>" \
      "nstat -az | grep -E 'IpFragFails|Ip6FragFails|Ip6InTooBigErrors|Icmp6InPktTooBigs|TCPMTUP'" \
      "sudo tcpdump -ni any 'icmp or icmp6'"
  elif ((NET_TCP_RETRANS_DELTA>=20)); then
    add_next_step "Hay retransmisiones TCP: distinguir pérdida/congestión de un posible problema de PMTU, especialmente si tráfico pequeño funciona y transferencias grandes se bloquean." \
      "ip route get <IP_DESTINO>" \
      "tracepath -n <IP_DESTINO>" \
      "ping -4 -M do -s 1472 <IP_DESTINO>" \
      "ss -ti dst <IP_DESTINO>"
  fi

  if ((TCP_CLOSE_WAIT>=100)); then add_finding NET_CLOSE_WAIT network socket_lifecycle 4 high "${TCP_CLOSE_WAIT} CLOSE-WAIT; posible mala gestión de cierre de sockets de aplicación."
  elif ((TCP_CLOSE_WAIT>=20)); then add_finding NET_CLOSE_WAIT network socket_lifecycle 2 medium "${TCP_CLOSE_WAIT} CLOSE-WAIT; revisar gestión de conexiones."; fi
  if ((TCP_CLOSE_WAIT>=20)); then add_next_step "Identificar procesos con CLOSE-WAIT; reiniciar puede mitigar, pero no corrige la causa." "ss -Htanp state close-wait" "lsof -nP -iTCP -sTCP:CLOSE_WAIT"; fi

  if ((TCP_SYN_SENT>=20)); then add_finding NET_SYN_SENT network handshake 4 high "${TCP_SYN_SENT} SYN-SENT: clientes esperando completar handshake."
  elif ((TCP_SYN_SENT>0)); then add_finding NET_SYN_SENT network handshake 1 low "${TCP_SYN_SENT} SYN-SENT en la fotografía; confirmar persistencia."; fi
  if ((TCP_SYN_SENT>0)); then add_next_step "Localizar destinos SYN-SENT y comprobar handshake en ambos extremos antes de culpar a red/aplicación." \
      "ss -Htanp state syn-sent" "ip route get <IP_DESTINO>" "nc -vz -w3 <IP_DESTINO> <PUERTO>" "sudo tcpdump -ni any host <IP_DESTINO> and port <PUERTO>"; fi

  if ((CONNTRACK_AVAILABLE)); then
    if num_ge "$CONNTRACK_PCT" 95; then add_finding NET_CONNTRACK network conntrack 6 critical "Conntrack al ${CONNTRACK_PCT}% (${CONNTRACK_COUNT}/${CONNTRACK_MAX})."
    elif num_ge "$CONNTRACK_PCT" 80; then add_finding NET_CONNTRACK network conntrack 3 high "Conntrack al ${CONNTRACK_PCT}% (${CONNTRACK_COUNT}/${CONNTRACK_MAX})."; fi
    if num_ge "$CONNTRACK_PCT" 80; then add_next_step "Revisar presión de conntrack y origen de conexiones." "cat /proc/sys/net/netfilter/nf_conntrack_count" "cat /proc/sys/net/netfilter/nf_conntrack_max" "conntrack -S" "ss -s"; fi
  fi
}

print_network() {
  section "RED Y TCP"
  ((NETWORK_AVAILABLE)) || { warn "No se puede acceder a /sys/class/net."; return; }

  subsection "Resumen local"
  kv_at 4 32 "Interfaces (sin loopback):" "$NET_IFACE_COUNT"; kv_at 4 32 "Interfaces UP:" "$NET_UP_COUNT"
  kv_at 4 32 "Ruta por defecto IPv4:" "${NET_DEFAULT4:-no detectada}"; kv_at 4 32 "Ruta por defecto IPv6:" "${NET_DEFAULT6:-no detectada}"
  kv_at 4 32 "Resolver:" "${DNS_RESOLV_CONF_TARGET:-no disponible}"; kv_at 4 32 "DNS visibles:" "${DNS_SERVERS:-no detectados}"
  [[ -n "$DNS_SEARCH" ]] && kv_at 4 32 "Dominios search:" "$DNS_SEARCH"; ((DNS_STUB)) && kv_at 4 32 "DNS local/stub:" "sí; upstream en resolvectl"
  kv_at 4 32 "Herramientas firewall:" "${FIREWALL_TOOLS:-no detectadas}"; [[ -n "$FIREWALL_SERVICE_STATE" ]] && kv_at 4 32 "Servicios firewall activos:" "$FIREWALL_SERVICE_STATE"

  if [[ -n "$NET_PRIMARY_IFACE" ]]; then
    subsection "Enlace principal"
    kv_at 4 30 "Interfaz:" "$NET_PRIMARY_IFACE"; kv_at 4 30 "Estado / carrier:" "${NET_PRIMARY_STATE:-n/d} / ${NET_PRIMARY_CARRIER:-n/d}"
    kv_at 4 30 "IPv4:" "${NET_PRIMARY_IPV4:-n/d}"; [[ "${NET_PRIMARY_IPV6:-n/d}" != n/d ]] && kv_at 4 30 "IPv6 global:" "$NET_PRIMARY_IPV6"
    kv_at 4 30 "MTU:" "${NET_PRIMARY_MTU:-n/d}"
    if [[ "${NET_PRIMARY_SPEED:-}" =~ ^[0-9]+$ ]] && ((NET_PRIMARY_SPEED>0)); then kv_at 4 30 "Velocidad:" "${NET_PRIMARY_SPEED} Mb/s"; else kv_at 4 30 "Velocidad:" "n/d"; fi
    kv_at 4 30 "RX durante muestra:" "$(rate_bytes_human "$NET_PRIMARY_RX_BPS") (${NET_PRIMARY_RX_UTIL_PCT:-0}% enlace)"
    kv_at 4 30 "TX durante muestra:" "$(rate_bytes_human "$NET_PRIMARY_TX_BPS") (${NET_PRIMARY_TX_UTIL_PCT:-0}% enlace)"
  fi

  subsection "Interfaces"
  local shown=0 max_rows=20 line iface state carrier kind mtu speed duplex rxdrop txdrop rxerr txerr drxd dtxd drxe dtxe rxbps txbps marker
  [[ ${VERBOSE:-0} -eq 1 ]] && max_rows=80
  if [[ "${OUTPUT_LAYOUT:-normal}" == compact ]]; then
    printf '    %-11s %-6s %6s %7s %7s %9s %9s\n' INTERFAZ ESTADO MTU RXdΔ TXdΔ RX_RATE TX_RATE
  else
    printf '    %-12s %-7s %-8s %6s %8s %8s %8s %8s %10s %10s\n' INTERFAZ ESTADO TIPO MTU RXDROP TXDROP RXERR TXERR RX_RATE TX_RATE
  fi
  while IFS='|' read -r iface state carrier kind mtu speed duplex rxdrop txdrop rxerr txerr drxd dtxd drxe dtxe rxbps txbps; do
    [[ -n "$iface" ]] || continue; ((shown++))||true; ((shown<=max_rows))||continue; marker=" "; [[ "$iface" == "$NET_DEFAULT4_IFACE" || "$iface" == "$NET_DEFAULT6_IFACE" ]] && marker="*"
    if [[ "${OUTPUT_LAYOUT:-normal}" == compact ]]; then
      printf '   %s%-10s %-6s %6s %7s %7s %9s %9s\n' "$marker" "$iface" "$state" "$mtu" "+$drxd" "+$dtxd" "$(rate_bytes_human "$rxbps")" "$(rate_bytes_human "$txbps")"
    else
      printf '   %s%-11s %-7s %-8s %6s %8s %8s %8s %8s %10s %10s\n' "$marker" "$iface" "$state" "$kind" "$mtu" "$rxdrop" "$txdrop" "$rxerr" "$txerr" "$(rate_bytes_human "$rxbps")" "$(rate_bytes_human "$txbps")"
      ((drxd+dtxd+drxe+dtxe>0)) && printf '      delta %ss: RXdrop +%s TXdrop +%s RXerr +%s TXerr +%s\n' "$NET_SAMPLE_SECONDS" "$drxd" "$dtxd" "$drxe" "$dtxe"
    fi
  done <<<"$NET_IF_TABLE"
  ((shown>max_rows)) && printf '    ... %d interfaces adicionales; usa --verbose.\n' "$((shown-max_rows))"
  printf '    * interfaz usada por una ruta por defecto\n'

  subsection "Estados TCP"
  if ((SS_AVAILABLE)); then
    printf '    %-14s %8s    %-14s %8s\n' ESTADO SOCKETS ESTADO SOCKETS
    printf '    %-14s %8s    %-14s %8s\n' LISTEN "$TCP_LISTEN" ESTABLISHED "$TCP_ESTAB"
    printf '    %-14s %8s    %-14s %8s\n' TIME-WAIT "$TCP_TIME_WAIT" CLOSE-WAIT "$TCP_CLOSE_WAIT"
    printf '    %-14s %8s    %-14s %8s\n' SYN-SENT "$TCP_SYN_SENT" SYN-RECV "$TCP_SYN_RECV"
    printf '    %-14s %8s    %-14s %8s\n' FIN-WAIT-1 "$TCP_FIN_WAIT1" FIN-WAIT-2 "$TCP_FIN_WAIT2"
  else note "ss no disponible o excedió timeout."; fi

  subsection "Actividad durante ${NET_SAMPLE_SECONDS}s"
  kv_at 4 38 "RX/TX drops nuevos:" "${NET_RX_DROP_DELTA}/${NET_TX_DROP_DELTA}"; kv_at 4 38 "RX/TX errors nuevos:" "${NET_RX_ERR_DELTA}/${NET_TX_ERR_DELTA}"
  kv_at 4 38 "Retransmisiones TCP nuevas:" "$NET_TCP_RETRANS_DELTA"; kv_at 4 38 "Retransmisiones SYN nuevas:" "$NET_TCP_SYN_RETRANS_DELTA"
  kv_at 4 38 "ListenOverflows / Drops:" "${NET_LISTEN_OVER_DELTA}/${NET_LISTEN_DROP_DELTA}"
  kv_at 4 38 "softnet drops / squeeze:" "${NET_SOFTNET_DROP_DELTA}/${NET_SOFTNET_SQUEEZE_DELTA}"
  if ((CONNTRACK_AVAILABLE)); then kv_at 4 38 "Conntrack:" "${CONNTRACK_COUNT}/${CONNTRACK_MAX} (${CONNTRACK_PCT}%)"; fi
  kv_at 4 38 "Puertos efímeros IPv4:" "${EPHEMERAL_PORT_RANGE:-n/d}"

  subsection "MTU / PMTU"
  if ((NET_UP_MTU_MAX>0)); then
    kv_at 4 38 "MTU interfaces UP (mín/máx):" "${NET_UP_MTU_MIN}/${NET_UP_MTU_MAX}"
    kv_at 4 38 "Valores MTU distintos (UP):" "$NET_UP_MTU_VARIANTS"
    [[ -n "$NET_LOWER_MTU_IFACES" ]] && kv_at 4 38 "MTU inferiores al máximo:" "$NET_LOWER_MTU_IFACES"
  else
    kv_at 4 38 "MTU interfaces UP:" "n/d"
  fi
  kv_at 4 38 "net.ipv4.tcp_mtu_probing:" "$NET_TCP_MTU_PROBING"
  kv_at 4 38 "net.ipv4.tcp_base_mss:" "$NET_TCP_BASE_MSS"
  kv_at 4 38 "IPv4 FragFails nuevos:" "$NET_FRAG_FAIL_DELTA"
  kv_at 4 38 "IPv6 FragFails / TooBig nuevos:" "${NET_IP6_FRAG_FAIL_DELTA}/${NET_IP6_TOO_BIG_DELTA}"
  kv_at 4 38 "ICMPv6 Packet Too Big nuevos:" "$NET_ICMP6_PTB_DELTA"
  kv_at 4 38 "TCP MTU probe fail/success nuevos:" "${NET_TCP_MTUP_FAIL_DELTA}/${NET_TCP_MTUP_SUCCESS_DELTA}"
  note "SYSdiag no hace probes activos de PMTU automáticamente; los propone para un destino concreto."

  if (( ${VERBOSE:-0} == 1 )); then
    subsection "Direcciones y rutas"
    while IFS='|' read -r iface ipv4 ipv6; do [[ -n "$iface" ]] && printf '    %-14s IPv4 %-20s IPv6 %s\n' "$iface" "$ipv4" "$ipv6"; done <<<"$NET_ADDR_TABLE"
    [[ -n "$IP_ROUTE4_TABLE" ]] && { printf '\n    IPv4:\n'; sed 's/^/      /' <<<"$IP_ROUTE4_TABLE"; }
    [[ -n "$IP_ROUTE6_TABLE" ]] && { printf '\n    IPv6:\n'; sed 's/^/      /' <<<"$IP_ROUTE6_TABLE"; }
    if ((RESOLVECTL_AVAILABLE)) && [[ -n "$DNS_RESOLVECTL" ]]; then printf '\n    DNS upstream:\n'; sed 's/^/      /' <<<"$DNS_RESOLVECTL"; fi
    if [[ -n "$TCP_LISTENER_DETAILS" ]]; then subsection "Listeners TCP (máx. 25)"; sed 's/^/    /' <<<"$TCP_LISTENER_DETAILS"; fi
    if [[ -n "$TCP_PROBLEM_DETAILS" ]]; then subsection "Sockets a revisar"; sed 's/^/    /' <<<"$TCP_PROBLEM_DETAILS"; fi
  fi

  subsection "Comandos de comprobación manual"
  printf '    Resolución:\n      $ getent hosts <nombre>\n      $ resolvectl query <nombre>\n      $ dig <nombre>\n'
  printf '    Ruta:\n      $ ip route get <IP>\n      $ ip -4 route\n'
  printf '    TCP/listeners:\n      $ ss -lntp\n      $ ss -ntp\n      $ ss -s\n'
  printf '    Puerto concreto:\n      $ nc -vz -w3 <HOST> <PUERTO>\n      $ curl -v --connect-timeout 3 http://<HOST>:<PUERTO>/\n'
  printf '    Interfaz/kernel:\n      $ ip -s link\n      $ ethtool -S <INTERFAZ>\n      $ cat /proc/net/softnet_stat\n'
  printf '    MTU/PMTU:\n      $ ip route get <IP_DESTINO>\n      $ tracepath -n <IP_DESTINO>\n      $ ping -4 -M do -s 1472 <IP_DESTINO>\n      $ ss -ti dst <IP_DESTINO>\n'
  printf '    Captura:\n      $ sudo tcpdump -ni any host <IP> and port <PUERTO>\n'

  if (( ${EXPLAIN:-0} == 1 )); then
    printf '\n  Explicación:\n'
    printf '    - SYSdiag diferencia contadores acumulados de deltas ocurridos durante la ventana común.\n'
    printf '    - RX dropped no implica automáticamente firewall; softnet/driver/buffers también pueden descartarlos.\n'
    printf '    - CLOSE-WAIT suele apuntar al ciclo de vida de sockets de aplicación; SYN-SENT obliga a revisar handshake.\n'
    printf '    - Throughput de la interfaz principal es orientativo y se calcula con bytes RX/TX del mismo periodo de muestra.\n'
    printf '    - La MTU de una interfaz es local: no demuestra la Path MTU completa hasta un destino.\n'
    printf '    - VPN/overlays añaden cabeceras; por eso la MTU útil dentro del túnel puede necesitar ser menor que la red física.\n'
    printf '    - PMTUD depende de recibir la señal de que un paquete es demasiado grande; si esa señal se pierde, tráfico pequeño puede funcionar y tráfico grande quedarse retransmitiendo (PMTU black hole).\n'
    printf '    - Un ping correcto no demuestra que TCP/<puerto> sea accesible.\n'
  fi
}

# ===== modules/logging.sh =====

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

# ===== modules/recent_events.sh =====

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

# ===== modules/systemd_services.sh =====

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

# ===== modules/boot.sh =====

# Boot / startup diagnostics for SYSdiag.
# Read-only: inspects current boot evidence, fstab, mount units, journal and
# systemd-analyze. It does not repair initramfs, GRUB, filesystems or mounts.

BOOT_FSTAB_DETAIL_LIMIT_DEFAULT=30
BOOT_ANALYZE_BLAME_LIMIT_DEFAULT=12
BOOT_JOURNAL_LIMIT_DEFAULT=120

_boot_sanitize_one_line() {
  printf '%s\n' "$1" | sanitize_terminal_text | head -n 1
}

_boot_is_remote_fstype() {
  case "${1,,}" in
    nfs|nfs4|cifs|smb3|smbfs|ceph|glusterfs|fuse.sshfs|sshfs|9p|afs|lustre) return 0 ;;
    *) return 1 ;;
  esac
}

_boot_is_container() {
  [[ "${BOOT_FORCE_CONTEXT:-}" == "container" ]] && return 0
  [[ "${BOOT_FORCE_CONTEXT:-}" == "host" ]] && return 1
  local root="${BOOT_PROC_ROOT:-/proc}" detected=""
  if have_cmd systemd-detect-virt; then
    detected="$(run_with_timeout 2 systemd-detect-virt --container 2>/dev/null || true)"
    [[ -n "$detected" && "$detected" != none ]] && return 0
  fi
  [[ -e /.dockerenv ]] && return 0
  if [[ -r "$root/1/cgroup" ]] && grep -Eqi '(docker|containerd|kubepods|podman|lxc)' "$root/1/cgroup" 2>/dev/null; then
    return 0
  fi
  return 1
}

_boot_fstab_decode() {
  # fstab escapes whitespace and backslashes using octal sequences.
  local s="$1"
  s="${s//\\040/ }"; s="${s//\\011/$'\t'}"; s="${s//\\134/\\}"
  printf '%s' "$s"
}

_boot_ref_exists() {
  local spec="$1" rc=0 out=""
  case "$spec" in
    UUID=*|LABEL=*|PARTUUID=*|PARTLABEL=*)
      if ! have_cmd blkid; then return 2; fi
      rc=0; out="$(run_with_timeout 3 blkid -t "$spec" -o device 2>/dev/null)" || rc=$?
      (( rc == 124 )) && return 3
      [[ -n "$out" ]] && return 0 || return 1
      ;;
    /dev/*)
      [[ -e "$spec" ]] && return 0 || return 1
      ;;
    *) return 2 ;;
  esac
}

_boot_root_source() {
  if have_cmd findmnt; then
    run_with_timeout 3 findmnt -n -o SOURCE / 2>/dev/null | head -n 1
  else
    awk '$5=="/" {for(i=1;i<=NF;i++) if($i=="-"){print $(i+2); exit}}' "${BOOT_PROC_ROOT:-/proc}/self/mountinfo" 2>/dev/null
  fi
}

_boot_root_fstype() {
  if have_cmd findmnt; then
    run_with_timeout 3 findmnt -n -o FSTYPE / 2>/dev/null | head -n 1
  else
    awk '$5=="/" {for(i=1;i<=NF;i++) if($i=="-"){print $(i+1); exit}}' "${BOOT_PROC_ROOT:-/proc}/self/mountinfo" 2>/dev/null
  fi
}

collect_boot() {
  BOOT_COLLECTED=1
  BOOT_CONTEXT="host/VM"; BOOT_CONTEXT_REPRESENTATIVE=1
  BOOT_KERNEL="$(uname -r 2>/dev/null || echo n/d)"
  BOOT_CMDLINE="n/d"; BOOT_ROOT_ARG="n/d"; BOOT_ROOT_SOURCE="n/d"; BOOT_ROOT_FSTYPE="n/d"
  BOOT_INITRAMFS_STYLE="n/d"; BOOT_FSTAB_PRESENT=0; BOOT_FSTAB_ENTRY_COUNT=0; BOOT_FSTAB_INVALID_COUNT=0
  BOOT_FSTAB_DUPLICATE_MOUNT_COUNT=0; BOOT_FSTAB_MISSING_REQUIRED=0; BOOT_FSTAB_MISSING_NOFAIL=0
  BOOT_FSTAB_MISSING_NOAUTO=0; BOOT_FSTAB_MISSING_AUTOMOUNT=0; BOOT_FSTAB_UNCHECKED_REFS=0
  BOOT_FSTAB_REMOTE_COUNT=0; BOOT_FAILED_MOUNTS_COUNT="n/d"; BOOT_FAILED_MOUNT_QUERY_VALID=0
  BOOT_SYSTEMD_ANALYZE_AVAILABLE=0; BOOT_ANALYZE_TIME="n/d"; BOOT_ANALYZE_TIME_VALID=0
  BOOT_ANALYZE_BLAME=""; BOOT_ANALYZE_BLAME_VALID=0; BOOT_CRITICAL_CHAIN=""; BOOT_CRITICAL_CHAIN_VALID=0
  BOOT_JOURNAL_QUERY_VALID=0; BOOT_KERNEL_JOURNAL_QUERY_VALID=0; BOOT_JOURNAL_EVIDENCE=""; BOOT_KERNEL_EVIDENCE=""
  BOOT_EMERGENCY_HINTS=0; BOOT_DEVICE_TIMEOUT_HINTS=0; BOOT_FSCK_HINTS=0; BOOT_MOUNT_FAILURE_HINTS=0
  BOOT_IO_KERNEL_HINTS=0; BOOT_PREVIOUS_BOOT_AVAILABLE="n/d"; BOOT_JOURNAL_BOOT_COUNT="n/d"
  BOOT_FSTAB_DETAILS=(); BOOT_FAILED_MOUNTS=()

  local proc_root="${BOOT_PROC_ROOT:-/proc}" etc_root="${BOOT_ETC_ROOT:-/etc}" fstab=""
  fstab="${BOOT_FSTAB_FILE:-$etc_root/fstab}"
  local cmdline=""
  if [[ -r "$proc_root/cmdline" ]]; then
    cmdline="$(cat "$proc_root/cmdline" 2>/dev/null || true)"
    cmdline="$(_boot_sanitize_one_line "$cmdline")"
    [[ -n "$cmdline" ]] && BOOT_CMDLINE="$cmdline"
    local token
    for token in $cmdline; do
      case "$token" in root=*) BOOT_ROOT_ARG="${token#root=}"; break ;; esac
    done
  fi

  BOOT_ROOT_SOURCE="$(_boot_root_source || true)"; [[ -n "$BOOT_ROOT_SOURCE" ]] || BOOT_ROOT_SOURCE="n/d"
  BOOT_ROOT_FSTYPE="$(_boot_root_fstype || true)"; [[ -n "$BOOT_ROOT_FSTYPE" ]] || BOOT_ROOT_FSTYPE="n/d"

  if _boot_is_container; then
    BOOT_CONTEXT="contenedor"
    BOOT_CONTEXT_REPRESENTATIVE=0
    add_limitation "SYSdiag se ejecuta dentro de un contenedor: /proc/cmdline puede describir el boot del host y no el root del contenedor; se evita correlacionarlos como si fueran el mismo sistema."
  fi

  if [[ -d "$etc_root/initramfs-tools" ]]; then BOOT_INITRAMFS_STYLE="initramfs-tools";
  elif have_cmd dracut || [[ -e "$etc_root/dracut.conf" || -d "$etc_root/dracut.conf.d" ]]; then BOOT_INITRAMFS_STYLE="dracut";
  fi

  # Parse /etc/fstab without touching the referenced filesystems. Only local
  # block-device references are checked with blkid/stat. Remote targets are never contacted.
  if [[ -r "$fstab" ]]; then
    BOOT_FSTAB_PRESENT=1
    local line spec mnt fstype opts dump pass extra decoded_mnt ref_rc mode detail
    declare -A seen_mounts=()
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      [[ -n "${line//[[:space:]]/}" ]] || continue
      spec=""; mnt=""; fstype=""; opts=""; dump=""; pass=""; extra=""
      read -r spec mnt fstype opts dump pass extra <<<"$line"
      if [[ -z "$spec" || -z "$mnt" || -z "$fstype" || -z "$opts" ]]; then
        ((BOOT_FSTAB_INVALID_COUNT+=1)); BOOT_FSTAB_DETAILS+=("INVALID|$(_boot_sanitize_one_line "$line")")
        continue
      fi
      ((BOOT_FSTAB_ENTRY_COUNT+=1))
      decoded_mnt="$(_boot_fstab_decode "$mnt")"
      if [[ -n "${seen_mounts[$decoded_mnt]:-}" ]]; then ((BOOT_FSTAB_DUPLICATE_MOUNT_COUNT+=1)); fi
      seen_mounts[$decoded_mnt]=1

      if _boot_is_remote_fstype "$fstype" || [[ "$spec" == *:* || "$spec" == //* ]]; then
        ((BOOT_FSTAB_REMOTE_COUNT+=1)); continue
      fi
      case "$fstype" in swap|proc|sysfs|tmpfs|devtmpfs|devpts|cgroup|cgroup2|overlay|squashfs) continue ;; esac

      mode="required"
      case ",$opts," in *,noauto,*) mode="noauto" ;; *,x-systemd.automount,*) mode="automount" ;; *,nofail,*) mode="nofail" ;; esac
      ref_rc=0; _boot_ref_exists "$spec" || ref_rc=$?
      case "$ref_rc" in
        0) ;;
        1)
          detail="$mode|$(_boot_sanitize_one_line "$spec")|$(_boot_sanitize_one_line "$decoded_mnt")|$(_boot_sanitize_one_line "$fstype")"
          BOOT_FSTAB_DETAILS+=("$detail")
          case "$mode" in
            required) ((BOOT_FSTAB_MISSING_REQUIRED+=1)) ;;
            nofail) ((BOOT_FSTAB_MISSING_NOFAIL+=1)) ;;
            noauto) ((BOOT_FSTAB_MISSING_NOAUTO+=1)) ;;
            automount) ((BOOT_FSTAB_MISSING_AUTOMOUNT+=1)) ;;
          esac
          ;;
        2) ((BOOT_FSTAB_UNCHECKED_REFS+=1)) ;;
        3) ((BOOT_FSTAB_UNCHECKED_REFS+=1)); add_limitation "La consulta blkid superó el timeout al comprobar una referencia local de fstab; se deja como no determinada." ;;
      esac
    done < "$fstab"
  else
    add_limitation "No se puede leer $fstab; análisis de fstab limitado."
  fi

  # Reuse systemd state when the systemd module already collected it; otherwise
  # perform only the bounded mount query needed by Boot.
  local pid1=""
  [[ -r "$proc_root/1/comm" ]] && pid1="$(tr -d '\n' <"$proc_root/1/comm" 2>/dev/null || true)"
  if [[ "${SYSTEMD_PID1:-}" == "1" && "${SYSTEMD_ACCESS:-n/d}" != "n/d" && "${SYSTEMD_ACCESS:-n/d}" != "disponible" ]]; then
    add_limitation "Boot reutiliza el estado de systemd: el system manager no fue consultable de forma fiable, por lo que se omite la consulta duplicada de mounts failed."
  elif [[ "$pid1" == systemd ]] && have_cmd systemctl; then
    local raw="" rc=0 unit
    rc=0; raw="$(run_with_timeout 5 env LC_ALL=C systemctl --failed --type=mount --no-legend --plain --no-pager 2>/dev/null)" || rc=$?
    if (( rc == 0 )); then
      BOOT_FAILED_MOUNT_QUERY_VALID=1; BOOT_FAILED_MOUNTS_COUNT=0
      while IFS= read -r line; do
        [[ -n "${line//[[:space:]]/}" ]] || continue
        unit="$(awk '{print $1}' <<<"$line")"; [[ -n "$unit" ]] || continue
        BOOT_FAILED_MOUNTS+=("$(_boot_sanitize_one_line "$unit")"); ((BOOT_FAILED_MOUNTS_COUNT+=1))
      done <<<"$raw"
    elif (( rc == 124 )); then add_limitation "La consulta systemctl --failed --type=mount superó 5s; mounts fallidos no determinados."
    else add_limitation "No se pudo consultar systemctl --failed --type=mount; no se asume que haya 0 mounts fallidos."; fi
  else
    add_limitation "PID 1 no es systemd o systemctl no está disponible; mounts fallidos de systemd y critical chain no son evaluables desde este contexto."
  fi

  # systemd-analyze is meaningful only on the actual systemd host/VM.
  if (( BOOT_CONTEXT_REPRESENTATIVE == 1 )) && [[ "$pid1" == systemd ]] && have_cmd systemd-analyze; then
    BOOT_SYSTEMD_ANALYZE_AVAILABLE=1
    local raw="" rc=0
    rc=0; raw="$(run_with_timeout 6 env LC_ALL=C systemd-analyze time 2>/dev/null)" || rc=$?
    if (( rc == 0 )) && [[ -n "$raw" ]]; then BOOT_ANALYZE_TIME="$(_boot_sanitize_one_line "$raw")"; BOOT_ANALYZE_TIME_VALID=1
    elif (( rc == 124 )); then add_limitation "La consulta systemd-analyze time superó 6s."; fi
    rc=0; raw="$(run_with_timeout 7 env LC_ALL=C systemd-analyze blame --no-pager 2>/dev/null)" || rc=$?
    if (( rc == 0 )); then BOOT_ANALYZE_BLAME="$(printf '%s\n' "$raw" | sanitize_terminal_text | sed '/^[[:space:]]*$/d' | head -n "${BOOT_ANALYZE_BLAME_LIMIT:-$BOOT_ANALYZE_BLAME_LIMIT_DEFAULT}")"; BOOT_ANALYZE_BLAME_VALID=1
    elif (( rc == 124 )); then add_limitation "La consulta systemd-analyze blame superó 7s."; fi
    rc=0; raw="$(run_with_timeout 7 env LC_ALL=C systemd-analyze critical-chain --no-pager 2>/dev/null)" || rc=$?
    if (( rc == 0 )); then BOOT_CRITICAL_CHAIN="$(printf '%s\n' "$raw" | sanitize_terminal_text | head -n 60)"; BOOT_CRITICAL_CHAIN_VALID=1
    elif (( rc == 124 )); then add_limitation "La consulta systemd-analyze critical-chain superó 7s."; fi
  fi

  # Journal: if logging already established that journal access is unavailable,
  # do not hit the same failing service again.
  local can_query_journal=1
  if [[ "${LOGGING_COLLECTED:-0}" == 1 && "${JOURNAL_ACCESS:-n/d}" != "disponible" ]]; then
    can_query_journal=0
    add_limitation "Boot reutiliza el estado de Logging: journald no fue consultable de forma fiable, por lo que se omiten consultas duplicadas del boot."
  fi
  if (( can_query_journal == 1 )) && have_cmd journalctl; then
    local raw="" rc=0
    rc=0; raw="$(run_with_timeout 5 journalctl --list-boots --no-pager 2>/dev/null)" || rc=$?
    if (( rc == 0 )); then
      BOOT_JOURNAL_BOOT_COUNT="$(printf '%s\n' "$raw" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
      if [[ "$BOOT_JOURNAL_BOOT_COUNT" =~ ^[0-9]+$ ]] && (( BOOT_JOURNAL_BOOT_COUNT > 1 )); then BOOT_PREVIOUS_BOOT_AVAILABLE="sí"; else BOOT_PREVIOUS_BOOT_AVAILABLE="no"; fi
    else
      BOOT_JOURNAL_BOOT_COUNT="n/d"; BOOT_PREVIOUS_BOOT_AVAILABLE="n/d"
    fi

    rc=0; raw="$(run_with_timeout 6 journalctl -b -p warning -n "$BOOT_JOURNAL_LIMIT_DEFAULT" --no-pager -o short-iso 2>/dev/null)" || rc=$?
    if (( rc == 0 )); then
      BOOT_JOURNAL_QUERY_VALID=1; BOOT_JOURNAL_EVIDENCE="$(printf '%s\n' "$raw" | sanitize_terminal_text | sed '/^[[:space:]]*$/d; /^-- No entries --$/d')"
      BOOT_EMERGENCY_HINTS="$(grep -Eic 'emergency mode|rescue mode|entered emergency|emergency\.target|rescue\.target' <<<"$BOOT_JOURNAL_EVIDENCE" || true)"
      BOOT_DEVICE_TIMEOUT_HINTS="$(grep -Eic 'timed out waiting for device|dependency failed for .*\.device|start job is running for .*device' <<<"$BOOT_JOURNAL_EVIDENCE" || true)"
      BOOT_FSCK_HINTS="$(grep -Eic 'fsck.*(failed|error)|filesystem check failed|UNEXPECTED INCONSISTENCY' <<<"$BOOT_JOURNAL_EVIDENCE" || true)"
      BOOT_MOUNT_FAILURE_HINTS="$(grep -Eic 'failed to mount|mount process exited|dependency failed for .*\.mount' <<<"$BOOT_JOURNAL_EVIDENCE" || true)"
    elif (( rc == 124 )); then add_limitation "La consulta journalctl del boot actual superó 6s."; else add_limitation "No se pudo consultar journalctl del boot actual."; fi

    rc=0; raw="$(run_with_timeout 6 journalctl -k -b -p warning -n "$BOOT_JOURNAL_LIMIT_DEFAULT" --no-pager -o short-iso 2>/dev/null)" || rc=$?
    if (( rc == 0 )); then
      BOOT_KERNEL_JOURNAL_QUERY_VALID=1; BOOT_KERNEL_EVIDENCE="$(printf '%s\n' "$raw" | sanitize_terminal_text | sed '/^[[:space:]]*$/d; /^-- No entries --$/d')"
      BOOT_IO_KERNEL_HINTS="$(grep -Eic 'I/O error|I/O timeout|blk_update_request|nvme.*timeout|EXT4-fs error|XFS.*corrupt|Buffer I/O error' <<<"$BOOT_KERNEL_EVIDENCE" || true)"
    elif (( rc == 124 )); then add_limitation "La consulta journalctl -k del boot actual superó 6s."; fi
  elif ! have_cmd journalctl; then
    add_limitation "Journalctl no está disponible; evidencias históricas del boot no evaluables."
  fi
}

analyze_boot() {
  if (( BOOT_CONTEXT_REPRESENTATIVE == 0 )); then
    add_next_step "Ejecutar SYSdiag en el host/VM si se necesita diagnosticar su secuencia de boot real; dentro del contenedor el contexto es parcial." \
      "systemd-detect-virt --container" "cat /proc/1/cgroup"
  fi

  if (( BOOT_FSTAB_INVALID_COUNT > 0 )); then
    add_finding BOOT_FSTAB_INVALID boot fstab_syntax 4 high "/etc/fstab contiene ${BOOT_FSTAB_INVALID_COUNT} entrada(s) que SYSdiag no pudo interpretar como válidas."
    add_next_step "Revisar sintaxis de fstab antes de un próximo reboot; una entrada inválida puede impedir o retrasar mounts esperados." \
      "findmnt --verify --verbose" "cat /etc/fstab"
  fi
  if (( BOOT_FSTAB_DUPLICATE_MOUNT_COUNT > 0 )); then
    add_finding BOOT_FSTAB_DUPLICATE boot fstab_syntax 2 medium "Fstab contiene ${BOOT_FSTAB_DUPLICATE_MOUNT_COUNT} mountpoint(s) repetidos; el comportamiento efectivo merece revisión."
  fi
  if (( BOOT_FSTAB_MISSING_REQUIRED > 0 )); then
    add_finding BOOT_FSTAB_MISSING_REQUIRED boot fstab_reference 5 high "${BOOT_FSTAB_MISSING_REQUIRED} referencia(s) local(es) obligatoria(s) de fstab no existen actualmente."
    add_next_step "Comparar las referencias obligatorias de fstab con los UUID/LABEL/dispositivos realmente presentes; no editar ni reiniciar hasta entender qué mount es crítico." \
      "lsblk -f" "blkid" "findmnt --verify --verbose" "cat /etc/fstab"
  fi
  if (( BOOT_FSTAB_MISSING_NOFAIL > 0 || BOOT_FSTAB_MISSING_NOAUTO > 0 || BOOT_FSTAB_MISSING_AUTOMOUNT > 0 )); then
    add_finding BOOT_FSTAB_MISSING_OPTIONAL boot fstab_optional 1 low "Hay referencias de fstab ausentes protegidas por nofail/noauto/x-systemd.automount; se muestran como evidencia, no como causa automática del boot."
  fi
  if [[ "$BOOT_FAILED_MOUNT_QUERY_VALID" == 1 && "$BOOT_FAILED_MOUNTS_COUNT" =~ ^[0-9]+$ ]] && (( BOOT_FAILED_MOUNTS_COUNT > 0 )); then
    add_finding BOOT_FAILED_MOUNTS boot mount_units 4 high "Systemd mantiene ${BOOT_FAILED_MOUNTS_COUNT} unidad(es) .mount en estado failed."
    add_next_step "Correlacionar cada .mount fallida con fstab, unidad generada y journal del boot actual." \
      "systemctl --failed --type=mount --no-pager" "systemctl status <unidad.mount> --no-pager -l" "journalctl -b -u <unidad.mount> --no-pager"
  fi
  if (( BOOT_EMERGENCY_HINTS > 0 )); then
    add_finding BOOT_EMERGENCY boot boot_target 4 high "El journal del boot contiene indicios de rescue/emergency (${BOOT_EMERGENCY_HINTS}); es un estado de recuperación, no la causa raíz."
  fi
  if (( BOOT_DEVICE_TIMEOUT_HINTS > 0 )); then
    add_finding BOOT_DEVICE_TIMEOUT boot device_wait 4 high "El boot contiene ${BOOT_DEVICE_TIMEOUT_HINTS} indicio(s) de espera/timeout de dispositivos."
  fi
  if (( BOOT_FSCK_HINTS > 0 )); then
    add_finding BOOT_FSCK boot filesystem_check 4 high "El boot contiene ${BOOT_FSCK_HINTS} indicio(s) de fallo de comprobación de filesystem."
  fi
  if (( BOOT_MOUNT_FAILURE_HINTS > 0 )); then
    add_finding BOOT_MOUNT_JOURNAL boot mount_journal 3 high "El journal del boot contiene ${BOOT_MOUNT_FAILURE_HINTS} indicio(s) de fallos de mount/dependencias de mount."
  fi
  if (( BOOT_IO_KERNEL_HINTS > 0 )); then
    add_finding BOOT_KERNEL_IO boot kernel_storage 4 high "El kernel del boot contiene ${BOOT_IO_KERNEL_HINTS} indicio(s) de error/timeout de almacenamiento o filesystem."
    add_next_step "Revisar el contexto kernel del boot antes de atribuir el fallo a systemd o a fstab." \
      "journalctl -k -b --no-pager" "dmesg -T" "lsblk -f"
  fi

  if (( BOOT_ANALYZE_BLAME_VALID == 1 )); then
    add_next_step "Si el síntoma es boot lento, usar blame para localizar unidades lentas y critical-chain para comprobar cuáles condicionaron realmente el camino crítico." \
      "systemd-analyze time" "systemd-analyze blame" "systemd-analyze critical-chain"
  fi
}

print_boot() {
  section "BOOT / ARRANQUE"
  kv "Contexto:" "${BOOT_CONTEXT:-n/d}"
  kv "Kernel actual:" "${BOOT_KERNEL:-n/d}"
  kv "Parámetro root= del cmdline:" "${BOOT_ROOT_ARG:-n/d}"
  kv "Root montado desde:" "${BOOT_ROOT_SOURCE:-n/d}"
  kv "Filesystem de /:" "${BOOT_ROOT_FSTYPE:-n/d}"
  kv "Generador initramfs detectado:" "${BOOT_INITRAMFS_STYLE:-n/d}"
  if (( ${BOOT_CONTEXT_REPRESENTATIVE:-1} == 0 )); then
    warn "Contexto contenedor: root= del kernel y / del contenedor pueden pertenecer a capas distintas; no se correlacionan como evidencia de boot del host."
  fi

  subsection "fstab"
  kv_at 4 38 "Lectura de fstab:" "$([[ ${BOOT_FSTAB_PRESENT:-0} -eq 1 ]] && echo sí || echo no)"
  kv_at 4 38 "Entradas interpretadas:" "${BOOT_FSTAB_ENTRY_COUNT:-0}"
  kv_at 4 38 "Entradas inválidas:" "${BOOT_FSTAB_INVALID_COUNT:-0}"
  kv_at 4 38 "Mountpoints duplicados:" "${BOOT_FSTAB_DUPLICATE_MOUNT_COUNT:-0}"
  kv_at 4 38 "Referencias obligatorias ausentes:" "${BOOT_FSTAB_MISSING_REQUIRED:-0}"
  kv_at 4 38 "Ausentes con nofail:" "${BOOT_FSTAB_MISSING_NOFAIL:-0}"
  kv_at 4 38 "Ausentes con noauto:" "${BOOT_FSTAB_MISSING_NOAUTO:-0}"
  kv_at 4 38 "Ausentes con automount:" "${BOOT_FSTAB_MISSING_AUTOMOUNT:-0}"
  kv_at 4 38 "Mounts remotos declarados:" "${BOOT_FSTAB_REMOTE_COUNT:-0}"
  if ((${#BOOT_FSTAB_DETAILS[@]})); then
    printf '\n    Referencias/entradas que requieren atención:\n'
    local d mode spec mnt fstype shown=0
    for d in "${BOOT_FSTAB_DETAILS[@]}"; do
      (( shown >= BOOT_FSTAB_DETAIL_LIMIT_DEFAULT )) && break
      if [[ "$d" == INVALID\|* ]]; then printf '      - %s\n' "${d#INVALID|}"; else
        IFS='|' read -r mode spec mnt fstype <<<"$d"
        printf '      - %-9s %-28s -> %-24s (%s)\n' "$mode" "$spec" "$mnt" "$fstype"
      fi
      ((shown+=1))
    done
  fi

  subsection "systemd / tiempos"
  kv_at 4 38 "Mount units failed:" "${BOOT_FAILED_MOUNTS_COUNT:-n/d}"
  kv_at 4 38 "Disponibilidad de systemd-analyze:" "$([[ ${BOOT_SYSTEMD_ANALYZE_AVAILABLE:-0} -eq 1 ]] && echo sí || echo no)"
  kv_at 4 38 "Tiempo de arranque:" "${BOOT_ANALYZE_TIME:-n/d}"
  if (( ${VERBOSE:-0} == 1 )) && [[ -n "${BOOT_ANALYZE_BLAME:-}" ]]; then
    printf '\n    Unidades con mayor duración (blame; duración ≠ retraso causal):\n'
    while IFS= read -r line; do printf '      %s\n' "$line"; done <<<"$BOOT_ANALYZE_BLAME"
  fi
  if (( ${VERBOSE:-0} == 1 )) && [[ -n "${BOOT_CRITICAL_CHAIN:-}" ]]; then
    printf '\n    Critical chain (camino que condicionó el target):\n'
    while IFS= read -r line; do printf '      %s\n' "$line"; done <<<"$BOOT_CRITICAL_CHAIN"
  fi

  subsection "Journal del boot"
  kv_at 4 38 "Boots visibles:" "${BOOT_JOURNAL_BOOT_COUNT:-n/d}"
  kv_at 4 38 "Boot anterior consultable:" "${BOOT_PREVIOUS_BOOT_AVAILABLE:-n/d}"
  kv_at 4 38 "Indicios rescue/emergency:" "${BOOT_EMERGENCY_HINTS:-0}"
  kv_at 4 38 "Timeouts/esperas de device:" "${BOOT_DEVICE_TIMEOUT_HINTS:-0}"
  kv_at 4 38 "Fallos fsck:" "${BOOT_FSCK_HINTS:-0}"
  kv_at 4 38 "Fallos de mount:" "${BOOT_MOUNT_FAILURE_HINTS:-0}"
  kv_at 4 38 "Errores kernel storage/fs:" "${BOOT_IO_KERNEL_HINTS:-0}"

  if (( ${EXPLAIN:-0} == 1 )); then
    printf '\n  Cómo interpretar Boot:\n'
    printf '    - Firmware/UEFI y GRUB ocurren antes de que SYSdiag pueda ejecutarse; esta sección no afirma diagnosticarlos retrospectivamente.\n'
    printf '    - Caer en initramfs suele situar el problema antes de systemd: root, storage, LVM/LUKS/RAID, drivers o filesystem.\n'
    printf '    - emergency/rescue es una consecuencia de no alcanzar el target esperado; no demuestra que systemd sea la causa.\n'
    printf '    - systemd-analyze blame muestra duración; critical-chain ayuda a ver qué condicionó realmente el arranque.\n'
  fi

  printf '\n  Comandos útiles de investigación (manuales/read-only):\n'
  printf '    $ cat /proc/cmdline\n'
  printf '    $ lsblk -f\n'
  printf '    $ blkid\n'
  printf '    $ findmnt --verify --verbose\n'
  printf '    $ systemctl --failed --type=mount --no-pager\n'
  printf '    $ systemd-analyze time\n'
  printf '    $ systemd-analyze blame\n'
  printf '    $ systemd-analyze critical-chain\n'
  printf '    $ journalctl -b --no-pager\n'
  printf '    $ journalctl -k -b --no-pager\n'
  printf '    $ journalctl -b -1 --no-pager\n'
}

# ===== modules/containers.sh =====

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

# ===== modules/kubernetes.sh =====

# Kubernetes/OpenShift diagnostics through the API and existing cluster observability.
# Read-only by design: no apply/create/delete/patch/edit/exec/debug/port-forward/rollout actions.

K8S_MODE="${K8S_MODE:-deep}"
K8S_SCOPE="${K8S_SCOPE:-cluster}"
K8S_TARGET_NODE="${K8S_TARGET_NODE:-}"
K8S_TARGET_NAMESPACE="${K8S_TARGET_NAMESPACE:-}"
K8S_TARGET_POD="${K8S_TARGET_POD:-}"
K8S_CONTEXT="${K8S_CONTEXT:-}"
K8S_KUBECONFIG="${K8S_KUBECONFIG:-}"
K8S_AUTH_PROMPT="${K8S_AUTH_PROMPT:-1}"
K8S_INTERACTIVE_CONFIG="${K8S_INTERACTIVE_CONFIG:-0}"
K8S_DETAIL_LIMIT=200
K8S_EVENT_LIMIT=250
K8S_EVENT_RECENT_MINUTES="${K8S_EVENT_RECENT_MINUTES:-120}"

K8S_CLI=""
K8S_CLIENT_VERSION="n/d"
K8S_ACCESS="no disponible"
K8S_CONTEXT_EFFECTIVE="n/d"
K8S_SERVER="n/d"
K8S_USER="n/d"
K8S_PLATFORM="Kubernetes"
K8S_SERVER_VERSION="n/d"
K8S_OPENSHIFT_VERSION="n/d"
K8S_EFFECTIVE_KUBECONFIG=""
K8S_PERMISSION_DENIED=0
K8S_PERMISSION_CHECKED=0
K8S_NODE_COUNT=0
K8S_NODE_NOTREADY_COUNT=0
K8S_NODE_MEMORY_PRESSURE_COUNT=0
K8S_NODE_DISK_PRESSURE_COUNT=0
K8S_NODE_PID_PRESSURE_COUNT=0
K8S_POD_COUNT=0
K8S_POD_PENDING_COUNT=0
K8S_POD_FAILED_COUNT=0
K8S_POD_NOTREADY_COUNT=0
K8S_POD_HIGH_RESTART_COUNT=0
K8S_POD_OOMKILLED_COUNT=0
K8S_POD_CRASHLOOP_COUNT=0
K8S_POD_IMAGEPULL_COUNT=0
K8S_POD_EVICTED_COUNT=0
K8S_SERVICE_COUNT=0
K8S_SERVICE_NO_ENDPOINT_COUNT=0
K8S_SERVICE_NO_READY_ENDPOINT_COUNT=0
K8S_PVC_COUNT=0
K8S_PVC_PENDING_COUNT=0
K8S_WORKLOAD_DEGRADED_COUNT=0
K8S_WARNING_EVENT_COUNT=0
K8S_WARNING_EVENT_RECENT_COUNT=0
K8S_WARNING_EVENT_STALE_COUNT=0
K8S_WARNING_EVENT_UNKNOWN_TIME_COUNT=0
K8S_FAILED_SCHEDULING_COUNT=0
K8S_PROBE_FAILURE_COUNT=0
K8S_FAILED_MOUNT_COUNT=0
K8S_FAILED_ATTACH_COUNT=0
K8S_STORAGE_PROVISION_FAILURE_COUNT=0
K8S_METRICS_AVAILABLE=0
K8S_KUBELET_STATS_OK_COUNT=0
K8S_KUBELET_STATS_FAIL_COUNT=0
K8S_OPENSHIFT_DEGRADED_OPERATORS=0
K8S_OPENSHIFT_UNAVAILABLE_OPERATORS=0
K8S_OPENSHIFT_MACHINE_FAILED_COUNT=0
K8S_OPENSHIFT_NODE_LOG_HINT_COUNT=0
K8S_STORAGECLASS_LIST_AVAILABLE=0
K8S_ENDPOINTSLICE_LIST_AVAILABLE=0

declare -a K8S_NODE_DETAILS K8S_POD_ISSUES K8S_SERVICE_ISSUES K8S_PVC_ISSUES K8S_WORKLOAD_ISSUES K8S_WARNING_EVENTS K8S_OPENSHIFT_ISSUES K8S_NODE_METRICS
declare -a K8S_SUSPECT_NODES
declare -A K8S_NODE_SUSPECT_SEEN K8S_EP_TOTAL K8S_EP_READY K8S_STORAGECLASS_SEEN
K8S_NODE_DETAILS=(); K8S_POD_ISSUES=(); K8S_SERVICE_ISSUES=(); K8S_PVC_ISSUES=(); K8S_WORKLOAD_ISSUES=(); K8S_WARNING_EVENTS=(); K8S_OPENSHIFT_ISSUES=(); K8S_NODE_METRICS=(); K8S_SUSPECT_NODES=()

_k8s_clean() {
  if (($#)); then
    printf '%s' "${1-}" | sanitize_terminal_text | tr '|' '/' | head -c 600
  else
    sanitize_terminal_text | tr '|' '/' | head -c 600
  fi
}

_k8s_id() {
  printf '%s' "${1-}" | LC_ALL=C tr -c '[:alnum:]_-' '_' | cut -c1-100
}

_k8s_yaml_sq() {
  local x="${1-}"
  x="${x//\'/\'\'}"
  printf "'%s'" "$x"
}

_k8s_sum_ints() {
  local raw="${1-}"
  awk 'BEGIN{s=0} {gsub(/[^0-9]+/," "); for(i=1;i<=NF;i++) s+=$i} END{print s+0}' <<<"$raw"
}

_k8s_count_tokens() {
  local raw="${1-}"
  [[ -n "$raw" && "$raw" != "<none>" ]] || { printf '0'; return; }
  awk 'BEGIN{n=0} {gsub(/[,[:space:]]+/," "); for(i=1;i<=NF;i++) if($i!="<none>" && $i!="") n++} END{print n+0}' <<<"$raw"
}

_k8s_count_true() {
  local raw="${1-}" total="${2:-0}"
  if [[ -z "$raw" || "$raw" == "<none>" ]]; then printf '%s' "$total"; return; fi
  awk 'BEGIN{n=0} {gsub(/[,[:space:]]+/," "); for(i=1;i<=NF;i++) if(tolower($i)=="true" || $i=="<none>") n++} END{print n+0}' <<<"$raw"
}

_k8s_event_is_recent() {
  local ts="${1-}" now epoch age max_age
  [[ -n "$ts" && "$ts" != "<none>" && "$ts" != "n/d" ]] || return 2
  have_cmd date || return 2
  epoch="$(date -d "$ts" +%s 2>/dev/null || true)"
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 2
  now="$(date +%s)"
  [[ "$now" =~ ^[0-9]+$ ]] || return 2
  age=$((now - epoch)); max_age=$((K8S_EVENT_RECENT_MINUTES * 60))
  # Tolera hasta cinco minutos de desfase de reloj entre cliente y cluster.
  (( age >= -300 && age <= max_age ))
}

_k8s_capture() {
  local seconds="$1"; shift
  local -a cmd=("$K8S_CLI")
  [[ -n "$K8S_EFFECTIVE_KUBECONFIG" ]] && cmd+=(--kubeconfig "$K8S_EFFECTIVE_KUBECONFIG")
  [[ -n "$K8S_CONTEXT" ]] && cmd+=(--context "$K8S_CONTEXT")
  cmd+=("$@")
  run_with_timeout "$seconds" "${cmd[@]}"
}

_k8s_scope_args() {
  case "$K8S_SCOPE" in
    namespace|pod) printf '%s\n' -n "$K8S_TARGET_NAMESPACE" ;;
    *) printf '%s\n' -A ;;
  esac
}

_k8s_add_suspect_node() {
  local node="${1-}"
  [[ -n "$node" && "$node" != "<none>" ]] || return 0
  [[ -n "${K8S_NODE_SUSPECT_SEEN[$node]:-}" ]] && return 0
  K8S_NODE_SUSPECT_SEEN[$node]=1
  K8S_SUSPECT_NODES+=("$node")
}

_k8s_prompt_configuration() {
  (( K8S_INTERACTIVE_CONFIG == 1 )) || return 0
  [[ -t 0 && -t 1 ]] || return 0
  local input
  printf '\n  Profundidad Kubernetes/OpenShift:\n'
  printf '    1) Rápido\n    2) Profundo\n    3) Exhaustivo\n'
  printf '  Selecciona [2]: '
  IFS= read -r input || true
  case "${input:-2}" in 1) K8S_MODE=quick ;; 3) K8S_MODE=exhaustive ;; *) K8S_MODE=deep ;; esac
  printf '\n  Ámbito:\n'
  printf '    1) Cluster completo\n    2) Nodo\n    3) Namespace\n    4) Pod\n'
  printf '  Selecciona [1]: '
  IFS= read -r input || true
  case "${input:-1}" in
    2) K8S_SCOPE=node; printf '  Nodo: '; IFS= read -r K8S_TARGET_NODE || true ;;
    3) K8S_SCOPE=namespace; printf '  Namespace: '; IFS= read -r K8S_TARGET_NAMESPACE || true ;;
    4) K8S_SCOPE=pod; printf '  Namespace: '; IFS= read -r K8S_TARGET_NAMESPACE || true; printf '  Pod: '; IFS= read -r K8S_TARGET_POD || true ;;
    *) K8S_SCOPE=cluster ;;
  esac
}

_k8s_validate_scope() {
  case "$K8S_MODE" in quick|deep|exhaustive) ;; *) add_limitation "El modo Kubernetes '$K8S_MODE' no es válido; se usa deep."; K8S_MODE=deep ;; esac
  case "$K8S_SCOPE" in
    cluster) ;;
    node) [[ -n "$K8S_TARGET_NODE" ]] || { add_limitation "El ámbito node requiere un nombre de nodo; se usa cluster."; K8S_SCOPE=cluster; } ;;
    namespace) [[ -n "$K8S_TARGET_NAMESPACE" ]] || { add_limitation "El ámbito namespace requiere un namespace; se usa cluster."; K8S_SCOPE=cluster; } ;;
    pod) [[ -n "$K8S_TARGET_NAMESPACE" && -n "$K8S_TARGET_POD" ]] || { add_limitation "El ámbito pod requiere namespace y nombre; se usa cluster."; K8S_SCOPE=cluster; } ;;
    *) add_limitation "El ámbito Kubernetes '$K8S_SCOPE' no es válido; se usa cluster."; K8S_SCOPE=cluster ;;
  esac
  case "$K8S_MODE" in quick) K8S_DETAIL_LIMIT=80; K8S_EVENT_LIMIT=100 ;; deep) K8S_DETAIL_LIMIT=250; K8S_EVENT_LIMIT=300 ;; exhaustive) K8S_DETAIL_LIMIT=1000; K8S_EVENT_LIMIT=1000 ;; esac
}

_k8s_write_temp_kubeconfig() {
  local server="$1" method="$2" user="$3" secret="$4" file="$RUNTIME_DIR/kubeconfig-sysdiag"
  [[ "$server" != *$'\n'* && "$user" != *$'\n'* && "$secret" != *$'\n'* ]] || return 1
  umask 077
  {
    printf 'apiVersion: v1\nkind: Config\nclusters:\n- name: sysdiag\n  cluster:\n    server: '; _k8s_yaml_sq "$server"; printf '\n'
    printf 'users:\n- name: sysdiag\n  user:\n'
    if [[ "$method" == token ]]; then printf '    token: '; _k8s_yaml_sq "$secret"; printf '\n'; else printf '    username: '; _k8s_yaml_sq "$user"; printf '\n    password: '; _k8s_yaml_sq "$secret"; printf '\n'; fi
    printf 'contexts:\n- name: sysdiag\n  context:\n    cluster: sysdiag\n    user: sysdiag\ncurrent-context: sysdiag\n'
  } > "$file" || return 1
  chmod 600 "$file" 2>/dev/null || true
  K8S_EFFECTIVE_KUBECONFIG="$file"
  K8S_CONTEXT=""
}

_k8s_try_interactive_auth() {
  (( K8S_AUTH_PROMPT == 1 )) || return 1
  local machine_interactive="${SYSDIAG_MACHINE_INTERACTIVE:-0}" prompt_fd=1
  [[ -t 0 && ( -t 1 || "$machine_interactive" == 1 ) ]] || return 1
  if (( JSON_OUTPUT == 1 )) && [[ "$machine_interactive" != 1 ]]; then return 1; fi
  [[ "$machine_interactive" == 1 ]] && prompt_fd=2
  local server="" method="" user="" secret="" input="" tmp="$RUNTIME_DIR/kubeconfig-sysdiag"
  printf '\n  No existe una sesión válida contra el cluster.\n' >&"$prompt_fd"
  printf '  API URL: ' >&"$prompt_fd"
  IFS= read -r server || return 1
  [[ -n "$server" ]] || return 1
  printf '    1) Token\n    2) Usuario y contraseña\n    3) Omitir Kubernetes/OpenShift\n' >&"$prompt_fd"
  printf '  Método [1]: ' >&"$prompt_fd"
  IFS= read -r input || true
  case "${input:-1}" in
    1)
      method=token; printf '  Token: ' >&"$prompt_fd"; IFS= read -rs secret || return 1; printf '\n' >&"$prompt_fd"
      _k8s_write_temp_kubeconfig "$server" token "" "$secret" || return 1
      ;;
    2)
      printf '  Usuario: ' >&"$prompt_fd"; IFS= read -r user || return 1
      if [[ "$K8S_CLI" == oc ]]; then
        rm -f -- "$tmp" 2>/dev/null || true
        printf '  OpenShift solicitará la contraseña directamente; SYSdiag no la leerá ni la pasará en argv.\n' >&"$prompt_fd"
        if [[ "$machine_interactive" == 1 ]]; then
          if ! run_with_timeout 60 oc login "$server" -u "$user" --kubeconfig="$tmp" >&2; then
            add_limitation "La autenticación OpenShift con usuario/contraseña no fue aceptada. No se ha modificado el kubeconfig habitual."
            return 1
          fi
        elif ! run_with_timeout 60 oc login "$server" -u "$user" --kubeconfig="$tmp"; then
          add_limitation "La autenticación OpenShift con usuario/contraseña no fue aceptada. No se ha modificado el kubeconfig habitual."
          return 1
        fi
        chmod 600 "$tmp" 2>/dev/null || true
        K8S_EFFECTIVE_KUBECONFIG="$tmp"; K8S_CONTEXT=""
      else
        printf '  Contraseña: ' >&"$prompt_fd"; IFS= read -rs secret || return 1; printf '\n' >&"$prompt_fd"
        _k8s_write_temp_kubeconfig "$server" basic "$user" "$secret" || return 1
      fi
      ;;
    *) return 1 ;;
  esac
  secret=""; unset secret
  return 0
}

_k8s_detect_access() {
  if [[ -n "${K8S_CLI_OVERRIDE:-}" ]]; then
    K8S_CLI="$K8S_CLI_OVERRIDE"
    if ! have_cmd "$K8S_CLI"; then
      add_limitation "El cliente Kubernetes/OpenShift configurado no puede ejecutarse; el diagnóstico Kubernetes/OpenShift no puede continuar."
      return 1
    fi
  elif have_cmd oc; then
    K8S_CLI=oc
  elif have_cmd kubectl; then
    K8S_CLI=kubectl
  else
    add_limitation "No se encontró kubectl ni oc; el diagnóstico Kubernetes/OpenShift no puede ejecutarse."
    return 1
  fi

  K8S_EFFECTIVE_KUBECONFIG="$K8S_KUBECONFIG"
  K8S_CLIENT_VERSION="$(_k8s_capture 4 version --client --output=yaml 2>/dev/null | awk -F': ' '/gitVersion:/{print $2; exit}' || true)"
  [[ -n "$K8S_CLIENT_VERSION" ]] || K8S_CLIENT_VERSION="$(_k8s_capture 4 version --client 2>/dev/null | head -n1 | _k8s_clean || true)"
  [[ -n "$K8S_CLIENT_VERSION" ]] || K8S_CLIENT_VERSION="n/d"

  if ! _k8s_capture 8 get --raw=/version >/dev/null 2>&1; then
    _k8s_try_interactive_auth || true
  fi
  if ! _k8s_capture 8 get --raw=/version >/dev/null 2>&1; then
    add_limitation "El cliente Kubernetes/OpenShift está disponible, pero no hay una sesión válida o el API Server no responde."
    return 1
  fi
  K8S_ACCESS="disponible"
  if [[ -n "$K8S_CONTEXT" ]]; then
    K8S_CONTEXT_EFFECTIVE="$(_k8s_clean "$K8S_CONTEXT")"
  else
    K8S_CONTEXT_EFFECTIVE="$(_k8s_capture 3 config current-context 2>/dev/null | head -n1 | _k8s_clean || true)"
    [[ -n "$K8S_CONTEXT_EFFECTIVE" ]] || K8S_CONTEXT_EFFECTIVE="temporal/directo"
  fi
  K8S_SERVER="$(_k8s_capture 3 config view --minify -o 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null | _k8s_clean || true)"
  [[ -n "$K8S_SERVER" ]] || K8S_SERVER="n/d"
  K8S_USER="$(_k8s_capture 4 auth whoami -o name 2>/dev/null | head -n1 | _k8s_clean || true)"
  [[ -n "$K8S_USER" ]] || K8S_USER="$(_k8s_capture 3 config view --minify -o 'jsonpath={.contexts[0].context.user}' 2>/dev/null | _k8s_clean || true)"
  [[ -n "$K8S_USER" ]] || K8S_USER="n/d"
  K8S_SERVER_VERSION="$(_k8s_capture 5 version --output=yaml 2>/dev/null | awk -F': ' '/serverVersion:/{p=1;next} p&&/gitVersion:/{print $2; exit}' || true)"
  [[ -n "$K8S_SERVER_VERSION" ]] || K8S_SERVER_VERSION="n/d"

  local apis
  apis="$(_k8s_capture 6 api-resources --api-group=config.openshift.io -o name 2>/dev/null || true)"
  if grep -q 'clusterversions' <<<"$apis"; then
    K8S_PLATFORM="OpenShift"
    K8S_OPENSHIFT_VERSION="$(_k8s_capture 5 get clusterversion version -o 'jsonpath={.status.desired.version}' 2>/dev/null | _k8s_clean || true)"
    [[ -n "$K8S_OPENSHIFT_VERSION" ]] || K8S_OPENSHIFT_VERSION="n/d"
  fi
  return 0
}

_k8s_check_permissions() {
  local check desc
  local -a checks=(
    'list nodes|Nodes'
    'list pods --all-namespaces|Pods'
    'list services --all-namespaces|Services'
    'list endpointslices.discovery.k8s.io --all-namespaces|EndpointSlices'
    'list persistentvolumeclaims --all-namespaces|PVC'
    'list storageclasses.storage.k8s.io|StorageClass'
    'list events --all-namespaces|Events'
  )
  for check in "${checks[@]}"; do
    local args="${check%%|*}"; desc="${check#*|}"; ((K8S_PERMISSION_CHECKED+=1))
    # shellcheck disable=SC2086
    if [[ "$(_k8s_capture 5 auth can-i $args 2>/dev/null | head -n1)" != yes ]]; then
      ((K8S_PERMISSION_DENIED+=1)); add_limitation "El usuario actual no puede listar $desc; esa parte del diagnóstico quedará limitada."
    fi
  done
}

_k8s_collect_nodes() {
  local raw="" line name ready mem disk pid unsched cpu memalloc
  local -a args=(get nodes --no-headers -o 'custom-columns=NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,MEMORY:.status.conditions[?(@.type=="MemoryPressure")].status,DISK:.status.conditions[?(@.type=="DiskPressure")].status,PID:.status.conditions[?(@.type=="PIDPressure")].status,UNSCHED:.spec.unschedulable,CPU:.status.allocatable.cpu,MEMALLOC:.status.allocatable.memory')
  [[ "$K8S_SCOPE" == node ]] && args+=(--field-selector "metadata.name=$K8S_TARGET_NODE")
  raw="$(_k8s_capture 12 "${args[@]}" 2>/dev/null || true)"
  [[ -n "$raw" ]] || { add_limitation "No se pudo obtener el inventario de nodos."; return 0; }
  while IFS=$'\t' read -r name ready mem disk pid unsched cpu memalloc; do
    [[ -n "$name" ]] || continue
    ((K8S_NODE_COUNT+=1))
    name="$(_k8s_clean "$name")"; ready="$(_k8s_clean "$ready")"; mem="$(_k8s_clean "$mem")"; disk="$(_k8s_clean "$disk")"; pid="$(_k8s_clean "$pid")"
    K8S_NODE_DETAILS+=("$name|$ready|$mem|$disk|$pid|${unsched:-false}|${cpu:-n/d}|${memalloc:-n/d}")
    if [[ "$ready" != True ]]; then
      ((K8S_NODE_NOTREADY_COUNT+=1)); _k8s_add_suspect_node "$name"
      add_finding "K8S_NODE_NOTREADY_$(_k8s_id "$name")" kubernetes node_condition 5 high "El nodo $name no está Ready. NotReady es un síntoma; se requiere correlación con kubelet, runtime, red o Linux."
    fi
    if [[ "$mem" == True ]]; then
      ((K8S_NODE_MEMORY_PRESSURE_COUNT+=1)); _k8s_add_suspect_node "$name"
      add_finding "K8S_NODE_MEMORY_$(_k8s_id "$name")" kubernetes node_pressure 4 high "El nodo $name informa MemoryPressure=True; se observa presión global de memoria a nivel de nodo."
    fi
    if [[ "$disk" == True ]]; then
      ((K8S_NODE_DISK_PRESSURE_COUNT+=1)); _k8s_add_suspect_node "$name"
      add_finding "K8S_NODE_DISK_$(_k8s_id "$name")" kubernetes node_pressure 4 high "El nodo $name informa DiskPressure=True; se observa presión de almacenamiento a nivel de nodo."
    fi
    if [[ "$pid" == True ]]; then
      ((K8S_NODE_PID_PRESSURE_COUNT+=1)); _k8s_add_suspect_node "$name"
      add_finding "K8S_NODE_PID_$(_k8s_id "$name")" kubernetes node_pressure 4 high "El nodo $name informa PIDPressure=True; se observa presión de PIDs a nivel de nodo."
    fi
  done <<<"$raw"
}

_k8s_pod_args() {
  case "$K8S_SCOPE" in
    cluster) printf '%s\n' -A ;;
    namespace) printf '%s\n' -n "$K8S_TARGET_NAMESPACE" ;;
    node) printf '%s\n' -A --field-selector "spec.nodeName=$K8S_TARGET_NODE" ;;
    pod) printf '%s\n' -n "$K8S_TARGET_NAMESPACE" "$K8S_TARGET_POD" ;;
  esac
}

_k8s_collect_pods() {
  local -a scope_args=(); mapfile -t scope_args < <(_k8s_pod_args)
  local raw="" ns name phase ready node restarts waiting last exitcode reason total_restarts issue=0
  raw="$(_k8s_capture 20 get pods "${scope_args[@]}" --no-headers -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,READY:.status.conditions[?(@.type=="Ready")].status,NODE:.spec.nodeName,RESTARTS:.status.containerStatuses[*].restartCount,WAITING:.status.containerStatuses[*].state.waiting.reason,LAST:.status.containerStatuses[*].lastState.terminated.reason,EXIT:.status.containerStatuses[*].lastState.terminated.exitCode,REASON:.status.reason' 2>/dev/null || true)"
  [[ -n "$raw" ]] || { add_limitation "No se pudo obtener el inventario de Pods para el ámbito solicitado."; return 0; }
  while IFS=$'\t' read -r ns name phase ready node restarts waiting last exitcode reason; do
    [[ -n "$name" ]] || continue
    ((K8S_POD_COUNT+=1)); issue=0; total_restarts="$(_k8s_sum_ints "$restarts")"
    ns="$(_k8s_clean "$ns")"; name="$(_k8s_clean "$name")"; phase="$(_k8s_clean "$phase")"; ready="$(_k8s_clean "$ready")"; node="$(_k8s_clean "$node")"; waiting="$(_k8s_clean "$waiting")"; last="$(_k8s_clean "$last")"; reason="$(_k8s_clean "$reason")"
    [[ "$phase" == Pending ]] && { ((K8S_POD_PENDING_COUNT+=1)); issue=1; add_finding "K8S_POD_PENDING_$(_k8s_id "$ns-$name")" kubernetes pod_state 1 medium "El Pod $ns/$name está Pending; el estado por sí solo no identifica si la causa es scheduling, PVC u otra dependencia."; }
    [[ "$phase" == Failed ]] && { ((K8S_POD_FAILED_COUNT+=1)); issue=1; }
    if [[ "$phase" == Running && "$ready" != True ]]; then
      ((K8S_POD_NOTREADY_COUNT+=1)); issue=1
      add_finding "K8S_POD_NOTREADY_$(_k8s_id "$ns-$name")" kubernetes readiness 2 medium "El Pod $ns/$name está Running pero no Ready; se debe investigar readiness, aplicación y dependencias antes de asumir un fallo de red."
    fi
    if (( total_restarts >= 10 )); then
      ((K8S_POD_HIGH_RESTART_COUNT+=1)); issue=1
      add_finding "K8S_POD_RESTARTS_$(_k8s_id "$ns-$name")" kubernetes restart_history 2 medium "El Pod $ns/$name acumula $total_restarts reinicios; el contador no demuestra que la aplicación haya terminado espontáneamente."
    fi
    if [[ "$waiting" == *CrashLoopBackOff* ]]; then
      ((K8S_POD_CRASHLOOP_COUNT+=1)); issue=1
      add_finding "K8S_POD_CRASHLOOP_$(_k8s_id "$ns-$name")" kubernetes pod_state 4 high "El Pod $ns/$name presenta CrashLoopBackOff; es un patrón de reintentos, no una causa raíz."
    fi
    if [[ "$waiting" == *ImagePullBackOff* || "$waiting" == *ErrImagePull* ]]; then
      ((K8S_POD_IMAGEPULL_COUNT+=1)); issue=1
      add_finding "K8S_POD_IMAGEPULL_$(_k8s_id "$ns-$name")" kubernetes image_pull 3 high "El Pod $ns/$name no puede obtener una imagen; revisar referencia, registry, credenciales y conectividad hacia el registro."
    fi
    if [[ "$last" == *OOMKilled* ]]; then
      ((K8S_POD_OOMKILLED_COUNT+=1)); issue=1
      add_finding "K8S_POD_OOM_$(_k8s_id "$ns-$name")" kubernetes cgroup_memory 4 high "Un contenedor de $ns/$name terminó con OOMKilled. Esto puede ser un OOM del cgroup aunque el nodo no tenga MemoryPressure."
    fi
    if [[ "$reason" == Evicted ]]; then
      ((K8S_POD_EVICTED_COUNT+=1)); issue=1
      add_finding "K8S_POD_EVICTED_$(_k8s_id "$ns-$name")" kubernetes eviction 3 high "El Pod $ns/$name fue Evicted; correlacionar el motivo con presión de nodo, cuotas o almacenamiento efímero."
    fi
    (( issue == 1 )) && K8S_POD_ISSUES+=("$ns|$name|$phase|$ready|$total_restarts|${waiting:-n/d}|${last:-n/d}|${reason:-n/d}|${node:-n/d}")
  done <<<"$raw"
}

_k8s_collect_events() {
  local -a scope_args=()
  local selector="type=Warning"
  case "$K8S_SCOPE" in
    cluster) scope_args=(-A) ;;
    namespace) scope_args=(-n "$K8S_TARGET_NAMESPACE") ;;
    node) scope_args=(-A); selector="type=Warning,involvedObject.kind=Node,involvedObject.name=$K8S_TARGET_NODE" ;;
    pod) scope_args=(-n "$K8S_TARGET_NAMESPACE"); selector="type=Warning,involvedObject.kind=Pod,involvedObject.name=$K8S_TARGET_POD" ;;
  esac
  local raw="" ns type reason kind name message series_time event_time legacy_time created_time last id rc
  raw="$(_k8s_capture 20 get events "${scope_args[@]}" --field-selector "$selector" --no-headers -o 'custom-columns=NS:.metadata.namespace,TYPE:.type,REASON:.reason,KIND:.involvedObject.kind,NAME:.involvedObject.name,MESSAGE:.message,SERIES:.series.lastObservedTime,EVENTTIME:.eventTime,LAST:.lastTimestamp,CREATED:.metadata.creationTimestamp' 2>/dev/null || true)"
  [[ -n "$raw" ]] || return 0
  while IFS=$'\t' read -r ns type reason kind name message series_time event_time legacy_time created_time; do
    [[ -n "$reason" ]] || continue
    ((K8S_WARNING_EVENT_COUNT+=1)); (( K8S_WARNING_EVENT_COUNT > K8S_EVENT_LIMIT )) && continue
    ns="$(_k8s_clean "$ns")"; reason="$(_k8s_clean "$reason")"; kind="$(_k8s_clean "$kind")"; name="$(_k8s_clean "$name")"; message="$(_k8s_clean "$message")"
    series_time="$(_k8s_clean "$series_time")"; event_time="$(_k8s_clean "$event_time")"; legacy_time="$(_k8s_clean "$legacy_time")"; created_time="$(_k8s_clean "$created_time")"
    last="$series_time"
    [[ -n "$last" && "$last" != "<none>" ]] || last="$event_time"
    [[ -n "$last" && "$last" != "<none>" ]] || last="$legacy_time"
    [[ -n "$last" && "$last" != "<none>" ]] || last="$created_time"
    id="$(_k8s_id "$ns-$kind-$name")"
    K8S_WARNING_EVENTS+=("$ns|$reason|$kind|$name|$message|${last:-n/d}")
    if _k8s_event_is_recent "$last"; then
      ((K8S_WARNING_EVENT_RECENT_COUNT+=1))
    else
      rc=$?
      if (( rc == 1 )); then
        ((K8S_WARNING_EVENT_STALE_COUNT+=1))
      else
        ((K8S_WARNING_EVENT_UNKNOWN_TIME_COUNT+=1))
      fi
      continue
    fi
    case "$reason|$message" in
      FailedScheduling*|*FailedScheduling*)
        ((K8S_FAILED_SCHEDULING_COUNT+=1))
        if [[ "$message" == *"Insufficient memory"* ]]; then
          add_finding "K8S_SCHED_MEM_$id" kubernetes scheduling 5 high "El scheduler informa Insufficient memory para $ns/$name. La decisión se basa en requests y Allocatable, no en MemAvailable instantánea del host."
        elif [[ "$message" == *"Insufficient cpu"* ]]; then
          add_finding "K8S_SCHED_CPU_$id" kubernetes scheduling 4 high "El scheduler informa Insufficient cpu para $ns/$name; revisar requests comprometidos y nodos elegibles."
        elif [[ "$message" == *"untolerated taint"* || "$message" == *"taint"* ]]; then
          add_finding "K8S_SCHED_TAINT_$id" kubernetes scheduling 3 high "El scheduler descarta nodos por taints/tolerations para $ns/$name."
        elif [[ "$message" == *"unbound immediate PersistentVolumeClaims"* ]]; then
          add_finding "K8S_SCHED_PVC_$id" kubernetes storage 4 high "El Pod $ns/$name no puede avanzar porque tiene PVC inmediatos sin enlazar; investigar el almacenamiento antes de culpar al scheduler."
        else
          add_finding "K8S_SCHED_GENERIC_$id" kubernetes scheduling 2 medium "Se observa FailedScheduling para $ns/$name; revisar el mensaje del scheduler para discriminar recursos, afinidad, taints o almacenamiento."
        fi
        ;;
      Unhealthy*|*"probe failed"*)
        ((K8S_PROBE_FAILURE_COUNT+=1))
        if [[ "$message" == *"Readiness probe failed"* ]]; then
          add_finding "K8S_READINESS_$id" kubernetes readiness 3 high "La readiness probe de $ns/$name está fallando; el Pod puede seguir Running y dejar de ser un backend Ready del Service."
        elif [[ "$message" == *"Liveness probe failed"* ]]; then
          add_finding "K8S_LIVENESS_$id" kubernetes liveness 3 high "La liveness probe de $ns/$name está fallando; kubelet puede reiniciar el contenedor si se supera el umbral configurado."
        elif [[ "$message" == *"Startup probe failed"* ]]; then
          add_finding "K8S_STARTUP_$id" kubernetes startup_probe 2 medium "La startup probe de $ns/$name está fallando; revisar tiempo real de arranque y umbrales antes de interpretar otros healthchecks."
        fi
        ;;
      FailedMount*|*"MountVolume.SetUp failed"*)
        ((K8S_FAILED_MOUNT_COUNT+=1)); add_finding "K8S_MOUNT_$id" kubernetes storage_mount 4 high "Se observa FailedMount en $ns/$name; investigar kubelet, CSI node plugin, filesystem, dispositivo y opciones de montaje del nodo." ;;
      FailedAttachVolume*|FailedAttach*|*"AttachVolume.Attach failed"*)
        ((K8S_FAILED_ATTACH_COUNT+=1)); add_finding "K8S_ATTACH_$id" kubernetes storage_attach 4 high "Se observa FailedAttach en $ns/$name; investigar CSI controller, backend y la operación de attach hacia el nodo." ;;
      ProvisioningFailed*|*"failed to provision volume"*)
        ((K8S_STORAGE_PROVISION_FAILURE_COUNT+=1)); add_finding "K8S_PROVISION_$id" kubernetes storage_provision 4 high "Se observa un fallo de aprovisionamiento de almacenamiento para $ns/$name; revisar StorageClass, CSI provisioner y backend según la evidencia." ;;
      Killing*|*"failed liveness probe"*)
        if [[ "$message" == *liveness* || "$message" == *Liveness* ]]; then
          add_finding "K8S_LIVENESS_KILL_$id" kubernetes liveness_restart 4 high "Kubelet está matando contenedores de $ns/$name tras fallos de liveness; los reinicios no deben interpretarse automáticamente como crashes espontáneos."
        fi
        ;;
    esac
  done <<<"$raw"
  (( K8S_WARNING_EVENT_COUNT > K8S_EVENT_LIMIT )) && add_limitation "Se detectaron más de $K8S_EVENT_LIMIT eventos Warning; el detalle mostrado se ha acotado para evitar ruido."
  (( K8S_WARNING_EVENT_STALE_COUNT > 0 )) && add_limitation "Se observaron $K8S_WARNING_EVENT_STALE_COUNT eventos Warning fuera de la ventana reciente de ${K8S_EVENT_RECENT_MINUTES} minutos; se muestran como contexto, pero no puntúan ni se presentan como causa actual."
  (( K8S_WARNING_EVENT_UNKNOWN_TIME_COUNT > 0 )) && add_limitation "No se pudo validar la antigüedad de $K8S_WARNING_EVENT_UNKNOWN_TIME_COUNT eventos Warning; se muestran como contexto, pero no puntúan."
}

_k8s_collect_storageclasses() {
  K8S_STORAGECLASS_SEEN=()
  K8S_STORAGECLASS_LIST_AVAILABLE=0
  local raw sc
  if ! raw="$(_k8s_capture 8 get storageclass --no-headers -o 'custom-columns=NAME:.metadata.name' 2>/dev/null)"; then
    add_limitation "No se pudieron listar las StorageClass; SYSdiag no interpretará una clase no visible como inexistente."
    return 1
  fi
  K8S_STORAGECLASS_LIST_AVAILABLE=1
  while IFS= read -r sc; do [[ -n "$sc" ]] && K8S_STORAGECLASS_SEEN[$sc]=1; done <<<"$raw"
  return 0
}
_k8s_collect_pvcs() {
  local -a scope_args=()
  case "$K8S_SCOPE" in
    namespace|pod) scope_args=(-n "$K8S_TARGET_NAMESPACE") ;;
    *) scope_args=(-A) ;;
  esac
  local raw ns name status volume sc id
  raw="$(_k8s_capture 15 get pvc "${scope_args[@]}" --no-headers -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,VOLUME:.spec.volumeName,SC:.spec.storageClassName' 2>/dev/null || true)"
  [[ -n "$raw" ]] || return 0
  _k8s_collect_storageclasses
  while IFS=$'\t' read -r ns name status volume sc; do
    [[ -n "$name" ]] || continue
    ((K8S_PVC_COUNT+=1)); ns="$(_k8s_clean "$ns")"; name="$(_k8s_clean "$name")"; status="$(_k8s_clean "$status")"; sc="$(_k8s_clean "$sc")"; id="$(_k8s_id "$ns-$name")"
    if [[ "$status" == Pending ]]; then
      ((K8S_PVC_PENDING_COUNT+=1)); K8S_PVC_ISSUES+=("$ns|$name|$status|${volume:-n/d}|${sc:-n/d}")
      if [[ -n "$sc" && "$sc" != "<none>" && "$K8S_STORAGECLASS_LIST_AVAILABLE" == 1 && -z "${K8S_STORAGECLASS_SEEN[$sc]:-}" ]]; then
        add_finding "K8S_PVC_SC_$id" kubernetes storage_config 5 high "El PVC $ns/$name solicita la StorageClass '$sc', que no aparece entre las StorageClass visibles del cluster."
      else
        add_finding "K8S_PVC_PENDING_$id" kubernetes storage_provision 3 high "El PVC $ns/$name está Pending; revisar eventos, PV compatibles, StorageClass, CSI y capacidad del backend antes de atribuirlo al scheduler."
      fi
    fi
  done <<<"$raw"
}

_k8s_endpoint_scope_args() {
  case "$K8S_SCOPE" in namespace|pod) printf '%s\n' -n "$K8S_TARGET_NAMESPACE" ;; *) printf '%s\n' -A ;; esac
}

_k8s_collect_endpointslices() {
  local -a scope_args=(); mapfile -t scope_args < <(_k8s_endpoint_scope_args)
  local raw ns svc addresses ready total ready_count key
  K8S_ENDPOINTSLICE_LIST_AVAILABLE=0
  if ! raw="$(_k8s_capture 15 get endpointslices.discovery.k8s.io "${scope_args[@]}" --no-headers -o 'custom-columns=NS:.metadata.namespace,SVC:.metadata.labels.kubernetes\.io/service-name,ADDR:.endpoints[*].addresses,READY:.endpoints[*].conditions.ready' 2>/dev/null)"; then
    add_limitation "No se pudieron listar EndpointSlices; SYSdiag no interpretará su ausencia como un Service sin backends."
    return 1
  fi
  K8S_ENDPOINTSLICE_LIST_AVAILABLE=1
  while IFS=$'\t' read -r ns svc addresses ready; do
    [[ -n "$svc" && "$svc" != "<none>" ]] || continue
    key="$ns|$svc"; total="$(_k8s_count_tokens "$addresses")"; ready_count="$(_k8s_count_true "$ready" "$total")"
    K8S_EP_TOTAL[$key]=$(( ${K8S_EP_TOTAL[$key]:-0} + total ))
    K8S_EP_READY[$key]=$(( ${K8S_EP_READY[$key]:-0} + ready_count ))
  done <<<"$raw"
  return 0
}
_k8s_service_selector() {
  local ns="$1" name="$2"
  _k8s_capture 6 get service -n "$ns" "$name" -o 'go-template={{range $k,$v := .spec.selector}}{{$k}}={{$v}},{{end}}' 2>/dev/null | sed 's/,$//' | _k8s_clean
}

_k8s_service_pod_state() {
  local ns="$1" selector="$2" raw total=0 ready=0 line
  [[ -n "$selector" ]] || { printf '0 0'; return 0; }
  if ! raw="$(_k8s_capture 8 get pods -n "$ns" -l "$selector" --no-headers -o 'custom-columns=READY:.status.conditions[?(@.type=="Ready")].status' 2>/dev/null)"; then
    return 1
  fi
  while IFS= read -r line; do [[ -n "$line" ]] || continue; ((total+=1)); [[ "$line" == *True* ]] && ((ready+=1)); done <<<"$raw"
  printf '%s %s' "$total" "$ready"
}
_k8s_collect_services() {
  local -a scope_args=(); mapfile -t scope_args < <(_k8s_endpoint_scope_args)
  _k8s_collect_endpointslices || true
  local raw ns name type selector publish key total ready sel podstate pods podsready reason id
  raw="$(_k8s_capture 15 get services "${scope_args[@]}" --no-headers -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type,SELECTOR:.spec.selector,PUBLISH:.spec.publishNotReadyAddresses' 2>/dev/null || true)"
  [[ -n "$raw" ]] || return 0
  while IFS=$'\t' read -r ns name type selector publish; do
    [[ -n "$name" ]] || continue; ((K8S_SERVICE_COUNT+=1))
    [[ "$type" == ExternalName ]] && continue
    [[ -n "$selector" && "$selector" != "<none>" && "$selector" != "map[]" ]] || continue
    key="$ns|$name"; total="${K8S_EP_TOTAL[$key]:-0}"; ready="${K8S_EP_READY[$key]:-0}"; reason=""; id="$(_k8s_id "$ns-$name")"
    if (( K8S_ENDPOINTSLICE_LIST_AVAILABLE == 0 )); then
      continue
    fi
    if (( total == 0 )); then
      ((K8S_SERVICE_NO_ENDPOINT_COUNT+=1)); reason="Sin endpoints"
      if [[ "$K8S_MODE" != quick ]]; then
        if ! sel="$(_k8s_service_selector "$ns" "$name")" || [[ -z "$sel" ]]; then
          reason="Sin endpoints; selector no verificable"
          add_limitation "No se pudo verificar el selector de $ns/$name; no se atribuye la ausencia de endpoints a labels o readiness."
          add_finding "K8S_SVC_ENDPOINT_$id" kubernetes service_endpoints 2 medium "El Service $ns/$name no tiene endpoints observables; no se pudo verificar de forma fiable selector, labels y readiness."
        elif ! podstate="$(_k8s_service_pod_state "$ns" "$sel")"; then
          reason="Sin endpoints; Pods no verificables"
          add_limitation "No se pudieron listar los Pods seleccionados por $ns/$name; no se atribuye la ausencia de endpoints a selector o readiness."
          add_finding "K8S_SVC_ENDPOINT_$id" kubernetes service_endpoints 2 medium "El Service $ns/$name no tiene endpoints observables; la visibilidad de los Pods seleccionados es insuficiente para precisar la causa."
        else
          read -r pods podsready <<<"$podstate"
          if (( pods == 0 )); then
            reason="Selector sin Pods coincidentes"
            add_finding "K8S_SVC_SELECTOR_$id" kubernetes service_selector 4 high "El Service $ns/$name tiene selector pero no tiene endpoints ni Pods coincidentes; comparar selector y labels antes de investigar CNI."
          elif (( podsready == 0 )); then
            reason="Pods seleccionados no Ready"
            add_finding "K8S_SVC_READINESS_$id" kubernetes service_readiness 4 high "El Service $ns/$name selecciona Pods, pero ninguno está Ready; investigar readiness y aplicación antes de culpar al dataplane de red."
          else
            add_finding "K8S_SVC_ENDPOINT_$id" kubernetes service_endpoints 3 high "El Service $ns/$name tiene Pods Ready seleccionables pero no aparecen endpoints; revisar EndpointSlices/controladores y configuración del Service."
          fi
        fi
      else
        add_finding "K8S_SVC_ENDPOINT_$id" kubernetes service_endpoints 2 medium "El Service $ns/$name no tiene endpoints observables; revisar selector, labels y readiness antes de investigar networking."
      fi
      K8S_SERVICE_ISSUES+=("$ns|$name|$type|$total|$ready|$reason")
    elif (( ready == 0 )) && [[ "${publish,,}" != true ]]; then
      ((K8S_SERVICE_NO_READY_ENDPOINT_COUNT+=1)); reason="Endpoints no Ready"
      K8S_SERVICE_ISSUES+=("$ns|$name|$type|$total|$ready|$reason")
      add_finding "K8S_SVC_NOREADY_$id" kubernetes service_readiness 3 high "El Service $ns/$name tiene endpoints, pero ninguno aparece Ready; correlacionar con readiness probes y estado de los Pods."
    fi
  done <<<"$raw"
}

_k8s_collect_workloads() {
  [[ "$K8S_MODE" == quick || "$K8S_SCOPE" == pod ]] && return 0
  local -a scope_args=(); case "$K8S_SCOPE" in namespace) scope_args=(-n "$K8S_TARGET_NAMESPACE") ;; *) scope_args=(-A) ;; esac
  local raw ns name desired available updated ready id
  raw="$(_k8s_capture 15 get deployments.apps "${scope_args[@]}" --no-headers -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,DESIRED:.spec.replicas,AVAILABLE:.status.availableReplicas,UPDATED:.status.updatedReplicas' 2>/dev/null || true)"
  while IFS=$'\t' read -r ns name desired available updated; do
    [[ "$desired" =~ ^[0-9]+$ ]] || continue; [[ "$available" =~ ^[0-9]+$ ]] || available=0
    if (( available < desired )); then
      ((K8S_WORKLOAD_DEGRADED_COUNT+=1)); K8S_WORKLOAD_ISSUES+=("Deployment|$ns|$name|$desired|$available")
      id="$(_k8s_id "$ns-$name")"; add_finding "K8S_DEPLOY_$id" kubernetes workload 2 high "El Deployment $ns/$name dispone de $available/$desired réplicas disponibles; seguir los Pods y eventos asociados para localizar la causa."
    fi
  done <<<"$raw"
  raw="$(_k8s_capture 15 get statefulsets.apps "${scope_args[@]}" --no-headers -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas' 2>/dev/null || true)"
  while IFS=$'\t' read -r ns name desired ready; do
    [[ "$desired" =~ ^[0-9]+$ ]] || continue; [[ "$ready" =~ ^[0-9]+$ ]] || ready=0
    if (( ready < desired )); then
      ((K8S_WORKLOAD_DEGRADED_COUNT+=1)); K8S_WORKLOAD_ISSUES+=("StatefulSet|$ns|$name|$desired|$ready")
      id="$(_k8s_id "$ns-$name")"; add_finding "K8S_STS_$id" kubernetes workload 2 high "El StatefulSet $ns/$name tiene $ready/$desired réplicas Ready; revisar Pods, PVC y eventos asociados."
    fi
  done <<<"$raw"
  raw="$(_k8s_capture 15 get daemonsets.apps "${scope_args[@]}" --no-headers -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,DESIRED:.status.desiredNumberScheduled,READY:.status.numberReady' 2>/dev/null || true)"
  while IFS=$'\t' read -r ns name desired ready; do
    [[ "$desired" =~ ^[0-9]+$ ]] || continue; [[ "$ready" =~ ^[0-9]+$ ]] || ready=0
    if (( ready < desired )); then
      ((K8S_WORKLOAD_DEGRADED_COUNT+=1)); K8S_WORKLOAD_ISSUES+=("DaemonSet|$ns|$name|$desired|$ready")
      id="$(_k8s_id "$ns-$name")"; add_finding "K8S_DS_$id" kubernetes workload 2 high "El DaemonSet $ns/$name tiene $ready/$desired instancias Ready; revisar nodos excluidos y Pods asociados."
    fi
  done <<<"$raw"
}

_k8s_collect_metrics() {
  [[ "$K8S_MODE" == quick ]] && return 0
  local raw
  if [[ "$K8S_SCOPE" == node ]]; then raw="$(_k8s_capture 8 top node "$K8S_TARGET_NODE" --no-headers 2>/dev/null || true)"; else raw="$(_k8s_capture 10 top nodes --no-headers 2>/dev/null || true)"; fi
  if [[ -n "$raw" ]]; then
    K8S_METRICS_AVAILABLE=1
    while IFS= read -r line; do [[ -n "$line" ]] && K8S_NODE_METRICS+=("$(_k8s_clean "$line")"); done <<<"$raw"
  else
    add_limitation "No se pudieron obtener métricas de 'top nodes'; metrics-server o los permisos pueden no estar disponibles."
  fi
}

_k8s_collect_kubelet_stats() {
  [[ "$K8S_MODE" == quick ]] && return 0
  local -a nodes=() row node raw
  if [[ "$K8S_SCOPE" == node ]]; then
    nodes=("$K8S_TARGET_NODE")
  elif [[ "$K8S_MODE" == exhaustive ]]; then
    for row in "${K8S_NODE_DETAILS[@]:-}"; do IFS='|' read -r node _ <<<"$row"; [[ -n "$node" ]] && nodes+=("$node"); done
  else
    nodes=("${K8S_SUSPECT_NODES[@]:-}")
  fi
  ((${#nodes[@]})) || return 0
  for node in "${nodes[@]}"; do
    raw="$(_k8s_capture 8 get --raw="/api/v1/nodes/$node/proxy/stats/summary" 2>/dev/null | head -c 200 || true)"
    if [[ "$raw" == *'"node"'* || "$raw" == *'"pods"'* ]]; then ((K8S_KUBELET_STATS_OK_COUNT+=1)); else ((K8S_KUBELET_STATS_FAIL_COUNT+=1)); fi
  done
  (( K8S_KUBELET_STATS_FAIL_COUNT > 0 )) && add_limitation "No se pudo consultar stats/summary del kubelet en $K8S_KUBELET_STATS_FAIL_COUNT nodo(s); puede faltar permiso nodes/proxy o el kubelet no responder."
}

_k8s_collect_openshift() {
  [[ "$K8S_PLATFORM" == OpenShift && "$K8S_MODE" != quick ]] || return 0
  local raw name avail prog degr message phase id
  raw="$(_k8s_capture 15 get clusteroperators.config.openshift.io --no-headers -o 'custom-columns=NAME:.metadata.name,AVAILABLE:.status.conditions[?(@.type=="Available")].status,PROGRESSING:.status.conditions[?(@.type=="Progressing")].status,DEGRADED:.status.conditions[?(@.type=="Degraded")].status,MESSAGE:.status.conditions[?(@.type=="Degraded")].message' 2>/dev/null || true)"
  if [[ -z "$raw" ]]; then add_limitation "OpenShift detectado, pero no se pudieron consultar ClusterOperators."; else
    while IFS=$'\t' read -r name avail prog degr message; do
      [[ -n "$name" ]] || continue; id="$(_k8s_id "$name")"
      if [[ "$degr" == True ]]; then
        ((K8S_OPENSHIFT_DEGRADED_OPERATORS+=1)); K8S_OPENSHIFT_ISSUES+=("ClusterOperator|$name|Degraded|$(_k8s_clean "$message")")
        add_finding "OCP_OPERATOR_DEGRADED_$id" kubernetes openshift_operator 5 high "El ClusterOperator $name está Degraded=True; revisar su mensaje y recursos relacionados antes de atribuir el síntoma a una capa inferior."
      elif [[ "$avail" != True ]]; then
        ((K8S_OPENSHIFT_UNAVAILABLE_OPERATORS+=1)); K8S_OPENSHIFT_ISSUES+=("ClusterOperator|$name|Available=$avail|$(_k8s_clean "$message")")
        add_finding "OCP_OPERATOR_UNAVAILABLE_$id" kubernetes openshift_operator 4 high "El ClusterOperator $name no está Available=True."
      fi
    done <<<"$raw"
  fi
  [[ "$K8S_MODE" == exhaustive ]] || return 0
  raw="$(_k8s_capture 15 get machines.machine.openshift.io -A --no-headers -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,NODE:.status.nodeRef.name' 2>/dev/null || true)"
  while IFS=$'\t' read -r ns name phase node; do
    [[ -n "$name" ]] || continue
    if [[ "$phase" == Failed ]]; then
      ((K8S_OPENSHIFT_MACHINE_FAILED_COUNT+=1)); K8S_OPENSHIFT_ISSUES+=("Machine|$ns/$name|Failed|${node:-n/d}")
      add_finding "OCP_MACHINE_FAILED_$(_k8s_id "$ns-$name")" kubernetes openshift_machine 4 high "La Machine $ns/$name está en fase Failed; correlacionar con el Node y Machine API."
    fi
  done <<<"$raw"

  # Only suspicious nodes are sampled. node-logs is a read-only OpenShift API operation.
  if [[ "$K8S_CLI" == oc && ${#K8S_SUSPECT_NODES[@]} -gt 0 ]]; then
    for node in "${K8S_SUSPECT_NODES[@]}"; do
      local -a oc_args=(oc)
      [[ -n "$K8S_EFFECTIVE_KUBECONFIG" ]] && oc_args+=(--kubeconfig "$K8S_EFFECTIVE_KUBECONFIG")
      [[ -n "$K8S_CONTEXT" ]] && oc_args+=(--context "$K8S_CONTEXT")
      oc_args+=(adm node-logs "$node" -u kubelet --since=10m)
      message="$(run_with_timeout 8 "${oc_args[@]}" 2>/dev/null | grep -Ei 'error|failed|notready|not ready|runtime|pleg|evict|pressure' | tail -n 5 | sanitize_terminal_text || true)"
      if [[ -n "$message" ]]; then
        ((K8S_OPENSHIFT_NODE_LOG_HINT_COUNT+=1)); K8S_OPENSHIFT_ISSUES+=("NodeLog|$node|kubelet|$(_k8s_clean "$message")")
      fi
    done
  fi
}

collect_kubernetes() {
  _k8s_prompt_configuration
  _k8s_validate_scope
  _k8s_detect_access || return 0
  _k8s_check_permissions
  _k8s_collect_nodes
  _k8s_collect_pods
  _k8s_collect_events
  _k8s_collect_pvcs
  _k8s_collect_services
  _k8s_collect_workloads
  _k8s_collect_metrics
  _k8s_collect_kubelet_stats
  _k8s_collect_openshift
}

analyze_kubernetes() {
  [[ "$K8S_ACCESS" == disponible ]] || return 0
  if (( K8S_PERMISSION_DENIED > 0 )); then
    add_finding "K8S_RBAC_LIMITED" kubernetes rbac 1 medium "El diagnóstico está limitado por RBAC en $K8S_PERMISSION_DENIED de $K8S_PERMISSION_CHECKED comprobaciones básicas."
  fi
  add_next_step "Revisar el contexto y permisos de solo lectura utilizados por SYSdiag." \
    "$K8S_CLI config current-context" \
    "$K8S_CLI auth whoami" \
    "$K8S_CLI auth can-i --list"
  if (( K8S_NODE_NOTREADY_COUNT + K8S_NODE_MEMORY_PRESSURE_COUNT + K8S_NODE_DISK_PRESSURE_COUNT + K8S_NODE_PID_PRESSURE_COUNT > 0 )); then
    add_next_step "Correlacionar Node Conditions con kubelet/runtime/Linux sin tratar NotReady o Pressure como causa raíz." \
      "$K8S_CLI get nodes" \
      "$K8S_CLI describe node <nodo>" \
      "$K8S_CLI get events -A --field-selector involvedObject.kind=Node,involvedObject.name=<nodo>"
  fi
  if (( K8S_POD_PENDING_COUNT + K8S_POD_CRASHLOOP_COUNT + K8S_POD_OOMKILLED_COUNT + K8S_POD_HIGH_RESTART_COUNT > 0 )); then
    add_next_step "Inspeccionar Pods problemáticos con estado previo, eventos y límites antes de concluir la causa." \
      "$K8S_CLI describe pod -n <namespace> <pod>" \
      "$K8S_CLI logs -n <namespace> <pod> --all-containers --tail=100" \
      "$K8S_CLI logs -n <namespace> <pod> --all-containers --previous --tail=100"
  fi
  if (( K8S_SERVICE_NO_ENDPOINT_COUNT + K8S_SERVICE_NO_READY_ENDPOINT_COUNT > 0 )); then
    add_next_step "Seguir la cadena DNS → Service → EndpointSlice → Pod IP/puerto → aplicación y localizar el primer salto que falla." \
      "$K8S_CLI get svc -n <namespace> <service> -o yaml" \
      "$K8S_CLI get endpointslices.discovery.k8s.io -n <namespace> -l kubernetes.io/service-name=<service>" \
      "$K8S_CLI get pods -n <namespace> --show-labels"
  fi
  if (( K8S_PVC_PENDING_COUNT + K8S_FAILED_MOUNT_COUNT + K8S_FAILED_ATTACH_COUNT + K8S_STORAGE_PROVISION_FAILURE_COUNT > 0 )); then
    add_next_step "Separar provisioning, attach y mount antes de bajar a CSI o al almacenamiento externo." \
      "$K8S_CLI get pvc,pv,storageclass -A" \
      "$K8S_CLI describe pvc -n <namespace> <pvc>" \
      "$K8S_CLI get events -n <namespace> --field-selector type=Warning"
  fi
}

print_kubernetes() {
  section "KUBERNETES / OPENSHIFT"
  kv "Cliente:" "${K8S_CLI:-no disponible} ${K8S_CLIENT_VERSION:-}"
  kv "Acceso API:" "$K8S_ACCESS"
  kv "Contexto:" "$K8S_CONTEXT_EFFECTIVE"
  kv "API Server:" "$K8S_SERVER"
  kv "Usuario:" "$K8S_USER"
  local platform_text="$K8S_PLATFORM"
  [[ "$K8S_PLATFORM" == OpenShift && "$K8S_OPENSHIFT_VERSION" != "n/d" ]] && platform_text+=" $K8S_OPENSHIFT_VERSION"
  kv "Plataforma:" "$platform_text"
  kv "Versión servidor:" "$K8S_SERVER_VERSION"
  kv "Modo / ámbito:" "$K8S_MODE / $K8S_SCOPE"
  [[ "$K8S_SCOPE" == node ]] && kv "Nodo objetivo:" "$K8S_TARGET_NODE"
  [[ "$K8S_SCOPE" == namespace || "$K8S_SCOPE" == pod ]] && kv "Namespace objetivo:" "$K8S_TARGET_NAMESPACE"
  [[ "$K8S_SCOPE" == pod ]] && kv "Pod objetivo:" "$K8S_TARGET_POD"
  [[ "$K8S_ACCESS" == disponible ]] || { printf '\n  No hay evidencia suficiente para analizar el cluster desde esta ejecución.\n'; return 0; }

  subsection "RESUMEN"
  kv "Nodos / NotReady:" "$K8S_NODE_COUNT / $K8S_NODE_NOTREADY_COUNT"
  kv "Memory/Disk/PID Pressure:" "$K8S_NODE_MEMORY_PRESSURE_COUNT / $K8S_NODE_DISK_PRESSURE_COUNT / $K8S_NODE_PID_PRESSURE_COUNT"
  kv "Pods inspeccionados:" "$K8S_POD_COUNT"
  kv "Pending / NotReady / Failed:" "$K8S_POD_PENDING_COUNT / $K8S_POD_NOTREADY_COUNT / $K8S_POD_FAILED_COUNT"
  kv "CrashLoop / ImagePull / OOMKilled:" "$K8S_POD_CRASHLOOP_COUNT / $K8S_POD_IMAGEPULL_COUNT / $K8S_POD_OOMKILLED_COUNT"
  kv "RestartCount >=10 / Evicted:" "$K8S_POD_HIGH_RESTART_COUNT / $K8S_POD_EVICTED_COUNT"
  kv "Services sin endpoint / sin Ready:" "$K8S_SERVICE_NO_ENDPOINT_COUNT / $K8S_SERVICE_NO_READY_ENDPOINT_COUNT"
  kv "PVC Pending:" "$K8S_PVC_PENDING_COUNT"
  kv "FailedScheduling / probes:" "$K8S_FAILED_SCHEDULING_COUNT / $K8S_PROBE_FAILURE_COUNT"
  kv "FailedAttach / FailedMount:" "$K8S_FAILED_ATTACH_COUNT / $K8S_FAILED_MOUNT_COUNT"
  kv "Workloads degradados:" "$K8S_WORKLOAD_DEGRADED_COUNT"
  kv "Eventos Warning observados:" "$K8S_WARNING_EVENT_COUNT"
  kv "Warning recientes / históricos / sin fecha:" "$K8S_WARNING_EVENT_RECENT_COUNT / $K8S_WARNING_EVENT_STALE_COUNT / $K8S_WARNING_EVENT_UNKNOWN_TIME_COUNT"
  kv "Métricas de nodos:" "$([[ $K8S_METRICS_AVAILABLE == 1 ]] && echo disponibles || echo no disponibles)"
  kv "Kubelet stats OK / fallo:" "$K8S_KUBELET_STATS_OK_COUNT / $K8S_KUBELET_STATS_FAIL_COUNT"
  if [[ "$K8S_PLATFORM" == OpenShift ]]; then
    kv "Operators degraded / unavailable:" "$K8S_OPENSHIFT_DEGRADED_OPERATORS / $K8S_OPENSHIFT_UNAVAILABLE_OPERATORS"
    kv "Machines Failed:" "$K8S_OPENSHIFT_MACHINE_FAILED_COUNT"
  fi

  if (( ${VERBOSE:-0} == 1 )); then
    local row a b c d e f g h i
    if ((${#K8S_NODE_DETAILS[@]})); then
      subsection "NODOS"
      printf '    %-28s %-8s %-8s %-8s %-8s %-12s %-8s %s\n' "Nodo" "Ready" "Memory" "Disk" "PID" "Unsched" "CPU" "Mem alloc"
      for row in "${K8S_NODE_DETAILS[@]}"; do IFS='|' read -r a b c d e f g h <<<"$row"; printf '    %-28.28s %-8s %-8s %-8s %-8s %-12s %-8s %s\n' "$a" "$b" "$c" "$d" "$e" "$f" "$g" "$h"; done
    fi
    if ((${#K8S_POD_ISSUES[@]})); then
      subsection "PODS CON SEÑALES"
      printf '    %-20s %-34s %-12s %-7s %-9s %-18s %-14s %s\n' "Namespace" "Pod" "Phase" "Ready" "Restarts" "Waiting" "Last" "Nodo"
      local n=0
      for row in "${K8S_POD_ISSUES[@]}"; do ((n+=1)); (( n > K8S_DETAIL_LIMIT )) && break; IFS='|' read -r a b c d e f g h i <<<"$row"; printf '    %-20.20s %-34.34s %-12.12s %-7s %-9s %-18.18s %-14.14s %s\n' "$a" "$b" "$c" "$d" "$e" "$f" "$g" "$i"; done
    fi
    if ((${#K8S_SERVICE_ISSUES[@]})); then
      subsection "SERVICES / ENDPOINTSLICES"
      for row in "${K8S_SERVICE_ISSUES[@]}"; do IFS='|' read -r a b c d e f <<<"$row"; printf '    - %s/%s: %s (endpoints=%s, ready=%s)\n' "$a" "$b" "$f" "$d" "$e"; done
    fi
    if ((${#K8S_PVC_ISSUES[@]})); then
      subsection "PVC"
      for row in "${K8S_PVC_ISSUES[@]}"; do IFS='|' read -r a b c d e <<<"$row"; printf '    - %s/%s: %s, volume=%s, StorageClass=%s\n' "$a" "$b" "$c" "$d" "$e"; done
    fi
    if ((${#K8S_WORKLOAD_ISSUES[@]})); then
      subsection "WORKLOADS"
      for row in "${K8S_WORKLOAD_ISSUES[@]}"; do IFS='|' read -r a b c d e <<<"$row"; printf '    - %s %s/%s: disponibles/ready=%s de %s\n' "$a" "$b" "$c" "$e" "$d"; done
    fi
    if ((${#K8S_OPENSHIFT_ISSUES[@]})); then
      subsection "OPENSHIFT"
      for row in "${K8S_OPENSHIFT_ISSUES[@]}"; do printf '    - %s\n' "${row//|/ | }"; done
    fi
  fi

  if (( ${EXPLAIN:-0} == 1 )); then
    subsection "CÓMO INTERPRETARLO"
    printf '    - Pending, CrashLoopBackOff, NotReady y Evicted son estados/síntomas; no se presentan como causa por sí solos.\n'
    printf '    - Scheduling usa requests y Allocatable; MemAvailable Linux no representa capacidad libre para scheduling.\n'
    printf '    - OOMKilled de un contenedor no implica MemoryPressure del nodo.\n'
    printf '    - Readiness falla → Pod puede seguir Running pero dejar de recibir tráfico; liveness puede provocar reinicios.\n'
    printf '    - DNS → Service → EndpointSlice → Pod IP/puerto → aplicación: SYSdiag intenta localizar el primer salto roto antes de culpar al CNI.\n'
    printf '    - PVC Pending, FailedAttach y FailedMount pertenecen a fases distintas; Bound no significa attached ni mounted.\n'
    printf '    - El análisis remoto usa la API, metrics y kubelet proxy cuando están disponibles; no instala agentes ni crea Pods de diagnóstico.\n'
    printf '    - SYSdiag no ejecuta apply, create, delete, patch, edit, exec, debug, port-forward ni acciones correctivas.\n'
  fi
}

# ===== modules/reference.sh =====

# Static professional diagnostic reference. No collection and no mutations.

guide_cmd() {
  local cmd="$1" desc="$2"
  printf '    %s\n' "$desc"
  printf '      $ %s\n' "$cmd"
}

print_reference_guide() {
  section "GUÍA TÉCNICA DE DIAGNÓSTICO Y COMANDOS"
  printf '  Referencia técnica de investigación para las áreas cubiertas por SYSdiag. No sustituye el análisis de evidencias.\n'
  printf '  Patrón recomendado: Datos → hipótesis → prueba que discrimina → nuevo dato → siguiente decisión.\n'
  printf '  Los comandos se muestran como referencia; SYSdiag no los ejecuta automáticamente.\n'

  subsection "QUÉ HACE CADA APARTADO"
  printf '    Resumen general       Prioriza señales sin volcar todas las métricas. LIMITADO ≠ OK.\n'
  printf '    CPU y procesos        Load, CPU real, iowait, estados R/S/D/Z y correlaciones.\n'
  printf '    Memoria               Free/available, swap, si/so, presión y OOM.\n'
  printf '    I/O y almacenamiento  Latencia, cola, IOPS/throughput, utilización y procesos D.\n'
  printf '    Filesystems           Espacio, inodos, mounts, df/du y deleted-open files.\n'
  printf '    Red                   Interfaces, rutas, DNS, sockets/TCP, drops, retransmisiones y MTU/PMTU.\n'
  printf '    Logs / journald       Persistencia, boots, rsyslog, logrotate y capacidad de investigación.\n'
  printf '    Eventos recientes     WARNING/ERROR recientes de journal y kernel como evidencia de triaje.\n'
  printf '    Systemd / servicios   Units failed, start-limit, restart loops, dependencias y estado efectivo.\n'
  printf '    Boot / arranque       Fstab, mounts, journal del boot, critical-chain y contexto initramfs/root.\n'
  printf '    Contenedores          Docker/Podman/CRI, lifecycle, health, OOM/cgroups, recursos y storage del runtime.\n'
  printf '    Kubernetes/OpenShift  Contexto/RBAC, nodes, workloads, Pods, Services/EndpointSlices, probes, storage y eventos.\n'

  subsection "PROCESOS / CPU / I/O"
  guide_cmd "ps -eo pid,ppid,user,stat,%cpu,%mem,comm --sort=-%cpu" "Procesos, estado y consumo."
  guide_cmd "pstree -p" "Relaciones padre/hijo."
  guide_cmd "uptime" "Load average y uptime."
  guide_cmd "vmstat 1" "CPU, procesos bloqueados, swap e I/O en serie temporal."
  guide_cmd "iostat -xz 1" "Latencia, colas y utilización de dispositivos."
  guide_cmd "ps -eo pid,ppid,user,stat,comm,wchan:32 | awk '\$4 ~ /^D/'" "Procesos en estado D."
  printf '    Claves: Load alto no implica CPU saturada; iowait no es CPU ocupada ejecutando trabajo; D indica espera no interrumpible.\n'

  subsection "MEMORIA"
  guide_cmd "free -h" "Interpretación de free frente a available y swap."
  guide_cmd "vmstat 1" "Actividad real de swap: si/so."
  guide_cmd "journalctl -k --since \"-1 hour\" | grep -Ei 'oom|out of memory|killed process'" "Evidencia OOM del kernel."
  printf '    Claves: Poca memoria free puede ser normal por page cache; available es más útil. Swap usada sin si/so no demuestra thrashing.\n'

  subsection "FILESYSTEMS"
  guide_cmd "df -hT" "Uso y tipo de filesystem."
  guide_cmd "df -i" "Uso de inodos."
  guide_cmd "findmnt" "Mounts y origen/tipo."
  guide_cmd "lsof -nP +L1" "Ficheros borrados que siguen abiertos."
  guide_cmd "du -xsh <ruta>" "Uso visible dentro de un filesystem; puede ser costoso."
  printf '    Claves: df mide bloques del filesystem; du suma ficheros visibles. Un deleted-open puede explicar df ≫ du.\n'

  subsection "RED / TCP / MTU"
  guide_cmd "ip addr" "Interfaces y direcciones."
  guide_cmd "ip route" "Tabla de routing."
  guide_cmd "ip route get <destino>" "Ruta efectiva hacia un destino."
  guide_cmd "getent hosts <nombre>" "Resolución usando NSS del sistema."
  guide_cmd "ss -lntp" "Listeners TCP y procesos."
  guide_cmd "ss -s" "Resumen de sockets/TCP."
  guide_cmd "ss -ti" "Detalle TCP, retransmisiones/MSS según conexión."
  guide_cmd "nc -vz <host> <puerto>" "Prueba de establecimiento TCP a un puerto concreto."
  guide_cmd "curl -v http://<host>:<puerto>/" "Prueba HTTP y detalle de conexión/respuesta."
  guide_cmd "nstat" "Contadores IP/TCP si está disponible."
  guide_cmd "tracepath <destino>" "Camino y estimación de PMTU."
  guide_cmd "ping -M do -s 1472 <destino>" "Prueba IPv4 DF para MTU 1500; genera tráfico."
  guide_cmd "tcpdump -ni <iface> <filtro>" "Captura manual acotada; requiere criterio y permisos."
  printf '    Claves: Refused implica respuesta activa; timeout implica ausencia de respuesta útil. MTU local no demuestra PMTU extremo a extremo.\n'

  subsection "LOGS"
  guide_cmd "journalctl -u <unidad> --since \"-30 min\"" "Histórico reciente de una unit."
  guide_cmd "journalctl -k --since \"-30 min\"" "Mensajes de kernel en una ventana."
  guide_cmd "journalctl --list-boots" "Boots conservados en el journal."
  guide_cmd "journalctl -k -b -1" "Kernel del boot anterior si está retenido."
  guide_cmd "journalctl -f" "Seguimiento del journal en vivo."
  guide_cmd "dmesg -T" "Ring buffer del kernel con tiempo legible aproximado."
  guide_cmd "tail -f <log>" "Seguimiento de un fichero de log."
  guide_cmd "grep -C 3 <patrón> <log>" "Coincidencia con contexto."
  guide_cmd "zgrep <patrón> <log.gz>" "Búsqueda en logs comprimidos."
  guide_cmd "less <log>" "Exploración de ficheros grandes."
  guide_cmd "awk '{print \$1, \$2, \$3}' <log>" "Selección y transformación de campos de texto."
  guide_cmd "sed -n '100,140p' <log>" "Visualización de un rango concreto de líneas."
  guide_cmd "jq 'select(.level == \"error\")' <log.json>" "Filtrado de JSON estructurado."
  printf '    Claves: ERROR ≠ causa. Prioriza ventana temporal, capa que emite el mensaje y correlation/request IDs.\n'

  subsection "SYSTEMD / SERVICIOS"
  guide_cmd "systemctl status <unidad> --no-pager -l" "Estado actual y resumen."
  guide_cmd "systemctl cat <unidad>" "Definición efectiva y overrides."
  guide_cmd "systemctl show <unidad> -p Result -p MainPID -p ExecMainStatus -p Restart -p NRestarts" "Propiedades útiles."
  guide_cmd "systemctl is-active <unidad>" "Estado activo."
  guide_cmd "systemctl is-enabled <unidad>" "Estado de enable."
  guide_cmd "systemctl is-failed <unidad>" "Estado failed."
  guide_cmd "systemctl --failed --no-pager" "Unidades actualmente failed."
  guide_cmd "systemctl list-dependencies --all <unidad>" "Grafo de dependencias."
  guide_cmd "systemctl list-timers --all" "Timers y próximas ejecuciones."
  guide_cmd "journalctl -u <unidad> --since \"-1 hour\"" "Primer error y secuencia de reinicios."
  printf '    Claves: Start ≠ enable; loaded ≠ running; After ≠ Requires; started ≠ ready; failed ≠ systemd es la causa.\n'

  subsection "BOOT / ARRANQUE"
  guide_cmd "cat /proc/cmdline" "Parámetros entregados por el bootloader/kernel, incluido root= cuando existe."
  guide_cmd "lsblk -f" "Dispositivos, filesystems, UUID/LABEL y relación con fstab."
  guide_cmd "blkid" "Identificadores de filesystems/bloques."
  guide_cmd "findmnt --verify --verbose" "Validación read-only de fstab y mounts declarados."
  guide_cmd "systemctl --failed --type=mount --no-pager" "Mount units fallidas en systemd."
  guide_cmd "systemd-analyze time" "Tiempo global informado por systemd."
  guide_cmd "systemd-analyze blame" "Duración por unit; no demuestra por sí sola retraso causal."
  guide_cmd "systemd-analyze critical-chain" "Cadena crítica que condicionó alcanzar el target."
  guide_cmd "journalctl -b --no-pager" "Userspace/systemd del boot actual."
  guide_cmd "journalctl -k -b --no-pager" "Kernel del boot actual."
  guide_cmd "journalctl -b -1 --no-pager" "Boot anterior si el journal lo conserva."
  printf '    Claves: Identifica primero la capa: firmware → GRUB → kernel → initramfs → root → systemd. Emergency es consecuencia, no causa.\n'

  subsection "CONTENEDORES / RUNTIME"
  guide_cmd "docker ps -a --no-trunc" "Inventario y estado actual/histórico de contenedores Docker."
  guide_cmd "docker inspect <contenedor>" "Estado/configuración efectiva: exit code, OOMKilled, restart policy, límites, mounts y red."
  guide_cmd "docker stats --no-stream" "Muestra puntual de CPU, memoria, I/O y PIDs."
  guide_cmd "docker logs --tail 100 <contenedor>" "Salida stdout/stderr reciente sin volcar el histórico completo."
  guide_cmd "docker system df -v" "Ocupación lógica de imágenes, contenedores, cache y volúmenes; puede ser costoso en hosts grandes."
  guide_cmd "docker network inspect <red>" "Configuración de una red Docker."
  guide_cmd "docker volume inspect <volumen>" "Configuración y mountpoint de un volumen."
  guide_cmd "podman ps -a --no-trunc" "Inventario de contenedores Podman."
  guide_cmd "podman inspect <contenedor>" "Estado y configuración efectiva en Podman."
  guide_cmd "podman stats --no-stream" "Muestra puntual de recursos Podman; rootless puede limitar algunas métricas."
  guide_cmd "crictl ps -a" "Visibilidad de contenedores a través de CRI en hosts Kubernetes/OpenShift."
  guide_cmd "cat /sys/fs/cgroup/<cgroup>/cpu.stat" "Cuotas/throttling de CPU en cgroup v2."
  guide_cmd "cat /sys/fs/cgroup/<cgroup>/memory.events" "Eventos de memoria/OOM del cgroup."
  printf '    Claves: Imagen ≠ contenedor; namespaces = qué ve; cgroups = recursos; running ≠ healthy ≠ ready; exit 137 ≠ OOM sin evidencias; volumen ≠ backup.
'
  printf '    Seguridad: docker.sock y privileged conceden capacidades muy amplias; validar necesidad y mínimo privilegio.
'


  subsection "KUBERNETES / OPENSHIFT"
  guide_cmd "kubectl config current-context" "Contexto efectivo sin modificarlo."
  guide_cmd "kubectl auth whoami" "Identidad efectiva cuando el API lo soporta."
  guide_cmd "kubectl auth can-i --list" "Permisos visibles para el usuario actual."
  guide_cmd "kubectl get nodes -o wide" "Estado general y distribución de nodos."
  guide_cmd "kubectl describe node <nodo>" "Conditions, capacity/allocatable, eventos y asignaciones del nodo."
  guide_cmd "kubectl get pods -A -o wide" "Estado, nodo e IP de Pods en todo el cluster."
  guide_cmd "kubectl describe pod -n <namespace> <pod>" "Eventos, probes, mounts, requests/limits y estado detallado."
  guide_cmd "kubectl logs -n <namespace> <pod> --all-containers --tail=100" "Logs actuales acotados."
  guide_cmd "kubectl logs -n <namespace> <pod> --all-containers --previous --tail=100" "Logs de la instancia anterior del contenedor cuando existe."
  guide_cmd "kubectl get events -A --field-selector type=Warning" "Eventos Warning como evidencia suplementaria; revisar siempre su contexto temporal."
  guide_cmd "kubectl top nodes" "Uso observado si metrics-server/monitoring y RBAC lo permiten."
  guide_cmd "kubectl get svc -n <namespace> <service> -o yaml" "Selector, puertos y configuración efectiva del Service."
  guide_cmd "kubectl get endpointslices.discovery.k8s.io -n <namespace> -l kubernetes.io/service-name=<service>" "Backends observados detrás de un Service."
  guide_cmd "kubectl get pvc,pv,storageclass -A" "Estado de claims, volúmenes y clases de almacenamiento."
  guide_cmd "kubectl get --raw /api/v1/nodes/<nodo>/proxy/stats/summary" "Stats del kubelet a través del API Server cuando RBAC lo permite."
  guide_cmd "oc get clusteroperators" "Available/Progressing/Degraded de operadores OpenShift."
  guide_cmd "oc adm node-logs <nodo> -u kubelet --since=10m" "Journal remoto del kubelet mediante OpenShift sin copiar SYSdiag al nodo."
  printf '    Claves: Pending ≠ scheduler caído; NotReady ≠ causa; OOMKilled ≠ MemoryPressure; Running ≠ Ready; Bound ≠ attached ≠ mounted.\n'
  printf '    Red: DNS → Service → EndpointSlice → Pod IP/puerto → aplicación. Localiza el primer salto roto antes de atribuirlo al CNI.\n'
  printf '    Probes: Readiness retira tráfico; liveness puede provocar reinicios; startup protege arranques lentos.\n'
  printf '    Eventos: Son evidencia best-effort y temporal; un error antiguo no debe presentarse como causa actual sin correlación.\n'

  subsection "ACCIONES QUE CAMBIAN EL SISTEMA — SOLO MANUALES"
  printf '    SYSdiag no ejecuta estas acciones. Se incluyen únicamente como referencia operativa y deben utilizarse tras evaluar su impacto.\n'
  guide_cmd "systemctl start|stop|restart|reload <unidad>" "Cambio del estado/lifecycle del servicio."
  guide_cmd "systemctl enable|disable <unidad>" "Cambio de las relaciones de arranque automático."
  guide_cmd "systemctl mask|unmask <unidad>" "Bloqueo o restauración de la activación normal."
  guide_cmd "systemctl edit <unidad>" "Creación o edición de un override local de la unit."
  guide_cmd "systemctl daemon-reload" "Recarga de definiciones de units; no reinicia servicios."
  guide_cmd "systemctl reset-failed <unidad>" "Limpieza del estado y contadores failed; no corrige la causa."
  guide_cmd "kill <PID>" "Envío de SIGTERM por defecto; permite cierre ordenado."
  guide_cmd "kill -9 <PID>" "SIGKILL; último recurso, no permite cleanup."

  subsection "REGLAS DE TROUBLESHOOTING"
  printf '    1. Empieza por el síntoma y el momento exacto, no por una lista de comandos.\n'
  printf '    2. Separa datos de interpretación.\n'
  printf '    3. Prioriza hipótesis que expliquen más evidencias independientes.\n'
  printf '    4. Busca una prueba que discrimine entre hipótesis, no otra métrica al azar.\n'
  printf '    5. La correlación temporal fuerte ayuda a priorizar, pero no demuestra causalidad.\n'
  printf '    6. Si una herramienta falta o una muestra no es válida, el estado correcto es LIMITADO, no OK.\n'
}

# ===== lib/json.sh =====

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

# ===== lib/cli.sh =====

# CLI / launcher for SYSdiag. Kept separate so the standalone builder does not
# depend on brittle text markers in sysdiag.sh.

VERBOSE=0; EXPLAIN=0; NO_COLOR=0; SECTION="all"; REPORT_FILE=""; SAMPLE_SECONDS=1
SHARED_SAMPLE_READY=0; SHARED_SAMPLE_IOSTAT_REQUESTED=0; RUNTIME_DIR=""
FORCE_MENU=0; SUMMARY_ONLY=0; MENU_REQUESTED=0; MENU_SELECTION=()
RECENT_MINUTES=60; RECENT_EVENT_LIMIT=20
JSON_OUTPUT=0; SUPPRESS_TEXT=0
CONTAINER_MODE="${CONTAINER_MODE:-normal}"; CONTAINER_MODE_EXPLICIT=0
MACHINE_REPORT_FILE=""; INTERNAL_SECTIONS=""; HOST_ONLY=0

usage() {
  cat <<EOF_USAGE
SYSdiag ${SYS_DIAG_VERSION} - diagnóstico de sistemas y plataformas de solo lectura
Autor: Chus (GitHub: chus87)

Uso:
  ./sysdiag.sh [opciones]

Opciones:
  --verbose              Muestra detalle, findings y puntuaciones por categoría.
  --explain              Explica las métricas y el razonamiento.
  --section <nombre>     system, cpu, processes, memory, io, filesystem, network,
                         logging, recent, systemd, boot, containers, kubernetes, guide, all.
  --container-mode <m>   normal o deep. Deep inspecciona todos los contenedores y analiza todo el histórico de logs accesible.
  --containers-deep      Atajo para --section containers --container-mode deep.
  --k8s-mode <modo>      quick, deep o exhaustive (defecto: deep).
  --k8s-node <nodo>      Analiza un nodo concreto.
  --k8s-namespace <ns>   Analiza un namespace concreto.
  --k8s-pod <ns/pod>     Analiza un Pod concreto.
  --k8s-context <ctx>    Usa un contexto concreto sin cambiar el kubeconfig.
  --k8s-kubeconfig <f>   Usa un kubeconfig concreto.
  --k8s-no-auth-prompt   No solicita credenciales si no hay sesión válida.
  --recent-errors        Muestra WARNING/ERROR recientes de journalctl y, si es
                         posible, eventos adicionales de dmesg (última hora).
  --guide                Muestra la guía técnica de diagnóstico y comandos.
  --json                 Salida estructurada JSON (schema versionado); desactiva menú/ANSI.
  --summary              Ejecuta todas las comprobaciones y muestra solo un resumen priorizado.
  --all                  Ejecuta el diagnóstico completo sin mostrar el menú.
  --menu                 Fuerza el menú interactivo incluso si se han pasado opciones.
  --sample <segundos>    Ventana común para CPU/swap/red/I/O (1-30; defecto: 1).
  --report [fichero]     Guarda informe de texto sin códigos ANSI.
  --no-color             Desactiva colores ANSI.
  --version              Muestra la versión y termina.
  -h, --help             Muestra esta ayuda.

Ejemplos:
  ./sysdiag.sh                   # Menú si hay terminal interactiva
  ./sysdiag.sh --summary
  ./sysdiag.sh --recent-errors
  ./sysdiag.sh --section systemd --verbose --explain
  ./sysdiag.sh --section boot --verbose --explain
  ./sysdiag.sh --section containers --verbose --explain
  ./sysdiag.sh --containers-deep --verbose --explain
  ./sysdiag.sh --section kubernetes --k8s-mode deep --verbose --explain
  ./sysdiag.sh --section kubernetes --k8s-node worker-03 --k8s-mode exhaustive
  ./sysdiag.sh --all --json
  ./sysdiag.sh --guide
  ./sysdiag.sh --all
  ./sysdiag.sh --verbose --explain
  ./sysdiag.sh --sample 5
  ./sysdiag.sh --section network --sample 10 --verbose
  ./sysdiag.sh --section recent --report

Seguridad:
  SYSdiag ${SYS_DIAG_VERSION} es read-only. No mata procesos, reinicia servicios,
  modifica ficheros, instala paquetes, desmonta FS, cambia red/firewall ni sysctls.
  En Kubernetes/OpenShift no ejecuta apply/create/delete/patch/edit/exec/debug,
  port-forward, drain, cordon ni otras acciones correctivas o mutantes.
EOF_USAGE
}

parse_args() {
  while (($#)); do
    case "$1" in
      --verbose) VERBOSE=1; shift ;;
      --explain) EXPLAIN=1; shift ;;
      --no-color) NO_COLOR=1; shift ;;
      --summary) SUMMARY_ONLY=1; SECTION="all"; shift ;;
      --container-mode)
        [[ $# -ge 2 ]] || die "Falta el modo tras --container-mode"
        case "$2" in normal|deep) CONTAINER_MODE="$2" ;; *) die "--container-mode admite normal o deep" ;; esac
        CONTAINER_MODE_EXPLICIT=1; shift 2 ;;
      --containers-deep) SECTION="containers"; SUMMARY_ONLY=0; CONTAINER_MODE="deep"; CONTAINER_MODE_EXPLICIT=1; shift ;;
      --k8s-mode)
        [[ $# -ge 2 ]] || die "Falta el modo tras --k8s-mode"
        case "$2" in quick|deep|exhaustive) K8S_MODE="$2" ;; *) die "--k8s-mode admite quick, deep o exhaustive" ;; esac
        shift 2 ;;
      --k8s-node) [[ $# -ge 2 ]] || die "Falta el nodo tras --k8s-node"; K8S_SCOPE=node; K8S_TARGET_NODE="$2"; shift 2 ;;
      --k8s-namespace) [[ $# -ge 2 ]] || die "Falta el namespace tras --k8s-namespace"; K8S_SCOPE=namespace; K8S_TARGET_NAMESPACE="$2"; shift 2 ;;
      --k8s-pod)
        [[ $# -ge 2 && "$2" == */* ]] || die "--k8s-pod requiere namespace/pod"
        K8S_SCOPE=pod; K8S_TARGET_NAMESPACE="${2%%/*}"; K8S_TARGET_POD="${2#*/}"; shift 2 ;;
      --k8s-context) [[ $# -ge 2 ]] || die "Falta el contexto tras --k8s-context"; K8S_CONTEXT="$2"; shift 2 ;;
      --k8s-kubeconfig) [[ $# -ge 2 ]] || die "Falta el fichero tras --k8s-kubeconfig"; K8S_KUBECONFIG="$2"; shift 2 ;;
      --k8s-no-auth-prompt) K8S_AUTH_PROMPT=0; shift ;;
      --recent-errors) SECTION="recent"; SUMMARY_ONLY=0; shift ;;
      --guide) SECTION="guide"; SUMMARY_ONLY=0; shift ;;
      --json) JSON_OUTPUT=1; NO_COLOR=1; FORCE_MENU=0; shift ;;
      --all) SECTION="all"; SUMMARY_ONLY=0; shift ;;
      --menu) FORCE_MENU=1; shift ;;
      --sample)
        [[ $# -ge 2 ]] || die "Faltan segundos tras --sample"
        [[ "$2" =~ ^[0-9]+$ ]] || die "--sample requiere un entero entre 1 y 30"
        (( $2 >= 1 && $2 <= 30 )) || die "--sample debe estar entre 1 y 30 segundos"
        SAMPLE_SECONDS="$2"; shift 2 ;;
      --section)
        [[ $# -ge 2 ]] || die "Falta el nombre de sección tras --section"
        SECTION="$2"
        case "$SECTION" in system|cpu|processes|memory|io|filesystem|network|logging|recent|systemd|boot|containers|kubernetes|guide|all) ;; *) die "Sección no válida: $SECTION";; esac
        shift 2 ;;
      --report)
        if [[ $# -ge 2 && "$2" != --* ]]; then REPORT_FILE="$2"; shift 2; else REPORT_FILE="AUTO"; shift; fi ;;
      --machine-report) [[ $# -ge 2 ]] || die "Falta el fichero tras --machine-report"; MACHINE_REPORT_FILE="$2"; shift 2 ;;
      --internal-sections) [[ $# -ge 2 ]] || die "Faltan secciones tras --internal-sections"; INTERNAL_SECTIONS="$2"; shift 2 ;;
      --host-only) HOST_ONLY=1; SECTION="all"; shift ;;
      --version) printf 'SYSdiag %s\nAutor: Chus (GitHub: chus87)\nEngine: bash-standalone\n' "$SYS_DIAG_VERSION"; exit 0 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Opción desconocida: $1" ;;
    esac
  done
}

init_runtime() {
  RUNTIME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sysdiag.XXXXXX" 2>/dev/null || true)"
  [[ -n "$RUNTIME_DIR" && -d "$RUNTIME_DIR" ]] || die "No puedo crear directorio temporal"
  trap '[[ -n "${RUNTIME_DIR:-}" && -d "${RUNTIME_DIR:-}" ]] && rm -rf -- "$RUNTIME_DIR"' EXIT HUP INT TERM
}

# Collect/analyze a set of sections as one diagnostic transaction. This avoids
# duplicate collection and guarantees that an I/O selection requests iostat
# before the shared sampling window starts.
run_selected_sections() {
  local item need_sample=0 want_iostat=0 need_system=0 need_process_snapshot=0
  local do_system=0 do_cpu=0 do_processes=0 do_memory=0 do_io=0 do_filesystem=0 do_network=0 do_logging=0 do_recent=0 do_systemd=0 do_boot=0 do_containers=0 do_kubernetes=0
  local -a analysis_categories=()

  for item in "$@"; do
    case "$item" in
      system) do_system=1 ;;
      cpu) do_cpu=1; need_sample=1; need_system=1; need_process_snapshot=1 ;;
      processes) do_processes=1; need_process_snapshot=1 ;;
      memory) do_memory=1; need_sample=1 ;;
      io) do_io=1; need_sample=1; want_iostat=1 ;;
      filesystem) do_filesystem=1 ;;
      network) do_network=1; need_sample=1 ;;
      logging) do_logging=1 ;;
      recent) do_recent=1 ;;
      systemd) do_systemd=1 ;;
      boot) do_boot=1 ;;
      containers) do_containers=1 ;;
      kubernetes) do_kubernetes=1 ;;
    esac
  done

  (( do_system || need_system )) && collect_system
  (( need_sample )) && ensure_shared_sample "$want_iostat"
  (( need_process_snapshot )) && collect_process_states

  if (( do_cpu )); then collect_cpu; analyze_cpu; analysis_categories+=(cpu); fi
  if (( do_processes )); then analyze_processes; analysis_categories+=(processes); fi
  if (( do_cpu && need_process_snapshot )); then analyze_cross_signals; fi
  if (( do_memory )); then collect_memory; analyze_memory; analysis_categories+=(memory); fi
  if (( do_io )); then collect_io; analyze_io; analysis_categories+=(io); fi
  if (( do_filesystem )); then collect_filesystem; analyze_filesystem; analysis_categories+=(filesystem); fi
  if (( do_network )); then collect_network; analyze_network; analysis_categories+=(network); fi
  if (( do_logging )); then collect_logging; analyze_logging; analysis_categories+=(logging); fi
  if (( do_recent )); then collect_recent_events; fi
  if (( do_systemd )); then collect_systemd_services; analyze_systemd_services; analysis_categories+=(systemd); fi
  if (( do_boot )); then collect_boot; analyze_boot; analysis_categories+=(boot); fi
  if (( do_containers )); then collect_containers; analyze_containers; analysis_categories+=(containers); fi
  if (( do_kubernetes )); then collect_kubernetes; analyze_kubernetes; analysis_categories+=(kubernetes); fi

  # Print in a stable order regardless of the user's input order.
  if (( SUPPRESS_TEXT == 0 )); then
    (( do_system )) && print_system
    (( do_cpu )) && print_cpu
    (( do_processes )) && print_processes
    (( do_memory )) && print_memory
    (( do_io )) && print_io
    (( do_filesystem )) && print_filesystem
    (( do_network )) && print_network
    (( do_logging )) && print_logging
    (( do_recent )) && print_recent_events
    (( do_systemd )) && print_systemd_services
    (( do_boot )) && print_boot
    (( do_containers )) && print_containers
    (( do_kubernetes )) && print_kubernetes

    # Generic recent events are evidence for triage, not an automatic finding.
    # Only print scoring when at least one scored diagnostic section was selected.
    if ((${#analysis_categories[@]})); then
      print_analysis_summary "${analysis_categories[@]}"
    fi
  fi
}

run_section() {
  if [[ "$1" == guide ]]; then
    print_reference_guide
  else
    run_selected_sections "$1"
  fi
}

collect_and_analyze_all() {
  collect_system
  ensure_shared_sample 1
  collect_cpu; collect_process_states; collect_memory; collect_io; collect_filesystem; collect_network; collect_logging; collect_systemd_services; collect_boot; collect_containers; collect_kubernetes
  analyze_cpu; analyze_processes; analyze_memory; analyze_io; analyze_filesystem; analyze_network; analyze_logging; analyze_systemd_services; analyze_boot; analyze_containers; analyze_kubernetes; analyze_cross_signals
}

run_all() {
  collect_and_analyze_all
  print_system; print_cpu; print_processes; print_memory; print_io; print_filesystem; print_network; print_logging; print_systemd_services; print_boot; print_containers; print_kubernetes
  print_analysis_summary cpu io memory processes filesystem network logging systemd boot containers kubernetes
}

run_summary() {
  collect_and_analyze_all
  print_quick_summary
}

show_menu() {
  local input choice
  local -a choices=()
  declare -A selected=()

  while true; do
    printf '\n%s¿Qué quieres analizar?%s\n\n' "$C_BOLD" "$C_RESET"
    printf '  1) Resumen general\n'
    printf '  2) CPU y procesos\n'
    printf '  3) Memoria\n'
    printf '  4) I/O y almacenamiento\n'
    printf '  5) Filesystems\n'
    printf '  6) Red\n'
    printf '  7) Logs / journald\n'
    printf '  8) Warnings y errores recientes (última hora)\n'
    printf '  9) Systemd / servicios\n'
    printf ' 10) Boot / arranque\n'
    printf ' 11) Contenedores / runtime\n'
    printf ' 12) Kubernetes / OpenShift\n'
    printf ' 13) Guía de diagnóstico y comandos\n'
    printf ' 14) Diagnóstico completo\n\n'
    printf '  0) Salir\n\n'
    printf 'Puedes combinar secciones, por ejemplo: 4,6,8\n'
    printf 'Selecciona una opción: '
    IFS= read -r input || return 1
    [[ -n "${input//[[:space:],]/}" ]] || { warn "Selección vacía."; continue; }

    choices=()
    read -r -a choices <<<"${input//,/ }"
    selected=()
    local valid=1 has_summary=0 has_all=0 has_guide=0 has_exit=0
    for choice in "${choices[@]}"; do
      case "$choice" in
        0) has_exit=1 ;;
        1) has_summary=1 ;;
        2) selected[cpu]=1; selected[processes]=1 ;;
        3) selected[memory]=1 ;;
        4) selected[io]=1 ;;
        5) selected[filesystem]=1 ;;
        6) selected[network]=1 ;;
        7) selected[logging]=1 ;;
        8) selected[recent]=1 ;;
        9) selected[systemd]=1 ;;
        10) selected[boot]=1 ;;
        11) selected[containers]=1 ;;
        12) selected[kubernetes]=1 ;;
        13) has_guide=1 ;;
        14) has_all=1 ;;
        *) valid=0 ;;
      esac
    done

    (( valid == 1 )) || { warn "Selección no válida. Usa números del 0 al 14."; continue; }
    if (( has_exit == 1 )); then
      if (( ${#choices[@]} == 1 )); then MENU_SELECTION=(exit); return 0; fi
      warn "La opción 0 debe elegirse sola."; continue
    fi
    if (( has_summary == 1 )); then
      if (( ${#choices[@]} == 1 )); then MENU_SELECTION=(summary); return 0; fi
      warn "El resumen general (1) debe elegirse solo."; continue
    fi
    if (( has_guide == 1 )); then
      if (( ${#choices[@]} == 1 )); then MENU_SELECTION=(guide); return 0; fi
      warn "La guía (13) debe elegirse sola."; continue
    fi
    if (( has_all == 1 )); then
      MENU_SELECTION=(all); return 0
    fi

    MENU_SELECTION=()
    for choice in cpu processes memory io filesystem network logging recent systemd boot containers kubernetes; do
      [[ -n "${selected[$choice]:-}" ]] && MENU_SELECTION+=("$choice")
    done
    ((${#MENU_SELECTION[@]})) && return 0
    warn "No se ha seleccionado ninguna sección."
  done
}

configure_container_mode_interactive() {
  (( ${CONTAINER_MODE_EXPLICIT:-0} == 0 )) || return 0
  [[ -t 0 && -t 1 ]] || return 0
  local input
  while true; do
    printf '\n%sModo de análisis de contenedores%s\n\n' "$C_BOLD" "$C_RESET"
    printf '  1) Normal: estado, inspect, recursos, health, límites y storage.\n'
    printf '  2) Profundo: todos los contenedores y todo el histórico de logs accesible.\n\n'
    printf 'El modo profundo puede tardar varios minutos y no muestra los logs completos; los analiza y resume.\n'
    printf 'Selecciona una opción [1]: '
    IFS= read -r input || input=""
    case "${input:-1}" in
      1) CONTAINER_MODE="normal"; return 0 ;;
      2) CONTAINER_MODE="deep"; return 0 ;;
      *) warn "Selección no válida. Usa 1 o 2." ;;
    esac
  done
}

run_menu_selection() {
  case "${MENU_SELECTION[0]:-}" in
    exit) return 10 ;;
    summary) run_summary; return 0 ;;
    guide) print_reference_guide; return 0 ;;
    all) run_all; return 0 ;;
  esac
  local x has_containers=0
  for x in "${MENU_SELECTION[@]}"; do
    [[ "$x" == kubernetes ]] && K8S_INTERACTIVE_CONFIG=1
    [[ "$x" == containers ]] && has_containers=1
  done
  (( has_containers == 1 )) && configure_container_mode_interactive
  run_selected_sections "${MENU_SELECTION[@]}"
}


_write_machine_report() {
  local dest="$1"; shift
  [[ -n "$dest" ]] || return 0
  mkdir -p "$(dirname "$dest")" 2>/dev/null || return 1
  [[ ! -L "$dest" ]] || return 1
  ( umask 077; print_json_report "$@" >"$dest" ) || return 1
  chmod 600 "$dest" 2>/dev/null || true
}

main() {
  local original_argc=$#
  parse_args "$@"
  init_runtime

  if (( JSON_OUTPUT == 1 )) && [[ "$SECTION" == guide ]]; then
    die "--json no es compatible con --guide; la guía es una referencia humana, no un diagnóstico estructurado."
  fi

  # Sin argumentos, una terminal real abre el menú. En pipes/automatización se
  # conserva el comportamiento histórico y se ejecuta el diagnóstico completo.
  if (( JSON_OUTPUT == 0 )) && { (( FORCE_MENU == 1 )) || { (( original_argc == 0 )) && [[ -t 0 && -t 1 ]]; }; }; then
    MENU_REQUESTED=1
  fi

  # El menú se pinta antes de redirigir --report para que el informe contenga
  # diagnóstico y no preguntas/respuestas de la interfaz interactiva.
  init_output
  if (( MENU_REQUESTED == 1 )); then
    print_banner
    show_menu || die "No se pudo leer la selección del menú"
    [[ "${MENU_SELECTION[0]:-}" == exit ]] && return 0
  fi

  if [[ "$REPORT_FILE" == AUTO ]]; then
    local host ts
    host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo host)"; ts="$(date '+%Y%m%d-%H%M%S')"
    if (( JSON_OUTPUT == 1 )); then REPORT_FILE="./sysdiag-${host}-${ts}.json"; else REPORT_FILE="./sysdiag-${host}-${ts}.txt"; fi
  fi
  if [[ -n "$REPORT_FILE" ]]; then NO_COLOR=1; init_output; fi

  init_scoring


  # Modos internos usados por el núcleo Go. Deben resolverse antes de cualquier
  # redirección de report para que host-only no caiga por error en --all.
  if [[ -n "$INTERNAL_SECTIONS" ]]; then
    IFS=',' read -r -a _internal_arr <<<"$INTERNAL_SECTIONS"
    SUPPRESS_TEXT=$(( JSON_OUTPUT == 1 ? 1 : 0 ))
    run_selected_sections "${_internal_arr[@]}"
    if (( JSON_OUTPUT == 1 )); then print_json_report "${_internal_arr[@]}"; fi
    [[ -n "$MACHINE_REPORT_FILE" ]] && _write_machine_report "$MACHINE_REPORT_FILE" "${_internal_arr[@]}"
    return 0
  fi

  if (( HOST_ONLY == 1 )); then
    local -a _host_sections=(system cpu processes memory io filesystem network logging recent systemd boot)
    SUPPRESS_TEXT=$(( JSON_OUTPUT == 1 ? 1 : 0 ))
    run_selected_sections "${_host_sections[@]}"
    if (( JSON_OUTPUT == 1 )); then print_json_report cpu processes memory io filesystem network logging systemd boot; fi
    [[ -n "$MACHINE_REPORT_FILE" ]] && _write_machine_report "$MACHINE_REPORT_FILE" cpu processes memory io filesystem network logging systemd boot
    return 0
  fi

  if [[ -n "$REPORT_FILE" ]]; then
    mkdir -p "$(dirname "$REPORT_FILE")" 2>/dev/null || die "No puedo crear el directorio del informe"
    [[ ! -L "$REPORT_FILE" ]] || die "El destino del informe es un enlace simbólico; se rechaza por seguridad"
    ( umask 077; : >"$REPORT_FILE" ) || die "No puedo crear el informe"
    chmod 600 "$REPORT_FILE" 2>/dev/null || true
    if (( JSON_OUTPUT == 1 )); then
      # Keep stderr outside the JSON stream so an unexpected diagnostic cannot
      # corrupt a machine-readable report.
      exec > >(tee "$REPORT_FILE")
    else
      exec > >(tee "$REPORT_FILE") 2>&1
    fi
  fi


  if (( JSON_OUTPUT == 1 )); then
    SUPPRESS_TEXT=1
    if [[ "$SECTION" == all || "$SUMMARY_ONLY" == 1 ]]; then
      collect_and_analyze_all
      collect_recent_events
      print_json_report all
    else
      collect_system
      run_selected_sections "$SECTION"
      print_json_report "$SECTION"
    fi
  else
    (( MENU_REQUESTED == 0 )) && print_banner
    if (( MENU_REQUESTED == 1 )); then
      run_menu_selection
    elif (( SUMMARY_ONLY == 1 )); then
      run_summary
    elif [[ "$SECTION" == all ]]; then
      run_all
    else
      run_section "$SECTION"
    fi
  fi

  if [[ -n "$MACHINE_REPORT_FILE" && "$JSON_OUTPUT" == 0 ]]; then
    if [[ "$SECTION" == all || "$SUMMARY_ONLY" == 1 ]]; then
      _write_machine_report "$MACHINE_REPORT_FILE" all
    elif (( MENU_REQUESTED == 1 )); then
      case "${MENU_SELECTION[0]:-}" in
        all|summary) _write_machine_report "$MACHINE_REPORT_FILE" all ;;
        guide|exit|'') ;;
        *) _write_machine_report "$MACHINE_REPORT_FILE" "${MENU_SELECTION[@]}" ;;
      esac
    else
      _write_machine_report "$MACHINE_REPORT_FILE" "$SECTION"
    fi
  fi

  if [[ -n "$REPORT_FILE" && "$JSON_OUTPUT" == 0 ]]; then printf '\nInforme guardado en: %s\n' "$REPORT_FILE"; fi
  return 0
}

main "$@"
