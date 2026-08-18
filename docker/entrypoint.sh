#!/usr/bin/env bash
# GSM2SIP — entrypoint kontejneru asterisk.
#
# Dva režimy:
#  - default: /etc/asterisk dodává bind-mount (vyrenderovaný configure.sh),
#    entrypoint jen spustí Asterisk;
#  - GSM2SIP_SELFCONFIG=1: konfigurace se renderuje při každém startu ze
#    šablon v image; tajemství se generují jednou a persistují ve volume.
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
  # (čisté awk — python v image není; funguje i pro jedinou hodnotu)
  awk -v perms="$ami_permit" '
    /^permit = / { n = split(perms, a, ","); for (i = 1; i <= n; i++) print "permit = " a[i]; next }
    { print }' /etc/asterisk/manager.conf > /tmp/manager.conf.new \
    && mv /tmp/manager.conf.new /etc/asterisk/manager.conf
  mkdir -p "$DATA/queue" "$DATA/ts"
  chown -R asterisk "$DATA" /etc/asterisk 2>/dev/null || true
  # Web UI běží pod jiným uživatelem než Asterisk (na Umbrelu nobody):
  # data musí umět přečíst (fronta, žurnál) a do ts/ i zapsat (klíč sítě,
  # ten si ukládá s právy 600). Tajemství zůstávají jen pro Asterisk.
  # Obsah zpráv a fronta nesmí být čitelné pro „ostatní" — čte je jen
  # ústředna (vlastník) a ovládání (skupina nobody). Šifrování na disku
  # nedává smysl: klíč by ležel hned vedle; skutečná ochrana dat v klidu
  # je šifrovaný disk hostitele.
  chmod 0750 "$DATA" "$DATA/queue" 2>/dev/null || true
  chgrp 65534 "$DATA" "$DATA/queue" 2>/dev/null || true
  chmod 0770 "$DATA/ts" 2>/dev/null || true
  chgrp 65534 "$DATA/ts" 2>/dev/null || true
  chgrp 65534 "$DATA/journal.jsonl" 2>/dev/null || true
  chmod 0640 "$DATA/journal.jsonl" 2>/dev/null || true
  find "$DATA/queue" -type f -exec chgrp 65534 {} + -exec chmod 0640 {} + 2>/dev/null || true
  # log Asterisku (volume bývá založený rootem — bez tohohle se nezapisuje
  # a Diagnostika ve web UI zůstane prázdná)
  chown -R asterisk /var/log/asterisk 2>/dev/null || \
    chmod 0777 /var/log/asterisk 2>/dev/null || true
  chmod 0644 /var/log/asterisk/messages.log 2>/dev/null || true
  # webui (běží jako nobody) potřebuje SIP i AMI heslo — dáme mu přístup
  # přes skupinu, ne pro celý svět
  chgrp 65534 "$SECRETS" 2>/dev/null || true
  chmod 0640 "$SECRETS" 2>/dev/null || true
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

# Na hostiteli si QMI rozhraní modemu obvykle zabere ModemManager — pak
# selže správa carrier profilu i ostrovní režim. Zastavíme ho přes systemd
# D-Bus (socket musí být namountovaný); bez socketu se jen tiše přeskočí.
mm_release() {
  [[ -S /run/dbus/system_bus_socket ]] || return 0
  command -v dbus-send >/dev/null || return 0
  for unit in ModemManager.service; do
    dbus-send --system --print-reply --dest=org.freedesktop.systemd1 \
      /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager.StopUnit \
      string:"$unit" string:replace >/dev/null 2>&1 && log "zastaven $unit"
  done
}

qmi_ok() { timeout 15 qmicli -d /dev/cdc-wdm0 --dms-get-model >/dev/null 2>&1; }

