#!/usr/bin/env bash
# Phone21 — host-setup.sh
#
# JEDINÝ host-level zásah celého projektu (spouštět na umbrelOS Pi, přes sudo).
# Idempotentní — bezpečné spustit opakovaně, nutné spustit po každém updatu
# umbrelOS (update může znovu povolit ModemManager).
#
# Dělá přesně tři věci:
#   1. zastaví a zakáže ModemManager (přebíral si modem — qmi-proxy, reenumerace)
#   2. ověří přítomnost obou by-id sériových portů (AT + PCM audio)
#   3. ověří, že modem odpovídá na ATI
#
# Nic neinstaluje (apt na umbrelOS nefunguje) — jen stty/printf/cat/grep.

set -u  # bez -e: jednotlivé kontroly hlásí a sčítají chyby, neumírají v půlce

AT_PORT="/dev/serial/by-id/usb-SimTech__Incorporated_SimTech__Incorporated_0123456789ABCDEF-if02-port0"
AUDIO_PORT="/dev/serial/by-id/usb-SimTech__Incorporated_SimTech__Incorporated_0123456789ABCDEF-if04-port0"

fail=0
ok()   { echo "  OK: $*"; }
err()  { echo "  CHYBA: $*" >&2; fail=1; }

if [[ ${EUID} -ne 0 ]]; then
  echo "Spusť přes sudo: sudo $0" >&2
  exit 2
fi

echo "[1/3] ModemManager"
if systemctl list-unit-files ModemManager.service >/dev/null 2>&1 \
   && systemctl list-unit-files | grep -q '^ModemManager.service'; then
  systemctl stop ModemManager.service 2>/dev/null || true
  systemctl disable ModemManager.service 2>/dev/null || true
  systemctl mask ModemManager.service 2>/dev/null || true
  if systemctl is-active --quiet ModemManager.service; then
    err "ModemManager stále běží"
  else
    ok "ModemManager zastaven, zakázán a maskován"
  fi
else
  ok "ModemManager.service na systému není — není co vypínat"
fi

echo "[2/3] Sériové porty (by-id)"
for p in "${AT_PORT}" "${AUDIO_PORT}"; do
  if [[ -e "${p}" ]]; then
    ok "${p} -> $(readlink -f "${p}")"
  else
    err "chybí ${p} (modem odpojen? jiná USB kompozice? zkontroluj lsusb: 1e0e:9001)"
  fi
done

echo "[3/3] Modem odpovídá na ATI"
if [[ -e "${AT_PORT}" ]]; then
  at_dev="$(readlink -f "${AT_PORT}")"
  # stty je best-effort: USB AT porty termios z velké části ignorují a přísná
  # zpětná verifikace GNU stty pak hlásí "unable to perform all requested
  # operations", i když port normálně funguje. Rozhoduje výhradně ATI odpověď.
  # (clocal: open nesmí čekat na carrier; timeout: kdyby port držel jiný proces)
  timeout 3 stty -F "${at_dev}" 115200 raw -echo clocal -crtscts 2>/dev/null \
    || echo "  POZN: stty nenastavilo všechny parametry — nevadí, rozhoduje ATI test"
  # čtení otevřít dřív, než se pošle příkaz, ať odpověď neuteče
  resp="$(
    timeout 5 bash -c '
      exec 3<"$1"
      printf "ATI\r" > "$1"
      timeout 3 cat <&3
    ' _ "${at_dev}" | tr -d '\r'
  )" || true
  if grep -qiE 'modem|výrobce|OK' <<<"${resp}"; then
    ok "ATI odpověď: $(grep -m1 -iE 'modem|Model|Revision' <<<"${resp}" || echo OK)"
  else
    err "modem na ATI neodpověděl (port drží jiný proces? kontejner? USB stav — zkus přepojit modem)"
  fi
else
  err "AT port chybí — přeskakuji test ATI"
fi

echo
if [[ ${fail} -eq 0 ]]; then
  echo "HOTOVO: host je připravený. Další krok: ./configure.sh && sudo docker compose up -d"
else
  echo "HOST NENÍ PŘIPRAVENÝ — viz chyby výše." >&2
fi
exit ${fail}
