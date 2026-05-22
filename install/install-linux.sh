#!/bin/bash

# ============================================================
#  install-linux.sh – Installs check-certs on Debian/Ubuntu
#
#  Always installs:
#    check-certs.sh      – terminal table view + shell alias
#
#  Optionally installs one or more automation variants:
#    check-certs-mail.sh         – email via Postfix, ssmtp, or sendmail
#    check-certs-webhook.sh      – HTTP POST webhook
#    check-certs-teams.sh        – Microsoft Teams Adaptive Card
#    check-certs-pushover.sh     – Pushover mobile push
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
echo -e "  Select one or more automation variants to install.\n"
echo -e "  ${BOLD}1)${NC} Email    – daily cron job, choose transport in the next step"
echo -e "  ${BOLD}2)${NC} Webhook  – HTTP POST to Slack, ntfy, custom endpoints"
echo -e "  ${BOLD}3)${NC} Teams    – Adaptive Card to a Microsoft Teams channel"
echo -e "  ${BOLD}4)${NC} Pushover – mobile push notifications with priority levels"
echo -e "  ${BOLD}5)${NC} Terminal only – skip automation for now"
echo ""
echo -e "  Enter one or more numbers separated by spaces (e.g. ${BOLD}1 3 4${NC}):"
read -r -p "  Choose: " VARIANT_INPUT
echo ""

INSTALL_MAIL=""
MAIL_TRANSPORT=""
INSTALL_WEBHOOK=false
INSTALL_TEAMS=false
INSTALL_PUSHOVER=false
INSTALL_NONE=false

for choice in $VARIANT_INPUT; do
    case "$choice" in
        1) INSTALL_MAIL=true     ;;
        2) INSTALL_WEBHOOK=true  ;;
        3) INSTALL_TEAMS=true    ;;
        4) INSTALL_PUSHOVER=true ;;
        *) INSTALL_NONE=true     ;;
    esac
done

if [ -z "$INSTALL_MAIL" ] && [ "$INSTALL_WEBHOOK" = false ] && \
   [ "$INSTALL_TEAMS" = false ] && [ "$INSTALL_PUSHOVER" = false ]; then
    INSTALL_NONE=true
fi

echo "──────────────────────────────"
echo ""

