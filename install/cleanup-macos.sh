#!/bin/bash

# ============================================================
#  cleanup-macos.sh – Remove pre-2.7.0 check-certs installation
#
#  Removes the old ~/scripts/check-certs/ directory, the shell
#  alias from rc files, and any launchd jobs from the old install.
#
#  Safe to run even if some parts were never installed — each
#  step checks before acting and reports what it does.
#
#  Run BEFORE installing check-certs 2.7.0.
#  Does NOT touch:
#    ~/Library/Application Support/check-certs/   (state — kept)
#    ~/Library/Logs/check-certs/                  (logs — kept)
#    ~/Library/LaunchAgents/com.check-certs.*.plist (unloaded + removed)
# ============================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

OLD_DIR="$HOME/scripts/check-certs"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"

ok()   { printf "${GREEN}✓${NC}  %s\n" "$*"; }
warn() { printf "${YELLOW}⚠${NC}  %s\n" "$*"; }
skip() { printf "   %s\n" "$*"; }

echo ""
echo -e "${BOLD}check-certs pre-2.7.0 cleanup${NC}"
echo "──────────────────────────────"
echo ""

# ── 1. Unload and remove launchd jobs ────────────────────────
echo -e "${BOLD}Launchd jobs${NC}"
for label in notify mail webhook teams pushover ntfy; do
    plist="$LAUNCH_AGENTS/com.check-certs.${label}.plist"
    if [ -f "$plist" ]; then
        launchctl unload "$plist" 2>/dev/null && true
        rm -f "$plist"
        ok "Unloaded and removed com.check-certs.${label}.plist"
    else
        skip "com.check-certs.${label}.plist — not found, skipping"
    fi
done
echo ""

# ── 2. Remove old script directory ───────────────────────────
echo -e "${BOLD}Script directory${NC}"
if [ -d "$OLD_DIR" ]; then
    # Show what will be deleted so there are no surprises
    echo "   Contents of $OLD_DIR:"
    ls "$OLD_DIR" | sed 's/^/     /'
    echo ""
    read -r -p "   Remove $OLD_DIR and all its contents? [y/N] " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        rm -rf "$OLD_DIR"
        ok "Removed $OLD_DIR"

        # Remove ~/scripts/ itself if now empty
        if [ -d "$HOME/scripts" ] && [ -z "$(ls -A "$HOME/scripts")" ]; then
            rmdir "$HOME/scripts"
            ok "Removed ~/scripts/ (was empty)"
        fi
    else
        warn "Skipped — $OLD_DIR not removed"
    fi
else
    skip "$OLD_DIR — not found, skipping"
fi
echo ""

# ── 3. Remove alias from shell rc files ──────────────────────
echo -e "${BOLD}Shell alias${NC}"
RC_FILES=("$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile")
for rc in "${RC_FILES[@]}"; do
    [ -f "$rc" ] || continue
    if grep -q "alias check-certs" "$rc"; then
        # Remove the alias line and the '# check-certs' comment line above it
        # Use a temp file so we don't partially edit on failure
        tmp=$(mktemp)
        grep -v "^# check-certs$" "$rc" | grep -v "alias check-certs=" > "$tmp"
        mv "$tmp" "$rc"
        ok "Removed alias from $(basename "$rc")"
    else
        skip "$(basename "$rc") — no alias found, skipping"
    fi
done
echo ""

# ── 4. Remove symlink at /usr/local/bin if pointing at old dir ─
echo -e "${BOLD}Old symlink${NC}"
if [ -L "/usr/local/bin/check-certs" ]; then
    target=$(readlink "/usr/local/bin/check-certs")
    if [[ "$target" == "$HOME/scripts/check-certs/"* ]]; then
        sudo rm -f "/usr/local/bin/check-certs"
        ok "Removed old symlink /usr/local/bin/check-certs → $target"
    else
        skip "/usr/local/bin/check-certs points to $target — not from old install, leaving it"
    fi
elif [ -f "/usr/local/bin/check-certs" ]; then
    warn "/usr/local/bin/check-certs exists but is not a symlink — inspect manually"
else
    skip "/usr/local/bin/check-certs — not found, skipping"
fi
echo ""

# ── Done ─────────────────────────────────────────────────────
echo -e "${GREEN}${BOLD}Cleanup complete.${NC}"
echo ""
echo "  State and logs have been preserved:"
echo "    $HOME/Library/Application Support/check-certs/"
echo "    $HOME/Library/Logs/check-certs/"
echo ""
echo "  You can now run the 2.7.0 installer:"
echo -e "    ${BOLD}chmod +x install/install.sh && ./install/install.sh${NC}"
echo ""
