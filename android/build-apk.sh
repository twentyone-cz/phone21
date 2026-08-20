#!/usr/bin/env bash
# Phone21 — build podepsaného APK. Spouštět na build stroji (docker + image
# phone21-android-build z android/Dockerfile.build).
#
#   ./android/build-apk.sh            # release, podepsaný
#   DEBUG=1 ./android/build-apk.sh    # debug build bez podpisu
#
# Podpisový klíč leží MIMO repo (KEYSTORE_DIR). Bez něj by šlo appku sice
# postavit, ale uživatel by si další verzi nemohl nainstalovat přes tu
# stávající — Android to bere jako jinou aplikaci.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYSTORE_DIR="${KEYSTORE_DIR:-/root/android-keystore}"
IMAGE="${IMAGE:-phone21-android-build}"

if [[ "${DEBUG:-0}" == "1" ]]; then
  docker run --rm -v "$REPO/android/dialer:/src" -v gradle-cache:/root/.gradle \
    "$IMAGE" gradle assembleDebug
  echo "APK: android/dialer/app/build/outputs/apk/debug/app-debug.apk"
  exit 0
fi

[[ -f "$KEYSTORE_DIR/jednadvacet.jks" ]] \
  || { echo "CHYBA: chybí $KEYSTORE_DIR/jednadvacet.jks" >&2; exit 1; }
# shellcheck disable=SC1091
source "$KEYSTORE_DIR/keystore.env"

docker run --rm \
  -v "$REPO/android/dialer:/src" \
  -v gradle-cache:/root/.gradle \
  -v "$KEYSTORE_DIR:/keystore:ro" \
  -e PHONE21_KEYSTORE=/keystore/jednadvacet.jks \
  -e PHONE21_KEYSTORE_PASSWORD="$KEYSTORE_PASSWORD" \
  -e PHONE21_KEY_ALIAS="$KEY_ALIAS" \
  "$IMAGE" gradle assembleRelease

APK="$REPO/android/dialer/app/build/outputs/apk/release/app-release.apk"
docker run --rm -v "$REPO/android/dialer:/src" "$IMAGE" \
  sh -c '$ANDROID_SDK_ROOT/build-tools/34.0.0/apksigner verify --print-certs \
    /src/app/build/outputs/apk/release/app-release.apk' | head -4
echo "APK: $APK"
