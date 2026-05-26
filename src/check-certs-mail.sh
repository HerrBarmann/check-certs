#!/bin/bash

# ============================================================
#  check-certs-mail.sh – Email notification wrapper
#  Runs daily via cron (Linux) or launchd (macOS). Sends an
#  email when findings change or when a daily reminder is due
#  for persistent issues. Silent when everything is OK.
#
#  Mail transport is selected via MAIL_TRANSPORT in
#  check-certs.conf:
#    MAIL_TRANSPORT=postfix    – send via mailutils (Linux)
#    MAIL_TRANSPORT=ssmtp      – send via ssmtp (Linux + macOS)
#    MAIL_TRANSPORT=sendmail   – send via any MTA providing
#                                a sendmail-compatible interface
#
#  Requirements:
#    postfix:   openssl, mailutils  (apt install mailutils)
#    ssmtp:     openssl, ssmtp      (apt install ssmtp / brew install ssmtp)
#    sendmail:  openssl, any MTA providing /usr/sbin/sendmail
#
#  Schedule:
#    Linux cron (daily at 07:00):
#      0 7 * * * /opt/check-certs/check-certs-mail.sh
#    macOS launchd (daily at 07:00):
#      use install/com.check-certs.mail.plist
#      (installed automatically by install.sh)
# ============================================================

CORE="$(dirname "$0")/check-certs.sh"
[ -f "$CORE" ] || { echo "Error: check-certs.sh not found (expected: $CORE)" >&2; exit 1; }

# ── Load check-certs.sh (functions + escalation logic) ───────
# shellcheck source=check-certs.sh
source "$CORE"

# configure_wrapper loads check-certs.conf and applies defaults
configure_wrapper

# ── State file default for this variant ──────────────────────
# Each variant has its own state directory so multiple variants can run side by side.
# The directory holds one small file per monitored host.
if [ -z "${STATE_FILE:-}" ]; then
    if [[ "$(uname)" == "Darwin" ]]; then
        STATE_FILE="$HOME/Library/Application Support/check-certs/state-mail"
    else
        STATE_FILE="/var/lib/check-certs/state-mail"
    fi
fi
state_init

# ── Email defaults (if not set in check-certs.conf) ──────────
: "${MAIL_TRANSPORT:=postfix}"
: "${MAIL_TO:=admin@example.com}"
: "${MAIL_TO_URGENT:=$MAIL_TO}"
_fqdn=$(hostname -f 2>/dev/null || hostname)
: "${MAIL_FROM:=certcheck@${_fqdn:-localhost}}"
unset _fqdn

# ── Validate transport ────────────────────────────────────────
case "$MAIL_TRANSPORT" in
    postfix)
        if ! command -v mail &>/dev/null; then
            echo "Error: 'mail' command not found. Install mailutils: apt install mailutils" >&2
            exit 1
        fi ;;
    ssmtp)
        if ! command -v ssmtp &>/dev/null; then
            echo "Error: 'ssmtp' not found. Install: apt install ssmtp (Linux) or brew install ssmtp (macOS)" >&2
            exit 1
        fi ;;
    sendmail)
        if [ ! -x /usr/sbin/sendmail ] && ! command -v sendmail &>/dev/null; then
            echo "Error: 'sendmail' not found. Install an MTA that provides it." >&2
            exit 1
        fi
        _SENDMAIL_CMD=$(command -v sendmail 2>/dev/null || echo "/usr/sbin/sendmail") ;;
    *)
        echo "Error: unknown MAIL_TRANSPORT '${MAIL_TRANSPORT}'. Use 'postfix', 'ssmtp', or 'sendmail'." >&2
        exit 1
        ;;
esac

# ── Validate recipients ───────────────────────────────────────
if [[ "$MAIL_TO" == *"example.com"* ]]; then
    echo "Warning: MAIL_TO appears to be a placeholder ('${MAIL_TO}'). Update check-certs.conf." >&2
fi

# ── Internal variables ───────────────────────────────────────
report_new=""
report_reminder=""
report_known=""
hline_text="$(printf '%.0s─' {1..80})"

