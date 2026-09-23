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
# filtr provozu z privátní sítě, smyčku služby privátní sítě (že se compose
# nerozešly se zdrojem, že volání nástroje drží kontrakt a že smyčka projde
# vlastním testem), klienta koordinátoru v ovládání, syntaxi skriptů
# a pythonu v repu a zákaz názvů technologií ve veřejných textech.
#
# RELEASE=1 přidá kontroly, které dávají smysl až při vydání (shoda verze
# v manifestu s tagy a digesty obrazů). Mimo vydání jsou vynechané: mezi
# zvýšením verze v manifestu a postavením obrazů je manifest napřed a
# kontrola by svítila červeně celou vlnu oprav.
#
# Bez dockeru se běh nezastaví: kroky, které ho potřebují, se hlásí jako
# vynechané (nikdy jako splněné) a na konci se vypíše, co tím zůstalo
# neověřené. Textové a syntaktické kontroly běží i tak.
#
# Návratový kód:  0 = úplný zelený běh (smí se tagovat)
#                 1 = aspoň jeden krok selhal
#                 2 = nic neselhalo, ale běh je neúplný (chybí docker)

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PASS=0; FAIL=0; SKIP=0; SKIP_DOCKER=0
AST=phone21-smoke-ast
WEB=phone21-smoke-web
DAV=phone21-smoke-dav

# Klient a démon se rozlišují schválně: `docker compose config` si vystačí
# s klientem, build a start kontejneru potřebují běžící démona.
DOCKER_CLI=0; DOCKER_DAEMON=0
if command -v docker >/dev/null 2>&1; then
  DOCKER_CLI=1
  docker info >/dev/null 2>&1 && DOCKER_DAEMON=1
fi
if [ "$DOCKER_CLI" = 0 ]; then
  DOCKER_WHY="docker není nainstalovaný"
elif [ "$DOCKER_DAEMON" = 0 ]; then
  DOCKER_WHY="démon dockeru neodpovídá"
else
  DOCKER_WHY=""
fi

step() { # $1 popis, $2.. příkaz (i funkce)
  local desc="$1"; shift
  if "$@" >/tmp/smoke-step.log 2>&1; then
    echo "PASS: ${desc}"; PASS=$((PASS + 1))
  else
    echo "FAIL: ${desc}"; sed 's/^/      /' /tmp/smoke-step.log | tail -15
    FAIL=$((FAIL + 1))
  fi
}

skip() { # $1 popis, $2 důvod — krok se v tomhle režimu nespouští
  echo "SKIP: $1 ($2)"; SKIP=$((SKIP + 1))
}

skip_docker() { # $1 popis — krok potřebuje docker a ten tu není
  echo "SKIP: $1 (${DOCKER_WHY})"
  SKIP=$((SKIP + 1)); SKIP_DOCKER=$((SKIP_DOCKER + 1))
}

dstep() { # $1 popis, $2.. příkaz — potřebuje běžícího démona
  if [ "$DOCKER_DAEMON" = 1 ]; then step "$@"; else skip_docker "$1"; fi
}

cstep() { # $1 popis, $2.. příkaz — stačí klient (docker compose config)
  if [ "$DOCKER_CLI" = 1 ]; then step "$@"; else skip_docker "$1"; fi
}

