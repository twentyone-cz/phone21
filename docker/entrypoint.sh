#!/usr/bin/env bash
# GSM2SIP — entrypoint kontejneru asterisk.
#
# Dva režimy:
#  - LXC/klasika (default): /etc/asterisk dodává bind-mount vyrenderovaný
#    hostitelským configure.sh → entrypoint nic nerenderuje a jen spustí
#    Asterisk (chování beze změny).
#  - Umbrel/selfkonfigurace (GSM2SIP_SELFCONFIG=1): /etc/asterisk se
#    renderuje při KAŽDÉM startu ze šablon zapečených v image
#    (/opt/gsm2sip/templates) + env; tajemství se generují při prvním běhu
#    a persistují v /var/lib/gsm2sip/secrets.env (volume).
#
# Volitelné interní služby (Umbrel nemá host systemd):
#   WATCHDOG_INTERNAL=1  hlídání modemu → restart procesu Asterisku
#   MBN_INTERNAL=1       držení MBN carrier profilu (VoLTE), potřeba
#                        /dev/cdc-wdm0 v devices
#   SUPERVISE=1          restart Asterisku po pádu/watchdogu (smyčka)
#
# SIP_DOMAIN: pevná hodnota z env, nebo prázdná → čeká se (max TS_WAIT s)
# na /var/lib/gsm2sip/ts/ip od tailscale sidecaru (tailnet IP brány).

set -u
TPL=/opt/gsm2sip/templates
DATA=/var/lib/gsm2sip
SECRETS="$DATA/secrets.env"
TS_IP_FILE="$DATA/ts/ip"

log() { echo "[entrypoint] $*"; }

render() {
  mkdir -p "$DATA"
  # tajemství: vygenerovat jednou, pak držet (přežívají recreate)
  if [[ -f "$SECRETS" ]]; then
    # shellcheck disable=SC1090
    source "$SECRETS"
  fi
  SIP_USER="${SIP_USER:-softphone}"
  if [[ -z "${SIP_PASSWORD:-}" || -z "${AMI_PASSWORD:-}" ]]; then
    SIP_PASSWORD="${SIP_PASSWORD:-$(head -c 18 /dev/urandom | base64 | tr -d '/+=')}"
    AMI_PASSWORD="${AMI_PASSWORD:-$(head -c 18 /dev/urandom | base64 | tr -d '/+=')}"
    umask 077
    printf 'SIP_USER=%s\nSIP_PASSWORD=%s\nAMI_PASSWORD=%s\n' \
      "$SIP_USER" "$SIP_PASSWORD" "$AMI_PASSWORD" > "$SECRETS"
    log "vygenerována nová tajemství → $SECRETS"
  fi

  # SIP_DOMAIN: env > tailnet IP ze sidecaru > 127.0.0.1 (provizorium,
  # po připojení do privátní sítě se při dalším startu přerenderuje)
  local domain="${SIP_DOMAIN:-}"
  if [[ -z "$domain" ]]; then
    local waited=0 ts_wait="${TS_WAIT:-60}"
    while [[ ! -s "$TS_IP_FILE" && $waited -lt $ts_wait ]]; do
      sleep 2; waited=$((waited + 2))
    done
    domain="$(cat "$TS_IP_FILE" 2>/dev/null || true)"
    [[ -n "$domain" ]] || { domain="127.0.0.1"; log "POZOR: tailnet IP zatím není — SIP_DOMAIN provizorně $domain"; }
  fi

  local ami_bind="${AMI_BIND:-127.0.0.1}"
  local ami_permit="${AMI_PERMIT:-127.0.0.1/255.255.255.255}"
  local cc="${COUNTRY_CODE:-420}"

  esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }
  local f base
  for f in "$TPL"/*.conf; do
    base="$(basename "$f")"
    sed -e "s|\${SIP_USER}|$(esc "$SIP_USER")|g" \
        -e "s|\${SIP_PASSWORD}|$(esc "$SIP_PASSWORD")|g" \
        -e "s|\${SIP_DOMAIN}|$(esc "$domain")|g" \
        -e "s|\${AMI_PASSWORD}|$(esc "$AMI_PASSWORD")|g" \
        -e "s|\${COUNTRY_CODE}|$(esc "$cc")|g" \
        -e "s|\${AMI_BIND}|$(esc "$ami_bind")|g" \
        -e "s|\${AMI_PERMIT}|$(esc "$ami_permit")|g" \
        "$f" > "/etc/asterisk/$base"
  done
  # víc permit položek: čárkami oddělený seznam → samostatné řádky
  if [[ "$ami_permit" == *,* ]]; then
    python3 - "$ami_permit" <<'PYEOF' > /tmp/permits || true
import sys
print("\n".join("permit = " + p.strip() for p in sys.argv[1].split(",")))
PYEOF
    sed -i -e "/^permit = /{r /tmp/permits
d}" /etc/asterisk/manager.conf
  fi
  mkdir -p "$DATA/queue" "$DATA/ts"
  chown -R asterisk "$DATA" /etc/asterisk 2>/dev/null || true
  log "konfigurace vyrenderována (SIP_DOMAIN=$domain)"
}

watchdog_loop() {
  local fails=0 thr="${FAIL_THRESHOLD:-3}" interval="${WATCHDOG_INTERVAL:-30}"
  sleep 120  # po startu má modem čas na inicializaci
  while true; do
    state="$(asterisk -rx 'quectel show device state quectel0' 2>/dev/null | awk '/State/{print $3}')"
    if [[ -z "$state" || "$state" == "Not" ]]; then
      fails=$((fails + 1))
      log "watchdog: modem nezdravý ($fails/$thr)"
      if [[ $fails -ge $thr ]]; then
        log "watchdog: restartuji Asterisk"
        asterisk -rx 'core stop now' 2>/dev/null || true
        fails=0
        sleep 60
      fi
    else
      fails=0
    fi
    sleep "$interval"
  done
}

mbn_loop() {
  # držení MBN profilu (autoselect ho po resetu modemu vrací)
  while true; do
    if [[ -c /dev/cdc-wdm0 ]]; then
      MBN_PROFILE="${MBN_PROFILE:-auto}" /opt/gsm2sip/scripts/mbn-profile.sh auto || true
    fi
    sleep 600
  done
}

if [[ "${GSM2SIP_SELFCONFIG:-0}" == "1" ]]; then
  render
fi
[[ "${WATCHDOG_INTERNAL:-0}" == "1" ]] && watchdog_loop &
[[ "${MBN_INTERNAL:-0}" == "1" ]] && mbn_loop &

if [[ "${SUPERVISE:-0}" == "1" ]]; then
  while true; do
    asterisk -f -U asterisk
    log "Asterisk skončil — restart za 2 s"
    sleep 2
  done
else
  exec asterisk -f -U asterisk
fi
