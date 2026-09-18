#!/usr/bin/env bash
#
# Phone21 — test smyčky služby privátní sítě (docker/ts-sidecar.sh).
#
# Běží bez dockeru: do PATH se podstrčí falešné nástroje, které vracejí
# připravené odpovědi, a smyčka se pustí v dočasném adresáři s daným počtem
# průchodů (P21_TICK=0, takže se nečeká).
#
# Pokryté scénáře (viz docs/ts-protokol.md):
#   1) převzetí klíče přejmenováním, tvar volání pro přihlášení
#   2) klíč s vypršelou platností
#   3) doložitelně odmítnutý klíč (žádost o nový) — tak, jak se chová skutečný
#      nástroj: důvod na chybovém výstupu, návratový kód 1, žádný JSON
#  3b) totéž, ale s důvodem v poli JSON (kdyby ho někdy nějaká verze vyplnila)
#  3c) klíč citovaný v chybové hlášce se nesmí dostat do stavu
#  3d) vypršelý klíč UZLU nesmí zahodit čerstvý klíč brány
#   4) výpadek sítě klíč nezahazuje
#   5) odhlášený uzel: žádost o klíč a mazání adresy až po šesti průchodech
#   6) pozastavená síť (připojeno, ale nikdo kolem): o klíč se NEŽÁDÁ
#   7) nečitelný i jinak tvarovaný výstup stavu → nic se nerozbije
#   8) uzel, který není veden jako brána → jedno odhlášení a žádost o klíč
#   9) nabídka výstupního uzlu podle volby přístupu
#  10) tvar a atomičnost zápisu stavu
#  11) statické kontroly skriptu
#  12) služba na pozadí se spouští a po skončení se uklidí
#
# Klíč se nikdy nesmí objevit v argumentech ani ve stavu — hlídá se globálně
# na konci.
#
# Použití: bash scripts/test-ts-sidecar.sh
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/docker/ts-sidecar.sh"
SECRET="tskey-auth-TEST0NEVER1LEAK2-abcdefghijklmnop"

PASS_N=0
FAIL_N=0
CASE_N=0
CASE=""
WORK=""
TS=""
CTL=""
BIN=""

cleanup() {
  [ -n "$WORK" ] && [ -d "$WORK" ] && rm -rf "$WORK"
}
trap cleanup EXIT

ok()  { PASS_N=$((PASS_N + 1)); printf '    ok   %s\n' "$1"; }
bad() { FAIL_N=$((FAIL_N + 1)); printf '    FAIL %s\n' "$1"; }

# --- drobné kontroly --------------------------------------------------------

want_line() {   # soubor, řetězec, popis
  if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else
    bad "$3 (v $(basename "$1") chybí: $2)"
  fi
}

want_no_line() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then
    bad "$3 (v $(basename "$1") je navíc: $2)"
  else ok "$3"; fi
}

want_exists() {
  if [ -e "$1" ]; then ok "$2"; else bad "$2 (chybí $1)"; fi
}

want_absent() {
  if [ -e "$1" ]; then bad "$2 (je tu $1)"; else ok "$2"; fi
}

want_count() { # soubor, vzor, kolik, popis
  n=$(grep -cF -- "$2" "$1" 2>/dev/null || true)
  if [ "${n:-0}" = "$3" ]; then ok "$4"; else bad "$4 (nalezeno ${n:-0}, čekáno $3)"; fi
}

# --- příprava ---------------------------------------------------------------

