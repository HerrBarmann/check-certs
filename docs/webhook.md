# check-certs – Webhook

Posts a JSON payload to a configurable URL for each new finding and daily reminder. Works with any service that accepts HTTP POST – Slack, ntfy.sh, Teams, Mattermost, Grafana Alerting, PagerDuty, or a custom endpoint.

No mail server required. Runs on any platform with `curl`.

← [Back to overview](../README.md)

---

## Contents

- [Installation](#installation)
- [Configuration](#configuration)
- [Payload format](#payload-format)
- [Service examples](#service-examples)
- [Troubleshooting](#troubleshooting)

---

## Installation

### Automatic (macOS and Debian/Ubuntu)

```bash
chmod +x install/install-macos.sh   # macOS
./install/install-macos.sh

chmod +x install/install-linux.sh   # Linux
sudo ./install/install-linux.sh
```

Select **Webhook** when prompted. The installer writes `check-certs.conf`, copies the script and sets up a launchd job (macOS) or cron job (Linux).

### Manual

```bash
# Copy files
mkdir -p /opt/check-certs
cp src/check-certs.sh /opt/check-certs/
cp src/check-certs-webhook.sh /opt/check-certs/
cp config/servers.conf /opt/check-certs/
cp config/check-certs.conf /opt/check-certs/
chmod +x /opt/check-certs/check-certs.sh /opt/check-certs/check-certs-webhook.sh

# Then edit check-certs.conf and set WEBHOOK_URL (it is commented out by default)
nano /opt/check-certs/check-certs.conf

# Create state directory
mkdir -p /var/lib/check-certs
touch /var/lib/check-certs/state
```

Set up the cron job (Linux) or launchd job (macOS – see [docs/macos-notify.md](macos-notify.md) for the launchd template approach):

```bash
crontab -e
```

```
0 7 * * * /opt/check-certs/check-certs-webhook.sh
```

---

## Configuration

All webhook settings go in `check-certs.conf`:

```bash
nano /opt/check-certs/check-certs.conf
```

| Setting | Required | Description |
| ------- | -------- | ----------- |
| `WEBHOOK_URL` | Yes | URL to POST payloads to |
| `WEBHOOK_AUTH_HEADER` | No | Authentication header name (e.g. `Authorization`) |
| `WEBHOOK_AUTH_VALUE` | No | Authentication header value (e.g. `Bearer mytoken`) |
| `WEBHOOK_SEND_SUMMARY` | No | Post a summary event after all checks (default: `true`) |

Threshold and state settings (`WARN_DAYS`, `CRIT_DAYS`, `URGENT_DAYS`, `STATE_FILE` etc.) are shared with the other variants and work identically.

---

## Payload format

Each event is posted as a separate HTTP request with `Content-Type: application/json`.

### Finding or reminder event

Posted once per affected server. `"event"` is `"finding"` for new issues and status changes, `"reminder"` for daily reminders on persistent issues.

```json
{
  "event":       "finding",
  "timestamp":   "2026-05-18T07:00:03Z",
  "hostname":    "ldap.example.com",
  "status":      "CRITICAL",
  "days_left":   5,
  "expiry_date": "May 23 2026",
  "ca":          "GEANT TLS RSA 1",
  "chain":       "OK"
}
```

**Status values:**

| Value | Meaning |
| ----- | ------- |
| `RENEWED` | Was expiring or unreachable, is now valid |
| `WARNING` | Expiring soon (below `WARN_DAYS`) |
| `CRITICAL` | Expiring critically soon, or chain broken |
| `URGENT` | Expiring urgently soon (below `URGENT_DAYS`) |
| `EXPIRED` | Certificate has expired |
| `ERROR` | Server unreachable or invalid port; `ca` field carries the reason |

**Chain values:** `"OK"` or a human-readable reason string such as `"certificate has expired"` or `"unable to get local issuer certificate"`.

### Summary event

Posted once at the end of each run when `WEBHOOK_SEND_SUMMARY=true` (the default).

```json
{
  "event":      "summary",
  "timestamp":  "2026-05-18T07:00:08Z",
  "total":      8,
  "warned":     2,
  "errors":     1,
  "new_issues": 2,
  "reminders":  0
}
```

Set `WEBHOOK_SEND_SUMMARY=false` in `check-certs.conf` to disable it.

---

## Service examples

### Slack incoming webhook

Create an incoming webhook in your Slack app and set the URL:

```bash
WEBHOOK_URL="https://hooks.slack.com/services/YOUR/SLACK/WEBHOOKURL"
```

No authentication header needed – the URL itself is the secret. To format the payload as a Slack message you can proxy it through a small middleware, or use Slack's workflow builder to transform incoming webhooks.

### ntfy.sh

```bash
WEBHOOK_URL="https://ntfy.sh/my-topic"
WEBHOOK_AUTH_HEADER="Authorization"
WEBHOOK_AUTH_VALUE="Bearer <your-ntfy-token>"
```

ntfy.sh accepts arbitrary JSON but displays the raw body. For a nicer message, use ntfy's native API instead and adapt the payload format in a custom wrapper.

### Teams incoming webhook

```bash
WEBHOOK_URL="https://myorg.webhook.office.com/webhookb2/..."
```

Teams expects a specific `{"text": "..."}` format. Use a custom wrapper (see [wrapper-interface.md](wrapper-interface.md)) to shape the payload for Teams.

### Generic endpoint with Bearer token

```bash
WEBHOOK_URL="https://api.example.com/alerts"
WEBHOOK_AUTH_HEADER="Authorization"
WEBHOOK_AUTH_VALUE="Bearer <your-token>"
```

### Custom header authentication

```bash
WEBHOOK_URL="https://api.example.com/alerts"
WEBHOOK_AUTH_HEADER="X-API-Key"
WEBHOOK_AUTH_VALUE="<your-api-key>"
```

---

## Troubleshooting

| Problem | Solution |
| ------- | -------- |
| `WEBHOOK_URL is not set` | Add `WEBHOOK_URL=...` to `check-certs.conf` |
| `curl is required but not installed` | `apt install curl` or `brew install curl` |
| `webhook POST returned HTTP 4xx` | Check URL and authentication settings |
| `webhook POST returned HTTP 5xx` | Endpoint is unavailable; check-certs will retry once |
| No events received | Run manually and check output: `/opt/check-certs/check-certs-webhook.sh` |
| Only summary received, no findings | All certificates are OK and no state changes occurred |

For general certificate checking issues see [troubleshooting.md](troubleshooting.md).

---

→ [Troubleshooting](troubleshooting.md)