cleanup() {
  [ "$DOCKER_DAEMON" = 1 ] || return 0
  docker rm -f "$AST" "$WEB" "$DAV" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

# --- 1. compose soubory jsou validní --------------------------------------
compose_shape_check() {
  # Náhrada za `docker compose config` tam, kde docker není (a za pyyaml,
  # který tu taky nemusí být). Nekontroluje význam, jen tvar: odsazení
  # tabulátorem, konce řádků CRLF a DVAKRÁT ZAPSANÝ KLÍČ. Zrovna duplicitu
  # klíče pyyaml mlčky přejde (druhý výskyt přebije první), a přitom je to
  # nejpravděpodobnější chyba po vložení generovaného bloku smyčky.
  python3 - \
    docker-compose.yml \
    docker-compose.standalone.yml \
    docker-compose.tailscale.yml \
    umbrel/jednadvacet-phone21/docker-compose.yml <<'PYEOF'
import re
import sys

KEY = re.compile(r"^(\s*)([A-Za-z_][A-Za-z0-9_.-]*)\s*:(\s|$)")
ITEM = re.compile(r"^(\s*)-(\s|$)")
BLOCK = re.compile(r"[|>][+-]?[0-9]*\s*$")   # otevření víceřádkového textu

bad = 0
for path in sys.argv[1:]:
    try:
        raw_lines = open(path, encoding="utf-8").read().splitlines(True)
    except OSError as exc:
        print("nelze číst %s: %s" % (path, exc))
        bad = 1
        continue
    stack = []          # [(odsazení, množina klíčů)]
    block_indent = None  # odsazení uzlu, který otevřel víceřádkový text
    has_services = False
    for num, raw in enumerate(raw_lines, 1):
        if raw.rstrip("\n").endswith("\r"):
            print("%s:%d: řádek končí CRLF" % (path, num))
            bad = 1
        line = raw.rstrip("\n").rstrip("\r")
        indent = len(line) - len(line.lstrip(" "))
        if block_indent is not None:
            # obsah víceřádkového textu se nečte, je to shell, ne YAML
            if not line.strip() or indent > block_indent:
                continue
            block_indent = None
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if "\t" in line[:indent] or line.lstrip(" ").startswith("\t"):
            print("%s:%d: odsazení tabulátorem" % (path, num))
            bad = 1
            continue
        item = ITEM.match(line)
        if item:
            while stack and stack[-1][0] > indent:
                stack.pop()
            if BLOCK.search(line):
                block_indent = indent
            continue
        key = KEY.match(line)
        if not key:
            continue
        name = key.group(2)
        while stack and stack[-1][0] > indent:
            stack.pop()
        if not stack or stack[-1][0] < indent:
            stack.append((indent, set()))
        seen = stack[-1][1]
        if name in seen:
            print("%s:%d: klíč %r je na této úrovni už podruhé" % (path, num, name))
            bad = 1
        seen.add(name)
        if indent == 0 and name == "services":
            has_services = True
        if BLOCK.search(line):
            block_indent = indent
    if not has_services:
        print("%s: chybí blok services:" % path)
        bad = 1
sys.exit(bad)
PYEOF
}
step "compose soubory mají zdravou strukturu (bez dockeru)" compose_shape_check

logging_cap_check() {
  # Služba s vlastním image musí mít strop logu (bez rotace docker log umí
  # zaplnit celý disk). app_proxy v umbrel compose image nemá (dodává ho
  # šablona Umbrelu), a tak se do kontroly nepočítá. Bez pyyaml, čte se
  # přímo tvar souboru jako v compose_shape_check výše.
  python3 - \
    docker-compose.yml \
    docker-compose.standalone.yml \
    docker-compose.tailscale.yml \
    umbrel/jednadvacet-phone21/docker-compose.yml <<'PYEOF'
import re
import sys

BLOCK = re.compile(r"[|>][+-]?[0-9]*\s*$")   # otevření víceřádkového textu

bad = 0
for path in sys.argv[1:]:
    services = []   # [{"name":, "image": bool, "max_size": bool}]
    cur = None       # rozepsaná služba
    key = None       # aktuální klíč na úrovni služby (odsazení 4)
    block_indent = None  # odsazení uzlu, který otevřel víceřádkový text
    for raw in open(path, encoding="utf-8"):
        line = raw.rstrip("\n")
        indent = len(line) - len(line.lstrip(" "))
        if block_indent is not None:
            # obsah víceřádkového textu se nečte, je to shell, ne YAML
            if not line.strip() or indent > block_indent:
                continue
            block_indent = None
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        stripped = line.strip()
        head = re.match(r"^([A-Za-z0-9_.-]+):\s*(#.*)?$", stripped) if indent == 2 else None
        if head:
            cur = {"name": head.group(1), "image": False, "max_size": False}
            services.append(cur)
            key = None
            continue
        if cur is None:
            continue
        if indent == 4:
            key = stripped.split(":", 1)[0]
            if key in ("image", "build"):
                # "build" počítá stejně jako "image": vlastní image i tehdy,
                # když se staví lokálně a "image:" v souboru není vůbec
                cur["image"] = True
            if BLOCK.search(line):
                block_indent = indent
            continue
        if key == "logging" and "max-size" in stripped:
            cur["max_size"] = True
        if BLOCK.search(line):
            block_indent = indent

    for svc in services:
        if svc["image"] and not svc["max_size"]:
            print("%s: služba %r má vlastní image, ale chybí logging.max-size"
                  % (path, svc["name"]))
            bad = 1

sys.exit(bad)
PYEOF
}
step "služby s vlastním image mají strop logu (logging.max-size)" logging_cap_check

cstep "docker-compose.yml validní" \
  env AMI_PASSWORD=x WEBUI_PASSWORD=x SIP_USER=x SIP_DOMAIN=x \
    docker compose -f docker-compose.yml config -q
cstep "docker-compose.standalone.yml validní" \
  env WEBUI_PASSWORD=x docker compose -f docker-compose.standalone.yml config -q

# umbrel compose má službu app_proxy bez image (konvence umbrelu) — compose
# by ji odmítl, kontroluje se aspoň syntaxe YAML. Čte se i umbrel-app.yml:
# rozbitý manifest (typicky víceřádkové poznámky k vydání) by se jinak poznal
# až ve storu. Bez parseru se krok hlásí jako vynechaný; dřív se tvářil jako
# splněný, což je horší než nic.
UMBREL_YAML="umbrel/jednadvacet-phone21/docker-compose.yml umbrel/jednadvacet-phone21/umbrel-app.yml"
umbrel_yaml_check() {
  python3 - $UMBREL_YAML <<'PYEOF'
import sys
import yaml
for path in sys.argv[1:]:
    yaml.safe_load(open(path, encoding="utf-8"))
PYEOF
}
umbrel_yaml_check_node() {
  # záloha pro stroje bez pyyaml (balík node-js-yaml)
  node -e '
const yaml = require("js-yaml"), fs = require("fs");
for (const p of process.argv.slice(1)) yaml.load(fs.readFileSync(p, "utf8"));
' $UMBREL_YAML
}
if python3 -c 'import yaml' 2>/dev/null; then
  step "umbrel compose a manifest jsou validní YAML" umbrel_yaml_check
elif node -e 'require("js-yaml")' 2>/dev/null; then
  step "umbrel compose a manifest jsou validní YAML" umbrel_yaml_check_node
else
  skip "umbrel compose a manifest jsou validní YAML" \
    "není pyyaml ani js-yaml; tvar kontroluje krok bez dockeru výše"
fi
umbrel_compose_check() {
  # docker compose musí soubor přijmout i s dosazenými proměnnými —
  # odhalí rozbité připojení adresářů (např. "too many colons").
  # app_proxy dodává Umbrel z vlastní šablony, tady se doplní náhrada.
  printf 'services:\n  app_proxy:\n    image: alpine:3\n' > /tmp/p21-proxy.yml
  APP_DATA_DIR=/tmp/p21-check APP_PASSWORD=x \
    docker compose -f umbrel/jednadvacet-phone21/docker-compose.yml \
      -f /tmp/p21-proxy.yml config >/dev/null
}
cstep "umbrel compose projde přes docker compose config" umbrel_compose_check
mount_spec_check() {
  # každý řádek připojení musí končit cestou, případně :ro/:rw
  ! grep -E "^\s+- \\$\{APP_DATA_DIR\}[^ ]*" umbrel/jednadvacet-phone21/docker-compose.yml \
    | grep -vE ":(ro|rw)$|:[^:]+$"
}
step "připojené adresáře mají platný zápis" mount_spec_check

ts_mounts_check() {
  # Sdílený adresář ts/ musí být na hostiteli JEDNA cesta pro všechny tři
  # kontejnery: ústředna v něm zakládá práva, ovládání do něj píše klíč
  # a služba privátní sítě si ho odtud bere. Když se mounty rozejdou, každý
  # píše jinam a nic nespadne — jen to tiše nefunguje.
  python3 - <<'PYEOF'
import re
import sys

# Skupina = co se spouští dohromady. Overlay se přikládá k základnímu souboru,
# takže ústředna je v prvním a ovládání se sítí ve druhém.
GROUPS = (
    ("umbrel", ["umbrel/jednadvacet-phone21/docker-compose.yml"]),
    ("standalone", ["docker-compose.standalone.yml"]),
    ("overlay", ["docker-compose.yml", "docker-compose.tailscale.yml"]),
)
UI_TS = "/var/lib/phone21/ts"      # TS_DIR ovládání
NET_TS = "/phone21-ts"             # sdílený adresář ve službě privátní sítě
PBX_DATA = "/var/lib/phone21"      # datový adresář ústředny (ts/ je v něm)


def load(paths):
    """Mapa služba → seznam připojení. Bez pyyaml, protože ten tu být nemusí."""
    svc = {}
    for path in paths:
        cur, invol = None, False
        for raw in open(path, encoding="utf-8"):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            indent = len(line) - len(line.lstrip())
            if indent < 2:
                cur, invol = None, False
                continue
            if indent == 2 and line.rstrip().endswith(":"):
                cur, invol = line.strip()[:-1], False
                continue
            if cur is None:
                continue
            if indent == 4:
                # seznam připojení se v overlayi nahrazuje, neslučuje
                invol = line.strip() == "volumes:"
                if invol:
                    svc[cur] = []
                continue
            if invol and line.lstrip().startswith("- "):
                item = re.split(r"\s+#", line.lstrip()[2:], maxsplit=1)[0]
                svc[cur].append(item.strip().strip('"').strip("'"))
    return svc


def hosts(vols, target):
    out = []
    for vol in vols:
        parts = vol.split(":")
        if len(parts) >= 2 and parts[1] == target:
            out.append((parts[0], parts[2] if len(parts) > 2 else ""))
    return out


bad = 0
for name, paths in GROUPS:
    svc = load(paths)
    found = {}
    for service, target in (("pbx", PBX_DATA), ("ui", UI_TS), ("net", NET_TS)):
        hit = hosts(svc.get(service, []), target)
        if len(hit) != 1:
            print("%s: služba %s nemá právě jedno připojení na %s (%s)"
                  % (name, service, target, hit))
            bad = 1
            continue
        found[service] = hit[0]
    if len(found) != 3:
        continue
    if found["ui"][0] != found["net"][0]:
        print("%s: ovládání a síť mají jiný adresář ts/ (%s × %s)"
              % (name, found["ui"][0], found["net"][0]))
        bad = 1
    if found["ui"][0] != found["pbx"][0].rstrip("/") + "/ts":
        print("%s: ts/ ovládání neleží v datovém adresáři ústředny (%s × %s)"
              % (name, found["ui"][0], found["pbx"][0]))
        bad = 1
    if found["ui"][1] != "rw":
        print("%s: ovládání má ts/ připojené jako %r, musí být rw"
              % (name, found["ui"][1]))
        bad = 1
    if found["net"][1] == "ro":
        print("%s: síť má ts/ připojené jen pro čtení" % name)
        bad = 1
    if found["pbx"][1] == "ro":
        print("%s: ústředna má datový adresář jen pro čtení, ts/ by nezaložila"
              % name)
        bad = 1

sys.exit(bad)
PYEOF
}
step "sdílený adresář ts/ sedí ve všech compose souborech" ts_mounts_check

# --- 1b. služba privátní sítě (zdroj smyčky vs. compose) -------------------
# Smyčka má jediný zdroj: docker/ts-sidecar.sh. Do compose souborů ji vkládá
# generátor, takže se tři kopie nemůžou rozejít (dřív se rozešly).
step "compose sedí se zdrojem smyčky (gen-compose-sidecar --check)" \
  python3 scripts/gen-compose-sidecar.py --check --quiet
step "skript smyčky má platnou syntaxi" sh -n docker/ts-sidecar.sh

ts_up_flags_check() {
  # Přihlášení musí být v JEDNOM volání: --reset vrací i nabídku výstupního
  # uzlu do výchozího stavu, takže když v tom samém volání chybí
  # --advertise-exit-node, brána po každém přihlášení tiše přestane pouštět
  # provoz ven. Klíč se předává souborem (síť je hostitelská, argumenty vidí
  # celý stroj) a zařazení uzlu dává výhradně klíč, nikdy argument.
  local call count
  # spojení pokračovacích řádků, aby se kontrola nedala obejít zalomením
  call=$(awk '{ while (sub(/\\$/, "")) { if ((getline nxt) <= 0) break; $0 = $0 nxt } print }' \
           docker/ts-sidecar.sh | grep -F 'tailscale up')
  count=$(printf '%s\n' "$call" | grep -c . || true)
  if [ "$count" != "1" ]; then
    echo "očekává se právě jedno přihlášení, nalezeno: $count"
    return 1
  fi
  local flag
  for flag in '--reset' '--auth-key=file:' '--timeout=' '--advertise-exit-node='; do
    case "$call" in
      *"$flag"*) ;;
      *) echo "ve volání chybí $flag"; return 1 ;;
    esac
  done
  return 0
}
step "přihlášení drží kontrakt (reset, klíč souborem, uzel v témže volání)" \
  ts_up_flags_check