setup_bin() {
  BIN="$WORK/bin"
  mkdir -p "$BIN"

  cat > "$BIN/tailscale" <<'STUB'
#!/bin/sh
# Falešný nástroj sítě pro test: všechny argumenty zapíše a odpoví podle
# připravených souborů v P21_TEST_CTL.
C="$P21_TEST_CTL"
printf '%s\n' "$*" >> "$C/args.log"
cmd="${1:-}"
case "$cmd" in
  status)
    [ -f "$C/status.json" ] && cat "$C/status.json"
    exit 0
    ;;
  ip)
    [ -f "$C/ip" ] && cat "$C/ip"
    exit 0
    ;;
  up)
    mode="$(cat "$C/upmode" 2>/dev/null || echo ok)"
    case "$mode" in
      ok)
        [ -f "$C/after_up.json" ] && cp "$C/after_up.json" "$C/status.json"
        printf '{\n  "BackendState": "Running"\n}\n'
        exit 0
        ;;
      reject_real)
        # Jak se chová skutečný nástroj: chyba jde na chybový výstup jako
        # obyčejný text, návratový kód je 1 a žádný JSON se netiskne.
        printf 'backend error: invalid key: authkey expired\n' >&2
        exit 1
        ;;
      reject_leak)
        # Chybová hláška, ve které nástroj cituje samotný klíč.
        printf 'backend error: invalid key: %s rejected by control\n' \
          "${P21_TEST_SECRET:-tskey-neznamy}" >&2
        exit 1
        ;;
      flagerr)
        # Jiná verze nástroje: neznámý přepínač a k tomu nápověda, ve které
        # se o klíči taky píše.
        printf 'flag provided but not defined: -advertise-exit-node\n' >&2
        printf 'Usage: tailscale up [flags]\n' >&2
        printf '  --authkey string  starší tvar pro --auth-key\n' >&2
        exit 2
        ;;
      nodekey_expired)
        # Vypršel klíč UZLU, ne klíč k přihlášení: tímtéž klíčem se má
        # přihlásit znovu, zahodit ho nesmí.
        printf 'backend error: node key has expired\n' >&2
        exit 1
        ;;
      reject)
        printf '{\n  "BackendState": "NeedsLogin",\n  "Error": "invalid key: unauthorized"\n}\n'
        exit 1
        ;;
      neterr)
        printf 'backend error: dial tcp: lookup koordinator: no such host\n' >&2
        exit 1
        ;;
      *)
        printf 'tohle vubec neni json\n'
        exit 1
        ;;
    esac
    ;;
  set)
    exit 0
    ;;
  logout)
    : > "$C/logout.done"
    [ -f "$C/after_logout.json" ] && cp "$C/after_logout.json" "$C/status.json"
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
STUB

  cat > "$BIN/tailscaled" <<'STUB'
#!/bin/sh
# Falešná služba na pozadí: jen se drží naživu, aby šlo ověřit hlídání procesu.
printf '%s\n' "$$" > "$P21_TEST_CTL/tsd.pid"
exec sleep 20
STUB

  chmod +x "$BIN/tailscale" "$BIN/tailscaled"
}

new_case() {
  CASE_N=$((CASE_N + 1))
  CASE="$1"
  TS="$WORK/c$CASE_N/ts"
  CTL="$WORK/c$CASE_N/ctl"
  mkdir -p "$TS" "$CTL"
  : > "$CTL/args.log"
  printf 'ok\n' > "$CTL/upmode"
  printf '\n== %s\n' "$CASE"
}

run_loop() { # počet průchodů [P21_NO_DAEMON]
  PATH="$BIN:$PATH" \
  P21_TS_DIR="$TS" \
  P21_TICK=0 \
  P21_MAX_PASSES="$1" \
  P21_NO_DAEMON="${2:-1}" \
  P21_TEST_CTL="$CTL" \
  P21_TEST_SECRET="$SECRET" \
  COCKSCALE_URL="https://zaloha.example" \
    sh "$SCRIPT" > "$CTL/out.log" 2>&1
}

put_key() { # klíč se zakládá tak, jak ho píše ovládání: metadata, pak klíč
  printf 'origin=gateway\nlogin_server=https://lab.example\nexpires_epoch=%s\nissued_epoch=%s\ntag=tag:c-ab12\n' \
    "$1" "$(date +%s)" > "$TS/key_meta"
  printf '%s\n' "$SECRET" > "$TS/authkey"
  chmod 600 "$TS/authkey"
}

