#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"
TMP="$TEST_TMP_ROOT/network"; mkdir -p "$TMP"

"$BASE_DIR/sysdiag-legacy.sh" --section network --no-color > "$TMP/network.txt"
for pattern in '^RED Y TCP$' 'Estados TCP' 'Actividad durante 1s' 'MTU / PMTU' 'TCP MTU probe fail/success nuevos:' 'tracepath -n <IP_DESTINO>' '^ANÁLISIS Y PRIORIZACIÓN$'; do
  assert_grep "$pattern" "$TMP/network.txt"
done

(
  source "$BASE_DIR/lib/common.sh"; source "$BASE_DIR/lib/scoring.sh"; source "$BASE_DIR/modules/network.sh"
  init_scoring; NETWORK_AVAILABLE=1; NET_SAMPLE_SECONDS=1; NET_DEFAULT4_IFACE=""
  NET_RX_ERR_DELTA=0; NET_TX_ERR_DELTA=0; NET_RX_DROP_DELTA=0; NET_TX_DROP_DELTA=0; NET_SOFTNET_DROP_DELTA=0; NET_SOFTNET_SQUEEZE_DELTA=0
  NET_LISTEN_OVER_DELTA=0; NET_LISTEN_DROP_DELTA=0; NET_TCP_RETRANS_DELTA=25; NET_TCP_SYN_RETRANS_DELTA=2
  TCP_CLOSE_WAIT=150; TCP_SYN_SENT=25; CONNTRACK_AVAILABLE=0
  analyze_network
  (( SCORE[network] >= 8 )); [[ "$(confidence_for_category network)" == ALTA ]]; (( ${DOMAIN_COUNT[network]} >= 3 ))
)

(
  source "$BASE_DIR/lib/common.sh"; source "$BASE_DIR/lib/scoring.sh"; source "$BASE_DIR/modules/network.sh"
  init_scoring; NETWORK_AVAILABLE=1; NET_SAMPLE_SECONDS=1; NET_DEFAULT4_IFACE=""
  NET_RX_ERR_DELTA=0; NET_TX_ERR_DELTA=0; NET_RX_DROP_DELTA=0; NET_TX_DROP_DELTA=0; NET_SOFTNET_DROP_DELTA=0; NET_SOFTNET_SQUEEZE_DELTA=0
  NET_LISTEN_OVER_DELTA=0; NET_LISTEN_DROP_DELTA=0; NET_TCP_RETRANS_DELTA=0; NET_TCP_SYN_RETRANS_DELTA=0
  TCP_CLOSE_WAIT=0; TCP_SYN_SENT=0; CONNTRACK_AVAILABLE=0
  NET_FRAG_FAIL_DELTA=0; NET_IP6_FRAG_FAIL_DELTA=0; NET_IP6_TOO_BIG_DELTA=0; NET_ICMP6_PTB_DELTA=0; NET_TCP_MTUP_FAIL_DELTA=0
  analyze_network; [[ "${SCORE[network]}" == 0 ]]
  init_scoring; NET_TCP_RETRANS_DELTA=25; NET_FRAG_FAIL_DELTA=1; NET_TCP_MTUP_FAIL_DELTA=1
  analyze_network; (( SCORE[network] >= 8 ))
  printf '%s\n' "${EVIDENCE[@]}" | grep -q NET_PMTU_KERNEL
  printf '%s\n' "${NEXT_COMMANDS[@]}" | grep -q 'ping -4 -M do -s 1472 <IP_DESTINO>'
)

pass network
