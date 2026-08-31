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