# Stav: připojeno, jeden protějšek, uzel je veden jako brána.
json_running() {
  cat > "$1" <<'JSON'
{
  "Version": "1.86.2-t0000000",
  "TUN": true,
  "BackendState": "Running",
  "HaveNodeKey": true,
  "AuthURL": "",
  "TailscaleIPs": [
    "100.64.0.4",
    "fd7a:115c:a1e0::4"
  ],
  "Self": {
    "ID": "1",
    "PublicKey": "nodekey:aaaa1111",
    "HostName": "brana",
    "DNSName": "brana.example.",
    "OS": "linux",
    "UserID": 0,
    "TailscaleIPs": [
      "100.64.0.4"
    ],
    "Tags": [
      "tag:c-ab12"
    ],
    "Online": true,
    "ExitNodeOption": true
  },
  "Health": [],
  "MagicDNSSuffix": "example",
  "CurrentTailnet": null,
  "CertDomains": null,
  "Peer": {
    "nodekey:bbbb2222": {
      "ID": "2",
      "PublicKey": "nodekey:bbbb2222",
      "HostName": "telefon",
      "TailscaleIPs": [
        "100.64.0.9"
      ],
      "Tags": [
        "tag:c-ab12"
      ],
      "Online": true
    }
  },
  "User": {},
  "ClientVersion": null
}
JSON
}

# Stav: připojeno, prázdná netmapa (pozastavená síť).
json_running_empty() {
  cat > "$1" <<'JSON'
{
  "Version": "1.86.2-t0000000",
  "BackendState": "Running",
  "HaveNodeKey": true,
  "AuthURL": "",
  "TailscaleIPs": [
    "100.64.0.4"
  ],
  "Self": {
    "ID": "1",
    "PublicKey": "nodekey:aaaa1111",
    "HostName": "brana",
    "TailscaleIPs": [
      "100.64.0.4"
    ],
    "Tags": [
      "tag:c-ab12"
    ],
    "Online": true
  },
  "Health": [],
  "Peer": {},
  "User": {},
  "ClientVersion": null
}
JSON
}

# Stav: připojeno, ale uzel není veden jako brána (stará instalace).
json_running_untagged() {
  cat > "$1" <<'JSON'
{
  "Version": "1.86.2-t0000000",
  "BackendState": "Running",
  "HaveNodeKey": true,
  "TailscaleIPs": [
    "100.64.0.4"
  ],
  "Self": {
    "ID": "1",
    "PublicKey": "nodekey:aaaa1111",
    "HostName": "brana",
    "TailscaleIPs": [
      "100.64.0.4"
    ],
    "Online": true
  },
  "Health": [],
  "Peer": {
    "nodekey:bbbb2222": {
      "ID": "2",
      "PublicKey": "nodekey:bbbb2222",
      "HostName": "telefon",
      "Tags": [
        "tag:c-ab12"
      ],
      "Online": true
    }
  },
  "User": {},
  "ClientVersion": null
}
JSON
}

json_needs_login() {
  cat > "$1" <<'JSON'
{
  "Version": "1.86.2-t0000000",
  "BackendState": "NeedsLogin",
  "HaveNodeKey": false,
  "AuthURL": "",
  "TailscaleIPs": null,
  "Self": {
    "ID": "1",
    "PublicKey": "nodekey:aaaa1111",
    "HostName": "brana",
    "TailscaleIPs": null,
    "Online": false
  },
  "Health": [],
  "Peer": null,
  "User": {},
  "ClientVersion": null
}
JSON
}

WORK="$(mktemp -d)"
setup_bin

echo "== test smyčky služby privátní sítě =="
echo "   skript: $SCRIPT"

# --- 1) převzetí klíče a tvar volání pro přihlášení -------------------------

new_case "převzetí klíče a tvar přihlášení"
json_needs_login "$CTL/status.json"
json_running "$CTL/after_up.json"
printf '100.64.0.4\n' > "$CTL/ip"
printf 'router\n' > "$TS/tunnel_access"
put_key "$(( $(date +%s) + 3600 ))"
run_loop 1

