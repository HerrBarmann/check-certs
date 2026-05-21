#!/bin/bash

# ============================================================
#  install-linux.sh – Installs check-certs on Debian/Ubuntu
#
#  Always installs:
#    check-certs.sh      – terminal table view + shell alias
#
#  Optionally installs one automation variant:
#    check-certs-mail.sh    – email via Postfix or ssmtp
#    check-certs-webhook.sh     – HTTP POST webhook
#
#  Usage: sudo ./install-linux.sh
# ============================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

TARGET_DIR="/opt/check-certs"
CONF_NAME="servers.conf"
INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$INSTALL_DIR/../src" && pwd)"
CONF_DIR="$(cd "$INSTALL_DIR/../config" && pwd)"
CRON_USER="${SUDO_USER:-$USER}"
FQDN="$(hostname -f 2>/dev/null || hostname)"

# ── Root check ───────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}✗ This script must be run with sudo.${NC}"
    echo "  Usage: sudo ./install-linux.sh"
    exit 1
fi

echo ""
echo -e "${BOLD}check-certs Installer${NC} ${CYAN}(Debian/Ubuntu)${NC}"
echo "──────────────────────────────"
echo ""

# ── Verify core source files ─────────────────────────────────
if [ ! -f "$SRC_DIR/check-certs.sh" ]; then
    echo -e "${RED}✗ File 'check-certs.sh' not found (expected in: $SRC_DIR)${NC}"
    exit 1
fi
if [ ! -f "$CONF_DIR/$CONF_NAME" ]; then
    echo -e "${RED}✗ File '$CONF_NAME' not found (expected in: $CONF_DIR)${NC}"
    exit 1
fi

# ── Variant selection ─────────────────────────────────────────
echo -e "  check-certs.sh (terminal table view) will always be installed."
echo -e "  Would you also like to set up automated background monitoring?\n"
echo -e "  ${BOLD}1)${NC} Postfix email  – daily cron job, sends email via Postfix relay"
echo -e "  ${BOLD}2)${NC} ssmtp email    – daily cron job, sends email via ssmtp (no daemon)"
echo -e "  ${BOLD}3)${NC} sendmail       – daily cron job, uses your existing MTA"
echo -e "  ${BOLD}4)${NC} Webhook        – HTTP POST to Slack, ntfy, Teams, custom endpoints"
echo -e "  ${BOLD}5)${NC} Pushover       – mobile push notifications with priority levels"
echo -e "  ${BOLD}6)${NC} Terminal only  – skip automation for now"
echo ""
read -r -p "  Choose [1/2/3/4/5/6]: " VARIANT_CHOICE
echo ""

case "$VARIANT_CHOICE" in
    1) INSTALL_VARIANT="postfix"   ;;
    2) INSTALL_VARIANT="ssmtp"     ;;
    3) INSTALL_VARIANT="sendmail"  ;;
    4) INSTALL_VARIANT="webhook"   ;;
    5) INSTALL_VARIANT="pushover"  ;;
    *) INSTALL_VARIANT="none"      ;;
esac

# ── Verify variant source file exists ────────────────────────
case "$INSTALL_VARIANT" in
    postfix|ssmtp|sendmail)
        if [ ! -f "$SRC_DIR/check-certs-mail.sh" ]; then
            echo -e "${RED}✗ File 'check-certs-mail.sh' not found (expected in: $SRC_DIR)${NC}"
            exit 1
        fi ;;
    webhook)
        if [ ! -f "$SRC_DIR/check-certs-webhook.sh" ]; then
            echo -e "${RED}✗ File 'check-certs-webhook.sh' not found (expected in: $SRC_DIR)${NC}"
            exit 1
        fi ;;
    pushover)
        if [ ! -f "$SRC_DIR/check-certs-pushover.sh" ]; then
            echo -e "${RED}✗ File 'check-certs-pushover.sh' not found (expected in: $SRC_DIR)${NC}"
            exit 1
        fi ;;
esac

echo "──────────────────────────────"
echo ""

# ── Prompt helper functions ───────────────────────────────────

