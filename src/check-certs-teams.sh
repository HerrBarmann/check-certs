#!/bin/bash

# ============================================================
#  check-certs-teams.sh – Microsoft Teams Adaptive Card wrapper
#
#  Sends a single Adaptive Card to a Teams Workflow webhook
#  mirroring the terminal table output — all servers, grouped
#  by section, with a colour-coded status column and summary.
#
#  The card is only sent when notification thresholds are
#  reached (new findings or daily reminders). Silent runs
#  produce no output.
#
#  Setup: create a Workflow in Teams using the template
#    "Post to a channel when a webhook request is received"
#    Copy the generated URL and set it as TEAMS_WEBHOOK_URL
#    in check-certs.conf. No Power Automate configuration
#    beyond the initial template setup is required — this
#    wrapper sends a complete Adaptive Card directly.
#
#  Requirements: openssl, curl
#  Configure:    TEAMS_WEBHOOK_URL in check-certs.conf
#
#  Cron job example (daily at 07:00):
#    0 7 * * * /opt/check-certs/check-certs-teams.sh
# ============================================================

CORE="$(dirname "$0")/check-certs.sh"
[ -f "$CORE" ] || { echo "Error: check-certs.sh not found (expected: $CORE)" >&2; exit 1; }

# shellcheck source=check-certs.sh
source "$CORE"
configure_wrapper

# ── State file ───────────────────────────────────────────────
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

    _r_host+=("$hostname")
    _r_days+=("$days_display")
    _r_date+=("$short_date")
    _r_status+=("$status${chain_note}")
    _r_ca+=("$ca_name")
    _r_color+=("$color")
    _groups+=("ROW:$_row_count")
    _row_count=$(( _row_count + 1 ))
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
_timestamp=$(date '+%Y-%m-%d %H:%M')

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
_body+='{"type":"ColumnSet","columns":['
_body+='{"type":"Column","width":"stretch","items":[{"type":"TextBlock","text":"**Server**","wrap":true}]},'
_body+='{"type":"Column","width":"auto","items":[{"type":"TextBlock","text":"**Days**"}]},'
_body+='{"type":"Column","width":"auto","items":[{"type":"TextBlock","text":"**Expiry**"}]},'
_body+='{"type":"Column","width":"auto","items":[{"type":"TextBlock","text":"**Status**"}]},'
_body+='{"type":"Column","width":"stretch","items":[{"type":"TextBlock","text":"**CA**","wrap":true}]}'
_body+=']},'

# Separator
_body+='{"type":"Separator"},'

# Rows and group headers
_current_group=""
for entry in "${_groups[@]}"; do
    kind="${entry%%:*}"
    value="${entry#*:}"

    if [ "$kind" = "GROUP" ]; then
        _body+=$(printf '{"type":"TextBlock","text":"%s","weight":"Bolder","spacing":"Medium","color":"Accent"},' \
            "$(_json_str "$value")")
    elif [ "$kind" = "ROW" ]; then
        local _idx="$value"
        local _h _d _dt _st _ca _cl
        _h="${_r_host[$_idx]}"
        _d="${_r_days[$_idx]}"
        _dt="${_r_date[$_idx]}"
        _st="${_r_status[$_idx]}"
        _ca="${_r_ca[$_idx]}"
        _cl="${_r_color[$_idx]}"
        _body+='{"type":"ColumnSet","columns":['
        _body+='{"type":"Column","width":"stretch","items":[{"type":"TextBlock","text":"'"$(_json_str "$_h")"'"","wrap":true,"size":"Small"}]},'
        _body+='{"type":"Column","width":"auto","items":[{"type":"TextBlock","text":"'"$(_json_str "$_d")"'"","color":"'"$_cl"'"","size":"Small"}]},'
        _body+='{"type":"Column","width":"auto","items":[{"type":"TextBlock","text":"'"$(_json_str "$_dt")"'"","size":"Small"}]},'
        _body+='{"type":"Column","width":"auto","items":[{"type":"TextBlock","text":"'"$(_json_str "$_st")"'"","color":"'"$_cl"'"","weight":"Bolder","size":"Small"}]},'
        _body+='{"type":"Column","width":"stretch","items":[{"type":"TextBlock","text":"'"$(_json_str "$_ca")"'"","wrap":true,"size":"Small","isSubtle":true}]}'
        _body+=']},'
    fi
done

# Remove trailing comma and close body
_body="${_body%,}"
_body+=']'

# Summary footer
_ok_count=$(( total - warned ))
_summary=$(printf '%d checked  ·  ✓ %d OK  ·  ⚠ %d Warning  ·  ✗ %d Critical/Error' \
    "$total" "$_ok_count" "$warned" "$errors")

# Assemble the full Adaptive Card payload
# Teams Workflow webhooks require the message wrapper format
_card=$(cat << CARD
{
  "type": "message",
  "attachments": [
    {
      "contentType": "application/vnd.microsoft.card.adaptive",
      "contentUrl": null,
      "content": {
        "\$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        "type": "AdaptiveCard",
        "version": "1.4",
        "body": [
          {
            "type": "Container",
            "style": "$_header_color",
            "items": [
              {
                "type": "TextBlock",
                "text": "$(_json_str "$_header_text")",
                "weight": "Bolder",
                "size": "Medium",
                "color": "Light"
              },
              {
                "type": "TextBlock",
                "text": "$(_json_str "$_timestamp")",
                "size": "Small",
                "color": "Light",
                "isSubtle": true
              }
            ]
          },
          {
            "type": "Container",
            "items": $_body
          },
          {
            "type": "TextBlock",
            "text": "$(_json_str "$_summary")",
            "size": "Small",
            "isSubtle": true,
            "separator": true,
            "spacing": "Medium"
          }
        ]
      }
    }
  ]
}
CARD
)

# ── Post card ─────────────────────────────────────────────────
_post_card() {
    local payload="$1"
    local -a args=(-s -o /dev/null -w "%{http_code}" \
        -X POST "$TEAMS_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$payload")

    local http_code
    http_code=$(curl "${args[@]}" 2>/dev/null)

    if [ -z "$http_code" ] || [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        sleep 5
        http_code=$(curl "${args[@]}" 2>/dev/null)
        if [ -z "$http_code" ] || [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
            echo "Warning: Teams POST failed (HTTP ${http_code:-no response})" >&2
            return 1
        fi
    fi
    return 0
}

_post_card "$_card"

logger -t check-certs \
    "Teams – ${new_issues} new, ${reminders} reminder(s), ${errors} error(s) of ${total} checked"

[ $((new_issues + reminders)) -gt 0 ] && exit 1 || exit 0