# ── Verify source files exist ─────────────────────────────────
[ -n "$INSTALL_MAIL" ] && {
    if [ ! -f "$SRC_DIR/check-certs-mail.sh" ]; then
        echo -e "${RED}✗ File 'check-certs-mail.sh' not found (expected in: $SRC_DIR)${NC}"
        exit 1
    fi
}
[ "$INSTALL_WEBHOOK" = true ] && {
    if [ ! -f "$SRC_DIR/check-certs-webhook.sh" ]; then
        echo -e "${RED}✗ File 'check-certs-webhook.sh' not found (expected in: $SRC_DIR)${NC}"
        exit 1
    fi
}
[ "$INSTALL_TEAMS" = true ] && {
    if [ ! -f "$SRC_DIR/check-certs-teams.sh" ]; then
        echo -e "${RED}✗ File 'check-certs-teams.sh' not found (expected in: $SRC_DIR)${NC}"
        exit 1
    fi
}
[ "$INSTALL_PUSHOVER" = true ] && {
    if [ ! -f "$SRC_DIR/check-certs-pushover.sh" ]; then
        echo -e "${RED}✗ File 'check-certs-pushover.sh' not found (expected in: $SRC_DIR)${NC}"
        exit 1
    fi
}

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
    local label="${1:-Cron job}"
    read -r -p "  ${label} – hour (0–23) [7]: " _HOUR
    _HOUR="${_HOUR:-7}"
    while ! [[ "$_HOUR" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; do
        echo -e "  ${RED}Please enter a valid hour (0–23).${NC}"
        read -r -p "  ${label} – hour (0–23) [7]: " _HOUR
        _HOUR="${_HOUR:-7}"
    done

    read -r -p "  ${label} – minute (0–59) [0]: " _MINUTE
    _MINUTE="${_MINUTE:-0}"
    while ! [[ "$_MINUTE" =~ ^([0-9]|[1-5][0-9])$ ]]; do
        echo -e "  ${RED}Please enter a valid minute (0–59).${NC}"
        read -r -p "  ${label} – minute (0–59) [0]: " _MINUTE
        _MINUTE="${_MINUTE:-0}"
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

    read -r -p "  SMTP username (leave blank for unauthenticated relay): " SMTP_USER
    if [ -n "$SMTP_USER" ]; then
        read -r -s -p "  SMTP password (app password): " SMTP_PASS
        echo ""
        while [ -z "$SMTP_PASS" ]; do
            echo -e "  ${RED}Please enter a password.${NC}"
            read -r -s -p "  SMTP password: " SMTP_PASS
            echo ""
        done
    fi
}

# ── Configuration prompts ─────────────────────────────────────

# Shared thresholds — prompt once for all variants
if [ "$INSTALL_NONE" = false ]; then
    echo -e "  ${BOLD}Thresholds${NC} (shared by all variants)"
    echo ""
    _prompt_thresholds
    echo ""
    echo "──────────────────────────────"
    echo ""
fi

# Email-specific prompts
if [ -n "$INSTALL_MAIL" ]; then
    echo -e "  ${BOLD}Email variant${NC}"
    echo ""
    echo -e "  Mail transport:"
    echo -e "    ${BOLD}1)${NC} Postfix  – full MTA with SMTP relay (recommended for servers)"
    echo -e "    ${BOLD}2)${NC} ssmtp    – lightweight, no daemon"
    echo -e "    ${BOLD}3)${NC} sendmail – use your existing MTA"
    echo ""
    read -r -p "  Choose transport [1/2/3]: " _mt
    case "$_mt" in
        2) MAIL_TRANSPORT="ssmtp"    ;;
        3) MAIL_TRANSPORT="sendmail" ;;
        *) MAIL_TRANSPORT="postfix"  ;;
    esac
    echo ""
    _prompt_email
    if [[ "$MAIL_TRANSPORT" =~ ^(postfix|ssmtp)$ ]]; then
        _prompt_smtp
    fi
    _prompt_cron_time "Email cron job"
    MAIL_CRON_HOUR="$_HOUR"
    MAIL_CRON_MINUTE="$_MINUTE"
    echo ""
    echo "──────────────────────────────"
    echo ""
fi

# Webhook-specific prompts
if [ "$INSTALL_WEBHOOK" = true ]; then
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

    _prompt_cron_time "Webhook cron job"
    WEBHOOK_CRON_HOUR="$_HOUR"
    WEBHOOK_CRON_MINUTE="$_MINUTE"
    echo ""
    echo "──────────────────────────────"
    echo ""
fi

# Teams-specific prompts
if [ "$INSTALL_TEAMS" = true ]; then
    echo -e "  ${BOLD}Teams variant${NC}"
    echo ""
    read -r -p "  Teams Workflow webhook URL: " TEAMS_WEBHOOK_URL
    while [ -z "$TEAMS_WEBHOOK_URL" ]; do
        echo -e "  ${RED}Please enter a webhook URL.${NC}"
        read -r -p "  Teams Workflow webhook URL: " TEAMS_WEBHOOK_URL
    done
    _prompt_cron_time "Teams cron job"
    TEAMS_CRON_HOUR="$_HOUR"
    TEAMS_CRON_MINUTE="$_MINUTE"
    echo ""
    echo "──────────────────────────────"
    echo ""
fi

# Teams-specific prompts
if [ "$INSTALL_TEAMS" = true ]; then
    echo -e "  ${BOLD}Teams variant${NC}"
    echo ""
    read -r -p "  Teams Workflow webhook URL: " TEAMS_WEBHOOK_URL
    while [ -z "$TEAMS_WEBHOOK_URL" ]; do
        echo -e "  ${RED}Please enter a webhook URL.${NC}"
        read -r -p "  Teams Workflow webhook URL: " TEAMS_WEBHOOK_URL
    done
    _prompt_cron_time "Teams cron job"
    TEAMS_CRON_HOUR="$_HOUR"
    TEAMS_CRON_MINUTE="$_MINUTE"
    echo ""
    echo "──────────────────────────────"
    echo ""
