#!/usr/bin/env bash
#
# Phone21 — nasazení na vývojovou bránu (spouští se PŘÍMO na ní, v kořeni repa).
#
#   ./scripts/dev-deploy.sh [ref]     # default: origin/main
#   P21_TS=1 ./scripts/dev-deploy.sh  # i s privátní sítí (overlay)
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
# Overlay privátní sítě se přidá na výslovné přání: P21_TS=1.
# Dřív se hádal podle runtime/ts-state (ten ale vzniká až prvním během
# overlaye) a podle runtime/smsdata/ts/.enabled, který nikdo nezakládá —
# na čisté bráně se tedy nezapnul nikdy. Kvůli už běžícím nasazením se
# existující adresář stavu bere dál jako „zapnuto“.
COMPOSE_FILES=(-f docker-compose.yml)
# bez proměnné rozhoduje běžící stav, s proměnnou rozhoduje proměnná
# (P21_TS=0 tedy overlay vypne i na bráně, kde už jednou jel)
[[ -n "${P21_TS:-}" || ! -d runtime/ts-state ]] || P21_TS=1
P21_TS="${P21_TS:-0}"
if [[ "$P21_TS" == "1" ]]; then
  COMPOSE_FILES+=(-f docker-compose.tailscale.yml)
  echo "-- s privátní sítí (P21_TS=1)"
else
  echo "-- bez privátní sítě (zapneš ji P21_TS=1)"
fi
docker compose "${COMPOSE_FILES[@]}" up -d --force-recreate

echo "== výsledek =="
docker ps --format '{{.Names}}\t{{.Status}}'
sleep 3
docker logs phone21-pbx --tail 15 2>&1 | sed 's/^/[ustredna] /' || true
docker logs phone21-ui --tail 5 2>&1 | sed 's/^/[webui] /' || true
