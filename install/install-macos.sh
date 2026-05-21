#!/bin/bash

# ============================================================
#  install-macos.sh – Installs check-certs on macOS
#
#  Always installs:
#    check-certs.sh      – terminal table view + shell alias
#
#  Optionally installs one automation variant:
#    check-certs-notify.sh  – daily macOS notifications via launchd
#    check-certs-webhook.sh – HTTP POST to Slack, ntfy, Teams, etc.
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

# Default threshold values – used in summary even for terminal-only installs
WARN_DAYS=15
CRIT_DAYS=7
URGENT_DAYS=2

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
        echo "  Your existing configuration is preserved."
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
    read -r -p "  Run time – hour (0–23) [7]: " LAUNCH_HOUR
    LAUNCH_HOUR="${LAUNCH_HOUR:-7}"
    while ! [[ "$LAUNCH_HOUR" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; do
        echo -e "  ${RED}Please enter a valid hour (0–23).${NC}"
        read -r -p "  Run time – hour (0–23) [7]: " LAUNCH_HOUR
        LAUNCH_HOUR="${LAUNCH_HOUR:-7}"
    done

    read -r -p "  Run time – minute (0–59) [0]: " LAUNCH_MINUTE
    LAUNCH_MINUTE="${LAUNCH_MINUTE:-0}"
    while ! [[ "$LAUNCH_MINUTE" =~ ^([0-9]|[1-5][0-9])$ ]]; do
        echo -e "  ${RED}Please enter a valid minute (0–59).${NC}"
        read -r -p "  Run time – minute (0–59) [0]: " LAUNCH_MINUTE
        LAUNCH_MINUTE="${LAUNCH_MINUTE:-0}"
    done
}

# _load_plist <plist_src> <plist_dst> <script_path> <label>
# Note: reads LAUNCH_HOUR, LAUNCH_MINUTE, LOG_DIR from the outer scope.
_load_plist() {
    local plist_src="$1" plist_dst="$2" script_path="$3" label="$4"
    if launchctl list 2>/dev/null | grep -q "$label"; then
        launchctl unload "$plist_dst" 2>/dev/null || true
        echo -e "${YELLOW}⚠ Existing launchd job '$label' unloaded${NC}"
    fi
    sed \
        -e "s|SCRIPT_PATH_PLACEHOLDER|${script_path}|g" \
        -e "s|HOUR_PLACEHOLDER|${LAUNCH_HOUR}|g" \
        -e "s|MINUTE_PLACEHOLDER|${LAUNCH_MINUTE}|g" \
        -e "s|LOGDIR_PLACEHOLDER|${LOG_DIR}|g" \
        "$plist_src" > "$plist_dst"
    launchctl load "$plist_dst"
    echo -e "${GREEN}✓ launchd job set up (daily at ${LAUNCH_HOUR}:$(printf '%02d' "$LAUNCH_MINUTE"))${NC}"
}

# ═══════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}check-certs Installer${NC} ${CYAN}(macOS)${NC}"
echo "──────────────────────────────"
echo ""

# ── Variant selection ─────────────────────────────────────────
echo -e "  check-certs.sh (terminal table view) will always be installed."
echo -e "  Would you also like to set up automated background monitoring?\n"
echo -e "  ${BOLD}1)${NC} Notifications  – daily macOS notifications via launchd"
echo -e "  ${BOLD}2)${NC} Webhook        – HTTP POST to Slack, ntfy, Teams, custom endpoints"
echo -e "  ${BOLD}3)${NC} Pushover       – mobile push notifications with priority levels"
echo -e "  ${BOLD}4)${NC} Terminal only  – skip automation for now"
echo ""
read -r -p "  Choose [1/2/3/4]: " VARIANT_CHOICE
echo ""

case "$VARIANT_CHOICE" in
    1) INSTALL_VARIANT="notify"   ;;
    2) INSTALL_VARIANT="webhook"  ;;
    3) INSTALL_VARIANT="pushover" ;;
    *) INSTALL_VARIANT="none"     ;;
esac

echo "──────────────────────────────"
echo ""

# ── Verify source files ──────────────────────────────────────
require_file "$SRC_DIR"     "check-certs.sh"
require_file "$CONF_DIR"    "servers.conf"
case "$INSTALL_VARIANT" in
    notify)
        require_file "$SRC_DIR"     "check-certs-notify.sh"
        require_file "$INSTALL_DIR" "$NOTIFY_PLIST_NAME"
        ;;
    webhook)
        require_file "$SRC_DIR"     "check-certs-webhook.sh"
        require_file "$INSTALL_DIR" "$WEBHOOK_PLIST_NAME"
        ;;
    pushover)
        require_file "$SRC_DIR"     "check-certs-pushover.sh"
        require_file "$INSTALL_DIR" "$PUSHOVER_PLIST_NAME"
        ;;
esac

