#!/usr/bin/env bash
#
# Phone21 — instalace automatické správy MBN carrier profilu (VoLTE).
#
#   ./install-mbn.sh             # nainstaluj systemd oneshot a hned spusť
#   ./install-mbn.sh --status    # stav služby + aktivní profil + IMS
#   ./install-mbn.sh --uninstall # vypni a odstraň
#
# Profil se volí v .env brány proměnnou MBN_PROFILE (auto|off|<název>),
# viz scripts/mbn-profile.sh. Služba běží po každém bootu.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE=/etc/systemd/system/phone21-mbn.service

die() { echo "CHYBA: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "spusť jako root"

case "${1:-}" in
  --status)
    systemctl status phone21-mbn.service --no-pager 2>/dev/null | head -8 || true
    "${REPO}/scripts/mbn-profile.sh" status || true
    exit 0
    ;;
  --uninstall)
    systemctl disable --now phone21-mbn.service 2>/dev/null || true
    rm -f "${SERVICE}"
    systemctl daemon-reload
    echo "Správa MBN profilu odstraněna (aktivní profil se nemění)."
    exit 0
    ;;
  "") ;;
  *) die "neznámý přepínač: $1" ;;
esac

command -v qmicli >/dev/null || die "chybí qmicli (apt install libqmi-utils)"
[[ -c /dev/cdc-wdm0 ]] || echo "POZOR: /dev/cdc-wdm0 teď není k dispozici — služba se nainstaluje a počká si (ExecCondition)." >&2
chmod +x "${REPO}/scripts/mbn-profile.sh"

# ExecCondition: bez QMI zařízení (bezmodemový stroj, odpojený modem) unit
# skončí jako "skipped" místo "failed" — failed by strašil v monitoringu
# u stavu, který je na bezmodemovém stroji korektní.
cat > "${SERVICE}" <<EOF
[Unit]
Description=Phone21: MBN carrier profil modemu dle operátora SIM (VoLTE)
After=network.target

[Service]
Type=oneshot
EnvironmentFile=-${REPO}/.env
ExecCondition=/usr/bin/test -c /dev/cdc-wdm0
ExecStart=${REPO}/scripts/mbn-profile.sh auto
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now phone21-mbn.service >/dev/null
echo "Správa MBN profilu nainstalována."
journalctl -u phone21-mbn.service --no-pager | tail -3
