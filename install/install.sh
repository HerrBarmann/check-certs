#!/bin/bash

# ============================================================
#  install.sh – Unified installer for check-certs
#
#  Supports macOS and Linux (Debian/Ubuntu). Platform is
#  detected automatically.
#
#  Always installs:
#    check-certs.sh          – terminal table + core logic
#
#  Optionally installs one or more automation variants:
#    check-certs-notify.sh   – macOS native notifications
#    check-certs-mail.sh     – email (Postfix, ssmtp, sendmail)
#    check-certs-webhook.sh  – HTTP POST webhook
#    check-certs-teams.sh    – Microsoft Teams Adaptive Card
#    check-certs-pushover.sh – Pushover mobile push
#    check-certs-ntfy.sh     – ntfy push notifications (ntfy.sh or self-hosted)
#
#  Usage:
#    macOS:  ./install.sh
#    Linux:  sudo ./install.sh
# ============================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Platform detection ────────────────────────────────────────
PLATFORM="$(uname -s)"
case "$PLATFORM" in
    Darwin) PLATFORM="macos" ;;
    Linux)  PLATFORM="linux" ;;
    *)
        echo -e "${RED}✗ Unsupported platform: $PLATFORM${NC}"
        echo "  check-certs supports macOS and Linux."
        exit 1
        ;;
esac

# check-certs installs to /usr/local/lib/ and /usr/local/bin/ — both
# require root on macOS and Linux. Run with sudo:
#   macOS:  sudo ./install/install.sh
#   Linux:  sudo ./install/install.sh
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}✗ This installer must be run as root.${NC}"
    echo ""
    echo "  Run it with sudo:"
    echo -e "    ${BOLD}sudo ./install/install.sh${NC}"
    echo ""
    exit 1
fi

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$INSTALL_DIR/../src" && pwd)"
CONF_DIR="$(cd "$INSTALL_DIR/../config" && pwd)"
CONF_NAME="servers.conf"

# Platform-specific defaults
if [ "$PLATFORM" = "macos" ]; then
    TARGET_DIR="/usr/local/lib/check-certs"         # scripts co-located here
    CONF_TARGET_DIR="$HOME/.config/check-certs"      # config and servers.conf
    BIN_DIR="/usr/local/bin"                          # check-certs symlink
    LOG_DIR="$HOME/Library/Logs/check-certs"
    STATE_DIR="$HOME/Library/Application Support/check-certs"
    NOTIFY_PLIST_NAME="com.check-certs.notify.plist"
    WEBHOOK_PLIST_NAME="com.check-certs.webhook.plist"
    PUSHOVER_PLIST_NAME="com.check-certs.pushover.plist"
    NTFY_PLIST_NAME="com.check-certs.ntfy.plist"
    NOTIFY_PLIST_TARGET="$HOME/Library/LaunchAgents/$NOTIFY_PLIST_NAME"
    WEBHOOK_PLIST_TARGET="$HOME/Library/LaunchAgents/$WEBHOOK_PLIST_NAME"
    PUSHOVER_PLIST_TARGET="$HOME/Library/LaunchAgents/$PUSHOVER_PLIST_NAME"
    NTFY_PLIST_TARGET="$HOME/Library/LaunchAgents/$NTFY_PLIST_NAME"
    FQDN="$(hostname -f 2>/dev/null || hostname)"
else
    TARGET_DIR="/opt/check-certs"         # scripts and config co-located
    CONF_TARGET_DIR="/opt/check-certs"     # same as TARGET_DIR on Linux
    BIN_DIR="/usr/local/bin"
    LOG_DIR="/var/log/check-certs"
    STATE_DIR="/var/lib/check-certs"
    CRON_USER="${SUDO_USER:-$USER}"
    FQDN="$(hostname -f 2>/dev/null || hostname)"
fi

WARN_DAYS=15; CRIT_DAYS=7; URGENT_DAYS=2

# ── Root check (Linux only) ───────────────────────────────────
if [ "$PLATFORM" = "linux" ] && [ "$EUID" -ne 0 ]; then
    echo -e "${RED}✗ This script must be run with sudo on Linux.${NC}"
    echo "  Usage: sudo ./install.sh"
    exit 1
fi

echo ""
echo -e "${BOLD}check-certs Installer${NC} ${CYAN}($([ "$PLATFORM" = "macos" ] && echo "macOS" || echo "Debian/Ubuntu"))${NC}"
echo "──────────────────────────────"
echo ""

# ── Verify core source files ──────────────────────────────────
[ -f "$SRC_DIR/check-certs.sh"   ] || { echo -e "${RED}✗ check-certs.sh not found (expected in: $SRC_DIR)${NC}"; exit 1; }
[ -f "$CONF_DIR/$CONF_NAME"      ] || { echo -e "${RED}✗ servers.conf not found (expected in: $CONF_DIR)${NC}"; exit 1; }

# ── Helper functions ──────────────────────────────────────────

require_file() {
    local dir="$1" file="$2"
    [ -f "$dir/$file" ] || { echo -e "${RED}✗ '$file' not found (expected in: $dir)${NC}"; exit 1; }
}

