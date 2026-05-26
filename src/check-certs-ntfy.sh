#!/bin/bash

# ============================================================
#  check-certs-ntfy.sh – ntfy notification wrapper
#
#  Sends push notifications to a ntfy topic for each new
#  finding and daily reminder. Works with ntfy.sh (hosted)
#  or any self-hosted ntfy server.
#
#  ntfy priority mapping:
#    RENEWED          →  2  (low – good news, no interruption)
#    WARNING          →  3  (default)
#    CRITICAL         →  4  (high – bypasses Do Not Disturb)
#    URGENT / EXPIRED →  5  (max – emergency alert)
#    ERROR            →  4  (high)
#
#  Each finding is sent as a separate notification so the
#  sysadmin sees one actionable item per host.
#  Reminder runs send a single batched summary to avoid
#  notification fatigue.
#
#  Requirements: openssl, curl
#
#  Configure: NTFY_URL and NTFY_TOPIC in check-certs.conf
#    NTFY_URL="https://ntfy.sh"      # or your self-hosted server
#    NTFY_TOPIC="my-cert-alerts"     # your topic name
#
#  Optional authentication (for protected topics):
#    NTFY_TOKEN="tk_..."             # ntfy access token
#    # or username/password:
#    NTFY_USER="alice"
#    NTFY_PASS="s3cret"
#
#  Schedule:
#    Linux cron (daily at 07:00):
#      0 7 * * * /opt/check-certs/check-certs-ntfy.sh
#    macOS: add a launchd plist – see docs/ntfy.md
# ============================================================

CORE="$(dirname "$0")/check-certs.sh"
[ -f "$CORE" ] || { echo "Error: check-certs.sh not found (expected: $CORE)" >&2; exit 1; }

# ── Load check-certs.sh (functions + escalation logic) ───────
# shellcheck source=check-certs.sh
source "$CORE"

# configure_wrapper loads check-certs.conf and applies defaults
configure_wrapper

# ── State directory default for this variant ─────────────────
# Each variant uses its own directory; one file per monitored host.
if [ -z "${STATE_FILE:-}" ]; then
    if [[ "$(uname)" == "Darwin" ]]; then
        STATE_FILE="$HOME/Library/Application Support/check-certs/state-ntfy"
    else
        STATE_FILE="/var/lib/check-certs/state-ntfy"
    fi
fi
state_init

# ── Log file ─────────────────────────────────────────────────
if [[ "$(uname)" == "Darwin" ]]; then
    : "${LOG_FILE:=$HOME/Library/Logs/check-certs/check-certs-ntfy.log}"
else
    : "${LOG_FILE:=/var/log/check-certs/check-certs-ntfy.log}"
fi
mkdir -p "$(dirname "$LOG_FILE")"

# ── ntfy config (set in check-certs.conf) ────────────────────
: "${NTFY_URL:=}"        # ntfy server URL, e.g. https://ntfy.sh
: "${NTFY_TOPIC:=}"      # topic name (no leading slash)
: "${NTFY_TOKEN:=}"      # access token (takes precedence over user/pass)
: "${NTFY_USER:=}"       # username for basic auth
: "${NTFY_PASS:=}"       # password for basic auth

# ── Validate required config ─────────────────────────────────
if [ -z "$NTFY_URL" ]; then
    echo "Error: NTFY_URL is not set. Add it to check-certs.conf." >&2
    echo "  Example: NTFY_URL=\"https://ntfy.sh\"" >&2
    exit 1
fi
if [ -z "$NTFY_TOPIC" ]; then
    echo "Error: NTFY_TOPIC is not set. Add it to check-certs.conf." >&2
    echo "  Example: NTFY_TOPIC=\"my-cert-alerts\"" >&2
    exit 1
fi
if ! command -v curl &>/dev/null; then
    echo "Error: curl is required but not installed." >&2
    exit 1
fi

# Strip trailing slash from URL so we never get double slashes
NTFY_URL="${NTFY_URL%/}"

