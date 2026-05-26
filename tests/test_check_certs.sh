#!/bin/bash
# ============================================================
#  test_check_certs.sh – Unit test suite for check-certs
#
#  Tests pure logic only – no network access required.
#  Covers: parse_hostspec, state engine, state migration,
#          _starttls_proto, extract_ca, escalation state
#          machine, and --check exit code mapping.
#
#  Usage:
#    bash tests/test_check_certs.sh          # from project root
#    bash tests/test_check_certs.sh -v       # verbose (show all PASS lines)
# ============================================================

PASS=0; FAIL=0; SKIP=0
VERBOSE=false
[[ "${1:-}" == "-v" ]] && VERBOSE=true

ok()   { ((PASS++)); $VERBOSE && printf '  PASS  %s\n' "$*" || true; }
fail() { ((FAIL++)); printf '  FAIL  %s\n' "$*"; }
skip() { ((SKIP++)); printf '  SKIP  %s\n' "$*"; }
section() { printf '\n══  %s\n' "$*"; }

chk_eq() {
    local desc="$1" got="$2" exp="$3"
    [ "$got" = "$exp" ] && ok "$desc" || fail "$desc: expected '$exp', got '$got'"
}

# ── Load the library ─────────────────────────────────────────
# Strip the terminal UI block (BASH_SOURCE guard) before sourcing
# so no terminal output or exit calls fire during tests.
_TMP_LIB=$(mktemp --suffix=.sh)
sed '/^if \[\[ "\${BASH_SOURCE\[0\]}" == "\${0}" \]\]/,$ d' \
    "$(dirname "$0")/../src/check-certs.sh" > "$_TMP_LIB"
source "$_TMP_LIB"
rm -f "$_TMP_LIB"

# ════════════════════════════════════════════════════════════
section "parse_hostspec"
# ════════════════════════════════════════════════════════════

_chk_parse() {
    local label="$1" spec="$2" eh="$3" ep="$4" epr="$5"
    local h="" p="" pr=""
    if parse_hostspec "$spec" h p pr; then
        if [[ "$h" == "$eh" && "$p" == "$ep" && "$pr" == "$epr" ]]; then
            ok "$label"
        else
            fail "$label: got h='$h' p='$p' pr='$pr'  (expected h='$eh' p='$ep' pr='$epr')"
        fi
    else
        [ -z "$eh" ] && ok "$label (expected failure)" \
                     || fail "$label: parse returned 1 unexpectedly"
    fi
}

_chk_parse "hostname:port"              "mail.example.com:587"       "mail.example.com" "587" ""
_chk_parse "hostname:port:proto"        "mail.example.com:587:smtp"  "mail.example.com" "587" "smtp"
_chk_parse "IPv4:port"                  "192.0.2.1:443"              "192.0.2.1"        "443" ""
_chk_parse "IPv4:port:proto"            "192.0.2.1:443:https"        "192.0.2.1"        "443" "https"
_chk_parse "IPv6 loopback:port"         "[::1]:443"                  "::1"              "443" ""
_chk_parse "IPv6 full:port"             "[2001:db8::1]:636"          "2001:db8::1"      "636" ""
_chk_parse "IPv6 full:port:proto"       "[2001:db8::1]:636:ldaps"    "2001:db8::1"      "636" "ldaps"
_chk_parse "bare hostname (fail)"       "hostname"                   ""                 ""    ""
_chk_parse "empty port (fail)"          "host:"                      ""                 ""    ""
_chk_parse "missing brackets IPv6"      "::1:443"                    ""                 ""    ""

# ════════════════════════════════════════════════════════════
section "_starttls_proto  (port-based auto-detection)"
# ════════════════════════════════════════════════════════════

_chk_starttls() {
    local desc="$1" port="$2" proto="$3" expected="$4"
    local got
    got=$(_starttls_proto "$port" "$proto")
    chk_eq "$desc" "$got" "$expected"
}

