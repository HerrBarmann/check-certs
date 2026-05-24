# Changelog

## v2.4.0

### New

- **`check-certs --check`** — structured single-server output for scripting
  and monitoring integrations. Prints one `key=value` pair per line covering
  host, port, proto, status, days, expiry, CA, and chain status. Exit codes
  map directly to severity: 0=OK, 1=WARNING, 2=CRITICAL/EXPIRED/ERROR,
  3=URGENT. Compatible with Nagios/Icinga plugin conventions.
- **Unified installer** (`install/install.sh`) — replaces `install-linux.sh`
  and `install-macos.sh`. Detects the platform automatically (`uname -s`)
  and runs the appropriate setup. All variant options, prompts, and post-
  install steps are preserved. Both old scripts remain in the repository
  for reference but `install.sh` is now the primary installer.
- **`com.check-certs.teams.plist`** — dedicated launchd job template for
  the Teams variant, used by `install.sh` and available for manual installs.
- **`check-certs --check` documented** in both README.md and README-DE.md
  with full output field reference, exit code table, and scripting examples.
- **German README** (`README-DE.md`) — full German translation of README.md.

### Changed

- Installers now back up an existing `check-certs.conf` to
  `check-certs.conf.bak` before overwriting, rather than silently skipping.
- Email subject lines are now pure 7-bit ASCII — em dash replaced with
  hyphen to prevent mangling by mail servers and clients.
- SMTP username and password are now optional in the installer — leave blank
  for unauthenticated relay. Postfix SASL block and ssmtp auth lines are
  only written when credentials are provided.
- All launchd plist comments updated to reference `install.sh`.

### Fixed

- `install.sh`: `_install_derived_plist` sed pattern produced wrong script
  name (e.g. `mail` instead of `check-certs-mail`) — fixed by preserving
  the `check-certs-` prefix in the substitution.
- `install.sh`: `_sm_cmd` test-email helper defined inside a conditional
  block — moved to a proper function definition before the prompt.
- `install.sh`: unused `DIM` colour variable removed.
- `check-certs --check`: temp file not cleaned on all exit paths — fixed
  with `trap 'rm -f "$_ch_tmp"' EXIT`.
- `check-certs --check`: ERROR output showed user-supplied proto instead of
  the auto-resolved protocol — now reads line 4 from worker output for
  both RESULT and ERROR cases.
- `check-certs --check`: `mktemp` return value not checked — now exits with
  an error message if temp file creation fails.
- Stale `check-certs/` subdirectory (nested git clone) removed from working
  tree.

---

## v2.4.0

### New

- **Per-host threshold overrides** in `servers.conf` — individual servers can
  have their own `warn`, `crit`, `urgent`, and `timeout` values, overriding
  the global thresholds in `check-certs.conf`. All wrappers inherit this
  automatically since it is applied inside the worker.
  ```
  api.example.com:443 warn=30 crit=14   # tighter for critical services
  internal.example.com:443 warn=7        # looser for internal tools
  slow.example.com:443 timeout=15        # longer timeout for slow hosts
  ```
- **`check-certs --check`** — structured single-server output for scripting
  and monitoring integrations. Prints `key=value` pairs covering host, port,
  proto, status, days, expiry, CA, and chain. Exit codes map to severity:
  0=OK, 1=WARNING, 2=CRITICAL/EXPIRED/ERROR, 3=URGENT.
- **`check-certs --clear-state`** — clears all `state-*` files in the state
  directory in one command. Any variant's state file can be used as the
  reference; all sibling state files are cleared.
- **Unified installer** (`install/install.sh`) — single script replacing the
  former `install-linux.sh` and `install-macos.sh`. Platform is detected
  automatically via `uname`. The old platform-specific scripts have been
  removed from the repository.
- **`com.check-certs.mail.plist`** and **`com.check-certs.teams.plist`** —
  dedicated launchd job templates for the mail and Teams variants.
- **German README** (`README-DE.md`) — full German translation of README.md,
  linked from the top of both files.
- **`--check` and `--clear-state`** documented in both READMEs with full
  output field reference, exit code table, and scripting examples.

### Changed

- Unified installer backs up an existing `check-certs.conf` to
  `check-certs.conf.bak` before overwriting.
- SMTP username and password are now optional in the installer — leave blank
  for unauthenticated relay. Postfix SASL and ssmtp auth lines are only
  written when credentials are provided.
- `check-certs --list` now shows per-host overrides inline:
  `google.com (port 443 | warn=30 crit=14)`.
- `--help` output updated to include `--check`, `--clear-state`, and the
  per-host override syntax.
- Email subject lines are now pure 7-bit ASCII — em dash replaced with
  hyphen to prevent mangling by mail servers and clients.
- All wrapper header comments updated for consistency: macOS launchd
  schedule noted in all variants, Teams wrapper accurately describes that
  only non-OK servers are shown.
- `email.md` title corrected from "Linux Email" to "Email".
- `pushover.md` and `teams.md` launchd sections updated to reference their
  own dedicated plist files rather than transforming the webhook template.

### Fixed

