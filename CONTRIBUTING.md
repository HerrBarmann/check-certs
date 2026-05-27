# Contributing to check-certs

This document is the authoritative reference for anyone developing check-certs — whether you are a human contributor picking up an issue, an AI agent continuing a session, or someone building a new automation variant. It covers the full architecture, every design decision that matters, known constraints, and the rules for contributing safely.

---

## Contents

- [Project overview](#project-overview)
- [Repository layout](#repository-layout)
- [Core architecture](#core-architecture)
  - [Script structure and BASH_SOURCE guard](#script-structure-and-bash_source-guard)
  - [Data flow](#data-flow)
  - [The worker output format](#the-worker-output-format)
  - [Two-phase execution in run_server_loop](#two-phase-execution-in-run_server_loop)
  - [State engine](#state-engine)
  - [Escalation logic](#escalation-logic)
- [Function reference](#function-reference)
- [Automation variants](#automation-variants)
  - [How a wrapper is structured](#how-a-wrapper-is-structured)
  - [Delivery hooks](#delivery-hooks)
  - [Event hooks](#event-hooks)
  - [Building a new variant](#building-a-new-variant)
- [The installer](#the-installer)
- [Testing](#testing)
- [Platform constraints](#platform-constraints)
- [Design rules](#design-rules)
- [Known bugs and limitations](#known-bugs-and-limitations)
- [Changelog summary](#changelog-summary)
- [Contribution workflow](#contribution-workflow)

---

## Project overview

check-certs is a shell-based SSL/TLS certificate monitoring tool for sysadmins. It checks the expiry dates and certificate chains of servers listed in `servers.conf`, runs checks in parallel, and notifies through whichever channel the sysadmin wants — terminal table, email, webhook, Teams, Pushover, or ntfy.

**Core values that must not be violated:**

- **No runtime dependencies beyond `openssl` and optionally `curl`**. No Python, no Node, no external packages. This is a deliberate design choice. The tool runs on any Linux box and any macOS machine without an install step beyond the shell scripts themselves.
- **`bash`, not `sh`**. The shebang is `#!/bin/bash` and the code uses bash features (`[[ ]]`, arrays, `${var##pattern}`, etc.). However, **no Bash 4+ features** — macOS ships Bash 3.2 and that must keep working. Specifically: no `declare -A` (associative arrays), no `mapfile`/`readarray`, no `wait -n` without a fallback.
- **Single script = single source of truth**. There is one main library file. Wrappers source it. Nothing is duplicated across files. If you find the same logic in two places, that is a bug.

---

## Repository layout

```
README.md                ← User-facing documentation (English)
README-DE.md             ← User-facing documentation (German)
CHANGELOG.md             ← Version history
CONTRIBUTING.md          ← This file
LICENSE                  ← MIT, copyright HerrBarmann

src/
  check-certs.sh              ← Main script: library + terminal UI
  check-certs-mail.sh         ← Email wrapper
  check-certs-notify.sh       ← macOS native notifications wrapper
  check-certs-webhook.sh      ← HTTP webhook wrapper
  check-certs-teams.sh        ← Microsoft Teams wrapper
  check-certs-pushover.sh     ← Pushover mobile push wrapper
  check-certs-ntfy.sh         ← ntfy push notifications wrapper

config/
  servers.conf                ← Example server list (shipped, never auto-modified)
  check-certs.conf            ← Full configuration reference with all settings

install/
  install.sh                  ← Unified interactive installer (macOS + Linux)
  com.check-certs.*.plist     ← launchd job templates for each macOS variant
  check-certs.logrotate       ← logrotate config for Linux

docs/
  wrapper-interface.md        ← Full wrapper API reference
  email.md                    ← Email variant setup
  macos-notify.md             ← macOS notifications setup
  webhook.md                  ← Webhook setup
  teams.md                    ← Teams setup
  pushover.md                 ← Pushover setup
  ntfy.md                     ← ntfy setup
  troubleshooting.md          ← Common problems

tests/
  test_check_certs.sh         ← Unit test suite (119 tests, no network required)
```

---

## Core architecture

### Script structure and BASH_SOURCE guard

`check-certs.sh` is both a standalone executable and a sourced library. The distinction is controlled by a guard near line 814:

```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Terminal UI, command dispatch, --check, --scan, --list, --version, --help
    ...
fi  # end BASH_SOURCE guard
```

**When executed directly** (`./check-certs.sh`): the guard is true and the full terminal section runs — argument parsing, table rendering, and the terminal run loop.

**When sourced by a wrapper** (`source check-certs.sh`): the guard is false and the terminal section is completely skipped. Only the library functions are loaded. No output, no checks, no side effects.

**Everything before the guard** is the library:
- Configuration defaults (`_CC_DEFAULTS_*`) and `configure_wrapper`
- State functions (`state_init`, `state_get`, `state_set`, `state_delete`, `state_migrate`)
- Certificate checking functions (`parse_hostspec`, `_starttls_proto`, `_check_cert_worker`, `_worker_field`)
- Loop and dispatch (`run_server_loop`, `_dispatch_result`)
- Escalation (`_escalation_on_cert_result`, `_escalation_on_cert_error`, `install_escalation_hooks`)
- Utility helpers (`_repeat`, `_json_escape`)
- Table rendering helpers (`hline`, `print_group`, `print_error_row`)
- Terminal hooks (`on_cert_result`, `on_cert_error`, `on_format_error`, `on_group`)

Note: the table rendering helpers and terminal hooks are defined at library level even though they are only called when the script runs directly. This keeps all reusable function definitions together above the guard. The one exception is `_ch_print_record` and `_ch_exit_code` — these are `--check` helpers defined inside the terminal section because they are only ever called from the `--check` command block.

**Everything inside the guard** is the terminal section:
- Config loading and terminal-specific defaults
- `--version`, `--help`, `--list`, `--clear-state`, `--scan`
- `--check` command block (including `_ch_print_record` and `_ch_exit_code` helpers)
  - no args → checks all servers in `SERVER_FILE`
  - one arg → single-host mode
  - multiple args → batch mode (hosts checked in parallel, one record per host)
- The terminal table run (at the very end of the guard)

---

### Data flow

The complete data flow for a `run_server_loop` call:

```
servers.conf
    │
    ▼
run_server_loop (phase 1: parallel)
    │
    ├─► _check_cert_worker (background, one per host)
    │       │
    │       ├── openssl s_client → leaf cert enddate + issuer
    │       ├── openssl s_client -verify → chain status
    │       ├── extract_ca → CA name string
    │       ├── compute days_left, status (OK/WARNING/CRITICAL/URGENT/EXPIRED)
    │       ├── promote OK → CRITICAL if chain broken
    │       └── writes TYPE=RESULT|ERROR + fields to tmpdir/$idx
    │
    └─► run_server_loop (phase 2: in-order replay)
            │
            └─► _dispatch_result (one per host)
                    │
                    ├── reads host state from STATE_FILE directory
                    ├── computes hours_since last notification
                    └─► on_cert_result / on_cert_error (hook)
                                │
                                ├── terminal: prints table row
                                └── wrapper: _escalation_on_cert_result
                                                │
                                                ├── deliver_finding (new issue)
                                                └── deliver_reminder (daily repeat)
```

The two-phase design is critical: **phase 1 runs all workers concurrently; phase 2 replays results in original file order**. This gives parallel speed while preserving the user's grouping and ordering from `servers.conf`.

---

### The worker output format

`_check_cert_worker` writes a small key=value file to a temp path. This is the internal data interchange format between the worker and all consumers.

**RESULT record:**

```
TYPE=RESULT
HOST=mail.example.com
PORT=587
PROTO=smtp
DAYS=12
EXPIRY=Jun 01 2026
EXPIRY_TS=1748736000
CA=Let's Encrypt
STATUS=WARNING
CHAIN=OK
```

**ERROR record:**

```
TYPE=ERROR
HOST=ldap.example.com
PORT=636
PROTO=
REASON=Unreachable
```

**Rules:**
- `PROTO` is the STARTTLS protocol string (`smtp`, `imap`, etc.) or empty for plain TLS. Consumers normalise empty to `"tls"` for display.
- `STATUS` is the full verdict including chain: a chain-broken cert that would otherwise be OK has `STATUS=CRITICAL`. `CHAIN` carries the human-readable reason string for consumers that need it.
- Values may contain `=` signs (e.g. CA names from `O=Let's Encrypt, CN=R10`). Always read with `cut -d= -f2-` or `grep "^KEY=" | cut -d= -f2-`. Never split on `=` naively.
- Use `_worker_field "$file" KEY` to read a single field. Do not use `declare -A` — it requires Bash 4+ and macOS ships Bash 3.2.

---

### Two-phase execution in run_server_loop

Phase 1 builds two parallel arrays: `order[]` (a sequence of `GROUP:name`, `HOST:idx`, or `FORMAT_ERROR:line` tags in file order) and `pids[]` (background worker PIDs). Workers write to `$tmpdir/$idx`.

The semaphore that limits concurrency to `MAX_JOBS`:
```bash
if [ "$running" -ge "${MAX_JOBS:-10}" ]; then
    if wait -n 2>/dev/null; then :             # Bash 4.3+: wait for any child
    else wait "${pids[$(( idx - running ))]}" 2>/dev/null || true  # Bash 3.2 fallback
    fi
    running=$((running - 1))
fi
```

`pids[idx - running]` is the oldest outstanding PID. At the point of the check, `idx` is the count of dispatched hosts (the next index to assign), and `running == MAX_JOBS`. So the oldest unwaited PID is at `pids[idx - MAX_JOBS]` = `pids[idx - running]`. This is correct.

Phase 2 iterates `order[]` and calls `_dispatch_result "$tmpdir/$value"` for each `HOST:idx` entry, which ensures results appear in `servers.conf` order regardless of which workers finished first.

---

### State engine

`STATE_FILE` is a **directory path**, not a file. Each monitored host gets its own small key=value file inside the directory. The filename is the hostname with non-safe characters replaced by underscores.

Example directory layout for `STATE_FILE=/var/lib/check-certs/state-mail`:

```
/var/lib/check-certs/state-mail/
    mail.example.com          ← status=CRIT\ndays=5\nlast_notify=1748000000
    ldap.example.com          ← status=OK
    __1                       ← IPv6 [::1] sanitised (brackets stripped by parse_hostspec, colons → underscores)
```

**State key format:** `field:hostname` — e.g. `status:mail.example.com`. The field name is everything before the first colon; the hostname is everything after. `_state_file()` derives the filename from the hostname portion.

**Fields written by the escalation logic:**
- `status:hostname` — abbreviated status: `OK`, `WARN`, `CRIT`, `URGENT`, `EXPIRED`, `ERROR_CONNECT`, `ERROR_PORT`
- `days:hostname` — integer days remaining at last check
- `last_notify:hostname` — Unix timestamp of the last `deliver_finding` or `deliver_reminder` call

**Abbreviation mismatch warning:** `STATUS` in worker output uses full names (`CRITICAL`, `WARNING`). State uses abbreviated names (`CRIT`, `WARN`). The escalation logic translates when writing state. Wrappers that read `prev_status` from `_escalation_on_cert_result` arg 7 receive the abbreviated stored value.

**Migration:** `state_init` automatically calls `state_migrate`, which detects a 2.4.x flat state file at the `STATE_FILE` path and upgrades it to the per-host directory layout. The original is backed up as `$STATE_FILE.pre-2.5.bak`. Migration is idempotent.

---

### Escalation logic

The escalation functions decide whether a result warrants a notification. They are the core of what makes check-certs useful rather than noisy.

**`_escalation_on_cert_result` rules:**

| Current status | Previous state | Action |
|---|---|---|
| `OK` | Was non-OK | `deliver_finding` with status `RENEWED`, clear `last_notify` |
| `OK` | Was OK (or absent) | Silent |
| `WARNING` | Not `WARN` | `deliver_finding`, store `WARN` |
| `WARNING` | `WARN` | Silent (no daily reminders for WARNING by design) |
| `CRITICAL` | Not `CRIT` | `deliver_finding`, store `CRIT` |
| `CRITICAL` | `CRIT` + ≥23 h since last notify | `deliver_reminder` |
| `URGENT` | Not `URGENT` | `deliver_finding`, store `URGENT` |
| `URGENT` | `URGENT` + ≥23 h | `deliver_reminder` |
| `EXPIRED` | Not `EXPIRED` | `deliver_finding`, store `EXPIRED` |
| `EXPIRED` | `EXPIRED` + ≥23 h | `deliver_reminder` |

**Why WARNING has no daily reminder:** At 15 days out, a daily reminder would fire every day for two weeks. The sysadmin would disable the tool. CRITICAL (≤7 days) is when daily reminders begin. To make WARNING repeat, set `CRIT_DAYS=WARN_DAYS` in `check-certs.conf`.

**`_escalation_on_cert_error` rules:**
- `Invalid port`: fires `deliver_finding` once, stores `ERROR_PORT`, never repeats (port config errors don't change on their own).
- `Unreachable`: fires `deliver_finding` on first occurrence, `deliver_reminder` every 23 hours thereafter.

---

## Function reference

All functions defined in `check-certs.sh` in order of definition:

| Function | Scope | Description |
|---|---|---|
| `configure_wrapper` | Library | Load `check-certs.conf`, apply defaults, reset counters. Must be first call after sourcing. |
| `_state_file key` | Library (private) | Returns the filesystem path for a host's state file. Handles hostname sanitisation. |
| `state_init` | Library | Creates `$STATE_FILE` directory; runs `state_migrate` if a flat file is detected. |
| `state_get key` | Library | Returns stored value or empty string. No-op if `STATE_FILE` is empty. |
| `state_set key value` | Library | Creates or updates a field in the host's state file. No-op if `STATE_FILE` is empty. |
| `state_delete key` | Library | Removes a field; leaves the host file in place. |
| `state_migrate` | Library (private) | One-way upgrade from 2.4.x flat file to per-host directory layout. Called by `state_init`. |
| `extract_ca issuer_string` | Library | Extracts CA display name from openssl issuer string (CN preferred, O fallback). Truncates to `CA_MAX_LEN`. |
| `parse_hostspec spec h_var p_var pr_var` | Library | Parses `hostname:port[:proto]` or `[IPv6]:port[:proto]`. Returns 0 on success, 1 on failure. Sets named variables. |
| `_starttls_proto port proto` | Library (private) | Returns the STARTTLS protocol string for a port/proto combination, or empty for plain TLS. |
| `_check_cert_worker host port outfile proto [warn crit urgent timeout]` | Library (private) | Runs in background. Checks one host, writes TYPE=RESULT or TYPE=ERROR record to `outfile`. |
| `_worker_field file KEY` | Library (private) | Reads a single field from a worker output file. Safe with values containing `=`. |
| `_dispatch_result outfile` | Library (private) | Reads worker file, looks up state, calls `on_cert_result` or `on_cert_error`. Increments `$total`. |
| `run_server_loop file` | Library | Main entry point for wrappers. Runs all checks and invokes hooks. |
| `_escalation_on_cert_error hostname port reason prev_status hours_since [ts]` | Library (private) | Escalation logic for error results. |
| `_escalation_on_cert_result hostname port days date ca status prev hours chain [ts]` | Library (private) | Escalation logic for certificate results. |
| `install_escalation_hooks` | Library | Wires `on_cert_result`, `on_cert_error`, `on_format_error` to escalation. Call after defining delivery hooks. |
| `_repeat char n` | Library (utility) | Prints a character N times without forking. Used by table rendering. |
| `_json_escape string` | Library (utility) | Escapes backslashes and double-quotes for JSON string values. |
| `hline left mid right` | Library (table) | Prints one horizontal rule using `COL1`–`COL5` widths. |
| `print_group name` | Library (table) | Prints a group banner spanning the full table width. |
| `print_error_row hostname reason` | Library (table) | Prints one ERROR row in the terminal table. |
| `on_group name` | Library (terminal hook) | Default terminal: prints group banner, draws mid-rule between groups. |
| `on_cert_error hostname port reason ...` | Library (terminal hook) | Default terminal: calls `print_error_row`. |
| `on_format_error line` | Library (terminal hook) | Default terminal: prints format error row. |
| `on_cert_result hostname port days date ca status ... chain ...` | Library (terminal hook) | Default terminal: prints one data row with colour and chain column. |
| `_ch_print_record tmpfile mode` | Terminal (`--check`) | Prints one worker result record in kv, nagios, or json format. Defined inside the terminal section; not available when the script is sourced. |
| `_ch_exit_code status` | Terminal (`--check`) | Maps a STATUS string to an exit code integer (0/1/2). Defined inside the terminal section; not available when sourced. |

**Counters** (reset by `configure_wrapper`, updated during `run_server_loop`):

| Variable | Description |
|---|---|
| `$total` | Total hosts checked |
| `$errors` | Unreachable hosts or format errors |
| `$warned` | Hosts with non-OK status |
| `$new_issues` | `deliver_finding` calls this run |
| `$reminders` | `deliver_reminder` calls this run |
| `$ok` / `$warn` / `$crit` | Terminal table counters (not used by wrappers) |

---

## Automation variants

### How a wrapper is structured

Every wrapper follows the same skeleton:

```bash
#!/bin/bash

CORE="$(dirname "$0")/check-certs.sh"
[ -f "$CORE" ] || { echo "Error: check-certs.sh not found" >&2; exit 1; }

source "$CORE"           # 1. Load library

configure_wrapper        # 2. Load config, apply defaults

# 3. Override STATE_FILE after configure_wrapper so it wins over check-certs.conf
: "${STATE_FILE:=/var/lib/check-certs/state-mywrapper}"
state_init               # 4. Create state directory, migrate if needed

# 5. Define delivery hooks (required)
deliver_finding()  { ... }
deliver_reminder() { ... }

# 6. Install escalation (connects hooks to logic)
install_escalation_hooks

# 7. Optional: override on_cert_result to log every host
on_cert_result() {
    log_line "$1" "$6"              # e.g. log every host
    _escalation_on_cert_result "$@" # call through to escalation
}

run_server_loop "$SERVER_FILE"  # 8. Run all checks

# 9. Act on results
[ $((new_issues + reminders)) -gt 0 ] && exit 1 || exit 0
```

---

### Delivery hooks

Both hooks receive the same signature:

```
deliver_finding  hostname status days_left short_date ca_name chain_status
deliver_reminder hostname status days_left short_date ca_name chain_status
```

| Arg | Type | Description |
|---|---|---|
| 1 `hostname` | string | As listed in `servers.conf` |
| 2 `status` | string | `RENEWED`, `WARNING`, `CRITICAL`, `URGENT`, `EXPIRED`, `ERROR` |
| 3 `days_left` | integer or `-` | Days until expiry; `-` for ERROR |
| 4 `short_date` | string | `Mon DD YYYY` or `-` for ERROR |
| 5 `ca_name` | string | Issuer display name, or error reason for ERROR |
| 6 `chain_status` | string | `OK` or chain failure description |

`deliver_finding` is called for new issues (status change) and for RENEWED certificates. `deliver_reminder` is called for persistent known issues after ≥23 hours.

---

### Event hooks

These are called for every result, not just notifiable ones. Override them **after** `install_escalation_hooks` and call through to `_escalation_on_cert_result` / `_escalation_on_cert_error` to preserve escalation behaviour.

> **Important:** before `install_escalation_hooks` is called, `on_cert_result`, `on_cert_error`, and `on_format_error` are bound to the terminal table printing functions. A wrapper that calls `run_server_loop` without first calling `install_escalation_hooks` will get terminal table rows written to stdout — not silence. Always call `install_escalation_hooks` before `run_server_loop`.

`on_cert_result hostname port days_left short_date ca_name status prev_status hours_since chain_status current_ts`

`on_cert_error hostname port reason prev_status hours_since current_ts`

`on_group group_name` — called when a `[Group]` section header is encountered. Not affected by `install_escalation_hooks`.

`on_format_error line` — called for unparseable lines. After `install_escalation_hooks`, calls `deliver_finding` with status ERROR.

---

### Building a new variant

1. **Copy the closest existing variant** (`check-certs-webhook.sh` for HTTP-based, `check-certs-pushover.sh` for mobile push).

2. **Change the STATE_FILE default** in the `${STATE_FILE:=...}` line. Each variant must use its own state directory so multiple variants can run simultaneously.

3. **Implement `deliver_finding` and `deliver_reminder`**. These are your only required functions.

4. **Add a launchd plist** for macOS in `install/com.check-certs.yourvariant.plist`. Copy an existing plist and update the label, log file paths, and placeholder names.

5. **Update `install.sh`**:
   - Add `INSTALL_YOURVARIANT=false` to the defaults
   - Add `YOURVARIANT_PLIST_NAME` and `YOURVARIANT_PLIST_TARGET` to the platform block
   - Add a `require_file` check in the pre-flight section
   - Add a `state-yourvariant` directory creation in the state init section
   - Add the interactive prompt and install block following the pattern of existing variants

6. **Add a doc page** at `docs/yourvariant.md` following the structure of `docs/ntfy.md`.

7. **Add a line** to `config/check-certs.conf` documenting the variant-specific settings.

8. **Update both READMEs** (EN and DE):
   - Overview table
   - Manual installation links (macOS and Linux sections)
   - Background monitoring list

9. **Update `docs/wrapper-interface.md`** if the new variant introduces any wrapper patterns not already documented.

10. **Add syntax and config validation tests** to `tests/test_check_certs.sh` following the `check-certs-ntfy.sh` section.

---

## The installer

`install.sh` is an interactive installer that runs on macOS and Linux. It is not required — all scripts can be installed manually.

**Key behaviours:**
- `servers.conf` is **never overwritten** by the installer on reinstall.
- `check-certs.conf` is backed up to `check-certs.conf.bak` before being overwritten.
- State directories are created with `mkdir -p`, never `touch`. (This changed in 2.5.0 when the state engine moved from flat files to directories.)
- On macOS, variants use launchd plists with hardcoded placeholder strings (`SCRIPT_PATH_PLACEHOLDER`, `HOUR_PLACEHOLDER`, `MINUTE_PLACEHOLDER`, `LOGDIR_PLACEHOLDER`) that `_install_plist` replaces with `sed` at install time.
- The `_install_derived_plist` function was removed when the ntfy variant got its own dedicated plist. All variants now use `_install_plist` directly.

**Adding a new variant to the installer:** follow the pattern established by the ntfy variant (the most recently added). The `require_file` call, `state-variant` directory creation, hour/minute prompts, and `_install_plist` call must all be present.

---

## Testing

Run the test suite from the project root:

```bash
bash tests/test_check_certs.sh       # summary only
bash tests/test_check_certs.sh -v    # show all PASS lines too
```

The suite has 119 tests across 14 sections. It requires no network access. Live tests that need a real host (e.g. `--check example.com`) are wrapped in `if ... 2>/dev/null; then ... else skip "..."; fi` so they pass cleanly in offline environments.

**Test sections and what they cover:**

| Section | What is tested |
|---|---|
| `parse_hostspec` | All input forms: hostname, IPv4, IPv6, with/without proto, expected failures |
| `_starttls_proto` | All 17 port/protocol combinations including aliases and explicit overrides |
| `extract_ca` | CN extraction, O fallback, truncation, empty issuer |
| `State engine` | create/read/overwrite/delete, IPv6 filenames, unset STATE_FILE no-op |
| `State migration` | Flat file detection, per-field preservation, idempotency |
| `Escalation state machine` | All transitions: new issue, unchanged, level change, reminder, RENEWED, OK→OK |
| `Escalation: error path` | First error, 23h window, daily reminder, invalid port (no repeat) |
| `--check --json output` | Field presence, unquoted integers, valid JSON |
| `--check --nagios exit codes` | Exit 0 for OK, exit 3 for unreachable, UNKNOWN in output |
| `--check kv exit codes` | Exit 2 for unreachable |
| `--check chain error exit codes` | Exit logic using mock worker files |
| `--scan discovery mode` | No arg exit 1, unreachable exit 1, live port discovery |
| `check-certs-ntfy.sh` | Syntax check, NTFY_URL missing, NTFY_TOPIC missing |
| `--check server-list mode` | kv and json array output, --nagios rejection, missing SERVER_FILE |

**How to add tests:** follow the existing pattern. Use `ok()`, `fail()`, `skip()`, `chk_eq()`, and `section()`. Tests that require network access must use the `if cmd 2>/dev/null; then ... else skip "reason"; fi` pattern. Tests that require mocking worker output should write a temp file directly and source the library for the function under test.

**When to update tests:** any change to function signatures, output format, exit codes, or escalation behaviour requires a corresponding test update. Run the suite before and after every change.

---

## Platform constraints

These are hard constraints. Violating them breaks the tool for real users.

**Bash 3.2 compatibility (macOS):**
- No `declare -A` (associative arrays). Use `_worker_field` to read individual fields from worker files.
- No `mapfile` / `readarray`.
- `wait -n` (Bash 4.3+) is used but only with a `wait "${pids[idx-running]}"` fallback.
- `local` is only valid inside functions. Never use `local` at script top level.
- `(( ))` arithmetic is fine. `[[ ]]` is fine.

**macOS `date` vs GNU `date`:**
- macOS `date` does not support `-d "string"`. GNU `date` (installed as `gdate` via `brew install coreutils`) does.
- `DATE_CMD` is set at startup to either `gdate` or `date` depending on availability.
- Always use `$DATE_CMD` for any date formatting or arithmetic. Never call `date` directly.

**`timeout` vs `gtimeout`:**
- macOS may have neither or both. The worker checks for `gtimeout` first, then `timeout`, and falls back to no timeout wrapper.

**Unicode in `printf`:**
- `bash printf "%-*s"` pads by **bytes**, not display columns.
- `✓`, `⚠`, `✗` are 3-byte UTF-8 characters. `%-3s` applied to `✓` produces zero padding because all 3 bytes are consumed by the character itself.
- The table rendering works around this by printing unicode symbols directly followed by explicit spaces. Never use `%-*s` with unicode symbol arguments.

**`IFS='='` with `read -r key value`:**
- Correctly splits on the **first** `=` only when there are exactly two target variables. `CA=O=Let's Encrypt, CN=R10` produces `key=CA`, `value=O=Let's Encrypt, CN=R10`. This is correct bash behaviour and is used in the `--check` server-list loop.

---

## Design rules

These are the rules that emerged from the development history. Follow them.

**1. The worker is the single source of truth for STATUS.**
`_check_cert_worker` computes the full STATUS verdict including chain errors (broken chain + OK leaf → CRITICAL). Every consumer reads STATUS directly. Do not re-derive severity from raw values in consumers. The CHAIN field is available for display purposes only.

**2. `STATE_FILE` is a directory, not a file.**
It was changed in 2.5.0. All code that touches state must treat `STATE_FILE` as a directory path. `state_init` creates it with `mkdir -p`. Per-host files live inside it. The old flat-file design caused concurrency issues at scale.

**3. `local` is only valid inside functions.**
The terminal section (inside the BASH_SOURCE guard but outside any function) cannot use `local`. This trips up code generators. Use plain variable assignments. Use distinctive variable name prefixes (e.g. `_ch_`, `_sl_`, `_sc_`) to avoid collisions.

**4. Both READMEs must stay in sync.**
Every user-facing change must be made in both `README.md` (English) and `README-DE.md` (German). After any README change, verify that section headings, table structures, and all technical content match. German prose should read naturally, not like a literal translation.

**5. Don't add runtime dependencies.**
Not even `jq`, `python3`, or `curl` to the core script. `curl` is required for wrapper variants that do HTTP, but not for the core. The test suite uses `python3 -m json.tool` for JSON validation, but only wrapped in `command -v python3 &>/dev/null` guards with a `skip` fallback.

**6. `declare -A` is banned.**
This breaks Bash 3.2 (macOS default). Use `_worker_field` to read individual fields. See the `--check` block for the canonical pattern.

**7. Every function that reads from a worker file must use `_worker_field`.**
Do not `source` worker files, do not `eval` them, do not `grep` them ad-hoc. `_worker_field` handles the `cut -d= -f2-` correctly for values containing `=`.

**8. Version bumps follow semver loosely.**
- Patch (`2.5.x`): bug fixes, comment improvements, no behaviour change.
- Minor (`2.x.0`): new features, no breaking changes.
- Major (`x.0.0`): breaking changes to CLI interface, hook signatures, or state format.

---

## Known bugs and limitations

**No test runner in CI.** There is no GitHub Actions or similar CI configuration. The test suite is run manually. A CI workflow running `bash tests/test_check_certs.sh` on `ubuntu-latest` and `macos-latest` would be a valuable addition.

**`--scan` is sequential.** Each port is checked one after another (each times out individually), so scanning 11 ports × 5s timeout = up to 55s on a host with many closed ports. The fix would be to run scan probes through `_check_cert_worker` in parallel, similar to `run_server_loop`.

**`--check --json` for server-list mode captures each object via subshell.** The `_sl_obj=$(_ch_print_record ...)` call in the JSON array path is a subshell fork per host. For large server lists this is slower than streaming directly. Acceptable at the current scale.

**No IPv6 literal in servers.conf group names.** Group names containing `[` and `]` (unlikely in practice) would be misidentified as IPv6 addresses by the group header detection regex `^\\[(.+)\\]$`. Not a real-world problem but worth knowing.

**`--nagios` exit code for `URGENT` is 2 (CRITICAL).** URGENT maps to CRITICAL in Nagios terms — there is no Nagios exit code for "more urgent than critical". This is intentional and documented, but it means Nagios cannot distinguish between a cert expiring in 6 days (CRITICAL) and one expiring in 1 day (URGENT). Use `--check` kv or json output if you need that distinction.

---

## Changelog summary

For the full changelog see `CHANGELOG.md`. Key architectural changes by version:

| Version | Architectural change |
|---|---|
| 2.4.0 | Initial public release |
| 2.5.0 | State engine rewritten: `STATE_FILE` is now a directory; per-host files; `state_migrate` for automatic upgrade; `parse_hostspec` centralises host parsing; IPv6 bracket notation support throughout; `--check --nagios`, `--check --json`, `--check` bare hostname default to 443; ntfy variant added; `--scan` discovery mode |
| 2.5.1–2.5.5 | Bug fixes: worker SNI for IP addresses, state_migrate printf, `--nagios` chain error message, table helper function placement, `_json_escape` at library level, `CA_MAX_LEN` documentation, chain exit code handling |
| 2.5.6 | Chain column (Ch) added to terminal table; unicode padding fix for `✓`/`⚠`/`✗` in `printf`; `declare -A` removed (Bash 3.2 compatibility restored); `--nagios` CRITICAL distinguishes chain errors from expiry |
| 2.6.0 | `--check` without a hostspec checks all of `servers.conf` in parallel; batch mode (`--check host1 host2 …`) checks multiple hosts in parallel with the same output modes; `--nagios` works for all three modes; `_ch_print_record` and `_ch_exit_code` helpers extracted |

---

## Contribution workflow

1. **Read this document** before making any change.
2. **Run the test suite** before and after your change: `bash tests/test_check_certs.sh`.
3. **Check Bash 3.2 compatibility**. If you are on Linux, check mentally for `declare -A`, `mapfile`, `wait -n` without fallback.
4. **Update documentation** for any user-visible change:
   - Both `README.md` and `README-DE.md`
   - The relevant `docs/*.md` page
   - `CHANGELOG.md`
   - `docs/wrapper-interface.md` for any hook or API change
5. **Update or add tests** in `tests/test_check_certs.sh`.
6. **Update the version** in `VERSION=` and in the `#  Version` header comment in `check-certs.sh`. Patch for fixes, minor for features.
7. **Open an issue before large changes** to discuss the approach. Bug fixes can go straight to a pull request.

For questions about the wrapper interface, `docs/wrapper-interface.md` is the canonical reference. For questions about the test suite, the test file itself is heavily commented and the section names map directly to the functions under test.