# Auto-detection by port number
_chk_starttls "port 25  → smtp"         "25"   ""    "smtp"
_chk_starttls "port 587 → smtp"         "587"  ""    "smtp"
_chk_starttls "port 143 → imap"         "143"  ""    "imap"
_chk_starttls "port 110 → pop3"         "110"  ""    "pop3"
_chk_starttls "port 389 → ldap"         "389"  ""    "ldap"
_chk_starttls "port 21  → ftp"          "21"   ""    "ftp"
_chk_starttls "port 5222→ xmpp"         "5222" ""    "xmpp"
_chk_starttls "port 443 → (plain TLS)"  "443"  ""    ""
_chk_starttls "port 636 → (plain TLS)"  "636"  ""    ""
_chk_starttls "port 993 → (plain TLS)"  "993"  ""    ""
# Explicit protocol overrides
_chk_starttls "explicit smtp"           "443"  "smtp"       "smtp"
_chk_starttls "explicit imap"           "443"  "imap"       "imap"
_chk_starttls "explicit ldap"           "636"  "ldap"       "ldap"
_chk_starttls "tls alias → plain"       "25"   "tls"        ""
_chk_starttls "https alias → plain"     "25"   "https"      ""
_chk_starttls "smtps alias → plain"     "25"   "smtps"      ""
_chk_starttls "submission alias"        "587"  "submission" "smtp"

# ════════════════════════════════════════════════════════════
section "extract_ca  (issuer name parsing)"
# ════════════════════════════════════════════════════════════

_chk_ca() {
    local desc="$1" issuer="$2" expected="$3"
    CA_MAX_LEN=30
    local got
    got=$(extract_ca "$issuer")
    chk_eq "$desc" "$got" "$expected"
}

_chk_ca "CN present"           "issuer=C=US, O=Let's Encrypt, CN=R10"              "R10"
_chk_ca "CN with spaces"       "issuer=CN = My Corporate CA"                       "My Corporate CA"
_chk_ca "CN fallback to O"     "issuer=O=Some Org, OU=PKI"                         "Some Org"
_chk_ca "Let's Encrypt R3"     "issuer=C=US, O=Let's Encrypt, CN=R3"               "R3"
_chk_ca "Truncation at 30"     "issuer=CN=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"       "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
_chk_ca "No issuer info"       "issuer="                                            "Unknown"

# ════════════════════════════════════════════════════════════
section "State engine  (directory-based, per-host files)"
# ════════════════════════════════════════════════════════════

_STMP=$(mktemp -d)
STATE_FILE="$_STMP/state-test"

state_init
[ -d "$STATE_FILE" ] && ok "state_init creates directory" || fail "directory not created"

# Basic set/get
state_set "status:mail.example.com" "WARNING"
state_set "days:mail.example.com"   "10"
state_set "last_notify:mail.example.com" "1748000000"
chk_eq "state_get status"      "$(state_get 'status:mail.example.com')"       "WARNING"
chk_eq "state_get days"        "$(state_get 'days:mail.example.com')"         "10"
chk_eq "state_get last_notify" "$(state_get 'last_notify:mail.example.com')"  "1748000000"

# One file per host
files=$(ls "$STATE_FILE" | wc -l | tr -d ' ')
chk_eq "one file per host" "$files" "1"

# Second host = second file
state_set "status:ldap.example.com" "OK"
files=$(ls "$STATE_FILE" | wc -l | tr -d ' ')
chk_eq "two hosts → two files" "$files" "2"

# Overwrite
state_set "status:mail.example.com" "CRITICAL"
chk_eq "state_set overwrites value" "$(state_get 'status:mail.example.com')" "CRITICAL"

# Delete single field; other fields in same host file survive
state_delete "last_notify:mail.example.com"
chk_eq "state_delete removes field"   "$(state_get 'last_notify:mail.example.com')" ""
chk_eq "state_delete preserves other" "$(state_get 'status:mail.example.com')"      "CRITICAL"

# Missing key returns empty string (no error)
chk_eq "state_get missing key" "$(state_get 'status:nonexistent.example.com')" ""

# IPv6 address as hostname – colons and brackets become underscores
state_set "status:[::1]" "OK"
safe=$(ls "$STATE_FILE" | grep -v 'mail\|ldap')
[[ "$safe" =~ ^[a-zA-Z0-9._-]+$ ]] \
    && ok "IPv6 filename is safe ('$safe')" \
    || fail "unsafe IPv6 filename: '$safe'"
chk_eq "IPv6 state round-trip" "$(state_get 'status:[::1]')" "OK"

# STATE_FILE="" → all operations are no-ops, never error
old_sf="$STATE_FILE"; STATE_FILE=""
state_init; state_set "status:x" "y"
chk_eq "state_get returns empty when STATE_FILE unset" "$(state_get 'status:x')" ""
STATE_FILE="$old_sf"