ts_forbidden_flags_check() {
  # --authkey= dá klíč na příkazovou řádku (hostitelská síť = vidí ho celý
  # stroj), --advertise-tags si zařazení nevynucuje klient, dává ho klíč.
  ! grep -nE -- '--authkey=|--advertise-tags' \
      docker/ts-sidecar.sh \
      umbrel/jednadvacet-phone21/docker-compose.yml \
      docker-compose.standalone.yml \
      docker-compose.tailscale.yml
}
step "klíč ani zařazení uzlu nejsou na příkazové řádce" ts_forbidden_flags_check

access_levels_check() {
  # Smyčka i filtr provozu čtou týž soubor ts/tunnel_access. Kdyby si každý
  # vykládal jeho hodnoty jinak, uzel by se nabízel bez otevřeného filtru
  # (nebo naopak) a vypadalo by to jako výpadek sítě.
  grep -qE '^[[:space:]]*router\)[[:space:]]*WANT=true' docker/ts-sidecar.sh || {
    echo "smyčka nezapíná výstupní uzel na stupni router"; return 1; }
  local level
  for level in $(sed -n '/tunnel_access/,/esac/p' docker/ts-sidecar.sh \
      | sed -n 's/^[[:space:]]*\([a-z][a-z|]*\))[[:space:]]*WANT=.*/\1/p' \
      | tr '|' ' '); do
    grep -qE "\\b${level}\\b" docker/tunnel-firewall.sh || {
      echo "stupeň přístupu ${level} nezná docker/tunnel-firewall.sh"; return 1; }
  done
  grep -qE 'endpoint\|router\|phone' docker/tunnel-firewall.sh || {
    echo "filtr už nezná trojici stupňů přístupu"; return 1; }
  return 0
}
step "smyčka a filtr rozumí volbě přístupu stejně" access_levels_check

