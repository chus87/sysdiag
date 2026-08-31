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