copy_script() {
    local name="$1"
    cp "$SRC_DIR/$name" "$TARGET_DIR/$name"
    chmod +x "$TARGET_DIR/$name"
    echo -e "${GREEN}✓ $name installed${NC}"
}

copy_conf() {
    if [ -f "$CONF_TARGET_DIR/servers.conf" ]; then
        echo -e "${YELLOW}⚠ 'servers.conf' already exists – will not be overwritten.${NC}"
    else
        cp "$CONF_DIR/servers.conf" "$CONF_TARGET_DIR/servers.conf"
        echo -e "${GREEN}✓ servers.conf copied to $CONF_TARGET_DIR/${NC}"
    fi
}

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

_prompt_email() {
    read -r -p "  Email recipient (e.g. admin@example.com): " MAIL_TO
    while [[ -z "$MAIL_TO" || ! "$MAIL_TO" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; do
        echo -e "  ${RED}Invalid email address.${NC}"
        read -r -p "  Email recipient: " MAIL_TO
    done
    read -r -p "  Urgent email recipient [$MAIL_TO]: " MAIL_TO_URGENT
    MAIL_TO_URGENT="${MAIL_TO_URGENT:-$MAIL_TO}"
    while [[ ! "$MAIL_TO_URGENT" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; do
        echo -e "  ${RED}Invalid email address.${NC}"
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
        echo -e "  ${RED}Please enter a valid port.${NC}"
        read -r -p "  SMTP port [587]: " SMTP_PORT
        SMTP_PORT="${SMTP_PORT:-587}"
    done
    read -r -p "  SMTP username (leave blank for unauthenticated relay): " SMTP_USER
    if [ -n "$SMTP_USER" ]; then
        read -r -s -p "  SMTP password: " SMTP_PASS; echo ""
        while [ -z "$SMTP_PASS" ]; do
        echo -e "  ${RED}Please enter a password.${NC}"
            read -r -s -p "  SMTP password: " SMTP_PASS; echo ""
        done
    fi
}

_prompt_schedule() {
    local label="${1:-Run time}"
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

# ── macOS: plist install helpers ──────────────────────────────
if [ "$PLATFORM" = "macos" ]; then

# _install_plist <src> <dst> <script> <label> <hour> <minute>
_install_plist() {
    local plist_src="$1" plist_dst="$2" script_path="$3"
    local label="$4" hour="$5" minute="$6"
    if launchctl list 2>/dev/null | grep -q "$label"; then
        launchctl unload "$plist_dst" 2>/dev/null || true
        echo -e "${YELLOW}⚠ Existing launchd job '$label' unloaded${NC}"
    fi
    sed \
        -e "s|SCRIPT_PATH_PLACEHOLDER|${script_path}|g" \
        -e "s|HOUR_PLACEHOLDER|${hour}|g" \
        -e "s|MINUTE_PLACEHOLDER|${minute}|g" \
        -e "s|LOGDIR_PLACEHOLDER|${LOG_DIR}|g" \
        "$plist_src" > "$plist_dst"
    launchctl load "$plist_dst"
    echo -e "${GREEN}✓ launchd job '$label' loaded (daily at ${hour}:$(printf '%02d' "$minute"))${NC}"
}

# Derives plist from webhook template (for mail and teams which share structure)
_install_derived_plist() {
    local label="$1" script_path="$2" hour="$3" minute="$4"
    local plist_dst="$HOME/Library/LaunchAgents/${label}.plist"
    local tmp
    tmp=$(mktemp)
    sed \
        -e "s|com\\.check-certs\\.webhook|${label}|g" \
        -e "s|check-certs-webhook|${label#com.check-certs.}|g" \
        "$INSTALL_DIR/$WEBHOOK_PLIST_NAME" > "$tmp"
    _install_plist "$tmp" "$plist_dst" "$script_path" "$label" "$hour" "$minute"
    rm -f "$tmp"
}

fi  # end macOS plist helpers

# ── Linux: cron helper ────────────────────────────────────────
if [ "$PLATFORM" = "linux" ]; then

_add_cron() {
    local script="$1" hour="$2" minute="$3"
    local job="${minute} ${hour} * * * $TARGET_DIR/${script}"
    ( crontab -u "$CRON_USER" -l 2>/dev/null || true \
        | grep -v "$script"; echo "$job" ) \
        | crontab -u "$CRON_USER" -
    echo -e "${GREEN}✓ Cron job: $script (daily at ${hour}:$(printf '%02d' "$minute"))${NC}"
}

fi  # end Linux cron helper

# ── Variant selection ─────────────────────────────────────────
echo -e "  check-certs.sh (terminal table view) will always be installed."
echo -e "  Select one or more automation variants to install.\n"

if [ "$PLATFORM" = "macos" ]; then
    echo -e "  ${BOLD}1)${NC} Notifications  – daily macOS notifications via launchd"
    echo -e "  ${BOLD}2)${NC} Email          – daily email, choose transport in the next step"
    echo -e "  ${BOLD}3)${NC} Webhook        – HTTP POST to Slack, custom endpoints, etc."
    echo -e "  ${BOLD}4)${NC} Teams          – Adaptive Card to a Microsoft Teams channel"
    echo -e "  ${BOLD}5)${NC} Pushover       – mobile push notifications with priority levels"
    echo -e "  ${BOLD}6)${NC} ntfy           – push notifications via ntfy.sh or self-hosted ntfy"
    echo -e "  ${BOLD}7)${NC} Terminal only  – skip automation for now"
    echo ""
    echo -e "  Enter one or more numbers separated by spaces (e.g. ${BOLD}1 4${NC}):"
else
    echo -e "  ${BOLD}1)${NC} Email    – daily cron job, choose transport in the next step"
    echo -e "  ${BOLD}2)${NC} Webhook  – HTTP POST to Slack, custom endpoints, etc."
    echo -e "  ${BOLD}3)${NC} Teams    – Adaptive Card to a Microsoft Teams channel"
    echo -e "  ${BOLD}4)${NC} Pushover – mobile push notifications with priority levels"
    echo -e "  ${BOLD}5)${NC} ntfy     – push notifications via ntfy.sh or self-hosted ntfy"
    echo -e "  ${BOLD}6)${NC} Terminal only – skip automation for now"
    echo ""
    echo -e "  Enter one or more numbers separated by spaces (e.g. ${BOLD}1 3${NC}):"
fi

read -r -p "  Choose: " VARIANT_INPUT
echo ""

INSTALL_NOTIFY=false; INSTALL_MAIL=false; MAIL_TRANSPORT=""
INSTALL_WEBHOOK=false; INSTALL_TEAMS=false; INSTALL_PUSHOVER=false
INSTALL_NTFY=false
INSTALL_NONE=false

if [ "$PLATFORM" = "macos" ]; then
    for choice in $VARIANT_INPUT; do
        case "$choice" in
            1) INSTALL_NOTIFY=true   ;;
            2) INSTALL_MAIL=true     ;;
            3) INSTALL_WEBHOOK=true  ;;
            4) INSTALL_TEAMS=true    ;;
            5) INSTALL_PUSHOVER=true ;;
            6) INSTALL_NTFY=true     ;;
            *) INSTALL_NONE=true     ;;
        esac
    done
