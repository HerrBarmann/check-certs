# check-certs – ntfy

Sends push notifications to a [ntfy](https://ntfy.sh) topic for each new finding and daily reminder. Works with the free hosted service at ntfy.sh or any self-hosted ntfy server.

No account or API key required for public topics. Private topics support token auth and basic auth.

← [Back to overview](../README.md)

---

## Contents

- [Why ntfy?](#why-ntfy)
- [How notifications work](#how-notifications-work)
- [Installation](#installation)
- [Configuration](#configuration)
- [Authentication](#authentication)
- [Notification format](#notification-format)
- [Troubleshooting](#troubleshooting)

---

## Why ntfy?

ntfy is a simple HTTP-based pub/sub notification service. You subscribe to a topic on your phone with the ntfy app, and anything posted to that topic shows up as a push notification. No account needed for public topics.

For sysadmins already running a self-hosted stack, ntfy slots in naturally — it's a single Docker container, no external dependencies.

---

## How notifications work

**New findings** (first time a certificate enters a warning/critical/expired state, or when it's renewed) arrive as individual notifications — one per host. This gives you a clear, actionable item for each problem.

**Daily reminders** for persistent issues are batched into a single notification per severity level to avoid filling your screen with repeats.

**Priority mapping** — ntfy displays different sounds and lock-screen behaviour based on priority:

| Status | Priority | ntfy behaviour |
|--------|----------|----------------|
| RENEWED | 2 – low | Quiet, no sound |
| WARNING | 3 – default | Standard alert |
| CRITICAL / ERROR | 4 – high | Bypasses Do Not Disturb |
| URGENT / EXPIRED | 5 – max | Emergency alert, may override silent mode |

---

## Installation

### Automatic (macOS and Debian/Ubuntu)

Run the unified installer and select **ntfy** when prompted:

```bash
chmod +x install/install.sh
./install/install.sh          # macOS
sudo ./install/install.sh     # Linux
```

The installer installs the script, writes `check-certs.conf` with the ntfy settings, creates the state directory, and sets up the launchd job (macOS) or cron job (Linux).

### macOS launchd

Create `/Library/LaunchAgents/com.check-certs.ntfy.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>        <string>com.check-certs.ntfy</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/lib/check-certs/check-certs-ntfy.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict><key>Hour</key><integer>7</integer><key>Minute</key><integer>0</integer></dict>
    <key>StandardOutPath</key>
    <string>/Users/YOURUSER/Library/Logs/check-certs/check-certs-ntfy.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/YOURUSER/Library/Logs/check-certs/check-certs-ntfy.log</string>
</dict>
</plist>
```

Load it:
```bash
launchctl load ~/Library/LaunchAgents/com.check-certs.ntfy.plist
```

---

## Configuration

Add these settings to `check-certs.conf`:

```bash
# ── ntfy settings (check-certs-ntfy.sh) ──────────────────────

# ntfy server URL. Use https://ntfy.sh for the hosted service,
# or your own server URL (e.g. https://ntfy.example.com).
NTFY_URL="https://ntfy.sh"

# Topic name. Anyone who knows this name can subscribe, so use
# something unguessable for public servers, or protect it with auth.
NTFY_TOPIC="my-cert-alerts-a7f3k9"
```

That's all that's required for a public ntfy.sh topic. Test it:

```bash
/usr/local/lib/check-certs/check-certs-ntfy.sh  # macOS
/opt/check-certs/check-certs-ntfy.sh             # Linux
```

---

## Authentication

For private topics or self-hosted servers with access control:

### Access token (recommended)

```bash
# Generate a token in your ntfy server's web UI or CLI, then:
NTFY_TOKEN="tk_AgQdq7mVBoFD37zQVN29RhuMzNIz2"
```

### Username and password

```bash
NTFY_USER="alice"
NTFY_PASS="s3cret"
```

Token takes precedence if both are set.

---

## Notification format

Each finding notification contains:
- **Title**: severity label (e.g. "⚠️ Certificate expiring soon")
- **Body**: hostname, days remaining, expiry date, CA name
- **Tags**: emoji tags shown as icons (e.g. 🔒⚠)
- **Priority**: maps to ntfy's 1–5 scale

Example notification body for a WARNING:
```
mail.example.com
12d remaining – warning
Expires: Jun 1 2026 (CA: Let's Encrypt)
```

Example for EXPIRED:
```
api.example.com
EXPIRED 3d ago
Expired: May 23 2026 (CA: DigiCert)
```

---

## Troubleshooting

**No notifications arriving:**
- Check the log file (`/var/log/check-certs/check-certs-ntfy.log` on Linux, `~/Library/Logs/check-certs/check-certs-ntfy.log` on macOS)
- Confirm `NTFY_URL` and `NTFY_TOPIC` are set correctly in `check-certs.conf`
- Test the POST manually: `curl -d "test message" https://ntfy.sh/your-topic`
- For private topics, verify your token or credentials

**Getting notifications for already-known issues:**
Run `check-certs --clear-state --state-dir /var/lib/check-certs/state-ntfy` to reset state. The next run will re-discover all issues.

**Certificate renewed but still getting notifications:**
State may be stale. Clear state as above, or wait — the next run will detect the renewal and send a RENEWED notification, then go silent.
