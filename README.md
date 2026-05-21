# check-certs

You know that sinking feeling when a user calls to say your site is showing a scary browser warning? Or when your LDAP authentication silently dies at 3am because a certificate quietly expired while you were busy with other things – like sleeping?

check-certs is a certificate monitoring tool that watches expiry dates across all your servers and alerts you well before anything breaks. It checks in parallel, verifies the full certificate chain (not just the leaf), understands STARTTLS protocols like SMTP, IMAP and LDAP, and tracks state between runs so you only hear about something when it actually changes. Alerts go wherever you want them: a colour-coded terminal table for a quick glance, native macOS notifications, email, an HTTP webhook, or Pushover mobile push with emergency-priority acknowledgement for the ones that really can't wait.

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
- [Output](#output)
- [How it works](#how-it-works)
- [Adjusting thresholds](#adjusting-thresholds)
- [Background monitoring](#background-monitoring)
- [Files](#files)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [Licence](#licence)

---

## Overview

check-certs consists of `check-certs.sh` and the automation variants built on top of it.

**`check-certs.sh`** is the main script – a colour-coded terminal table that works on both macOS and Linux. It also contains the shared core logic that all automation variants build on. Start here. Both installers always include it.

Three optional automation variants extend it with background monitoring:

| Variant | Script | Platform | Details |
| ------- | ------ | -------- | ------- |
| **Notification** | `check-certs-notify.sh` | macOS | Native notifications via launchd → [docs/macos-notify.md](docs/macos-notify.md) |
| **Email** | `check-certs-mail.sh` | Debian/Ubuntu | Email via Postfix, ssmtp, or sendmail, selected by `MAIL_TRANSPORT` → [docs/linux-email.md](docs/linux-email.md) |
| **Webhook** | `check-certs-webhook.sh` | Any | HTTP POST to Slack, ntfy, Teams, custom endpoints → [docs/webhook.md](docs/webhook.md) |
| **Pushover** | `check-certs-pushover.sh` | Any | Mobile push with priority levels and emergency acknowledgement → [docs/pushover.md](docs/pushover.md) |

**Key features:**

- Checks all servers **in parallel** for speed, results displayed in original `servers.conf` order
- Verifies the **full certificate chain**, not just the leaf certificate – a broken intermediate CA is caught and reported
- **State tracking** ensures you only get notified when something changes, not on every daily run
- **Escalation levels** with distinct behaviour at warning, critical and urgent thresholds

---

## Installation

### macOS

**Requires:** Homebrew (`coreutils` and `openssl` are installed automatically).

**Automatic** – installs `check-certs.sh`, sets up the alias, and optionally configures a notification, webhook, or Pushover variant via launchd:

```bash
chmod +x install/install-macos.sh && ./install/install-macos.sh
```

**Manual** – terminal table only:

```bash
brew install coreutils openssl
mkdir -p ~/scripts/check-certs
cp src/check-certs.sh src/servers.conf config/check-certs.conf ~/scripts/check-certs/
chmod +x ~/scripts/check-certs/check-certs.sh
echo 'alias check-certs="$HOME/scripts/check-certs/check-certs.sh"' >> ~/.zshrc
source ~/.zshrc
```

To add background monitoring after a manual install see [docs/macos-notify.md](docs/macos-notify.md), [docs/webhook.md](docs/webhook.md), or [docs/pushover.md](docs/pushover.md).

### Linux

GNU `date` is available natively — no Homebrew or `coreutils` needed.

**Automatic** (Debian/Ubuntu) – installs `check-certs.sh` and optionally configures a Postfix, ssmtp, sendmail, webhook, or Pushover variant via cron:

```bash
chmod +x install/install-linux.sh && sudo ./install/install-linux.sh
```

**Manual** – terminal table only:

```bash
apt install openssl        # Debian/Ubuntu
# or: dnf install openssl  # Fedora/RHEL

mkdir -p ~/scripts/check-certs
cp src/check-certs.sh config/servers.conf config/check-certs.conf ~/scripts/check-certs/
chmod +x ~/scripts/check-certs/check-certs.sh
echo 'alias check-certs="$HOME/scripts/check-certs/check-certs.sh"' >> ~/.bashrc
source ~/.bashrc
```

To add background monitoring after a manual install see [docs/linux-email.md](docs/linux-email.md), [docs/webhook.md](docs/webhook.md), or [docs/pushover.md](docs/pushover.md).

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

STARTTLS is automatically applied on standard ports. Use the optional `:proto`
field to override detection or to force plain TLS on a non-standard port.

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
| `MAIL_TRANSPORT` | `postfix` | Email transport: `postfix`, `ssmtp`, or `sendmail` (email variant) |
| `MAIL_TO` | – | Primary email recipient (email variant) |
| `MAIL_TO_URGENT` | – | Second recipient for urgent alerts (email variant) |
| `MAIL_FROM` | – | Sender address (email variant) |
| `WEBHOOK_URL` | – | URL to POST findings to (webhook variant) |

> An existing `check-certs.conf` is **never overwritten** during reinstallation.

---

## Usage

```bash
check-certs                          # Check all servers from servers.conf
check-certs <hostname>               # Check a single server (port defaults to 443)
check-certs <hostname>:<port>        # Check a single server on a specific port
check-certs <hostname>:<port>:<proto> # Check with explicit STARTTLS protocol
check-certs <hostname> <port>        # Same as above, port as a second argument
check-certs --list                   # List all servers without running checks
check-certs --version                # Show version
check-certs --help                   # Show help
```

---

## Output

Colour-coded table in the terminal, grouped by sections from `servers.conf`:

```
╔══════════════════════════════════╦════════════════════╦════════════════╦════════════════════════╗
║ Server                           ║ Expiry date        ║ Remaining      ║ Issued by              ║
╠══════════════════════════════════╬════════════════════╬════════════════╬════════════════════════╣
╠  LDAP ══════════════════════════════════════════════════════════════════════════════════════════╣
║ ldap.example.com                 ║ Nov 20 2026        ║ ✓ 185d         ║ R11                    ║
║ ldap-dev.example.com             ║ -                  ║ ERROR          ║ Unreachable            ║
╠══════════════════════════════════╬════════════════════╬════════════════╬════════════════════════╣
╠  Web ═══════════════════════════════════════════════════════════════════════════════════════════╣
║ www.example.com                  ║ Jul 14 2026        ║ ⚠ 28d          ║ GEANT TLS RSA 1        ║
║ intranet.example.com             ║ Jun 01 2026        ║ ✗ 14d          ║ GEANT TLS RSA 1 ⚠chain ║
╚══════════════════════════════════╩════════════════════╩════════════════╩════════════════════════╝

  Summary:  4 servers checked  │  ✓ 1 OK  │  ⚠ 1 Warning  │  ✗ 2 Critical/Error
```

| Colour | Condition | Meaning |
| ------ | --------- | ------- |
| 🟢 Green | ≥ `WARN_DAYS` remaining | All good |
| 🟡 Yellow | < `WARN_DAYS` remaining | Renew soon |
| 🔴 Red | < `CRIT_DAYS` remaining | Immediate action required |
| 🔴 Red / ERROR | – | Server unreachable |

The **"Issued by"** column shows the CN value from the certificate issuer (e.g. `R11` for Let's Encrypt, `GEANT TLS RSA 1` for GÉANT), falling back to the O value if CN is absent. A `⚠chain` suffix indicates a broken certificate chain even if the leaf certificate itself is still valid.

---

## How it works

All servers are checked in parallel (up to 10 concurrent connections by default), then results are displayed in the original `servers.conf` order. Each check makes two `openssl` connections: one to fetch the leaf certificate's expiry date and issuer, and one to verify the full certificate chain with `-verify_return_error`. A broken chain (e.g. an expired or missing intermediate CA) raises the status to at least CRITICAL regardless of how many days the leaf certificate has left.

The concurrency limit (`MAX_JOBS` in `check-certs.conf`) prevents resource spikes on large server lists. Reduce it if running on a constrained host, increase it if you have many servers and want faster results.

---

## Adjusting thresholds

Edit `check-certs.conf` in the installation directory:

```bash
nano ~/scripts/check-certs/check-certs.conf
```

```bash
WARN_DAYS=15    # Yellow below this number of remaining days
CRIT_DAYS=7     # Red below this threshold
URGENT_DAYS=2   # 0 disables the urgent level
```

---

## Background monitoring

Once you have `check-certs.sh` set up, you can add automated background monitoring:

- 🍎 **[macOS notifications](docs/macos-notify.md)** – daily launchd job, native macOS notifications with escalation levels
- 🖥️ **[Linux email](docs/linux-email.md)** – daily cron job, email reports via Postfix, ssmtp, or sendmail
- 🌐 **[Webhook](docs/webhook.md)** – HTTP POST to Slack, ntfy.sh, Teams, Mattermost, or any custom endpoint
- 📱 **[Pushover](docs/pushover.md)** – mobile push notifications with emergency acknowledgement for iOS and Android
- 🔧 **[Build your own wrapper](docs/wrapper-interface.md)** – full interface reference for custom delivery scripts

---

## Files

```
README.md
LICENSE
.gitignore

docs/
├── macos-notify.md        ← macOS notification variant
├── linux-email.md         ← Linux email variant (Postfix or ssmtp via MAIL_TRANSPORT)
├── webhook.md             ← Webhook variant
├── pushover.md            ← Pushover variant
├── wrapper-interface.md   ← Interface reference for building custom wrappers
└── troubleshooting.md     ← Troubleshooting for all platforms

src/
├── check-certs.sh               ← Main script – terminal table + core logic
├── check-certs-notify.sh        ← macOS notification variant
├── check-certs-mail.sh          ← Linux email variant (Postfix or ssmtp)
├── check-certs-webhook.sh       ← Webhook variant (HTTP POST, any platform)
└── check-certs-pushover.sh      ← Pushover variant (mobile push, any platform)

install/
├── install-macos.sh             ← Installer for macOS
├── install-linux.sh             ← Installer for Debian/Ubuntu
├── com.check-certs.notify.plist ← launchd job template (notifications)
├── com.check-certs.webhook.plist  ← launchd job template (webhook)
├── com.check-certs.pushover.plist ← launchd job template (Pushover)
└── check-certs.logrotate        ← logrotate config for the email variant

config/
├── servers.conf                 ← Example server list
└── check-certs.conf             ← Configuration file (all settings)
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
| Chain always shows invalid | Verify SNI: `openssl s_client -connect hostname:port -servername hostname </dev/null` |
| *"gdate: command not found"* | macOS only: `brew install coreutils` |
| *"Homebrew not found"* | `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` |
| `check-certs` command not found | Run `source ~/.zshrc` (macOS) or `source ~/.bashrc` (Linux) |

For notification, email and webhook specific errors see [docs/troubleshooting.md](docs/troubleshooting.md).

---

## Contributing

Contributions are welcome. Please open an issue before starting work on a larger feature so we can discuss the approach. For bug fixes, a pull request with a clear description of the problem and fix is sufficient.

## Licence

MIT – see [LICENSE](LICENSE) for the full text.
