# check-certs – Troubleshooting

← [Back to overview](../README.md)

---

## Contents

- [General](#general)
- [Installation](#installation)
- [servers.conf and configuration](#serversconf-and-configuration)
- [STARTTLS](#starttls)
- [State and notifications](#state-and-notifications)
- [--check and scripting](#--check-and-scripting)
- [macOS – Terminal](#macos--terminal)
- [macOS – Notifications](#macos--notifications)
- [Email](#email)
- [Webhook](#webhook)
- [Microsoft Teams](#microsoft-teams)
- [Pushover](#pushover)
- [ntfy](#ntfy)

---

## General

| Error | Solution |
| ----- | -------- |
| `check-certs.sh not found` | The script is not in the same directory as the calling wrapper. Each wrapper expects `check-certs.sh` to sit beside it. |
| *"Server file not found"* | Check `SERVER_FILE` in `check-certs.conf`, or verify `servers.conf` exists at the expected path. |
| *"Unreachable"* | The host or port is not responding. Test manually: `openssl s_client -connect hostname:port </dev/null` |
| *"Invalid format"* | A line in `servers.conf` could not be parsed. The separator must be `:`, not `,` or space. Run `check-certs --list` to see which line is flagged. |
| CA shows "Unknown" | The certificate issuer has no CN or O field. Inspect it: `openssl s_client -connect hostname:port </dev/null 2>/dev/null \| openssl x509 -noout -issuer` |
| Chain always shows invalid | Usually a missing intermediate CA in the local trust store. Update: `brew install ca-certificates` (macOS) or `apt install ca-certificates` (Linux). Verify: `openssl s_client -connect hostname:port -servername hostname </dev/null` |
| All hosts show ERROR | `TIMEOUT` may be too low. Try `TIMEOUT=15` in `check-certs.conf`, or test a host manually with openssl. |
| Table output is misaligned | `CA_MAX_LEN` in `check-certs.conf` is set higher than the table was designed for, or a CA name exceeds it. The default of 22 fits an 80-column terminal. Increase `CA_MAX_LEN` and the table will widen to match. |

---

## Installation

| Error | Solution |
| ----- | -------- |
| *"Homebrew not found"* | Install Homebrew: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` |
| *"gdate: command not found"* | macOS only — install coreutils: `brew install coreutils` |
| `check-certs` command not found after install | On macOS the installer creates a symlink at `/usr/local/bin/check-certs` — verify it exists: `ls -la /usr/local/bin/check-certs`. On Linux, run `source ~/.bashrc` or open a new terminal to pick up the alias. |
| Installer says "must be run as root" | The installer writes to `/usr/local/lib/` and `/usr/local/bin/` and requires root on both macOS and Linux. Run `sudo ./install/install.sh`. |
| Re-running the installer overwrote my settings | `servers.conf` is never overwritten. `check-certs.conf` is backed up to `check-certs.conf.bak` before being overwritten — your old settings are in that file. |
| State directory is missing after install | The installer creates state directories with `mkdir -p`. If they are absent, run `state_init` by executing any automation variant once, or create them manually: `mkdir -p /var/lib/check-certs/state-mail` etc. |

---

## servers.conf and configuration

| Error | Solution |
| ----- | -------- |
| Per-host override not taking effect | Overrides go after the hostspec on the same line, space-separated: `host:443 warn=30 crit=14`. Run `check-certs --list` to confirm they are parsed. Non-integer values are silently discarded. |
| `--list` shows no overrides | Overrides only appear in `--list` when at least one `key=value` pair is present on the entry line. |
| IPv6 host not being checked | Use bracket notation: `[2001:db8::1]:443` or `[::1]:636:ldaps`. A bare IPv6 address without brackets will not parse. |
| Group header treated as a host | Group names must be in square brackets on their own line: `[My Group]`. A line that looks like `[hostname:443]` will be skipped as a group header — remove the brackets. |
| `check-certs.conf` setting not taking effect | Settings in `check-certs.conf` are loaded by `configure_wrapper` when a wrapper script starts. Changes take effect on the next run. The terminal script (`check-certs.sh`) also reads `check-certs.conf` from its own directory. |
| Running multiple variants simultaneously | Each variant uses its own state directory (`state-mail/`, `state-webhook/`, etc.) by default. Multiple variants can run at the same time without interfering. |

---

## STARTTLS

| Error | Solution |
| ----- | -------- |
| Port 389 (LDAP) shows ERROR | Port 389 uses STARTTLS. Verify: `openssl s_client -connect hostname:389 -starttls ldap </dev/null` |
| Port 587 (Submission) shows ERROR | Port 587 uses STARTTLS smtp. Verify: `openssl s_client -connect hostname:587 -starttls smtp </dev/null` |
| Port 465 shows ERROR | Port 465 is SMTPS — plain TLS, no STARTTLS. Use `hostname:465:smtps` or `hostname:465:tls`. |
| Port 993 shows ERROR | Port 993 is IMAPS — plain TLS. If you see STARTTLS errors, try `hostname:993:imaps`. |
| STARTTLS with custom port not working | Auto-detection only covers standard ports. Add the protocol explicitly: `hostname:10025:smtp`. |
| Unknown proto value | Valid STARTTLS protocols: `smtp` `submission` `imap` `pop3` `ldap` `ftp` `xmpp`. Plain TLS aliases: `tls` `https` `ldaps` `imaps` `pop3s` `smtps` `ftps`. |
| Connection hangs without timing out | `TIMEOUT` defaults to 5 seconds. Increase it per-host: `slow.example.com:443 timeout=15`, or globally in `check-certs.conf`. |

---

## State and notifications

Understanding how state works prevents most "why did I get/not get a notification" questions.

State is stored as small per-host files in a directory (e.g. `/var/lib/check-certs/state-mail/`). Each file holds the last known status, days remaining, and timestamp of the last notification for that host.

**Notification rules:**
- A notification fires when the status *changes* (OK → WARNING, WARNING → CRITICAL, etc.)
- Daily reminders fire for CRITICAL, URGENT, and EXPIRED hosts — but not for WARNING (to avoid 15 days of daily reminders)
- No notification fires if the status has not changed and the 23-hour reminder window has not elapsed

| Symptom | Cause | Solution |
| ------- | ----- | -------- |
| No notification on first run | Everything is OK — no findings to report | Check the terminal table: `check-certs` |
| No notification after a cert went bad | State already records the issue from a previous run | The next status *change* (e.g. WARNING → CRITICAL) will trigger a new notification. Or reset state: `check-certs --clear-state` |
| Notification every day for the same issue | This is correct for CRITICAL/URGENT/EXPIRED (daily reminders). For WARNING it should not happen — check the state file for that host. |
| Getting notifications for already-renewed certs | State records the old status. On the next run, the tool detects the renewal (status went back to OK) and sends a RENEWED notification, then goes silent. |
| Want to force a fresh notification for everything | `check-certs --clear-state` removes all per-host state files. The next run treats every host as new. |
| Want to clear state for one specific variant | `check-certs --clear-state --state-dir /var/lib/check-certs/state-mail` |
| State files are not being written | Check write permissions: `ls -la /var/lib/check-certs/` (Linux) or `ls -la "$HOME/Library/Application Support/check-certs/"` (macOS). The running user must own the state directory. |
| Upgrading from 2.4.x: state not carrying over | State is automatically migrated on first run. If the old flat file is present at `STATE_FILE`, it is converted to the per-host directory layout and backed up as `*.pre-2.5.bak`. |

---

## --check and scripting

| Problem | Solution |
| ------- | -------- |
| `--check` exits 0 even for a WARNING cert | Exit code 1 = WARNING, 0 = OK. A WARNING cert correctly exits 1. Check `echo $?` immediately after the command — the exit code is overwritten by the next command. |
| `--check --json` returns all fields as `"OK"` | This happens on macOS with the system Bash (3.2). It was caused by a `declare -A` (associative array) in an older version. Update to 2.5.6 or later which uses `_worker_field` instead. |
| `--check` with no args shows an error about SERVER_FILE | `check-certs --check` with no arguments checks all hosts in `servers.conf`. `SERVER_FILE` must point to a valid `servers.conf`. Set it in `check-certs.conf` or run from the directory containing `servers.conf`. |
| `--check --nagios` produces no output | In server-list mode (no hostspec), `--nagios` emits one line per host. If all hosts are OK the output is several `OK - ...` lines and exit 0. Redirect stderr too: `check-certs --check --nagios 2>&1`. |
| Batch mode (`--check host1 host2`) only checks the first host | Ensure no quotes group the arguments: `check-certs --check "host1 host2"` passes one argument. Use `check-certs --check host1 host2` (unquoted, space-separated). |
| JSON output is a single object, expected an array | A single hostspec always produces a JSON object `{}`. Multiple hostspecs or no hostspec (all servers) produce a JSON array `[]`. |
| `--scan` is slow | `--scan` probes 11 ports sequentially, each waiting up to `TIMEOUT` seconds. On a host with many closed ports this can take up to 11 × `TIMEOUT` seconds. Reduce `TIMEOUT` in `check-certs.conf` for faster scans. |
| `--scan` finds no ports | The host may require a hostname for SNI — `--scan` uses the hostname as-is. Bare IP addresses may not work with some servers. Also check firewall rules. |
| `expiry_ts` value looks wrong | `expiry_ts` is a Unix timestamp in seconds (e.g. `1782384567` = June 2026). Verify: `date -d @1782384567` (Linux) or `date -r 1782384567` (macOS). |

---

## macOS – Terminal

| Error | Solution |
| ----- | -------- |
| *"gdate: command not found"* | `brew install coreutils` |
| *"Homebrew not found"* | `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` |
| `check-certs` command not found | Verify the symlink exists: `ls -la /usr/local/bin/check-certs`. If missing, re-run the installer or create it manually: `sudo ln -s /usr/local/lib/check-certs/check-certs.sh /usr/local/bin/check-certs` |
| Output has broken box-drawing characters | Your terminal does not support UTF-8. Set `LANG=en_US.UTF-8` or switch to a terminal that does (Terminal.app, iTerm2). |
| Date parsing fails with "Could not parse expiry date" | If openssl outputs a date in an unexpected format, `gdate` can't parse it. Ensure `gdate` is from a recent version of coreutils: `brew upgrade coreutils`. |

---

## macOS – Notifications

| Error | Solution |
| ----- | -------- |
| No notifications appear | System Settings → Notifications → terminal-notifier → enable. If `terminal-notifier` is not listed, run the script once from the terminal to trigger a permission prompt. |
| `terminal-notifier: command not found` | `brew install terminal-notifier` |
| Notifications appear but clicking "Show" opens nothing | Verify `check-certs.sh` is at `/usr/local/lib/check-certs/check-certs.sh` and is executable: `chmod +x /usr/local/lib/check-certs/check-certs.sh` |
| launchd job not running on schedule | `launchctl list \| grep check-certs` — if the job is absent, reload it: `launchctl load ~/Library/LaunchAgents/com.check-certs.notify.plist` |
| launchd job loaded but never fires | Check the log file for errors: `cat ~/Library/Logs/check-certs/check-certs-notify.log`. A common cause is the script path in the plist being wrong after moving files. |
| Mac was asleep at the scheduled run time | launchd does not catch up missed jobs. Run manually: `/usr/local/lib/check-certs/check-certs-notify.sh` |
| Notifications stopped after macOS upgrade | Re-grant notification permission: System Settings → Notifications → terminal-notifier → allow. |

---

## Email

`check-certs-mail.sh` works on Linux and macOS. The transport (`MAIL_TRANSPORT`) must be set in `check-certs.conf`: `postfix`, `ssmtp`, or `sendmail`.

**Common to all transports:**

| Error | Solution |
| ----- | -------- |
| No email received | Verify `MAIL_TO` is set correctly in `check-certs.conf`. Check the log file for delivery errors. |
| Same alert every day | State may be unwritable. Check permissions: `ls -la /var/lib/check-certs/` (Linux) or `ls -la "$HOME/Library/Application Support/check-certs/"` (macOS). Fix with `chown -R $(whoami) /var/lib/check-certs/` or equivalent. Or reset: `check-certs --clear-state`. |
| Alert received once, then silence | This is correct — check-certs only notifies on status changes. A CRITICAL cert that stays CRITICAL only sends daily reminders (CRITICAL threshold), not a notification on every run. |
| Cron/launchd job not running | Linux: `grep cron /var/log/syslog \| grep check-certs`. macOS: `launchctl list \| grep check-certs`. Check log file for errors. |
| `MAIL_TO appears to be a placeholder` | Set `MAIL_TO` to a real email address in `check-certs.conf`. |
| HTML entities in email (`&amp;` etc.) | Your MTA is modifying the body. The email is sent as plain text — check `Content-Type` headers and MTA rewriting rules. |

**Postfix:**

| Error | Solution |
| ----- | -------- |
| No email received | Test delivery: `echo "Test" \| mail -s "Test" you@example.com`. Check logs: `journalctl -u postfix` or `tail -f /var/log/mail.log`. |
| Authentication failed | Verify credentials in `/etc/postfix/sasl_passwd`. After editing, run `postmap /etc/postfix/sasl_passwd` and `systemctl restart postfix`. |
| `mail: command not found` | `apt install mailutils` |
| Mail sent but not received | Check spam folders. Verify SPF/DKIM records if sending from a custom domain. |

**ssmtp:**

| Error | Solution |
| ----- | -------- |
| No email received | Test: `printf "To: you@example.com\nSubject: test\n\ntest\n" \| ssmtp you@example.com` |
| `Cannot open mail.example.com:587` | Check `mailhub` in `/etc/ssmtp/ssmtp.conf` (Linux) or `$(brew --prefix)/etc/ssmtp/ssmtp.conf` (macOS). Verify the port is reachable: `nc -zv mail.example.com 587`. |
| Authentication failed | Double-check `AuthUser` and `AuthPass`. For Gmail use an App Password, not your account password. |
| Mail arrives with wrong sender | Set `FromLineOverride=YES` in `ssmtp.conf`. |
| `ssmtp: command not found` | Linux: `apt install ssmtp`. macOS: `brew install ssmtp`. |

**sendmail:**

| Error | Solution |
| ----- | -------- |
| `sendmail: command not found` | Install an MTA that provides a sendmail interface. Linux: `apt install exim4`. macOS: `brew install postfix`. |
| Mail rejected by relay | Your local MTA must be configured to relay through a smarthost. Check `/etc/exim4/` or Postfix `main.cf`. |
| Wrong sender address | `MAIL_FROM` in `check-certs.conf` sets the `-f` envelope sender — ensure it matches an address your MTA allows. |

---

## Webhook

| Error | Solution |
| ----- | -------- |
| `WEBHOOK_URL is not set` | Add `WEBHOOK_URL=https://...` to `check-certs.conf`. |
| `curl is required but not installed` | `apt install curl` or `brew install curl`. |
| HTTP 4xx response | Check the URL and any authentication headers in `check-certs.conf`. 401 = bad credentials, 404 = wrong URL, 403 = wrong method or content type. |
| HTTP 5xx response | The endpoint is unavailable. check-certs retries once automatically. Check the endpoint's own logs. |
| No events received, no errors in log | All certificates are OK and no state has changed. Run `check-certs --clear-state` then trigger the script manually to force a notification. |
| Payload arrives but Slack shows nothing | Slack incoming webhooks expect `{"text":"..."}`. The webhook variant sends a structured JSON payload — use a Slack Workflow or the Teams variant instead for rich formatting. |
| Self-signed certificate on webhook endpoint | If your endpoint uses a self-signed cert, curl will refuse the connection. Add `WEBHOOK_CURL_OPTS="-k"` to `check-certs.conf` (insecure, use only for internal endpoints). |

---

## Microsoft Teams

| Error | Solution |
| ----- | -------- |
| `TEAMS_WEBHOOK_URL is not set` | Add `TEAMS_WEBHOOK_URL=https://...` to `check-certs.conf`. |
| `curl is required but not installed` | `apt install curl` or `brew install curl`. |
| Nothing arrives in Teams | State may have already recorded all issues. Run `check-certs --clear-state` then trigger manually. |
| HTTP 400 from the workflow URL | Use `TEAMS_DEBUG=true ./check-certs-teams.sh` to inspect the payload. Ensure the Workflow was created with the "Post to a channel when a webhook request is received" template. |
| `BadSyntax: unsupported card element` | The card uses Adaptive Card v1.2 elements only (`TextBlock`, `ColumnSet`). Check that the Workflow has not been customised to expect a different schema. |
| Workflow stopped posting | The workflow owner's account may have been deactivated. Assign a co-owner in Power Automate at `make.powerautomate.com`. |
| Card arrives but body is empty | The card only shows non-OK servers. If all servers are currently OK the card body will be empty — the summary line at the top confirms total counts. |
| Old-style "Incoming Webhook" connector stopped working | Microsoft retired legacy Office 365 connectors. Migrate to a Power Automate Workflow webhook — see [docs/teams.md](teams.md). |

---

## Pushover

| Error | Solution |
| ----- | -------- |
| `PUSHOVER_APP_TOKEN is not set` | Add `PUSHOVER_APP_TOKEN=...` to `check-certs.conf`. Create a token at [pushover.net/apps](https://pushover.net/apps). |
| `PUSHOVER_USER_KEY is not set` | Add `PUSHOVER_USER_KEY=...` to `check-certs.conf`. Find your key on your Pushover dashboard. |
| `PUSHOVER_RETRY must be at least 30 seconds` | Set `PUSHOVER_RETRY=300` (or any value ≥ 30) in `check-certs.conf`. |
| `curl is required but not installed` | `apt install curl` or `brew install curl`. |
| HTTP 4xx from Pushover API | Verify `PUSHOVER_APP_TOKEN` and `PUSHOVER_USER_KEY` are correct at [pushover.net](https://pushover.net). |
| Emergency notifications not retrying | `PUSHOVER_RETRY` must be ≥ 30 and `PUSHOVER_EXPIRE` ≤ 10800. Acknowledgement must be done in the Pushover app within the expiry window. |
| Notifications arrive on all devices | Set `PUSHOVER_DEVICE="device-name"` in `check-certs.conf` to target one device. Find device names in the Pushover app settings. |
| No notifications despite visible issues | State already recorded the issues. Run `check-certs --clear-state` then trigger manually. |

---

## ntfy

| Error | Solution |
| ----- | -------- |
| `NTFY_URL is not set` | Add `NTFY_URL="https://ntfy.sh"` (or your server URL) to `check-certs.conf`. |
| `NTFY_TOPIC is not set` | Add `NTFY_TOPIC="your-topic-name"` to `check-certs.conf`. |
| `curl is required but not installed` | `apt install curl` or `brew install curl`. |
| Notifications not arriving | Test the connection manually: `curl -d "test" https://ntfy.sh/your-topic`. Check the log file for HTTP errors. |
| HTTP 401 / 403 from ntfy server | Your topic requires authentication. Set `NTFY_TOKEN="..."` (preferred) or `NTFY_USER` and `NTFY_PASS` in `check-certs.conf`. |
| Notifications arrive but with no title or wrong priority | Verify the ntfy app on your device is subscribed to the correct topic and server. Priority 4–5 notifications may need "Do Not Disturb" permissions on the device. |
| Self-hosted ntfy server not reachable | Test: `curl -d "test" https://your-ntfy-server/your-topic`. If using a self-signed certificate, add `-k` to the curl call in `check-certs-ntfy.sh` (insecure, internal use only). |
| No notifications despite issues | State already recorded them. Run `check-certs --clear-state --state-dir /var/lib/check-certs/state-ntfy` then trigger manually. |
| Reminder notifications flooding the device | Reminders only fire for CRITICAL, URGENT, and EXPIRED — once every 23 hours. For WARNING there are no reminders by design. If flooding occurs, check whether multiple instances of the script are running. |