else
    for choice in $VARIANT_INPUT; do
        case "$choice" in
            1) INSTALL_MAIL=true     ;;
            2) INSTALL_WEBHOOK=true  ;;
            3) INSTALL_TEAMS=true    ;;
            4) INSTALL_PUSHOVER=true ;;
            5) INSTALL_NTFY=true     ;;
            *) INSTALL_NONE=true     ;;
        esac
    done
fi

if [ "$INSTALL_NOTIFY" = false ] && [ "$INSTALL_MAIL" = false ] && \
   [ "$INSTALL_WEBHOOK" = false ] && [ "$INSTALL_TEAMS" = false ] && \
   [ "$INSTALL_PUSHOVER" = false ] && [ "$INSTALL_NTFY" = false ]; then
    INSTALL_NONE=true
fi

echo "──────────────────────────────"
echo ""

# ── Verify source files ───────────────────────────────────────
[ "$INSTALL_NOTIFY"   = true ] && require_file "$SRC_DIR"     "check-certs-notify.sh" \
                                && require_file "$INSTALL_DIR" "$NOTIFY_PLIST_NAME"
[ "$INSTALL_MAIL"     = true ] && require_file "$SRC_DIR"     "check-certs-mail.sh"
[ "$INSTALL_WEBHOOK"  = true ] && require_file "$SRC_DIR"     "check-certs-webhook.sh" \
                                && { [ "$PLATFORM" = "macos" ] && require_file "$INSTALL_DIR" "$WEBHOOK_PLIST_NAME" || true; }
[ "$INSTALL_TEAMS"    = true ] && require_file "$SRC_DIR"     "check-certs-teams.sh"
[ "$INSTALL_PUSHOVER" = true ] && require_file "$SRC_DIR"     "check-certs-pushover.sh" \
                                && { [ "$PLATFORM" = "macos" ] && require_file "$INSTALL_DIR" "$PUSHOVER_PLIST_NAME" || true; }
[ "$INSTALL_NTFY"     = true ] && require_file "$SRC_DIR"     "check-certs-ntfy.sh" \
                                && { [ "$PLATFORM" = "macos" ] && require_file "$INSTALL_DIR" "$NTFY_PLIST_NAME" || true; }

# ── Configuration prompts ─────────────────────────────────────

# Shared thresholds
if [ "$INSTALL_NONE" = false ]; then
    echo -e "  ${BOLD}Thresholds${NC} (shared by all variants)"
    echo ""
    _prompt_thresholds
    echo ""
    echo "──────────────────────────────"
    echo ""
fi

# macOS notifications
if [ "$INSTALL_NOTIFY" = true ]; then
    echo -e "  ${BOLD}Notification variant${NC}"
    echo ""
    _prompt_schedule "Notifications run time"
    NOTIFY_HOUR="$_HOUR"; NOTIFY_MINUTE="$_MINUTE"
    echo ""; echo "──────────────────────────────"; echo ""
fi

