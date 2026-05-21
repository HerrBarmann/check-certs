# check-certs – Linux (Email)

Runs daily via cron job and sends email reports for expiring certificates. A single script, `check-certs-mail.sh`, handles both Postfix and ssmtp – the transport is selected via `MAIL_TRANSPORT` in `check-certs.conf`.

← [Back to overview](../README.md)

---

## Contents

- [Postfix vs ssmtp](#postfix-vs-ssmtp)
- [How it works](#how-it-works)
- [Automatic installation](#automatic-installation)
- [Manual installation](#manual-installation)
  - [Postfix](#postfix)
  - [ssmtp](#ssmtp)
- [Adjustments](#adjustments)
- [Email output](#email-output)

---

## Postfix vs ssmtp

| | Postfix | ssmtp |
| --- | ------- | ----- |
| Setup complexity | More involved – multiple files, service | Minimal – one config file |
| System service | Runs as a daemon | None – stateless binary |
| Suitable for | Servers already running Postfix, complex needs | Simple relay to an external SMTP server |
| Script | `check-certs-mail.sh` | `check-certs-mail.sh` |
| Transport setting | `MAIL_TRANSPORT=postfix` | `MAIL_TRANSPORT=ssmtp` |
| Installer | `install/install-linux.sh` | `install/install-linux.sh` |

---

## How it works

Both variants share the same logic from `check-certs.sh`:

- All servers are checked **in parallel** including full chain verification
- A report is assembled and sent **only when there is something to report**
- **State tracking** under `/var/lib/check-certs/state` ensures you only get emailed when something changes

| Level | Default | Behaviour |
| ----- | ------- | --------- |
| **WARNING** | < 15 days | One-time email; again only on status change |
| **CRITICAL** | < 7 days | Daily reminder email |
| **URGENT** | < 2 days | Daily email + additional email to `MAIL_TO_URGENT` |

`🚨` in the subject line signals URGENT entries, `🔁` signals daily reminders.

---

## Automatic installation

```bash
chmod +x install/install-linux.sh
sudo ./install/install-linux.sh
```

> Root privileges required for package installation and mail transport configuration.

Run the installer and select **1) Postfix email** or **2) ssmtp email** when prompted. It installs the required packages, configures the chosen mail transport, writes `check-certs.conf` with `MAIL_TRANSPORT` set appropriately, copies files to `/opt/check-certs/` and sets up the cron job. It also installs `check-certs.sh` so you can run interactive certificate checks from the terminal at any time.

The installer prompts for:

| Prompt | Description | Example |
| ------ | ----------- | ------- |
| Email recipient | Where warning emails are sent | `admin@example.com` |
| Urgent email recipient | Second recipient for critical alerts | `oncall@example.com` |
| SMTP relay host | Outgoing mail server | `smtp.example.com` |
| SMTP port | Default: 587 | `587` |
| SMTP username | Login name for the mail server | `user@example.com` |
| SMTP password | Password or app password (not echoed) | – |
| Sender address | Displayed sender of warning emails | `certcheck@example.com` |
| Warning threshold (days) | First alert X days before expiry | `15` |
| Critical threshold (days) | Daily reminder from X days | `7` |
| Urgent threshold (days) | Escalation from X days | `2` |
| Cron job time | Daily execution time | `7:00` |

Any external SMTP relay works. If using Gmail, create an **App Password** under Google Account → Security → App Passwords and use that instead of your regular password.

If the mail transport configuration file already exists (`/etc/postfix/main.cf` or `/etc/ssmtp/ssmtp.conf`), the installer will not overwrite it. Add the SMTP relay directives manually if needed – see the manual installation sections below.

---

## Manual installation

Both transports use the same script. Copy the files first, then follow the section for your chosen transport:

```bash
mkdir -p /opt/check-certs /var/lib/check-certs
cp src/check-certs.sh /opt/check-certs/
cp src/check-certs-mail.sh /opt/check-certs/
cp config/servers.conf /opt/check-certs/
chmod +x /opt/check-certs/check-certs.sh /opt/check-certs/check-certs-mail.sh
touch /var/lib/check-certs/state
```

### Postfix

```bash
apt install openssl mailutils postfix libsasl2-modules
```

Add the following to `/etc/postfix/main.cf`, replacing the placeholders with your SMTP relay details:

```
relayhost = [smtp.example.com]:587
smtp_use_tls = yes
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt
smtp_generic_maps = hash:/etc/postfix/generic
```

```bash
# Store SMTP credentials
echo "[smtp.example.com]:587 user@example.com:your-password" > /etc/postfix/sasl_passwd
postmap /etc/postfix/sasl_passwd
chmod 600 /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db
systemctl restart postfix
```

> **Gmail example:** use `smtp.gmail.com` as the relay host, your Gmail address as the username, and an App Password as the password.

> **Note:** The installer writes a minimal `check-certs.conf` with only the keys needed for the chosen variant. For a full reference of all available settings see `config/check-certs.conf` in the repository.

Create `check-certs.conf`:

```bash
cat > /opt/check-certs/check-certs.conf <<'EOF'
WARN_DAYS=15
CRIT_DAYS=7
URGENT_DAYS=2
TIMEOUT=5
MAX_JOBS=10
CA_MAX_LEN=30
STATE_FILE=/var/lib/check-certs/state
MAIL_TRANSPORT=postfix
MAIL_TO=admin@example.com
MAIL_TO_URGENT=admin@example.com
MAIL_FROM=certcheck@server.example.com
EOF
```

Add the cron job:

```bash
crontab -e
```

```
0 7 * * * /opt/check-certs/check-certs-mail.sh
```

### ssmtp

ssmtp is a lightweight send-only mail forwarder – no daemon, no service, just a single config file. Use it if Postfix feels like overkill for your setup.

```bash
apt install openssl ssmtp
```

Edit `/etc/ssmtp/ssmtp.conf`, replacing the placeholders with your SMTP relay details:

```
# Address that mail appears to come from
root=certcheck@example.com

# SMTP relay host and port
mailhub=smtp.example.com:587

# SMTP credentials
AuthUser=user@example.com
AuthPass=your-password

# TLS
UseTLS=YES
UseSTARTTLS=YES

# Server hostname (used in EHLO)
hostname=yourserver.example.com

# Rewrite sender to root address
FromLineOverride=YES
```

```bash
chmod 640 /etc/ssmtp/ssmtp.conf
```

> **Gmail example:** set `mailhub=smtp.gmail.com:587`, `AuthUser=you@gmail.com`, and use an App Password as `AuthPass`.

Test mail delivery before continuing:

```bash
echo -e "To: you@example.com\nFrom: certcheck@example.com\nSubject: ssmtp test\n\nIt works." | ssmtp you@example.com
```

Create `check-certs.conf`:

```bash
cat > /opt/check-certs/check-certs.conf <<'EOF'
WARN_DAYS=15
CRIT_DAYS=7
URGENT_DAYS=2
TIMEOUT=5
MAX_JOBS=10
CA_MAX_LEN=30
STATE_FILE=/var/lib/check-certs/state
MAIL_TRANSPORT=ssmtp
MAIL_TO=admin@example.com
MAIL_TO_URGENT=admin@example.com
MAIL_FROM=certcheck@server.example.com
EOF
```

Add the cron job:

```bash
crontab -e
```

```
0 7 * * * /opt/check-certs/check-certs-mail.sh
```

---

## Adjustments

**Edit settings:** All configuration lives in `check-certs.conf`:

```bash
nano /opt/check-certs/check-certs.conf
```

| Setting | Description |
| ------- | ----------- |
| `MAIL_TRANSPORT` | Mail transport: `postfix` or `ssmtp` |
| `MAIL_TO` | Primary recipient |
| `MAIL_TO_URGENT` | Additional recipient for URGENT alerts |
| `MAIL_FROM` | Sender address |
| `WARN_DAYS` | First warning below this threshold |
| `CRIT_DAYS` | Daily reminder below this threshold |
| `URGENT_DAYS` | Escalation below this threshold |

**Reset state:**

```bash
# Single server
sed -i '/hostname\.example\.com/d' /var/lib/check-certs/state
# All servers
> /var/lib/check-certs/state
```

**Change cron job time:** Open the crontab and update the entry to your preferred time:

```bash
crontab -e
```

```
30 6 * * * /opt/check-certs/check-certs-mail.sh
```

**View syslog entries:**

```bash
journalctl -t check-certs
```

**Set up log rotation (optional):**

The script writes to syslog via `logger` by default. To also capture output in a log file, redirect in the cron job:

```
0 7 * * * /opt/check-certs/check-certs-mail.sh >> /var/log/check-certs/check-certs-mail.log 2>&1
```

Create the directory first, then install the logrotate config:

```bash
sudo mkdir -p /var/log/check-certs
sudo cp install/check-certs.logrotate /etc/logrotate.d/check-certs
```

This rotates logs under `/var/log/check-certs/` weekly, keeps 8 weeks of compressed history and skips rotation if the log is empty.

---

## Email output

Both transports produce the same report format. The subject line reflects the highest severity in the email:

| Subject prefix | Condition |
| -------------- | --------- |
| `🚨 Certificate URGENT` | Any URGENT or EXPIRED finding |
| `⚠ Certificate warning` | WARNING or CRITICAL findings only |
| `🚨 Reminder: Certificate URGENT` | Reminder with URGENT or EXPIRED entry |
| `🔁 Reminder: renew certificates` | Reminder for WARNING or CRITICAL only |

**New findings email:**

```
SSL Certificate Check – New findings (2026-05-18 at 07:00)
Servers checked: 8  |  Non-OK: 3  |  Errors: 1

────────────────────────────────────────────────────────────────────────────────
Server                                  Days    Expiry date           Status / CA
────────────────────────────────────────────────────────────────────────────────
ldap.example.com                        5d      May 23 2026           CRITICAL: 5d remaining | CA: GEANT TLS RSA 1
mail.example.com                        -3d     May 18 2026           EXPIRED (3d overdue) | CA: Let's Encrypt
zks.example.com                         -       -                     ERROR: Unreachable
────────────────────────────────────────────────────────────────────────────────

Known ongoing issues:

────────────────────────────────────────────────────────────────────────────────
Server                                  Days    Expiry date           Status / CA
────────────────────────────────────────────────────────────────────────────────
intranet.example.com                    4d      May 22 2026           CRITICAL: 4d remaining | CA: GEANT TLS RSA 1 | Chain: certificate has expired
────────────────────────────────────────────────────────────────────────────────

Please renew the affected certificates promptly.
```

The **Known ongoing issues** section appears when other servers are already in a non-OK state but not yet due for their daily reminder. It gives the recipient the full picture in every email.

**Columns:**

| Column | Description |
| ------ | ----------- |
| Server | Hostname as listed in `servers.conf` |
| Days | Days remaining (`5d`), or `-` for unreachable hosts |
| Expiry date | Certificate expiry date (`Mon DD YYYY`), or `-` for errors |
| Status / CA | Severity label, days remaining, issuer CN, chain status if broken |

**`Non-OK`** in the summary counts all servers whose current status is not OK, including ones not in this email (e.g. known issues within the reminder window).

---

→ [Troubleshooting](troubleshooting.md)
