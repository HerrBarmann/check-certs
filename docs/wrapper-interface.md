# Wrapper Interface Reference

`check-certs.sh` doubles as a library. Source it from another script and it
exposes certificate checking, state management, and escalation logic without
producing any output or running any checks. The terminal table UI only
activates when the script is executed directly.

← [Back to overview](../README.md)

---

## Contents

- [How a wrapper works](#how-a-wrapper-works)
- [Lifecycle](#lifecycle)
- [Configuration](#configuration)
- [Setup functions](#setup-functions)
- [Hooks](#hooks)
  - [Delivery hooks](#delivery-hooks) — you define these
  - [Event hooks](#event-hooks) — you override these
- [Escalation rules](#escalation-rules)
- [Counters](#counters)
- [State API](#state-api)
- [Complete example](#complete-example)

---

## How a wrapper works

A wrapper is a shell script that:

1. Sources `check-certs.sh` to load the library
2. Defines two **delivery hooks** — functions the library calls when it wants
   to notify you about a certificate issue
3. Calls `run_server_loop` to perform all certificate checks

The library handles scheduling logic (new issue vs. known issue vs. daily
reminder), state persistence, parallel execution, and TLS checking. The
wrapper only decides what to do with the results.

---

## Lifecycle

Every wrapper must follow this sequence:

```
1.  source check-certs.sh          Load the library. No side effects.
2.  configure_wrapper              Load check-certs.conf, apply defaults,
                                   reset counters.
3.  state_init                     Create the state file and its directory
                                   if absent. No-op if STATE_FILE is empty.
4.  define deliver_finding()       Required. Called for new issues.
5.  define deliver_reminder()      Required. Called for daily reminders.
6.  define on_group() et al.       Optional. Override event hooks if needed.
7.  install_escalation_hooks       Wire the event hooks to the escalation
                                   logic. Must come after steps 4–6.
8.  run_server_loop "$SERVER_FILE" Run all checks. Blocks until complete.
9.  read $new_issues / $reminders  Act on results.
```

Deviating from this order causes undefined behaviour.

---

## Configuration

These variables control the library's behaviour. They are read by
`configure_wrapper`, which applies them in this priority order:

```
highest  Values set in your wrapper after configure_wrapper
         Values set in check-certs.conf
         Values set in your wrapper before configure_wrapper
lowest   Built-in defaults
```

To guarantee a value in your wrapper wins over `check-certs.conf`, set it
**after** `configure_wrapper` using the `${VAR:=default}` form, which sets
the variable only if it is not already set:

```bash
configure_wrapper
: "${STATE_FILE:=/var/lib/my-wrapper/state-mywrapper}"   # wins over check-certs.conf
```

**Available variables:**

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `SERVER_FILE` | `./servers.conf` | Path to the server list |
| `STATE_FILE` | *(variant default)* | Path to the state file. Each built-in variant defaults to its own named file (e.g. `state-mail`). Empty string disables state tracking entirely |
| `WARN_DAYS` | `15` | Days remaining below which `WARNING` is triggered |
| `CRIT_DAYS` | `7` | Days remaining below which `CRITICAL` is triggered |
| `URGENT_DAYS` | `2` | Days remaining below which `URGENT` is triggered. `0` disables the URGENT level |
| `TIMEOUT` | `5` | TLS connection timeout in seconds per host |
| `MAX_JOBS` | `10` | Maximum parallel certificate checks |
| `CA_MAX_LEN` | `30` | Maximum display length of the CA name column |

---

## Setup functions

### `configure_wrapper`

```
configure_wrapper
```

Loads `check-certs.conf` from the same directory as `check-certs.sh`, fills
in any unset variables from built-in defaults, and resets all counters to
zero. Must be the first call after sourcing the library.

---

### `state_init`

```
state_init
```

Creates `$STATE_FILE` and its parent directory if they do not already exist.
No-op when `STATE_FILE` is empty (state tracking disabled). Call after
`configure_wrapper`.

---

### `install_escalation_hooks`

```
install_escalation_hooks
```

Replaces the default `on_cert_result`, `on_cert_error`, and `on_format_error`
event hooks with wrappers that apply the escalation rules and call
`deliver_finding` or `deliver_reminder` as appropriate.

Call this **after** defining your delivery hooks and any event hook overrides,
and **before** `run_server_loop`.

After this call, the pre-wired escalation functions are available as
`_escalation_on_cert_result` and `_escalation_on_cert_error` if you need to
call through to them from a custom event hook.

---

### `run_server_loop`

```
run_server_loop "$SERVER_FILE"
```

Reads the server list, checks each certificate in parallel (up to `$MAX_JOBS`
at a time), and invokes the appropriate hook for each result. Blocks until all
checks are complete, then returns. Read `$new_issues`, `$reminders`, and
`$errors` after it returns.

Each entry in the server list may include an optional protocol field:
`hostname:port` or `hostname:port:proto`. STARTTLS is auto-detected on
standard ports when no proto is specified.

STARTTLS protocols: `smtp` `submission` `imap` `pop3` `ldap` `ftp` `xmpp`

Plain TLS aliases (self-documenting, bypass auto-detection): `tls` `https` `ldaps` `imaps` `pop3s` `smtps` `ftps`

---

## Hooks

Hooks are shell functions. The library calls them at specific points during
execution. There are two kinds:

- **Delivery hooks** — you must define these. They are called when the
  escalation logic decides a notification is warranted.
- **Event hooks** — the library defines defaults. Override them when you need
  to act on every certificate result, not just notifiable ones.

---

### Delivery hooks

Define these two functions before calling `install_escalation_hooks`. They are
invoked by the escalation logic, not directly by `run_server_loop`. Both
receive the same parameter signature.

**Signature:**

```bash
deliver_finding  hostname status days_left short_date ca_name chain_status
deliver_reminder hostname status days_left short_date ca_name chain_status
```

**Parameters:**

| # | Name | Type | Description |
|---|------|------|-------------|
| 1 | `hostname` | string | Server hostname as listed in `servers.conf` |
| 2 | `status` | string | One of the values defined in [Escalation rules](#escalation-rules) |
| 3 | `days_left` | integer | Days until expiry. `-` for unreachable hosts |
| 4 | `short_date` | string | Expiry date formatted `Mon DD YYYY`. `-` for unreachable hosts |
| 5 | `ca_name` | string | Issuer CN/O name, or the error reason for `ERROR` status |
| 6 | `chain_status` | string | `OK`, or a description of the chain verification failure |

---

#### `deliver_finding`

Called when a **new issue** is detected (status changed or first occurrence),
or when a previously failing certificate has been **renewed**.

---

#### `deliver_reminder`

Called for a **known, unresolved issue** that has persisted long enough to
warrant a repeat notification. Only triggered after at least 23 hours have
elapsed since the last notification, and only for `CRITICAL`, `URGENT`,
`EXPIRED`, and `ERROR` — see [Escalation rules](#escalation-rules) for the
full table.

---

### Event hooks

These functions are called by `run_server_loop` for every certificate result,
including results that do not warrant a notification. The library installs
no-op defaults before `install_escalation_hooks` is called, and escalation
wrappers after.

Override them when you need to act on events the delivery hooks don't cover —
for example, to log every server on every run regardless of state.

**Pattern — override after `install_escalation_hooks` and call through:**

```bash
install_escalation_hooks

on_cert_result() {
    local hostname="$1" status="$6"
    # Your unconditional logic here
    [ "$status" = "OK" ] && log_cert "$hostname" "OK"
    # Then call through to escalation
    _escalation_on_cert_result "$@"
}

on_cert_error() {
    local hostname="$1" port="$2" reason="$3"
    log_cert "$hostname" "$port" "ERROR" "($reason)"
    _escalation_on_cert_error "$@"
}
```

---

#### `on_cert_result`

```
on_cert_result hostname port days_left short_date ca_name status prev_status hours_since chain_status
```

Called for every certificate that was successfully checked, regardless of
status. Invoked before the escalation logic makes its decision.

| # | Name | Type | Description |
|---|------|------|-------------|
| 1 | `hostname` | string | Server hostname |
| 2 | `port` | integer | Port checked |
| 3 | `days_left` | integer | Days until expiry |
| 4 | `short_date` | string | Expiry date (`Mon DD YYYY`) |
| 5 | `ca_name` | string | Issuer name |
| 6 | `status` | string | Current status |
| 7 | `prev_status` | string | Status recorded in state from the previous run. Empty on first run |
| 8 | `hours_since` | integer | Hours elapsed since the last `deliver_finding` or `deliver_reminder` call for this host |
| 9 | `chain_status` | string | `OK` or a chain failure description |

---

#### `on_cert_error`

```
on_cert_error hostname port reason prev_status hours_since
```

Called for every host that could not be reached or had an invalid port,
regardless of whether it is a new error or a known one.

| # | Name | Type | Description |
|---|------|------|-------------|
| 1 | `hostname` | string | Server hostname |
| 2 | `port` | integer | Port that was checked |
| 3 | `reason` | string | `Unreachable` or `Invalid port` |
| 4 | `prev_status` | string | Status from the previous run. Empty on first run |
| 5 | `hours_since` | integer | Hours elapsed since the last notification for this host |

---

#### `on_group`

```
on_group group_name
```

Called when a `[Group Name]` section header is encountered in `servers.conf`,
before the servers in that group are checked. Default: no-op. Not replaced by
`install_escalation_hooks`.

| # | Name | Type | Description |
|---|------|------|-------------|
| 1 | `group_name` | string | Group name as written in `servers.conf`, without brackets |

---

#### `on_format_error`

```
on_format_error line
```

Called when a line in `servers.conf` cannot be parsed. Default before
`install_escalation_hooks`: no-op. After: logs the bad line to stderr and
increments `$errors`.

| # | Name | Type | Description |
|---|------|------|-------------|
| 1 | `line` | string | The raw unparseable line |

---

## Escalation rules

The escalation logic determines which hook to call and when, based on the
current certificate status and what was recorded in the state file from the
previous run.

| Status | Condition | `deliver_finding` | `deliver_reminder` |
| ------ | --------- | :---: | :---: |
| `OK` | Certificate valid, chain intact | – | – |
| `RENEWED` | Was non-OK last run, now valid | ✓ once | – |
| `WARNING` | `days_left < WARN_DAYS` | ✓ on first occurrence or status change | – |
| `CRITICAL` | `days_left < CRIT_DAYS`, or chain broken with valid leaf | ✓ on status change | ✓ every 23 h |
| `URGENT` | `days_left < URGENT_DAYS` | ✓ on status change | ✓ every 23 h |
| `EXPIRED` | `days_left < 0` | ✓ on status change | ✓ every 23 h |
| `ERROR` | Host unreachable or invalid port | ✓ on first occurrence | ✓ every 23 h |

**Status change** means the current status is more severe than the previous
run's status (e.g. `WARNING` → `CRITICAL`). Escalation always fires on a
status change regardless of the time elapsed since the last notification.

> **`WARNING` does not trigger reminders.** A daily WARNING reminder would
> fire continuously until the certificate is renewed or escalates, which is
> noise at the WARNING threshold. To make WARNING repeat, set `CRIT_DAYS`
> equal to `WARN_DAYS` so the certificate immediately enters `CRITICAL` and
> receives daily reminders from there.

---

## Counters

Set to zero by `configure_wrapper`. Updated by `run_server_loop`. Read after
`run_server_loop` returns.

| Variable | Description |
| -------- | ----------- |
| `$total` | Total number of servers checked |
| `$errors` | Servers that were unreachable or had a parse error |
| `$warned` | Servers whose current status is non-OK |
| `$new_issues` | Number of `deliver_finding` calls made this run |
| `$reminders` | Number of `deliver_reminder` calls made this run |

---

## State API

State is stored in a plain-text key=value file (`$STATE_FILE`). Use these
functions rather than reading or writing the file directly.

```bash
value=$(state_get "key")     # Returns empty string if key is absent
state_set    "key" "value"   # Create or update a key
state_delete "key"           # Remove a key
```

**Keys written by the escalation logic:**

| Key pattern | Example value | Description |
| ----------- | ------------- | ----------- |
| `status:hostname` | `CRIT` | Last known status abbreviation |
| `days:hostname` | `5` | Days remaining at last check |
| `last_notify:hostname` | `1747564801` | Unix timestamp of the last `deliver_finding` or `deliver_reminder` call |

**Status abbreviations used in state:** `OK`, `WARN`, `CRIT`, `URGENT`,
`EXPIRED`, `ERROR_CONNECT`, `ERROR_PORT`.

Note that `URGENT` and `EXPIRED` are stored as distinct values. A
certificate transitioning from `URGENT` to `EXPIRED` triggers a new
`deliver_finding` call rather than being treated as a known issue.

You may add your own keys to the same state file. Use a prefix that does not
start with `status:`, `days:`, or `last_notify:` to avoid conflicts.

---

## Complete example

A minimal wrapper that POSTs certificate findings and reminders to a webhook,
logs every server on every run, and exits non-zero when issues exist.

```bash
#!/bin/bash
# my-wrapper.sh

CORE="$(dirname "$0")/check-certs.sh"
[ -f "$CORE" ] || { echo "Error: check-certs.sh not found" >&2; exit 1; }

# 1. Load the library
source "$CORE"

# 2. Configure – set STATE_FILE after configure_wrapper so it wins over
#    any value in check-certs.conf
configure_wrapper
: "${STATE_FILE:=/var/lib/my-wrapper/state-mywrapper}"
state_init

# 3. Internal helpers
WEBHOOK_URL="https://hooks.example.com/alerts"
LOG="/var/log/my-wrapper.log"

_log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

_post() {
    local type="$1" hostname="$2" status="$3" days_left="$4"
    curl -s -X POST "$WEBHOOK_URL" \
         -H "Content-Type: application/json" \
         -d "{\"type\":\"${type}\",\"host\":\"${hostname}\",\"status\":\"${status}\",\"days\":${days_left}}"
}

# 4. Define delivery hooks
deliver_finding() {
    local hostname="$1" status="$2" days_left="$3"
    _post "finding" "$hostname" "$status" "$days_left"
}

deliver_reminder() {
    local hostname="$1" status="$2" days_left="$3"
    _post "reminder" "$hostname" "$status" "$days_left"
}

# 5. Wire escalation, then override event hooks to add unconditional logging
install_escalation_hooks

on_cert_result() {
    local hostname="$1" days_left="$3" status="$6"
    _log "$hostname  ${days_left}d  $status"
    _escalation_on_cert_result "$@"
}

on_cert_error() {
    local hostname="$1" port="$2" reason="$3"
    _log "$hostname:$port  -  ERROR  ($reason)"
    _escalation_on_cert_error "$@"
}

# 6. Run
run_server_loop "$SERVER_FILE"

_log "Done: ${total} checked, ${new_issues} new, ${reminders} reminders, ${errors} errors"
[ $((new_issues + reminders)) -gt 0 ] && exit 1 || exit 0
```

---

→ [Troubleshooting](troubleshooting.md)