_prompt_thresholds() {
    read -r -p "  Warning threshold – first alert X days before expiry [15]: " WARN_DAYS
    WARN_DAYS="${WARN_DAYS:-15}"
    while ! [[ "$WARN_DAYS" =~ ^[0-9]+$ ]]; do
        echo -e "  ${RED}Please enter a number.${NC}"
        read -r -p "  Warning threshold in days [15]: " WARN_DAYS
        WARN_DAYS="${WARN_DAYS:-15}"
    done

    read -r -p "  Critical threshold – daily reminder from X days [7]: " CRIT_DAYS
    CRIT_DAYS="${CRIT_DAYS:-7}"
    while ! [[ "$CRIT_DAYS" =~ ^[0-9]+$ ]]; do
        echo -e "  ${RED}Please enter a number.${NC}"
        read -r -p "  Critical threshold in days [7]: " CRIT_DAYS
        CRIT_DAYS="${CRIT_DAYS:-7}"
    done

    read -r -p "  Urgent threshold – escalation from X days [2]: " URGENT_DAYS
    URGENT_DAYS="${URGENT_DAYS:-2}"
    while ! [[ "$URGENT_DAYS" =~ ^[0-9]+$ ]]; do
        echo -e "  ${RED}Please enter a number.${NC}"
        read -r -p "  Urgent threshold in days [2]: " URGENT_DAYS
        URGENT_DAYS="${URGENT_DAYS:-2}"
    done
}

