#!/usr/bin/env bash
set -u
LOG=/home/adrianl/npm/data/logs/proxy-host-12_access.log
RHEA=adrianl@144.31.203.197
PORT=4853
TO=zmey.1123r@mail.ru

exec 9>/var/tmp/webstat-mail.lock
flock -n 9 || exit 0

ssh -o BatchMode=yes -p "$PORT" "$RHEA" "sudo -n SKIP_MAIL=1 /usr/local/bin/webstat.sh $LOG" > /tmp/webstat-out.txt 2>&1
scp -q -o BatchMode=yes -P "$PORT" "$RHEA:/var/tmp/webstat/report.last" /tmp/webstat-report.txt 2>/dev/null

[[ -s /tmp/webstat-report.txt ]] || exit 0
SUBJECT="webstat Nyx<-Rhea: $(head -1 /tmp/webstat-report.txt | sed 's/Период: //')"
mail -s "$SUBJECT" -r adel_gataullin@list.ru "$TO" < /tmp/webstat-report.txt
