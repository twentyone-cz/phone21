#!/usr/bin/env bash
#
# Phone21 — smoke test před vydáním. Spouští se v kořeni repa na stroji
# s dockerem. ŽÁDNÝ TAG BEZ ZELENÉHO BĚHU.
#
#   ./scripts/smoke-test.sh
#
# Kontroluje: validitu compose souborů, build obou obrazů, přítomnost
# souborů, na kterých stojí funkce (sms-queue.sh!), start ústředny včetně
# dialplanu a CDR adresáře, start ovládání včetně přihlašovací stránky,
# filtr provozu z privátní sítě a zákaz názvů technologií ve veřejných
# textech.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PASS=0; FAIL=0
AST=phone21-smoke-ast
WEB=phone21-smoke-web
DAV=phone21-smoke-dav

step() { # $1 popis, $2.. příkaz (i funkce)
  local desc="$1"; shift
  if "$@" >/tmp/smoke-step.log 2>&1; then
    echo "PASS: ${desc}"; PASS=$((PASS + 1))
  else
    echo "FAIL: ${desc}"; sed 's/^/      /' /tmp/smoke-step.log | tail -15
    FAIL=$((FAIL + 1))
  fi
}

cleanup() {
  docker rm -f "$AST" "$WEB" "$DAV" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

# --- 1. compose soubory jsou validní --------------------------------------
step "docker-compose.yml validní" \
  env AMI_PASSWORD=x WEBUI_PASSWORD=x SIP_USER=x SIP_DOMAIN=x \
    docker compose -f docker-compose.yml config -q
step "docker-compose.standalone.yml validní" \
  env WEBUI_PASSWORD=x docker compose -f docker-compose.standalone.yml config -q

# umbrel compose má službu app_proxy bez image (konvence umbrelu) — compose
# by ji odmítl, kontroluje se aspoň syntaxe YAML (bez pyyaml se přeskočí)
umbrel_yaml_check() {
  python3 - <<'PYEOF'
try:
    import yaml
except ImportError:
    print("pyyaml neni k dispozici - kontrola preskocena")
    raise SystemExit(0)
yaml.safe_load(open("umbrel/phone21/docker-compose.yml"))
PYEOF
}
step "umbrel compose je validní YAML" umbrel_yaml_check
umbrel_compose_check() {
  # docker compose musí soubor přijmout i s dosazenými proměnnými —
  # odhalí rozbité připojení adresářů (např. "too many colons")
  APP_DATA_DIR=/tmp/p21-check APP_PASSWORD=x \
    docker compose -f umbrel/jednadvacet-phone21/docker-compose.yml config >/dev/null
}
step "umbrel compose projde přes docker compose config" umbrel_compose_check
mount_spec_check() {
  # každý řádek připojení musí končit cestou, případně :ro/:rw
  ! grep -E "^\s+- \\$\{APP_DATA_DIR\}[^ ]*" umbrel/jednadvacet-phone21/docker-compose.yml \
    | grep -vE ":(ro|rw)$|:[^:]+$"
}
step "připojené adresáře mají platný zápis" mount_spec_check

# --- 2. build obrazů -------------------------------------------------------
step "build obrazu ústředny" \
  docker build -q -f docker/Dockerfile -t phone21-pbx:smoke .
step "build obrazu ovládání" \
  docker build -q -t phone21-ui:smoke webui/

# --- 3. statické kontroly obsahu obrazu ------------------------------------
step "sms-queue.sh je v obraze a spustitelný" \
  docker run --rm --entrypoint sh phone21-pbx:smoke -c \
    'test -x /usr/local/phone21/sms-queue.sh && sh -n /usr/local/phone21/sms-queue.sh'
step "šablony a entrypoint v obraze" \
  docker run --rm --entrypoint sh phone21-pbx:smoke -c \
    'test -f /opt/phone21/templates/extensions.conf && test -f /opt/phone21/templates/cdr.conf && bash -n /opt/phone21/entrypoint.sh'

# --- 4. ústředna nastartuje (bez modemu, selfconfig) ------------------------
step "start kontejneru ústředny" \
  docker run -d --name "$AST" -e PHONE21_SELFCONFIG=1 -e TS_WAIT=1 \
    phone21-pbx:smoke
ast_boot_check() {
  # CLI socket vzniká až po startu procesu — bez opakování by kontrola
  # závodila se startem a falešně padala
  local i
  for i in $(seq 1 45); do
    docker exec "$AST" asterisk -rx 'core waitfullybooted' >/dev/null 2>&1 && return 0
    sleep 2
  done
  docker logs "$AST" --tail 20
  return 1
}
step "ústředna plně nabootovala" ast_boot_check
step "CDR adresář existuje (historie hovorů se má kam psát)" \
  docker exec "$AST" test -f /var/log/asterisk/cdr-csv/Master.csv
ast_dialplan_check() {
  docker exec "$AST" sh -c \
    "asterisk -rx 'dialplan show quectel-incoming' | grep -q sms-queue.sh"
}
step "dialplan volá sms-queue.sh" ast_dialplan_check
ast_journal_check() {
  docker exec "$AST" sh -c \
    '/usr/local/phone21/sms-queue.sh journal smoke-test "$(printf %s "{}" | base64)" && grep -q smoke-test /var/lib/phone21/journal.jsonl'
}
step "žurnál SMS jde zapsat (sms-queue.sh journal)" ast_journal_check

# --- 5. ovládání nastartuje a mluví ----------------------------------------
step "start kontejneru ovládání" \
  docker run -d --name "$WEB" -e WEBUI_PASSWORD=smoke phone21-ui:smoke
step "modul app.py jde importovat" \
  docker exec "$WEB" python3 -c "import sys; sys.path.insert(0, '/app'); import app"
web_login_check() {
  sleep 2
  docker exec "$WEB" python3 -c "
import urllib.request
b = urllib.request.urlopen('http://127.0.0.1:8090/login', timeout=5).read().decode()
assert 'OVL-LOGIN' in b, 'chybi OVL-LOGIN'
"
}
step "přihlašovací stránka odpovídá (OVL-LOGIN)" web_login_check
web_badpass_check() {
  docker exec "$WEB" python3 -c "
import urllib.request, urllib.parse
data = urllib.parse.urlencode({'password': 'spatne'}).encode()
b = urllib.request.urlopen('http://127.0.0.1:8090/login', data, timeout=5).read().decode()
assert 'OVL-E01' in b, 'chybi OVL-E01'
"
}
step "špatné heslo vrací OVL-E01" web_badpass_check

# --- 6. filtr provozu z privátní sítě --------------------------------------
fw_syntax_check() {
  # nft -c potřebuje NET_ADMIN, jinak skončí na inicializaci cache
  docker run --rm --cap-add NET_ADMIN --entrypoint sh phone21-pbx:smoke \
    -c 'nft -c -f /opt/phone21/tunnel-firewall.nft'
}
step "pravidla filtru mají platnou syntaxi" fw_syntax_check
step "skript filtru je v obraze a spustitelný" \
  docker run --rm --entrypoint sh phone21-pbx:smoke \
    -c 'test -x /opt/phone21/scripts/tunnel-firewall.sh && bash -n /opt/phone21/scripts/tunnel-firewall.sh'
fw_default_off_check() {
  # bez FIREWALL_INTERNAL se filtr nesmí zapnout
  ! docker logs "$AST" 2>&1 | grep -q '\[firewall\]'
}
step "bez FIREWALL_INTERNAL se filtr nezapíná" fw_default_off_check

# --- 7. kontakty a kalendář -------------------------------------------------
step "build obrazu úložiště kontaktů" \
  docker build -q -t phone21-dav:smoke dav/
dav_start_check() {
  rm -rf /tmp/phone21-dav-smoke && mkdir -p /tmp/phone21-dav-smoke
  docker rm -f "$DAV" >/dev/null 2>&1 || true
  docker run -d --name "$DAV" -v /tmp/phone21-dav-smoke:/data phone21-dav:smoke >/dev/null
  for _ in $(seq 1 20); do
    docker exec "$DAV" python3 -c "
import urllib.request
urllib.request.urlopen('http://127.0.0.1:5232/.web/', timeout=3)" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}
step "úložiště kontaktů nastartuje a odpovídá" dav_start_check
step "úložiště běží pod nobody (65534)" \
  docker exec "$DAV" sh -c 'grep -q "Uid:.*65534" /proc/1/status || test "$(id -u)" = 65534'
dav_auth_check() {
  docker exec "$DAV" python3 -c "
import urllib.request, urllib.error
try:
    urllib.request.urlopen(urllib.request.Request(
        'http://127.0.0.1:5232/', method='PROPFIND'), timeout=5)
except urllib.error.HTTPError as e:
    raise SystemExit(0 if e.code == 401 else 'ocekavano 401, prislo %s' % e.code)
raise SystemExit('pozadavek bez hesla prosel')
"
}
step "bez hesla vrací 401" dav_auth_check
dav_split_check() {
  python3 - <<'PY'
import importlib.util, sys, types
spec = importlib.util.spec_from_file_location("wapp", "webui/app.py")
mod = importlib.util.module_from_spec(spec)
sys.modules["wapp"] = mod
spec.loader.exec_module(mod)
cards = mod.split_vcards("BEGIN:VCARD\nFN:A\nEND:VCARD\nBEGIN:VCARD\nFN:B\nEND:VCARD\n")
assert len(cards) == 2 and cards[0][0] != cards[1][0], cards
ics = ("BEGIN:VCALENDAR\nVERSION:2.0\n"
       "BEGIN:VEVENT\nUID:x\nSUMMARY:a\nEND:VEVENT\n"
       "BEGIN:VEVENT\nUID:x\nRECURRENCE-ID:1\nSUMMARY:b\nEND:VEVENT\n"
       "END:VCALENDAR\n")
items = mod.split_ics(ics)
assert len(items) == 1, items
assert mod.DAV_USER_RE.match("petr") and not mod.DAV_USER_RE.match("_x")
assert not mod.DAV_USER_RE.match("Petr Novak")
# vizitka bez jména musí jméno dostat, jinak ji úložiště odmítne (400)
def fn_of(raw):
    uid, card = mod.split_vcards(raw + "\n")[0]
    return [l for l in card.split("\r\n") if l.startswith("FN:")][0]
assert fn_of("BEGIN:VCARD\nVERSION:3.0\nN:Novak;Petr;;;\nTEL:+420111\nEND:VCARD") == "FN:Petr Novak"
assert fn_of("BEGIN:VCARD\nVERSION:3.0\nTEL:+420222\nEND:VCARD") == "FN:+420222"
assert fn_of("BEGIN:VCARD\nVERSION:3.0\nFN:Beze zmeny\nTEL:+420333\nEND:VCARD") == "FN:Beze zmeny"
PY
}
step "dělení kontaktů a kalendáře funguje" dav_split_check

# --- 8. veřejné texty bez názvů technologií --------------------------------
# Samostatná slova v lidsky psaném textu; identifikátory (phone21,
# asterisk.conf, tailscale0) \b nechytí, resp. jsou vyloučené níže.
TECH_RE='\b(sip|asterisk|tailscale|linphone|wireguard|headscale|voip|quectel|volte|csfb|graphene|radicale|it-one)\b'
public_text_check() {
  ! grep -inE "$TECH_RE" \
      umbrel/phone21/umbrel-app.yml
}
step "umbrel-app.yml bez názvů technologií" public_text_check
public_docs_check() {
  ! grep -inE "$TECH_RE" README.md docs/faq.md docs/telefon.md \
    | grep -vE '(asterisk|webui|scripts|docker|dav)/'
}
step "README a veřejné návody bez názvů technologií" public_docs_check
public_compose_check() {
  # v compose zůstávají jen identifikátory (názvy služeb, obrazů, cest)
  ! grep -inE "$TECH_RE" umbrel/phone21/docker-compose.yml \
    | grep -vE 'image:|container_name|_1|/var/|/opt/|/etc/|Phone21_|AMI_|SIP_|asterisk:|tailscale/tailscale|asterisk -rx|tailscale ip|phone21-ts|tailscale0|/phone21'
}
step "umbrel compose bez názvů technologií v textu" public_compose_check
webui_text_check() {
  # v ovládání se hlídá jen to, co vidí zákazník v textu stránek
  ! grep -inE 'AT příkaz|VoLTE|CSFB|GrapheneOS|Linphon' webui/app.py \
    | grep -vE 'linphone\.org|linphone-config:|volte_state|"volte"|volte ==|volte =='
}
step "texty ovládání bez názvů technologií" webui_text_check

echo
echo "== výsledek: ${PASS} PASS, ${FAIL} FAIL =="
[ "$FAIL" -eq 0 ]
