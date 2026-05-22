# check-certs – Microsoft Teams Adaptive Card Notifications

Daily background monitoring via cron (Linux) or launchd (macOS). Sends a
single Adaptive Card to a Teams channel showing all non-OK servers grouped
by section, with a summary line — but only when notification thresholds are
reached. Silent runs produce no output.

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
Adaptive Card and posts it to your Teams channel. The card is only sent when
new findings or daily reminders are due — if everything is fine and no
escalation is triggered, nothing is posted.

The card shows only servers with a non-OK status (WARNING, CRITICAL, URGENT,
EXPIRED, or ERROR). Servers that are fine are omitted to keep the card short.
Groups where all servers are OK are omitted entirely. A summary line at the
bottom shows the full count across all servers.

---

## Prerequisites

- Microsoft Teams with the **Workflows** app (included in all Microsoft 365
  plans)
- `curl` installed on the machine running check-certs
- A Teams channel to post to

---

## Part 1 — Create the Teams Workflow

The Teams Workflow receives the HTTP POST and posts the Adaptive Card to your
channel. No Power Automate configuration is needed beyond this initial setup —
the wrapper sends a complete, pre-formatted card directly.

1. In Teams, navigate to the channel where you want alerts
2. Click **⋯** next to the channel name → **Workflows**
3. Search for **"Post to a channel when a webhook request is received"**
4. Click the template and select **Add workflow**
5. Choose the team and channel
6. Click **Add workflow**
7. Copy the webhook URL — it looks like:
   `https://prod-xx.westeurope.logic.azure.com:443/workflows/...`

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
        "version": "1.2",
        "body": [{"type": "TextBlock", "text": "check-certs test"}]
      }
    }]
  }'
```

A `200` response means the workflow is reachable and a card should appear in
your Teams channel.

> **Tip:** If cards stop arriving after the first test run, the state file may
> have recorded all issues as already notified. Clear it before testing:
>
> ```bash
> # macOS
> > "$HOME/Library/Application Support/check-certs/state-teams"
> # Linux
> > /var/lib/check-certs/state-teams
> ```

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

Set up the launchd job using the webhook plist template:

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

The card shows only servers with a non-OK status, grouped by section:

```
🚨 Certificate issues found
2026-05-22 07:35

Server                      Expiry        Status
— LDAP
ldap.example.com            —             ERROR
ldap-dev.example.com        —             ERROR
— Services
legacy.example.com          —             ERROR
old-cert.example.com        Mar 27 2023   EXPIRED

24 checked · ✓ 16 OK · ⚠ 1 Warning · × 7 Critical/Error
```

**Columns:** Server · Expiry date · Status. Days remaining and CA are omitted
to maximise the space available for hostnames.

**Only non-OK servers are shown.** Groups where all servers are OK are
omitted entirely. The summary line at the bottom always reflects the full
count across all checked servers.

**Header title by run type:**

| Condition | Title |
| --------- | ----- |
| New findings, errors present | `🚨 Certificate issues found` |
| New findings, warnings only | `⚠️ Certificate warnings` |
| Daily reminder, errors present | `🔁 Reminder: certificate issues unresolved` |
| Daily reminder, warnings only | `🔁 Reminder: certificates expiring soon` |

**Debug mode** — print the card JSON without posting:

```bash
TEAMS_DEBUG=true ./check-certs-teams.sh
```

---

## Adjustments

**Change thresholds:** Edit `WARN_DAYS`, `CRIT_DAYS`, `URGENT_DAYS` in
`check-certs.conf`.

**Run alongside other variants:** Each variant uses its own state file
(`state-teams`) so they track escalation independently.

**Reset state** (forces a fresh notification on next run):

```bash
# macOS
> "$HOME/Library/Application Support/check-certs/state-teams"

# Linux
> /var/lib/check-certs/state-teams
```

**Disable:**

```bash
# macOS
launchctl unload ~/Library/LaunchAgents/com.check-certs.teams.plist
rm ~/Library/LaunchAgents/com.check-certs.teams.plist

# Linux — remove the line from crontab
crontab -e
```

---

## Troubleshooting

**Nothing arrives in Teams** — the state file may have marked all issues as
already notified. Reset it and run again:

```bash
> /var/lib/check-certs/state-teams   # Linux
TEAMS_DEBUG=true /opt/check-certs/check-certs-teams.sh
```

If debug mode produces JSON output but a live run sends nothing, the state
file is the cause.

**HTTP 400 from the workflow URL** — the payload must include the
`"type": "message"` wrapper and `"contentType"` in attachments. Use the
test curl command in Part 2 to verify the URL is reachable independently.
The card uses Adaptive Card version 1.2 for maximum Teams compatibility.

**Workflow stopped posting** — check if the workflow owner's account is
still active. Add a co-owner in Power Automate to prevent orphaned workflows.

**Card arrives but shows no servers** — all servers checked are currently OK.
The card is only sent when escalation fires (new findings or reminders), but
if it does fire and the server list is empty, check that `WARN_DAYS` is set
appropriately for your certificates' expiry dates.

---

→ [Troubleshooting](troubleshooting.md)
