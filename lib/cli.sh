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
