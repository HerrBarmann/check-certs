# Changelog

All notable changes to check-certs are documented here.

---

## 2.5.1 — 2026-05-26

### Bug fixes

**SNI skipped for IP address hosts.** Both `openssl s_client` calls in `_check_cert_worker` passed `-servername "$hostname"` unconditionally. SNI is only valid for DNS hostnames — passing a bare IPv4 or IPv6 address as the server name is meaningless and produces warnings in some openssl versions. The calls now check whether the hostname looks like an IP address and omit `-servername` in that case.

**`state_migrate` printf escape sequence.** The `printf` inside the migration loop had a literal newline in the format string rather than `\n`. It produced correct output (a literal newline in a single-quoted string is valid shell), but the intent was `\n` and the form was fragile. Corrected to `printf '%s=%s\n'`.

**`--scan` and `--check` comment blocks were merged.** The `--check` header comment ran directly into the `--scan` comment, then the `--scan` if-block appeared 90 lines before the `--check` if-block. Each section header now sits immediately above its own block.

### Documentation and comments

Updated inline comments throughout `check-certs.sh` and all wrapper scripts: worker field list now includes `EXPIRY_TS`; `_dispatch_result`, `run_server_loop`, `install_escalation_hooks`, and the semaphore block all have expanded explanations; the state abbreviation scheme (`CRIT`/`WARN`) is explicitly documented at the point where it is written; wrapper headers and function comments are consistent across all six variants.

`check-certs.conf` updated: the variant list in the file header now includes all six variants; the state tracking section describes the directory layout correctly; ntfy settings added with documentation.

---

## 2.5.0 — 2026-05-26

### New features

**`--scan` — port discovery mode**
`check-certs --scan <hostname>` probes 11 common TLS ports (443, 8443, 465, 587, 993, 143, 995, 110, 636, 389, 25) and prints a ready-to-paste `servers.conf` snippet for every port that responds with a valid certificate. Intended as an onboarding helper: run it once on a new host and copy the output directly into your server list. STARTTLS protocols are detected and annotated automatically.

**ntfy notification variant (`check-certs-ntfy.sh`)**
New automation wrapper for [ntfy](https://ntfy.sh) — a lightweight HTTP push notification service popular in self-hosted setups. Works with ntfy.sh (hosted) or any self-hosted ntfy server. Supports token auth and basic auth for protected topics. Priority mapping follows the same severity model as the Pushover variant: URGENT and EXPIRED send at priority 5 (max, bypasses silent mode), CRITICAL and ERROR at 4 (high), WARNING at 3 (default), RENEWED at 2 (low, no interruption). Individual findings send as separate notifications; daily reminders are batched into one message per severity level to reduce noise. See `docs/ntfy.md` for setup instructions.

**`--check --nagios` — Nagios/Icinga plugin output**
`check-certs --check --nagios <host>` produces output and exit codes compatible with Nagios, Icinga, Checkmk, and any monitoring system that speaks the Nagios plugin interface. Output format: `STATUS - host:port: human message`. Exit codes: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN (unreachable or parse error). URGENT and EXPIRED both map to CRITICAL (exit 2) — mapping them to UNKNOWN would suppress paging in most monitoring setups.

**`--check --json` — JSON output**
`check-certs --check --json <host>` emits a single JSON object to stdout. Numeric fields (`days`, `port`) are unquoted integers. Both successful results and error conditions are covered. The `chain_status` field is included so consumers can detect broken intermediate CAs without string-parsing the `ca` field. Useful for feeding into dashboards, log aggregators, or shell pipelines.

**IPv6 support**
Bracket notation is now accepted everywhere a host is specified: in `servers.conf`, as a CLI argument, and with `--check`/`--scan`. Examples: `[::1]:443`, `[2001:db8::1]:636:ldaps`. A shared `parse_hostspec` function handles all parsing; the four previously independent regex copies have been replaced.

**`--clear-state --state-dir <path>`**
The `--clear-state` command now accepts an optional `--state-dir <path>` argument, making it possible to clear a specific variant's state directory without needing `STATE_FILE` configured in `check-certs.conf`. Useful when running multiple variants or when the terminal user wants to reset a particular wrapper's state.

### Changes

**State engine rewritten to per-host directory layout**
`STATE_FILE` is now treated as a directory path. Each monitored host gets its own small file inside it, named after the sanitised hostname. Previously, every `state_set` call rewrote the entire flat file (grep → tmpfile → mv), which became slow and race-prone at scale. The new layout makes each write a single-file operation. Multiple wrapper variants running simultaneously no longer contend on a shared file.

The `STATE_FILE` path itself does not change — only its interpretation. Existing installations are migrated automatically on first run: `state_init` detects a 2.4.x flat file at the configured path, parses it into per-host files, and renames the original to `<path>.pre-2.5.bak`. The migration is idempotent.

**`--check` exit codes corrected**
In 2.4.0, URGENT exited with code 3. This was inconsistent — URGENT is more severe than CRITICAL, not less. All of CRITICAL, URGENT, and EXPIRED now exit 2. Exit code 3 (UNKNOWN) is reserved for `--nagios` mode on unreachable hosts.

**`install.sh` creates state directories instead of state files**
The installer now runs `mkdir -p` for each variant's state path instead of `touch`. No functional change for new installations; the directories are created by `state_init` anyway, but pre-creating them makes the install output accurate.

### Tests

A test suite has been added at `tests/test_check_certs.sh`. It requires no network access and no external dependencies beyond bash itself. Run it from the project root:

```bash
bash tests/test_check_certs.sh        # summary output
bash tests/test_check_certs.sh -v     # show all PASS lines
```

101 tests covering: `parse_hostspec` (all input forms including IPv6), `_starttls_proto` (all ports and explicit overrides), `extract_ca` (CN/O parsing, truncation), the state engine (create/read/overwrite/delete, IPv6 filenames, unset `STATE_FILE`), state migration (flat-file detection, field preservation, idempotency), the escalation state machine (all transitions: new issue, unchanged within window, level escalation, daily reminder, renewal, error path), `--check --json` (field presence, integer encoding, JSON validity), `--check --nagios` (exit codes, output format), `--scan` (missing argument, unreachable host), and ntfy config validation.

### Files changed

| File | Change |
|------|--------|
| `src/check-certs.sh` | State engine rewrite, `parse_hostspec`, `--scan`, `--check --nagios/--json`, exit code fix, `--clear-state --state-dir` |
| `src/check-certs-ntfy.sh` | New file |
| `src/check-certs-mail.sh` | Comment update (state file → state directory) |
| `src/check-certs-notify.sh` | Comment update |
| `src/check-certs-pushover.sh` | Comment update |
| `src/check-certs-teams.sh` | Comment update |
| `src/check-certs-webhook.sh` | Comment update |
| `install/install.sh` | `touch` → `mkdir -p` for state paths |
| `docs/ntfy.md` | New file |
| `docs/wrapper-interface.md` | State API section updated for directory layout |
| `tests/test_check_certs.sh` | New file |

---

## 2.4.0

Initial public release.
