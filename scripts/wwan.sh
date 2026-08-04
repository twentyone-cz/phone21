#!/usr/bin/env bash
# GSM2SIP — „ostrovní režim": internet přes USB modem (QMI data, wwan0)
#
#   wwan.sh start    # sestavit datové spojení a nastavit záložní default route
#   wwan.sh stop     # spojení položit a uklidit
#   wwan.sh status   # stav bearer + rozhraní
#   wwan.sh watch    # failover smyčka: primární konektivitu hlídá pingem,
#                    # při výpadku přepne default route na modem, po zotavení zpět
#
# Env: WWAN_APN (default internet), WWAN_DEV (/dev/cdc-wdm0), WWAN_IF (wwan0),
#      WWAN_METRIC_STANDBY=700, WWAN_METRIC_ACTIVE=50,
#      WWAN_CHECK_HOST=1.1.1.1, WWAN_CHECK_INTERVAL=15, WWAN_FAIL_N=4
#
# Poznámky:
# - Data (rmnet) jedou nezávisle na hlasové části brány (AT/PCM porty);
#   s VoLTE tečou data i během hovoru.
# - Kontejner potřebuje: network_mode: host, cap_add NET_ADMIN,
#   devices /dev/cdc-wdm0 (viz compose).
# - V LXC nasazení POZOR: rozhraní wwan0 žije v netns hostitele — bez
#   passthrough (lxc.net.X.type=phys) tam ostrovní režim nejde; feature
#   cílí na nativní/Umbrel nasazení.

set -u
DEV="${WWAN_DEV:-/dev/cdc-wdm0}"
IF="${WWAN_IF:-wwan0}"
APN="${WWAN_APN:-internet}"
M_STANDBY="${WWAN_METRIC_STANDBY:-700}"
M_ACTIVE="${WWAN_METRIC_ACTIVE:-50}"
CHECK_HOST="${WWAN_CHECK_HOST:-1.1.1.1}"
CHECK_INT="${WWAN_CHECK_INTERVAL:-15}"
FAIL_N="${WWAN_FAIL_N:-4}"
STATE=/var/lib/gsm2sip/wwan.state

log() { echo "[wwan] $(date -Is) $*"; }
qmi() { timeout 25 qmicli -d "$DEV" "$@"; }

wwan_start() {
  [[ -c "$DEV" ]] || { log "CHYBA: $DEV neexistuje"; return 1; }
  [[ -d "/sys/class/net/$IF" ]] || { log "CHYBA: rozhraní $IF neexistuje (qmi_wwan driver?)"; return 1; }
  ip link set "$IF" down 2>/dev/null
  echo Y > "/sys/class/net/$IF/qmi/raw_ip" 2>/dev/null || true
  out="$(qmi --wds-start-network="apn=$APN,ip-type=4" --client-no-release-cid 2>&1)" \
    || { log "CHYBA start-network: $out"; return 1; }
  handle="$(grep -oE "handle: '[0-9]+'" <<<"$out" | grep -oE '[0-9]+')"
  cid="$(grep -oE "CID: '[0-9]+'" <<<"$out" | grep -oE '[0-9]+')"
  printf 'HANDLE=%s\nCID=%s\n' "$handle" "$cid" > "$STATE"
  set_="$(qmi --wds-get-current-settings --client-cid="$cid" --client-no-release-cid 2>/dev/null)"
  addr="$(grep -oE "IPv4 address: [0-9.]+" <<<"$set_" | awk '{print $3}')"
  pfx="$(grep -oE "IPv4 subnet mask: [0-9.]+" <<<"$set_" | awk '{print $4}')"
  [[ -n "$addr" ]] || { log "CHYBA: bearer bez IPv4 adresy"; return 1; }
  # prefix z masky (default /30 kdyby parsování selhalo)
  bits=$(awk -F. '{n=0; for(i=1;i<=4;i++){x=$i; while(x>0){n+=x%2; x=int(x/2)}}; print n}' <<<"${pfx:-255.255.255.252}")
  ip link set "$IF" up
  ip addr replace "$addr/$bits" dev "$IF"
  ip route replace default dev "$IF" metric "$M_STANDBY"
  log "spojení nahoře: $addr/$bits (APN $APN), default route metric $M_STANDBY"
}

wwan_stop() {
  if [[ -f "$STATE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE"
    [[ -n "${HANDLE:-}" && -n "${CID:-}" ]] \
      && qmi --wds-stop-network="$HANDLE" --client-cid="$CID" >/dev/null 2>&1
    rm -f "$STATE"
  fi
  ip route del default dev "$IF" 2>/dev/null
  ip addr flush dev "$IF" 2>/dev/null
  ip link set "$IF" down 2>/dev/null
  log "spojení položeno"
}

wwan_up() { [[ -f "$STATE" ]] && ip route show default dev "$IF" 2>/dev/null | grep -q .; }

primary_if() {
  ip route show default | awk -v w="$IF" '$5 != w {print $5; exit}'
}

primary_ok() {
  local pif; pif="$(primary_if)"
  [[ -n "$pif" ]] && ping -c1 -W3 -I "$pif" "$CHECK_HOST" >/dev/null 2>&1
}

case "${1:-}" in
  start)  wwan_start ;;
  stop)   wwan_stop ;;
  status)
    qmi --wds-get-packet-service-status 2>/dev/null
    ip addr show "$IF" 2>/dev/null | grep -E "inet |state"
    ip route show default
    ;;
  watch)
    log "failover watch: kontrola $CHECK_HOST po ${CHECK_INT}s, práh $FAIL_N"
    fails=0; active=0
    while true; do
      if primary_ok; then
        fails=0
        if [[ $active -eq 1 ]]; then
          log "primární konektivita zpět — vracím modem do standby"
          ip route replace default dev "$IF" metric "$M_STANDBY" 2>/dev/null
          active=0
        fi
      else
        fails=$((fails + 1))
        if [[ $fails -ge $FAIL_N && $active -eq 0 ]]; then
          log "primární konektivita mrtvá ($fails×) — OSTROVNÍ REŽIM"
          wwan_up || wwan_start
          ip route replace default dev "$IF" metric "$M_ACTIVE" 2>/dev/null
          active=1
        fi
      fi
      sleep "$CHECK_INT"
    done
    ;;
  *) echo "použití: $0 start|stop|status|watch" >&2; exit 2 ;;
esac
