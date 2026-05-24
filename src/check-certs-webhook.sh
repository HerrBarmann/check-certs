#!/bin/bash

# ============================================================
#  check-certs-webhook.sh – Webhook wrapper for check-certs
#
#  Posts a JSON payload to a configurable URL for each new
#  finding and reminder. Works with Slack incoming webhooks,
#  ntfy.sh, Mattermost, custom endpoints, or any service
#  that accepts HTTP POST with a JSON body. For Microsoft
#  Teams, use check-certs-teams.sh instead.
#
#  Requirements: openssl, curl
#  Configure:    WEBHOOK_URL in check-certs.conf
#
#  Schedule:
#    Linux cron (daily at 07:00):
#      0 7 * * * /opt/check-certs/check-certs-webhook.sh
#    macOS: use install/com.check-certs.webhook.plist
#           (installed automatically by install.sh)
# ============================================================

CORE="$(dirname "$0")/check-certs.sh"
[ -f "$CORE" ] || { echo "Error: check-certs.sh not found (expected: $CORE)" >&2; exit 1; }

# ── Load check-certs.sh (functions + escalation logic) ───────
# shellcheck source=check-certs.sh
source "$CORE"

# configure_wrapper loads check-certs.conf and applies defaults
configure_wrapper

# ── State file default for this variant ──────────────────────
# Each variant has its own state file so multiple variants can run side by side.
if [ -z "${STATE_FILE:-}" ]; then
    if [[ "$(uname)" == "Darwin" ]]; then
        STATE_FILE="$HOME/Library/Application Support/check-certs/state-webhook"
    else
        STATE_FILE="/var/lib/check-certs/state-webhook"
    fi
fi
state_init

# ── Webhook defaults (set in check-certs.conf) ───────────────
: "${WEBHOOK_URL:=}"
: "${WEBHOOK_AUTH_HEADER:=}"          # e.g. "Authorization"
: "${WEBHOOK_AUTH_VALUE:=}"           # e.g. "Bearer mytoken"
: "${WEBHOOK_SEND_SUMMARY:=true}"     # post a summary after all checks

# ── Validate required config ─────────────────────────────────
if [ -z "$WEBHOOK_URL" ]; then
    echo "Error: WEBHOOK_URL is not set. Add it to check-certs.conf." >&2
    exit 1
fi

if ! command -v curl &>/dev/null; then
    echo "Error: curl is required but not installed." >&2
    exit 1
fi

# ── JSON helpers ─────────────────────────────────────────────
# Minimal JSON string escaping – covers the characters that
# appear in hostnames, CA names and status strings.
_json_str() {
    local s="$1"
    s="${s//\\/\\\\}"   # backslash
    s="${s//\"/\\\"}"   # double quote
    s="${s//$'\n'/\\n}" # newline
    s="${s//$'\t'/\\t}" # tab
    s="${s//%/%%}"             # escape % for printf safety
    printf '%s' "$s"
}

# Post a JSON payload to the webhook URL.
# Retries once on failure with a 5-second delay.
_post() {
    local payload="$1"
    local -a args=(-s -o /dev/null -w "%{http_code}" \
        -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$payload")

    # Auth header passed as two separate args to handle values with spaces
    if [ -n "$WEBHOOK_AUTH_HEADER" ] && [ -n "$WEBHOOK_AUTH_VALUE" ]; then
        args+=(-H "$WEBHOOK_AUTH_HEADER: $WEBHOOK_AUTH_VALUE")
    fi

    local http_code
    http_code=$(curl "${args[@]}" 2>/dev/null)

    # Guard against empty response (network failure before HTTP response)
    if [ -z "$http_code" ] || [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        sleep 5
        http_code=$(curl "${args[@]}" 2>/dev/null)
        if [ -z "$http_code" ] || [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
            echo "Warning: webhook POST failed (HTTP ${http_code:-no response})" >&2
            return 1
        fi
    fi
    return 0
}

# Build and post a certificate event payload.
# $1 = type ("finding" or "reminder")
# $2..7 = hostname status days_left short_date ca_name chain_status
_post_event() {
    local type="$1" hostname="$2" status="$3" days_left="$4"
    local short_date="$5" ca_name="$6" chain_status="${7:-OK}"
    local timestamp
    timestamp="$($DATE_CMD -u '+%Y-%m-%dT%H:%M:%SZ')"

    # days_left is an integer for cert results, "-" for errors → use null
    local days_json
    [[ "$days_left" =~ ^-?[0-9]+$ ]] && days_json="$days_left" || days_json="null"

    # expiry_date is "-" for errors → use null
    local date_json
    [ "$short_date" = "-" ] && date_json="null" || date_json="\"$(_json_str "$short_date")\""

    local payload
    payload=$(printf '{"event":"%s","timestamp":"%s","hostname":"%s","status":"%s","days_left":%s,"expiry_date":%s,"ca":"%s","chain":"%s"}' \
        "$(_json_str "$type")" \
        "$(_json_str "$timestamp")" \
        "$(_json_str "$hostname")" \
        "$(_json_str "$status")" \
        "$days_json" \
        "$date_json" \
        "$(_json_str "$ca_name")" \
        "$(_json_str "$chain_status")")

    _post "$payload"
}

# ── Delivery hooks ───────────────────────────────────────────
deliver_finding() {
    local hostname="$1" status="$2" days_left="$3" short_date="$4"
    local ca_name="$5" chain_status="${6:-OK}"
    _post_event "finding" \
        "$hostname" "$status" "$days_left" "$short_date" "$ca_name" "$chain_status"
}

deliver_reminder() {
    local hostname="$1" status="$2" days_left="$3" short_date="$4"
    local ca_name="$5" chain_status="${6:-OK}"
    _post_event "reminder" \
        "$hostname" "$status" "$days_left" "$short_date" "$ca_name" "$chain_status"
}

on_group() { :; }

# ── Wire escalation logic ────────────────────────────────────
install_escalation_hooks

# ── Run ──────────────────────────────────────────────────────
run_server_loop "$SERVER_FILE"

# ── Post summary ─────────────────────────────────────────────
if [ "$WEBHOOK_SEND_SUMMARY" = "true" ]; then
    timestamp="$($DATE_CMD -u '+%Y-%m-%dT%H:%M:%SZ')"
    payload=$(printf '{"event":"summary","timestamp":"%s","total":%d,"warned":%d,"errors":%d,"new_issues":%d,"reminders":%d}' \
        "$(_json_str "$timestamp")" \
        "$total" "$warned" "$errors" "$new_issues" "$reminders")
    _post "$payload"
fi

logger -t check-certs "Webhook – ${new_issues} new, ${reminders} reminder(s), ${errors} error(s) of ${total} checked"

[ $((new_issues + reminders)) -gt 0 ] && exit 1 || exit 0