# Email
if [ "$INSTALL_MAIL" = true ]; then
    echo -e "  ${BOLD}Email variant${NC}"
    echo ""
    if [ "$PLATFORM" = "macos" ]; then
        echo -e "  Mail transport:"
        echo -e "    ${BOLD}1)${NC} ssmtp    – lightweight, no daemon"
        echo -e "    ${BOLD}2)${NC} sendmail – use your existing MTA (e.g. brew install postfix)"
        echo ""
        read -r -p "  Choose transport [1/2]: " _mt
        [ "$_mt" = "2" ] && MAIL_TRANSPORT="sendmail" || MAIL_TRANSPORT="ssmtp"
    else
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
    fi
    echo ""
    _prompt_email
    [[ "$MAIL_TRANSPORT" =~ ^(postfix|ssmtp)$ ]] && _prompt_smtp
    _prompt_schedule "Email run time"
    MAIL_HOUR="$_HOUR"; MAIL_MINUTE="$_MINUTE"
    echo ""; echo "──────────────────────────────"; echo ""
fi

# Webhook
if [ "$INSTALL_WEBHOOK" = true ]; then
    echo -e "  ${BOLD}Webhook variant${NC}"
    echo ""
    read -r -p "  Webhook URL: " WEBHOOK_URL
    while [ -z "$WEBHOOK_URL" ]; do
        echo -e "  ${RED}Please enter a webhook URL.${NC}"
        read -r -p "  Webhook URL: " WEBHOOK_URL
    done
    read -r -p "  Auth header name (leave blank if none): " WEBHOOK_AUTH_HEADER
    [ -n "$WEBHOOK_AUTH_HEADER" ] && read -r -p "  Auth header value: " WEBHOOK_AUTH_VALUE
    read -r -p "  Post summary after each run? [Y/n]: " _ws
    [[ "$_ws" =~ ^[nN]$ ]] && WEBHOOK_SEND_SUMMARY="false" || WEBHOOK_SEND_SUMMARY="true"
    _prompt_schedule "Webhook run time"
    WEBHOOK_HOUR="$_HOUR"; WEBHOOK_MINUTE="$_MINUTE"
    echo ""; echo "──────────────────────────────"; echo ""
fi

# Teams
if [ "$INSTALL_TEAMS" = true ]; then
    echo -e "  ${BOLD}Teams variant${NC}"
    echo ""
    read -r -p "  Teams Workflow webhook URL: " TEAMS_WEBHOOK_URL
    while [ -z "$TEAMS_WEBHOOK_URL" ]; do
        echo -e "  ${RED}Please enter a webhook URL.${NC}"
        read -r -p "  Teams Workflow webhook URL: " TEAMS_WEBHOOK_URL
    done
    _prompt_schedule "Teams run time"
    TEAMS_HOUR="$_HOUR"; TEAMS_MINUTE="$_MINUTE"
    echo ""; echo "──────────────────────────────"; echo ""
fi

# Pushover
if [ "$INSTALL_PUSHOVER" = true ]; then
    echo -e "  ${BOLD}Pushover variant${NC}"
    echo ""
    read -r -p "  Pushover app token: " PUSHOVER_APP_TOKEN
    while [ -z "$PUSHOVER_APP_TOKEN" ]; do
        echo -e "  ${RED}Please enter your app token.${NC}"
        read -r -p "  Pushover app token: " PUSHOVER_APP_TOKEN
    done
    read -r -p "  Pushover user key: " PUSHOVER_USER_KEY
    while [ -z "$PUSHOVER_USER_KEY" ]; do
        echo -e "  ${RED}Please enter your user key.${NC}"
        read -r -p "  Pushover user key: " PUSHOVER_USER_KEY
    done
    read -r -p "  Device name (leave blank for all): " PUSHOVER_DEVICE
    _prompt_schedule "Pushover run time"
    PUSHOVER_HOUR="$_HOUR"; PUSHOVER_MINUTE="$_MINUTE"
    echo ""; echo "──────────────────────────────"; echo ""
fi

# ntfy
if [ "$INSTALL_NTFY" = true ]; then
    echo -e "  ${BOLD}ntfy variant${NC}"
    echo ""
    echo -e "  ntfy server URL. Use https://ntfy.sh for the free hosted service,"
    echo -e "  or your own server (e.g. https://ntfy.example.com)."
    echo ""
    read -r -p "  ntfy server URL [https://ntfy.sh]: " NTFY_URL
    NTFY_URL="${NTFY_URL:-https://ntfy.sh}"
    # Strip trailing slash so we never produce double slashes
    NTFY_URL="${NTFY_URL%/}"
    read -r -p "  Topic name: " NTFY_TOPIC
    while [ -z "$NTFY_TOPIC" ]; do
        echo -e "  ${RED}Please enter a topic name.${NC}"
        read -r -p "  Topic name: " NTFY_TOPIC
    done
    echo ""
    echo -e "  Authentication (leave both blank for public topics):"
    read -r -p "  Access token (or leave blank): " NTFY_TOKEN
    if [ -z "$NTFY_TOKEN" ]; then
        read -r -p "  Username (or leave blank): " NTFY_USER
        [ -n "$NTFY_USER" ] && { read -r -s -p "  Password: " NTFY_PASS; echo ""; }
    fi
    _prompt_schedule "ntfy run time"
    NTFY_HOUR="$_HOUR"; NTFY_MINUTE="$_MINUTE"
    echo ""; echo "──────────────────────────────"; echo ""
fi

