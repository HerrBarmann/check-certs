#!/bin/bash

# ============================================================
#  install-macos.sh – Installs check-certs on macOS
#
#  Always installs:
#    check-certs.sh      – terminal table view + shell alias
#
#  Optionally installs one or more automation variants:
#    check-certs-notify.sh  – daily macOS notifications via launchd
#    check-certs-mail.sh    – email via ssmtp or sendmail
#    check-certs-webhook.sh – HTTP POST to Slack, ntfy, Teams, etc.
#    check-certs-pushover.sh – Pushover mobile push
#
#  Usage: ./install-macos.sh
# ============================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$INSTALL_DIR/../src" && pwd)"
CONF_DIR="$(cd "$INSTALL_DIR/../config" && pwd)"
TARGET_DIR="$HOME/scripts/check-certs"
LOG_DIR="$HOME/Library/Logs/check-certs"

NOTIFY_PLIST_NAME="com.check-certs.notify.plist"
WEBHOOK_PLIST_NAME="com.check-certs.webhook.plist"
PUSHOVER_PLIST_NAME="com.check-certs.pushover.plist"
NOTIFY_PLIST_TARGET="$HOME/Library/LaunchAgents/$NOTIFY_PLIST_NAME"
WEBHOOK_PLIST_TARGET="$HOME/Library/LaunchAgents/$WEBHOOK_PLIST_NAME"
PUSHOVER_PLIST_TARGET="$HOME/Library/LaunchAgents/$PUSHOVER_PLIST_NAME"

# Default threshold values
WARN_DAYS=15; CRIT_DAYS=7; URGENT_DAYS=2

# ── Helper functions ─────────────────────────────────────────
require_file() {
    local dir="$1" file="$2"
    if [ ! -f "$dir/$file" ]; then
        echo -e "${RED}✗ File '$file' not found (expected in: $dir)${NC}"
        exit 1
    fi
}

copy_script() {
    local name="$1"
    if [ -f "$TARGET_DIR/$name" ]; then
        echo -e "${YELLOW}⚠ '$name' already exists.${NC}"
        read -r -p "  Overwrite? [y/N] " confirm
        if [[ ! "$confirm" =~ ^[yYjJ]$ ]]; then
            echo "  Skipped."
            return 0
        fi
    fi
    cp "$SRC_DIR/$name" "$TARGET_DIR/$name"
    chmod +x "$TARGET_DIR/$name"
    echo -e "${GREEN}✓ $name installed${NC}"
}