_prompt_cron_time() {
    read -r -p "  Cron job time – hour (0–23) [7]: " CRON_HOUR
    CRON_HOUR="${CRON_HOUR:-7}"
    while ! [[ "$CRON_HOUR" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; do
        echo -e "  ${RED}Please enter a valid hour (0–23).${NC}"
        read -r -p "  Cron job time – hour (0–23) [7]: " CRON_HOUR
        CRON_HOUR="${CRON_HOUR:-7}"
    done

    read -r -p "  Cron job time – minute (0–59) [0]: " CRON_MINUTE
    CRON_MINUTE="${CRON_MINUTE:-0}"
    while ! [[ "$CRON_MINUTE" =~ ^([0-9]|[1-5][0-9])$ ]]; do
        echo -e "  ${RED}Please enter a valid minute (0–59).${NC}"
        read -r -p "  Cron job time – minute (0–59) [0]: " CRON_MINUTE
        CRON_MINUTE="${CRON_MINUTE:-0}"
    done
}

_prompt_email() {
    read -r -p "  Email recipient (e.g. admin@example.com): " MAIL_TO
    while [[ -z "$MAIL_TO" || ! "$MAIL_TO" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; do
        echo -e "  ${RED}Invalid email address. Please try again.${NC}"
        read -r -p "  Email recipient: " MAIL_TO
    done

    read -r -p "  Urgent email recipient [$MAIL_TO]: " MAIL_TO_URGENT
    MAIL_TO_URGENT="${MAIL_TO_URGENT:-$MAIL_TO}"
    while [[ ! "$MAIL_TO_URGENT" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; do
        echo -e "  ${RED}Invalid email address. Please try again.${NC}"
        read -r -p "  Urgent email recipient: " MAIL_TO_URGENT
    done

    read -r -p "  Sender address [certcheck@${FQDN}]: " MAIL_FROM
    MAIL_FROM="${MAIL_FROM:-certcheck@${FQDN}}"
}

_prompt_smtp() {
    read -r -p "  SMTP relay host (e.g. smtp.gmail.com): " SMTP_HOST
    while [ -z "$SMTP_HOST" ]; do
        echo -e "  ${RED}Please enter an SMTP host.${NC}"
        read -r -p "  SMTP relay host: " SMTP_HOST
    done

    read -r -p "  SMTP port [587]: " SMTP_PORT
    SMTP_PORT="${SMTP_PORT:-587}"
    while ! [[ "$SMTP_PORT" =~ ^[0-9]+$ ]]; do
        echo -e "  ${RED}Please enter a valid port number.${NC}"
        read -r -p "  SMTP port [587]: " SMTP_PORT
        SMTP_PORT="${SMTP_PORT:-587}"
    done

    read -r -p "  SMTP username (email address): " SMTP_USER
    while [[ -z "$SMTP_USER" || ! "$SMTP_USER" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; do
        echo -e "  ${RED}Invalid email address. Please try again.${NC}"
        read -r -p "  SMTP username: " SMTP_USER
    done

    read -r -s -p "  SMTP password (app password): " SMTP_PASS
    echo ""
    while [ -z "$SMTP_PASS" ]; do
        echo -e "  ${RED}Please enter a password.${NC}"
        read -r -s -p "  SMTP password: " SMTP_PASS
        echo ""
    done
}

# ── Variant-specific configuration prompts ────────────────────
case "$INSTALL_VARIANT" in

    postfix)
        echo -e "  ${BOLD}Postfix email variant${NC}"
        echo ""
        _prompt_email
        _prompt_smtp
        _prompt_thresholds
        _prompt_cron_time
        echo ""
        echo "──────────────────────────────"
        echo ""
        ;;

    ssmtp)
        echo -e "  ${BOLD}ssmtp email variant${NC}"
        echo ""
        _prompt_email
        _prompt_smtp
        _prompt_thresholds
        _prompt_cron_time
        echo ""
        echo "──────────────────────────────"
        echo ""
        ;;

    sendmail)
        echo -e "  ${BOLD}sendmail variant${NC}"
        echo "  Uses your existing MTA – no SMTP configuration needed."
        echo ""
        _prompt_email
        _prompt_thresholds
        _prompt_cron_time
        echo ""
        echo "──────────────────────────────"
        echo ""
        ;;

    webhook)
        echo -e "  ${BOLD}Webhook variant${NC}"
        echo ""
        read -r -p "  Webhook URL: " WEBHOOK_URL
        while [ -z "$WEBHOOK_URL" ]; do
            echo -e "  ${RED}Please enter a webhook URL.${NC}"
            read -r -p "  Webhook URL: " WEBHOOK_URL
        done

        read -r -p "  Auth header name (leave blank if none): " WEBHOOK_AUTH_HEADER
        if [ -n "$WEBHOOK_AUTH_HEADER" ]; then
            read -r -p "  Auth header value: " WEBHOOK_AUTH_VALUE
        fi

        read -r -p "  Post summary event after each run? [Y/n]: " _ws
        [[ "$_ws" =~ ^[nN]$ ]] && WEBHOOK_SEND_SUMMARY="false" || WEBHOOK_SEND_SUMMARY="true"

        _prompt_thresholds
        _prompt_cron_time
        echo ""
        echo "──────────────────────────────"
        echo ""
        ;;

    pushover)
        echo -e "  ${BOLD}Pushover variant${NC}"
        echo ""
        read -r -p "  Pushover app token: " PUSHOVER_APP_TOKEN
        while [ -z "$PUSHOVER_APP_TOKEN" ]; do
            echo -e "  ${RED}Please enter your Pushover app token.${NC}"
            read -r -p "  Pushover app token: " PUSHOVER_APP_TOKEN
        done

        read -r -p "  Pushover user key: " PUSHOVER_USER_KEY
        while [ -z "$PUSHOVER_USER_KEY" ]; do
            echo -e "  ${RED}Please enter your Pushover user key.${NC}"
            read -r -p "  Pushover user key: " PUSHOVER_USER_KEY
        done

        read -r -p "  Device name (leave blank for all devices): " PUSHOVER_DEVICE

        _prompt_thresholds
        _prompt_cron_time
        echo ""
        echo "──────────────────────────────"
        echo ""
        ;;

    none)
        echo -e "  ${BOLD}Terminal only${NC} – no automation variant will be installed."
        echo ""
        echo "──────────────────────────────"
        echo ""
        ;;
esac

# ── Install packages ─────────────────────────────────────────
echo "  Updating package lists..."
apt-get update -qq
echo -e "${GREEN}✓ Package lists updated${NC}"

echo "  Installing openssl..."
apt-get install -y -qq openssl
echo -e "${GREEN}✓ openssl installed${NC}"

case "$INSTALL_VARIANT" in
    postfix)
        echo "  Installing postfix, mailutils, libsasl2-modules..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postfix mailutils libsasl2-modules
        echo -e "${GREEN}✓ postfix and mailutils installed${NC}"
        ;;
    ssmtp)
        echo "  Installing ssmtp..."
        apt-get install -y -qq ssmtp
        echo -e "${GREEN}✓ ssmtp installed${NC}"
        ;;
    sendmail)
        if ! command -v sendmail &>/dev/null && [ ! -x /usr/sbin/sendmail ]; then
            echo -e "${YELLOW}⚠ No sendmail binary found. Ensure your MTA is installed and provides sendmail.${NC}"
        else
            echo -e "${GREEN}✓ sendmail binary found${NC}"
        fi
        ;;
    webhook|pushover)
        echo "  Installing curl..."
        apt-get install -y -qq curl
        echo -e "${GREEN}✓ curl installed${NC}"
        ;;