# ── Install packages (Linux) ──────────────────────────────────
if [ "$PLATFORM" = "linux" ]; then
    echo "  Updating package lists..."
    apt-get update -qq
    echo -e "${GREEN}✓ Package lists updated${NC}"

    echo "  Installing openssl..."
    apt-get install -y -qq openssl
    echo -e "${GREEN}✓ openssl installed${NC}"

    if [ "$INSTALL_MAIL" = true ]; then
        case "$MAIL_TRANSPORT" in
            postfix)
                echo "  Installing postfix, mailutils, libsasl2-modules..."
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                    postfix mailutils libsasl2-modules
                echo -e "${GREEN}✓ postfix and mailutils installed${NC}"
                ;;
            ssmtp)
                echo "  Installing ssmtp..."
                apt-get install -y -qq ssmtp
                echo -e "${GREEN}✓ ssmtp installed${NC}"
                ;;
            sendmail)
                if ! command -v sendmail &>/dev/null && [ ! -x /usr/sbin/sendmail ]; then
                    echo -e "${YELLOW}⚠ No sendmail binary found. Ensure your MTA provides one.${NC}"
                else
                    echo -e "${GREEN}✓ sendmail binary found${NC}"
                fi
                ;;
        esac
    fi

    if [ "$INSTALL_WEBHOOK" = true ] || [ "$INSTALL_TEAMS" = true ] || \
       [ "$INSTALL_PUSHOVER" = true ] || [ "$INSTALL_NTFY" = true ]; then
        echo "  Installing curl..."
        apt-get install -y -qq curl
        echo -e "${GREEN}✓ curl installed${NC}"
    fi
fi

# ── Install packages (macOS) ──────────────────────────────────
if [ "$PLATFORM" = "macos" ]; then
    if ! command -v brew &>/dev/null; then
        echo -e "${RED}✗ Homebrew not found.${NC}"
        echo '  Install: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
        exit 1
    fi
    echo -e "${GREEN}✓ Homebrew found${NC}"

    DEPS="coreutils openssl"
    [ "$INSTALL_NOTIFY" = true ] && DEPS="$DEPS terminal-notifier"
    [ "$INSTALL_MAIL" = true ] && [ "$MAIL_TRANSPORT" = "ssmtp" ] && DEPS="$DEPS ssmtp"
    echo "  Installing dependencies ($DEPS)..."
    # shellcheck disable=SC2086
    brew install $DEPS --quiet
    echo -e "${GREEN}✓ Dependencies installed${NC}"

    if [ "$INSTALL_MAIL" = true ] && [ "$MAIL_TRANSPORT" = "sendmail" ]; then
        command -v sendmail &>/dev/null \
            || echo -e "${YELLOW}⚠ sendmail not found. Install: brew install postfix${NC}"
    fi
fi

# ── Configure Postfix (Linux) ─────────────────────────────────
if [ "$PLATFORM" = "linux" ] && [ "$INSTALL_MAIL" = true ] && \
   [ "$MAIL_TRANSPORT" = "postfix" ]; then
    if [ -f /etc/postfix/main.cf ]; then
        echo -e "${YELLOW}⚠ Existing Postfix config found – not overwritten. See docs/email.md.${NC}"
    else
        echo "  Configuring Postfix..."
        cat > /etc/postfix/main.cf <<EOF
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
smtp_generic_maps = hash:/etc/postfix/generic
EOF
        echo "${FQDN}" > /etc/mailname
        if [ -n "$SMTP_USER" ]; then
            cat >> /etc/postfix/main.cf <<EOF
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous
EOF
        echo "[${SMTP_HOST}]:${SMTP_PORT} ${SMTP_USER}:${SMTP_PASS}" \
                > /etc/postfix/sasl_passwd
            postmap /etc/postfix/sasl_passwd
            chmod 600 /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db
        fi
        echo "root ${MAIL_FROM}" > /etc/postfix/generic
        postmap /etc/postfix/generic
        systemctl enable postfix -q
        systemctl restart postfix
        echo -e "${GREEN}✓ Postfix configured and started${NC}"
    fi
fi

# ── Configure ssmtp (Linux) ───────────────────────────────────
if [ "$PLATFORM" = "linux" ] && [ "$INSTALL_MAIL" = true ] && \
   [ "$MAIL_TRANSPORT" = "ssmtp" ]; then
    if [ -f /etc/ssmtp/ssmtp.conf ]; then
        echo -e "${YELLOW}⚠ Existing ssmtp config found – not overwritten.${NC}"
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

# ── Create directories ────────────────────────────────────────
mkdir -p "$TARGET_DIR"
mkdir -p "$CONF_TARGET_DIR"
if [ "$PLATFORM" = "macos" ]; then
    mkdir -p "$LOG_DIR" "$STATE_DIR" "$HOME/Library/LaunchAgents"
else
    mkdir -p "$LOG_DIR" "$STATE_DIR"
fi
echo -e "${GREEN}✓ Directories created${NC}"

# ── Install core script ───────────────────────────────────────
echo ""
echo -e "  ${BOLD}Installing check-certs${NC}"
copy_script "check-certs.sh"
copy_conf