# --- 1c. zdroje v repu: syntaxe a vlastní testy (bez dockeru) --------------
# Tyhle soubory se jinak kontrolují až UVNITŘ obrazu (kroky 3, 5 a 6), takže
# bez dockeru by se na ně nepodíval nikdo. Kontrola nad repem není náhrada
# (neřekne, jestli se soubor do obrazu vůbec dostal a je spustitelný), ale
# překlep v shellu nebo v pythonu zachytí stejně.
repo_sh_syntax_check() {
  local file sheb rc=0
  for file in docker/entrypoint.sh docker/tunnel-firewall.sh docker/ts-sidecar.sh \
              scripts/sms-queue.sh scripts/dev-deploy.sh scripts/watchdog.sh \
              scripts/wwan.sh scripts/install-firewall.sh scripts/install-mbn.sh \
              scripts/install-watchdog.sh scripts/mbn-profile.sh \
              scripts/test-ts-sidecar.sh scripts/smoke-test.sh; do
    if [ ! -f "$file" ]; then
      echo "chybí ${file}"; rc=1; continue
    fi
    sheb=$(head -1 "$file")
    case "$sheb" in
      *bash*) bash -n "$file" || rc=1 ;;
      *) sh -n "$file" || rc=1 ;;
    esac
  done
  return "$rc"
}
step "shellové skripty v repu mají platnou syntaxi" repo_sh_syntax_check
repo_py_syntax_check() {
  # ast.parse, ne py_compile — ten by po sobě nechal __pycache__ v repu
  python3 - webui/app.py scripts/gen-compose-sidecar.py \
    scripts/test-webui-partner.py <<'PYEOF'
import ast
import sys

bad = 0
for path in sys.argv[1:]:
    try:
        ast.parse(open(path, encoding="utf-8").read(), filename=path)
    except (OSError, SyntaxError) as exc:
        print("%s: %s" % (path, exc))
        bad = 1
sys.exit(bad)
PYEOF
}
step "pythonové zdroje v repu se přeloží" repo_py_syntax_check

