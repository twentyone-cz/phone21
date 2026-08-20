#!/usr/bin/env bash
# Phone21 — build a push multi-arch (amd64/arm64) obrazů pro Umbrel appku
# do GitHub Container Registry (ghcr.io).
#
# Spouštět na stroji s dockerem (LXC brány). Předpoklady:
#   - docker buildx s builderem umějícím --push (docker-container driver):
#       docker buildx create --name phone21 --driver docker-container --use
#   - qemu binfmt pro arm64 (jednorázově, registruje handlery v kernelu
#     SDÍLENÉM s Proxmox hostem):
#       docker run --privileged --rm tonistiigi/binfmt --install arm64
#   - docker login ghcr.io (PAT se scope write:packages)
#
# Použití:
#   VERSION=0.9.0 ./umbrel/build-images.sh
#
# Po pushi vypíše digesty — před publikací appky připnout v
# umbrel/phone21/docker-compose.yml (image@sha256:...).

set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REGISTRY="${REGISTRY:-ghcr.io/twentyone-cz}"
VERSION="${VERSION:?nastav VERSION, např. VERSION=0.9.0}"
PLATFORMS="linux/amd64,linux/arm64"

echo "==> ${REGISTRY}/phone21-pbx:${VERSION}"
docker buildx build \
  --platform "${PLATFORMS}" \
  --file "${REPO}/docker/Dockerfile" \
  --tag "${REGISTRY}/phone21-pbx:${VERSION}" \
  --push \
  "${REPO}"

echo "==> ${REGISTRY}/phone21-ui:${VERSION}"
docker buildx build \
  --platform "${PLATFORMS}" \
  --tag "${REGISTRY}/phone21-ui:${VERSION}" \
  --push \
  "${REPO}/webui"

echo
echo "Digesty pro připnutí v umbrel compose:"
for img in phone21-pbx phone21-ui; do
  docker buildx imagetools inspect "${REGISTRY}/${img}:${VERSION}" \
    | awk -v i="${REGISTRY}/${img}" '/^Digest:/{print i "@" $2; exit}'
done