fi

# Pushover-specific prompts
if [ "$INSTALL_PUSHOVER" = true ]; then
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

    _prompt_cron_time "Pushover cron job"
    PUSHOVER_CRON_HOUR="$_HOUR"
    PUSHOVER_CRON_MINUTE="$_MINUTE"
    echo ""
    echo "──────────────────────────────"
    echo ""
fi

# ── Install packages ─────────────────────────────────────────
echo "  Updating package lists..."
apt-get update -qq
echo -e "${GREEN}✓ Package lists updated${NC}"

echo "  Installing openssl..."
apt-get install -y -qq openssl
echo -e "${GREEN}✓ openssl installed${NC}"

if [ -n "$INSTALL_MAIL" ]; then
    case "$MAIL_TRANSPORT" in
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
    esac
fi

if [ "$INSTALL_WEBHOOK" = true ] || [ "$INSTALL_TEAMS" = true ] || [ "$INSTALL_PUSHOVER" = true ]; then
    echo "  Installing curl..."
    apt-get install -y -qq curl
    echo -e "${GREEN}✓ curl installed${NC}"
fi

# ── Configure Postfix ────────────────────────────────────────
if [ -n "$INSTALL_MAIL" ] && [ "$MAIL_TRANSPORT" = "postfix" ]; then
    if [ -f /etc/postfix/main.cf ]; then
        echo -e "${YELLOW}⚠ Existing Postfix configuration found – will not be overwritten.${NC}"
        echo "  SMTP relay settings must be added manually to /etc/postfix/main.cf"
        echo "  See docs/email.md for the required directives."
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

smtp_use_tls = yes
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt
smtp_tls_session_cache_database = btree:\${data_directory}/smtp_scache

smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous

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
if [ -n "$INSTALL_MAIL" ] && [ "$MAIL_TRANSPORT" = "ssmtp" ]; then
    if [ -f /etc/ssmtp/ssmtp.conf ]; then
        echo -e "${YELLOW}⚠ Existing ssmtp configuration found – will not be overwritten.${NC}"
        echo "  Edit /etc/ssmtp/ssmtp.conf manually if SMTP settings need updating."
    else
        echo "  Writing /etc/ssmtp/ssmtp.conf..."
        mkdir -p /etc/ssmtp
        {
            echo "root=${MAIL_FROM}"
            echo "mailhub=${SMTP_HOST}:${SMTP_PORT}"
            [ -n "$SMTP_USER" ] && echo "AuthUser=${SMTP_USER}"
            [ -n "$SMTP_PASS" ] && echo "AuthPass=${SMTP_PASS}"
            echo "UseTLS=YES"
            echo "UseSTARTTLS=YES"
            echo "hostname=${FQDN}"
            echo "FromLineOverride=YES"
        } > /etc/ssmtp/ssmtp.conf
        chmod 640 /etc/ssmtp/ssmtp.conf
        echo -e "${GREEN}✓ ssmtp configured${NC}"
    fi
fi

# ── Copy files ───────────────────────────────────────────────
mkdir -p "$TARGET_DIR"

cp "$SRC_DIR/check-certs.sh" "$TARGET_DIR/check-certs.sh"
chmod +x "$TARGET_DIR/check-certs.sh"
echo -e "${GREEN}✓ check-certs.sh installed${NC}"

ALIAS_LINE="alias check-certs=\"$TARGET_DIR/check-certs.sh\""
declare -a RC_FILES=("/root/.bashrc")
[ "$CRON_USER" != "root" ] && RC_FILES+=("/home/$CRON_USER/.bashrc")
for config in "${RC_FILES[@]}"; do
    [ -f "$config" ] || continue
    if grep -q "alias check-certs" "$config"; then
        echo -e "${YELLOW}⚠ Alias already present in $config – skipped${NC}"
    else
        { echo ""; echo "# check-certs"; echo "$ALIAS_LINE"; } >> "$config"
        echo -e "${GREEN}✓ Alias added to $config${NC}"
    fi
done