# Oba testy si vystačí s podstrčeným nástrojem, resp. s lokálním http.server,
# takže běží i tam, kde docker není. Pokrývají přesně ta dvě místa, kde se
# tiché selhání pozná nejhůř: převzetí klíče ve smyčce a mapování odpovědí
# koordinátoru na hlášky v ovládání.
step "smyčka služby privátní sítě projde vlastním testem" \
  bash scripts/test-ts-sidecar.sh
step "klient koordinátoru v ovládání projde vlastním testem" \
  python3 scripts/test-webui-partner.py

# --- 2. build obrazů -------------------------------------------------------
dstep "build obrazu ústředny" \
  docker build -q -f docker/Dockerfile -t phone21-pbx:smoke .
dstep "build obrazu ovládání" \
  docker build -q -t phone21-ui:smoke webui/

# --- 3. statické kontroly obsahu obrazu ------------------------------------
dstep "sms-queue.sh je v obraze a spustitelný" \
  docker run --rm --entrypoint sh phone21-pbx:smoke -c \
    'test -x /usr/local/phone21/sms-queue.sh && sh -n /usr/local/phone21/sms-queue.sh'
dstep "šablony a entrypoint v obraze" \
  docker run --rm --entrypoint sh phone21-pbx:smoke -c \
    'test -f /opt/phone21/templates/extensions.conf && test -f /opt/phone21/templates/cdr.conf && bash -n /opt/phone21/entrypoint.sh'

