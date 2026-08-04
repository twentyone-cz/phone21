#!/usr/bin/env bash
# GSM2SIP — správa Qualcomm MBN carrier profilu modemu (VoLTE)
#
#   mbn-profile.sh auto              # vybrat a aktivovat profil dle operátora SIM
#   mbn-profile.sh status            # aktivní profil + stav IMS registrace
#   mbn-profile.sh list              # všechny profily ve firmwaru
#   mbn-profile.sh activate <název>  # ručně aktivovat profil podle Description
#
# Proč: mcfg autoselect vybírá profil podle SIM při každém bootu modemu;
# pro operátory bez shody (např. T-Mobile CZ) spadne na profil, se
# kterým IMS registrace neproběhne a hovory padají CSFB do 2G. `auto` vybere
# profil z tabulky OPERÁTOR→PROFIL a aktivuje ho za horka (bez resetu
# modemu, ověřeno 2026-08-04). Spouští se po bootu ze systemd
# (install-mbn.sh), protože autoselect volbu při resetu modemu vrací.
#
# Nastavení v .env brány:
#   MBN_PROFILE=auto        # default: vybrat z tabulky podle home network SIM
#   MBN_PROFILE=off         # nic neměnit (nechat autoselect)
#   MBN_PROFILE=<Description>  # vynutit konkrétní profil (viz `list`)
#
# Vyžaduje: libqmi-utils a /dev/cdc-wdm0 (na LXC: lxc.cgroup2.devices.allow
# c 180:* rwm + lxc.mount.entry /dev/cdc-wdm0 v konfiguraci kontejneru).
#
# POZOR: aktivace profilu je vratná (activate <původní>), ale NEmazat
# profily (--pdc-delete-config) — přišli bychom o ně bez možnosti návratu.

set -u
DEV="${MBN_QMI_DEV:-/dev/cdc-wdm0}"
WANT="${MBN_PROFILE:-auto}"

log() { echo "$(date -Is) $*"; }
die() { log "CHYBA: $*" >&2; exit 1; }

qmi() { timeout 20 qmicli -d "$DEV" "$@" 2>/dev/null; }

wait_qmi() {
  for _ in $(seq 1 30); do
    [[ -c "$DEV" ]] && qmi --get-service-version-info >/dev/null && return 0
    sleep 5
  done
  die "QMI zařízení $DEV neodpovídá (chybí passthrough, nebo modem nejede?)"
}

list_raw() { qmi --pdc-list-configs=software; }

active_desc() {
  list_raw | awk '/Description:/{d=$2} /Status:[ \t]*Active/{print d}'
}

id_by_desc() { # $1 = Description
  list_raw | awk -v want="$1" '/Description:/{d=$2} /ID:/{if (d==want) print $2}'
}

# Tabulka operátor (MCC-MNC home network SIM) → profil. Rozšiřovat dle
# nasazení; názvy musí odpovídat Description z `list` (firmware firmware:
# profil, profil, profil, profil,
# profil, VF_Germany/Italy/Portugal/Spain/Turkey/UK_VoLTE, ...).
profile_for_operator() {
  case "$1" in
    230-1)  echo "profil" ;;      # T-Mobile CZ (skupina DT)
    262-1)  echo "profil" ;;      # Telekom DE
    262-2)  echo "profil" ;;   # Vodafone DE
    230-3)  echo "profil" ;;   # Vodafone CZ (skupina VF — bez záruky)
    *)      echo "" ;;
  esac
}

home_network() {
  # MCC-MNC domácí sítě SIM (ne serving — roaming nemá měnit profil).
  local out mcc mnc
  out="$(qmi --nas-get-home-network)" || return 1
  mcc="$(grep -oE "MCC: '[0-9]+'" <<<"$out" | grep -oE '[0-9]+')"
  mnc="$(grep -oE "MNC: '[0-9]+'" <<<"$out" | grep -oE '[0-9]+')"
  [[ -n "$mcc" && -n "$mnc" ]] || return 1
  # normalizace bez vedoucích nul (MNC '01' vs '1')
  echo "$((10#$mcc))-$((10#$mnc))"
}

do_activate() { # $1 = cílový Description
  local target="$1" cur id cur_id
  cur="$(active_desc)"
  if [[ "$cur" == "$target" ]]; then
    log "MBN '$target' už je aktivní — nic neměním."
    return 0
  fi
  id="$(id_by_desc "$target")"
  [[ -n "$id" ]] || die "profil '$target' ve firmwaru není (viz: $0 list)"
  if [[ -n "$cur" ]]; then
    cur_id="$(id_by_desc "$cur")"
    [[ -n "$cur_id" ]] && qmi --pdc-deactivate-config="software,$cur_id" >/dev/null || true
  fi
  qmi --pdc-activate-config="software,$id" >/dev/null \
    || die "aktivace '$target' selhala"
  # ověření
  [[ "$(active_desc)" == "$target" ]] \
    || die "aktivace proběhla, ale '$target' není aktivní (zkontroluj list)"
  log "MBN '$target' aktivován (předtím: ${cur:-žádný})."
}

case "${1:-auto}" in
  list)
    wait_qmi
    list_raw | grep -E "Description|Status" | paste - -
    ;;
  status)
    wait_qmi
    echo "Aktivní profil: $(active_desc)"
    echo "Operátor SIM:   $(home_network || echo '?')"
    qmi --imsa-get-ims-registration-status || true
    ;;
  activate)
    [[ -n "${2:-}" ]] || die "použití: $0 activate <Description>"
    wait_qmi
    do_activate "$2"
    ;;
  auto)
    case "$WANT" in
      off)
        log "MBN_PROFILE=off — nechávám autoselect být."
        exit 0
        ;;
      auto)
        wait_qmi
        op="$(home_network)" || die "nezjistím operátora SIM (home network)"
        target="$(profile_for_operator "$op")"
        if [[ -z "$target" ]]; then
          log "Pro operátora $op nemám v tabulce profil — nechávám autoselect ($(active_desc))."
          exit 0
        fi
        log "Operátor $op → profil '$target'."
        do_activate "$target"
        ;;
      *)
        wait_qmi
        do_activate "$WANT"
        ;;
    esac
    ;;
  *)
    die "použití: $0 auto|status|list|activate <Description>"
    ;;
esac