want_absent "$TS/authkey" "klíč se z ts/authkey převzal"
want_absent "$TS/authkey.inuse" "spotřebovaný klíč se uklidil"
want_line "$CTL/args.log" "up --reset" "volání obsahuje --reset"
want_line "$CTL/args.log" "--login-server=https://lab.example" "adresa koordinátoru je z metadat klíče"
want_line "$CTL/args.log" "--auth-key=file:$TS/authkey.inuse" "klíč se předává souborem"
want_line "$CTL/args.log" "--advertise-exit-node=true" "nabídka výstupního uzlu je ve stejném volání"
want_line "$CTL/args.log" "--timeout=90s" "volání má omezený čas"
want_line "$CTL/args.log" "--accept-dns=false" "překlad jmen se nepřebírá"
want_line "$CTL/args.log" "--json" "výsledek se čte strojově"
want_no_line "$CTL/args.log" "--advertise-tags" "zařazení uzlu se neposílá"
want_no_line "$CTL/args.log" "--authkey=" "starý tvar s klíčem v argumentu zmizel"
want_no_line "$CTL/args.log" "--hostname" "jméno uzlu se neposílá"
want_no_line "$CTL/args.log" "$SECRET" "klíč není v argumentech"
want_line "$TS/state" "key=accepted" "stav: klíč přijat"
want_line "$TS/state" "backend=Running" "stav: připojeno"
want_line "$TS/state" "peers=1" "stav: jeden protějšek"
want_no_line "$TS/state" "peers=0" "hned po přihlášení se stav netváří jako pozastavená síť"
want_line "$TS/state" "tags=tag:c-ab12" "stav: uzel je veden jako brána"
want_line "$TS/state" "login_server=https://lab.example" "stav: použitá adresa koordinátoru"
want_line "$TS/state" "ip=100.64.0.4" "stav: adresa v privátní síti"
want_line "$TS/ip" "100.64.0.4" "adresa zapsaná pro ústřednu"
want_absent "$TS/want_key" "po přihlášení se o klíč nežádá"
STATE_CASE1="$TS/state"
TS_CASE1="$TS"

# --- 2) klíč s vypršelou platností ------------------------------------------

new_case "klíč s vypršelou platností"
json_needs_login "$CTL/status.json"
put_key "$(( $(date +%s) - 60 ))"
run_loop 1

want_absent "$TS/authkey.inuse" "zastaralý klíč se zahodil"
want_no_line "$CTL/args.log" "up --reset" "se zastaralým klíčem se přihlášení nezkouší"
want_line "$TS/state" "key=expired" "stav: klíč vypršel"
want_line "$TS/want_key" "reason=key_expired" "žádost o nový klíč s důvodem"

# --- 3) doložitelně odmítnutý klíč (chování skutečného nástroje) ------------

# Skutečný nástroj pole "Error" nevyplňuje: důvod jde na chybový výstup jako
# obyčejný text. Kdyby se četlo jen pole z JSONu, byla by celá tahle větev
# mrtvá a odmítnutý klíč by se zkoušel dokola až do vypršení.
new_case "odmítnutý klíč — důvod na chybovém výstupu, žádný JSON"
json_needs_login "$CTL/status.json"
printf 'reject_real\n' > "$CTL/upmode"
put_key "$(( $(date +%s) + 3600 ))"
run_loop 1

want_absent "$TS/authkey.inuse" "odmítnutý klíč se zahodil"
want_line "$TS/state" "key=rejected" "stav: klíč odmítnut"
want_line "$TS/state" "last_error=backend error: invalid key: authkey expired" \
  "stav nese důvod z chybového výstupu"
want_no_line "$TS/state" "last_error=up_failed" "důvod nenahradil holý návratový kód"
want_line "$TS/want_key" "reason=needs_login" "po odmítnutí se žádá nový klíč"
want_no_line "$TS/state" "$SECRET" "klíč není ve stavu"

# --- 3b) odmítnutí v poli JSON (kdyby ho někdy nějaká verze vyplnila) -------

new_case "odmítnutý klíč — důvod v poli JSON"
json_needs_login "$CTL/status.json"
printf 'reject\n' > "$CTL/upmode"
put_key "$(( $(date +%s) + 3600 ))"
run_loop 1

