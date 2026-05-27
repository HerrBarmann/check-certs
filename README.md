# check-certs

[🇩🇪 Auf Deutsch lesen](README-DE.md)

You know that sinking feeling when a user calls to say your site is showing a scary browser warning? Or when your LDAP authentication silently dies at 3am because a certificate quietly expired while you were busy with other things – like sleeping?

check-certs is a certificate monitoring tool that watches expiry dates across all your servers and alerts you well before anything breaks. It checks all servers in parallel, verifies the full certificate chain (not just the leaf certificate – a broken intermediate CA is caught and reported), understands STARTTLS protocols like SMTP, IMAP and LDAP, and tracks state between runs so you only hear about something when it actually changes. Alerts go wherever you want them: a colour-coded terminal table for a quick glance, native macOS notifications, email, an HTTP webhook, Microsoft Teams, ntfy, or Pushover mobile push with emergency-priority acknowledgement for the ones that really can't wait.

No more surprise expirations. No more embarrassing phone calls. Just certificates, quietly minding their own deadlines.

---

## Contents

- [Overview](#overview)
- [Installation](#installation)
  - [macOS](#macos)
  - [Linux](#linux)
- [Server configuration](#server-configuration)
- [Configuration](#configuration)
- [Usage](#usage)
- [Single-server check](#single-server-check)
- [Output](#output)
- [Background monitoring](#background-monitoring)
- [Files](#files)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [Licence](#licence)

---

## Overview

check-certs consists of `check-certs.sh` and the automation variants built on top of it.

**`check-certs.sh`** is the main script – a colour-coded terminal table that works on both macOS and Linux. It also contains the shared core logic that all automation variants build on. Both installers always include it.

Six optional automation variants extend it with background monitoring:

| Variant | Script | Platform | Details |
| ------- | ------ | -------- | ------- |
| **Notification** | `check-certs-notify.sh` | macOS | Native notifications via launchd → [docs/macos-notify.md](docs/macos-notify.md) |
| **Email** | `check-certs-mail.sh` | Linux + macOS | Email via Postfix, ssmtp, or sendmail → [docs/email.md](docs/email.md) |
| **Webhook** | `check-certs-webhook.sh` | Linux + macOS | HTTP POST to Slack, ntfy, Teams, custom endpoints → [docs/webhook.md](docs/webhook.md) |
| **Teams** | `check-certs-teams.sh` | Linux + macOS | Adaptive Card to Microsoft Teams via Workflow webhook → [docs/teams.md](docs/teams.md) |
| **Pushover** | `check-certs-pushover.sh` | Linux + macOS | Mobile push with priority levels and emergency acknowledgement → [docs/pushover.md](docs/pushover.md) |
| **ntfy** | `check-certs-ntfy.sh` | Linux + macOS | Push notifications via ntfy.sh or self-hosted ntfy → [docs/ntfy.md](docs/ntfy.md) |

**Key features:**

- Checks all servers **in parallel** (up to `MAX_JOBS` concurrent connections, results displayed in original `servers.conf` order)
- Verifies the **full certificate chain**, not just the leaf certificate – a broken intermediate CA is caught and reported
- **State tracking** ensures you only get notified when something changes, not on every daily run
- **Escalation levels** with distinct behaviour at warning, critical and urgent thresholds
- **STARTTLS** auto-detected on standard ports (SMTP, IMAP, POP3, LDAP, FTP, XMPP)

---

## Installation

### macOS

**Requires:** Homebrew (`coreutils` and `openssl` are installed automatically).

**Automatic** – installs `check-certs.sh`, sets up the alias, and optionally configures one or more automation variants (notifications, email, webhook, Teams, Pushover, ntfy) via launchd:

```bash
chmod +x install/install.sh && ./install/install.sh
```

**Manual** – terminal table only:

```bash
brew install coreutils openssl
mkdir -p ~/scripts/check-certs
cp src/check-certs.sh config/servers.conf config/check-certs.conf ~/scripts/check-certs/
chmod +x ~/scripts/check-certs/check-certs.sh
echo 'alias check-certs="$HOME/scripts/check-certs/check-certs.sh"' >> ~/.zshrc
source ~/.zshrc
```

To add background monitoring after a manual install, copy the relevant script from `src/` to your install directory and follow the setup guide:

- 🍎 [macOS notifications](docs/macos-notify.md) – `check-certs-notify.sh`
- 📧 [Email](docs/email.md) – `check-certs-mail.sh`
- 🌐 [Webhook](docs/webhook.md) – `check-certs-webhook.sh`
- 💬 [Teams](docs/teams.md) – `check-certs-teams.sh`
- 📱 [Pushover](docs/pushover.md) – `check-certs-pushover.sh`
- 🔔 [ntfy](docs/ntfy.md) – `check-certs-ntfy.sh`

### Linux

GNU `date` is available natively — no Homebrew or `coreutils` needed.

**Automatic** (Debian/Ubuntu) – installs `check-certs.sh` and optionally configures one or more automation variants (email, webhook, Teams, Pushover, ntfy) via cron:

```bash
chmod +x install/install.sh && sudo ./install/install.sh
```

**Manual** – terminal table only:

```bash
apt install openssl        # Debian/Ubuntu
# or: dnf install openssl  # Fedora/RHEL

mkdir -p /opt/check-certs
cp src/check-certs.sh config/servers.conf config/check-certs.conf /opt/check-certs/
chmod +x /opt/check-certs/check-certs.sh
echo 'alias check-certs="/opt/check-certs/check-certs.sh"' >> ~/.bashrc
source ~/.bashrc
```

To add background monitoring after a manual install, copy the relevant script from `src/` to your install directory and follow the setup guide:

- 📧 [Email](docs/email.md) – `check-certs-mail.sh`
- 🌐 [Webhook](docs/webhook.md) – `check-certs-webhook.sh`
- 💬 [Teams](docs/teams.md) – `check-certs-teams.sh`
- 📱 [Pushover](docs/pushover.md) – `check-certs-pushover.sh`
- 🔔 [ntfy](docs/ntfy.md) – `check-certs-ntfy.sh`

---

## Server configuration

`servers.conf` is shared by all variants. Servers are organised into named **groups**:

```
# Lines starting with # are comments

[LDAP]
ldap.example.com:636:ldaps
ldap-plain.example.com:389
ldap-ng.example.com:389:ldap

[Mail]
mail.example.com:587:submission
imap.example.com:143:imap
imap.example.com:993:imaps

[Web]
www.example.com:443:https
intranet.example.com:443:https

[Services]
ticketing.example.com:443:https
custom.example.com:8443:tls
```

**Entry format:** `hostname:port` or `hostname:port:proto`

IPv6 addresses use bracket notation: `[2001:db8::1]:443` or `[::1]:636:ldaps`

STARTTLS is automatically applied on standard ports. Optional `key=value` pairs after the port field override the global thresholds for that server:

| Override | Description |
| -------- | ----------- |
| `warn=N` | Warning threshold in days |
| `crit=N` | Critical threshold in days |
| `urgent=N` | Urgent threshold in days (0 = disabled) |
| `timeout=N` | Connection timeout in seconds |

```
api.example.com:443 warn=30 crit=14   # stricter thresholds for a critical API
internal.example.com:443 warn=7        # more relaxed for internal tools
slow.example.com:443 timeout=15        # longer timeout for a slow host
```

`check-certs --list` shows active overrides next to each entry. Use the optional `:proto`
field to override protocol detection or to force plain TLS on a non-standard port.

| Port(s) | Auto-detected protocol |
| ------- | ---------------------- |
| 25, 587 | `smtp` |
| 143 | `imap` |
| 110 | `pop3` |
| 389 | `ldap` |
| 21 | `ftp` |
| 5222 | `xmpp` |
| all others | plain TLS |

STARTTLS protocols: `smtp` `submission` `imap` `pop3` `ldap` `ftp` `xmpp`

Plain TLS aliases (self-documenting, no STARTTLS): `tls` `https` `ldaps` `imaps` `pop3s` `smtps` `ftps`

> An existing `servers.conf` is **never overwritten** during reinstallation.

---

## Configuration

All settings live in `check-certs.conf` in the same directory as the scripts. The installers write a minimal `check-certs.conf` containing only the settings relevant to the chosen variant. For a manual install, copy `config/check-certs.conf` from the repository as a starting point — it documents every available setting. To change any setting after installation, edit the file directly – the scripts themselves never need to be modified.

```bash
nano ~/scripts/check-certs/check-certs.conf   # macOS
nano /opt/check-certs/check-certs.conf         # Linux
```

Key settings:

| Setting | Default | Description |
| ------- | ------- | ----------- |
| `WARN_DAYS` | `15` | First warning X days before expiry |
| `CRIT_DAYS` | `7` | Daily reminder from X days before expiry |
| `URGENT_DAYS` | `2` | Urgent alert from X days (0 = disabled) |
| `TIMEOUT` | `5` | Connection timeout per server in seconds |
| `MAX_JOBS` | `10` | Maximum parallel checks |
| `MAIL_TRANSPORT` | `postfix` (Linux) / `ssmtp` (macOS) | Email transport: `postfix`, `ssmtp`, or `sendmail` |
| `MAIL_TO` | – | Primary email recipient |
| `MAIL_TO_URGENT` | – | Second recipient for urgent alerts |
| `MAIL_FROM` | – | Sender address |
| `WEBHOOK_URL` | – | URL to POST findings to |
| `TEAMS_WEBHOOK_URL` | – | Teams Workflow webhook URL |
| `PUSHOVER_APP_TOKEN` | – | Pushover application token |
| `PUSHOVER_USER_KEY` | – | Pushover user or group key |
| `NTFY_URL` | – | ntfy server URL (e.g. `https://ntfy.sh`) |
| `NTFY_TOPIC` | – | ntfy topic name |
| `NTFY_TOKEN` | – | ntfy access token (optional, for protected topics) |

> On reinstallation, an existing `check-certs.conf` is backed up to `check-certs.conf.bak` before being overwritten.

---

## Usage

```bash
check-certs                              # Check all servers from servers.conf
check-certs <hostname>                   # Check a single server (port defaults to 443)
check-certs <hostname>:<port>            # Check a single server on a specific port
check-certs <hostname>:<port>:<proto>    # Check with explicit STARTTLS protocol
check-certs --scan <hostname>            # Probe common TLS ports (onboarding helper)
check-certs --list                       # List all servers without running checks
check-certs --check <host>[:<port>]       # key=value output for scripting (port defaults to 443)
check-certs --check --nagios <host>[:<port>]  # Nagios/Icinga plugin output
check-certs --check --json <host>[:<port>]    # JSON output
check-certs --clear-state                # Clear all state (forces fresh notifications)
check-certs --version                    # Show version
check-certs --help                       # Show help
```

---

## Single-server check

`check-certs --check` performs a structured check on one server and prints
machine-readable output — useful for scripting, monitoring integrations, and
testing STARTTLS configuration. The port is optional and defaults to 443.
IPv6 addresses use bracket notation: `[::1]:443`.

**Output modes:**

```bash
check-certs --check mail.example.com              # key=value, port defaults to 443
check-certs --check mail.example.com:587          # key=value with explicit port
check-certs --check --nagios mail.example.com:587  # Nagios/Icinga plugin format
check-certs --check --json mail.example.com:587    # JSON
```

**key=value output** — one field per line, parse by key name not position:

```
host=mail.example.com
port=587
proto=smtp
days=12
expiry=Jun 01 2026
expiry_ts=1748736000
ca=Let's Encrypt
status=WARNING
chain=OK
```

| Field | Description |
| ----- | ----------- |
| `host` | Hostname as given |
| `port` | Port checked |
| `proto` | STARTTLS protocol used (`smtp`, `ldap`, …) or `tls` for plain TLS |
| `status` | `OK`, `WARNING`, `CRITICAL`, `URGENT`, `EXPIRED`, or `ERROR` |
| `days` | Days until expiry (negative if already expired) |
| `expiry` | Expiry date, human-readable (`Mon DD YYYY`) |
| `expiry_ts` | Expiry date as a Unix timestamp |
| `ca` | Certificate issuer name |
| `chain` | `OK` or a chain verification error message |

On `ERROR` (unreachable or invalid port), only `host`, `port`, `proto`, `status`, and `reason` are printed.

**Exit codes:**

| Code | Meaning |
| ---- | ------- |
| `0` | OK (certificate valid, chain OK) |
| `1` | WARNING |
| `2` | CRITICAL, URGENT, EXPIRED, or ERROR |
| `3` | UNKNOWN — unreachable host (`--nagios` mode only) |

**Scripting examples:**

```bash
# Branch on exit code
if ! check-certs --check api.example.com; then
    echo "Certificate issue on api.example.com"
fi

# Parse a specific field
days=$(check-certs --check cert.example.com | grep "^days=" | cut -d= -f2)
[ "$days" -lt 14 ] && send_alert "Certificate expiring in ${days}d"

# Compare expiry timestamps across hosts
check-certs --check a.example.com | grep "^expiry_ts="
check-certs --check b.example.com | grep "^expiry_ts="

# Use as a Nagios/Icinga plugin
check-certs --check --nagios monitor.example.com:443

# Feed into a dashboard or log pipeline
check-certs --check --json api.example.com:443
```

---

## Output

Colour-coded table in the terminal, grouped by sections from `servers.conf`:

```
╔══════════════════════════════════╦════════════════════╦════════════════╦════════════════════════╦═════╗
║ Server                           ║ Expiry date        ║ Remaining      ║ Issued by              ║ Ch  ║
╠══════════════════════════════════╬════════════════════╬════════════════╬════════════════════════╬═════╣
╠  LDAP ══════════════════════════════════════════════════════════════════════════════════════════════╣
║ ldap.example.com                 ║ Nov 20 2026        ║ ✓ 185d         ║ R11                    ║ ✓   ║
║ ldap-dev.example.com             ║ -                  ║ ERROR          ║ Unreachable            ║     ║
╠══════════════════════════════════╬════════════════════╬════════════════╬════════════════════════╬═════╣
╠  Web ═══════════════════════════════════════════════════════════════════════════════════════════════╣
║ www.example.com                  ║ Jul 14 2026        ║ ⚠ 28d          ║ GEANT TLS RSA 1        ║ ✓   ║
║ intranet.example.com             ║ Jun 01 2026        ║ ✗ 14d          ║ GEANT TLS RSA 1        ║ ⚠   ║
╚══════════════════════════════════╩════════════════════╩════════════════╩════════════════════════╩═════╝

  Summary:  4 servers checked  │  ✓ 1 OK  │  ⚠ 1 Warning  │  ✗ 2 Critical/Error
```

| Colour | Condition | Meaning |
| ------ | --------- | ------- |
| 🟢 Green | ≥ `WARN_DAYS` remaining | All good |
| 🟡 Yellow | < `WARN_DAYS` remaining | Renew soon |
| 🔴 Red | < `CRIT_DAYS` remaining | Immediate action required |
| 🔴 Red / ERROR | – | Server unreachable |

The **"Issued by"** column shows the CN value from the certificate issuer (e.g. `R11` for Let's Encrypt, `GEANT TLS RSA 1` for GÉANT), falling back to the O value if CN is absent. The **Ch** column shows `✓` when the full certificate chain is valid, or `⚠` when an intermediate CA is missing or invalid. A broken chain promotes an otherwise-OK certificate to CRITICAL — the `chain_status` field in `--check` output carries the reason string.

---

## Background monitoring

Once you have `check-certs.sh` set up, you can add automated background monitoring. All variants use the same `servers.conf` and `check-certs.conf`, notify only when state changes, and escalate through warning → critical → urgent levels with daily reminders for unresolved issues.

- 🍎 **[macOS notifications](docs/macos-notify.md)** – daily launchd job, native macOS notifications with escalation levels
- 📧 **[Email](docs/email.md)** – daily email reports via Postfix, ssmtp, or sendmail (Linux and macOS)
- 🌐 **[Webhook](docs/webhook.md)** – HTTP POST to Slack, ntfy.sh, Teams, Mattermost, or any custom endpoint
- 💬 **[Teams](docs/teams.md)** – full Adaptive Card to a Microsoft Teams channel via Workflow webhook
- 📱 **[Pushover](docs/pushover.md)** – mobile push notifications with emergency acknowledgement for iOS and Android
- 🔔 **[ntfy](docs/ntfy.md)** – push notifications via ntfy.sh or a self-hosted ntfy server
- 🔧 **[Build your own wrapper](docs/wrapper-interface.md)** – full interface reference for custom delivery scripts

---

## Files

```
README.md
README-DE.md
CHANGELOG.md
LICENSE

docs/
├── macos-notify.md        ← macOS notification variant
├── email.md               ← Email variant (Postfix, ssmtp, or sendmail)
├── webhook.md             ← Webhook variant
├── teams.md               ← Microsoft Teams Adaptive Card variant
├── pushover.md            ← Pushover variant
├── ntfy.md                ← ntfy variant
├── wrapper-interface.md   ← Interface reference for building custom wrappers
└── troubleshooting.md     ← Troubleshooting for all platforms

src/
├── check-certs.sh               ← Main script – terminal table + core logic
├── check-certs-notify.sh        ← macOS notification variant
├── check-certs-mail.sh          ← Email variant
├── check-certs-webhook.sh       ← Webhook variant
├── check-certs-teams.sh         ← Teams variant
├── check-certs-pushover.sh      ← Pushover variant
└── check-certs-ntfy.sh          ← ntfy variant

install/
├── install.sh                     ← Unified installer (macOS and Linux)
├── com.check-certs.notify.plist   ← launchd job template (notifications)
├── com.check-certs.mail.plist     ← launchd job template (email)
├── com.check-certs.webhook.plist  ← launchd job template (webhook)
├── com.check-certs.teams.plist    ← launchd job template (Teams)
├── com.check-certs.pushover.plist ← launchd job template (Pushover)
├── com.check-certs.ntfy.plist     ← launchd job template (ntfy)
└── check-certs.logrotate          ← logrotate config (Linux)

config/
├── servers.conf                 ← Example server list
└── check-certs.conf             ← Configuration file (all settings documented)

tests/
└── test_check_certs.sh          ← Unit test suite (no network required)
```

---

## Troubleshooting

| Error | Solution |
| ----- | -------- |
| `check-certs.sh not found` | Script is not in the same directory as the calling wrapper |
| *"Server file not found"* | Check `SERVER_FILE` in `check-certs.conf` or verify `servers.conf` exists |
| *"Unreachable"* | `openssl s_client -connect hostname:port </dev/null` |
| *"Invalid format"* | Separator in `servers.conf` must be `:`, not `,` |
| CA shows "Unknown" | `openssl s_client -connect hostname:port </dev/null 2>/dev/null \| openssl x509 -noout -issuer` |
| Chain always invalid | Usually a missing intermediate CA in the local trust store. Update: `brew install ca-certificates` (macOS) or `apt install ca-certificates` (Linux). Verify with: `openssl s_client -connect hostname:port -servername hostname </dev/null` |
| *"gdate: command not found"* | macOS only: `brew install coreutils` |
| *"Homebrew not found"* | `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` |
| `check-certs` command not found | Run `source ~/.zshrc` (macOS) or `source ~/.bashrc` (Linux) |

For further troubleshooting and variant-specific issues see [docs/troubleshooting.md](docs/troubleshooting.md).

---

## Contributing

Contributions are welcome. Please open an issue before starting work on a larger feature so we can discuss the approach. For bug fixes, a pull request with a clear description of the problem and fix is sufficient.

## Licence

MIT – see [LICENSE](LICENSE) for the full text.