copy_conf() {
    if [ -f "$TARGET_DIR/servers.conf" ]; then
        echo -e "${YELLOW}⚠ 'servers.conf' already exists – will not be overwritten.${NC}"
    else
        cp "$CONF_DIR/servers.conf" "$TARGET_DIR/servers.conf"
        echo -e "${GREEN}✓ servers.conf copied${NC}"
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

_prompt_launch_time() {
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

    read -r -p "  Sender address [certcheck@$(hostname -f 2>/dev/null || hostname)]: " MAIL_FROM
    MAIL_FROM="${MAIL_FROM:-certcheck@$(hostname -f 2>/dev/null || hostname)}"
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
    read -r -p "  SMTP username: " SMTP_USER
    while [[ -z "$SMTP_USER" || ! "$SMTP_USER" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; do
        echo -e "  ${RED}Invalid email address. Please try again.${NC}"
        read -r -p "  SMTP username: " SMTP_USER
    done
    read -r -s -p "  SMTP password: " SMTP_PASS; echo ""
    while [ -z "$SMTP_PASS" ]; do
        echo -e "  ${RED}Please enter a password.${NC}"
        read -r -s -p "  SMTP password: " SMTP_PASS; echo ""
    done
}

# _install_plist <plist_src> <plist_dst> <script_path> <label> <hour> <minute>
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

_install_mail_plist() {
    local script_path="$1" hour="$2" minute="$3"
    local plist_dst="$HOME/Library/LaunchAgents/com.check-certs.mail.plist"
    local label="com.check-certs.mail"
    if launchctl list 2>/dev/null | grep -q "$label"; then
        launchctl unload "$plist_dst" 2>/dev/null || true
        echo -e "${YELLOW}⚠ Existing launchd job '$label' unloaded${NC}"
    fi
    sed \
        -e "s|com.check-certs.webhook|${label}|g" \
        -e "s|check-certs-webhook|check-certs-mail|g" \
        -e "s|SCRIPT_PATH_PLACEHOLDER|${script_path}|g" \
        -e "s|HOUR_PLACEHOLDER|${hour}|g" \
        -e "s|MINUTE_PLACEHOLDER|${minute}|g" \
        -e "s|LOGDIR_PLACEHOLDER|${LOG_DIR}|g" \
        "$INSTALL_DIR/$WEBHOOK_PLIST_NAME" > "$plist_dst"
    launchctl load "$plist_dst"
    echo -e "${GREEN}✓ launchd job '$label' loaded (daily at ${hour}:$(printf '%02d' "$minute"))${NC}"
}

# ═══════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}check-certs Installer${NC} ${CYAN}(macOS)${NC}"
echo "──────────────────────────────"
echo ""

# ── Variant selection ─────────────────────────────────────────
echo -e "  check-certs.sh (terminal table view) will always be installed."
echo -e "  Select one or more automation variants to install.\n"
echo -e "  ${BOLD}1)${NC} Notifications – daily macOS notifications via launchd"
echo -e "  ${BOLD}2)${NC} Email         – daily email, choose transport in the next step"
echo -e "  ${BOLD}3)${NC} Webhook       – HTTP POST to Slack, ntfy, Teams, custom endpoints"
echo -e "  ${BOLD}4)${NC} Pushover      – mobile push notifications with priority levels"
echo -e "  ${BOLD}5)${NC} Terminal only – skip automation for now"
echo ""
echo -e "  Enter one or more numbers separated by spaces (e.g. ${BOLD}1 4${NC}):"
read -r -p "  Choose: " VARIANT_INPUT
echo ""

INSTALL_NOTIFY=false
INSTALL_MAIL=false
MAIL_TRANSPORT="ssmtp"
INSTALL_WEBHOOK=false
INSTALL_PUSHOVER=false
INSTALL_NONE=false

for choice in $VARIANT_INPUT; do
    case "$choice" in
        1) INSTALL_NOTIFY=true   ;;
        2) INSTALL_MAIL=true     ;;
        3) INSTALL_WEBHOOK=true  ;;
        4) INSTALL_PUSHOVER=true ;;
        *) INSTALL_NONE=true     ;;
    esac
done

if [ "$INSTALL_NOTIFY" = false ] && [ "$INSTALL_MAIL" = false ] && \
   [ "$INSTALL_WEBHOOK" = false ] && [ "$INSTALL_PUSHOVER" = false ]; then
    INSTALL_NONE=true
fi

echo "──────────────────────────────"
echo ""

# ── Verify source files ──────────────────────────────────────
require_file "$SRC_DIR"     "check-certs.sh"
require_file "$CONF_DIR"    "servers.conf"
[ "$INSTALL_NOTIFY"   = true ] && require_file "$SRC_DIR" "check-certs-notify.sh" \
                                && require_file "$INSTALL_DIR" "$NOTIFY_PLIST_NAME"
[ "$INSTALL_MAIL"     = true ] && require_file "$SRC_DIR" "check-certs-mail.sh"
[ "$INSTALL_WEBHOOK"  = true ] && require_file "$SRC_DIR" "check-certs-webhook.sh" \
                                && require_file "$INSTALL_DIR" "$WEBHOOK_PLIST_NAME"
[ "$INSTALL_PUSHOVER" = true ] && require_file "$SRC_DIR" "check-certs-pushover.sh" \
                                && require_file "$INSTALL_DIR" "$PUSHOVER_PLIST_NAME"

# ── Configuration prompts ─────────────────────────────────────

# Shared thresholds — prompt once
if [ "$INSTALL_NONE" = false ]; then
    echo -e "  ${BOLD}Thresholds${NC} (shared by all variants)"
    echo ""
    _prompt_thresholds
    echo ""
    echo "──────────────────────────────"
    echo ""
fi