# --- 4. ústředna nastartuje (bez modemu, selfconfig) ------------------------
dstep "start kontejneru ústředny" \
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
dstep "ústředna plně nabootovala" ast_boot_check
spool_writable_check() {
  # bez zapisovatelného spoolu se nikdy nevytvoří opakovaný pokus
  # o doručení a zpráva navždy uvízne ve frontě
  docker exec "$AST" sh -c '
    test -d /var/spool/asterisk/outgoing/.tmp &&
    su -s /bin/sh asterisk -c "touch /var/spool/asterisk/outgoing/.tmp/smoke" &&
    rm -f /var/spool/asterisk/outgoing/.tmp/smoke'
}
dstep "ústředna smí psát do spoolu (opakované pokusy)" spool_writable_check
dstep "CDR adresář existuje (historie hovorů se má kam psát)" \
  docker exec "$AST" test -f /var/log/asterisk/cdr-csv/Master.csv
ast_dialplan_check() {
  docker exec "$AST" sh -c \
    "asterisk -rx 'dialplan show quectel-incoming' | grep -q sms-queue.sh"
}
dstep "dialplan volá sms-queue.sh" ast_dialplan_check
ast_journal_check() {
  docker exec "$AST" sh -c \
    '/usr/local/phone21/sms-queue.sh journal smoke-test "$(printf %s "{}" | base64)" && grep -q smoke-test /var/lib/phone21/journal.jsonl'
}
dstep "žurnál SMS jde zapsat (sms-queue.sh journal)" ast_journal_check

# --- 5. ovládání nastartuje a mluví ----------------------------------------
dstep "start kontejneru ovládání" \
  docker run -d --name "$WEB" -e WEBUI_PASSWORD=smoke phone21-ui:smoke
dstep "modul app.py jde importovat" \
  docker exec "$WEB" python3 -c "import sys; sys.path.insert(0, '/app'); import app"
web_login_check() {
  sleep 2
  docker exec "$WEB" python3 -c "
import urllib.request
b = urllib.request.urlopen('http://127.0.0.1:8090/login', timeout=5).read().decode()
assert 'OVL-LOGIN' in b, 'chybi OVL-LOGIN'
"
}
dstep "přihlašovací stránka odpovídá (OVL-LOGIN)" web_login_check
web_badpass_check() {
  docker exec "$WEB" python3 -c "
import urllib.request, urllib.parse
data = urllib.parse.urlencode({'password': 'spatne'}).encode()
b = urllib.request.urlopen('http://127.0.0.1:8090/login', data, timeout=5).read().decode()
assert 'OVL-E01' in b, 'chybi OVL-E01'
"
}
dstep "špatné heslo vrací OVL-E01" web_badpass_check

# --- 6. filtr provozu z privátní sítě --------------------------------------
fw_syntax_check() {
  # nft -c potřebuje NET_ADMIN, jinak skončí na inicializaci cache
  docker run --rm --cap-add NET_ADMIN --entrypoint sh phone21-pbx:smoke \
    -c 'nft -c -f /opt/phone21/tunnel-firewall.nft'
}
dstep "pravidla filtru mají platnou syntaxi" fw_syntax_check
dstep "skript filtru je v obraze a spustitelný" \
  docker run --rm --entrypoint sh phone21-pbx:smoke \
    -c 'test -x /opt/phone21/scripts/tunnel-firewall.sh && bash -n /opt/phone21/scripts/tunnel-firewall.sh'
fw_levels_check() {
  # tři stupně přístupu: telefon (bílá listina), celý miniserver, i dál do sítě
  local base=/tmp/phone21-fw-levels
  rm -rf "$base" && mkdir -p "$base/ts"
  run() {  # $1 = obsah volby ("" = žádná), vypíše řetězy tun_pre a fwd_pre
    if [ -n "$1" ]; then printf '%s' "$1" > "$base/ts/tunnel_access";
    else rm -f "$base/ts/tunnel_access"; fi
    docker run --rm --network none --cap-add NET_ADMIN -v "$base":/var/lib/phone21 \
      --entrypoint sh phone21-pbx:smoke -c \
      '/opt/phone21/scripts/tunnel-firewall.sh apply >/dev/null 2>&1;
       nft list chain inet phone21 tun_pre; nft list chain inet phone21 fwd_pre'
  }
  run "" | grep -q "accept" && return 1                       # výchozí: nic navíc
  # celý miniserver: vstup bez omezení + publikované porty aplikací
  run "endpoint" | grep -q "ct status dnat counter" || return 1
  [ "$(run "endpoint" | grep -c "accept")" = "2" ] || return 1
  # i dál do sítě: průchod bez omezení (žádná podmínka na překlad adresy)
  run "router" | grep -q "ct status dnat" && return 1
  [ "$(run "router" | grep -c "accept")" = "2" ] || return 1
  return 0
}
dstep "přístup z privátní sítě má tři stupně" fw_levels_check

fw_default_off_check() {
  # bez FIREWALL_INTERNAL se filtr nesmí zapnout
  ! docker logs "$AST" 2>&1 | grep -q '\[firewall\]'
}
dstep "bez FIREWALL_INTERNAL se filtr nezapíná" fw_default_off_check

