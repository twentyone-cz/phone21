#!/usr/bin/env bash
# Test docker/modem-health.sh bez modemu a bez ústředny.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=docker/modem-health.sh
. "$ROOT/docker/modem-health.sh"
fail=0
check() { # $1 popis, $2 očekávané, $3 skutečné
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: čekáno '$2', je '$3'"; fail=1; fi
}

# skutečný výstup z Pi 2026-11-16 (zkrácený): v síti, plný signál, bez hlasu i SMS
NOCAPS='-------------- Status -------------
  Device                  : quectel0
  State                   : Free
  Audio                   : /dev/ttyUSB4
  Data                    : /dev/ttyUSB2
  Voice                   : No
  SMS                     : No
  GSM Registration Status : Registered, home network
  RSSI                    : 30, -53 dBm
  Current device state    : Start
  Desired device state    : Start
  Calls/Channels          : 0
    Active                : 0'
modem_state_parse <<< "$NOCAPS"
check "rozbor: State" "Free" "$MS_STATE"
check "rozbor: Voice" "No" "$MS_VOICE"
check "rozbor: SMS" "No" "$MS_SMS"
check "rozbor: registrace" "Registered, home network" "$MS_REG"
check "rozbor: Current device state nepřepíše State" "Free" "$MS_STATE"
check "verdikt: v síti bez hlasu/SMS = nocaps" "nocaps" "$(modem_verdict)"
modem_busy && b=busy || b=idle
check "bez hovoru není busy" "idle" "$b"

modem_state_parse <<< "${NOCAPS//Voice                   : No/Voice                   : Yes}"
check "jen bez SMS = nocaps" "nocaps" "$(modem_verdict)"
OK="${NOCAPS//: No/: Yes}"
modem_state_parse <<< "$OK"
check "hlas i SMS = ok" "ok" "$(modem_verdict)"
modem_state_parse <<< "${OK//Calls\/Channels          : 0/Calls/Channels          : 1}"
modem_busy && b=busy || b=idle
check "probíhající hovor = busy" "busy" "$b"
modem_state_parse <<< "${NOCAPS//Registered, home network/Not registered, searching}"
check "nepřihlášený do sítě = wait (o schopnostech nesoudit)" "wait" "$(modem_verdict)"
modem_state_parse <<< "${NOCAPS//State                   : Free/State                   : Not connected}"
check "Not connected = dead" "dead" "$(modem_verdict)"
modem_state_parse <<< ""
check "prázdný výstup (ústředna neodpovídá) = dead" "dead" "$(modem_verdict)"

# modem_wait_ready: port zmizí, vrátí se, a připraven je až po několika dotazech
T="$(mktemp -d)"; DEV="$T/ttyUSB2"; ln -s /dev/null "$DEV"
CALLS="$T/calls"; : > "$CALLS"
at_cmd() { # podstrčená: připraveno až od 3. dotazu na CPIN
  echo x >> "$CALLS"
  case "$2" in
    'AT+CPIN?') [[ $(grep -c x "$CALLS") -ge 3 ]] && printf '+CPIN: READY\nOK\n' || printf 'ERROR\n' ;;
    *) printf 'OK\n' ;;
  esac
}
( sleep 1; rm -f "$DEV"; sleep 2; ln -s /dev/null "$DEV" ) &
MODEM_READY_STEP=1
start=$SECONDS
modem_wait_ready "$DEV" 20 && r=ready || r=timeout
wait
check "po resetu: zmizí, vrátí se, počká na READY" "ready" "$r"
[[ $((SECONDS - start)) -ge 3 ]] && w=ano || w=ne
check "nečekal jen na starý port (čekal na zmizení)" "ano" "$w"

at_cmd() { printf 'ERROR\n'; }
rm -f "$DEV"; ln -s /dev/null "$DEV"; ( sleep 1; rm -f "$DEV"; sleep 1; ln -s /dev/null "$DEV" ) &
modem_wait_ready "$DEV" 6 && r=ready || r=timeout
wait
check "modem se nepřipraví = vyprší strop" "timeout" "$r"
rm -rf "$T"

exit $fail