# Notifications
if [ "$INSTALL_NOTIFY" = true ]; then
    echo -e "  ${BOLD}Notification variant${NC}"
    echo ""
    _prompt_launch_time "Notifications run time"
    NOTIFY_HOUR="$_HOUR"; NOTIFY_MINUTE="$_MINUTE"
    echo ""
    echo "──────────────────────────────"
    echo ""
fi

# Email
if [ "$INSTALL_MAIL" = true ]; then
    echo -e "  ${BOLD}Email variant${NC}"
    echo ""
    echo -e "  Mail transport:"
    echo -e "    ${BOLD}1)${NC} ssmtp    – lightweight, no daemon"
    echo -e "    ${BOLD}2)${NC} sendmail – use your existing MTA (e.g. brew install postfix)"
    echo ""
    read -r -p "  Choose transport [1/2]: " _mt
    [ "$_mt" = "2" ] && MAIL_TRANSPORT="sendmail" || MAIL_TRANSPORT="ssmtp"
    echo ""
    _prompt_email
    [ "$MAIL_TRANSPORT" = "ssmtp" ] && _prompt_smtp
    _prompt_launch_time "Email run time"
    MAIL_HOUR="$_HOUR"; MAIL_MINUTE="$_MINUTE"
    echo ""
    echo "──────────────────────────────"
    echo ""
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
    _prompt_launch_time "Webhook run time"
    WEBHOOK_HOUR="$_HOUR"; WEBHOOK_MINUTE="$_MINUTE"
    echo ""
    echo "──────────────────────────────"
    echo ""
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
    _prompt_launch_time "Pushover run time"
    PUSHOVER_HOUR="$_HOUR"; PUSHOVER_MINUTE="$_MINUTE"
    echo ""
    echo "──────────────────────────────"
    echo ""
fi

# ── Homebrew ─────────────────────────────────────────────────
if ! command -v brew &>/dev/null; then
    echo -e "${RED}✗ Homebrew not found.${NC}"
    echo '  Install it: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    exit 1
fi
echo -e "${GREEN}✓ Homebrew found${NC}"

# ── Dependencies ─────────────────────────────────────────────
DEPS="coreutils openssl"
[ "$INSTALL_NOTIFY" = true ] && DEPS="$DEPS terminal-notifier"
if [ "$INSTALL_MAIL" = true ] && [ "$MAIL_TRANSPORT" = "ssmtp" ]; then
    DEPS="$DEPS ssmtp"
fi
echo "  Installing dependencies ($DEPS)..."
# shellcheck disable=SC2086
brew install $DEPS --quiet
echo -e "${GREEN}✓ Dependencies installed${NC}"

if [ "$INSTALL_MAIL" = true ] && [ "$MAIL_TRANSPORT" = "sendmail" ]; then
    if ! command -v sendmail &>/dev/null; then
        echo -e "${YELLOW}⚠ sendmail not found. Install an MTA: brew install postfix${NC}"
    fi
fi

# ── Create directories ───────────────────────────────────────
mkdir -p "$TARGET_DIR"
[ "$INSTALL_NONE" = false ] && mkdir -p "$LOG_DIR"
mkdir -p "$HOME/Library/LaunchAgents"
echo -e "${GREEN}✓ Directories created${NC}"

# ── Main script and servers.conf ────────────────────────────
echo ""
echo -e "  ${BOLD}Installing check-certs${NC}"
copy_script "check-certs.sh"
copy_conf

ALIAS_RC_FILE=""
ALIAS_LINE="alias check-certs=\"$TARGET_DIR/check-certs.sh\""
for config in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    [ -f "$config" ] || continue
    if grep -q "alias check-certs" "$config"; then
        echo -e "${YELLOW}⚠ Alias already present in $(basename "$config") – skipped${NC}"
    else
        { echo ""; echo "# check-certs"; echo "$ALIAS_LINE"; } >> "$config"
        echo -e "${GREEN}✓ Alias added to $(basename "$config")${NC}"
        [ -z "$ALIAS_RC_FILE" ] && ALIAS_RC_FILE="$config"
    fi
done

# ── Write check-certs.conf ───────────────────────────────────
if [ -f "$TARGET_DIR/check-certs.conf" ]; then
    echo -e "${YELLOW}⚠ 'check-certs.conf' already exists – will not be overwritten.${NC}"
    echo "  Edit it manually: $TARGET_DIR/check-certs.conf"