# ── Logging ──────────────────────────────────────────────────
log() {
    printf '[%s] %s\n' "$($DATE_CMD '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

log_cert() {
    local hostname="$1" days="$2" status="$3" note="${4:-}"
    if [ -n "$note" ]; then
        printf '[%s] %-38s %6s  %-12s %s\n' \
            "$($DATE_CMD '+%Y-%m-%d %H:%M:%S')" "$hostname" "$days" "$status" "$note"
    else
        printf '[%s] %-38s %6s  %s\n' \
            "$($DATE_CMD '+%Y-%m-%d %H:%M:%S')" "$hostname" "$days" "$status"
    fi | tee -a "$LOG_FILE"
}

# ── ntfy API ──────────────────────────────────────────────────
# Send a single ntfy notification.
#
# Arguments:
#   $1  message body (plain text)
#   $2  ntfy priority (1-5; default 3)
#   $3  notification title (shown on device)
#   $4  comma-separated emoji tags (optional, e.g. "warning,lock")
#
# ntfy priority scale:
#   1=min  2=low  3=default  4=high  5=max (emergency)
_ntfy_send() {
    local message="$1" priority="${2:-3}" title="${3:-check-certs}" tags="${4:-}"

    local -a auth_args=()
    if [ -n "$NTFY_TOKEN" ]; then
        # Token-based auth (preferred – avoids sending password over the wire)
        auth_args+=(-H "Authorization: Bearer $NTFY_TOKEN")
    elif [ -n "$NTFY_USER" ] && [ -n "$NTFY_PASS" ]; then
        auth_args+=(-u "$NTFY_USER:$NTFY_PASS")
    fi

    local -a headers=(
        -H "Title: $title"
        -H "Priority: $priority"
        -H "Content-Type: text/plain"
    )
    [ -n "$tags" ] && headers+=(-H "Tags: $tags")

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        "${auth_args[@]}" \
        "${headers[@]}" \
        -d "$message" \
        "$NTFY_URL/$NTFY_TOPIC" 2>/dev/null)

    # Retry once with a 5-second delay on failure
    if [ -z "$http_code" ] || [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        sleep 5
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST \
            "${auth_args[@]}" \
            "${headers[@]}" \
            -d "$message" \
            "$NTFY_URL/$NTFY_TOPIC" 2>/dev/null)
        if [ -z "$http_code" ] || [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
            log "Warning: ntfy POST failed (HTTP ${http_code:-no response})"
            return 1
        fi
    fi
    return 0
}

# Map a check-certs status to a ntfy priority level (1–5)
_ntfy_priority() {
    case "$1" in
        RENEWED)         echo "2" ;;   # low  – good news
        WARNING)         echo "3" ;;   # default
        CRITICAL|ERROR)  echo "4" ;;   # high
        URGENT|EXPIRED)  echo "5" ;;   # max  – emergency alert
        *)               echo "3" ;;
    esac
}

# Map a status to a comma-separated list of ntfy emoji tags.
# These appear as small icons in the ntfy notification.
_ntfy_tags() {
    case "$1" in
        RENEWED)         echo "white_check_mark,lock" ;;
        WARNING)         echo "warning,lock" ;;
        CRITICAL)        echo "rotating_light,lock" ;;
        URGENT)          echo "rotating_light,sos" ;;
        EXPIRED)         echo "no_entry,lock" ;;
        ERROR)           echo "x,globe_with_meridians" ;;
        *)               echo "bell" ;;
    esac
}

# Build the notification body for a single certificate event.
_ntfy_message() {
    local hostname="$1" status="$2" days_left="$3" expiry="$4"
    local ca_name="$5" chain_status="${6:-OK}"

    local chain_note=""
    [ "$chain_status" != "OK" ] && chain_note=" | Chain: ${chain_status}"

    case "$status" in
        RENEWED)
            printf '%s\nRenewed – %sd remaining\nExpires: %s (CA: %s)' \
                "$hostname" "$days_left" "$expiry" "$ca_name"
            ;;
        ERROR)
            printf '%s\nUnreachable – %s' "$hostname" "$ca_name"
            ;;
        EXPIRED)
            printf '%s\nEXPIRED %sd ago\nExpired: %s (CA: %s%s)' \
                "$hostname" "${days_left#-}" "$expiry" "$ca_name" "$chain_note"
            ;;
        URGENT)
            printf '%s\n%sd remaining – act now!\nExpires: %s (CA: %s%s)' \
                "$hostname" "$days_left" "$expiry" "$ca_name" "$chain_note"
            ;;
        CRITICAL)
            printf '%s\n%sd remaining – critical\nExpires: %s (CA: %s%s)' \
                "$hostname" "$days_left" "$expiry" "$ca_name" "$chain_note"
            ;;
        *)  # WARNING
            printf '%s\n%sd remaining – warning\nExpires: %s (CA: %s%s)' \
                "$hostname" "$days_left" "$expiry" "$ca_name" "$chain_note"
            ;;
    esac
}