[ -n "$INSTALL_MAIL" ] && {
    cp "$SRC_DIR/check-certs-mail.sh" "$TARGET_DIR/check-certs-mail.sh"
    chmod +x "$TARGET_DIR/check-certs-mail.sh"
    echo -e "${GREEN}✓ check-certs-mail.sh installed${NC}"
}
[ "$INSTALL_WEBHOOK" = true ] && {
    cp "$SRC_DIR/check-certs-webhook.sh" "$TARGET_DIR/check-certs-webhook.sh"
    chmod +x "$TARGET_DIR/check-certs-webhook.sh"
    echo -e "${GREEN}✓ check-certs-webhook.sh installed${NC}"
}
[ "$INSTALL_TEAMS" = true ] && {
    cp "$SRC_DIR/check-certs-teams.sh" "$TARGET_DIR/check-certs-teams.sh"
    chmod +x "$TARGET_DIR/check-certs-teams.sh"
    echo -e "${GREEN}✓ check-certs-teams.sh installed${NC}"
}
[ "$INSTALL_PUSHOVER" = true ] && {
    cp "$SRC_DIR/check-certs-pushover.sh" "$TARGET_DIR/check-certs-pushover.sh"
    chmod +x "$TARGET_DIR/check-certs-pushover.sh"
    echo -e "${GREEN}✓ check-certs-pushover.sh installed${NC}"
}

# ── Write check-certs.conf ───────────────────────────────────
if [ -f "$TARGET_DIR/check-certs.conf" ]; then
    echo -e "${YELLOW}⚠ 'check-certs.conf' already exists – will not be overwritten.${NC}"
    echo "  Edit it manually to change settings: $TARGET_DIR/check-certs.conf"
elif [ "$INSTALL_NONE" = false ]; then
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

        if [ -n "$INSTALL_MAIL" ]; then
            echo ""
            echo "# ── Email settings ──────────────────────────────────────"
            echo "MAIL_TRANSPORT=${MAIL_TRANSPORT}"
            echo "MAIL_TO=\"${MAIL_TO}\""
            echo "MAIL_TO_URGENT=\"${MAIL_TO_URGENT}\""
            echo "MAIL_FROM=\"${MAIL_FROM}\""
        fi

        if [ "$INSTALL_WEBHOOK" = true ]; then
            echo ""
            echo "# ── Webhook settings ────────────────────────────────────"
            echo "WEBHOOK_URL=\"${WEBHOOK_URL}\""
            if [ -n "$WEBHOOK_AUTH_HEADER" ]; then
                echo "WEBHOOK_AUTH_HEADER=\"${WEBHOOK_AUTH_HEADER}\""
                echo "WEBHOOK_AUTH_VALUE=\"${WEBHOOK_AUTH_VALUE}\""
            fi
            echo "WEBHOOK_SEND_SUMMARY=${WEBHOOK_SEND_SUMMARY}"
        fi

        if [ "$INSTALL_TEAMS" = true ]; then
            echo ""
            echo "# ── Teams settings ──────────────────────────────────────"
            echo "TEAMS_WEBHOOK_URL=\"${TEAMS_WEBHOOK_URL}\""
        fi

        if [ "$INSTALL_PUSHOVER" = true ]; then
            echo ""
            echo "# ── Pushover settings ───────────────────────────────────"
            echo "PUSHOVER_APP_TOKEN=\"${PUSHOVER_APP_TOKEN}\""
            echo "PUSHOVER_USER_KEY=\"${PUSHOVER_USER_KEY}\""
            [ -n "$PUSHOVER_DEVICE" ] && echo "PUSHOVER_DEVICE=\"${PUSHOVER_DEVICE}\""
        fi
    } > "$TARGET_DIR/check-certs.conf"
    echo -e "${GREEN}✓ check-certs.conf written${NC}"
fi

# ── Copy servers.conf ─────────────────────────────────────────
if [ -f "$TARGET_DIR/$CONF_NAME" ]; then
    echo -e "${YELLOW}⚠ '$TARGET_DIR/$CONF_NAME' already exists – will not be overwritten.${NC}"
else
    cp "$CONF_DIR/$CONF_NAME" "$TARGET_DIR/$CONF_NAME"
    echo -e "${GREEN}✓ servers.conf copied to $TARGET_DIR/$CONF_NAME${NC}"
