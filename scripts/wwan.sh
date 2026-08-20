#!/usr/bin/env bash
# Phone21 — „ostrovní režim": internet přes USB modem (QMI data)
#
#   wwan.sh start    # sestavit datové spojení a nastavit záložní default route
#   wwan.sh stop     # spojení položit a uklidit
#   wwan.sh status   # stav bearer + rozhraní
#   wwan.sh watch    # failover smyčka: primární konektivitu hlídá pingem,
#                    # při výpadku přepne default route na modem, po zotavení zpět
#
# Env: WWAN_APN (default internet), WWAN_DEV (/dev/cdc-wdm0),
#      WWAN_IF (jinak se rozhraní detekuje podle sysfs),
#      WWAN_METRIC_STANDBY=700, WWAN_METRIC_ACTIVE=50,
#      WWAN_CHECK_HOST=1.1.1.1, WWAN_CHECK_INTERVAL=15, WWAN_FAIL_N=4
#
# Poznámky:
# - Data (rmnet) jedou nezávisle na hlasové části brány (AT/PCM porty);
#   s VoLTE tečou data i během hovoru. BEZ VoLTE jde hovor CSFB do 2G a
#   datové spojení na tu dobu padá — hlídka to hlásí do logu a po hovoru
#   spojení postaví znovu.
# - Kontejner potřebuje: network_mode: host, cap_add NET_ADMIN,
#   devices /dev/cdc-wdm0 (viz compose).
# - V LXC nasazení POZOR: datové rozhraní žije v netns hostitele — bez
#   passthrough (lxc.net.X.type=phys) tam ostrovní režim nejde; feature
#   cílí na nativní/Umbrel nasazení.

set -u
DEV="${WWAN_DEV:-/dev/cdc-wdm0}"
APN="${WWAN_APN:-internet}"
M_STANDBY="${WWAN_METRIC_STANDBY:-700}"
M_ACTIVE="${WWAN_METRIC_ACTIVE:-50}"
CHECK_HOST="${WWAN_CHECK_HOST:-1.1.1.1}"
CHECK_INT="${WWAN_CHECK_INTERVAL:-15}"
FAIL_N="${WWAN_FAIL_N:-4}"
STATE=/var/lib/phone21/wwan.state

log() { echo "[wwan] $(date -Is) $*"; }
qmi() { timeout 25 qmicli -d "$DEV" "$@"; }

# Jméno datového rozhraní není napevno: podle systému a jmenné politiky to
# je wwan0, nebo předvídatelný název typu wwp1s0u1u1u4i5. Poznávací znamení
# je adresář qmi/ v sysfs.
detect_if() {
  local d
  for d in /sys/class/net/*/qmi; do
    [[ -d "$d" ]] || continue
    d="${d%/qmi}"
    echo "${d##*/}"
    return 0
  done
  return 1
}
IF="${WWAN_IF:-$(detect_if || true)}"
IF="${IF:-wwan0}"

wwan_start() {
  [[ -c "$DEV" ]] || { log "CHYBA: $DEV neexistuje"; return 1; }
  [[ -d "/sys/class/net/$IF" ]] || { log "CHYBA: rozhraní $IF neexistuje (qmi_wwan driver?)"; return 1; }
  ip link set "$IF" down 2>/dev/null
  # raw_ip musí být Y, jinak rozhraním neteče nic; v kontejneru je /sys jen
  # pro čtení, takže když už Y není, musí to přepnout hostitel
  if ! echo Y > "/sys/class/net/$IF/qmi/raw_ip" 2>/dev/null; then
    [[ "$(cat "/sys/class/net/$IF/qmi/raw_ip" 2>/dev/null)" == "Y" ]] || \
      log "POZOR: $IF nemá raw_ip=Y a nejde přepnout (/sys read-only) — data nepotečou"
  fi
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

# Route po pádu spojení nezmizí sama, takže „jede to" se musí ptát modemu.
bearer_ok() { qmi --wds-get-packet-service-status 2>/dev/null | grep -q "'connected'"; }

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
    # Zapnuto/vypnuto se řídí za běhu z web UI (AstDB phone21/island_mode).
    island_on() {
      asterisk -rx "database get phone21 island_mode" 2>/dev/null | grep -q "Value: on"
    }
    # Bez VoLTE jde hovor CSFB do 2G a datové spojení na tu dobu padá —
    # v ostrovním režimu tím zmizí i cesta k telefonu. Stav plní mbn smyčka.
    # Neznámý stav (jinde než v Umbrel appce ho nikdo neplní) se nehlásí —
    # varuje se jen na prokazatelně chybějící VoLTE.
    volte_ok() { [[ "$(cat /var/lib/phone21/volte 2>/dev/null)" != "not-registered" ]]; }
    fails=0; active=0; warned=0; volte_warned=0
    while true; do
      # rozhraní se může objevit až po uvolnění QMI (ModemManager) — hlídka
      # proto nekončí, jen čeká
      [[ -d "/sys/class/net/$IF" ]] || IF="$(detect_if || echo "$IF")"
      if [[ ! -c "$DEV" || ! -d "/sys/class/net/$IF" ]]; then
        [[ $warned -eq 0 ]] && log "datové rozhraní modemu zatím není k dispozici ($DEV / $IF) — čekám"
        warned=1
        sleep "$CHECK_INT"
        continue
      fi
      if [[ $warned -eq 1 ]]; then log "datové rozhraní $IF je k dispozici"; warned=0; fi
      if ! island_on; then
        if [[ $active -eq 1 ]]; then
          log "ostrovní režim vypnut v nastavení — vracím modem do standby"
          ip route replace default dev "$IF" metric "$M_STANDBY" 2>/dev/null
          active=0
        fi
        fails=0
        sleep "$CHECK_INT"
        continue
      fi
      if volte_ok; then
        volte_warned=0
      elif [[ $volte_warned -eq 0 ]]; then
        log "POZOR: modem není registrovaný na VoLTE — hovor přepne do 2G a"
        log "       ostrovní spojení na tu dobu vypadne (data se obnoví po hovoru)"
        volte_warned=1
      fi
      if primary_ok; then
        fails=0
        if [[ $active -eq 1 ]]; then
          log "primární konektivita zpět — vracím modem do standby"
          ip route replace default dev "$IF" metric "$M_STANDBY" 2>/dev/null
          active=0
        fi
      elif [[ $active -eq 1 ]] && ! bearer_ok; then
        # spojení spadlo za běhu ostrovního režimu (typicky CSFB hovor) —
        # postavit ho znovu, jinak zůstane brána bez cesty ven
        log "ostrovní spojení spadlo — obnovuji"
        wwan_stop >/dev/null 2>&1
        if wwan_start; then
          ip route replace default dev "$IF" metric "$M_ACTIVE" 2>/dev/null
        else
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