esac

# ── Configure Postfix ────────────────────────────────────────
if [ "$INSTALL_VARIANT" = "postfix" ]; then
    if [ -f /etc/postfix/main.cf ]; then
        echo -e "${YELLOW}⚠ Existing Postfix configuration found – will not be overwritten.${NC}"
        echo "  SMTP relay settings must be added manually to /etc/postfix/main.cf"
        echo "  See docs/linux-email.md for the required directives."
    else
        echo "  Configuring Postfix..."

        cat > /etc/postfix/main.cf <<EOF
# Postfix configuration (generated by install-linux.sh)
smtpd_banner = \$myhostname ESMTP
biff = no
append_dot_mydomain = no
readme_directory = no

myhostname = ${FQDN}
myorigin = /etc/mailname
mydestination = localhost
relayhost = [${SMTP_HOST}]:${SMTP_PORT}
mynetworks = 127.0.0.0/8

# TLS
smtp_use_tls = yes
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt
smtp_tls_session_cache_database = btree:\${data_directory}/smtp_scache

# SASL authentication
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous

# Rewrite sender address
smtp_generic_maps = hash:/etc/postfix/generic
EOF

        echo "${FQDN}" > /etc/mailname

        echo "[${SMTP_HOST}]:${SMTP_PORT} ${SMTP_USER}:${SMTP_PASS}" > /etc/postfix/sasl_passwd
        postmap /etc/postfix/sasl_passwd
        chmod 600 /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db

        echo "root ${MAIL_FROM}" > /etc/postfix/generic
        postmap /etc/postfix/generic

        systemctl enable postfix -q
        systemctl restart postfix
        echo -e "${GREEN}✓ Postfix configured and started${NC}"
    fi
fi

# ── Configure ssmtp ──────────────────────────────────────────
if [ "$INSTALL_VARIANT" = "ssmtp" ]; then
    if [ -f /etc/ssmtp/ssmtp.conf ]; then
        echo -e "${YELLOW}⚠ Existing ssmtp configuration found – will not be overwritten.${NC}"
        echo "  Edit /etc/ssmtp/ssmtp.conf manually if SMTP settings need updating."
    else
        echo "  Writing /etc/ssmtp/ssmtp.conf..."
        mkdir -p /etc/ssmtp
        cat > /etc/ssmtp/ssmtp.conf <<EOF
# ssmtp configuration (generated by install-linux.sh)

# Address that mail appears to come from
root=${MAIL_FROM}

# SMTP relay host and port
mailhub=${SMTP_HOST}:${SMTP_PORT}

# SMTP credentials
AuthUser=${SMTP_USER}
AuthPass=${SMTP_PASS}

# TLS
UseTLS=YES
UseSTARTTLS=YES

# Server hostname (used in EHLO)
hostname=${FQDN}

# Rewrite sender to root address
FromLineOverride=YES
EOF
        chmod 640 /etc/ssmtp/ssmtp.conf
        echo -e "${GREEN}✓ ssmtp configured${NC}"
    fi
fi

# ── Copy files ───────────────────────────────────────────────
mkdir -p "$TARGET_DIR"

cp "$SRC_DIR/check-certs.sh" "$TARGET_DIR/check-certs.sh"
chmod +x "$TARGET_DIR/check-certs.sh"
echo -e "${GREEN}✓ check-certs.sh installed${NC}"

