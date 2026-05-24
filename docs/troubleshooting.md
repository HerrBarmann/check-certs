# check-certs – Troubleshooting

← [Back to overview](../README.md)

---

## General

| Error | Solution |
| ----- | -------- |
| `check-certs.sh not found` | Script is not in the same directory as the calling wrapper |
| *"Server file not found"* | Check `SERVER_FILE` in `check-certs.conf`, or verify `servers.conf` exists |
| *"Unreachable"* | `openssl s_client -connect hostname:port </dev/null` |
| *"Invalid format"* | Separator in `servers.conf` must be `:`, not `,` |
| CA shows "Unknown" | `openssl s_client -connect hostname:port </dev/null 2>/dev/null \| openssl x509 -noout -issuer` |
| Chain always shows invalid | Usually a missing intermediate CA in the local trust store. Update: `brew install ca-certificates` (macOS) or `apt install ca-certificates` (Linux). Verify with: `openssl s_client -connect hostname:port -servername hostname </dev/null` |

---

## Per-host threshold overrides

| Issue | Solution |
| ----- | -------- |
| Override not taking effect | Overrides go after the hostname in `servers.conf`, space-separated: `host:443 warn=30 crit=14`. Run `check-certs --list` to confirm they are parsed correctly |
| Invalid override value | Values must be positive integers. Non-integer values are silently discarded and the global threshold is used instead |
| `--list` shows no overrides | Overrides only appear in `--list` output when at least one key=value pair is present on the line |

---

## STARTTLS

| Error | Solution |
| ----- | -------- |
| Port 389 (LDAP) always shows ERROR | Plain LDAP uses STARTTLS — check-certs auto-detects it on port 389. Verify with: `openssl s_client -connect hostname:389 -starttls ldap </dev/null` |
| Port 587 (SMTP) shows ERROR | Port 587 uses STARTTLS smtp — auto-detected. Verify: `openssl s_client -connect hostname:587 -starttls smtp </dev/null` |
| Port 465 shows ERROR | Port 465 is SMTPS (plain TLS, not STARTTLS). Use `:smtps` or `:tls` as the proto field in `servers.conf` |
| STARTTLS not working with explicit proto | Valid proto values: `smtp` `submission` `imap` `pop3` `ldap` `ftp` `xmpp`. Plain TLS aliases: `tls` `https` `ldaps` `imaps` `pop3s` `smtps` `ftps` |

---

## macOS – Terminal

| Error | Solution |
| ----- | -------- |
| *"gdate: command not found"* | `brew install coreutils` |
| *"Homebrew not found"* | `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` |
| `check-certs` command not found | Restart your terminal or run `source ~/.zshrc` |

---

## macOS – Notifications

| Error | Solution |
| ----- | -------- |
| No notifications appear | System Settings → Notifications → terminal-notifier → enable |
| Clicking "Show" opens nothing | Check that `check-certs.sh` is in `~/scripts/check-certs/` and is executable |
| Notifications appear without click action | `brew install terminal-notifier` |
| launchd job not running | `launchctl list \| grep check-certs`; reload with `launchctl load ~/Library/LaunchAgents/com.check-certs.notify.plist` |
| Mac was asleep at run time | launchd does not catch up missed jobs – run manually: `~/scripts/check-certs/check-certs-notify.sh` |

---

## Email

`check-certs-mail.sh` works on Linux and macOS. The transport is selected by
`MAIL_TRANSPORT` in `check-certs.conf`: `postfix`, `ssmtp`, or `sendmail`.

**Common to all transports:**

| Error | Solution |
| ----- | -------- |
| No email received | Check that `MAIL_TO` is set correctly in `check-certs.conf` |
| Same alert every day | State file may be unwritable — check permissions: `ls -la /var/lib/check-certs/` (Linux) or `ls -la "$HOME/Library/Application Support/check-certs/"` (macOS). Or reset with `check-certs --clear-state` |
| Cron/launchd job not running | Linux: `grep CRON /var/log/syslog`. macOS: `launchctl list \| grep check-certs` |
| `MAIL_TO appears to be a placeholder` | Set `MAIL_TO` to a real address in `check-certs.conf` |

**Postfix:**

| Error | Solution |
| ----- | -------- |
| No email received | Test: `echo "Test" \| mail -s "Test" you@example.com`; check logs: `journalctl -u postfix` |
| Authentication failed | Verify credentials in `/etc/postfix/sasl_passwd`; run `postmap /etc/postfix/sasl_passwd` after editing |
| `mail: command not found` | `apt install mailutils` |