- Per-host override values are validated as positive integers before being
  passed to the worker — non-integer values are silently discarded and the
  global threshold is used instead.
- `check-certs --check`: temp file cleaned up on all exit paths via
  `trap EXIT`; `mktemp` failure handled; ERROR output now shows the
  auto-resolved STARTTLS protocol rather than the user-supplied value.
- `install.sh`: `_install_derived_plist` sed produced `mail` instead of
  `check-certs-mail` — fixed by preserving the `check-certs-` prefix.
- `install.sh`: `_sm_cmd` test-email helper moved to a proper function
  definition; unused `DIM` colour variable removed.
- `check-certs-mail.sh`: macOS launchd reference corrected to
  `com.check-certs.mail.plist`.
- Stale nested `check-certs/` subdirectory removed from the repository.

- Worker communication protocol refactored from positional line numbers
  to named `KEY=value` pairs. Adding new fields in future requires no
  changes to existing readers. A `_worker_field <file> KEY` helper reads
  individual fields by name.
- `check-certs --check` simplified to stream the worker output directly
  (lowercase keys, `TYPE=` line dropped, empty `PROTO=` normalised to
  `tls`). Field order now follows the worker file order.

### Fixed (post v2.4.0 initial packaging)

- `check-certs --check`: `IFS="=" read` split on every `=` sign, losing
  everything after the second `=` in values such as CA names containing
  `=`. Fixed by reading whole lines and splitting with `%%=*` / `#*=`.
- `check-certs --check`: `${key,,}` (bash 4 lowercase syntax) fails on
  macOS system bash 3.2. Replaced with `tr 'A-Z' 'a-z'`.

---

## v2.3.1 — Bugfixes

### Fixed

- `check-certs-teams.sh`: summary OK count was wrong — `total - warned`
  does not account for error hosts since `warned` and `errors` are tracked
  separately. Corrected to `total - warned - errors`.
- `check-certs-teams.sh`: card now uses Adaptive Card version 1.2 instead
  of 1.4 for maximum Teams Workflow compatibility.
- `check-certs-teams.sh`: payload delivered via temp file with
  `--data-binary` instead of shell argument to avoid escaping issues with
  large JSON payloads.

---

## v2.3.0

### New

- **Microsoft Teams Adaptive Card variant** (`check-certs-teams.sh`) — posts
  a single Adaptive Card to a Teams channel mirroring the terminal table
  output: all servers grouped by section, colour-coded status column, and a
  summary line. The card is sent only when notification thresholds are reached.
  Requires a Teams Workflow webhook created from the built-in template — no
  Power Automate configuration beyond the initial setup.
- Both installers updated to include Teams as a selectable variant.
- `docs/teams.md` — full setup guide including Workflow creation steps,
  configuration, manual installation for Linux and macOS, card format
  reference, and troubleshooting.
- `TEAMS_WEBHOOK_URL` added to `check-certs.conf` reference.

### Fixed

- `check-certs-teams.sh`: row data stored in separate indexed arrays instead
  of embedded JSON strings, eliminating a fragile grep/sed extraction pattern
  that would break on hostnames or CA names containing special characters.
- `check-certs-teams.sh`: `_body+=` lines rewrote to use correct bash quote
  alternation so variable expansions inside JSON strings work reliably.
- `check-certs-teams.sh`: `_ok_count` calculation corrected — `warned` already
  includes error hosts so `total - warned - errors` double-counted errors.
  Now `total - warned`.
- `check-certs-teams.sh`: reminder header text set explicitly instead of
  using a fragile emoji-strip on the multi-byte header string.
- `install-linux.sh` / `install-macos.sh`: example input in the multi-select
  menu prompt updated to reflect the new option count.

---

## v2.2.0

### New

- **Multi-variant installation** — both installers now support selecting
  multiple automation variants in a single run. Each variant gets its own
  schedule and independent state file so they coexist without interfering.
- **Email variant on macOS** — `check-certs-mail.sh` now works on macOS via
  ssmtp or any MTA that provides a `sendmail` interface (e.g. Homebrew
  Postfix). The macOS installer includes email as a selectable variant.
- **sendmail transport** — a third email transport option alongside Postfix
  and ssmtp, for servers running Exim or any other MTA with a
  `sendmail`-compatible binary.

### Changed

- **Per-variant state files** — each wrapper now defaults to its own state
  file (`state-mail`, `state-notify`, `state-webhook`, `state-pushover`)
  so multiple variants can run simultaneously without the escalation logic
  of one interfering with another. Explicit `STATE_FILE` in
  `check-certs.conf` still overrides this.
- **Installer conf no longer writes `STATE_FILE`** — the wrappers handle
  their own defaults; the installer only creates the state directory and
  touches the appropriate state file(s).
- **`linux-email.md` renamed to `email.md`** — reflects that the email
  variant now works on both Linux and macOS.
- `check-certs.conf` email settings (`MAIL_TO` etc.) changed from live
  placeholder values to commented-out defaults, consistent with all other
  variant-specific settings.
- Duplicate Pushover section in `check-certs.conf` removed; `PUSHOVER_RETRY`
  default unified to 300 seconds.

