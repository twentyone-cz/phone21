#!/usr/bin/env bash
#
# GSM2SIP — nasazení na vývojovou bránu (spouští se PŘÍMO na ní, v kořeni repa).
#
#   ./scripts/dev-deploy.sh [ref]     # default: origin/main
#
# Nahrazuje dřívější ruční kopírování souborů (tar-over-ssh), po kterém se
# nedalo zjistit, co na bráně vlastně běží. Teď je zdrojem pravdy git:
# fetch → checkout -f → build → configure --force → force-recreate.
#
# .env a runtime/ jsou gitignored a checkout je nechává na pokoji.

set -euo pipefail

REF="${1:-origin/main}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"

die() { echo "CHYBA: $*" >&2; exit 1; }

git rev-parse --git-dir >/dev/null 2>&1 || die "${REPO} není git repo — nejdřív ho převeď (git init + remote + fetch)"
[[ -f .env ]] || die "chybí .env (cp .env.example .env a doplň)"

echo "== fetch + checkout ${REF} =="
git fetch --all --tags
git checkout -f "${REF}"
echo "== stav: $(git log --oneline -1) =="

echo "== build obrazů =="
docker compose build

echo "== render konfigurace (--force) =="
./configure.sh --force

echo "== restart stacku =="
# tailscale overlay se přidá, jen pokud existuje (dev bez tunelu ho nemá mít)
COMPOSE_FILES=(-f docker-compose.yml)
[[ -f runtime/smsdata/ts/.enabled || -d runtime/ts-state ]] && \
  COMPOSE_FILES+=(-f docker-compose.tailscale.yml)
docker compose "${COMPOSE_FILES[@]}" up -d --force-recreate

echo "== výsledek =="
docker ps --format '{{.Names}}\t{{.Status}}'
sleep 3
docker logs asterisk --tail 15 2>&1 | sed 's/^/[asterisk] /' || true
docker logs gsm2sip-webui --tail 5 2>&1 | sed 's/^/[webui] /' || true
