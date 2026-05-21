#!/bin/bash

# ============================================================
#  check-certs-pushover.sh – Pushover notification wrapper
#  Runs daily via cron (Linux) or launchd (macOS). Sends
#  Pushover notifications grouped by severity with appropriate
#  priority levels.
#
#  Pushover priority mapping:
#    RENEWED          →  -1  (quiet, no sound)
#    WARNING          →   0  (normal)
#    CRITICAL         →   1  (high, bypasses quiet hours)
#    URGENT / EXPIRED →   2  (emergency, retries until acknowledged)
#    ERROR            →   1  (high)
#
#  Requirements: openssl, curl
#  Configure:    PUSHOVER_APP_TOKEN and PUSHOVER_USER_KEY
#                in check-certs.conf
#
#  Cron job example (daily at 07:00):
#    0 7 * * * /opt/check-certs/check-certs-pushover.sh
#
#  launchd: use install/com.check-certs.pushover.plist
#           (installed automatically by install-macos.sh)
# ============================================================

CORE="$(dirname "$0")/check-certs.sh"
[ -f "$CORE" ] || { echo "Error: check-certs.sh not found (expected: $CORE)" >&2; exit 1; }

# ── Load check-certs.sh (functions + escalation logic) ───────
# shellcheck source=check-certs.sh
source "$CORE"

# configure_wrapper loads check-certs.conf and applies defaults
configure_wrapper

# ── State file default for this variant ──────────────────────
if [ -z "${STATE_FILE:-}" ]; then
    if [[ "$(uname)" == "Darwin" ]]; then
        STATE_FILE="$HOME/Library/Application Support/check-certs/state-pushover"
    else
        STATE_FILE="/var/lib/check-certs/state-pushover"
    fi
fi
state_init

# ── Log file default ─────────────────────────────────────────
if [[ "$(uname)" == "Darwin" ]]; then
    : "${LOG_FILE:=$HOME/Library/Logs/check-certs/check-certs-pushover.log}"
else
    : "${LOG_FILE:=/var/log/check-certs/check-certs-pushover.log}"
fi
mkdir -p "$(dirname "$LOG_FILE")"

# ── Pushover config (set in check-certs.conf) ────────────────
: "${PUSHOVER_APP_TOKEN:=}"   # Application API token from pushover.net
: "${PUSHOVER_USER_KEY:=}"    # User or group key from pushover.net
: "${PUSHOVER_DEVICE:=}"      # Optional: limit to a specific device name
# Emergency priority (2) retry/expire settings.
# Pushover will retry every PUSHOVER_RETRY seconds until acknowledged,
# for up to PUSHOVER_EXPIRE seconds (max 10800 = 3 hours).
: "${PUSHOVER_RETRY:=300}"    # Retry interval in seconds (min 30)
: "${PUSHOVER_EXPIRE:=3600}"  # Expiry in seconds (max 10800)

# ── Validate required config ─────────────────────────────────
if [ "${PUSHOVER_RETRY:-300}" -lt 30 ]; then
    echo "Error: PUSHOVER_RETRY must be at least 30 seconds (Pushover API minimum)." >&2
    exit 1
fi
if [ -z "$PUSHOVER_APP_TOKEN" ]; then
    echo "Error: PUSHOVER_APP_TOKEN is not set. Add it to check-certs.conf." >&2
    exit 1
fi
if [ -z "$PUSHOVER_USER_KEY" ]; then
    echo "Error: PUSHOVER_USER_KEY is not set. Add it to check-certs.conf." >&2
    exit 1
fi

if ! command -v curl &>/dev/null; then
    echo "Error: curl is required but not installed." >&2
    exit 1
fi

# ── Logging ──────────────────────────────────────────────────
log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

log_cert() {
    local hostname="$1" days="$2" status="$3" note="${4:-}"
    if [ -n "$note" ]; then
        printf '[%s] %-38s %6s  %-12s %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$hostname" "$days" "$status" "$note"
    else
        printf '[%s] %-38s %6s  %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$hostname" "$days" "$status"
    fi | tee -a "$LOG_FILE"
}

