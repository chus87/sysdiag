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
