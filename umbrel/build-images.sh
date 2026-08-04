#!/usr/bin/env bash
# GSM2SIP — build a push multi-arch (amd64/arm64) obrazů pro Umbrel appku
# do Gitea container registry (it-one.cz).
#
# Spouštět na stroji s dockerem (LXC brány). Předpoklady:
#   - docker buildx s builderem umějícím --push (docker-container driver):
#       docker buildx create --name gsm2sip --driver docker-container --use
#   - qemu binfmt pro arm64 (jednorázově, registruje handlery v kernelu
#     SDÍLENÉM s Proxmox hostem):
#       docker run --privileged --rm tonistiigi/binfmt --install arm64
#   - docker login it-one.cz (účet s write:package tokenem)
#
# Použití:
#   VERSION=0.9.0 ./umbrel/build-images.sh
#
# Po pushi vypíše digesty — před publikací appky připnout v
# umbrel/eddie-gsm2sip/docker-compose.yml (image@sha256:...).

set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REGISTRY="${REGISTRY:-it-one.cz/eddie}"
VERSION="${VERSION:?nastav VERSION, např. VERSION=0.9.0}"
PLATFORMS="linux/amd64,linux/arm64"

echo "==> ${REGISTRY}/gsm2sip-asterisk:${VERSION}"
docker buildx build \
  --platform "${PLATFORMS}" \
  --file "${REPO}/docker/Dockerfile" \
  --tag "${REGISTRY}/gsm2sip-asterisk:${VERSION}" \
  --push \
  "${REPO}"

echo "==> ${REGISTRY}/gsm2sip-webui:${VERSION}"
docker buildx build \
  --platform "${PLATFORMS}" \
  --tag "${REGISTRY}/gsm2sip-webui:${VERSION}" \
  --push \
  "${REPO}/webui"

echo
echo "Digesty pro připnutí v umbrel compose:"
for img in gsm2sip-asterisk gsm2sip-webui; do
  docker buildx imagetools inspect "${REGISTRY}/${img}:${VERSION}" \
    | awk -v i="${REGISTRY}/${img}" '/^Digest:/{print i "@" $2; exit}'
done