want_absent "$TS/authkey.inuse" "odmítnutý klíč se zahodil"
want_line "$TS/state" "key=rejected" "stav: klíč odmítnut"
want_line "$TS/state" "last_error=invalid key: unauthorized" "stav nese důvod odmítnutí"
want_line "$TS/want_key" "reason=needs_login" "po odmítnutí se žádá nový klíč"
want_no_line "$TS/state" "$SECRET" "klíč není ve stavu"

# --- 3c) klíč citovaný v chybové hlášce se nesmí dostat do stavu ------------

new_case "klíč z chybové hlášky se do stavu nedostane"
json_needs_login "$CTL/status.json"
printf 'reject_leak\n' > "$CTL/upmode"
put_key "$(( $(date +%s) + 3600 ))"
run_loop 1

want_line "$TS/state" "key=rejected" "stav: klíč odmítnut"
want_no_line "$TS/state" "$SECRET" "klíč z hlášky je ve stavu zahozený"
want_line "$TS/state" "last_error=backend error: invalid key: *** rejected by control" \
  "z hlášky zbyla jen čitelná část"

# --- 3d) vypršelý klíč uzlu není odmítnutý klíč brány -----------------------

new_case "vypršelý klíč uzlu nezahazuje klíč brány"
json_needs_login "$CTL/status.json"
printf 'nodekey_expired\n' > "$CTL/upmode"
put_key "$(( $(date +%s) + 3600 ))"
run_loop 2

want_exists "$TS/authkey.inuse" "klíč brány zůstal k dalšímu pokusu"
want_line "$TS/state" "key=inuse" "stav: klíč se pořád zkouší"
want_no_line "$TS/state" "key=rejected" "vypršení klíče uzlu se nebere jako odmítnutí"
want_absent "$TS/want_key" "o další klíč se nežádá"

# --- 3e) neznámý přepínač není odmítnutý klíč -------------------------------

new_case "neznámý přepínač nezahazuje klíč"
json_needs_login "$CTL/status.json"
printf 'flagerr\n' > "$CTL/upmode"
put_key "$(( $(date +%s) + 3600 ))"
run_loop 2

want_exists "$TS/authkey.inuse" "klíč zůstal, nápověda není odmítnutí"
want_line "$TS/state" "key=inuse" "stav: klíč se pořád zkouší"
want_absent "$TS/want_key" "o další klíč se nežádá"
want_line "$TS/state" "last_error=flag provided but not defined: -advertise-exit-node" \
  "stav nese skutečný důvod, ne holý návratový kód"

# --- 4) výpadek sítě klíč nezahazuje ----------------------------------------

new_case "výpadek sítě klíč nezahazuje"
json_needs_login "$CTL/status.json"
printf 'neterr\n' > "$CTL/upmode"
put_key "$(( $(date +%s) + 3600 ))"
run_loop 3

want_exists "$TS/authkey.inuse" "klíč zůstal k dalšímu pokusu"
want_count "$CTL/args.log" "up --reset" 3 "přihlášení se zkusilo každý průchod"
want_line "$TS/state" "key=inuse" "stav: klíč se pořád zkouší"
want_absent "$TS/want_key" "o další klíč se nežádá, dokud tenhle platí"

# --- 4b) klíč pro jiného koordinátora se nespálí -----------------------------

new_case "klíč pro jinou adresu koordinátoru se nezkouší"
json_running "$CTL/status.json"
printf '100.64.0.4\n' > "$CTL/ip"
printf 'backend=Running\npeers=1\ntags=tag:c-ab12\nip=100.64.0.4\nlogin_server=https://stara.example\nkey=accepted\nlast_error=\nupdated=%s\n' \
  "$(date +%s)" > "$TS/state"
put_key "$(( $(date +%s) + 3600 ))"
run_loop 2

want_no_line "$CTL/args.log" "up --reset" "přihlášení na jinou adresu se nespustilo"
want_exists "$TS/authkey.inuse" "klíč se nespálil, čeká"
want_line "$TS/state" "last_error=login_server_mismatch" "stav vysvětluje, proč se čeká"