# --- 7. kontakty a kalendář -------------------------------------------------
dstep "build obrazu úložiště kontaktů" \
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
dstep "úložiště kontaktů nastartuje a odpovídá" dav_start_check
dstep "úložiště běží pod nobody (65534)" \
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
dstep "bez hesla vrací 401" dav_auth_check
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
# Výjimky jsou dva UZAVŘENÉ seznamy, ne volné podřetězce (dřív jich bylo
# šestnáct: osm z nich neomlouvalo nic a „/var/“ s „_1“ omlouvaly rovnou celý
# řádek včetně komentáře, takže se tudy dal propašovat libovolný text):
#   PATH_RE — cesty, názvy obrazů a identifikátory, kde je název technologie
#             součástí rozhraní a přejmenovat ho nejde
#   CLI_RE  — doslovná volání nástrojů příkazové řádky
# V KOMENTÁŘÍCH neplatí žádná výjimka: komentář je lidský text a ten se
# ve veřejném souboru píše bez názvů technologií.
# POZN.: seznamy čte python (re), ne grep — bez POSIX tříd typu [:space:].
PATH_RE='tailscale/tailscale:[^\s"]+|/var/(lib|run)/tailscale[A-Za-z0-9._/-]*|/var/(lib|log|spool)/asterisk[A-Za-z0-9._/-]*|\basterisk/'
CLI_RE='\basterisk -rx\b|\btailscale (status|ip|up|set|logout)\b'
tech_check() { # $@ = soubory
  TECH_RE="$TECH_RE" PATH_RE="$PATH_RE" CLI_RE="$CLI_RE" python3 - "$@" <<'PYEOF'
import os
import re
import sys

tech = re.compile(os.environ["TECH_RE"], re.I)
allowed = re.compile("(?:%s)|(?:%s)" % (os.environ["PATH_RE"], os.environ["CLI_RE"]))


def split_comment(line):
    """Řádek na (kód, komentář).

    Komentář začíná „#“ na začátku řádku nebo „#“ po bílém znaku. Když jsou
    před ním nepárové uvozovky, jde nejspíš o „#“ uvnitř řetězce a celý řádek
    se bere jako kód — radši výjimka navíc než falešný poplach.
    """
    if line.lstrip().startswith("#"):
        return "", line
    pos = 0
    while True:
        pos = line.find("#", pos)
        if pos <= 0:
            return line, ""
        head = line[:pos]
        if line[pos - 1] in " \t" \
                and head.count('"') % 2 == 0 and head.count("'") % 2 == 0:
            return head, line[pos:]
        pos += 1


bad = 0
for path in sys.argv[1:]:
    try:
        fh = open(path, encoding="utf-8")
    except OSError as exc:
        # dřív se kontrola nad neexistující cestou tvářila jako splněná
        print("nelze číst %s: %s" % (path, exc))
        bad = 1
        continue
    with fh:
        for num, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            code, comment = split_comment(line)
            for part, excuse in ((code, True), (comment, False)):
                if not part.strip():
                    continue
                hit = tech.search(allowed.sub(" ", part) if excuse else part)
                if hit:
                    print("%s:%d: %s   <- %s%s"
                          % (path, num, line.strip()[:110], hit.group(0),
                             "" if excuse else " (v komentáři neplatí výjimky)"))
                    bad = 1
sys.exit(bad)
PYEOF
}
step "umbrel-app.yml bez názvů technologií" \
  tech_check umbrel/jednadvacet-phone21/umbrel-app.yml
step "README a veřejné návody bez názvů technologií" \
  tech_check README.md docs/faq.md docs/telefon.md \
    web/phone/index.html web/phone/instalace.html
step "umbrel compose bez názvů technologií v textu" \
  tech_check umbrel/jednadvacet-phone21/docker-compose.yml
webui_text_check() {
  # v ovládání se hlídá jen to, co vidí zákazník v textu stránek
  ! grep -inE 'AT příkaz|VoLTE|CSFB|GrapheneOS|Linphon' webui/app.py \
    | grep -vE 'linphone\.org|linphone-config:|volte_state|"volte"|volte ==|volte =='
}
step "texty ovládání bez názvů technologií" webui_text_check

