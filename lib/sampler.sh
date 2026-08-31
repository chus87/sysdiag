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