# --- 5) odhlášený uzel: žádost o klíč a mazání adresy -----------------------

new_case "odhlášený uzel — pět průchodů adresu nemaže"
json_needs_login "$CTL/status.json"
printf '100.64.0.4\n' > "$TS/ip"
run_loop 5

want_line "$TS/want_key" "reason=needs_login" "žádost o klíč vznikla"
want_line "$TS/want_key" "since=" "žádost nese i čas vzniku"
want_count "$TS/want_key" "reason=" 1 "žádost se opakovaným průchodem nepřepsala"
want_exists "$TS/ip" "adresa po pěti průchodech ještě zůstává"
want_line "$TS/state" "backend=NeedsLogin" "stav: odhlášeno"

new_case "odhlášený uzel — šestý průchod adresu smaže"
json_needs_login "$CTL/status.json"
printf '100.64.0.4\n' > "$TS/ip"
run_loop 6

want_absent "$TS/ip" "adresa se po šesti průchodech smazala"
want_line "$TS/state" "ip=" "stav už adresu neuvádí"

# --- 6) pozastavená síť ------------------------------------------------------

new_case "pozastavená síť (připojeno, nikdo kolem)"
json_running_empty "$CTL/status.json"
printf '100.64.0.4\n' > "$CTL/ip"
printf '100.64.0.4\n' > "$TS/ip"
run_loop 8

want_absent "$TS/want_key" "o klíč se NEŽÁDÁ"
want_exists "$TS/ip" "adresa zůstává"
want_line "$TS/state" "backend=Running" "stav: pořád připojeno"
want_line "$TS/state" "peers=0" "stav: prázdná síť kolem"
want_no_line "$CTL/args.log" "up --reset" "nic se nepřihlašuje znovu"
want_no_line "$CTL/args.log" "logout" "nic se neodhlašuje"

# --- 7) nečitelný výstup stavu ----------------------------------------------

new_case "nečitelný výstup stavu"
printf 'tohle vubec neni json\n' > "$CTL/status.json"
printf '100.64.0.4\n' > "$TS/ip"
run_loop 8

want_line "$TS/state" "backend=unknown" "stav: nevíme"
want_line "$TS/state" "peers=-1" "počet protějšků: nevíme (ne nula)"
want_no_line "$TS/state" "backend=NeedsLogin" "nečitelný výstup NENÍ odhlášení"
want_absent "$TS/want_key" "o klíč se při nečitelném výstupu nežádá"
want_exists "$TS/ip" "adresa se při nečitelném výstupu nemaže"

# --- 7b) jiný tvar výstupu (vše na jednom řádku) ----------------------------

new_case "jiný tvar výstupu stavu"
printf '{"BackendState":"Running","Self":{"PublicKey":"nodekey:aaaa1111","Online":true},"Peer":{"nodekey:bbbb2222":{"Online":true}}}\n' \
  > "$CTL/status.json"
printf '100.64.0.4\n' > "$TS/ip"
run_loop 8

want_line "$TS/state" "backend=Running" "stav backendu se přečte i z jiného tvaru"
want_line "$TS/state" "peers=-1" "počet protějšků radši nevíme, než abychom hlásili nulu"
want_no_line "$CTL/args.log" "logout" "nepřečtené zařazení uzlu NEVEDE k odhlášení"
want_absent "$TS/want_key" "o klíč se nežádá"
want_exists "$TS/ip" "adresa se nemaže"

# --- 8) uzel, který není veden jako brána -----------------------------------

new_case "uzel není veden jako brána"
json_running_untagged "$CTL/status.json"
json_needs_login "$CTL/after_logout.json"
run_loop 3

want_exists "$CTL/logout.done" "uzel se odhlásil"
want_count "$CTL/args.log" "logout" 1 "odhlášení proběhlo právě jednou"
want_line "$TS/want_key" "reason=untagged" "žádost o klíč s důvodem přeregistrování"