# Shell alias – add to the invoking user's rc files; skip root's home
# when CRON_USER is a regular user (root's .bashrc is already in the list)
ALIAS_LINE="alias check-certs=\"$TARGET_DIR/check-certs.sh\""
declare -a RC_FILES=("/root/.bashrc")
if [ "$CRON_USER" != "root" ]; then
    RC_FILES+=("/home/$CRON_USER/.bashrc")
fi
for config in "${RC_FILES[@]}"; do
    [ -f "$config" ] || continue
    if grep -q "alias check-certs" "$config"; then
        echo -e "${YELLOW}⚠ Alias already present in $config – skipped${NC}"
    else
        { echo ""; echo "# check-certs"; echo "$ALIAS_LINE"; } >> "$config"
        echo -e "${GREEN}✓ Alias added to $config${NC}"
    fi
done

# Variant wrapper script
case "$INSTALL_VARIANT" in
    postfix|ssmtp|sendmail) WRAPPER_SCRIPT="check-certs-mail.sh" ;;
    webhook)       WRAPPER_SCRIPT="check-certs-webhook.sh"  ;;
    pushover)      WRAPPER_SCRIPT="check-certs-pushover.sh" ;;
    *)             WRAPPER_SCRIPT=""                         ;;
esac

if [ -n "$WRAPPER_SCRIPT" ]; then
    cp "$SRC_DIR/$WRAPPER_SCRIPT" "$TARGET_DIR/$WRAPPER_SCRIPT"
    chmod +x "$TARGET_DIR/$WRAPPER_SCRIPT"
    echo -e "${GREEN}✓ $WRAPPER_SCRIPT installed${NC}"
fi

# ── Write check-certs.conf ───────────────────────────────────
if [ -f "$TARGET_DIR/check-certs.conf" ]; then
    echo -e "${YELLOW}⚠ 'check-certs.conf' already exists – will not be overwritten.${NC}"
    echo "  Edit it manually to change settings: $TARGET_DIR/check-certs.conf"
elif [ "$INSTALL_VARIANT" != "none" ]; then
    {
        echo "# check-certs configuration"
        echo "# Edit this file to change settings. Scripts are never modified directly."
        echo ""
        echo "# ── Thresholds ──────────────────────────────────────────"
        echo "WARN_DAYS=${WARN_DAYS}"
        echo "CRIT_DAYS=${CRIT_DAYS}"
        echo "URGENT_DAYS=${URGENT_DAYS}"
        echo "TIMEOUT=5"
        echo "MAX_JOBS=10"
        echo "CA_MAX_LEN=30"
        echo ""
        echo "# ── State tracking ──────────────────────────────────────"
        echo "STATE_FILE=/var/lib/check-certs/state"

        case "$INSTALL_VARIANT" in
            postfix|ssmtp|sendmail)
                echo ""
                echo "# ── Email settings ──────────────────────────────────────"
                echo "MAIL_TRANSPORT=${INSTALL_VARIANT}"
                echo "MAIL_TO=\"${MAIL_TO}\""
                echo "MAIL_TO_URGENT=\"${MAIL_TO_URGENT}\""
                echo "MAIL_FROM=\"${MAIL_FROM}\""
                ;;
            webhook)
                echo ""
                echo "# ── Webhook settings ────────────────────────────────────"
                echo "WEBHOOK_URL=\"${WEBHOOK_URL}\""
                if [ -n "$WEBHOOK_AUTH_HEADER" ]; then
                    echo "WEBHOOK_AUTH_HEADER=\"${WEBHOOK_AUTH_HEADER}\""
                    echo "WEBHOOK_AUTH_VALUE=\"${WEBHOOK_AUTH_VALUE}\""
                fi
                echo "WEBHOOK_SEND_SUMMARY=${WEBHOOK_SEND_SUMMARY}"
                ;;
            pushover)
                echo ""
                echo "# ── Pushover settings ───────────────────────────────────"
                echo "PUSHOVER_APP_TOKEN=\"${PUSHOVER_APP_TOKEN}\""
                echo "PUSHOVER_USER_KEY=\"${PUSHOVER_USER_KEY}\""
                [ -n "$PUSHOVER_DEVICE" ] && echo "PUSHOVER_DEVICE=\"${PUSHOVER_DEVICE}\""
                ;;

        esac
    } > "$TARGET_DIR/check-certs.conf"
    echo -e "${GREEN}✓ check-certs.conf written${NC}"