# ── Format a report row ──────────────────────────────────────
_format_row() {
    local hostname="$1" status="$2" days_left="$3" short_date="$4"
    local ca_name="$5" chain_status="${6:-OK}"
    local ca_info="CA: ${ca_name}"
    [ "$chain_status" != "OK" ] && ca_info="CA: ${ca_name} | Chain: ${chain_status}"

    local label
    case "$status" in
        RENEWED)  label="✓ Certificate renewed | ${ca_info}" ;;
        ERROR)    label="ERROR: ${ca_name}" ;;
        EXPIRED)  label="EXPIRED (${days_left#-}d overdue) | ${ca_info}" ;;
        URGENT)   label="URGENT: ${days_left}d remaining | ${ca_info}" ;;
        CRITICAL) label="CRITICAL: ${days_left}d remaining | ${ca_info}" ;;
        *)        label="WARNING: ${days_left}d remaining | ${ca_info}" ;;
    esac

    local days_display
    if [[ "$days_left" =~ ^-[0-9]+$ ]]; then
        days_display="${days_left#-}d"
    elif [[ "$days_left" =~ ^[0-9]+$ ]]; then
        days_display="${days_left}d"
    else
        days_display="-"
    fi

    printf '%-38s  %-6s  %-20s  %s\n' "$hostname" "$days_display" "$short_date" "$label"
}

# ── Delivery hooks ───────────────────────────────────────────
deliver_finding() {
    local hostname="$1" status="$2" days_left="$3" short_date="$4"
    local ca_name="$5" chain_status="${6:-OK}"
    report_new+="$(_format_row "$hostname" "$status" "$days_left" "$short_date" "$ca_name" "$chain_status")"$'\n'
}

deliver_reminder() {
    local hostname="$1" status="$2" days_left="$3" short_date="$4"
    local ca_name="$5" chain_status="${6:-OK}"
    report_reminder+="$(_format_row "$hostname" "$status" "$days_left" "$short_date" "$ca_name" "$chain_status")"$'\n'
}

# Group headers not used in email reports
on_group() { :; }

# ── Wire escalation logic ────────────────────────────────────
install_escalation_hooks

# Capture servers that are in a known persistent state but not yet due
# for a reminder. They are included in any email that is sent so the
# recipient always sees the full picture, not just the new findings.
on_cert_result() {
    local hostname="$1" port="$2" days_left="$3" short_date="$4"
    local ca_name="$5" status="$6" prev_status="$7" hours_since="$8"
    local chain_status="${9:-OK}"
    _escalation_on_cert_result "$@"
    # If escalation did not call deliver_finding or deliver_reminder
    # (status unchanged and reminder not yet due), add to known list.
    # Translate stored abbreviations (WARN/CRIT) to runtime values before comparing.
    local state_status
    case "$prev_status" in
        WARN)    state_status="WARNING"  ;;
        CRIT)    state_status="CRITICAL" ;;
        URGENT)  state_status="URGENT"   ;;
        EXPIRED) state_status="EXPIRED"  ;;
        *)       state_status="$prev_status" ;;
    esac
    if [ "$status" != "OK" ] && [ "$status" = "$state_status" ] && [ "$hours_since" -lt 23 ]; then
        report_known+="$(_format_row "$hostname" "$status" "$days_left" "$short_date" "$ca_name" "$chain_status")"$'\n'
    fi
}

on_cert_error() {
    local hostname="$1" reason="$3" prev_status="$4" hours_since="$5"
    _escalation_on_cert_error "$@"
    # Add to the known-issues list when the error is persistent and not
    # yet due for a reminder — same window logic as on_cert_result above.
    # Translate reason to the stored state key to match prev_status.
    local err_status
    [ "$reason" = "Invalid port" ] && err_status="ERROR_PORT" || err_status="ERROR_CONNECT"
    if [ "$prev_status" = "$err_status" ] && [ "$hours_since" -lt 23 ]; then
        report_known+="$(_format_row "$hostname" "ERROR" "-" "-" "$reason" "OK")"$'\n'
    fi
}