# Stav zapsaný v TÉMŽE průchodu už nesmí být z doby před odhlášením: dvojice
# připojeno + nula protějšků je pro ovládání pozastavená síť (chybí kredit).
new_case "uzel není veden jako brána — stav v témže průchodu nelže"
json_running_untagged "$CTL/status.json"
json_needs_login "$CTL/after_logout.json"
run_loop 1

want_exists "$CTL/logout.done" "uzel se odhlásil hned v prvním průchodu"
want_no_line "$TS/state" "backend=Running" "stav po odhlášení nehlásí připojeno"
want_line "$TS/state" "backend=NeedsLogin" "stav po odhlášení hlásí odhlášeno"
want_no_line "$TS/state" "peers=0" "počet protějšků se nehlásí jako prázdná síť"
want_line "$TS/state" "peers=-1" "počet protějšků: nevíme"
want_no_line "$TS/state" "tags=tag:" "zařazení uzlu se po odhlášení nedrží"
want_line "$TS/want_key" "reason=untagged" "žádost o klíč vznikla"
want_no_line "$CTL/args.log" "set --advertise-exit-node" "na odhlášeném uzlu se nic nenastavuje"

# --- 9) nabídka výstupního uzlu ---------------------------------------------

new_case "nabídka výstupního uzlu podle volby přístupu"
json_running "$CTL/status.json"
printf '100.64.0.4\n' > "$CTL/ip"
printf 'router\n' > "$TS/tunnel_access"
run_loop 3

want_count "$CTL/args.log" "set --advertise-exit-node=true" 1 "nabídka se zapnula jednou, ne každý průchod"

new_case "nejnižší stupeň přístupu nabídku vypíná"
json_running "$CTL/status.json"
printf '100.64.0.4\n' > "$CTL/ip"
printf 'phone\n' > "$TS/tunnel_access"
run_loop 3

want_count "$CTL/args.log" "set --advertise-exit-node=false" 1 "nabídka se vypnula jednou"

# --- 10) tvar a atomičnost zápisu stavu -------------------------------------

new_case "tvar a atomičnost zápisu stavu"
for k in backend peers tags ip login_server key last_error updated; do
  want_line "$STATE_CASE1" "$k=" "stav má řádek $k"
done
if [ -z "$(find "$TS_CASE1" -name '.*.tmp' -print -quit 2>/dev/null)" ]; then
  ok "po zápisu nezůstal dočasný soubor"
else
  bad "po zápisu nezůstal dočasný soubor"
fi
if [ "$(sed -n 's/^updated=//p' "$STATE_CASE1")" -gt 0 ] 2>/dev/null; then
  ok "čas poslední změny je číslo"
else
  bad "čas poslední změny je číslo"
fi

# --- 11) statické kontroly --------------------------------------------------

new_case "statické kontroly skriptu"
if sh -n "$SCRIPT"; then ok "skript projde kontrolou syntaxe"; else bad "skript projde kontrolou syntaxe"; fi
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -s sh "$SCRIPT" >/dev/null 2>&1; then ok "shellcheck bez výhrad"; else bad "shellcheck bez výhrad"; fi
fi
UPLINE="$(grep -n 'up --reset' "$SCRIPT" | head -1)"
for f in -- --reset --login-server= --auth-key=file: --accept-dns=false --advertise-exit-node= --timeout=90s --json; do
  [ "$f" = "--" ] && continue
  if printf '%s' "$UPLINE" | grep -qF -- "$f"; then
    ok "přihlášení má $f v jednom volání"
  else
    bad "přihlášení má $f v jednom volání"
  fi
done
if grep -qF -- '--advertise-tags' "$SCRIPT"; then bad "skript neposílá zařazení uzlu"; else ok "skript neposílá zařazení uzlu"; fi
if grep -q -- '--authkey=' "$SCRIPT"; then bad "skript nemá klíč v argumentu"; else ok "skript nemá klíč v argumentu"; fi
if grep -qE '\b(jq|curl|python3?|awk|perl)\b' "$SCRIPT"; then bad "skript používá jen nástroje z obrazu"; else ok "skript používá jen nástroje z obrazu"; fi
if grep -qF 'mv -f "$TS/authkey" "$TS/authkey.inuse"' "$SCRIPT"; then ok "klíč se přebírá přejmenováním"; else bad "klíč se přebírá přejmenováním"; fi
if grep -qF 'set -C; printf' "$SCRIPT"; then
  ok "žádost o klíč vzniká nedělitelně i s obsahem"