fi

# ── Copy servers.conf ─────────────────────────────────────────
if [ -f "$TARGET_DIR/$CONF_NAME" ]; then
    echo -e "${YELLOW}⚠ '$TARGET_DIR/$CONF_NAME' already exists – will not be overwritten.${NC}"
    echo "  Your existing server list is preserved."
else
    cp "$CONF_DIR/$CONF_NAME" "$TARGET_DIR/$CONF_NAME"
    echo -e "${GREEN}✓ servers.conf copied to $TARGET_DIR/$CONF_NAME${NC}"
fi

# ── Create state directory ───────────────────────────────────
if [ "$INSTALL_VARIANT" != "none" ]; then
    mkdir -p /var/lib/check-certs
    touch /var/lib/check-certs/state
    echo -e "${GREEN}✓ State directory created: /var/lib/check-certs/${NC}"
fi

# ── Set up cron job ──────────────────────────────────────────
if [ -n "$WRAPPER_SCRIPT" ]; then
    CRON_JOB="${CRON_MINUTE} ${CRON_HOUR} * * * $TARGET_DIR/$WRAPPER_SCRIPT"
    ( crontab -u "$CRON_USER" -l 2>/dev/null || true \
        | grep -v "$WRAPPER_SCRIPT"; echo "$CRON_JOB" ) \
        | crontab -u "$CRON_USER" -
    echo -e "${GREEN}✓ Cron job set up for user '$CRON_USER' (daily at ${CRON_HOUR}:$(printf '%02d' "$CRON_MINUTE"))${NC}"
fi

# ── Test email / webhook ──────────────────────────────────────
echo ""
case "$INSTALL_VARIANT" in
    postfix)
        read -r -p "  Send a test email to '$MAIL_TO'? [Y/n] " send_test
        if [[ ! "$send_test" =~ ^[nN]$ ]]; then
            if echo "check-certs installation test" \
                    | mail -s "check-certs: test email" -a "From: $MAIL_FROM" "$MAIL_TO"; then
                echo -e "${GREEN}✓ Test email sent${NC}"
            else
                echo -e "${YELLOW}⚠ Test email could not be sent. Check: journalctl -u postfix${NC}"
            fi
        fi
        ;;
    ssmtp)
        read -r -p "  Send a test email to '$MAIL_TO'? [Y/n] " send_test
        if [[ ! "$send_test" =~ ^[nN]$ ]]; then
            if {
                printf 'To: %s\n'      "$MAIL_TO"
                printf 'From: %s\n'    "$MAIL_FROM"
                printf 'Subject: %s\n' "check-certs: test email"
                printf 'Content-Type: text/plain; charset=UTF-8\n'
                printf '\n'
                printf 'check-certs installation test\n'
               } | ssmtp "$MAIL_TO"; then
                echo -e "${GREEN}✓ Test email sent${NC}"
            else
                echo -e "${YELLOW}⚠ Test email could not be sent. Check /etc/ssmtp/ssmtp.conf${NC}"
            fi
        fi
        ;;
    sendmail)
        read -r -p "  Send a test email to '$MAIL_TO'? [Y/n] " send_test
        if [[ ! "$send_test" =~ ^[nN]$ ]]; then
            _sm=$(command -v sendmail 2>/dev/null || echo "/usr/sbin/sendmail")
            if {
                printf 'To: %s\n'      "$MAIL_TO"
                printf 'From: %s\n'    "$MAIL_FROM"
                printf 'Subject: %s\n' "check-certs: test email"
                printf 'Content-Type: text/plain; charset=UTF-8\n'
                printf '\n'
                printf 'check-certs installation test\n'
               } | "$_sm" -f "$MAIL_FROM" "$MAIL_TO"; then
                echo -e "${GREEN}✓ Test email sent${NC}"
            else
                echo -e "${YELLOW}⚠ Test email could not be sent. Check your MTA configuration.${NC}"
            fi
        fi
        ;;
    pushover)
        read -r -p "  Send a test Pushover notification? [Y/n] " send_test
        if [[ ! "$send_test" =~ ^[nN]$ ]]; then
            _code=$(curl -s -o /dev/null -w "%{http_code}" \
                --form-string "token=${PUSHOVER_APP_TOKEN}" \
                --form-string "user=${PUSHOVER_USER_KEY}" \
                --form-string "title=check-certs: installation test" \
                --form-string "message=check-certs Pushover variant installed successfully." \
                https://api.pushover.net/1/messages.json 2>/dev/null) || true
            if [ "$_code" = "200" ]; then
                echo -e "${GREEN}✓ Test notification sent${NC}"
            else
                echo -e "${YELLOW}⚠ Test returned HTTP ${_code:-no response}. Check your app token and user key.${NC}"
            fi
        fi
        ;;
    webhook)
        read -r -p "  Send a test POST to the webhook URL? [Y/n] " send_test
        if [[ ! "$send_test" =~ ^[nN]$ ]]; then
            _args=(-s -o /dev/null -w "%{http_code}" -X POST "$WEBHOOK_URL"
                   -H "Content-Type: application/json"
                   -d '{"event":"test","message":"check-certs installation test"}')
            [ -n "$WEBHOOK_AUTH_HEADER" ] && _args+=(-H "$WEBHOOK_AUTH_HEADER: $WEBHOOK_AUTH_VALUE")
            _code=$(curl "${_args[@]}" 2>/dev/null) || true
            if [[ "$_code" =~ ^2 ]]; then
                echo -e "${GREEN}✓ Test POST sent (HTTP ${_code})${NC}"
            else
                echo -e "${YELLOW}⚠ Test POST returned HTTP ${_code:-no response}. Check WEBHOOK_URL and auth settings.${NC}"
            fi
        fi
        ;;
