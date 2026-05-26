#!/bin/bash

# ============================================================
#  check-certs-teams.sh – Microsoft Teams Adaptive Card wrapper
#
#  Sends a single Adaptive Card to a Teams Workflow webhook.
#  Only non-OK servers are shown, grouped by section. Empty
#  groups are suppressed. A summary line covers all servers.
#  The card is only sent when notification thresholds are
#  reached (new findings or daily reminders). Silent runs
#  produce no output.
#
#  Setup: create a Workflow in Teams using the template
#    "Post to a channel when a webhook request is received"
#    Copy the generated URL and set it as TEAMS_WEBHOOK_URL
#    in check-certs.conf. No Power Automate configuration
#    beyond the initial template setup is required.
#
#  Requirements: openssl, curl
#  Configure:    TEAMS_WEBHOOK_URL in check-certs.conf
#
#  Schedule:
#    Linux cron (daily at 07:00):
#      0 7 * * * /opt/check-certs/check-certs-teams.sh
#    macOS: use install/com.check-certs.teams.plist
#           (installed automatically by install.sh)
# ============================================================

CORE="$(dirname "$0")/check-certs.sh"
[ -f "$CORE" ] || { echo "Error: check-certs.sh not found (expected: $CORE)" >&2; exit 1; }

# shellcheck source=check-certs.sh
source "$CORE"
configure_wrapper

# ── State directory default for this variant ─────────────────
# Each variant uses its own directory; one file per monitored host.
if [ -z "${STATE_FILE:-}" ]; then
    if [[ "$(uname)" == "Darwin" ]]; then
        STATE_FILE="$HOME/Library/Application Support/check-certs/state-teams"
    else
        STATE_FILE="/var/lib/check-certs/state-teams"
    fi
fi
state_init

# ── Config ───────────────────────────────────────────────────
: "${TEAMS_WEBHOOK_URL:=}"
: "${TEAMS_DEBUG:=false}"   # set to true to print the card JSON without posting

if [ -z "$TEAMS_WEBHOOK_URL" ]; then
    echo "Error: TEAMS_WEBHOOK_URL is not set. Add it to check-certs.conf." >&2
    exit 1
fi
if ! command -v curl &>/dev/null; then
    echo "Error: curl is required but not installed." >&2
    exit 1
fi

# ── JSON string escaping ─────────────────────────────────────
_json_str() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# ── Result collection ─────────────────────────────────────────
# Each field stored in a separate array indexed by _row_count.
# _groups[] interleaves "GROUP:name" and "ROW:N" markers.

declare -a _groups=()
declare -a _r_host=() _r_days=() _r_date=() _r_status=() _r_ca=() _r_color=()
_row_count=0

# Track which rows have notifiable status for card suppression
_has_findings=false

# ── Delivery hooks ────────────────────────────────────────────
# The Teams variant collects all results in arrays (via on_cert_result
# below) and sends a single card at the end. deliver_finding and
# deliver_reminder only set the _has_findings flag so the card is
# suppressed when nothing actionable happened.
deliver_finding() {
    _has_findings=true
}

deliver_reminder() {
    _has_findings=true
}

on_group() {
    _groups+=("GROUP:$1")
}

# ── Event hooks – collect every result ───────────────────────
install_escalation_hooks

on_cert_result() {
    local hostname="$1" port="$2" days_left="$3" short_date="$4"
    local ca_name="$5" status="$6" prev_status="$7" hours_since="$8"
    local chain_status="${9:-OK}"

    _escalation_on_cert_result "$@"

    local days_display
    if [[ "$days_left" =~ ^-[0-9]+$ ]]; then
        days_display="EXP -${days_left#-}d"
    elif [[ "$days_left" =~ ^[0-9]+$ ]]; then
        days_display="${days_left}d"
    else
        days_display="-"
    fi

    local color
    case "$status" in
        OK)               color="good"    ;;
        WARNING)          color="warning" ;;
        CRITICAL|EXPIRED) color="attention" ;;
        URGENT)           color="attention" ;;
        *)                color="attention" ;;
    esac

    local chain_note=""
    [ "$chain_status" != "OK" ] && chain_note=" ⚠ chain"

    # Only include non-OK results in the card
    if [ "$status" != "OK" ]; then
        _r_host+=("$hostname")
        _r_days+=("$days_display")
        _r_date+=("$short_date")
        _r_status+=("$status${chain_note}")
        _r_ca+=("$ca_name")
        _r_color+=("$color")
        _groups+=("ROW:$_row_count")
        _row_count=$(( _row_count + 1 ))
    fi
}

on_cert_error() {
    local hostname="$1" port="$2" reason="$3" prev_status="$4" hours_since="$5"

    _escalation_on_cert_error "$@"

    _r_host+=("$hostname")
    _r_days+=("-")
    _r_date+=("-")
    _r_status+=("ERROR")
    _r_ca+=("$reason")
    _r_color+=("attention")
    _groups+=("ROW:$_row_count")
    _row_count=$(( _row_count + 1 ))
}

# ── Run ──────────────────────────────────────────────────────
[ -f "$SERVER_FILE" ] || {
    echo "Error: server file not found: $SERVER_FILE" >&2
    exit 1
}

run_server_loop "$SERVER_FILE"

# Only send card when there are actual findings or reminders
if [ "$_has_findings" = false ]; then
    logger -t check-certs \
        "Teams – no notifications due (${total} checked, ${errors} errors)"
    exit 0
fi

# ── Build Adaptive Card ───────────────────────────────────────
_timestamp=$($DATE_CMD '+%Y-%m-%d %H:%M')