rm -rf "$_STMP"

# ════════════════════════════════════════════════════════════
section "State migration  (v2.4.x flat file → v2.5 directory)"
# ════════════════════════════════════════════════════════════

_STMP2=$(mktemp -d)
STATE_FILE="$_STMP2/state-mail"

# Write a v2.4.x flat state file (all keys in one file)
printf 'status:mail.example.com=WARNING\ndays:mail.example.com=10\nlast_notify:mail.example.com=1748000000\nstatus:ldap.example.com=OK\ndays:ldap.example.com=42\n' \
    > "$STATE_FILE"

state_init 2>/dev/null
[ -d "$STATE_FILE" ]               && ok "flat file migrated to directory"  || fail "not a directory after migration"
[ -f "${STATE_FILE}.pre-2.5.bak" ] && ok "original backed up as .pre-2.5.bak" || fail "backup not created"

chk_eq "status migrated"      "$(state_get 'status:mail.example.com')"      "WARNING"
chk_eq "days migrated"        "$(state_get 'days:mail.example.com')"         "10"
chk_eq "last_notify migrated" "$(state_get 'last_notify:mail.example.com')"  "1748000000"
chk_eq "second host migrated" "$(state_get 'days:ldap.example.com')"         "42"

# Second call to state_init must not re-migrate or corrupt state
state_init 2>/dev/null
chk_eq "idempotent re-init" "$(state_get 'status:mail.example.com')" "WARNING"

rm -rf "$_STMP2"

# ════════════════════════════════════════════════════════════
section "Escalation state machine"
# ════════════════════════════════════════════════════════════
# Tests _escalation_on_cert_result by injecting all state transitions
# and verifying which deliver_* function is called and what is stored.

_STMP3=$(mktemp -d)
STATE_FILE="$_STMP3/state-esc"
state_init

# Collect calls to the delivery hooks
_findings=(); _reminders=()
deliver_finding()  { _findings+=("$1:$2");  }
deliver_reminder() { _reminders+=("$1:$2"); }

TS=1748000000   # fixed timestamp so hours_since calculations are deterministic

# ── Fresh WARNING (no prior state) ───────────────────────────
new_issues=0; reminders=0; _findings=(); _reminders=()
_escalation_on_cert_result "mail.example.com" "443" "12" "Jun 1 2026" "Let's Encrypt" \
    "WARNING" "" "0" "OK" "$TS"
chk_eq "new WARNING triggers finding"     "${_findings[0]:-}" "mail.example.com:WARNING"
chk_eq "new WARNING: new_issues=1"        "$new_issues" "1"
chk_eq "new WARNING stored as WARN"       "$(state_get 'status:mail.example.com')" "WARN"

# ── Same WARNING within 23h (no reminder due) ────────────────
new_issues=0; reminders=0; _findings=(); _reminders=()
_escalation_on_cert_result "mail.example.com" "443" "12" "Jun 1 2026" "Let's Encrypt" \
    "WARNING" "WARN" "0" "OK" "$TS"
