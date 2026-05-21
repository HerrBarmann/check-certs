#!/bin/bash

# ============================================================
#  check-certs-notify.sh – macOS notification wrapper
#  Runs daily via launchd. Sends native macOS notifications
#  grouped by severity. Clicking a notification opens the
#  full certificate table in a new Terminal window.
#
#  Requirements: openssl, coreutils, terminal-notifier
#    brew install coreutils terminal-notifier
#  Setup: ./install/install-macos.sh
# ============================================================

CORE="$(dirname "$0")/check-certs.sh"
[ -f "$CORE" ] || { echo "Error: check-certs.sh not found (expected: $CORE)" >&2; exit 1; }

# ── Load check-certs.sh (functions + escalation logic) ───────
# shellcheck source=check-certs.sh
source "$CORE"

# configure_wrapper loads check-certs.conf and applies defaults
configure_wrapper

# ── Variant-specific defaults (applied after config file) ────
: "${LOG_FILE:=$HOME/Library/Logs/check-certs/check-certs-notify.log}"
: "${STATE_FILE:=$HOME/Library/Application Support/check-certs/state}"

# Initialise state and ensure log directory exists
state_init
mkdir -p "$(dirname "$LOG_FILE")"

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

# ── Notifications ────────────────────────────────────────────
_send_notification() {
    local title="$1" message="$2" sound="${3:-}"
    local check_script
    check_script="$(dirname "$0")/check-certs.sh"

    if command -v terminal-notifier &>/dev/null && [ -f "$check_script" ]; then
        local execute_cmd
        execute_cmd=$(cat <<APPLESCRIPT
osascript <<'EOF'
tell application "Terminal"
    set newTab to do script "\"${check_script}\""
    set bounds of front window to {100, 100, 1000, 780}
    activate
end tell
EOF
APPLESCRIPT
)
        local args=(-title "$title" -message "$message" -execute "$execute_cmd")
        [ -n "$sound" ] && args+=(-sound "$sound")
        terminal-notifier "${args[@]}"
    else
        local safe_title safe_message
        safe_title="${title//"/\\"}"
        safe_message="${message//"/\\"}"
        if [ -n "$sound" ]; then
            osascript -e "display notification \"${safe_message}\" with title \"${safe_title}\" sound name \"${sound}\""
        else
            osascript -e "display notification \"${safe_message}\" with title \"${safe_title}\""
        fi
    fi
}

# Pick the most severe entry to show first in a bundled message
_build_message() {
    local lines="$1" count="$2" first rest
    first=$(echo "$lines" | grep -m1 "urgent\|EXPIRED" || \
            echo "$lines" | grep -m1 "critical" || \
            echo "$lines" | head -1)
    rest=$(( count - 1 ))
    [ "$rest" -gt 0 ] && echo "${first} (+${rest} more)" || echo "$first"
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

# ── Notification buckets ─────────────────────────────────────
# Reminders are split into two buckets so urgency detection doesn't rely
# on grepping human-readable strings produced by _format_entry.
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

# ── Group hook – section separator in log ────────────────────
on_group() { log "── ${1} ──"; }

# ── Wire escalation logic and initialise state ────────────────
install_escalation_hooks

# Wrap on_cert_result to log every cert on every run.
# deliver_finding / deliver_reminder handle notification logging;
# this hook covers OK results and known issues within the reminder window.
on_cert_result() {
    local hostname="$1" port="$2" days_left="$3" short_date="$4"
    local ca_name="$5" status="$6" prev_status="$7" hours_since="$8"
    local chain_status="${9:-OK}"
    _escalation_on_cert_result "$@"
    # Log certs that escalation handled silently (OK results and known
    # issues not yet due for a reminder – deliver_finding/reminder log
    # the others via their own log_cert calls).
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
        log_cert "$hostname" "${days_left}d" "$status" "(CA: ${ca_name})"
    fi
}

# Wrap on_cert_error to always log every unreachable host, even when the
# error is already known and no notification is due yet. Without this,
# servers that are in ERROR state but within the 23-hour reminder window
# are silently skipped and never appear in the log.
on_cert_error() {
    local hostname="$1" reason="$3"
    log_cert "$hostname" "-" "ERROR" "(${reason})"
    _escalation_on_cert_error "$@"
}

# ── Run ──────────────────────────────────────────────────────
[ -f "$SERVER_FILE" ] || {
    log "ERROR: server file not found: $SERVER_FILE"
    _send_notification "check-certs: Error" "Server file not found: $SERVER_FILE"
    exit 1
}

server_count=$(awk '!/^[[:space:]]*(#|$|\[)/ && /:/' "$SERVER_FILE" | wc -l | tr -d ' ')
log "Started – checking ${server_count} servers"

run_server_loop "$SERVER_FILE"

# ── Send notifications ───────────────────────────────────────
# Count entries by counting newlines in each bucket
_count_lines() { local s="$1"; [ -z "$s" ] && echo 0 || printf '%s' "$s" | wc -l | tr -d ' '; }
renewed_count=$(_count_lines "$notify_renewed")
urgent_count=$(_count_lines "$notify_urgent")
critical_count=$(_count_lines "$notify_critical")
warning_count=$(_count_lines "$notify_warning")
reminder_urgent_count=$(_count_lines "$notify_reminder_urgent")
reminder_normal_count=$(_count_lines "$notify_reminder_normal")

if [ "$renewed_count" -gt 0 ]; then
    _send_notification "✅ Certificate renewed" \
        "$(_build_message "$notify_renewed" "$renewed_count")"
fi
if [ "$urgent_count" -gt 0 ]; then
    _send_notification "🚨 Act now – certificate expiring" \
        "$(_build_message "$notify_urgent" "$urgent_count")" "Basso"
fi
if [ "$critical_count" -gt 0 ]; then
    _send_notification "⚠️ Certificate expiring soon" \
        "$(_build_message "$notify_critical" "$critical_count")" "Ping"
fi
if [ "$warning_count" -gt 0 ]; then
    _send_notification "🔔 Certificate expiry notice" \
        "$(_build_message "$notify_warning" "$warning_count")"
fi
if [ "$reminder_urgent_count" -gt 0 ]; then
    _send_notification "🚨 Reminder – Act now" \
        "$(_build_message "$notify_reminder_urgent" "$reminder_urgent_count")" "Basso"
fi
if [ "$reminder_normal_count" -gt 0 ]; then
    _send_notification "🔁 Reminder – certificates expiring" \
        "$(_build_message "$notify_reminder_normal" "$reminder_normal_count")" "Ping"
fi

[ $((new_issues + reminders)) -gt 0 ] && \
    logger -t check-certs "Sent – ${new_issues} new, ${reminders} reminder(s), ${errors} error(s) of ${total} checked"

log "Done – ${total} checked, $((new_issues + reminders)) notification(s), ${errors} error(s)"

[ $((new_issues + reminders)) -gt 0 ] && exit 1 || exit 0