esac

# ── Summary ──────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}✅ Installation complete!${NC}"
echo ""
echo -e "  Terminal:     ${BOLD}$TARGET_DIR/check-certs.sh${NC}"
echo -e "  Server list:  ${BOLD}$TARGET_DIR/$CONF_NAME${NC}"
if [ -n "$WRAPPER_SCRIPT" ]; then
    echo -e "  Wrapper:      ${BOLD}$TARGET_DIR/$WRAPPER_SCRIPT${NC}"
    echo -e "  State:        ${BOLD}/var/lib/check-certs/state${NC}"
    echo -e "  Cron job:     ${BOLD}daily at ${CRON_HOUR}:$(printf '%02d' "$CRON_MINUTE")${NC}"
    echo -e "  Thresholds:   ${BOLD}warning >${WARN_DAYS}d${NC}  |  ${BOLD}critical >${CRIT_DAYS}d${NC}  |  ${BOLD}urgent >${URGENT_DAYS}d${NC}"
fi
case "$INSTALL_VARIANT" in
    postfix|ssmtp|sendmail)
        echo -e "  Alerts to:    ${BOLD}$MAIL_TO${NC}"
        [ "$MAIL_TO_URGENT" != "$MAIL_TO" ] && echo -e "  Urgent to:    ${BOLD}$MAIL_TO_URGENT${NC}"
        ;;
    webhook)
        echo -e "  Webhook:      ${BOLD}$WEBHOOK_URL${NC}"
        ;;
    pushover)
        echo -e "  Pushover:     ${BOLD}user key configured${NC}"
        ;;

esac
echo ""
echo "  Reload your shell or run:"
echo -e "    ${BOLD}source ~/.bashrc${NC}"
echo ""
echo "  Then use:"
echo -e "    ${BOLD}check-certs${NC}                  Check all servers interactively"
echo -e "    ${BOLD}check-certs <host>:<port>${NC}     Check a single server"
echo -e "    ${BOLD}check-certs --list${NC}            List configured servers"
if [ -n "$WRAPPER_SCRIPT" ]; then
    echo ""
    echo "  Manual run:"
    echo -e "    ${BOLD}$TARGET_DIR/$WRAPPER_SCRIPT${NC}"
    echo ""
    echo "  View syslog entries:"
    echo -e "    ${BOLD}journalctl -t check-certs${NC}"
fi
echo ""