# Symlink: /usr/local/bin/check-certs → TARGET_DIR/check-certs.sh
# This puts check-certs on $PATH for all users and all shells without
# requiring a shell alias or sourcing a rc file.
ALIAS_RC_FILE=""  # kept for summary section compatibility
if [ -L "$BIN_DIR/check-certs" ] || [ -f "$BIN_DIR/check-certs" ]; then
    rm -f "$BIN_DIR/check-certs"
    echo -e "${YELLOW}⚠ Existing $BIN_DIR/check-certs removed${NC}"
fi
ln -s "$TARGET_DIR/check-certs.sh" "$BIN_DIR/check-certs"
echo -e "${GREEN}✓ Symlink created: $BIN_DIR/check-certs${NC}"

# ── Write check-certs.conf ────────────────────────────────────
if [ -f "$CONF_TARGET_DIR/check-certs.conf" ]; then
    cp "$CONF_TARGET_DIR/check-certs.conf" "$CONF_TARGET_DIR/check-certs.conf.bak"
    echo -e "${YELLOW}⚠ Existing check-certs.conf backed up to $CONF_TARGET_DIR/check-certs.conf.bak${NC}"
fi

# Always write check-certs.conf — even for a terminal-only install.
# Without it, check-certs.sh falls back to built-in defaults but the
# user has nowhere obvious to edit settings. Terminal-only installs
# get the base thresholds; automation installs also get their variant
# settings appended below.
{
    echo "# check-certs configuration – generated by installer"
    echo ""
    echo "# ── Thresholds ──────────────────────────────────────────"
    echo "WARN_DAYS=${WARN_DAYS:-15}"
    echo "CRIT_DAYS=${CRIT_DAYS:-7}"
    echo "URGENT_DAYS=${URGENT_DAYS:-2}"
    echo "TIMEOUT=5"
    echo "MAX_JOBS=10"
    echo "CA_MAX_LEN=30"

    if [ "$INSTALL_NOTIFY" = true ]; then
        echo ""
        echo "# ── Notification log ────────────────────────────────────"
        echo "LOG_FILE=\"\$HOME/Library/Logs/check-certs/check-certs-notify.log\""
    fi

    if [ "$INSTALL_MAIL" = true ]; then
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
        [ -n "$WEBHOOK_AUTH_HEADER" ] && {
            echo "WEBHOOK_AUTH_HEADER=\"${WEBHOOK_AUTH_HEADER}\""
            echo "WEBHOOK_AUTH_VALUE=\"${WEBHOOK_AUTH_VALUE}\""
        }
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

    if [ "$INSTALL_NTFY" = true ]; then
        echo ""
        echo "# ── ntfy settings ───────────────────────────────────────"
        echo "NTFY_URL=\"${NTFY_URL}\""
        echo "NTFY_TOPIC=\"${NTFY_TOPIC}\""
        [ -n "$NTFY_TOKEN" ] && echo "NTFY_TOKEN=\"${NTFY_TOKEN}\""
        [ -n "$NTFY_USER"  ] && echo "NTFY_USER=\"${NTFY_USER}\""
        [ -n "$NTFY_PASS"  ] && echo "NTFY_PASS=\"${NTFY_PASS}\""
    fi
} > "$CONF_TARGET_DIR/check-certs.conf"
echo -e "${GREEN}✓ check-certs.conf written to $CONF_TARGET_DIR/${NC}"

# ── Create state directories ──────────────────────────────────
# Each automation variant stores per-host state files in its own
# subdirectory of STATE_DIR. Creating these here means the first run
# never needs to create them itself.
[ "$INSTALL_NOTIFY"   = true ] && mkdir -p "$STATE_DIR/state-notify"
[ "$INSTALL_MAIL"     = true ] && mkdir -p "$STATE_DIR/state-mail"
[ "$INSTALL_WEBHOOK"  = true ] && mkdir -p "$STATE_DIR/state-webhook"
[ "$INSTALL_TEAMS"    = true ] && mkdir -p "$STATE_DIR/state-teams"
[ "$INSTALL_PUSHOVER" = true ] && mkdir -p "$STATE_DIR/state-pushover"
[ "$INSTALL_NTFY"     = true ] && mkdir -p "$STATE_DIR/state-ntfy"

# ── Install variants ──────────────────────────────────────────

# macOS notifications
if [ "$INSTALL_NOTIFY" = true ]; then
    echo ""; echo -e "  ${BOLD}Notification variant${NC}"
    copy_script "check-certs-notify.sh"
    _install_plist "$INSTALL_DIR/$NOTIFY_PLIST_NAME" "$NOTIFY_PLIST_TARGET" \
        "$TARGET_DIR/check-certs-notify.sh" "com.check-certs.notify" \
        "$NOTIFY_HOUR" "$NOTIFY_MINUTE"
    echo ""
    echo -e "${YELLOW}  Allow notifications: System Settings → Notifications → terminal-notifier${NC}"
    echo ""
    read -r -p "  Run a test now? [Y/n] " run_test
    [[ ! "$run_test" =~ ^[nN]$ ]] && "$TARGET_DIR/check-certs-notify.sh" || true
fi

