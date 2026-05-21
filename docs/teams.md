# check-certs – Microsoft Teams Adaptive Card Notifications

Daily background monitoring via cron (Linux) or launchd (macOS). Sends a
single Adaptive Card to a Teams channel mirroring the terminal table — all
servers grouped by section, colour-coded status, and a summary line — but
only when notification thresholds are reached. Silent runs produce no output.

← [Back to overview](../README.md)

---

## Contents

- [How it works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Part 1 — Create the Teams Workflow](#part-1--create-the-teams-workflow)
- [Part 2 — Configure check-certs](#part-2--configure-check-certs)
- [Installation](#installation)
- [Card format](#card-format)
- [Adjustments](#adjustments)
- [Troubleshooting](#troubleshooting)

---

## How it works

After all certificate checks complete, `check-certs-teams.sh` builds one
Adaptive Card containing every server result and posts it to your Teams
channel. The card is only sent when new findings or daily reminders are
due — if everything is fine and no escalation is triggered, nothing is posted.

This is different from the generic webhook wrapper, which posts one small
payload per finding. The Teams wrapper gives you the full picture in a single
card on every alert.

---

## Prerequisites

- Microsoft Teams with the **Workflows** app available (included in all
  Microsoft 365 plans)
- `curl` installed on the machine running check-certs
- A Teams channel to post to

---

## Part 1 — Create the Teams Workflow

The Teams Workflow receives the HTTP POST from check-certs and posts the
Adaptive Card to your channel. No Power Automate configuration is needed
beyond this initial setup — the wrapper sends a complete, pre-formatted card.

1. In Teams, navigate to the channel where you want alerts
2. Click **⋯** next to the channel name → **Workflows**
3. Search for **"Post to a channel when a webhook request is received"**
4. Click the template and select **Add workflow**
5. Choose the team and channel (can be the same channel or a dedicated
   alerts channel)
6. Click **Add workflow**
7. Copy the webhook URL — it looks like:
   `https://prod-xx.westeurope.logic.azure.com:443/workflows/...`

That's all. The workflow is ready to receive the Adaptive Card payload that
`check-certs-teams.sh` builds.

> **Important:** The workflow is owned by the user who creates it. If that
> account is deactivated, the workflow stops. Assign a co-owner in
> Power Automate (`make.powerautomate.com`) under the workflow's **Share**
> settings to prevent this.

---

## Part 2 — Configure check-certs

Add to `check-certs.conf`:

```bash
TEAMS_WEBHOOK_URL="https://prod-xx.westeurope.logic.azure.com:443/workflows/..."
```

Test the connection:

```bash
curl -X POST "$TEAMS_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "message",
    "attachments": [{
      "contentType": "application/vnd.microsoft.card.adaptive",
      "contentUrl": null,
      "content": {
        "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        "type": "AdaptiveCard",
        "version": "1.4",
        "body": [{"type": "TextBlock", "text": "check-certs test"}]
      }
    }]
  }'
```

A `200` response means the workflow is reachable. A card titled
"check-certs test" should appear in your Teams channel.

---

## Installation

### Manual installation

**Linux:**

```bash
apt install openssl curl

mkdir -p /opt/check-certs /var/lib/check-certs
cp src/check-certs.sh /opt/check-certs/
cp src/check-certs-teams.sh /opt/check-certs/
cp config/servers.conf /opt/check-certs/
chmod +x /opt/check-certs/check-certs.sh /opt/check-certs/check-certs-teams.sh
touch /var/lib/check-certs/state-teams
```

Add to `/opt/check-certs/check-certs.conf`:

```bash
WARN_DAYS=15
CRIT_DAYS=7
URGENT_DAYS=2
TEAMS_WEBHOOK_URL="https://prod-xx.westeurope.logic.azure.com:443/workflows/..."
```

Set up the cron job:

```bash
crontab -e
```

```
0 7 * * * /opt/check-certs/check-certs-teams.sh
```

**macOS:**

```bash
brew install openssl coreutils curl

mkdir -p ~/scripts/check-certs
cp src/check-certs.sh ~/scripts/check-certs/
cp src/check-certs-teams.sh ~/scripts/check-certs/
cp config/servers.conf ~/scripts/check-certs/
chmod +x ~/scripts/check-certs/check-certs.sh ~/scripts/check-certs/check-certs-teams.sh
mkdir -p "$HOME/Library/Application Support/check-certs"
touch "$HOME/Library/Application Support/check-certs/state-teams"
```

Add to `~/scripts/check-certs/check-certs.conf`:

```bash
TEAMS_WEBHOOK_URL="https://prod-xx.westeurope.logic.azure.com:443/workflows/..."
```

Use the webhook plist template for the launchd job:

```bash
sed \
    -e "s|com.check-certs.webhook|com.check-certs.teams|g" \
    -e "s|check-certs-webhook|check-certs-teams|g" \
    -e "s|SCRIPT_PATH_PLACEHOLDER|$HOME/scripts/check-certs/check-certs-teams.sh|g" \
    -e "s|HOUR_PLACEHOLDER|7|g" \
    -e "s|MINUTE_PLACEHOLDER|0|g" \
    -e "s|LOGDIR_PLACEHOLDER|$HOME/Library/Logs/check-certs|g" \
    install/com.check-certs.webhook.plist \
    > ~/Library/LaunchAgents/com.check-certs.teams.plist
launchctl load ~/Library/LaunchAgents/com.check-certs.teams.plist
```

---

## Card format

The card mirrors the terminal table output:

```
┌─────────────────────────────────────────────────────────┐
│  🚨 Certificate issues found          2026-05-21 07:00  │
├─────────────────────────────────────────────────────────┤
│  Server           Days    Expiry       Status    CA      │
│  ─────────────────────────────────────────────────────  │
│  LDAP                                                   │
│  ldap.example.com  185d  Nov 20 2026  OK        GEANT   │
│  ldap-dev…           -   -            ERROR     Unreach  │
│  Web                                                    │
│  www.example.com    5d   May 26 2026  CRITICAL  GEANT   │
│  intranet…         54d   Jul 14 2026  OK        GEANT   │
├─────────────────────────────────────────────────────────┤
│  8 checked · ✓ 5 OK · ⚠ 1 Warning · ✗ 2 Critical/Error │
└─────────────────────────────────────────────────────────┘
```

**Header colour:**
- 🟢 Green container — all OK (only shown with reminders still pending)
- 🟡 Warning container — warnings only
- 🔴 Attention container — critical, urgent, expired, or errors present

**Status colours in the card:**
- `good` (green) — OK
- `warning` (amber) — WARNING
- `attention` (red) — CRITICAL, URGENT, EXPIRED, ERROR

**Reminder vs new finding** — the header title changes:
- New findings: `🚨 Certificate issues found`
- Reminder run: `🔁 Reminder: Certificate issues found`

---

## Adjustments

**Change thresholds:** Edit `WARN_DAYS`, `CRIT_DAYS`, `URGENT_DAYS` in
`check-certs.conf`.

**Run alongside other variants:** The Teams wrapper uses `state-teams` as its
default state file, independent of other variants.

**Reset state:**

```bash
# Linux
> /var/lib/check-certs/state-teams

# macOS
> "$HOME/Library/Application Support/check-certs/state-teams"
```

**Disable:** Unload the launchd job (macOS) or remove the cron entry (Linux).

```bash
# macOS
launchctl unload ~/Library/LaunchAgents/com.check-certs.teams.plist

# Linux
crontab -e   # remove the check-certs-teams.sh line
```

---

## Troubleshooting

**Card posts but is empty or broken** — most likely a JSON formatting
problem in the Adaptive Card body. Run the wrapper manually and pipe the
output to check the payload:

```bash
/opt/check-certs/check-certs-teams.sh 2>&1
```

Validate the card JSON at
[adaptivecards.io/designer](https://adaptivecards.io/designer/).

**HTTP 400 from the workflow URL** — the payload structure must include the
`"type": "message"` wrapper and the `"contentType"` field in attachments.
The test curl command in Part 2 verifies this independently.

**Workflow stopped posting** — check if the workflow owner's account is
still active. Add a co-owner in Power Automate to prevent orphaned workflows.

**No card sent even though certificates are expiring** — the wrapper only
sends a card when escalation fires. If state already recorded those
certificates as known issues, run with a fresh state file to confirm:

```bash
STATE_FILE=/tmp/test-state /opt/check-certs/check-certs-teams.sh
```

---

→ [Troubleshooting](troubleshooting.md)
