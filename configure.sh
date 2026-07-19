#!/usr/bin/env bash
# GSM2SIP — vygeneruje runtime konfiguraci Asterisku z šablon + .env
#
# Proč: umbreld při updatu appky přepisuje obsah adresáře appky, a hesla
# nesmí do gitu. Konfigurace se proto JEDNOU vygeneruje do runtime adresáře
# (mimo repo / v app-data) a dál se nechává být.
#
# Použití:
#   ./configure.sh              # vygeneruje do ${ASTERISK_CONF_DIR:-./runtime/asterisk}
#   ./configure.sh --force      # přegeneruje i existující (přepíše ruční změny!)
#
# Idempotentní: existující neprázdný cíl bez --force nechá být.
# Žádné závislosti mimo bash/sed/docker (docker jen volitelně na seed).

set -euo pipefail
cd "$(dirname "$0")"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

# --- .env --------------------------------------------------------------------
if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 600 .env
  echo "CHYBA: .env neexistoval — vytvořen z .env.example." >&2
  echo "Doplň SIP_USER a SIP_PASSWORD a spusť configure.sh znovu." >&2
  exit 1
fi
# shellcheck disable=SC1091
source .env

: "${SIP_USER:?V .env chybí SIP_USER}"
: "${SIP_PASSWORD:?V .env chybí SIP_PASSWORD}"
if ! [[ "${SIP_USER}" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "CHYBA: SIP_USER smí obsahovat jen A-Za-z0-9_- (jde do názvů pjsip sekcí a dialplanu)." >&2
  exit 1
fi
if [[ "${SIP_PASSWORD}" == "change-me"* || ${#SIP_PASSWORD} -lt 16 ]]; then
  echo "CHYBA: SIP_PASSWORD je placeholder nebo kratší než 16 znaků." >&2
  echo "Vygeneruj silné heslo, např.: openssl rand -base64 24" >&2
  exit 1
fi

TARGET="${ASTERISK_CONF_DIR:-./runtime/asterisk}"

# --- Idempotence ---------------------------------------------------------------
# Marker .generated vzniká až po úspěšném doběhnutí — nedoběhlý běh se nedá
# omylem považovat za hotovou konfiguraci.
MARKER="${TARGET}/.generated"
if [[ ${FORCE} -ne 1 && -e "${MARKER}" ]]; then
  echo "OK: ${TARGET} už je vygenerovaný — nechávám být (přegenerování: --force)."
  exit 0
fi
if [[ ${FORCE} -ne 1 && -d "${TARGET}" && -n "$(ls -A "${TARGET}" 2>/dev/null)" ]]; then
  echo "CHYBA: ${TARGET} není prázdný, ale chybí marker ${MARKER}." >&2
  echo "Buď je to nedoběhlý configure.sh (smaž adresář a spusť znovu, nebo --force)," >&2
  echo "nebo ruční konfigurace (pak vytvoř prázdný soubor ${MARKER})." >&2
  exit 1
fi
mkdir -p "${TARGET}"

# Předchozí generace mohla soubory chownout na UID asteriska (viz Práva níže)
# — před přegenerováním si vlastnictví vezmeme zpět, jinak render spadne
# na Permission denied.
if [[ -n "$(ls -A "${TARGET}" 2>/dev/null)" && ! -w "${TARGET}/pjsip.conf" ]]; then
  sudo chown -R "$(id -u):$(id -g)" "${TARGET}"
  chmod -R u+w "${TARGET}"
fi

# --- Seed z image (volitelně) --------------------------------------------------
# Základ /etc/asterisk z image zachová konfiguraci, se kterou je image laděný;
# naše šablony se položí přes něj. Bez dockeru se použije jen minimální sada
# šablon (funguje taky — chybějící .conf = defaulty Asterisku).
# Stejný default jako v docker-compose.yml; override přes ASTERISK_IMAGE v .env.
IMAGE="${ASTERISK_IMAGE:-gsm2sip-asterisk:local}"
DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
  if sudo docker info >/dev/null 2>&1; then DOCKER="sudo docker"; else DOCKER=""; fi
fi
if [[ -n "${DOCKER}" ]]; then
  echo "Seed /etc/asterisk z image ${IMAGE}..."
  if cid=$(${DOCKER} create "${IMAGE}") && ${DOCKER} cp "${cid}:/etc/asterisk/." "${TARGET}/"; then
    # docker cp přes sudo vytváří root-owned soubory — render (běžný uživatel)
    # by na nich spadl s EACCES; vrátit vlastnictví hned:
    if [[ "${DOCKER}" == sudo* ]]; then
      sudo chown -R "$(id -u):$(id -g)" "${TARGET}"
    fi
  else
    echo "POZOR: seed z image selhal — pokračuji jen s minimální sadou šablon." >&2
  fi
  [[ -n "${cid:-}" ]] && ${DOCKER} rm "${cid}" >/dev/null 2>&1 || true
else
  echo "POZN: docker nedostupný — přeskakuji seed, použije se jen minimální sada šablon."
fi

# --- Render šablon -------------------------------------------------------------
# Nahrazuje se VÝHRADNĚ ${SIP_USER} a ${SIP_PASSWORD} (sed, literal tokeny) —
# asteriskové proměnné (${EXTEN}, ${CALLERID(...)}) zůstávají netknuté.
# Escapování znaků, které mají v sed replacement význam (\, &, |):
esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }
SIP_USER_ESC="$(esc "${SIP_USER}")"
SIP_PASSWORD_ESC="$(esc "${SIP_PASSWORD}")"
for f in asterisk/*.conf; do
  base="$(basename "$f")"
  sed -e "s|\${SIP_USER}|${SIP_USER_ESC}|g" \
      -e "s|\${SIP_PASSWORD}|${SIP_PASSWORD_ESC}|g" \
      "$f" > "${TARGET}/${base}"
done

touch "${MARKER}"   # render doběhl celý — od teď je konfigurace „hotová"

# --- Práva ---------------------------------------------------------------------
# Asterisk v kontejneru neběží jako root a jeho UID neznáme předem — zkusíme ho
# zjistit z image a runtime adresář mu chownout (pak stačí 750/640). Když to
# nejde (docker chybí), zůstane čitelnost pro všechny a tajemství chrání .env
# (600) + fyzický přístup k boxu.
ast_uid=""
if [[ -n "${DOCKER}" ]]; then
  ast_uid=$(${DOCKER} run --rm --entrypoint id "${IMAGE}" -u asterisk 2>/dev/null | tr -d '[:space:]') || true
fi
if [[ "${ast_uid}" =~ ^[0-9]+$ ]]; then
  # chmod před chownem (po chownu už nejsme vlastník); group zůstává náš,
  # takže konfigurace jde číst i bez sudo.
  chmod 750 "${TARGET}" && chmod 640 "${TARGET}"/*.conf
  if ! sudo chown -R "${ast_uid}" "${TARGET}" 2>/dev/null; then
    chmod 755 "${TARGET}" && chmod 644 "${TARGET}"/*.conf
  fi
else
  chmod 755 "${TARGET}" && chmod 644 "${TARGET}"/*.conf
fi

echo "OK: konfigurace vygenerována do ${TARGET}."
echo "Start brány: sudo docker compose up -d"
