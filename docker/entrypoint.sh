#!/usr/bin/env bash
# Phone21 — entrypoint kontejneru asterisk.
#
# Dva režimy:
#  - default: /etc/asterisk dodává bind-mount (vyrenderovaný configure.sh),
#    entrypoint jen spustí Asterisk;
#  - PHONE21_SELFCONFIG=1: konfigurace se renderuje při každém startu ze
#    šablon v image; tajemství se generují jednou a persistují ve volume.
#
# Volitelné interní služby (Umbrel nemá host systemd):
#   WATCHDOG_INTERNAL=1  hlídání modemu → restart procesu Asterisku
#   MBN_INTERNAL=1       držení MBN carrier profilu (VoLTE), potřeba
#                        /dev/cdc-wdm0 v devices
#   SUPERVISE=1          restart Asterisku po pádu/watchdogu (smyčka)
#   FIREWALL_INTERNAL=1  filtr provozu přicházejícího z privátní sítě
#                        (potřebuje NET_ADMIN a síť hostitele)
#
# SIP_DOMAIN: pevná hodnota z env, nebo prázdná → čeká se (max TS_WAIT s)
# na /var/lib/phone21/ts/ip od tailscale sidecaru (tailnet IP brány).

set -u
# Přechod ze starých názvů (drží se jedno vydání): staré proměnné i starý
# datový adresář se přeberou, když nové chybí.
: "${PHONE21_SELFCONFIG:=${GSM2SIP_SELFCONFIG:-0}}"
TPL=/opt/phone21/templates
DATA="${PHONE21_DATA:-${GSM2SIP_DATA:-/var/lib/phone21}}"
LEGACY_DATA=/var/lib/gsm2sip
SECRETS="$DATA/secrets.env"
TS_IP_FILE="$DATA/ts/ip"

AST_PIDFILE=/run/asterisk-main.pid

log() { echo "[entrypoint] $*"; }

# PID hlavního procesu ústředny (z PID souboru, jinak z tabulky procesů —
# `asterisk -rx` spouští stejnojmenného klienta, proto shoda na celý řádek)
ast_pid() {
  local p
  p="$(cat "$AST_PIDFILE" 2>/dev/null || true)"
  if [[ -n "$p" && -d "/proc/$p" ]]; then printf '%s' "$p"; return 0; fi
  pgrep -f 'asterisk -f -U asterisk' 2>/dev/null | head -1
}

# Ukončení ústředny: SIGTERM, a když se do 15 s neukončí, SIGKILL.
# Restart pak obstará smyčka SUPERVISE (nebo Docker).
ast_stop() {
  local pid waited=0
  pid="$(ast_pid)"
  [[ -n "$pid" ]] || { log "ústředna neběží — není co ukončovat"; return 0; }
  log "ukončuji ústřednu (PID $pid)"
  kill -TERM "$pid" 2>/dev/null || true
  while [[ -d "/proc/$pid" && $waited -lt 15 ]]; do sleep 1; waited=$((waited + 1)); done
  if [[ -d "/proc/$pid" ]]; then
    log "POZOR: ústředna se neukončila do 15 s — posílám SIGKILL"
    kill -KILL "$pid" 2>/dev/null || true
    waited=0
    while [[ -d "/proc/$pid" && $waited -lt 10 ]]; do sleep 1; waited=$((waited + 1)); done
  fi
  [[ -d "/proc/$pid" ]] && { log "POZOR: PID $pid stále žije"; return 1; }
  return 0
}

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
  # stav ovládání (token brány, tajemství 2FA) vlastní ovládání (nobody)
  # a jeho soubory jsou 0600 — chown výš ho nesmí sebrat, jinak po
  # restartu nejde přečíst token (QR bez klíče sítě) ani kód 2FA
  # (zamčené přihlášení)
  [[ -d "$DATA/webui" ]] && chown -R 65534:65534 "$DATA/webui" 2>/dev/null || true
  # webui (běží jako nobody) potřebuje SIP i AMI heslo — dáme mu přístup
  # přes skupinu, ne pro celý svět
  chgrp 65534 "$SECRETS" 2>/dev/null || true
  chmod 0640 "$SECRETS" 2>/dev/null || true
  log "konfigurace vyrenderována (SIP_DOMAIN=$domain)"
}

