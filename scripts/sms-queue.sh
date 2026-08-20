#!/bin/sh
# Phone21 — žurnál a retry fronta příchozích SMS
#
# Volá se z dialplanu (System() pod uživatelem asterisk v kontejneru).
# Data: /var/lib/phone21 (persistentní volume), plán: /var/spool/asterisk/
# outgoing (call files; persistentní volume — retry přežije restart).
#
#   sms-queue.sh journal <status> <b64-json>            zápis do žurnálu
#   sms-queue.sh enqueue <b64-json> <retryN> [origts]   naplánovat (další) pokus
#   sms-queue.sh done <qid>                             úklid po úspěšném retry
#   sms-queue.sh missed <číslo-E.164>                   notifikace zmeškaného
#                                                       hovoru do chatu
#
# Backoff: 60s * 2^n, strop 10 minut. Give-up podle stáří zprávy (TTL 48 h
# od přijetí) — pak zůstává v žurnálu se stavem failed-ttl. Pokus o doručení
# se navíc dělá jen když je softphone registrovaný (kontrola v dialplanu),
# takže tiky ve stropu jsou téměř zadarmo.

set -u
DATA=/var/lib/phone21
QDIR=$DATA/queue
JOURNAL=$DATA/journal.jsonl
SPOOL=/var/spool/asterisk/outgoing
TTL=172800        # 48 h
MAXDELAY=600      # strop backoffu: 10 min

mkdir -p "$QDIR" 2>/dev/null || true
# webui (jiný uživatel, jen čte) se k datům dostane přes SKUPINU 65534 —
# adresáře mají setgid (2750, nastavuje entrypoint), takže nové soubory
# skupinu dědí a stačí jim group-read. POZOR: chmod adresářů smí jen root —
# chmod ne-root vlastníkem, který není ve skupině 65534, setgid bit MAŽE
# (ověřeno) a tím rozbije dědění skupiny pro všechny další soubory.
if [ "$(id -u)" = "0" ]; then
  chgrp 65534 "$DATA" "$QDIR" 2>/dev/null || true
  chmod 2750 "$DATA" "$QDIR" 2>/dev/null || true
fi

now_iso() { date -Is; }

journal() { # $1 status, $2 b64
  printf '{"t":"%s","status":"%s","sms_b64":"%s"}\n' "$(now_iso)" "$1" "$2" >> "$JOURNAL"
  chmod 0640 "$JOURNAL" 2>/dev/null || true
}

case "${1:-}" in
  journal)
    journal "$2" "$3"
    ;;

  enqueue)
    b64="$2"; n="${3:-0}"
    now="$(date +%s)"
    origts="${4:-$now}"
    if [ $(( now - origts )) -ge "$TTL" ]; then
      journal "failed-ttl" "$b64"
      exit 0
    fi
    qid="$(date +%s%N)"
    printf '%s' "$b64" > "$QDIR/$qid.b64"
    chmod 0640 "$QDIR/$qid.b64" 2>/dev/null || true
    shift_n=$n; [ "$shift_n" -gt 10 ] && shift_n=10
    delay=$(( 60 * (1 << shift_n) ))
    [ "$delay" -gt "$MAXDELAY" ] && delay=$MAXDELAY
    when=$(( now + delay ))
    # Tmp soubor NESMÍ vzniknout přímo ve spool adresáři — musí se do něj
    # přesunout hotový (viz NOTBEFORE pojistka v dialplanu). Neměnit.
    # 777, protože skript běží střídavě pod root (docker exec, testy) a pod
    # asterisk (System() z dialplanu) — bez toho adresář založený rootem
    # zablokuje zápisy asteriska a call file tiše nevznikne.
    mkdir -p "$SPOOL/.tmp" 2>/dev/null || true
    chmod 777 "$SPOOL/.tmp" 2>/dev/null || true
    tmp="$SPOOL/.tmp/$qid"
    {
      echo "Channel: Local/smsretry@quectel-incoming"
      echo "Application: Wait"
      echo "Data: 1"
      echo "MaxRetries: 0"
      echo "Setvar: QID=$qid"
      echo "Setvar: RETRYN=$(( n + 1 ))"
      echo "Setvar: ORIGTS=$origts"
      echo "Setvar: NOTBEFORE=$when"
    } > "$tmp"
    touch -d "@$when" "$tmp"
    mv "$tmp" "$SPOOL/$qid.call"   # rename na stejném fs = atomické
    if [ -e "$SPOOL/$qid.call" ]; then
      journal "queued-retry$(( n + 1 ))-in${delay}s" "$b64"
    else
      # Zápis call file selhal (práva/disk) — bez tohohle záznamu by zpráva
      # osiřela v queue/ a nikdo by se to nedozvěděl (viditelné ve web UI).
      journal "failed-spool-write" "$b64"
    fi
    ;;

  done)
    qid="$(printf '%s' "$2" | tr -cd '0-9')"
    rm -f "$QDIR/$qid.b64"
    ;;

  missed)
    # Zmeškaný hovor při offline telefonu. JSON se skládá tady, ne v dialplanu
    # (Set() neumí hodnotu s čárkami), a má stejný tvar jako příchozí SMS
    # {from, ts, msg} — doručení, retry, žurnál i web UI ho zpracují beze
    # změny; "type" navíc pro budoucí rozlišení. Zpráva jde „od volajícího",
    # takže v Linphone přistane ve vlákně jeho čísla. Čas v textu je čas
    # POKUSU o hovor (TZ kontejneru), doručí se se zpožděním až po registraci.
    num="$(printf '%s' "$2" | tr -cd '+0-9')"
    [ -n "$num" ] || exit 0
    now="$(date +%s)"
    hhmm="$(date +%H:%M)"
    json="$(printf '{"from":"%s","ts":%s,"msg":"Zmeškaný hovor v %s","type":"missed"}' "$num" "$now" "$hhmm")"
    b64="$(printf '%s' "$json" | base64 | tr -d '\n')"
    journal "missed-call" "$b64"
    "$0" enqueue "$b64" 0 "$now"
    ;;

  *)
    echo "usage: $0 journal|enqueue|done ..." >&2
    exit 2
    ;;
esac
exit 0
