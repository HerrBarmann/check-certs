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
| Chain always shows invalid | Some servers require SNI – check-certs uses `-servername` by default; verify with `openssl s_client -connect hostname:port -servername hostname </dev/null` |

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

## Linux – Email (Postfix)

| Error | Solution |
| ----- | -------- |
| No email received | Test: `echo "Test" \| mail -s "Test" you@example.com`; check logs: `journalctl -u postfix` |
| Authentication failed | Verify credentials in `/etc/postfix/sasl_passwd`; run `postmap /etc/postfix/sasl_passwd` after editing |
| Same email every day despite state | Check `/var/lib/check-certs/` is writable: `ls -la /var/lib/check-certs/` |
| Cron job not running | `grep CRON /var/log/syslog`; verify path in cron entry |

---

## Linux – Email (ssmtp)

| Error | Solution |
| ----- | -------- |
| No email received | Test: `echo -e "To: you@example.com\nSubject: test\n\ntest" \| ssmtp you@example.com` |
| `Cannot open mail.example.com:587` | Check `mailhub` in `/etc/ssmtp/ssmtp.conf`; verify the port is reachable |
| Authentication failed | Double-check `AuthUser` and `AuthPass`; for Gmail use an App Password |
| Mail arrives with wrong sender | Set `FromLineOverride=YES` in `ssmtp.conf` |
| `ssmtp: command not found` | `apt install ssmtp` |

---

## Webhook

| Error | Solution |
| ----- | -------- |
| `WEBHOOK_URL is not set` | Add `WEBHOOK_URL=https://...` to `check-certs.conf` |
| `curl is required but not installed` | `apt install curl` or `brew install curl` |
| `webhook POST returned HTTP 4xx` | Check the URL and authentication settings in `check-certs.conf` |
| `webhook POST returned HTTP 5xx` | The endpoint is unavailable; check-certs retries once automatically |
| No events received but no errors | All certificates are OK and no state changes occurred – try resetting state |
| Only summary received, no findings | Expected when all certificates are healthy |
| Events received but no alerts in Slack/Teams | Check the payload format – some services require a specific JSON structure; consider a custom wrapper |
