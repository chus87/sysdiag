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