# ── Variant-specific configuration prompts ────────────────────
case "$INSTALL_VARIANT" in

    notify)
        echo -e "  ${BOLD}Notification variant${NC}"
        echo ""
        _prompt_thresholds
        _prompt_launch_time
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
        _prompt_launch_time
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
        _prompt_launch_time
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

# ── Homebrew ─────────────────────────────────────────────────
if ! command -v brew &>/dev/null; then
    echo -e "${RED}✗ Homebrew not found.${NC}"
    echo "  Install Homebrew first:"
    echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    exit 1
fi
echo -e "${GREEN}✓ Homebrew found${NC}"

# ── Dependencies ─────────────────────────────────────────────
DEPS="coreutils openssl"
[ "$INSTALL_VARIANT" = "notify" ] && DEPS="$DEPS terminal-notifier"
echo "  Installing dependencies ($DEPS)..."
# shellcheck disable=SC2086
brew install $DEPS --quiet
echo -e "${GREEN}✓ Dependencies installed${NC}"

# ── Create directories ───────────────────────────────────────
mkdir -p "$TARGET_DIR"
if [ "$INSTALL_VARIANT" != "none" ]; then
    mkdir -p "$LOG_DIR"
    mkdir -p "$HOME/Library/LaunchAgents"
fi
echo -e "${GREEN}✓ Directories created${NC}"

# ── Main script and servers.conf (always) ───────────────────
echo ""
echo -e "  ${BOLD}Installing check-certs${NC}"
copy_script "check-certs.sh"
copy_conf

# Track which rc file the alias was added to so the summary can reference it
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

# ── Notification variant ─────────────────────────────────────
if [ "$INSTALL_VARIANT" = "notify" ]; then
    echo ""
    echo -e "  ${BOLD}Notification variant${NC}"
    echo ""

    copy_script "check-certs-notify.sh"

    if [ -f "$TARGET_DIR/check-certs.conf" ]; then
        echo -e "${YELLOW}⚠ 'check-certs.conf' already exists – will not be overwritten.${NC}"
        echo "  Edit it manually to change settings: $TARGET_DIR/check-certs.conf"
    else
        cat > "$TARGET_DIR/check-certs.conf" << 'EOF'
# check-certs configuration
# Edit this file to change settings. Scripts are never modified directly.

# ── Thresholds ────────────────────────────────────────────────
WARN_DAYS=__WARN__
CRIT_DAYS=__CRIT__
URGENT_DAYS=__URGENT__
TIMEOUT=5
MAX_JOBS=10
CA_MAX_LEN=30

# ── State tracking ────────────────────────────────────────────
STATE_FILE="$HOME/Library/Application Support/check-certs/state"

# ── Notification log ──────────────────────────────────────────
LOG_FILE="$HOME/Library/Logs/check-certs/check-certs-notify.log"
EOF
        # Replace threshold placeholders with the prompted values
        sed -i '' \
            -e "s/__WARN__/${WARN_DAYS}/" \
            -e "s/__CRIT__/${CRIT_DAYS}/" \
            -e "s/__URGENT__/${URGENT_DAYS}/" \
            "$TARGET_DIR/check-certs.conf"
        echo -e "${GREEN}✓ check-certs.conf written${NC}"
    fi

    mkdir -p "$HOME/Library/Application Support/check-certs"
    _load_plist \
        "$INSTALL_DIR/$NOTIFY_PLIST_NAME" "$NOTIFY_PLIST_TARGET" \
        "$TARGET_DIR/check-certs-notify.sh" "com.check-certs.notify"

    echo ""
    echo -e "${YELLOW}  Important: allow notifications${NC}"
    echo "  When running for the first time, macOS will ask whether"
    echo "  terminal-notifier may send notifications. Please allow it."
    echo "  If no notifications appear:"
    echo "  System Settings → Notifications → terminal-notifier → enable"

    echo ""
    read -r -p "  Run a test now? [Y/n] " run_test
    if [[ ! "$run_test" =~ ^[nN]$ ]]; then
        if "$TARGET_DIR/check-certs-notify.sh"; then
            echo -e "${GREEN}✓ Test run complete – all certificates OK${NC}"
        else
            echo -e "${YELLOW}⚠ Test run complete – notifications were triggered${NC}"
        fi
    fi
fi