[ ${#_findings[@]}  -eq 0 ] && ok "WARNING unchanged within 23h: no finding"  || fail "unexpected finding"
[ ${#_reminders[@]} -eq 0 ] && ok "WARNING unchanged within 23h: no reminder" || fail "unexpected reminder"
chk_eq "WARNING unchanged: counters still 0" "$((new_issues + reminders))" "0"

# ── Escalation WARNING → CRITICAL ────────────────────────────
new_issues=0; reminders=0; _findings=(); _reminders=()
_escalation_on_cert_result "mail.example.com" "443" "5" "Jun 1 2026" "Let's Encrypt" \
    "CRITICAL" "WARN" "10" "OK" "$TS"
chk_eq "WARN→CRIT triggers finding"   "${_findings[0]:-}" "mail.example.com:CRITICAL"
chk_eq "WARN→CRIT stored as CRIT"     "$(state_get 'status:mail.example.com')" "CRIT"

# ── CRITICAL daily reminder (hours_since ≥ 23) ───────────────
new_issues=0; reminders=0; _findings=(); _reminders=()
_escalation_on_cert_result "mail.example.com" "443" "5" "Jun 1 2026" "Let's Encrypt" \
    "CRITICAL" "CRIT" "24" "OK" "$TS"
chk_eq "CRITICAL 24h reminder triggered"  "${_reminders[0]:-}" "mail.example.com:CRITICAL"
chk_eq "CRITICAL reminder counter"        "$reminders" "1"

# ── RENEWED: was CRIT, now OK ────────────────────────────────
new_issues=0; reminders=0; _findings=(); _reminders=()
_escalation_on_cert_result "mail.example.com" "443" "90" "Aug 1 2026" "Let's Encrypt" \
    "OK" "CRIT" "0" "OK" "$TS"
chk_eq "RENEWED triggers finding"     "${_findings[0]:-}" "mail.example.com:RENEWED"
chk_eq "RENEWED stored as OK"         "$(state_get 'status:mail.example.com')" "OK"
chk_eq "last_notify cleared on OK"    "$(state_get 'last_notify:mail.example.com')" ""

# ── OK → OK (no prior issue) stays silent ────────────────────
new_issues=0; reminders=0; _findings=(); _reminders=()
state_set "status:clean.example.com" "OK"
_escalation_on_cert_result "clean.example.com" "443" "90" "Aug 1 2026" "DigiCert" \
    "OK" "OK" "0" "OK" "$TS"
[ ${#_findings[@]}  -eq 0 ] && ok "OK→OK: no finding"  || fail "unexpected finding on OK→OK"
[ ${#_reminders[@]} -eq 0 ] && ok "OK→OK: no reminder" || fail "unexpected reminder on OK→OK"

# ── URGENT escalation and EXPIRED ────────────────────────────
new_issues=0; reminders=0; _findings=(); _reminders=()
state_set "status:urgent.example.com" "CRIT"
_escalation_on_cert_result "urgent.example.com" "443" "1" "May 27 2026" "DigiCert" \
    "URGENT" "CRIT" "0" "OK" "$TS"
chk_eq "CRIT→URGENT triggers finding" "${_findings[0]:-}" "urgent.example.com:URGENT"
chk_eq "URGENT stored"                "$(state_get 'status:urgent.example.com')" "URGENT"

new_issues=0; reminders=0; _findings=(); _reminders=()
state_set "status:expired.example.com" "URGENT"
_escalation_on_cert_result "expired.example.com" "443" "-3" "May 23 2026" "DigiCert" \
    "EXPIRED" "URGENT" "0" "OK" "$TS"
chk_eq "URGENT→EXPIRED triggers finding" "${_findings[0]:-}" "expired.example.com:EXPIRED"
chk_eq "EXPIRED stored"                  "$(state_get 'status:expired.example.com')" "EXPIRED"

rm -rf "$_STMP3"

# ════════════════════════════════════════════════════════════
section "Escalation: error path"
# ════════════════════════════════════════════════════════════

_STMP4=$(mktemp -d)
STATE_FILE="$_STMP4/state-err"
state_init

_findings=(); _reminders=()
deliver_finding()  { _findings+=("$1:$2");  }
deliver_reminder() { _reminders+=("$1:$2"); }

# First error → finding
new_issues=0; reminders=0; _findings=(); _reminders=()
_escalation_on_cert_error "unreachable.example.com" "443" "Unreachable" "" "0" "$TS"
chk_eq "first error triggers finding"   "${_findings[0]:-}" "unreachable.example.com:ERROR"
chk_eq "error stored as ERROR_CONNECT"  "$(state_get 'status:unreachable.example.com')" "ERROR_CONNECT"

# Same error within 23h → no repeat
new_issues=0; reminders=0; _findings=(); _reminders=()
_escalation_on_cert_error "unreachable.example.com" "443" "Unreachable" "ERROR_CONNECT" "10" "$TS"
[ ${#_findings[@]}  -eq 0 ] && ok "error within 23h: silent"  || fail "unexpected finding"

# Same error after 23h → daily reminder
new_issues=0; reminders=0; _findings=(); _reminders=()
_escalation_on_cert_error "unreachable.example.com" "443" "Unreachable" "ERROR_CONNECT" "24" "$TS"
chk_eq "error after 24h: reminder" "${_reminders[0]:-}" "unreachable.example.com:ERROR"

# Invalid port → one-time finding only (no daily reminder)
new_issues=0; reminders=0; _findings=(); _reminders=()
_escalation_on_cert_error "bad.example.com" "99999" "Invalid port" "" "0" "$TS"
chk_eq "invalid port triggers finding" "${_findings[0]:-}" "bad.example.com:ERROR"
chk_eq "invalid port stored"           "$(state_get 'status:bad.example.com')" "ERROR_PORT"

new_issues=0; reminders=0; _findings=(); _reminders=()
_escalation_on_cert_error "bad.example.com" "99999" "Invalid port" "ERROR_PORT" "999" "$TS"
[ ${#_findings[@]}  -eq 0 ] && ok "invalid port: no repeat even after 23h" || fail "unexpected repeat"

rm -rf "$_STMP4"

# ════════════════════════════════════════════════════════════
section "--check --json output"
# ════════════════════════════════════════════════════════════

SCRIPT="$(dirname "$0")/../src/check-certs.sh"

# Valid host – check JSON structure and content fields
if out=$("$SCRIPT" --check --json example.com:443 2>/dev/null); then
    chk_eq "--json has host field"         "$(echo "$out" | grep -c '"host"')"   "1"
    chk_eq "--json has status field"       "$(echo "$out" | grep -c '"status"')" "1"
    chk_eq "--json has days field"         "$(echo "$out" | grep -c '"days"')"   "1"
    chk_eq "--json has chain_status field" "$(echo "$out" | grep -c '"chain_status"')" "1"
    chk_eq "--json has expiry_ts field"    "$(echo "$out" | grep -c '"expiry_ts"')"    "1"
    # days and expiry_ts must be bare integers (not quoted)
    days_raw=$(echo "$out" | grep '"days"' | grep -oP '"days":\s*\K-?[0-9]+')
    [[ "$days_raw" =~ ^-?[0-9]+$ ]] && ok "--json days is unquoted integer" \
                                     || fail "--json days not a bare integer: '$days_raw'"
    ts_raw=$(echo "$out" | grep '"expiry_ts"' | grep -oP '"expiry_ts":\s*\K[0-9]+')
    [[ "$ts_raw" =~ ^[0-9]+$ ]] && ok "--json expiry_ts is unquoted integer" \
                                  || fail "--json expiry_ts not a bare integer: '$ts_raw'"
    # Validate JSON is parseable
    if command -v python3 &>/dev/null; then
        echo "$out" | python3 -m json.tool > /dev/null 2>&1 \
            && ok "--json output is valid JSON" \
            || fail "--json output is not valid JSON"
    else
        skip "--json JSON validation (python3 not available)"
    fi
else
    skip "--check --json (no network)"
fi

# Error case – unreachable host produces JSON with status=ERROR
if out=$("$SCRIPT" --check --json 127.0.0.1:19999 2>/dev/null); then
    chk_eq "--json error has ERROR status" "$(echo "$out" | grep -c '"ERROR"')" "1"
    chk_eq "--json error has reason field" "$(echo "$out" | grep -c '"reason"')" "1"
    if command -v python3 &>/dev/null; then
        echo "$out" | python3 -m json.tool > /dev/null 2>&1 \
            && ok "--json error output is valid JSON" \
            || fail "--json error output is not valid JSON"
    fi
fi

# ════════════════════════════════════════════════════════════
section "--check --nagios exit codes"
# ════════════════════════════════════════════════════════════

# OK host → exit 0, output starts with "OK"
if "$SCRIPT" --check --nagios example.com:443 > /tmp/_nagios_out 2>/dev/null; then
    grep -q '^OK' /tmp/_nagios_out \
        && ok "--nagios OK: output starts with OK" \
        || fail "--nagios OK: unexpected output: $(cat /tmp/_nagios_out)"
    ok "--nagios OK: exit code 0"
else
    ec=$?
    skip "--nagios OK (exit $ec, possibly expired cert or no network)"
fi
rm -f /tmp/_nagios_out

# Unreachable → exit 3, output starts with "UNKNOWN"
"$SCRIPT" --check --nagios 127.0.0.1:19999 > /tmp/_nagios_out 2>/dev/null
ec=$?
chk_eq "--nagios unreachable: exit 3"          "$ec" "3"
grep -q '^UNKNOWN' /tmp/_nagios_out \
    && ok "--nagios unreachable: output starts with UNKNOWN" \
    || fail "--nagios unreachable: unexpected output: $(cat /tmp/_nagios_out)"
rm -f /tmp/_nagios_out

# ════════════════════════════════════════════════════════════
section "--check kv exit codes"
# ════════════════════════════════════════════════════════════

# kv output: expiry_ts must be present and be a bare integer
if kv_out=$("$SCRIPT" --check example.com:443 2>/dev/null); then
    grep -q "^expiry_ts=" <<< "$kv_out" \
        && ok "--check kv has expiry_ts field" \
        || fail "--check kv: expiry_ts field missing"
    ts_val=$(grep "^expiry_ts=" <<< "$kv_out" | cut -d= -f2)
    [[ "$ts_val" =~ ^[0-9]+$ ]] && ok "--check kv expiry_ts is a Unix timestamp" \
                                 || fail "--check kv expiry_ts is not an integer: '$ts_val'"
else
    skip "--check kv expiry_ts (no network)"
fi

# Unreachable host → exit 2
"$SCRIPT" --check 127.0.0.1:19999 > /dev/null 2>&1
chk_eq "--check unreachable: exit 2" "$?" "2"


# ════════════════════════════════════════════════════════════
section "--scan discovery mode"
# ════════════════════════════════════════════════════════════

SCRIPT="$(dirname "$0")/../src/check-certs.sh"

# --scan with no argument → exit 1, usage on stderr
"$SCRIPT" --scan > /dev/null 2>/tmp/_scan_err
chk_eq "--scan no arg: exit 1" "$?" "1"
grep -qi "usage\|scan" /tmp/_scan_err && ok "--scan no arg: usage message on stderr"     || fail "--scan no arg: no usage message"
rm -f /tmp/_scan_err

# --scan with unreachable host → exit 1, no certificate found
"$SCRIPT" --scan 127.0.0.1 > /tmp/_scan_out 2>/dev/null
ec=$?
chk_eq "--scan unreachable: exit 1" "$ec" "1"
rm -f /tmp/_scan_out

# --scan against example.com (live, if reachable)
if out=$("$SCRIPT" --scan example.com 2>/dev/null); then
    # Output should mention port 443
    grep -q ":443" <<< "$out"         && ok "--scan finds port 443 on example.com"         || fail "--scan: port 443 not mentioned in output"
    # The servers.conf snippet should contain example.com:443
    grep -q "example.com:443" <<< "$out"         && ok "--scan snippet contains example.com:443"         || fail "--scan: snippet missing example.com:443"
    # Exit 0 when certificates found
    ok "--scan reachable host: exit 0"
else
    skip "--scan live test (no network)"
fi

# ════════════════════════════════════════════════════════════
section "check-certs-ntfy.sh: syntax and config validation"
# ════════════════════════════════════════════════════════════

NTFY_SCRIPT="$(dirname "$0")/../src/check-certs-ntfy.sh"

# Syntax check
bash -n "$NTFY_SCRIPT" 2>/dev/null     && ok "check-certs-ntfy.sh: syntax OK"     || fail "check-certs-ntfy.sh: syntax error"

# Missing NTFY_URL → exit 1 with error message
out=$(NTFY_URL="" NTFY_TOPIC="" bash "$NTFY_SCRIPT" 2>&1) && ec=0 || ec=$?
chk_eq "ntfy: missing NTFY_URL exit 1" "$ec" "1"
echo "$out" | grep -qi "ntfy_url\|ntfy.sh"     && ok "ntfy: missing NTFY_URL error message mentions NTFY_URL"     || fail "ntfy: missing NTFY_URL: unexpected message: $out"

# NTFY_URL set but NTFY_TOPIC missing → exit 1
out=$(NTFY_URL="https://ntfy.sh" NTFY_TOPIC="" bash "$NTFY_SCRIPT" 2>&1) && ec=0 || ec=$?
chk_eq "ntfy: missing NTFY_TOPIC exit 1" "$ec" "1"
echo "$out" | grep -qi "ntfy_topic"     && ok "ntfy: missing NTFY_TOPIC error message mentions NTFY_TOPIC"     || fail "ntfy: unexpected message: $out"

# ════════════════════════════════════════════════════════════
printf '\n══  Summary\n'
printf '  Passed: %d   Failed: %d   Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -eq 0 ]; then
    printf '  ✓ All tests passed.\n\n'
    exit 0
else
    printf '  ✗ %d test(s) FAILED.\n\n' "$FAIL"
    exit 1
fi