# QMI umí po cizím klientovi zůstat zaseknuté (endpoint hangup) — pak pomůže
# jen reset modemu. Po resetu se USB znovu vyčísluje, chvíli to trvá.
qmi_recover() {
  qmi_ok && return 0
  mm_release
  sleep 5
  qmi_ok && return 0
  log "QMI neodpovídá — resetuji modem"
  asterisk -rx "quectel cmd quectel0 AT+CRESET" >/dev/null 2>&1 || return 1
  for _ in $(seq 1 20); do
    sleep 10
    qmi_ok && { log "QMI po resetu v pořádku"; return 0; }
  done
  log "POZOR: QMI se nepodařilo probrat"
  return 1
}

# Stav IMS (VoLTE) pro ostatní části appky: bez něj hovor shodí datové
# spojení (CSFB přepne modem do 2G), což je pro ostrovní režim zásadní.
volte_probe() {
  local out
  out="$(timeout 15 qmicli -d /dev/cdc-wdm0 --imsa-get-ims-registration-status 2>/dev/null)" || return 1
  case "$out" in
    *"Status: 'registered'"*) echo registered ;;
    *) echo not-registered ;;
  esac
}

mbn_loop() {
  sleep 30              # Asterisk musí být nahoře (reset jde přes CLI)
  mm_release
  qmi_recover || true
  local n=0
  while true; do
    if [[ -c /dev/cdc-wdm0 ]]; then
      # profil se řeší jednou za 10 minut, IMS stav každou minutu (levné)
      if [[ $((n % 10)) -eq 0 ]]; then
        MBN_PROFILE="${MBN_PROFILE:-auto}" /opt/gsm2sip/scripts/mbn-profile.sh auto || true
      fi
      v="$(volte_probe || echo unknown)"
      printf '%s\n' "$v" > "$DATA/volte.tmp" 2>/dev/null \
        && mv "$DATA/volte.tmp" "$DATA/volte" 2>/dev/null
      chmod 0644 "$DATA/volte" 2>/dev/null || true
    fi
    n=$((n + 1))
    sleep 60
  done
}

if [[ "${GSM2SIP_SELFCONFIG:-0}" == "1" ]]; then
  render
fi
[[ "${WATCHDOG_INTERNAL:-0}" == "1" ]] && watchdog_loop &
[[ "${MBN_INTERNAL:-0}" == "1" ]] && mbn_loop &
# Ostrovní režim: hlídka běží vždy, ale zasáhne jen když je zapnutý
# přepínač ve web UI (AstDB gsm2sip/island_mode); WWAN_FAILOVER je jen
# výchozí hodnota při první instalaci.
island_default() {
  sleep 40
  local want=off
  [[ "${WWAN_FAILOVER:-0}" == "1" ]] && want=on
  asterisk -rx "database get gsm2sip island_mode" 2>/dev/null | grep -q "Value:" || \
    asterisk -rx "database put gsm2sip island_mode $want" >/dev/null 2>&1
}
island_default &
/opt/gsm2sip/scripts/wwan.sh watch &

# Adresa v domácí síti pro QR telefonu. Zapisuje ji tenhle kontejner,
# protože běží v síti hostitele — webui je za mostem dockeru a viděl by
# jen jeho vnitřní adresu (10.21.x u umbrelu).
lan_ip_loop() {
  local iface addr
  while true; do
    iface=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
    if [[ -n "$iface" && "$iface" != "tailscale0" ]]; then
      addr=$(ip -4 -o addr show dev "$iface" 2>/dev/null \
             | awk '{split($4,a,"/"); print a[1]; exit}')
      if [[ -n "$addr" && "$addr" != 100.* && "$addr" != 127.* ]]; then
        printf '%s' "$addr" > "$DATA/lan_ip.tmp" && mv "$DATA/lan_ip.tmp" "$DATA/lan_ip"
      chgrp 65534 "$DATA/lan_ip" 2>/dev/null; chmod 0640 "$DATA/lan_ip" 2>/dev/null
      fi
    fi
    sleep 120
  done
}
lan_ip_loop &

if [[ "${SUPERVISE:-0}" == "1" ]]; then
  while true; do
    asterisk -f -U asterisk
    log "Asterisk skončil — restart za 2 s"
    sleep 2
  done
else
  exec asterisk -f -U asterisk
fi