**ssmtp:**

| Error | Solution |
| ----- | -------- |
| No email received | Test: `printf "To: you@example.com\nSubject: test\n\ntest\n" \| ssmtp you@example.com` |
| `Cannot open mail.example.com:587` | Check `mailhub` in `/etc/ssmtp/ssmtp.conf` (Linux) or `$(brew --prefix)/etc/ssmtp/ssmtp.conf` (macOS); verify the port is reachable |
| Authentication failed | Double-check `AuthUser` and `AuthPass`; for Gmail use an App Password |
| Mail arrives with wrong sender | Set `FromLineOverride=YES` in `ssmtp.conf` |
| `ssmtp: command not found` | Linux: `apt install ssmtp`. macOS: `brew install ssmtp` |

**sendmail:**

| Error | Solution |
| ----- | -------- |
| `sendmail not found` | Install an MTA that provides a sendmail interface: Linux: `apt install exim4`. macOS: `brew install postfix` |
| Mail rejected by relay | Your local MTA must be configured to relay through a smarthost. Check `/etc/exim4/` or Postfix `main.cf` |
| Wrong sender address | The `-f` flag sets the envelope sender — ensure `MAIL_FROM` matches an address your MTA allows |

---

## Webhook

| Error | Solution |
| ----- | -------- |
| `WEBHOOK_URL is not set` | Add `WEBHOOK_URL=https://...` to `check-certs.conf` |
| `curl is required but not installed` | `apt install curl` or `brew install curl` |
| HTTP 4xx response | Check the URL and any authentication settings in `check-certs.conf` |
| HTTP 5xx response | The endpoint is unavailable; check-certs retries once automatically |
| No events received but no errors | All certificates are OK and no state changes occurred – run `check-certs --clear-state` then try again |
| Payload arrives but Slack shows nothing | Slack incoming webhooks expect `{"text":"..."}` — use a Power Automate Workflow or ntfy for richer formatting |

---

## Teams

| Error | Solution |
| ----- | -------- |
| `TEAMS_WEBHOOK_URL is not set` | Add `TEAMS_WEBHOOK_URL=https://...` to `check-certs.conf` |
| `curl is required but not installed` | `apt install curl` or `brew install curl` |
| Nothing arrives in Teams | State file may have recorded all issues as already notified. Run `check-certs --clear-state` then try again |
| HTTP 400 from the workflow URL | Use `TEAMS_DEBUG=true ./check-certs-teams.sh` to inspect the payload. Ensure the Workflow was created with the "Post to a channel when a webhook request is received" template |
| `BadSyntax: unsupported card element` | The card uses only `TextBlock` and `ColumnSet` elements (Adaptive Card v1.2). Check that the Workflow has not been customised to expect a different schema |
| Workflow stopped posting | The workflow owner's account may have been deactivated. Assign a co-owner in Power Automate at `make.powerautomate.com` |
| Card arrives but shows no servers | The card only shows non-OK servers. If all servers are currently OK the card body will be empty — the summary line confirms total counts |
| Card arrives but no groups shown | Groups are suppressed when all their servers are OK |

---

## Pushover

| Error | Solution |
| ----- | -------- |
| `PUSHOVER_APP_TOKEN is not set` | Add `PUSHOVER_APP_TOKEN=...` to `check-certs.conf`. Create a token at [pushover.net/apps](https://pushover.net/apps) |
| `PUSHOVER_USER_KEY is not set` | Add `PUSHOVER_USER_KEY=...` to `check-certs.conf`. Find your key on your Pushover dashboard |
| `PUSHOVER_RETRY must be at least 30 seconds` | Set `PUSHOVER_RETRY=300` (or any value ≥ 30) in `check-certs.conf` |
| `curl is required but not installed` | `apt install curl` or `brew install curl` |
| HTTP 4xx from Pushover API | Verify `PUSHOVER_APP_TOKEN` and `PUSHOVER_USER_KEY` are correct |
| Emergency notifications not retrying | `PUSHOVER_RETRY` must be ≥ 30 and `PUSHOVER_EXPIRE` ≤ 10800. Acknowledgement must be done in the Pushover app |
| Notifications arrive on all devices | Set `PUSHOVER_DEVICE="device-name"` in `check-certs.conf` to limit to one device |
| No notifications despite issues | State file may have already recorded the issues. Run `check-certs --clear-state` then try again |
