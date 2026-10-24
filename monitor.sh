#!/usr/bin/env bash
# monitor.sh - サーバー異常の軽量検知と Webhook 通知
# 使い方: root で bash monitor.sh [--dry-run] [--test-notify]

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

COBACO_CONFIG_DIR="/root/cobaco_config"
MONITOR_CONFIG="${COBACO_CONFIG_DIR}/monitor.yml"
STATE_DIR="/var/lib/cobaco/monitor"
STATE_FILE="${STATE_DIR}/state"
JOURNAL_CURSOR="${STATE_DIR}/journal.cursor"
LOG_FILE="/var/log/cobaco/monitor.log"
HOST_LABEL="$(hostname -s 2>/dev/null || hostname)"

DRY_RUN=false
TEST_NOTIFY=false
PHP_FPM_SERVICES=(php7.3-fpm php7.4-fpm php8.2-fpm php8.3-fpm php8.5-fpm)

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --test-notify) TEST_NOTIFY=true ;;
        -h|--help)
            echo "Usage: monitor.sh [--dry-run] [--test-notify]"
            exit 0
            ;;
        *)
            error "不明な引数: $arg"
            exit 1
            ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    error "このスクリプトは root で実行してください。"
    exit 1
fi

if ! command -v yq &>/dev/null; then
    error "yq が見つかりません。"
    exit 1
fi

if [[ ! -f "$MONITOR_CONFIG" ]]; then
    error "設定がありません: ${MONITOR_CONFIG}"
    exit 1
fi

log_line() {
    local msg="$1"
    local ts
    ts="$(date -Iseconds)"
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "${ts} ${msg}" >> "$LOG_FILE"
}

cfg() {
    yq -r "$1" "$MONITOR_CONFIG"
}

WEBHOOK_URL="$(cfg '.webhook.url // ""')"
WEBHOOK_FORMAT="$(cfg '.webhook.format // "slack"')"

truncate_message() {
    local msg="$1"
    if ((${#msg} > 2000)); then
        msg="${msg:0:1997}..."
    fi
    printf '%s' "$msg"
}

json_field_payload() {
    local field="$1"
    local body="$2"
    printf '%s' "$body" | python3 -c 'import json,sys; k=sys.argv[1]; print(json.dumps({k: sys.stdin.read()}))' "$field"
}

send_webhook() {
    local body="$1"
    body="$(truncate_message "$body")"

    if [[ "$DRY_RUN" == true ]]; then
        echo "--- notify ---"
        echo "$body"
        echo "--------------"
        return 0
    fi

    local curl_args=(-fsS --max-time 15 -X POST)
    local payload=""

    case "$WEBHOOK_FORMAT" in
        slack)
            payload="$(json_field_payload text "$body")"
            curl_args+=(-H "Content-Type: application/json" -d "$payload")
            ;;
        discord)
            payload="$(json_field_payload content "$body")"
            curl_args+=(-H "Content-Type: application/json" -d "$payload")
            ;;
        ntfy)
            local title
            title="$(printf '%s' "$body" | head -n1)"
            curl_args+=(-H "Title: ${title}" -d "$body")
            ;;
        *)
            error "不明な webhook.format: ${WEBHOOK_FORMAT}"
            return 1
            ;;
    esac

    if ! curl "${curl_args[@]}" "$WEBHOOK_URL" >/dev/null 2>&1; then
        warn "Webhook 送信に失敗しました"
        log_line "webhook_failed ${body//$'\n'/ }"
        return 0
    fi
    log_line "webhook_sent ${body//$'\n'/ }"
}

notify_alert() {
    local kind="$1"
    local detail="$2"
    local msg
    msg="[cobaco] ${HOST_LABEL} ALERT ${kind}
${detail}"
    send_webhook "$msg"
}

notify_ok() {
    local kind="$1"
    local detail="${2:-}"
    local msg="[cobaco] ${HOST_LABEL} OK ${kind}"
    if [[ -n "$detail" ]]; then
        msg="${msg}
${detail}"
    fi
    send_webhook "$msg"
}

state_init() {
    mkdir -p "$STATE_DIR"
    if [[ ! -f "$STATE_FILE" ]]; then
        touch "$STATE_FILE"
        chmod 600 "$STATE_FILE"
    fi
}

state_get() {
    local key="$1"
    if [[ ! -f "$STATE_FILE" ]]; then
        return 0
    fi
    awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); exit }' "$STATE_FILE"
}