fi

# ── Create state directory ───────────────────────────────────
if [ "$INSTALL_NONE" = false ]; then
    mkdir -p /var/lib/check-certs
    [ -n "$INSTALL_MAIL"         ] && touch /var/lib/check-certs/state-mail
    [ "$INSTALL_WEBHOOK" = true  ] && touch /var/lib/check-certs/state-webhook
    [ "$INSTALL_TEAMS" = true    ] && touch /var/lib/check-certs/state-teams
    [ "$INSTALL_PUSHOVER" = true ] && touch /var/lib/check-certs/state-pushover
    echo -e "${GREEN}✓ State directory created: /var/lib/check-certs/${NC}"
fi

# ── Set up cron jobs ─────────────────────────────────────────
_add_cron() {
    local script="$1" hour="$2" minute="$3"
    local job="${minute} ${hour} * * * $TARGET_DIR/${script}"
    ( crontab -u "$CRON_USER" -l 2>/dev/null || true \
        | grep -v "$script"; echo "$job" ) \
        | crontab -u "$CRON_USER" -
    echo -e "${GREEN}✓ Cron job: $script (daily at ${hour}:$(printf '%02d' "$minute"))${NC}"
}

[ -n "$INSTALL_MAIL"         ] && _add_cron "check-certs-mail.sh"     "$MAIL_CRON_HOUR"     "$MAIL_CRON_MINUTE"
[ "$INSTALL_WEBHOOK" = true  ] && _add_cron "check-certs-webhook.sh"  "$WEBHOOK_CRON_HOUR"  "$WEBHOOK_CRON_MINUTE"
[ "$INSTALL_TEAMS" = true    ] && _add_cron "check-certs-teams.sh"    "$TEAMS_CRON_HOUR"    "$TEAMS_CRON_MINUTE"
[ "$INSTALL_PUSHOVER" = true ] && _add_cron "check-certs-pushover.sh" "$PUSHOVER_CRON_HOUR" "$PUSHOVER_CRON_MINUTE"

# ── Test sends ───────────────────────────────────────────────
echo ""
if [ -n "$INSTALL_MAIL" ]; then
    read -r -p "  Send a test email to '$MAIL_TO'? [Y/n] " send_test
    if [[ ! "$send_test" =~ ^[nN]$ ]]; then
        case "$MAIL_TRANSPORT" in
            postfix)
                if echo "check-certs installation test" \
                        | mail -s "check-certs: test email" -a "From: $MAIL_FROM" "$MAIL_TO"; then
                    echo -e "${GREEN}✓ Test email sent${NC}"
                else
                    echo -e "${YELLOW}⚠ Test email could not be sent. Check: journalctl -u postfix${NC}"
                fi ;;
            ssmtp)
                if { printf 'To: %s\n' "$MAIL_TO"; printf 'From: %s\n' "$MAIL_FROM"
                     printf 'Subject: check-certs: test email\n'
                     printf 'Content-Type: text/plain; charset=UTF-8\n\n'
                     printf 'check-certs installation test\n'
                   } | ssmtp "$MAIL_TO"; then
                    echo -e "${GREEN}✓ Test email sent${NC}"
                else
                    echo -e "${YELLOW}⚠ Test email could not be sent. Check /etc/ssmtp/ssmtp.conf${NC}"
                fi ;;
            sendmail)
                _sm=$(command -v sendmail 2>/dev/null || echo "/usr/sbin/sendmail")
                if { printf 'To: %s\n' "$MAIL_TO"; printf 'From: %s\n' "$MAIL_FROM"
                     printf 'Subject: check-certs: test email\n'
                     printf 'Content-Type: text/plain; charset=UTF-8\n\n'
                     printf 'check-certs installation test\n'
                   } | "$_sm" -f "$MAIL_FROM" "$MAIL_TO"; then
                    echo -e "${GREEN}✓ Test email sent${NC}"
                else
                    echo -e "${YELLOW}⚠ Test email could not be sent. Check your MTA configuration.${NC}"
                fi ;;
        esac
    fi
