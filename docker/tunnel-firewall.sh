#!/usr/bin/env bash
#
# Phone21 — zapnutí a hlídání filtru provozu z privátní sítě.
#
#   tunnel-firewall.sh apply    načte pravidla (respektuje FW_DISABLE a ladění)
#   tunnel-firewall.sh watch    smyčka: reaguje na změnu ladění i firewall.env
#   tunnel-firewall.sh check    jen ověří syntaxi pravidel (smoke test)
#   tunnel-firewall.sh status   vypíše stav
#   tunnel-firewall.sh off      pravidla odstraní
set -u

DATA="${GSM2SIP_DATA:-/var/lib/gsm2sip}"
RULES="${FW_RULES:-/opt/gsm2sip/tunnel-firewall.nft}"
GEN=/run/phone21-fw.nft
ERRLOG=/run/phone21-fw.err
STATE="$DATA/firewall"
ENVFILE="$DATA/firewall.env"
DEBUG_FLAG="$DATA/webui/debug_ssh"
TABLE="inet phone21"
INTERVAL="${FW_WATCH_INTERVAL:-15}"

log() { echo "[firewall] $*"; }

# Hodnota z firewall.env. Soubor se čte, nikdy nespouští.
read_env() {
  [[ -f "$ENVFILE" ]] || return 0
  local v
  v="$(sed -n "s/^$1=//p" "$ENVFILE" 2>/dev/null | tail -1)"
  v="${v%\"}"; v="${v#\"}"
  printf '%s' "$v"
}

debug_on() {
  [[ -f "$DEBUG_FLAG" ]] || return 1
  [[ "$(tr -d '[:space:]' < "$DEBUG_FLAG" 2>/dev/null)" == "1" ]]
}

set_state() {
  mkdir -p "$DATA" 2>/dev/null || true
  printf '%s\n' "$1" > "$STATE.tmp" 2>/dev/null || return 0
  chmod 0644 "$STATE.tmp" 2>/dev/null || true
  mv "$STATE.tmp" "$STATE" 2>/dev/null || rm -f "$STATE.tmp"
}

table_present() { nft list table $TABLE >/dev/null 2>&1; }

# Statická pravidla + případné pravidlo pro vzdálenou správu, vše v jedné
# transakci.
generate() {
  umask 077
  cp "$RULES" "$GEN" || return 1
  if debug_on; then
    printf '\nadd rule inet phone21 tun_debug tcp dport 22 counter accept\n' >> "$GEN"
  fi
}

load() { nft -f "$GEN" 2>"$ERRLOG"; }

# Bez modulů pro logování projde ruleset i bez log řádků.
load_without_log() {
  grep -v 'log prefix' "$GEN" > "$GEN.nolog" && mv "$GEN.nolog" "$GEN"
  nft -f "$GEN" 2>"$ERRLOG"
}

apply() {
  local dbg="vypnuto"
  debug_on && dbg="zapnuto"

  if [[ "$(read_env FW_DISABLE)" == "1" ]]; then
    nft delete table $TABLE 2>/dev/null || true
    set_state "disabled"
    log "vypnuto souborem firewall.env — provoz z privátní sítě se nefiltruje"
    return 0
  fi

  generate || { set_state "error"; log "POZOR: pravidla se nepodařilo připravit — brána je z privátní sítě OTEVŘENÁ"; return 1; }

  if load || load_without_log; then
    set_state "active $(date '+%Y-%m-%d %H:%M:%S') ladeni=$dbg"
    log "aktivní (ladění: $dbg)"
    return 0
  fi

  set_state "error"
  log "POZOR: pravidla se nepodařilo načíst — brána je z privátní sítě OTEVŘENÁ; $(tr '\n' ' ' < "$ERRLOG" 2>/dev/null)"
  return 1
}

watch_loop() {
  local last_env="" last_dbg="" cur_env cur_dbg cur_dis
  while true; do
    cur_env="$(stat -c %Y "$ENVFILE" 2>/dev/null || echo 0)"
    cur_dbg=off; debug_on && cur_dbg=on
    cur_dis="$(read_env FW_DISABLE)"
    if [[ "$cur_env" != "$last_env" || "$cur_dbg" != "$last_dbg" ]] \
       || { [[ "$cur_dis" != "1" ]] && ! table_present; }; then
      if [[ -n "$last_env" || -n "$last_dbg" ]]; then
        log "změna nastavení nebo chybějící pravidla — načítám znovu"
      fi
      apply || true
      last_env="$cur_env"; last_dbg="$cur_dbg"
    fi
    sleep "$INTERVAL"
  done
}

case "${1:-apply}" in
  apply)  apply ;;
  watch)  watch_loop ;;
  check)  nft -c -f "$RULES" && echo "pravidla v pořádku" ;;
  status) cat "$STATE" 2>/dev/null || echo "neznámý"; nft list table $TABLE 2>/dev/null | head -40 ;;
  off)    nft delete table $TABLE 2>/dev/null || true; set_state "disabled"; log "pravidla odstraněna" ;;
  *)      echo "použití: $0 apply|watch|check|status|off" >&2; exit 2 ;;
esac