### Fixed

- `install-linux.sh`: `curl` was installed twice when both webhook and
  Pushover were selected; collapsed into a single conditional.
- `install-macos.sh`: `_install_plist` extracted the launchd label from the
  plist file with a fragile grep; label is now passed as an explicit argument.
- `install-macos.sh`: `hour` and `minute` were not declared `local` in
  `_install_plist`, leaking them as globals.
- `install-macos.sh`: `_install_mail_plist` used a fragile double-sed pipe;
  rewritten to use a temp file and delegate to `_install_plist`.
- `check-certs.conf` header comment listed `check-certs-mail.sh` as Linux
  only; updated to reflect Linux + macOS support and sendmail.
- `check-certs.sh` header comment still said `Version 2.0.0`; updated.
- README files listing described `check-certs-mail.sh` as Linux-only.

---

## v2.1.1 — Bugfixes

### Fixed

- Port 465 removed from STARTTLS auto-detection. Port 465 (SMTPS) uses
  implicit TLS like HTTPS, not STARTTLS negotiation. It is now handled as
  plain TLS by default, consistent with 636 (LDAPS) and 993 (IMAPS).
  Explicitly setting `:smtps` or `:tls` in servers.conf continues to work.
- EXPIRED certificate row no longer overflows the terminal table. The
  "Remaining" column now shows "EXP -Nd" (e.g. "EXP -1151d") instead of
  "Nd (expired!)" which overflowed the fixed column width.
- check-certs --version now correctly reports v2.1.1.

---

## v2.1.0

### New

- **Pushover variant** (`check-certs-pushover.sh`) — mobile push notifications
  via the Pushover API. Priority levels map directly onto certificate severity:
  URGENT and EXPIRED trigger emergency priority (retries until acknowledged),
  CRITICAL and errors trigger high priority (bypasses quiet hours), WARNING is
  normal priority, and RENEWED is quiet. Configurable retry interval and
  expiry window for emergency notifications. Works on any platform with curl.
- **`com.check-certs.pushover.plist`** — dedicated launchd job template for
  the Pushover variant on macOS.
- Both installers updated to include Pushover as a variant option.

---

## v2.0.0 — Complete rewrite

This release is a full rebuild. The script is no longer a standalone
checker — it is now a library with a documented wrapper interface, and
all notification logic lives in separate, swappable variant scripts.

### Core (check-certs.sh)

- Rewritten as a sourceable library. When sourced by a wrapper it exposes
  certificate checking, state management, and escalation logic with no
  side effects. The terminal table only activates when run directly.
- Parallel certificate checking via a background worker pool with a
  configurable job limit (MAX_JOBS).
- Full certificate chain verification on every check, not just the leaf
  certificate.
- STARTTLS support — auto-detected on standard ports (389 LDAP, 25/587
  SMTP, 143 IMAP, 110 POP3, 21 FTP, 5222 XMPP) with per-host protocol
  override via hostname:port:proto in servers.conf.
- New URGENT severity level with a configurable threshold and separate
  escalation path.
- State tracking between runs — findings are only reported when status
  changes, with configurable daily reminders for persistent issues.
- --list command shows all configured servers with auto-detected or
  explicit STARTTLS protocol.
- Documented wrapper interface: on_cert_result, on_cert_error, on_group,
  on_format_error event hooks; deliver_finding / deliver_reminder delivery
  hooks; state API (state_get, state_set, state_delete).

### Variants (new)

- check-certs-mail.sh — Linux email via Postfix or ssmtp, selected by
  MAIL_TRANSPORT in check-certs.conf. Sends a formatted plain-text report
  only when there is something to report. Known ongoing issues are
  included in every email for full visibility.
- check-certs-notify.sh — macOS native notifications via terminal-notifier
  and launchd. Notifications are grouped by severity with distinct sounds.
  Clicking a notification opens the full terminal table.
- check-certs-webhook.sh — HTTP POST JSON payloads to any endpoint. Works
  with Slack, ntfy.sh, Teams, PagerDuty, Grafana Alerting, or custom
  receivers. Retries once on failure. Posts an optional run summary event.

### Installation

- install-macos.sh — interactive installer for macOS. Prompts for variant
  choice (notifications, webhook, Pushover, or terminal only), configures
  launchd, writes check-certs.conf.
- install-linux.sh — interactive installer for Debian/Ubuntu. Prompts for
  variant choice (Postfix, ssmtp, webhook, Pushover, or terminal only),
  installs packages, configures the chosen mail transport without
  overwriting existing system configuration, writes check-certs.conf,
  sets up cron job.
- Neither installer ever overwrites an existing servers.conf or
  check-certs.conf.

### Configuration

- All settings consolidated in check-certs.conf, shared across all
  variants.
- Variant-specific settings (email addresses, webhook URL, transport) live
  alongside shared threshold settings in the same file and are ignored by
  variants that don't use them.
- config/check-certs.conf ships as a full reference and manual install
  template documenting every available setting. The installers write their
  own minimal variant-specific config and do not use this file.