# Map status to a human-readable notification title
_ntfy_title() {
    case "$1" in
        RENEWED)  echo "✅ Certificate renewed" ;;
        WARNING)  echo "🔔 Certificate expiry notice" ;;
        CRITICAL) echo "⚠️ Certificate expiring soon" ;;
        URGENT)   echo "🚨 Act now – certificate expiring" ;;
        EXPIRED)  echo "🔴 Certificate EXPIRED" ;;
        ERROR)    echo "❌ Certificate check failed" ;;
        *)        echo "check-certs" ;;
    esac
}

# ── Reminder batching ─────────────────────────────────────────
# Individual findings get their own notification (one per host).
# Reminders are batched into one message per severity level to avoid
# flooding the device with repeat alerts.
_remind_urgent=""    # URGENT + EXPIRED reminders
_remind_normal=""    # CRITICAL + WARNING reminders

# ── Delivery hooks ───────────────────────────────────────────
deliver_finding() {
    local hostname="$1" status="$2" days_left="$3" short_date="$4"
    local ca_name="$5" chain_status="${6:-OK}"

    _ntfy_send \
        "$(_ntfy_message "$hostname" "$status" "$days_left" "$short_date" "$ca_name" "$chain_status")" \
        "$(_ntfy_priority "$status")" \
        "$(_ntfy_title "$status")" \
        "$(_ntfy_tags "$status")"

    local days_log
    [[ "$days_left" =~ ^-?[0-9]+$ ]] && days_log="${days_left}d" || days_log="$days_left"
    log_cert "$hostname" "$days_log" "$status" "(CA: ${ca_name}) → notification sent"
}

deliver_reminder() {
    local hostname="$1" status="$2" days_left="$3" short_date="$4"
    local ca_name="$5" chain_status="${6:-OK}"

    local days_log
    [[ "$days_left" =~ ^-?[0-9]+$ ]] && days_log="${days_left}d" || days_log="$days_left"

    # Batch reminders: one line per host, sent as a summary after the loop
    local line="${hostname} (${days_log})"
    case "$status" in
        URGENT|EXPIRED) _remind_urgent+="${line}"$'\n' ;;
        *)              _remind_normal+="${line}"$'\n' ;;
    esac

    log_cert "$hostname" "$days_log" "$status" "(CA: ${ca_name}) → batched for reminder"
}

on_group() { log "── ${1} ──"; }

# ── Wire escalation logic ────────────────────────────────────
install_escalation_hooks

# Log every cert on every run (mirrors check-certs-notify.sh pattern)
on_cert_result() {
    local hostname="$1" port="$2" days_left="$3" short_date="$4"
    local ca_name="$5" status="$6" prev_status="$7" hours_since="$8"
    local chain_status="${9:-OK}"
    _escalation_on_cert_result "$@"
    # Log certs that escalation handled silently (OK + known within window)
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
        [[ "$days_left" =~ ^-?[0-9]+$ ]] && days_log="${days_left}d" || days_log="$days_left"
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
    _ntfy_send "Server file not found: $SERVER_FILE" 4 "check-certs: config error" "x"
    exit 1
}

server_count=$(awk '!/^[[:space:]]*(#|$|\[)/ && /:/' "$SERVER_FILE" | wc -l | tr -d ' ')
log "Started – checking ${server_count} servers"

run_server_loop "$SERVER_FILE"

# ── Send batched reminder notifications ───────────────────────
# Urgent reminders (URGENT/EXPIRED): max priority, one notification
if [ -n "$_remind_urgent" ]; then
    count=$(printf '%s' "$_remind_urgent" | wc -l | tr -d ' ')
    _ntfy_send \
        "$(printf 'Reminder: %d certificate(s) need urgent attention:\n%s' "$count" "$_remind_urgent")" \
        "5" "🚨 Reminder – act now" "rotating_light,sos"
fi

# Normal reminders (CRITICAL/WARNING): high priority, one notification
if [ -n "$_remind_normal" ]; then
    count=$(printf '%s' "$_remind_normal" | wc -l | tr -d ' ')
    _ntfy_send \
        "$(printf 'Reminder: %d certificate(s) expiring soon:\n%s' "$count" "$_remind_normal")" \
        "4" "🔁 Reminder – certificates expiring" "warning,lock"
fi

[ $((new_issues + reminders)) -gt 0 ] && \
    logger -t check-certs \
        "ntfy – ${new_issues} new, ${reminders} reminder(s), ${errors} error(s) of ${total} checked"

log "Done – ${total} checked, $((new_issues + reminders)) notification(s), ${errors} error(s)"

[ $((new_issues + reminders)) -gt 0 ] && exit 1 || exit 0
