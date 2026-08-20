#!/usr/bin/env bash
# Phone21 — jednorázový AT příkaz na modem (spouštět přes sudo)
#
#   sudo ./at.sh 'AT+CPIN?'
#   sudo ./at.sh 'AT+CLCK="SC",0,"1234"'
#
# Stejný ověřený vzor jako v host-setup.sh: čtecí fd se otevře dřív, než se
# příkaz pošle, vše v jednom procesu — odpověď se neztratí. Nepoužívat, když
# běží kontejner asterisk (drží AT port): sudo docker compose down, nebo
# posílat příkazy přes: asterisk -rx 'quectel cmd quectel0 AT+...'

set -u
CMD="${1:?Použití: sudo ./at.sh 'AT+PRIKAZ'}"
DEV="${2:-/dev/serial/by-id/usb-SimTech__Incorporated_SimTech__Incorporated_0123456789ABCDEF-if02-port0}"

if [[ ${EUID} -ne 0 ]]; then
  echo "Spusť přes sudo: sudo $0 '${CMD}'" >&2
  exit 2
fi

dev="$(readlink -f "${DEV}")"
# stty best-effort — USB AT porty termios z velké části ignorují
timeout 3 stty -F "${dev}" 115200 raw -echo clocal -crtscts 2>/dev/null || true

exec 3<"${dev}"
printf '%s\r' "${CMD}" > "${dev}"
timeout 3 cat <&3 | tr -d '\r' | sed '/^$/d'
exit 0