# Email
if [ "$INSTALL_MAIL" = true ]; then
    echo ""; echo -e "  ${BOLD}Email variant${NC}"
    copy_script "check-certs-mail.sh"

    if [ "$PLATFORM" = "macos" ]; then
        _install_derived_plist "com.check-certs.mail" \
            "$TARGET_DIR/check-certs-mail.sh" "$MAIL_HOUR" "$MAIL_MINUTE"
    else
        _add_cron "check-certs-mail.sh" "$MAIL_HOUR" "$MAIL_MINUTE"
    fi

    # Helper for building test email headers
    _sm_cmd() {
        printf 'To: %s\nFrom: %s\nSubject: check-certs: test email\nContent-Type: text/plain; charset=UTF-8\n\ncheck-certs installation test\n' \
            "$MAIL_TO" "$MAIL_FROM"
    }
    echo ""
    read -r -p "  Send a test email to '$MAIL_TO'? [Y/n] " send_test
    if [[ ! "$send_test" =~ ^[nN]$ ]]; then
        case "$MAIL_TRANSPORT" in
            postfix)
                if _sm_cmd | mail -s "check-certs: test email" -a "From: $MAIL_FROM" "$MAIL_TO" 2>/dev/null; then
                    echo -e "${GREEN}✓ Test email sent${NC}"
                else
                    echo -e "${YELLOW}⚠ Test email failed. Check: journalctl -u postfix${NC}"
                fi ;;
            ssmtp)
                if _sm_cmd | ssmtp "$MAIL_TO" 2>/dev/null; then
                    echo -e "${GREEN}✓ Test email sent${NC}"
                else
                    echo -e "${YELLOW}⚠ Test email failed. Check ssmtp config.${NC}"
                fi ;;
            sendmail)
                _sm=$(command -v sendmail 2>/dev/null || echo "/usr/sbin/sendmail")
                if _sm_cmd | "$_sm" -f "$MAIL_FROM" "$MAIL_TO" 2>/dev/null; then
                    echo -e "${GREEN}✓ Test email sent${NC}"
                else
                    echo -e "${YELLOW}⚠ Test email failed. Check your MTA.${NC}"
                fi ;;
        esac
    fi
fi

# Webhook
if [ "$INSTALL_WEBHOOK" = true ]; then
    echo ""; echo -e "  ${BOLD}Webhook variant${NC}"
    copy_script "check-certs-webhook.sh"

    if [ "$PLATFORM" = "macos" ]; then
        _install_plist "$INSTALL_DIR/$WEBHOOK_PLIST_NAME" "$WEBHOOK_PLIST_TARGET" \
            "$TARGET_DIR/check-certs-webhook.sh" "com.check-certs.webhook" \
            "$WEBHOOK_HOUR" "$WEBHOOK_MINUTE"
    else
        _add_cron "check-certs-webhook.sh" "$WEBHOOK_HOUR" "$WEBHOOK_MINUTE"
    fi

    echo ""
    read -r -p "  Send a test POST? [Y/n] " send_test
    if [[ ! "$send_test" =~ ^[nN]$ ]]; then
        _pf=$(mktemp)
        printf '%s' '{"event":"test","message":"check-certs installation test"}' > "$_pf"
        _args=(-s -o /dev/null -w "%{http_code}" -X POST "$WEBHOOK_URL"
               -H "Content-Type: application/json" --data-binary "@${_pf}")
        [ -n "$WEBHOOK_AUTH_HEADER" ] && _args+=(-H "$WEBHOOK_AUTH_HEADER: $WEBHOOK_AUTH_VALUE")
        _code=$(curl "${_args[@]}" 2>/dev/null) || true
        rm -f "$_pf"
        [[ "$_code" =~ ^2 ]] \
            && echo -e "${GREEN}✓ Test POST sent (HTTP ${_code})${NC}" \
            || echo -e "${YELLOW}⚠ HTTP ${_code:-no response}. Check WEBHOOK_URL.${NC}"
    fi
fi

# Teams
if [ "$INSTALL_TEAMS" = true ]; then
    echo ""; echo -e "  ${BOLD}Teams variant${NC}"
    copy_script "check-certs-teams.sh"

    if [ "$PLATFORM" = "macos" ]; then
        _install_derived_plist "com.check-certs.teams" \
            "$TARGET_DIR/check-certs-teams.sh" "$TEAMS_HOUR" "$TEAMS_MINUTE"
    else
        _add_cron "check-certs-teams.sh" "$TEAMS_HOUR" "$TEAMS_MINUTE"
    fi
fi

# Pushover
if [ "$INSTALL_PUSHOVER" = true ]; then
    echo ""; echo -e "  ${BOLD}Pushover variant${NC}"
    copy_script "check-certs-pushover.sh"

    if [ "$PLATFORM" = "macos" ]; then
        _install_plist "$INSTALL_DIR/$PUSHOVER_PLIST_NAME" "$PUSHOVER_PLIST_TARGET" \
            "$TARGET_DIR/check-certs-pushover.sh" "com.check-certs.pushover" \
            "$PUSHOVER_HOUR" "$PUSHOVER_MINUTE"
    else
        _add_cron "check-certs-pushover.sh" "$PUSHOVER_HOUR" "$PUSHOVER_MINUTE"
    fi
fi

