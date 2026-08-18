#!/usr/bin/env bash
#
# GSM2SIP — watchdog modemu.
#
# Driver se umí zaseknout tak, že přestane odpovídat i na holé AT a točí se
# v restartní smyčce (`Not connected` / `Stopping by start request`). Sám se
# z toho nedostane, spraví to až restart kontejneru. Tenhle skript to pozná
# a restart udělá za nás.
#
# Spouští se ze systemd timeru po ~30 s (scripts/install-watchdog.sh).
#
#   watchdog.sh            # jeden běh: zkontroluj a případně zasáhni
#   watchdog.sh --check    # jen ohlas stav, nikdy nerestartuj (pro ladění)
#
# Rozhodovací pravidla, a proč:
#  - Zásah až po FAIL_THRESHOLD po sobě jdoucích neúspěších. Po startu
#    kontejneru je zařízení chvíli `Not connected` legitimně; bez tohohle by
#    watchdog restartoval bránu donekonečna.
#  - Mezi restarty COOLDOWN. Když je modem fyzicky pryč (odpojený kabel),
#    žádný restart nepomůže a nemá cenu bránu mlátit každou půlminutu.
#  - Zastavený kontejner (exited) se NErestartuje. `docker stop` je vědomý
#    úkon (údržba, ladění) a watchdog do něj nemá co mluvit — ale ticho taky
#    ne: jednou za čas to zapíše do logu, ať je stav vidět ve web UI.
#  - Kontejner ve stavu `created` se nikdy nespustil (typicky chybějící
#    zařízení modemu při compose up) — restart policy dockeru na něj NESAHÁ,
#    takže bez zásahu by stál navěky. Watchdog ho zkusí nastartovat
#    (s cooldownem) a hlásí to jako ALARM.

set -uo pipefail

CONTAINER="${CONTAINER:-asterisk}"
DEVICE="${QUECTEL_DEVICE:-quectel0}"
STATE_DIR="${STATE_DIR:-/opt/Gsm2Sip/runtime/smsdata}"
LOG="${STATE_DIR}/watchdog.log"
FAILS_FILE=/run/gsm2sip-watchdog.fails
LAST_RESTART_FILE=/run/gsm2sip-watchdog.last-restart
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"
COOLDOWN="${COOLDOWN:-600}"
LOG_KEEP="${LOG_KEEP:-200}"

DRY=0
[[ "${1:-}" == "--check" ]] && DRY=1

log() {
  local msg="$1"
  local line
  line="$(date '+%Y-%m-%dT%H:%M:%S%:z') ${msg}"
  echo "${line}"                       # → journal (systemd)
  mkdir -p "${STATE_DIR}" 2>/dev/null
  echo "${line}" >> "${LOG}" 2>/dev/null
  # log držíme krátký — čte ho i web UI a nemá cenu, aby rostl bez omezení
  if [[ -f "${LOG}" ]] && (( $(wc -l < "${LOG}") > LOG_KEEP * 2 )); then
    tail -n "${LOG_KEEP}" "${LOG}" > "${LOG}.tmp" && mv "${LOG}.tmp" "${LOG}"
  fi
}

read_num() { local f="$1"; [[ -r "$f" ]] && cat "$f" 2>/dev/null || echo 0; }

fails=$(read_num "${FAILS_FILE}")

# --- Je vůbec co hlídat? -----------------------------------------------------
# Neběžící kontejner nesmí projít mlčky: `created` = nikdy nenastartoval
# (zkusíme docker start), `exited` = vědomé zastavení (jen hlásíme). Aby log
# nezaplavilo 2880 řádků denně, píše se změna stavu a pak připomínka po 30 min.
LASTSTATE_FILE=/run/gsm2sip-watchdog.laststate
note_state() { # $1 stav, $2 zpráva
  local last="" last_t=0 now
  now=$(date +%s)
  [[ -r "${LASTSTATE_FILE}" ]] && read -r last last_t < "${LASTSTATE_FILE}" 2>/dev/null
  if [[ "${last}" != "$1" ]] || (( now - ${last_t:-0} >= 1800 )); then
    log "$2"
    echo "$1 ${now}" > "${LASTSTATE_FILE}"
  fi
}

