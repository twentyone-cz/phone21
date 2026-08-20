#!/usr/bin/env bash
#
# Phone21 — zapnutí a hlídání filtru provozu z privátní sítě.
#
#   tunnel-firewall.sh apply    načte pravidla (respektuje FW_DISABLE a ladění)
#   tunnel-firewall.sh watch    smyčka: reaguje na změnu přístupu i firewall.env
#   tunnel-firewall.sh check    jen ověří syntaxi pravidel (smoke test)
#   tunnel-firewall.sh status   vypíše stav
#   tunnel-firewall.sh off      pravidla odstraní
set -u

DATA="${PHONE21_DATA:-/var/lib/phone21}"
RULES="${FW_RULES:-/opt/phone21/tunnel-firewall.nft}"
GEN=/run/phone21-fw.nft
ERRLOG=/run/phone21-fw.err
STATE="$DATA/firewall"
ENVFILE="$DATA/firewall.env"
ACCESS_FILE="$DATA/ts/tunnel_access"
LEGACY_DEBUG="$DATA/webui/debug_ssh"
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

# Zvolený přístup z privátní sítě: phone | endpoint | router.
# Starý přepínač ladění se překládá na endpoint (SSH je služba miniserveru).
access_level() {
  local value=""
  [[ -f "$ACCESS_FILE" ]] && value="$(tr -d '[:space:]' < "$ACCESS_FILE" 2>/dev/null)"
  case "$value" in
    endpoint|router|phone) printf '%s' "$value"; return 0 ;;
  esac
  if [[ -f "$LEGACY_DEBUG" && "$(tr -d '[:space:]' < "$LEGACY_DEBUG" 2>/dev/null)" == "1" ]]; then
    printf 'endpoint'
  else
    printf 'phone'
  fi
}

access_label() {
  case "$1" in
    endpoint) printf 'celý miniserver' ;;
    router)   printf 'i dál do sítě' ;;
    *)        printf 'jen telefon' ;;
  esac
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
  case "$(access_level)" in
    endpoint)
      printf '\nadd rule inet phone21 tun_pre counter accept\n' >> "$GEN"
      ;;
    router)
      printf '\nadd rule inet phone21 tun_pre counter accept\n' >> "$GEN"
      printf 'add rule inet phone21 fwd_pre counter accept\n' >> "$GEN"
      ;;
  esac
}

load() { nft -f "$GEN" 2>"$ERRLOG"; }

# Bez modulů pro logování projde ruleset i bez log řádků.
load_without_log() {
  grep -v 'log prefix' "$GEN" > "$GEN.nolog" && mv "$GEN.nolog" "$GEN"
  nft -f "$GEN" 2>"$ERRLOG"
}

apply() {
  local level dbg
  level="$(access_level)"
  dbg="$(access_label "$level")"
  # průchod paketů je potřeba jen pro poslední stupeň; na hostiteli ho
  # obvykle zapíná už docker
  if [[ "$level" == "router" ]]; then
    if [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" != "1" ]]; then
      sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 \
        || log "POZOR: průchod paketů je vypnutý a nejde zapnout — na hostiteli: sysctl -w net.ipv4.ip_forward=1"
    fi
  fi

  if [[ "$(read_env FW_DISABLE)" == "1" ]]; then
    nft delete table $TABLE 2>/dev/null || true
    set_state "disabled"
    log "vypnuto souborem firewall.env — provoz z privátní sítě se nefiltruje"
    return 0
  fi

  generate || { set_state "error"; log "POZOR: pravidla se nepodařilo připravit — brána je z privátní sítě OTEVŘENÁ"; return 1; }

  if load || load_without_log; then
    set_state "active $(date '+%Y-%m-%d %H:%M:%S') pristup=$dbg"
    log "aktivní (přístup: $dbg)"
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
    cur_dbg="$(access_level)"
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
