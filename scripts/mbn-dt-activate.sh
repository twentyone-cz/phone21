#!/usr/bin/env bash
# GSM2SIP — po startu aktivuje MBN profil profil (VoLTE pokus, 2026-08)
#
# Qualcomm mcfg autoselect při každém bootu modemu vybere profil podle SIM;
# pro T-Mobile CZ nemá shodu a spadne na profil (s ním IMS registrace
# neprobíhá). Tenhle skript po startu LXC přepne na profil (matka DT
# = nejbližší profil pro TMCZ). Přepnutí je za horka (bez resetu modemu) —
# ověřeno, že MBN se aplikuje (UTAPNCFG se změní).
#
# Instalace (na LXC):
#   cp scripts/gsm2sip-mbn.service /etc/systemd/system/
#   systemctl daemon-reload && systemctl enable --now gsm2sip-mbn.service
#
# Vyžaduje: libqmi-utils, /dev/cdc-wdm0 (lxc.mount.entry + devices.allow c 180:*).

set -u
DEV=/dev/cdc-wdm0
DT="74:FB:CA:32:F4:48:A9:84:46:68:92:E8:BE:3F:9E:16:04:7E:8D:70"
ROW="90:F9:B1:2D:BD:2A:8C:8F:6D:65:41:F4:D7:74:2D:F8:D9:D7:81:25"

# Počkat na QMI (modem po bootu chvíli nabíhá)
for i in $(seq 1 30); do
  [ -c "$DEV" ] && timeout 5 qmicli -d "$DEV" --get-service-version-info >/dev/null 2>&1 && break
  sleep 5
done

active="$(timeout 20 qmicli -d "$DEV" --pdc-list-configs=software 2>/dev/null \
  | grep -B4 'Status:      Active' | grep -oE 'Description: .*' | awk '{print $2}')"
if [ "$active" = "profil" ]; then
  echo "MBN profil už aktivní — nic nedělám."
  exit 0
fi

timeout 15 qmicli -d "$DEV" --pdc-deactivate-config="software,$ROW" 2>/dev/null || true
timeout 15 qmicli -d "$DEV" --pdc-activate-config="software,$DT"
echo "MBN profil aktivován (předtím: ${active:-neznámý})."
