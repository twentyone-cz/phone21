#!/usr/bin/env bash
#
# GSM2SIP — nasazení firewallu brány (scripts/firewall.nft) na LXC.
#
# Firewall, který si člověk nasazuje přes SSH, má jednu spolehlivou poruchu:
# odřízne správu a není jak to vzít zpět. Proto se pravidla načtou na zkoušku
# a zároveň se ozbrojí ROLLBACK TIMER — když se do GRACE sekund nepotvrdí
# `--commit`, systemd tabulku sám smaže a přístup se vrátí. Timer běží
# v systemd, ne v téhle shellové session: přežije i to, že SSH spadne.
#
# Použití (na bráně, jako root):
#   ./install-firewall.sh            # načte pravidla + ozbrojí rollback (5 min)
#   ./install-firewall.sh --commit   # zruší rollback, zapne start při bootu
#   ./install-firewall.sh --rollback # okamžitě sundá firewall a vypne unit
#   ./install-firewall.sh --status   # co je načtené a jestli visí rollback
#
#   GRACE=600 ./install-firewall.sh  # delší okno na ověření
#
# Mezi načtením a `--commit` je potřeba OVĚŘIT, že správa žije — nová SSH
# session (ne ta stávající, tu drží conntrack jako established) a web UI.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/firewall.nft"
DST=/etc/nftables.d/gsm2sip.nft
UNIT_NAME=gsm2sip-firewall.service
UNIT=/etc/systemd/system/${UNIT_NAME}
ROLLBACK=gsm2sip-fw-rollback
GRACE="${GRACE:-300}"
NFT=/usr/sbin/nft

die() { echo "CHYBA: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "spusť jako root"
command -v "${NFT}" >/dev/null || die "nft není nainstalované (apt install nftables)"

rollback_armed() {
  systemctl list-units --all --no-legend "${ROLLBACK}.timer" 2>/dev/null | grep -q .
}

disarm() {
  systemctl stop "${ROLLBACK}.timer" 2>/dev/null || true
  systemctl reset-failed "${ROLLBACK}.timer" "${ROLLBACK}.service" 2>/dev/null || true
}

case "${1:-}" in
  --status)
    echo "=== tabulka inet gsm2sip ==="
    "${NFT}" list table inet gsm2sip 2>/dev/null || echo "(není načtená)"
    echo "=== rollback ==="
    if rollback_armed; then
      systemctl list-timers --all --no-legend "${ROLLBACK}.timer"
      echo "POZOR: rollback je ozbrojený — potvrď --commit, jinak firewall spadne."
    else
      echo "(neozbrojený)"
    fi
    echo "=== unit pro boot ==="
    systemctl is-enabled "${UNIT_NAME}" 2>/dev/null || echo "(nezapnutý)"
    exit 0
    ;;

  --rollback)
    disarm
    systemctl disable --now "${UNIT_NAME}" 2>/dev/null || true
    "${NFT}" delete table inet gsm2sip 2>/dev/null || true
    echo "Firewall sundán. Docker pravidla (ip filter/nat) zůstala nedotčená."
    exit 0
    ;;

  --commit)
    "${NFT}" list table inet gsm2sip >/dev/null 2>&1 \
      || die "tabulka inet gsm2sip není načtená — není co potvrzovat"
    disarm
    systemctl enable "${UNIT_NAME}" >/dev/null
    echo "Potvrzeno. Rollback zrušen, ${UNIT_NAME} se spustí i po rebootu."
    exit 0
    ;;

  "") ;;
  *) die "neznámý přepínač: $1 (viz hlavička skriptu)" ;;
esac

# --- Načtení na zkoušku + ozbrojení rollbacku --------------------------------

[[ -f "${SRC}" ]] || die "chybí ${SRC}"
"${NFT}" -c -f "${SRC}" || die "pravidla neprošla syntaktickou kontrolou — nic se nenačetlo"

install -d -m 755 /etc/nftables.d
install -m 644 "${SRC}" "${DST}"

cat > "${UNIT}" <<EOF
[Unit]
Description=GSM2SIP firewall (nftables, tabulka inet gsm2sip)
# Po dockeru a wg0 jen kvůli přehlednosti logů — tabulka je samostatná
# a pravidla používají iifname, takže na existenci wg0 při startu nezávisí.
After=network-pre.target docker.service wg-quick@wg0.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${NFT} -f ${DST}
ExecStop=${NFT} delete table inet gsm2sip

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

disarm
systemd-run --unit="${ROLLBACK}" --on-active="${GRACE}" \
  --timer-property=AccuracySec=1s \
  --description="GSM2SIP: automatické sundání firewallu, pokud se nepotvrdí" \
  "${NFT}" delete table inet gsm2sip >/dev/null

"${NFT}" -f "${DST}"

echo "Pravidla načtená. Rollback za ${GRACE} s, pokud nepřijde --commit."
echo
echo "Teď ověř Z JINÉ session (stávající SSH drží conntrack, takže by prošla i tak):"
echo "  ssh root@\$(hostname -I | awk '{print \$1}') true   # SSH z LAN"
echo "  curl -sI http://\$(hostname -I | awk '{print \$1}'):8090/   # web UI"
echo "Pak: $0 --commit"