# --- 9. jen při vydání (RELEASE=1) -----------------------------------------
# Verze v manifestu se zvedá na začátku vlny, obrazy se staví až na konci —
# mezitím je manifest napřed proti pinům a kontrola by svítila červeně celou
# dobu. Proto se pouští jen v režimu vydání, kdy už obrazy existují.
release_pins_check() {
  local ver line bad=0
  ver=$(sed -n 's/^version:[[:space:]]*"\{0,1\}\([0-9][0-9.]*\)"\{0,1\}[[:space:]]*$/\1/p' \
          umbrel/jednadvacet-phone21/umbrel-app.yml)
  if [ -z "$ver" ]; then
    echo "verzi v umbrel-app.yml se nepodařilo přečíst"
    return 1
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      *"phone21-pbx:${ver}@sha256:"*|\
      *"phone21-ui:${ver}@sha256:"*|\
      *"phone21-dav:${ver}@sha256:"*) ;;
      *)
        echo "obraz neodpovídá verzi ${ver} nebo není připnutý digestem:"
        echo "      ${line}"
        bad=1 ;;
    esac
  done <<EOF
$(grep -E '^[[:space:]]*image:[[:space:]]*ghcr\.io/twentyone-cz/phone21-' \
    umbrel/jednadvacet-phone21/docker-compose.yml)
EOF
  # tři obrazy, ani jeden nesmí chybět
  local count
  count=$(grep -cE '^[[:space:]]*image:[[:space:]]*ghcr\.io/twentyone-cz/phone21-' \
            umbrel/jednadvacet-phone21/docker-compose.yml)
  if [ "$count" != "3" ]; then
    echo "v umbrel compose je ${count} vlastních obrazů, očekávají se 3"
    bad=1
  fi
  [ "$bad" -eq 0 ]
}
if [ "${RELEASE:-0}" = "1" ]; then
  step "obrazy sedí s verzí manifestu a jsou připnuté digestem" release_pins_check
else
  # do důvodu se vypíše skutečný rozdíl, ať je vidět, co přesně čeká na build
  MAN_VER=$(sed -n 's/^version:[[:space:]]*"\{0,1\}\([0-9][0-9.]*\)"\{0,1\}[[:space:]]*$/\1/p' \
              umbrel/jednadvacet-phone21/umbrel-app.yml)
  PIN_VER=$(grep -E '^[[:space:]]*image:[[:space:]]*ghcr\.io/twentyone-cz/phone21-' \
              umbrel/jednadvacet-phone21/docker-compose.yml \
            | sed -n 's/.*phone21-[a-z]*:\([0-9][0-9.]*\)@.*/\1/p' \
            | sort -u | paste -sd' ' -)
  skip "obrazy sedí s verzí manifestu a jsou připnuté digestem" \
    "jen při RELEASE=1; manifest ${MAN_VER:-?}, piny ${PIN_VER:-?} — obrazy se staví až při vydání"
fi

echo
echo "== výsledek: ${PASS} PASS, ${FAIL} FAIL, ${SKIP} SKIP =="

if [ "$SKIP_DOCKER" -gt 0 ]; then
  cat <<TXT

NEÚPLNÝ BĚH: ${SKIP_DOCKER} kroků se nespustilo, protože ${DOCKER_WHY}.
Bez dockeru ZŮSTÁVÁ NEOVĚŘENÉ:
  - že se obrazy ústředny, ovládání a úložiště kontaktů vůbec postaví
  - že v obraze ústředny je spustitelný sms-queue.sh a šablony konfigurace
  - že ústředna nabootuje, dialplan volá sms-queue.sh, spool je zapisovatelný
    (bez toho se opakovaný pokus o doručení nikdy nezaloží) a CDR se má kam psát
  - že ovládání nastartuje, naimportuje app.py a odpoví přihlašovací stránkou
    (OVL-LOGIN) i chybou u špatného hesla (OVL-E01)
  - že pravidla filtru projdou nft a tři stupně přístupu dávají očekávané
    řetězy tun_pre a fwd_pre; a že se filtr bez FIREWALL_INTERNAL nezapíná
  - že úložiště kontaktů nastartuje, běží pod nobody a bez hesla vrací 401
  - datová cesta výstupního uzlu ve skutečném kontejneru (forwarding, NAT,
    dostupnost /lib/modules) — tu neukáže ani laboratoř, ta jede v userspace
Zkontrolované bez dockeru bylo: tvar a shoda compose souborů, sdílený adresář
ts/, kontrakt volání nástroje ve smyčce a její vlastní test, klient
koordinátoru v ovládání, syntaxe skriptů a pythonu v repu, dělení kontaktů
a kalendáře a zákaz názvů technologií ve veřejných textech.
Podle docs/release.md se bez ÚPLNÉHO zeleného běhu netaguje — pusť tenhle
skript na stroji s dockerem.
TXT
fi

[ "$FAIL" -eq 0 ] || exit 1
[ "$SKIP_DOCKER" -eq 0 ] || exit 2
exit 0
