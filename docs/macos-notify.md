# check-certs – macOS Notifications

Daily background monitoring via `launchd` with native macOS notifications. When a certificate is about to expire, you get a notification with sound – and clicking it opens `check-certs` in a new Terminal window showing the full table.

This is an optional add-on. `check-certs.sh` (the terminal table) must already be installed – see the [main README](../README.md) for that.

← [Back to overview](../README.md)

---

## Contents

- [Installation](#installation)
  - [Automatic](#automatic)
  - [Manual](#manual)
  - [Directory structure](#directory-structure)
- [Allowing notifications](#allowing-notifications)
- [How it works](#how-it-works)
- [Notification types](#notification-types)
- [Log](#log)
- [Adjustments](#adjustments)

---

## Installation

### Automatic

Run the macOS installer and select **1) Notifications** when prompted (option numbers may shift as new variants are added — check the menu):

```bash
chmod +x install/install.sh
./install/install.sh
```

The installer prompts for thresholds and run time, writes `check-certs.conf`, copies the scripts and sets up the launchd job.

| Prompt | Description | Default |
| ------ | ----------- | ------- |
| Warning threshold (days) | First notification X days before expiry | `15` |
| Critical threshold (days) | Daily reminder from X days before expiry | `7` |
| Urgent threshold (days) | Escalation from X days before expiry | `2` |
| Run time | Hour and minute of daily execution | `7:00` |

### Manual

```bash
brew install terminal-notifier
mkdir -p ~/Library/Logs/check-certs

sudo cp src/check-certs-notify.sh /usr/local/lib/check-certs/
sudo chmod +x /usr/local/lib/check-certs/check-certs-notify.sh
```

Edit `check-certs.conf` to set thresholds and state file path:

```bash
nano ~/.config/check-certs/check-certs.conf
```

```bash
WARN_DAYS=15
CRIT_DAYS=7
URGENT_DAYS=2
STATE_FILE="$HOME/Library/Application Support/check-certs/state-notify"
```

Set up the launchd job:

```bash
sed \
    -e "s|SCRIPT_PATH_PLACEHOLDER|/usr/local/lib/check-certs/check-certs-notify.sh|g" \
    -e "s|HOUR_PLACEHOLDER|7|g" \
    -e "s|MINUTE_PLACEHOLDER|0|g" \
    -e "s|LOGDIR_PLACEHOLDER|$HOME/Library/Logs/check-certs|g" \
    install/com.check-certs.notify.plist \
    > ~/Library/LaunchAgents/com.check-certs.notify.plist
launchctl load ~/Library/LaunchAgents/com.check-certs.notify.plist
```

### Directory structure

```
/usr/local/lib/check-certs/
├── check-certs.sh               ← always present
└── check-certs-notify.sh        ← added by this variant

~/.config/check-certs/
├── check-certs.conf             ← configuration
└── servers.conf

~/Library/LaunchAgents/
└── com.check-certs.notify.plist

~/Library/Logs/check-certs/
├── check-certs-notify.log
└── check-certs-notify.error.log

~/Library/Application Support/check-certs/
└── state-notify/                ← per-host state files (one file per server)
```

---

## Allowing notifications

The first time it runs, macOS will ask whether `terminal-notifier` may send notifications. If no notifications appear afterwards: **System Settings → Notifications → terminal-notifier → enable**.

> Notifications appear under the name **"terminal-notifier"**, not "Terminal".

---

## How it works

Runs daily via `launchd` and sends notifications **only when there is something to report**. State is tracked between runs so that known issues only trigger a new notification when their severity level changes.

| Level | Default | Behaviour |
| ----- | ------- | --------- |
| **RENEWED** | – | One-time notification when a previously non-OK cert is valid again |
| **WARNING** | < `WARN_DAYS` | One-time notification; again only on status change |
| **CRITICAL** | < `CRIT_DAYS` | Daily reminder with "Ping" sound |
| **URGENT** | < `URGENT_DAYS` | Daily reminder with "Basso" sound |
| **EXPIRED** | past expiry | Daily reminder with "Basso" sound |

Notifications are grouped by severity – one notification per level – so URGENT and CRITICAL issues arrive as separate alerts. When multiple servers share a level, the most critical is shown first with a `(+N more)` count.

---

## Notification types

| Title | Trigger | Sound | Click opens |
| ----- | ------- | ----- | ----------- |
| ✅ Certificate renewed | Was non-OK, now valid | – | Full certificate table |
| 🚨 Act now – certificate expiring | New URGENT or EXPIRED finding | Basso | Full certificate table |
| ⚠️ Certificate expiring soon | New CRITICAL finding | Ping | Full certificate table |
| 🔔 Certificate expiry notice | New WARNING finding | – | Full certificate table |
| 🚨 Reminder – Act now | Daily reminder, URGENT or EXPIRED | Basso | Full certificate table |
| 🔁 Reminder – certificates expiring | Daily reminder, CRITICAL or WARNING | Ping | Full certificate table |

---

## Log

Each run writes a timestamped log entry per server, grouped by `servers.conf` section.
Entries marked `→ notification sent` or `→ reminder sent` triggered a macOS notification.
All other entries were silent (OK, or a known issue within the 23-hour reminder window).

```
[2026-05-18 07:00:01] Started – checking 8 servers
[2026-05-18 07:00:01] ── LDAP ──
[2026-05-18 07:00:03] ldap.example.com                           185d  OK           (CA: GEANT TLS RSA 1)
[2026-05-18 07:00:04] ldap-dev.example.com                          -  ERROR        (Unreachable)
[2026-05-18 07:00:05] ── Web ──
[2026-05-18 07:00:06] www.example.com                             54d  OK           (CA: GEANT TLS RSA 1)
[2026-05-18 07:00:06] intranet.example.com                         5d  CRITICAL     (CA: GEANT TLS RSA 1) → notification sent
[2026-05-18 07:00:07] ── Services ──
[2026-05-18 07:00:08] mail.example.com                            12d  WARNING      (CA: Let's Encrypt)
[2026-05-18 07:00:08] old-cert.example.com                       210d  RENEWED      (CA: Let's Encrypt) → notification sent
[2026-05-18 07:00:09] Done – 8 checked, 2 notification(s), 1 error(s)
```

The `WARNING` entry for `mail.example.com` has no suffix — it was a known issue within the 23-hour reminder window and received no notification on this run.

```bash
tail -f ~/Library/Logs/check-certs/check-certs-notify.log
```

---

## Adjustments

**Change thresholds:** Edit `check-certs.conf`:

```bash
nano ~/.config/check-certs/check-certs.conf
```

The relevant settings are `WARN_DAYS`, `CRIT_DAYS` and `URGENT_DAYS`.

**Change run time:** Unload the job, edit the plist, then reload:

```bash
launchctl unload ~/Library/LaunchAgents/com.check-certs.notify.plist
nano ~/Library/LaunchAgents/com.check-certs.notify.plist
```

Set the desired hour and minute:

```xml
<key>Hour</key><integer>8</integer>
<key>Minute</key><integer>30</integer>
```

```bash
launchctl load ~/Library/LaunchAgents/com.check-certs.notify.plist
```

**Reset state:**

```bash
# All servers (forces fresh notifications on next run)
check-certs --clear-state
# This variant only
check-certs --clear-state --state-dir "$HOME/Library/Application Support/check-certs/state-notify"
```

**Remove launchd job:**

```bash
launchctl unload ~/Library/LaunchAgents/com.check-certs.notify.plist
rm ~/Library/LaunchAgents/com.check-certs.notify.plist
```

---

→ [Troubleshooting](troubleshooting.md)
