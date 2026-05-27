# Changelog

All notable changes to check-certs are documented here.

---

## 2.6.2 — 2026-05-27

### Bug fix

**Batch mode silently skipped bare hostnames.** `check-certs --check www.google.de www.telekom.de` only returned a result for hosts with an explicit port. The batch path writes a temp `servers.conf` and feeds it to the server-list loop, which calls `parse_hostspec` and silently discards entries that don't match `host:port`. Bare hostnames without a port were therefore skipped. The batch write step now normalises bare hostnames to `host:443` (matching the single-host fallback), so all three of `host`, `host:port`, and `host:port:proto` work correctly in batch mode.

---

## 2.6.1 — 2026-05-27

### New feature

**`--check` batch mode — multiple hosts as arguments.**

`--check` now accepts any number of hostspecs as arguments. They are checked in parallel (respecting `MAX_JOBS`) and results are emitted in argument order:

```bash
check-certs --check api.example.com ldap.example.com:636:ldaps [::1]:443
check-certs --check --json api.example.com ldap.example.com:636
check-certs --check --nagios api.example.com ldap.example.com:636
```

This completes the `--check` scripting surface: no args = `servers.conf`, one arg = single host, multiple args = batch.

All three output modes work for batch. `--json` produces a JSON array. `--nagios` produces one line per host and exits with the worst code across all hosts (exit 2 if any CRITICAL/ERROR, exit 1 if any WARNING, exit 0 if all OK). This makes it possible to use check-certs as a Nagios plugin that checks several related hosts in a single invocation.

The batch path writes a temp `servers.conf` from the argument list and feeds it to the existing server-list machinery — no duplicated worker or output logic.

---

## 2.6.0 — 2026-05-27

### New feature

**`--check` without a hostspec checks all servers in `servers.conf`.**

`check-certs --check` and `check-certs --check --json` now accept an optional hostspec. When no host is given, every server in `servers.conf` is checked in parallel (respecting `MAX_JOBS` and per-host threshold overrides) and the results are emitted in the original file order:

```bash
check-certs --check           # key=value blocks, one per host, separated by blank lines
check-certs --check --json    # JSON array, one object per host
```

Single-host behaviour is unchanged:

```bash
check-certs --check mail.example.com:587
check-certs --check --json api.example.com
```

`--nagios` remains single-host only — Nagios plugins check exactly one service. Passing `--nagios` without a hostspec exits 1 with a clear error.

**Exit codes for server-list mode:** `0` if all hosts OK, `1` if at least one WARNING (none worse), `2` if any CRITICAL, URGENT, EXPIRED, or ERROR.

**JSON output format:** a top-level JSON array (`[{...}, {...}]`), valid JSON parseable directly by `jq` and any JSON library without extra flags.

**Implementation notes:** the parallel worker pool and per-host override parsing from `run_server_loop` are replicated directly in the `--check` server-list path so it respects `warn=`, `crit=`, `urgent=`, and `timeout=` overrides from `servers.conf`. The shared `_ch_print_record` helper is extracted from the old single-host code so both paths use identical output formatting.

---

## 2.5.6 — 2026-05-26

### Changes

**`--check` exits 1 on chain errors.** A valid certificate with a broken intermediate CA now exits 1 (WARNING) rather than 0. A cert that is already WARNING keeps exit 1; CRITICAL/URGENT/EXPIRED keep exit 2. This makes `--check` usable as a strict gate in CI pipelines where a broken chain should not silently pass.

**`_json_escape` moved to library level.** Previously defined inside the `--check` block and re-created on every invocation. Now defined once alongside the other utility helpers.

**Table helpers moved above the BASH_SOURCE guard.** `_repeat`, `hline`, `print_group`, `print_error_row`, and the `on_*` terminal hooks were defined after more than 1100 lines of command dispatch. Moved to library level so all function definitions are together and the script reads top-to-bottom.

**`CA_MAX_LEN` comment expanded.** The terminal uses 22 and the wrapper default is 30. The comment now explains why: the terminal has a fixed column budget (fits an 80-column terminal at 22); wrappers format free-form text and can use the longer default without layout issues.

**`--check` field reading uses an associative array.** Previously read each worker output field with a separate `_worker_field` call (one subshell fork each, 8 total). Now reads the file once with a `while IFS='=' read` loop into a `declare -A` array. Values containing `=` signs (e.g. CA names with `O=` or `CN=`) are handled correctly because `IFS='='` with two read variables splits only on the first `=`.

---

## 2.5.5 — 2026-05-26

### Bug fix

**Chain column alignment corrected.** The chain cell needed `COL5+2=5` display columns (1 leading space + 1 symbol + 3 trailing spaces) but was only 4 wide (2 trailing spaces). Rows containing `✓` or `⚠` were one character short of the right border.

---

## 2.5.4 — 2026-05-26

### Bug fix

**Chain column now aligns correctly.** `bash printf` pads `%-*s` by bytes, not display columns. The `✓` and `⚠` symbols are 3 bytes each in UTF-8 but occupy only 1 display column, so `%-3s` produced no padding and the cell came out 2 chars short. The chain symbol is now printed directly followed by two explicit spaces, giving the correct 3-column width regardless of byte length.

---

## 2.5.3 — 2026-05-26

### Change

**Chain status is now a dedicated table column.** Previously, a broken certificate chain appended ` ⚠chain` to the CA name in the "Issued by" column, which overflowed the fixed column width and misaligned the table. The chain status is now shown in a separate narrow **Ch** column at the right edge of the table: `✓` (green, chain OK) or `⚠` (yellow, broken chain). The CA name column is now always clean and correctly padded. Error rows show an empty Ch cell.

---

## 2.5.2 — 2026-05-26

### Bug fix

**`--check` now accepts a bare hostname without a port.** Previously `check-certs --check hostname` failed with "invalid hostspec". The port is now optional and defaults to 443, consistent with the terminal single-host mode. Invalid specs that contain colons but don't match any valid form still produce a clear error.

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