# Determine overall severity for card header colour
if [ "$warned" -eq 0 ] && [ "$errors" -eq 0 ]; then
    _header_color="good"
    _header_text="✅ All certificates OK"
elif [ "$errors" -gt 0 ]; then
    _header_color="attention"
    _header_text="🚨 Certificate issues found"
else
    _header_color="warning"
    _header_text="⚠️ Certificate warnings"
fi

# Determine if this is a reminder run
if [ "$reminders" -gt 0 ] && [ "$new_issues" -eq 0 ]; then
    if [ "$errors" -gt 0 ]; then
        _header_text="🔁 Reminder: certificate issues unresolved"
    else
        _header_text="🔁 Reminder: certificates expiring soon"
    fi
fi

# Build the body array — column headers first, then rows grouped by section
_body='['

# Header row
_body+='{"type":"ColumnSet","spacing":"None","columns":['
_body+='{"type":"Column","width":"stretch","items":[{"type":"TextBlock","text":"Server","weight":"Bolder","size":"Small"}]},'
_body+='{"type":"Column","width":"110px","items":[{"type":"TextBlock","text":"Expiry","weight":"Bolder","size":"Small"}]},'
_body+='{"type":"Column","width":"80px","items":[{"type":"TextBlock","text":"Status","weight":"Bolder","size":"Small"}]}'
_body+=']},'

# (separator is a property, not an element — omitted)

# Rows and group headers
# Groups are only emitted when at least one non-OK row follows them
_pending_group=""
for entry in "${_groups[@]}"; do
    kind="${entry%%:*}"
    value="${entry#*:}"

    if [ "$kind" = "GROUP" ]; then
        _pending_group="$value"
    elif [ "$kind" = "ROW" ]; then
        # Emit buffered group label before the first row in this group
        if [ -n "$_pending_group" ]; then
            _body+=$(printf '{"type":"TextBlock","text":"— %s","weight":"Bolder","size":"Small","spacing":"Small"},' \
                "$(_json_str "$_pending_group")")
            _pending_group=""
        fi
        _idx="$value"
        _fmt='{"type":"ColumnSet","spacing":"None","columns":['
        _fmt+='{"type":"Column","width":"stretch","items":[{"type":"TextBlock","text":"%s","size":"Small","wrap":true}]},'
        _fmt+='{"type":"Column","width":"110px","items":[{"type":"TextBlock","text":"%s","size":"Small"}]},'
        _fmt+='{"type":"Column","width":"80px","items":[{"type":"TextBlock","text":"%s","size":"Small","weight":"Bolder"}]}'
        _fmt+=']},'
        _body+=$(printf "$_fmt" \
            "$(_json_str "${_r_host[$_idx]}")" \
            "$(_json_str "${_r_date[$_idx]}")" \
            "$(_json_str "${_r_status[$_idx]}")")
    fi
done

# Remove trailing comma and close body
_body="${_body%,}"
_body+=']'

# Summary footer
_ok_count=$(( total - warned - errors ))
_summary=$(printf '%d checked  ·  ✓ %d OK  ·  ⚠ %d Warning  ·  ✗ %d Critical/Error' \
    "$total" "$_ok_count" "$warned" "$errors")

# Assemble the full Adaptive Card payload
# Teams Workflow webhooks require the message wrapper format
_header_container=$(printf '{"type":"TextBlock","text":"%s","weight":"Bolder","size":"Large","wrap":true},{"type":"TextBlock","text":"%s","size":"Small","isSubtle":true}' \
    "$(_json_str "$_header_text")" "$(_json_str "$_timestamp")")

# No Container wrapper — items go directly into body
_table_container="$_body"

_summary_block=$(printf '{"type":"TextBlock","text":"%s","size":"Small","isSubtle":true}' \
    "$(_json_str "$_summary")")

# Splice all body items directly into one flat array
_ac_content=$(printf '{"$schema":"http://adaptivecards.io/schemas/adaptive-card.json","type":"AdaptiveCard","version":"1.2","body":[%s,%s,%s]}' \
    "$_header_container" "${_table_container:1:${#_table_container}-2}" "$_summary_block")

_card=$(printf '{"type":"message","attachments":[{"contentType":"application/vnd.microsoft.card.adaptive","contentUrl":null,"content":%s}]}' \
    "$_ac_content")

# ── Post card ─────────────────────────────────────────────────
_post_card() {
    local payload_file
    payload_file=$(mktemp)
    printf '%s' "$1" > "$payload_file"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$TEAMS_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        --data-binary "@${payload_file}" 2>/dev/null)

    if [ -z "$http_code" ] || [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        sleep 5
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "$TEAMS_WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            --data-binary "@${payload_file}" 2>/dev/null)
        if [ -z "$http_code" ] || [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
            echo "Warning: Teams POST failed (HTTP ${http_code:-no response})" >&2
            rm -f "$payload_file"
            return 1
        fi
    fi
    rm -f "$payload_file"
    return 0
}

if [ "$TEAMS_DEBUG" = "true" ]; then
    printf '%s\n' "$_card"
    echo "" >&2
    printf '%s' "$_card" | python3 -m json.tool >/dev/null 2>&1 \
        && echo "[DEBUG] JSON valid" >&2 \
        || echo "[DEBUG] WARNING: JSON invalid" >&2
    exit 0
fi
_post_card "$_card"

logger -t check-certs \
    "Teams – ${new_issues} new, ${reminders} reminder(s), ${errors} error(s) of ${total} checked"

[ $((new_issues + reminders)) -gt 0 ] && exit 1 || exit 0
