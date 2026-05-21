# check-certs – Pushover Notifications

Daily background monitoring via cron (Linux) or launchd (macOS) with
[Pushover](https://pushover.net) mobile notifications. Pushover's priority
system maps directly onto certificate severity levels — URGENT certificates
trigger emergency-priority notifications that retry every few minutes until
you acknowledge them on your phone.

← [Back to overview](../README.md)

---

## Contents

- [How it works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
  - [Manual installation](#manual-installation)
- [Configuration](#configuration)
- [Priority mapping](#priority-mapping)
- [Log](#log)
- [Adjustments](#adjustments)

---

## How it works

Runs daily and sends Pushover notifications only when there is something to
report. State is tracked between runs so known issues only trigger a new
notification when their severity changes, with daily reminders for persistent
critical and urgent issues.

Notifications are grouped by severity — one push per level — so URGENT and
CRITICAL arrive as separate alerts. When multiple servers share a level the
most severe entry is shown first with a `(+N more)` count.

---

## Prerequisites

- A [Pushover](https://pushover.net) account (one-time $5 per platform)
- An application token — create one at [pushover.net/apps](https://pushover.net/apps)
- Your user key — shown on your [Pushover dashboard](https://pushover.net)
- `curl` installed (`apt install curl` / `brew install curl`)

---

## Installation

### Manual installation

**Linux:**

```bash
apt install openssl curl

mkdir -p /opt/check-certs /var/lib/check-certs
cp src/check-certs.sh /opt/check-certs/
cp src/check-certs-pushover.sh /opt/check-certs/
cp config/servers.conf /opt/check-certs/
chmod +x /opt/check-certs/check-certs.sh /opt/check-certs/check-certs-pushover.sh
touch /var/lib/check-certs/state
```

Write `check-certs.conf`:

```bash
cat > /opt/check-certs/check-certs.conf << 'CONF'
WARN_DAYS=15
CRIT_DAYS=7
URGENT_DAYS=2
TIMEOUT=5
MAX_JOBS=10
CA_MAX_LEN=30
STATE_FILE=/var/lib/check-certs/state
PUSHOVER_APP_TOKEN="your-app-token"
PUSHOVER_USER_KEY="your-user-key"
CONF
```

Set up the cron job:

```bash
crontab -e
```

```
0 7 * * * /opt/check-certs/check-certs-pushover.sh
```

**macOS:**

```bash
brew install openssl coreutils curl

mkdir -p ~/scripts/check-certs
cp src/check-certs.sh ~/scripts/check-certs/
cp src/check-certs-pushover.sh ~/scripts/check-certs/
cp config/servers.conf ~/scripts/check-certs/
chmod +x ~/scripts/check-certs/check-certs.sh ~/scripts/check-certs/check-certs-pushover.sh
mkdir -p "$HOME/Library/Application Support/check-certs"
```

Write `check-certs.conf`:

```bash
cat > ~/scripts/check-certs/check-certs.conf << 'CONF'
WARN_DAYS=15
CRIT_DAYS=7
URGENT_DAYS=2
TIMEOUT=5
MAX_JOBS=10
CA_MAX_LEN=30
STATE_FILE="$HOME/Library/Application Support/check-certs/state"
LOG_FILE="$HOME/Library/Logs/check-certs/check-certs-pushover.log"
PUSHOVER_APP_TOKEN="your-app-token"
PUSHOVER_USER_KEY="your-user-key"
CONF
```

Set up a launchd job using the webhook plist template:

```bash
sed \
    -e "s|SCRIPT_PATH_PLACEHOLDER|$HOME/scripts/check-certs/check-certs-pushover.sh|g" \
    -e "s|HOUR_PLACEHOLDER|7|g" \
    -e "s|MINUTE_PLACEHOLDER|0|g" \
    -e "s|LOGDIR_PLACEHOLDER|$HOME/Library/Logs/check-certs|g" \
    install/com.check-certs.webhook.plist \
    > ~/Library/LaunchAgents/com.check-certs.pushover.plist
launchctl load ~/Library/LaunchAgents/com.check-certs.pushover.plist
```

---

## Configuration

All settings go in `check-certs.conf`. Required:

| Setting | Description |
| ------- | ----------- |
| `PUSHOVER_APP_TOKEN` | Application API token from [pushover.net/apps](https://pushover.net/apps) |
| `PUSHOVER_USER_KEY` | Your user or group key from your Pushover dashboard |

Optional:

| Setting | Default | Description |
| ------- | ------- | ----------- |
| `PUSHOVER_DEVICE` | *(all devices)* | Limit notifications to a specific device name |
| `PUSHOVER_RETRY` | `300` | Emergency priority: retry interval in seconds (min 30) |
| `PUSHOVER_EXPIRE` | `3600` | Emergency priority: stop retrying after this many seconds (max 10800) |

---

## Priority mapping

Pushover priorities control sound, interruption, and retry behaviour:

| Status | Priority | Behaviour |
| ------ | -------- | --------- |
| RENEWED | `-1` Quiet | Delivered silently, no sound, does not wake screen |
| WARNING | `0` Normal | Standard notification with sound |
| CRITICAL | `1` High | Bypasses the user's quiet hours |
| URGENT / EXPIRED | `2` Emergency | Alerts repeatedly every `PUSHOVER_RETRY` seconds until acknowledged, for up to `PUSHOVER_EXPIRE` seconds |
| ERROR | `1` High | Bypasses quiet hours |
| CRITICAL / WARNING reminders | `1` High | Bypasses quiet hours |
| URGENT / EXPIRED reminders | `2` Emergency | Continues alerting until acknowledged |

Emergency priority (2) requires the recipient to open the Pushover app and
tap **Acknowledge**. Until they do, Pushover keeps resending the notification.
This makes it appropriate for URGENT and EXPIRED certificates, where the
consequences of missing the alert are significant.

> **Note:** Pushover charges a one-time $5 licence fee per platform (iOS,
> Android). The API itself has no per-message cost up to 10,000 messages per
> month per application token.

---

## Log

Each run writes a timestamped log entry per server:

```
[2026-05-21 07:00:01] Started – checking 8 servers
[2026-05-21 07:00:01] ── LDAP ──
[2026-05-21 07:00:03] ldap.example.com                           185d  OK           (CA: GEANT TLS RSA 1)
[2026-05-21 07:00:04] ldap-dev.example.com                          -  ERROR        (Unreachable)
[2026-05-21 07:00:05] ── Web ──
[2026-05-21 07:00:06] www.example.com                             54d  OK           (CA: GEANT TLS RSA 1)
[2026-05-21 07:00:06] intranet.example.com                         5d  CRITICAL     (CA: GEANT TLS RSA 1) → notification sent
[2026-05-21 07:00:09] Done – 8 checked, 1 notification(s), 1 error(s)
```

**Linux:**
```bash
tail -f /var/log/check-certs/check-certs-pushover.log
```

**macOS:**
```bash
tail -f ~/Library/Logs/check-certs/check-certs-pushover.log
```

---

## Adjustments

**Change thresholds:** Edit `check-certs.conf` — `WARN_DAYS`, `CRIT_DAYS`, `URGENT_DAYS`.

**Limit to one device:** Add `PUSHOVER_DEVICE="my-iphone"` to `check-certs.conf`. The device name is shown in the Pushover app under Settings.

**Adjust emergency retry timing:**
```bash
PUSHOVER_RETRY=120    # Retry every 2 minutes
PUSHOVER_EXPIRE=7200  # Give up after 2 hours
```

**Send to a group instead of a user:** Replace `PUSHOVER_USER_KEY` with a Pushover group key. Group keys are created on the Pushover website and allow sending to multiple users simultaneously.

**Reset state:**

```bash
# Linux
> /var/lib/check-certs/state

# macOS
> "$HOME/Library/Application Support/check-certs/state"
```

---

→ [Troubleshooting](troubleshooting.md)