# ── Send emails ──────────────────────────────────────────────
_send_mail() {
    local subject="$1" recipient="$2" body="$3"
    case "$MAIL_TRANSPORT" in
        ssmtp)
            {
                printf 'To: %s\n'      "$recipient"
                printf 'From: %s\n'    "$MAIL_FROM"
                printf 'Subject: %s\n' "$subject"
                printf 'Content-Type: text/plain; charset=UTF-8\n'
                printf '\n'
                printf '%s\n'          "$body"
            } | ssmtp "$recipient"
            ;;
        sendmail)
            {
                printf 'To: %s\n'      "$recipient"
                printf 'From: %s\n'    "$MAIL_FROM"
                printf 'Subject: %s\n' "$subject"
                printf 'Content-Type: text/plain; charset=UTF-8\n'
                printf '\n'
                printf '%s\n'          "$body"
            } | "$_SENDMAIL_CMD" -f "$MAIL_FROM" "$recipient"
            ;;
        *)
            echo "$body" | mail -s "$subject" -a "From: $MAIL_FROM" "$recipient"
            ;;
    esac
}

_build_table() {
    printf '%s\n' "$hline_text"
    printf '%-38s  %-6s  %-20s  %s\n' 'Server' 'Days' 'Expiry date' 'Status / CA'
    printf '%s\n' "$hline_text"
    printf '%s' "$1"
    printf '%s\n' "$hline_text"
}

# ── Run ──────────────────────────────────────────────────────
run_server_loop "$SERVER_FILE"

timestamp="$($DATE_CMD '+%Y-%m-%d at %H:%M')"
summary="Servers checked: ${total}  |  Non-OK: ${warned}  |  Errors: ${errors}"

if [ "$new_issues" -gt 0 ]; then
    body="SSL Certificate Check – New findings (${timestamp})"$'\n'
    body+="${summary}"$'\n\n'
    body+="$(_build_table "$report_new")"$'\n'
    [ -n "$report_known" ] && body+="Known ongoing issues:"$'\n\n'"$(_build_table "$report_known")"$'\n'
    body+="Please renew the affected certificates promptly."$'\n'

    if echo "$report_new" | grep -q "URGENT\|EXPIRED"; then
        subject="[check-certs] URGENT - Certificate expiring ($($DATE_CMD '+%Y-%m-%d'))"
        _send_mail "$subject" "$MAIL_TO" "$body"
        [ "$MAIL_TO_URGENT" != "$MAIL_TO" ] && _send_mail "$subject" "$MAIL_TO_URGENT" "$body"
    else
        _send_mail "[check-certs] Certificate warning ($($DATE_CMD '+%Y-%m-%d'))" "$MAIL_TO" "$body"
    fi
    logger -t check-certs "New findings sent – ${new_issues} new, ${errors} errors of ${total} checked"
fi

if [ "$reminders" -gt 0 ]; then
    body="SSL Certificate Check – Daily reminder (${timestamp})"$'\n'
    body+="${summary}"$'\n\n'
    body+="$(_build_table "$report_reminder")"$'\n'
    [ -n "$report_known" ] && body+="Known ongoing issues:"$'\n\n'"$(_build_table "$report_known")"$'\n'
    body+="These certificates have already been reported and have not yet been renewed."$'\n'

    if echo "$report_reminder" | grep -q "URGENT\|EXPIRED"; then
        subject="[check-certs] URGENT - Certificate reminder ($($DATE_CMD '+%Y-%m-%d'))"
        _send_mail "$subject" "$MAIL_TO" "$body"
        [ "$MAIL_TO_URGENT" != "$MAIL_TO" ] && _send_mail "$subject" "$MAIL_TO_URGENT" "$body"
    else
        _send_mail "[check-certs] Certificate reminder ($($DATE_CMD '+%Y-%m-%d'))" "$MAIL_TO" "$body"
    fi
    logger -t check-certs "Reminder sent – ${reminders} known issues"
fi

[ $((new_issues + reminders)) -gt 0 ] && exit 1 || exit 0
