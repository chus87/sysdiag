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
