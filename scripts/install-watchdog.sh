#!/usr/bin/env bash
#
# GSM2SIP — instalace watchdogu modemu (systemd timer).
#
#   ./install-watchdog.sh             # nainstaluj a spusť
#   ./install-watchdog.sh --status    # stav timeru + poslední zásahy
#   ./install-watchdog.sh --uninstall # vypni a odstraň
#
# Interval a prahy se dají přenastavit v .env brány (čte je systemd unit):
#   WATCHDOG_INTERVAL=30    sekundy mezi kontrolami
#   FAIL_THRESHOLD=3        kolik neúspěchů v řadě před restartem
#   COOLDOWN=600            minimální odstup mezi restarty

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE=/etc/systemd/system/gsm2sip-watchdog.service
TIMER=/etc/systemd/system/gsm2sip-watchdog.timer
INTERVAL="${WATCHDOG_INTERVAL:-30}"

die() { echo "CHYBA: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "spusť jako root"

case "${1:-}" in
  --status)
    systemctl status gsm2sip-watchdog.timer --no-pager 2>/dev/null | head -8 || true
    echo "=== poslední kontrola (bez zásahu) ==="
    "${REPO}/scripts/watchdog.sh" --check || true
    echo "=== posledních 10 záznamů ==="
    tail -10 "${REPO}/runtime/smsdata/watchdog.log" 2>/dev/null || echo "(zatím nic — watchdog nikdy nezasáhl)"
    exit 0
    ;;
  --uninstall)
    systemctl disable --now gsm2sip-watchdog.timer 2>/dev/null || true
    rm -f "${SERVICE}" "${TIMER}"
    systemctl daemon-reload
    echo "Watchdog odstraněn."
    exit 0
    ;;
  "") ;;
  *) die "neznámý přepínač: $1" ;;
esac

[[ -x "${REPO}/scripts/watchdog.sh" ]] || chmod +x "${REPO}/scripts/watchdog.sh"

cat > "${SERVICE}" <<EOF
[Unit]
Description=GSM2SIP watchdog modemu (restart kontejneru při zaseknutí driveru)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
# Prahy jdou přenastavit v .env brány; EnvironmentFile je volitelný (-).
EnvironmentFile=-${REPO}/.env
ExecStart=${REPO}/scripts/watchdog.sh
EOF

cat > "${TIMER}" <<EOF
[Unit]
Description=GSM2SIP watchdog modemu — spouštění po ${INTERVAL} s

[Timer]
# Po bootu se nespěchá: Asterisk potřebuje chvíli na inicializaci modemu
# a watchdog by ho jinak počítal jako nezdravého hned po startu.
OnBootSec=3min
OnUnitActiveSec=${INTERVAL}s
AccuracySec=5s
Unit=gsm2sip-watchdog.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now gsm2sip-watchdog.timer >/dev/null
echo "Watchdog nainstalován, kontrola po ${INTERVAL} s."
systemctl list-timers --no-legend gsm2sip-watchdog.timer