else
  bad "žádost o klíč vzniká nedělitelně i s obsahem"
fi
if grep -qF 'set -C; : >' "$SCRIPT"; then
  bad "žádost o klíč nevzniká nejdřív prázdná"
else
  ok "žádost o klíč nevzniká nejdřív prázdná"
fi
# Důvod selhání se nesmí hledat jen v poli JSON: skutečný nástroj ho tam
# nedává (viz scénář 3).
if grep -qF 'hk_low=$(printf '"'"'%s\n'"'"' "$hk_out"' "$SCRIPT"; then
  ok "důvod selhání se čte z celého výstupu"
else
  bad "důvod selhání se čte z celého výstupu"
fi
if grep -qF 'tskey-[^ ]*' "$SCRIPT"; then
  ok "z hlášky pro ovládání se zahazuje cokoli ve tvaru klíče"
else
  bad "z hlášky pro ovládání se zahazuje cokoli ve tvaru klíče"
fi
# Stav musí jít na disk i před dlouhými operacemi (přihlášení až 90 s,
# čekání na službu na pozadí až 60 s), jinak ho ovládání označí za zastaralý.
if [ "$(grep -c '^  write_state$' "$SCRIPT")" -ge 3 ]; then
  ok "stav se zapisuje i před dlouhými operacemi"
else
  bad "stav se zapisuje i před dlouhými operacemi"
fi
if grep -qF 'mv -f "$TS/.state.tmp" "$TS/state"' "$SCRIPT"; then ok "stav se zapisuje přes dočasný soubor"; else bad "stav se zapisuje přes dočasný soubor"; fi

# --- 12) služba na pozadí ---------------------------------------------------

new_case "služba na pozadí se spustí a po skončení se uklidí"
json_running "$CTL/status.json"
printf '100.64.0.4\n' > "$CTL/ip"
run_loop 1 0
sleep 1
TSD_PID="$(cat "$CTL/tsd.pid" 2>/dev/null || true)"
if [ -n "$TSD_PID" ]; then
  ok "služba na pozadí se spustila"
  if kill -0 "$TSD_PID" 2>/dev/null; then
    bad "služba na pozadí se po skončení ukončila"
    kill "$TSD_PID" 2>/dev/null || true
  else
    ok "služba na pozadí se po skončení ukončila"
  fi
else
  bad "služba na pozadí se spustila"
fi
want_exists "$TS/state" "stav se zapsal i při běžící službě na pozadí"

# --- globální kontrola: klíč nikde neunikl ----------------------------------

printf '\n== klíč nikde neunikl\n'
# Klíč smí být jen ve svém vlastním kanálu (authkey a authkey.inuse).
LEAKS="$(find "$WORK"/c*/ts -type f ! -name 'authkey' ! -name 'authkey.inuse' \
          -exec grep -lF "$SECRET" {} + 2>/dev/null || true)"
if [ -n "$LEAKS" ]; then
  bad "klíč není v žádném jiném souboru sdíleného adresáře"
  printf '%s\n' "$LEAKS" | sed 's/^/      /'
else
  ok "klíč není v žádném jiném souboru sdíleného adresáře"
fi
if grep -rqF "$SECRET" "$WORK"/c*/ctl/args.log 2>/dev/null; then
  bad "klíč není v žádném volání nástroje"
else
  ok "klíč není v žádném volání nástroje"
fi
if grep -rqF "$SECRET" "$WORK"/c*/ctl/out.log 2>/dev/null; then
  bad "klíč není v záznamu běhu"
else
  ok "klíč není v záznamu běhu"
fi

printf '\n== výsledek: %s ok, %s FAIL ==\n' "$PASS_N" "$FAIL_N"
[ "$FAIL_N" -eq 0 ]
