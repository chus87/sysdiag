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