# ntfy
if [ "$INSTALL_NTFY" = true ]; then
    echo ""; echo -e "  ${BOLD}ntfy variant${NC}"
    copy_script "check-certs-ntfy.sh"

    if [ "$PLATFORM" = "macos" ]; then
        _install_plist "$INSTALL_DIR/$NTFY_PLIST_NAME" "$NTFY_PLIST_TARGET" \
            "$TARGET_DIR/check-certs-ntfy.sh" "com.check-certs.ntfy" \
            "$NTFY_HOUR" "$NTFY_MINUTE"
    else
        _add_cron "check-certs-ntfy.sh" "$NTFY_HOUR" "$NTFY_MINUTE"
    fi

    echo ""
    read -r -p "  Send a test notification to topic '$NTFY_TOPIC'? [Y/n] " send_test
    if [[ ! "$send_test" =~ ^[nN]$ ]]; then
        _ntfy_auth_args=()
        [ -n "$NTFY_TOKEN" ] && _ntfy_auth_args+=(-H "Authorization: Bearer $NTFY_TOKEN")
        [ -z "$NTFY_TOKEN" ] && [ -n "$NTFY_USER" ] && _ntfy_auth_args+=(-u "$NTFY_USER:$NTFY_PASS")
        _code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST \
            "${_ntfy_auth_args[@]}" \
            -H "Title: check-certs: installation test" \
            -H "Priority: 2" \
            -H "Tags: white_check_mark" \
            -d "check-certs was successfully installed on $(hostname)." \
            "$NTFY_URL/$NTFY_TOPIC" 2>/dev/null) || true
        [[ "$_code" =~ ^2 ]] \
            && echo -e "${GREEN}✓ Test notification sent (HTTP ${_code})${NC}" \
            || echo -e "${YELLOW}⚠ HTTP ${_code:-no response}. Check NTFY_URL and NTFY_TOPIC.${NC}"
    fi
fi

# ── Summary ───────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}✅ Installation complete!${NC}"
echo ""
echo -e "  Scripts:       ${BOLD}$TARGET_DIR${NC}"
echo -e "  Command:       ${BOLD}$BIN_DIR/check-certs${NC}"
echo -e "  Config:        ${BOLD}$CONF_TARGET_DIR/check-certs.conf${NC}"
echo -e "  Server list:   ${BOLD}$CONF_TARGET_DIR/servers.conf${NC}"
[ "$INSTALL_NONE" = false ] && \
    echo -e "  Thresholds:    ${BOLD}warning >${WARN_DAYS}d  critical >${CRIT_DAYS}d  urgent >${URGENT_DAYS}d${NC}"
[ "$INSTALL_NOTIFY"   = true ] && echo -e "  Notifications: daily at ${NOTIFY_HOUR}:$(printf '%02d' "$NOTIFY_MINUTE")"
[ "$INSTALL_MAIL"     = true ] && {
    echo -e "  Email:         daily at ${MAIL_HOUR}:$(printf '%02d' "$MAIL_MINUTE") (${MAIL_TRANSPORT})"
    echo -e "  Alerts to:     ${BOLD}$MAIL_TO${NC}"
    [ "$MAIL_TO_URGENT" != "$MAIL_TO" ] && echo -e "  Urgent to:     ${BOLD}$MAIL_TO_URGENT${NC}"
}
[ "$INSTALL_WEBHOOK"  = true ] && \
    echo -e "  Webhook:       daily at ${WEBHOOK_HOUR}:$(printf '%02d' "$WEBHOOK_MINUTE")"
[ "$INSTALL_TEAMS"    = true ] && \
    echo -e "  Teams:         daily at ${TEAMS_HOUR}:$(printf '%02d' "$TEAMS_MINUTE")"
[ "$INSTALL_PUSHOVER" = true ] && \
    echo -e "  Pushover:      daily at ${PUSHOVER_HOUR}:$(printf '%02d' "$PUSHOVER_MINUTE")"
[ "$INSTALL_NTFY"     = true ] && \
    echo -e "  ntfy:          daily at ${NTFY_HOUR}:$(printf '%02d' "$NTFY_MINUTE")  (${NTFY_URL}/${NTFY_TOPIC})"
echo ""

# No shell reload needed — check-certs is now on PATH via symlink
if [ -n "$ALIAS_RC_FILE" ]; then
    echo "  Reload your shell or run:"
    echo -e "    ${BOLD}source $ALIAS_RC_FILE${NC}"
    echo ""
fi

echo -e "  Then use:"
echo -e "    ${BOLD}check-certs${NC}                   Check all servers"
echo -e "    ${BOLD}check-certs <host>:<port>${NC}      Check a single server"
echo -e "    ${BOLD}check-certs --list${NC}             List configured servers"
echo -e "    ${BOLD}check-certs --clear-state${NC}      Reset state (force fresh notifications)"
echo ""
echo "  Edit server list:"
echo -e "    ${BOLD}$CONF_TARGET_DIR/servers.conf${NC}"
echo ""

if [ "$INSTALL_NONE" = false ] && [ "$PLATFORM" = "linux" ]; then
    echo "  Syslog entries:"
    echo -e "    ${BOLD}journalctl -t check-certs${NC}"
    echo "  Log rotation:"
    echo -e "    ${BOLD}/etc/logrotate.d/check-certs${NC} (weekly, 8 weeks)"
    echo ""
fi
