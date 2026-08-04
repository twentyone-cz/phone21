#!/usr/bin/env bash
#
# GSM2SIP — instalace automatické správy MBN carrier profilu (VoLTE).
#
#   ./install-mbn.sh             # nainstaluj systemd oneshot a hned spusť
#   ./install-mbn.sh --status    # stav služby + aktivní profil + IMS
#   ./install-mbn.sh --uninstall # vypni a odstraň
#
# Profil se volí v .env brány proměnnou MBN_PROFILE (auto|off|<název>),
# viz scripts/mbn-profile.sh. Služba běží po každém bootu — mcfg autoselect
# při resetu modemu volbu vrací, takže ji je potřeba obnovovat.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE=/etc/systemd/system/gsm2sip-mbn.service

die() { echo "CHYBA: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "spusť jako root"

case "${1:-}" in
  --status)
    systemctl status gsm2sip-mbn.service --no-pager 2>/dev/null | head -8 || true
    "${REPO}/scripts/mbn-profile.sh" status || true
    exit 0
    ;;
  --uninstall)
    systemctl disable --now gsm2sip-mbn.service 2>/dev/null || true
    rm -f "${SERVICE}"
    systemctl daemon-reload
    echo "Správa MBN profilu odstraněna (aktivní profil se nemění)."
    exit 0
    ;;
  "") ;;
  *) die "neznámý přepínač: $1" ;;
esac

command -v qmicli >/dev/null || die "chybí qmicli (apt install libqmi-utils)"
[[ -c /dev/cdc-wdm0 ]] || die "chybí /dev/cdc-wdm0 (passthrough do LXC — viz README Fáze 2)"
chmod +x "${REPO}/scripts/mbn-profile.sh"

cat > "${SERVICE}" <<EOF
[Unit]
Description=GSM2SIP: MBN carrier profil modemu dle operátora SIM (VoLTE)
After=network.target

[Service]
Type=oneshot
EnvironmentFile=-${REPO}/.env
ExecStart=${REPO}/scripts/mbn-profile.sh auto
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now gsm2sip-mbn.service >/dev/null
echo "Správa MBN profilu nainstalována."
journalctl -u gsm2sip-mbn.service --no-pager | tail -3