status=$(docker inspect -f '{{.State.Status}}' "${CONTAINER}" 2>/dev/null || echo missing)
if [[ "${status}" != "running" ]]; then
  echo 0 > "${FAILS_FILE}"
  case "${status}" in
    created)
      note_state created "ALARM: kontejner ${CONTAINER} se nikdy nespustil (stav created — nejspíš chybí zařízení modemu); zkouším docker start"
      if (( ! DRY )); then
        now=$(date +%s); last=$(read_num "${LAST_RESTART_FILE}")
        if (( last == 0 || now - last >= COOLDOWN )); then
          if docker start "${CONTAINER}" >/dev/null 2>&1; then
            echo "${now}" > "${LAST_RESTART_FILE}"
            log "ZÁSAH: docker start ${CONTAINER} proveden"
          else
            log "ZÁSAH SELHAL: docker start ${CONTAINER} skončil chybou (zkontroluj zařízení modemu a compose)"
          fi
        fi
      fi
      ;;
    exited)
      note_state exited "VAROVÁNÍ: kontejner ${CONTAINER} je zastavený (exited) — vědomé zastavení respektuji, telefonie neběží"
      ;;
    missing)
      note_state missing "VAROVÁNÍ: kontejner ${CONTAINER} neexistuje — brána není nasazená?"
      ;;
    *)
      note_state "${status}" "VAROVÁNÍ: kontejner ${CONTAINER} je ve stavu ${status}"
      ;;
  esac
  (( DRY )) && echo "stav kontejneru: ${status} — neběží"
  exit 0
fi
rm -f "${LASTSTATE_FILE}" 2>/dev/null

# --- Stav zařízení -----------------------------------------------------------
# `quectel show device state` je spolehlivější než `show devices`: stav je tam
# na vlastním řádku, takže se neplete víceslovné "Not connected" se sloupci.
state=$(timeout 15 docker exec "${CONTAINER}" \
          asterisk -rx "quectel show device state ${DEVICE}" 2>/dev/null \
        | sed -n 's/^ *State *: *//p' | head -1)

healthy=0
case "${state}" in
  "")                 reason="Asterisk neodpovídá na CLI" ;;
  "Not connected"*)   reason="zařízení hlásí: ${state}" ;;
  *)                  healthy=1 ;;
esac

if (( healthy )); then
  if (( fails > 0 )); then
    log "OK: ${DEVICE} je zpátky (${state}), počítadlo nulováno po ${fails} neúspěších"
  fi
  echo 0 > "${FAILS_FILE}"
  (( DRY )) && echo "stav: ${state} — zdravé"
  exit 0
fi

fails=$(( fails + 1 ))
echo "${fails}" > "${FAILS_FILE}"

if (( DRY )); then
  echo "stav: ${state:-<žádná odpověď>} — NEZDRAVÉ (${reason}); neúspěchů v řadě: ${fails}/${FAIL_THRESHOLD}"
  exit 1
fi

if (( fails < FAIL_THRESHOLD )); then
  log "VAROVÁNÍ: ${reason} (${fails}/${FAIL_THRESHOLD}) — zatím čekám"
  exit 0
fi

# --- Cooldown ----------------------------------------------------------------
now=$(date +%s)
last=$(read_num "${LAST_RESTART_FILE}")
if (( last > 0 && now - last < COOLDOWN )); then
  log "CHYBA: ${reason}, ale poslední restart byl před $(( now - last )) s (cooldown ${COOLDOWN} s) — nezasahuji. Zkontroluj modem fyzicky (kabel/napájení)."
  exit 0
fi

# --- Zásah -------------------------------------------------------------------
log "ZÁSAH: ${reason} po ${fails} kontrolách → restartuji kontejner ${CONTAINER}"
if docker restart "${CONTAINER}" >/dev/null 2>&1; then
  echo "${now}" > "${LAST_RESTART_FILE}"
  echo 0 > "${FAILS_FILE}"
  log "ZÁSAH: restart proveden. Pozor: restart maže SIP registrace z paměti, "\
"telefon se musí znovu přihlásit (příchozí SMS mezitím chytá retry fronta)."
else
  log "ZÁSAH SELHAL: docker restart ${CONTAINER} skončil chybou"
fi