fi

if [ "$INSTALL_WEBHOOK" = true ]; then
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
            echo -e "${YELLOW}⚠ Test POST returned HTTP ${_code:-no response}. Check WEBHOOK_URL.${NC}"
        fi
    fi
fi

if [ "$INSTALL_TEAMS" = true ]; then
    read -r -p "  Send a test POST to the Teams webhook URL? [Y/n] " send_test
    if [[ ! "$send_test" =~ ^[nN]$ ]]; then
        _payload_file=$(mktemp)
        printf '%s' '{"type":"message","attachments":[{"contentType":"application/vnd.microsoft.card.adaptive","contentUrl":null,"content":{"$schema":"http://adaptivecards.io/schemas/adaptive-card.json","type":"AdaptiveCard","version":"1.2","body":[{"type":"TextBlock","text":"check-certs installation test","weight":"Bolder"}]}}]}' > "$_payload_file"
        _code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$TEAMS_WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            --data-binary "@${_payload_file}" 2>/dev/null) || true
        rm -f "$_payload_file"
        if [[ "$_code" =~ ^2 ]]; then
            echo -e "${GREEN}✓ Test card sent (HTTP ${_code})${NC}"
        else
            echo -e "${YELLOW}⚠ Test POST returned HTTP ${_code:-no response}. Check TEAMS_WEBHOOK_URL.${NC}"
        fi
    fi
fi

# ── Summary ──────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}✅ Installation complete!${NC}"
echo ""
echo -e "  Terminal:     ${BOLD}$TARGET_DIR/check-certs.sh${NC}"
echo -e "  Server list:  ${BOLD}$TARGET_DIR/$CONF_NAME${NC}"
[ "$INSTALL_NONE" = false ] && \
    echo -e "  Thresholds:   ${BOLD}warning >${WARN_DAYS}d${NC}  |  ${BOLD}critical >${CRIT_DAYS}d${NC}  |  ${BOLD}urgent >${URGENT_DAYS}d${NC}"
[ -n "$INSTALL_MAIL" ] && {
    echo -e "  Email:        ${BOLD}$TARGET_DIR/check-certs-mail.sh${NC} (${MAIL_TRANSPORT}, daily at ${MAIL_CRON_HOUR}:$(printf '%02d' "$MAIL_CRON_MINUTE"))"
    echo -e "  Alerts to:    ${BOLD}$MAIL_TO${NC}"
    [ "$MAIL_TO_URGENT" != "$MAIL_TO" ] && echo -e "  Urgent to:    ${BOLD}$MAIL_TO_URGENT${NC}"
}
[ "$INSTALL_WEBHOOK" = true ] && \
    echo -e "  Webhook:      ${BOLD}$TARGET_DIR/check-certs-webhook.sh${NC} (daily at ${WEBHOOK_CRON_HOUR}:$(printf '%02d' "$WEBHOOK_CRON_MINUTE"))"
[ "$INSTALL_TEAMS" = true ] && \
    echo -e "  Teams:        ${BOLD}$TARGET_DIR/check-certs-teams.sh${NC} (daily at ${TEAMS_CRON_HOUR}:$(printf '%02d' "$TEAMS_CRON_MINUTE"))"
[ "$INSTALL_PUSHOVER" = true ] && \
    echo -e "  Pushover:     ${BOLD}$TARGET_DIR/check-certs-pushover.sh${NC} (daily at ${PUSHOVER_CRON_HOUR}:$(printf '%02d' "$PUSHOVER_CRON_MINUTE"))"
echo ""
echo "  Reload your shell or run:"
echo -e "    ${BOLD}source ~/.bashrc${NC}"
echo ""
echo "  Then use:"
echo -e "    ${BOLD}check-certs${NC}                  Check all servers interactively"
echo -e "    ${BOLD}check-certs <host>:<port>${NC}     Check a single server"
echo -e "    ${BOLD}check-certs --list${NC}            List configured servers"
echo ""
[ "$INSTALL_NONE" = false ] && {
    echo "  View syslog entries:"
    echo -e "    ${BOLD}journalctl -t check-certs${NC}"
    echo ""
}