# ── Pushover API ──────────────────────────────────────────────
# Send a Pushover notification.
# $1 = title, $2 = message, $3 = priority (-1..2), $4 = url (optional)
_push() {
    local title="$1" message="$2" priority="${3:-0}" url="${4:-}"

    local -a args=(
        -s -o /dev/null -w "%{http_code}"
        --form-string "token=$PUSHOVER_APP_TOKEN"
        --form-string "user=$PUSHOVER_USER_KEY"
        --form-string "title=$title"
        --form-string "message=$message"
        --form-string "priority=$priority"
        --form-string "html=0"
    )

    [ -n "$PUSHOVER_DEVICE" ] && args+=(--form-string "device=$PUSHOVER_DEVICE")
    [ -n "$url"             ] && args+=(--form-string "url=$url" \
                                        --form-string "url_title=View certificate table")

    # Emergency priority requires retry and expire parameters
    if [ "$priority" = "2" ]; then
        args+=(--form-string "retry=$PUSHOVER_RETRY"
               --form-string "expire=$PUSHOVER_EXPIRE")
    fi

    local http_code
    http_code=$(curl "${args[@]}" \
        https://api.pushover.net/1/messages.json 2>/dev/null)

    if [ -z "$http_code" ] || [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        sleep 5
        http_code=$(curl "${args[@]}" \
            https://api.pushover.net/1/messages.json 2>/dev/null)
        if [ -z "$http_code" ] || [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
            log "Warning: Pushover POST failed (HTTP ${http_code:-no response})"
            return 1
        fi
    fi
    return 0
}

# Format a single entry for the notification body
_format_entry() {
    local hostname="$1" status="$2" days_left="$3" ca_name="$4" chain_status="$5"
    local chain_note=""
    [ "$chain_status" != "OK" ] && chain_note=", chain: ${chain_status}"
    case "$status" in
        RENEWED)  echo "${hostname}: Renewed – ${days_left}d remaining (CA: ${ca_name})" ;;
        ERROR)    echo "${hostname}: ${ca_name}" ;;
        EXPIRED)  echo "${hostname} – EXPIRED (CA: ${ca_name}${chain_note})" ;;
        URGENT)   echo "${hostname} – ${days_left}d remaining – urgent (CA: ${ca_name}${chain_note})" ;;
        CRITICAL) echo "${hostname} – ${days_left}d remaining – critical (CA: ${ca_name}${chain_note})" ;;
        *)        echo "${hostname} – ${days_left}d remaining (CA: ${ca_name}${chain_note})" ;;
    esac
}

# Build notification message from a bucket.
# Shows the most severe entry first with a count of remaining entries.
_build_message() {
    local lines="$1" count="$2" first rest
    first=$(printf '%s' "$lines" | grep -m1 "urgent\|EXPIRED" || \
            printf '%s' "$lines" | grep -m1 "critical" || \
            printf '%s' "$lines" | head -1)
    rest=$(( count - 1 ))
    [ "$rest" -gt 0 ] && echo "${first} (+${rest} more)" || echo "$first"
}

_count_lines() { local s="$1"; [ -z "$s" ] && echo 0 || printf '%s' "$s" | wc -l | tr -d ' '; }

# ── Notification buckets ─────────────────────────────────────
notify_renewed=""
notify_urgent=""; notify_critical=""; notify_warning=""
notify_reminder_urgent=""; notify_reminder_normal=""

# ── Delivery hooks ───────────────────────────────────────────
deliver_finding() {
    local hostname="$1" status="$2" days_left="$3" short_date="$4"
    local ca_name="$5" chain_status="${6:-OK}"
    local entry
    entry=$(_format_entry "$hostname" "$status" "$days_left" "$ca_name" "$chain_status")
    case "$status" in
        RENEWED)        notify_renewed+="${entry}"$'\n'  ;;
        URGENT|EXPIRED) notify_urgent+="${entry}"$'\n'  ;;
        CRITICAL)       notify_critical+="${entry}"$'\n' ;;
        *)              notify_warning+="${entry}"$'\n'  ;;
    esac
    local days_log
    [[ "$days_left" =~ ^-?[0-9]+$ ]] && days_log="${days_left}d" || days_log="$days_left"
    log_cert "$hostname" "$days_log" "$status" "(CA: ${ca_name}) → notification sent"
}

deliver_reminder() {
    local hostname="$1" status="$2" days_left="$3" short_date="$4"
    local ca_name="$5" chain_status="${6:-OK}"
    local entry
    entry=$(_format_entry "$hostname" "$status" "$days_left" "$ca_name" "$chain_status")
    case "$status" in
        URGENT|EXPIRED) notify_reminder_urgent+="${entry}"$'\n' ;;
        *)              notify_reminder_normal+="${entry}"$'\n' ;;
    esac
    local days_log
    [[ "$days_left" =~ ^-?[0-9]+$ ]] && days_log="${days_left}d" || days_log="$days_left"
    log_cert "$hostname" "$days_log" "$status" "(CA: ${ca_name}) → reminder sent"
}