# ── Webhook variant ──────────────────────────────────────────
if [ "$INSTALL_VARIANT" = "webhook" ]; then
    echo ""
    echo -e "  ${BOLD}Webhook variant${NC}"
    echo ""

    copy_script "check-certs-webhook.sh"

    if [ -f "$TARGET_DIR/check-certs.conf" ]; then
        echo -e "${YELLOW}⚠ 'check-certs.conf' already exists – will not be overwritten.${NC}"
        echo "  Edit it manually to change settings: $TARGET_DIR/check-certs.conf"
    else
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
            echo 'STATE_FILE="$HOME/Library/Application Support/check-certs/state"'
            echo ""
            echo "# ── Webhook settings ────────────────────────────────────"
            echo "WEBHOOK_URL=\"${WEBHOOK_URL}\""
            if [ -n "$WEBHOOK_AUTH_HEADER" ]; then
                echo "WEBHOOK_AUTH_HEADER=\"${WEBHOOK_AUTH_HEADER}\""
                echo "WEBHOOK_AUTH_VALUE=\"${WEBHOOK_AUTH_VALUE}\""
            fi
            echo "WEBHOOK_SEND_SUMMARY=${WEBHOOK_SEND_SUMMARY}"
        } > "$TARGET_DIR/check-certs.conf"
        echo -e "${GREEN}✓ check-certs.conf written${NC}"
    fi

    mkdir -p "$HOME/Library/Application Support/check-certs"
    _load_plist \
        "$INSTALL_DIR/$WEBHOOK_PLIST_NAME" "$WEBHOOK_PLIST_TARGET" \
        "$TARGET_DIR/check-certs-webhook.sh" "com.check-certs.webhook"

    echo ""
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
fi

# ── Pushover variant ──────────────────────────────────────────
if [ "$INSTALL_VARIANT" = "pushover" ]; then
    echo ""
    echo -e "  ${BOLD}Pushover variant${NC}"
    echo ""

    copy_script "check-certs-pushover.sh"

    if [ -f "$TARGET_DIR/check-certs.conf" ]; then
        echo -e "${YELLOW}⚠ 'check-certs.conf' already exists – will not be overwritten.${NC}"
        echo "  Edit it manually to change settings: $TARGET_DIR/check-certs.conf"
    else
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
            echo 'STATE_FILE="$HOME/Library/Application Support/check-certs/state"'
            echo ""
            echo "# ── Pushover settings ───────────────────────────────────"
            echo "PUSHOVER_APP_TOKEN=\"${PUSHOVER_APP_TOKEN}\""
            echo "PUSHOVER_USER_KEY=\"${PUSHOVER_USER_KEY}\""
            [ -n "$PUSHOVER_DEVICE" ] && echo "PUSHOVER_DEVICE=\"${PUSHOVER_DEVICE}\""
        } > "$TARGET_DIR/check-certs.conf"
        echo -e "${GREEN}✓ check-certs.conf written${NC}"
    fi

    mkdir -p "$HOME/Library/Application Support/check-certs"
    _load_plist \
        "$INSTALL_DIR/$PUSHOVER_PLIST_NAME" "$PUSHOVER_PLIST_TARGET" \
        "$TARGET_DIR/check-certs-pushover.sh" "com.check-certs.pushover"

    echo ""
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
fi

# ── Summary ──────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}✅ Installation complete!${NC}"
echo ""
echo -e "  Installed to:  ${BOLD}$TARGET_DIR${NC}"
echo -e "  Server list:   ${BOLD}$TARGET_DIR/servers.conf${NC}"
if [ "$INSTALL_VARIANT" != "none" ]; then
    echo -e "  Thresholds:    ${BOLD}warning >${WARN_DAYS}d${NC}  |  ${BOLD}critical >${CRIT_DAYS}d${NC}  |  ${BOLD}urgent >${URGENT_DAYS}d${NC}"
fi
case "$INSTALL_VARIANT" in
    webhook)
        echo -e "  Webhook:       ${BOLD}$WEBHOOK_URL${NC}"
        ;;
    pushover)
        echo -e "  Pushover:      ${BOLD}user key configured${NC}"
        ;;
esac
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

case "$INSTALL_VARIANT" in
    notify)
        echo -e "  ${BOLD}Notification variant:${NC}"
        echo -e "  Runs automatically every day at ${LAUNCH_HOUR}:$(printf '%02d' "$LAUNCH_MINUTE")."
        echo ""
        echo "  View logs:"
        echo -e "    ${BOLD}tail -f $LOG_DIR/check-certs-notify.log${NC}"
        echo ""
        ;;
    webhook)
        echo -e "  ${BOLD}Webhook variant:${NC}"
        echo -e "  Runs automatically every day at ${LAUNCH_HOUR}:$(printf '%02d' "$LAUNCH_MINUTE")."
        echo ""
        echo "  View logs:"
        echo -e "    ${BOLD}tail -f $LOG_DIR/check-certs-webhook.log${NC}"
        echo ""
        ;;
    pushover)
        echo -e "  ${BOLD}Pushover variant:${NC}"
        echo -e "  Runs automatically every day at ${LAUNCH_HOUR}:$(printf '%02d' "$LAUNCH_MINUTE")."
        echo ""
        echo "  View logs:"
        echo -e "    ${BOLD}tail -f $LOG_DIR/check-certs-pushover.log${NC}"
        echo ""
        ;;
esac

echo "  Edit server list:"
echo -e "    ${BOLD}$TARGET_DIR/servers.conf${NC}"
echo ""