elif [ "$INSTALL_NONE" = false ]; then
    {
        echo "# check-certs configuration"
        echo ""
        echo "# ── Thresholds ──────────────────────────────────────────"
        echo "WARN_DAYS=${WARN_DAYS}"
        echo "CRIT_DAYS=${CRIT_DAYS}"
        echo "URGENT_DAYS=${URGENT_DAYS}"
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

# ── Install variants ─────────────────────────────────────────
mkdir -p "$HOME/Library/Application Support/check-certs"

if [ "$INSTALL_NOTIFY" = true ]; then
    echo ""
    echo -e "  ${BOLD}Notification variant${NC}"
    copy_script "check-certs-notify.sh"
    touch "$HOME/Library/Application Support/check-certs/state-notify"
    _install_plist "$INSTALL_DIR/$NOTIFY_PLIST_NAME" "$NOTIFY_PLIST_TARGET" \
        "$TARGET_DIR/check-certs-notify.sh" "com.check-certs.notify" "$NOTIFY_HOUR" "$NOTIFY_MINUTE"
    echo ""
    echo -e "${YELLOW}  Important: allow notifications${NC}"
    echo "  System Settings → Notifications → terminal-notifier → enable"
    echo ""
    read -r -p "  Run a test now? [Y/n] " run_test
    if [[ ! "$run_test" =~ ^[nN]$ ]]; then
        "$TARGET_DIR/check-certs-notify.sh" \
            && echo -e "${GREEN}✓ Test run complete${NC}" \
            || echo -e "${YELLOW}⚠ Test run complete – notifications triggered${NC}"
    fi
fi

if [ "$INSTALL_MAIL" = true ]; then
    echo ""
    echo -e "  ${BOLD}Email variant${NC}"
    copy_script "check-certs-mail.sh"
    touch "$HOME/Library/Application Support/check-certs/state-mail"
    _install_mail_plist "$TARGET_DIR/check-certs-mail.sh" "$MAIL_HOUR" "$MAIL_MINUTE"
    echo ""
    read -r -p "  Send a test email to '$MAIL_TO'? [Y/n] " send_test
    if [[ ! "$send_test" =~ ^[nN]$ ]]; then
        case "$MAIL_TRANSPORT" in
            ssmtp)
                if { printf 'To: %s\n' "$MAIL_TO"; printf 'From: %s\n' "$MAIL_FROM"
                     printf 'Subject: check-certs: test email\n'
                     printf 'Content-Type: text/plain; charset=UTF-8\n\n'
                     printf 'check-certs installation test\n'
                   } | ssmtp "$MAIL_TO"; then
                    echo -e "${GREEN}✓ Test email sent${NC}"
                else
                    echo -e "${YELLOW}⚠ Test email failed. Check ssmtp config.${NC}"
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
                    echo -e "${YELLOW}⚠ Test email failed. Check your MTA.${NC}"
                fi ;;
        esac
    fi
fi

if [ "$INSTALL_WEBHOOK" = true ]; then
    echo ""
    echo -e "  ${BOLD}Webhook variant${NC}"
    copy_script "check-certs-webhook.sh"
    touch "$HOME/Library/Application Support/check-certs/state-webhook"
    _install_plist "$INSTALL_DIR/$WEBHOOK_PLIST_NAME" "$WEBHOOK_PLIST_TARGET" \
        "$TARGET_DIR/check-certs-webhook.sh" "com.check-certs.webhook" "$WEBHOOK_HOUR" "$WEBHOOK_MINUTE"
    echo ""
    read -r -p "  Send a test POST? [Y/n] " send_test
    if [[ ! "$send_test" =~ ^[nN]$ ]]; then
        _args=(-s -o /dev/null -w "%{http_code}" -X POST "$WEBHOOK_URL"
               -H "Content-Type: application/json"
               -d '{"event":"test","message":"check-certs installation test"}')
        [ -n "$WEBHOOK_AUTH_HEADER" ] && _args+=(-H "$WEBHOOK_AUTH_HEADER: $WEBHOOK_AUTH_VALUE")
        _code=$(curl "${_args[@]}" 2>/dev/null) || true
        if [[ "$_code" =~ ^2 ]]; then
            echo -e "${GREEN}✓ Test POST sent (HTTP ${_code})${NC}"
        else
            echo -e "${YELLOW}⚠ Test POST returned HTTP ${_code:-no response}.${NC}"
        fi
    fi
