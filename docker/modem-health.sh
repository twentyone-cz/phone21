# shellcheck shell=bash
# Phone21 — zdraví modemu pro hlídku ústředny. Načítá ho entrypoint (source);
# test: scripts/test-modem-health.sh. Na port modemu se sahá jen přes at_cmd,
# kterou si test (nebo jiný volající) může podstrčit.
#
# Proč to existuje (výpadek 2026-11-15): hlídka zabila ústřednu a ve stejné
# vteřině resetovala modem. Ústředna naběhla dřív, než se modem po resetu
# vrátil, a ovladač se inicializoval proti modemu v půlce startu — zůstal bez
# zvukové cesty a bez SMS („Voice: No, SMS: No") přes den, i když modem byl
# v síti s plným signálem. Stav „žije" (State) to neodhalí.

# Výstup `quectel show device state` (stdin) → MS_STATE MS_VOICE MS_SMS MS_REG
# MS_CALLS. Klíč se porovnává celý: „Current device state" není „State".
modem_state_parse() {
  MS_STATE=""; MS_VOICE=""; MS_SMS=""; MS_REG=""; MS_CALLS=""
  local line k v
  while IFS= read -r line; do
    [[ "$line" == *:* ]] || continue
    k="${line%%:*}"; v="${line#*:}"
    k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    case "$k" in
      State) MS_STATE="$v" ;;
      Voice) MS_VOICE="$v" ;;
      SMS) MS_SMS="$v" ;;
      "GSM Registration Status") MS_REG="$v" ;;
      "Calls/Channels") MS_CALLS="$v" ;;
    esac
  done
}

# Verdikt nad rozebraným stavem:
#   dead   — ovladač modem nevidí (prázdný stav, „Not connected")
#   wait   — modem se teprve přihlašuje do sítě (o schopnostech nelze soudit)
#   nocaps — v síti, ale bez hlasu nebo SMS: inicializace se nepovedla
#   ok     — v síti, s hlasem i SMS
modem_verdict() {
  if [[ -z "$MS_STATE" || "$MS_STATE" == Not* ]]; then echo dead; return; fi
  if [[ "$MS_REG" != Registered* ]]; then echo wait; return; fi
  if [[ "$MS_VOICE" != Yes || "$MS_SMS" != Yes ]]; then echo nocaps; return; fi
  echo ok
}

# Probíhá hovor? (opravovat inicializaci uprostřed hovoru se nesmí)
modem_busy() { [[ -n "$MS_CALLS" && "$MS_CALLS" != 0 ]]; }

# Jeden AT příkaz přímo do portu modemu (jen když ústředna NEBĚŽÍ — jinak port
# drží ovladač). Vzor z at.sh: čtecí fd se otevře dřív, než příkaz odejde.
at_cmd() { # $1 = port, $2 = příkaz → odpověď na stdout
  local dev="$1" rc=0
  [[ -c "$dev" ]] || return 1
  timeout 3 stty -F "$dev" 115200 raw -echo clocal -crtscts 2>/dev/null || true
  exec 3<"$dev" || return 1
  printf '%s\r' "$2" > "$dev" 2>/dev/null || rc=1
  [[ $rc -eq 0 ]] && timeout 3 cat <&3 | tr -d '\r'
  exec 3<&-
  return $rc
}

# Po resetu počká, až modem z USB zmizí a vrátí se, a pak až je připravený na
# to, co ovladač při startu nastavuje: SIM, úložiště SMS a zvuková cesta.
# 0 = připraven, 1 = nestihl se do $2 sekund (ústředna se pak pustí i tak).
modem_wait_ready() { # $1 = port, $2 = strop v sekundách
  local dev="$1" max="${2:-180}" t=0 step="${MODEM_READY_STEP:-3}"
  # 1) zmizení z USB (do 30 s) — jinak bychom se ptali modemu před resetem
  while [[ $t -lt 30 && -c "$dev" ]]; do sleep 1; t=$((t + 1)); done
  # 2) návrat a připravenost
  while [[ $t -lt $max ]]; do
    if [[ -c "$dev" ]] \
       && at_cmd "$dev" 'AT+CPIN?' | grep -q 'READY' \
       && at_cmd "$dev" 'AT+CPMS?' | grep -q '^OK' \
       && at_cmd "$dev" 'AT+CPCMREG?' | grep -q '^OK'; then
      return 0
    fi
    sleep "$step"; t=$((t + step))
  done
  return 1
}