state_set() {
    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi
    local key="$1"
    local value="$2"
    state_init
    local tmp
    tmp="$(mktemp)"
    if [[ -f "$STATE_FILE" ]]; then
        awk -F= -v k="$key" '$1 != k { print }' "$STATE_FILE" > "$tmp" || true
    fi
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

state_delete() {
    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi
    local key="$1"
    [[ -f "$STATE_FILE" ]] || return 0
    local tmp
    tmp="$(mktemp)"
    awk -F= -v k="$key" '$1 != k { print }' "$STATE_FILE" > "$tmp" || true
    mv "$tmp" "$STATE_FILE"
}

handle_threshold_alert() {
    local id="$1"
    local is_bad="$2"
    local alert_detail="$3"
    local ok_detail="${4:-}"

    local status_key="alert_${id}_status"
    local notify_key="alert_${id}_last_notify"
    local repeat_sec
    repeat_sec="$(cfg '.cooldowns.alert_repeat_seconds // 21600')"

    local prev_status now_ts
    prev_status="$(state_get "$status_key")"
    now_ts="$(date +%s)"

    if [[ "$is_bad" == true ]]; then
        if [[ "$prev_status" != "alert" ]]; then
            notify_alert "$id" "$alert_detail"
            state_set "$status_key" "alert"
            state_set "$notify_key" "$now_ts"
        else
            local last_notify=0
            last_notify="$(state_get "$notify_key")"
            if [[ -z "$last_notify" ]]; then last_notify=0; fi
            if (( now_ts - last_notify >= repeat_sec )); then
                notify_alert "$id" "$alert_detail"
                state_set "$notify_key" "$now_ts"
            fi
        fi
    else
        if [[ "$prev_status" == "alert" ]]; then
            notify_ok "$id" "$ok_detail"
        fi
        state_set "$status_key" "ok"
        state_delete "$notify_key"
    fi
}

top_memory_lines() {
    local parts=()
    local line rss comm
    while IFS= read -r line; do
        rss="${line%% *}"
        comm="${line#* }"
        parts+=("${comm} $(( rss / 1024 ))MB")
    done < <(
        ps -eo comm,rss --no-headers 2>/dev/null \
            | awk '{ rss[$1]+=$2 } END { for (c in rss) print rss[c], c }' \
            | sort -rn \
            | head -3
    )
    if ((${#parts[@]} > 0)); then
        local IFS=', '
        echo "top: ${parts[*]}"
    fi
}

check_memory() {
    local min_pct
    min_pct="$(cfg '.thresholds.memory_available_min_percent // 10')"
    local mem_total mem_avail avail_pct swap_total swap_free swap_pct
    mem_total="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    mem_avail="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
    swap_total="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
    swap_free="$(awk '/^SwapFree:/ {print $2}' /proc/meminfo)"

    if [[ -z "$mem_total" || "$mem_total" -eq 0 ]]; then
        return 0
    fi
    avail_pct=$(( mem_avail * 100 / mem_total ))
    swap_pct=0
    if [[ "$swap_total" -gt 0 ]]; then
        swap_pct=$(( (swap_total - swap_free) * 100 / swap_total ))
    fi

    local bad=false
    if (( avail_pct < min_pct )); then
        bad=true
    fi

    local top_lines
    top_lines="$(top_memory_lines)"
    local detail
    detail="available ${avail_pct}% (threshold ${min_pct}%, free $(( mem_avail / 1024 ))MB, swap ${swap_pct}%)
${top_lines}"

    handle_threshold_alert "memory" "$bad" "$detail" "available ${avail_pct}%"
}

check_one_mount() {
    local mount="$1"
    local disk_max inode_max
    disk_max="$(cfg '.thresholds.disk_use_max_percent // 85')"
    inode_max="$(cfg '.thresholds.inode_use_max_percent // 90')"

    local df_line use_pct inode_line iuse_pct
    df_line="$(df -P "$mount" 2>/dev/null | tail -n1)" || return 0
    use_pct="$(awk '{print $5}' <<< "$df_line" | tr -d '%')"
    inode_line="$(df -Pi "$mount" 2>/dev/null | tail -n1)" || inode_line=""
    iuse_pct="$(awk '{print $5}' <<< "$inode_line" | tr -d '%')"

    local id="disk_$(echo "$mount" | tr '/ ' '__')"
    local bad=false
    if [[ -n "$use_pct" && "$use_pct" -ge "$disk_max" ]]; then bad=true; fi
    if [[ -n "$iuse_pct" && "$iuse_pct" -ge "$inode_max" ]]; then bad=true; fi

    local detail="mount ${mount} use ${use_pct:-?}% (threshold ${disk_max}%), inode ${iuse_pct:-?}% (threshold ${inode_max}%)"
    handle_threshold_alert "$id" "$bad" "$detail" "mount ${mount} use ${use_pct:-?}%"
}

check_disk() {
    check_one_mount "/"
    local extra
    extra="$(cfg '.extra_mounts // [] | .[]' 2>/dev/null || true)"
    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        check_one_mount "$m"
    done <<< "$extra"
}

check_load() {
    local mult load15 ncpu threshold bad
    mult="$(cfg '.thresholds.load15_multiplier // 2')"
    load15="$(awk '{print $3}' /proc/loadavg)"
    ncpu="$(nproc)"
    threshold="$(awk -v n="$ncpu" -v m="$mult" 'BEGIN { printf "%.2f", n * m }')"
    local bad=false
    if awk -v l="$load15" -v t="$threshold" 'BEGIN { exit !(l > t) }'; then
        bad=true
    fi
    local detail="load15 ${load15} (threshold > ${threshold}, cpus ${ncpu})"
    if [[ "$bad" == true ]]; then
        local top_cpu
        top_cpu="$(ps -eo comm,pcpu --no-headers 2>/dev/null | awk '{cpu[$1]+=$2} END {for (c in cpu) print cpu[c], c}' | sort -rn | head -3 | awk '{printf "%s %.0f%%", (NR>1?", ":""), $1; printf "%s", $2} END {print ""}' | sed 's/^/top: /' || true)"
        detail="${detail}
${top_cpu}"
    fi
    handle_threshold_alert "load" "$bad" "$detail" "load15 ${load15}"
}

check_services() {
    local services=(nginx mariadb)
    local php_svc bad detail failed=()
    for php_svc in "${PHP_FPM_SERVICES[@]}"; do
        if systemctl is-enabled --quiet "${php_svc}.service" 2>/dev/null; then
            services+=("$php_svc")
        fi
    done
    bad=false
    for svc in "${services[@]}"; do
        if ! systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
            bad=true
            failed+=("$svc")
        fi
    done
    detail=""
    if ((${#failed[@]} > 0)); then
        detail="inactive: $(IFS=,; echo "${failed[*]}")"
    else
        detail="all expected services active"
    fi
    handle_threshold_alert "services" "$bad" "$detail" "$detail"
}

get_ssh_listen_ports() {
    local ports=()
    mapfile -t ports < <(
        systemctl cat ssh.socket 2>/dev/null | awk '
            /^ListenStream=/ {
                line = $0
                sub(/^ListenStream=/, "", line)
                if (line == "" || line == "-") next
                n = split(line, a, ":")
                print a[n]
            }
        ' | sort -nu
    )
    if ((${#ports[@]} == 0)); then
        ports=(22)
    fi
    printf '%s\n' "${ports[@]}"
}

check_public_listeners() {
    local -a allowed=() ssh_ports=()
    mapfile -t ssh_ports < <(get_ssh_listen_ports)
    allowed+=("${ssh_ports[@]}")
    allowed+=(80 443)

    local bad=false
    local unexpected=()
    local addr port

    while IFS= read -r addr port; do
        [[ -z "$port" ]] && continue

        local ok=false
        local p
        for p in "${allowed[@]}"; do
            if [[ "$port" == "$p" ]]; then
                ok=true
                break
            fi
        done
        if [[ "$ok" == false ]]; then
            bad=true
            unexpected+=("${addr}:${port}")
        fi
    done < <(
        ss -tlnH 2>/dev/null | awk '
            $4 ~ /^0\.0\.0\.0:/ || $4 ~ /^\[::\]:/ || $4 ~ /^:::/ {
                n = split($4, a, ":")
                print $4, a[n]
            }
        '
    )

    local detail=""
    if ((${#unexpected[@]} > 0)); then
        detail="unexpected listeners: $(IFS='; '; echo "${unexpected[*]}")"
        detail="${detail}
allowed: SSH ($(IFS=,; echo "${ssh_ports[*]}")), 80, 443"
    else
        detail="no unexpected public TCP listeners"
    fi
    handle_threshold_alert "public_ports" "$bad" "$detail" "$detail"
}

check_reboot() {
    local btime prev
    btime="$(awk '/^btime / {print $2}' /proc/stat)"
    prev="$(state_get boot_btime)"
    if [[ -z "$prev" ]]; then
        state_set boot_btime "$btime"
        return 0
    fi
    if [[ "$prev" != "$btime" ]]; then
        notify_alert "reboot" "boot time changed (was ${prev}, now ${btime})"
        state_set boot_btime "$btime"
    fi
}

init_journal_cursor_if_needed() {
    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi
    if [[ ! -s "$JOURNAL_CURSOR" ]]; then
        journalctl --cursor-file="$JOURNAL_CURSOR" -n 0 --update >/dev/null 2>&1 || true
    fi
}

read_journal_since_cursor() {
    if [[ "$DRY_RUN" == true ]]; then
        journalctl --cursor-file="$JOURNAL_CURSOR" --no-pager -o short-iso -n 50 2>/dev/null || true
        return 0
    fi
    journalctl --cursor-file="$JOURNAL_CURSOR" --update --no-pager -o short-iso 2>/dev/null || true
}

check_journal_events() {
    init_journal_cursor_if_needed
    local log
    log="$(read_journal_since_cursor)"

    if [[ -z "$log" ]]; then
        check_ssh_fail_window
        return 0
    fi

    local ssh_repeat
    ssh_repeat="$(cfg '.cooldowns.ssh_success_repeat_seconds // 43200')"
    local now_ts line

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        if [[ "$line" == *"Out of memory"* ]] || [[ "$line" == *"Killed process"* ]]; then
            notify_alert "oom" "${line}"
            continue
        fi

        if [[ "$line" == *"sshd"* ]] && [[ "$line" == *"Accepted"* ]]; then
            local user ip method key
            user="$(sed -n 's/.*Accepted \(publickey\|password\) for \([^ ]*\) from \([^ ]*\).*/\2/p' <<< "$line")"
            ip="$(sed -n 's/.*Accepted \(publickey\|password\) for \([^ ]*\) from \([^ ]*\).*/\3/p' <<< "$line")"
            method="$(sed -n 's/.*Accepted \(publickey\|password\) for.*/\1/p' <<< "$line")"
            if [[ -z "$user" || -z "$ip" ]]; then
                continue
            fi
            local dedup_key="ssh_login_${user}_${ip}"
            local dedup_key_state last=0
            dedup_key_state="$(state_get "$dedup_key")"
            now_ts="$(date +%s)"
            if [[ -n "$dedup_key_state" ]]; then last="$dedup_key_state"; fi
            if (( now_ts - last >= ssh_repeat )); then
                notify_alert "ssh_login" "user ${user} from ${ip} (${method})"
                state_set "$dedup_key" "$now_ts"
            fi
        fi
    done <<< "$log"

    check_ssh_fail_window
}

check_ssh_fail_window() {
    local window_sec min_count
    window_sec="$(cfg '.events.ssh_fail_window_seconds // 300')"
    min_count="$(cfg '.events.ssh_fail_min_count // 50')"

    local count
    count="$(journalctl --since "${window_sec} sec ago" --no-pager 2>/dev/null \
        | grep -Ec 'sshd.*Failed password|sshd.*Invalid user' || true)"
    count="${count:-0}"

    local active
    active="$(state_get ssh_fail_active)"
    if (( count >= min_count )); then
        if [[ "$active" != "1" ]]; then
            notify_alert "ssh_bruteforce" "ssh failures ${count} in last ${window_sec}s (threshold ${min_count})"
            state_set ssh_fail_active "1"
        fi
    else
        if [[ "$active" == "1" ]]; then
            notify_ok "ssh_bruteforce" "failures ${count} in last ${window_sec}s"
            state_delete ssh_fail_active
        fi
    fi
}

run_checks() {
    check_memory
    check_disk
    check_load
    check_services
    check_public_listeners
    check_reboot
    check_journal_events
}

if [[ "$TEST_NOTIFY" == true ]]; then
    if [[ -z "$WEBHOOK_URL" ]]; then
        error "webhook.url が未設定です: ${MONITOR_CONFIG}"
        exit 1
    fi
    send_webhook "[cobaco] ${HOST_LABEL} TEST notify OK ($(date -Iseconds))"
    success "テスト通知を送信しました"
    exit 0
fi

if [[ -z "$WEBHOOK_URL" && "$DRY_RUN" != true ]]; then
    exit 0
fi

state_init
run_checks
success "監視チェック完了"
