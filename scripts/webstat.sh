#!/usr/bin/env bash
set -uo pipefail

LOG_FILE="${1:-/var/log/nginx/access.log}"
STATE_DIR="${STATE_DIR:-/var/tmp/webstat}"
STATE_FILE="$STATE_DIR/last_run"
REPORT_FILE="$STATE_DIR/report.tmp"
LOCK_FILE="$STATE_DIR/webstat.lock"
MAIL_TO="${MAIL_TO:-adel_gataullin@list.ru}"
MAIL_FROM="${MAIL_FROM:-webstat@$(hostname -s)}"

log()  { echo "[$(date '+%F %T')] $*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

acquire_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log "экземпляр уже запущен, выходим"
        exit 0
    fi
}

cleanup() {
    rm -f "$REPORT_FILE"
    [[ -n "${last_epoch:-}" ]] && echo "$last_epoch" > "$STATE_FILE"
}
trap cleanup EXIT

to_epoch() {
    date -d "$(echo "$1" | sed -E 's#/([A-Za-z]{3})/#/\1/#; s#^([0-9]{2})/#\1/#' | sed 's#/# #; s#/# #; s#:# #' 2>/dev/null)" +%s 2>/dev/null
}

# date -d не понимает "14/Aug/2019:04:12:10 +0300" напрямую
ts2epoch() {
    local raw="$1"
    date -d "$(sed -E 's#([0-9]{2})/([A-Za-z]{3})/([0-9]{4}):(.*)#\2 \1 \3 \4#' <<<"$raw")" +%s
}

find_log() {
    [[ -r "$LOG_FILE" ]] || LOG_FILE=$(find /var/log/nginx /var/log -maxdepth 2 -name '*access*.log*' -newer "$STATE_FILE" -type f 2>/dev/null | head -1)
    [[ -n "$LOG_FILE" && -r "$LOG_FILE" ]] || die "лог не найден"
}

is_npm() { [[ "$1" =~ ^\[[0-9]{2}/[A-Za-z]{3}/[0-9]{4} ]]; }
parse_status() {
    if is_npm "$1"; then
        awk -F' ' '{for(i=3;i<=6;i++) if($i ~ /^[0-9]{3}$/){print $i; exit}}' <<<"$1"
    else
        sed -E 's/^[^"]*"[^"]*" ([0-9]{3}) .*/\1/' <<<"$1"
    fi
}
parse_ip() {
    if is_npm "$1"; then
        sed -n 's/.*\[Client \([^]]*\)\].*/\1/p' <<<"$1"
    else
        awk '{print $1}' <<<"$1"
    fi
}
parse_url() {
    if is_npm "$1"; then
        sed -n 's/.*[A-Z]\+ \(http\|https\) [^ ]* "\([^"]*\)".*/\2/p' <<<"$1" | sed 's/?.*//'
    else
        sed -n 's/^[^"]*"[A-Z]\+ \([^ ?]*\).*".*/\1/p' <<<"$1"
    fi
}

build_report() {
    local since_epoch=$1 now_epoch=$2
    local window=() line ts code
    while IFS= read -r line; do
        ts=$(sed -n 's/^[^[]*\[\([^]]*\)\].*/\1/p' <<<"$line")
        [[ -n "$ts" ]] || continue
        ts=$(ts2epoch "$ts") || continue
        (( ts >= since_epoch && ts < now_epoch )) && window+=("$line")
    done < "$LOG_FILE"

    [[ ${#window[@]} -eq 0 ]] && { echo "С момента прошлого запуска новых запросов нет."; return 1; }

    local first last
    first=$(sed -n 's/^[^[]*\[\([^]]*\)\].*/\1/p' <<<"${window[0]}")
    last=$(sed -n 's/^[^[]*\[\([^]]*\)\].*/\1/p' <<<"${window[-1]}")

    {
        echo "Период: $first — $last"
        echo "Запросов за период: ${#window[@]}"
        echo
        echo "== Топ IP-адресов =="
        for line in "${window[@]}"; do parse_ip "$line"; done | sort | uniq -c | sort -rn | head -5
        echo
        echo "== Топ URL =="
        for line in "${window[@]}"; do parse_url "$line"; done | sort | uniq -c | sort -rn | head -5
        echo
        echo "== HTTP-коды ответов =="
        for line in "${window[@]}"; do parse_status "$line"; done | sort | uniq -c | sort -rn
        echo
        echo "== Ошибки (4xx/5xx) =="
        local err=0
        for line in "${window[@]}"; do
            code=$(parse_status "$line")
            [[ "$code" =~ ^[45] ]] && { echo "$code ${line:0:120}"; err=$((err+1)); }
        done
        (( err == 0 )) && echo "ошибок нет"
        return 0
    } > "$REPORT_FILE"
}

send_report() {
    local subject
    subject="webstat $(hostname -s): $(sed -n 's/^Период: //p' "$REPORT_FILE" | head -1)"
    if [[ "${SKIP_MAIL:-0}" == "1" ]]; then
        log "SKIP_MAIL=1, отчёт только сохраняется"
        cp "$REPORT_FILE" "$STATE_DIR/report.last"
    elif mail -s "$subject" -r "$MAIL_FROM" "$MAIL_TO" < "$REPORT_FILE" 2>/dev/null; then
        log "отчёт отправлен на $MAIL_TO"
    else
        log "mail недоступен, отчёт сохранён в $REPORT_FILE"
        cp "$REPORT_FILE" "$STATE_DIR/report.last"
    fi
}

main() {
    mkdir -p "$STATE_DIR"
    acquire_lock
    find_log
    local since=0 now
    now=$(date +%s)
    [[ -r "$STATE_FILE" ]] && since=$(<"$STATE_FILE")
    build_report "$since" "$now" || exit 0
    last_epoch=$now
    cat "$REPORT_FILE" >&2
    send_report
}

main "$@"