# Společná příprava dat — běží VŽDY (i v LXC režimu bez selfkonfigurace;
# dřív žila v render() a na nasazeních bez PHONE21_SELFCONFIG se nikdy
# neprovedla).
#
# Ovládání běží pod jiným uživatelem než ústředna: data musí umět přečíst
# a do ts/ a webui/ i zapsat. Zprávy a fronta nejsou čitelné pro ostatní.
# Data ze starého adresáře se přeberou jen tehdy, když nový ještě není
# naplněný (jinak by se přepsal živý stav).
legacy_data_migrate() {
  [[ "$DATA" != "$LEGACY_DATA" ]] || return 0
  [[ -d "$LEGACY_DATA" ]] || return 0
  [[ -z "$(ls -A "$DATA" 2>/dev/null)" ]] || return 0
  mkdir -p "$DATA" 2>/dev/null || return 0
  if cp -a "$LEGACY_DATA/." "$DATA/" 2>/dev/null; then
    log "data převzata ze starého adresáře $LEGACY_DATA"
  fi
}

# Klíče v databázi ústředny (rodina gsm2sip → phone21). Běží po startu,
# přepisovat se nic nesmí — bere se jen to, co v nové rodině chybí.
db_migrate() {
  sleep 45
  local line key val
  asterisk -rx "database show gsm2sip" 2>/dev/null | while read -r line; do
    case "$line" in
      /gsm2sip/*) ;;
      *) continue ;;
    esac
    key="${line%%:*}"; key="${key##/gsm2sip/}"; key="${key%"${key##*[![:space:]]}"}"
    val="${line#*: }"; val="${val#"${val%%[![:space:]]*}"}"
    [[ -n "$key" && -n "$val" ]] || continue
    asterisk -rx "database get phone21 $key" 2>/dev/null | grep -q "Value:" && continue
    asterisk -rx "database put phone21 $key $val" >/dev/null 2>&1 \
      && log "klíč $key převzat ze staré rodiny"
  done
}

common_setup() {
  # Čas v logu: ústředna čte /etc/localtime, proměnnou TZ ne.
  if [[ -n "${TZ:-}" && -e "/usr/share/zoneinfo/$TZ" ]]; then
    ln -sfn "/usr/share/zoneinfo/$TZ" /etc/localtime 2>/dev/null || true
    printf '%s\n' "$TZ" > /etc/timezone 2>/dev/null || true
  fi
  mkdir -p "$DATA/queue" "$DATA/ts" "$DATA/webui"
  # vlastníkem dat je ústředna
  chown asterisk "$DATA" "$DATA/queue" 2>/dev/null || true
  # setgid (2750/2770): soubory od ústředny dědí skupinu ovládání
  chgrp 65534 "$DATA" "$DATA/queue" 2>/dev/null || true
  chmod 2750 "$DATA" "$DATA/queue" 2>/dev/null || true
  chgrp 65534 "$DATA/ts" 2>/dev/null || true
  chmod 2770 "$DATA/ts" 2>/dev/null || true
  # stav ovládání (tajemství 2FA, token brány) — zapisuje ho jen webui
  chgrp 65534 "$DATA/webui" 2>/dev/null || true
  chmod 2770 "$DATA/webui" 2>/dev/null || true
  chgrp 65534 "$DATA/journal.jsonl" 2>/dev/null || true
  chmod 0640 "$DATA/journal.jsonl" 2>/dev/null || true
  find "$DATA/queue" -type f -exec chgrp 65534 {} + -exec chmod 0640 {} + 2>/dev/null || true
  # log ústředny
  chown -R asterisk /var/log/asterisk 2>/dev/null || \
    chmod 0777 /var/log/asterisk 2>/dev/null || true
  chmod 0644 /var/log/asterisk/messages.log 2>/dev/null || true
  # naplánované pokusy o doručení: adresář zakládá docker jako root, ale
  # zapisuje do něj ústředna — bez tohohle se retry nikdy nevytvoří
  mkdir -p /var/spool/asterisk/outgoing/.tmp
  chown -R asterisk /var/spool/asterisk/outgoing 2>/dev/null || true
  chmod 0750 /var/spool/asterisk/outgoing /var/spool/asterisk/outgoing/.tmp 2>/dev/null || true
  # historie hovorů: adresář musí existovat, jinak se nezapíše
  mkdir -p /var/log/asterisk/cdr-csv
  touch /var/log/asterisk/cdr-csv/Master.csv 2>/dev/null || true
  chown -R asterisk /var/log/asterisk/cdr-csv 2>/dev/null || true
  chgrp 65534 /var/log/asterisk/cdr-csv /var/log/asterisk/cdr-csv/Master.csv 2>/dev/null || true
  chmod 0750 /var/log/asterisk/cdr-csv 2>/dev/null || true
  chmod 0640 /var/log/asterisk/cdr-csv/Master.csv 2>/dev/null || true
}

watchdog_loop() {
  local fails=0 stuck=0 thr="${FAIL_THRESHOLD:-3}" interval="${WATCHDOG_INTERVAL:-30}"
  local out state
  sleep 120  # po startu má modem čas na inicializaci
  while true; do
    # ústředna zaseknutá ve vypínání: CLI odpovídá, ale nic nedělá —
    # graceful cesta už neexistuje, jediné gesto je zabít proces
    out="$(asterisk -rx 'core show uptime' 2>&1)"
    if [[ "$out" == *"during shutdown"* ]]; then
      stuck=$((stuck + 1))
      log "watchdog: ústředna visí ve vypínání ($stuck/2)"
      if [[ $stuck -ge 2 ]]; then
        ast_stop || true
        stuck=0; fails=0
        sleep 120
        continue
      fi
      sleep "$interval"
      continue
    fi
    stuck=0
    state="$(asterisk -rx 'quectel show device state quectel0' 2>/dev/null | awk '/State/{print $3}')"
    if [[ -z "$state" || "$state" == "Not" ]]; then
      fails=$((fails + 1))
      log "watchdog: modem nezdravý ($fails/$thr)"
      if [[ $fails -ge $thr ]]; then
        log "watchdog: restartuji ústřednu"
        ast_stop || true
        fails=0
        sleep 120
        continue
      fi
    else
      fails=0
    fi
    sleep "$interval"
  done
}

# Uvolnění datového rozhraní modemu přes systemd D-Bus (bez socketu se
# krok přeskočí).
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

# Probrání zaseknutého datového rozhraní modemu (v krajním případě reset).
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

# Stav hlasu po datové síti pro ostatní části aplikace.
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
        # mapu operátor→profil lze dodat souborem mbn.env v datovém
        # adresáři; soubor se jen čte, nikdy nespouští
        if [[ -f "$DATA/mbn.env" ]]; then
          mbn_v="$(sed -n 's/^MBN_PROFILE=//p' "$DATA/mbn.env" 2>/dev/null | tail -1)"
          mbn_v="${mbn_v%\"}"; mbn_v="${mbn_v#\"}"
          [[ -n "$mbn_v" ]] && MBN_PROFILE="$mbn_v"
          mbn_v="$(sed -n 's/^MBN_MAP=//p' "$DATA/mbn.env" 2>/dev/null | tail -1)"
          mbn_v="${mbn_v%\"}"; mbn_v="${mbn_v#\"}"
          [[ -n "$mbn_v" ]] && MBN_MAP="$mbn_v"
        fi
        MBN_PROFILE="${MBN_PROFILE:-auto}" MBN_MAP="${MBN_MAP:-}" \
          /opt/phone21/scripts/mbn-profile.sh auto || true
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

# Filtr provozu z privátní sítě. Nikdy nesmí zabránit startu ústředny —
# při selhání jen hlásí a jede se dál.
if [[ "${FIREWALL_INTERNAL:-0}" == "1" ]]; then
  /opt/phone21/scripts/tunnel-firewall.sh apply \
    || log "POZOR: filtr privátní sítě selhal — miniserver je z privátní sítě OTEVŘENÝ"
  /opt/phone21/scripts/tunnel-firewall.sh watch &
fi

legacy_data_migrate
if [[ "${PHONE21_SELFCONFIG:-0}" == "1" ]]; then
  render
fi
common_setup
db_migrate &
[[ "${WATCHDOG_INTERNAL:-0}" == "1" ]] && watchdog_loop &
[[ "${MBN_INTERNAL:-0}" == "1" ]] && mbn_loop &
# Ostrovní režim: hlídka běží vždy, ale zasáhne jen když je zapnutý
# přepínač ve web UI (AstDB phone21/island_mode); WWAN_FAILOVER je jen
# výchozí hodnota při první instalaci.
island_default() {
  sleep 40
  local want=off
  [[ "${WWAN_FAILOVER:-0}" == "1" ]] && want=on
  asterisk -rx "database get phone21 island_mode" 2>/dev/null | grep -q "Value:" || \
    asterisk -rx "database put phone21 island_mode $want" >/dev/null 2>&1
}
island_default &
/opt/phone21/scripts/wwan.sh watch &

# Adresa v domácí síti pro QR telefonu (kontejner běží v síti hostitele).
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

# Rotace rostoucích souborů: log ústředny, historie hovorů a žurnál zpráv.
rotate_loop() {
  local astlog=/var/log/asterisk
  local max_kb="${LOG_MAX_KB:-5120}" cdr_keep="${CDR_KEEP:-5000}" jr_keep="${JOURNAL_KEEP:-1000}"
  size_kb() { local s; s=$(stat -c %s "$1" 2>/dev/null || echo 0); echo $(( s / 1024 )); }
  trim() { # $1 = soubor, $2 = kolik posledních řádků ponechat
    tail -n "$2" "$1" > "$1.tmp" 2>/dev/null || { rm -f "$1.tmp"; return 0; }
    # vlastník a práva ještě PŘED výměnou souboru
    chown asterisk "$1.tmp" 2>/dev/null || true
    chgrp 65534 "$1.tmp" 2>/dev/null || true
    chmod 0640 "$1.tmp" 2>/dev/null || true
    mv "$1.tmp" "$1" 2>/dev/null || rm -f "$1.tmp"
  }
  while true; do
    sleep 3600
    if [[ $(size_kb "$astlog/messages.log") -ge $max_kb || $(size_kb "$astlog/debug.log") -ge $max_kb ]]; then
      asterisk -rx 'logger rotate' >/dev/null 2>&1 || true
      # drží se jen nejnovější generace (podle času)
      for b in messages.log debug.log; do
        ls -t "$astlog/$b".* 2>/dev/null | tail -n +2 | xargs -r rm -f
      done
      # log musí zůstat čitelný pro ovládání
      chmod 0644 "$astlog/messages.log" 2>/dev/null || true
    fi
    [[ $(size_kb "$astlog/cdr-csv/Master.csv") -ge 1024 ]] \
      && trim "$astlog/cdr-csv/Master.csv" "$cdr_keep"
    [[ $(size_kb "$DATA/journal.jsonl") -ge 1024 ]] \
      && trim "$DATA/journal.jsonl" "$jr_keep"
  done
}
rotate_loop &

if [[ "${SUPERVISE:-0}" == "1" ]]; then
  while true; do
    asterisk -f -U asterisk &
    AST_MAIN=$!
    printf '%s' "$AST_MAIN" > "$AST_PIDFILE"
    wait "$AST_MAIN" || true
    rm -f "$AST_PIDFILE"
    log "ústředna skončila — restart za 2 s"
    sleep 2
  done
else
  # exec nahradí tenhle shell, PID zůstává stejný
  printf '%s' "$$" > "$AST_PIDFILE"
  exec asterisk -f -U asterisk
fi