fi

if [ "$INSTALL_PUSHOVER" = true ]; then
    echo ""
    echo -e "  ${BOLD}Pushover variant${NC}"
    copy_script "check-certs-pushover.sh"
    touch "$HOME/Library/Application Support/check-certs/state-pushover"
    _install_plist "$INSTALL_DIR/$PUSHOVER_PLIST_NAME" "$PUSHOVER_PLIST_TARGET" \
        "$TARGET_DIR/check-certs-pushover.sh" "com.check-certs.pushover" "$PUSHOVER_HOUR" "$PUSHOVER_MINUTE"
fi

# ── Summary ──────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}✅ Installation complete!${NC}"
echo ""
echo -e "  Installed to:  ${BOLD}$TARGET_DIR${NC}"
echo -e "  Server list:   ${BOLD}$TARGET_DIR/servers.conf${NC}"
[ "$INSTALL_NONE" = false ] && \
    echo -e "  Thresholds:    ${BOLD}warning >${WARN_DAYS}d${NC}  |  ${BOLD}critical >${CRIT_DAYS}d${NC}  |  ${BOLD}urgent >${URGENT_DAYS}d${NC}"
[ "$INSTALL_NOTIFY"   = true ] && echo -e "  Notifications: daily at ${NOTIFY_HOUR}:$(printf '%02d' "$NOTIFY_MINUTE")"
[ "$INSTALL_MAIL"     = true ] && {
    echo -e "  Email:         daily at ${MAIL_HOUR}:$(printf '%02d' "$MAIL_MINUTE") (${MAIL_TRANSPORT})"
    echo -e "  Alerts to:     ${BOLD}$MAIL_TO${NC}"
    [ "$MAIL_TO_URGENT" != "$MAIL_TO" ] && echo -e "  Urgent to:     ${BOLD}$MAIL_TO_URGENT${NC}"
}
[ "$INSTALL_WEBHOOK"  = true ] && echo -e "  Webhook:       daily at ${WEBHOOK_HOUR}:$(printf '%02d' "$WEBHOOK_MINUTE") → $WEBHOOK_URL"
[ "$INSTALL_PUSHOVER" = true ] && echo -e "  Pushover:      daily at ${PUSHOVER_HOUR}:$(printf '%02d' "$PUSHOVER_MINUTE")"
echo ""
echo -e "  Restart your terminal or run:"
if [ -n "$ALIAS_RC_FILE" ]; then
    echo -e "    ${BOLD}source $ALIAS_RC_FILE${NC}"
else
    echo -e "    ${BOLD}source ~/.zshrc${NC}"
fi
echo ""
echo -e "  Then use:"
echo -e "    ${BOLD}check-certs${NC}                  Check all servers"
echo -e "    ${BOLD}check-certs <host>:<port>${NC}     Check a single server"
echo -e "    ${BOLD}check-certs --list${NC}            List configured servers"
echo ""
if [ "$INSTALL_NONE" = false ]; then
    echo "  View logs:"
    [ "$INSTALL_NOTIFY"   = true ] && echo -e "    ${BOLD}tail -f $LOG_DIR/check-certs-notify.log${NC}"
    [ "$INSTALL_MAIL"     = true ] && echo -e "    ${BOLD}tail -f $LOG_DIR/check-certs-mail.log${NC}"
    [ "$INSTALL_WEBHOOK"  = true ] && echo -e "    ${BOLD}tail -f $LOG_DIR/check-certs-webhook.log${NC}"
    [ "$INSTALL_PUSHOVER" = true ] && echo -e "    ${BOLD}tail -f $LOG_DIR/check-certs-pushover.log${NC}"
    echo ""
fi
echo "  Edit server list:"
echo -e "    ${BOLD}$TARGET_DIR/servers.conf${NC}"
echo ""