on_group() { log "── ${1} ──"; }

# ── Wire escalation logic ────────────────────────────────────
install_escalation_hooks

# Log every cert on every run (same pattern as check-certs-notify.sh)
on_cert_result() {
    local hostname="$1" port="$2" days_left="$3" short_date="$4"
    local ca_name="$5" status="$6" prev_status="$7" hours_since="$8"
    local chain_status="${9:-OK}"
    _escalation_on_cert_result "$@"
    local state_status
    case "$prev_status" in
        WARN)    state_status="WARNING"  ;;
        CRIT)    state_status="CRITICAL" ;;
        URGENT)  state_status="URGENT"   ;;
        EXPIRED) state_status="EXPIRED"  ;;
        *)       state_status="$prev_status" ;;
    esac
    if [ "$status" = "OK" ] || \
       { [ "$status" = "$state_status" ] && [ "$hours_since" -lt 23 ]; }; then
        local days_log
        [[ "$days_left" =~ ^-[0-9]+$ ]] && days_log="${days_left#-}d" \
            || days_log="${days_left}d"
        log_cert "$hostname" "$days_log" "$status" "(CA: ${ca_name})"
    fi
}

on_cert_error() {
    local hostname="$1" reason="$3"
    log_cert "$hostname" "-" "ERROR" "(${reason})"
    _escalation_on_cert_error "$@"
}

# ── Run ──────────────────────────────────────────────────────
[ -f "$SERVER_FILE" ] || {
    log "ERROR: server file not found: $SERVER_FILE"
    _push "check-certs: Error" "Server file not found: $SERVER_FILE" 1
    exit 1
}

server_count=$(awk '!/^[[:space:]]*(#|$|\[)/ && /:/' "$SERVER_FILE" | wc -l | tr -d ' ')
log "Started – checking ${server_count} servers"

run_server_loop "$SERVER_FILE"

# ── Send notifications ────────────────────────────────────────
renewed_count=$(_count_lines "$notify_renewed")
urgent_count=$(_count_lines "$notify_urgent")
critical_count=$(_count_lines "$notify_critical")
warning_count=$(_count_lines "$notify_warning")
reminder_urgent_count=$(_count_lines "$notify_reminder_urgent")
reminder_normal_count=$(_count_lines "$notify_reminder_normal")

# RENEWED: quiet (-1), no interruption for good news
if [ "$renewed_count" -gt 0 ]; then
    _push "✅ Certificate renewed" \
        "$(_build_message "$notify_renewed" "$renewed_count")" -1
fi

# URGENT / EXPIRED new findings: emergency (2), retries until acknowledged
if [ "$urgent_count" -gt 0 ]; then
    _push "🚨 Act now – certificate expiring" \
        "$(_build_message "$notify_urgent" "$urgent_count")" 2
fi

# CRITICAL new findings: high (1), bypasses quiet hours
if [ "$critical_count" -gt 0 ]; then
    _push "⚠️ Certificate expiring soon" \
        "$(_build_message "$notify_critical" "$critical_count")" 1
fi

# WARNING new findings: normal (0)
if [ "$warning_count" -gt 0 ]; then
    _push "🔔 Certificate expiry notice" \
        "$(_build_message "$notify_warning" "$warning_count")" 0
fi

# URGENT / EXPIRED reminders: emergency (2)
if [ "$reminder_urgent_count" -gt 0 ]; then
    _push "🚨 Reminder – Act now" \
        "$(_build_message "$notify_reminder_urgent" "$reminder_urgent_count")" 2
fi

# CRITICAL / WARNING reminders: high (1)
if [ "$reminder_normal_count" -gt 0 ]; then
    _push "🔁 Reminder – certificates expiring" \
        "$(_build_message "$notify_reminder_normal" "$reminder_normal_count")" 1
fi

[ $((new_issues + reminders)) -gt 0 ] && \
    logger -t check-certs \
        "Pushover – ${new_issues} new, ${reminders} reminder(s), ${errors} error(s) of ${total} checked"

log "Done – ${total} checked, $((new_issues + reminders)) notification(s), ${errors} error(s)"

[ $((new_issues + reminders)) -gt 0 ] && exit 1 || exit 0
