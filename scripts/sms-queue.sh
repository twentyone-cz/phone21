#!/bin/sh
# GSM2SIP — žurnál a retry fronta příchozích SMS
#
# Volá se z dialplanu (System() pod uživatelem asterisk v kontejneru).
# Data: /var/lib/gsm2sip (persistentní volume), plán: /var/spool/asterisk/
# outgoing (call files; persistentní volume — retry přežije restart).
#
#   sms-queue.sh journal <status> <b64-json>     zápis do žurnálu
#   sms-queue.sh enqueue <b64-json> <retryN>     naplánovat (další) pokus
#   sms-queue.sh done <qid>                      úklid po úspěšném retry
#
# Backoff: 60s * 2^min(n,5)  (60s..32min), give-up po 10. pokusu (~3,5 h) —
# zpráva pak zůstává v žurnálu se stavem failed.

set -u
DATA=/var/lib/gsm2sip
QDIR=$DATA/queue
JOURNAL=$DATA/journal.jsonl
SPOOL=/var/spool/asterisk/outgoing
MAXRETRY=10

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
    if [ "$n" -ge "$MAXRETRY" ]; then
      journal "failed-giveup" "$b64"
      exit 0
    fi
    qid="$(date +%s%N)"
    printf '%s' "$b64" > "$QDIR/$qid.b64"
    shift_n=$n; [ "$shift_n" -gt 5 ] && shift_n=5
    delay=$(( 60 * (1 << shift_n) ))
    when=$(( $(date +%s) + delay ))
    tmp="$SPOOL/.tmp.$qid"
    {
      echo "Channel: Local/smsretry@quectel-incoming"
      echo "Application: Wait"
      echo "Data: 1"
      echo "MaxRetries: 0"
      echo "Setvar: QID=$qid"
      echo "Setvar: RETRYN=$(( n + 1 ))"
    } > "$tmp"
    touch -d "@$when" "$tmp"
    mv "$tmp" "$SPOOL/$qid.call"   # rename na stejném fs = atomické
    journal "queued-retry$(( n + 1 ))-in${delay}s" "$b64"
    ;;

  done)
    qid="$(printf '%s' "$2" | tr -cd '0-9')"
    rm -f "$QDIR/$qid.b64"
    ;;

  *)
    echo "usage: $0 journal|enqueue|done ..." >&2
    exit 2
    ;;
esac
exit 0
