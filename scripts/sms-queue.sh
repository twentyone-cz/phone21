#!/bin/sh
# GSM2SIP — žurnál a retry fronta příchozích SMS
#
# Volá se z dialplanu (System() pod uživatelem asterisk v kontejneru).
# Data: /var/lib/gsm2sip (persistentní volume), plán: /var/spool/asterisk/
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
DATA=/var/lib/gsm2sip
QDIR=$DATA/queue
JOURNAL=$DATA/journal.jsonl
SPOOL=/var/spool/asterisk/outgoing
TTL=172800        # 48 h
MAXDELAY=600      # strop backoffu: 10 min

mkdir -p "$QDIR" 2>/dev/null || true

now_iso() { date -Is; }

journal() { # $1 status, $2 b64
  printf '{"t":"%s","status":"%s","sms_b64":"%s"}\n' "$(now_iso)" "$1" "$2" >> "$JOURNAL"
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
    shift_n=$n; [ "$shift_n" -gt 10 ] && shift_n=10
    delay=$(( 60 * (1 << shift_n) ))
    [ "$delay" -gt "$MAXDELAY" ] && delay=$MAXDELAY
    when=$(( now + delay ))
    tmp="$SPOOL/.tmp.$qid"
    {
      echo "Channel: Local/smsretry@quectel-incoming"
      echo "Application: Wait"
      echo "Data: 1"
      echo "MaxRetries: 0"
      echo "Setvar: QID=$qid"
      echo "Setvar: RETRYN=$(( n + 1 ))"
      echo "Setvar: ORIGTS=$origts"
    } > "$tmp"
    touch -d "@$when" "$tmp"
    mv "$tmp" "$SPOOL/$qid.call"   # rename na stejném fs = atomické
    journal "queued-retry$(( n + 1 ))-in${delay}s" "$b64"
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
