#!/bin/bash

# ============================================================
#  check-certs.sh – SSL certificate checker
#  Version 2.5.4
#
#  STANDALONE USAGE (terminal table, macOS + Linux):
#    check-certs [hostname[:port[:proto]]]          Terminal table (IPv6: [addr]:port[:proto])
#    check-certs --check [--nagios|--json] <host>  Scripting / monitoring integration
#    check-certs --scan <hostname>                 Probe common TLS ports (onboarding helper)
#    check-certs --list | --version | --help
#
#  WRAPPER INTERFACE (source this script to build a new variant):
#
#    1. Set configuration variables before sourcing:
#         SERVER_FILE   – path to servers.conf
#         STATE_FILE    – path to state file (empty = no state)
#         TIMEOUT       – connection timeout in seconds
#         WARN_DAYS     – warning threshold in days
#         CRIT_DAYS     – critical threshold in days
#         URGENT_DAYS   – urgent threshold in days (0 = disabled)
#         CA_MAX_LEN    – CA name truncation length
#         MAX_JOBS      – max parallel checks
#
#    2. Source this script:
#         source /path/to/check-certs.sh
#
#    3. Call setup functions:
#         configure_wrapper        – apply defaults, reset counters
#         state_init               – create state file if needed
#
#    4. Define the two delivery hooks:
#         deliver_finding  hostname status days_left short_date ca_name chain_status
#         deliver_reminder hostname status days_left short_date ca_name chain_status
#
#    5. Optionally define on_group group_name
#       (called when a [Group] section header is encountered)
#
#    6. Wire and run:
#         install_escalation_hooks – connect escalation to delivery hooks
#         run_server_loop "$SERVER_FILE"
#
#  STATUS VALUES passed to deliver_finding / deliver_reminder:
#    RENEWED  – certificate was non-OK, is now valid again
#    WARNING  – days_left < WARN_DAYS
#    CRITICAL – days_left < CRIT_DAYS, or chain broken with leaf OK
#    URGENT   – days_left < URGENT_DAYS
#    EXPIRED  – days_left < 0
#    ERROR    – unreachable or invalid port; ca_name carries the reason
#
#  Requirements (macOS): openssl, coreutils (brew install coreutils)
#  Requirements (Linux): openssl
# ============================================================

# ── Version ──────────────────────────────────────────────────
VERSION="2.5.4"

# ── Date command ─────────────────────────────────────────────
# macOS: gdate via coreutils; Linux: GNU date natively
if command -v gdate &>/dev/null; then
    DATE_CMD="gdate"
elif date --version &>/dev/null 2>&1; then
    DATE_CMD="date"
else
    echo "Error: neither 'gdate' nor GNU 'date' found. Install coreutils." >&2
    exit 1
fi

# ── Counters (reset by configure_wrapper) ────────────────────
total=0; errors=0; warned=0; new_issues=0; reminders=0

# ── Default configuration ────────────────────────────────────
# Wrappers may override any of these before calling configure_wrapper,
# or call configure_wrapper first and then override selectively.
_CC_DEFAULTS_SERVER_FILE="$(dirname "${BASH_SOURCE[0]}")/servers.conf"
_CC_DEFAULTS_STATE_FILE=""
_CC_DEFAULTS_TIMEOUT=5
_CC_DEFAULTS_WARN_DAYS=15
_CC_DEFAULTS_CRIT_DAYS=7
_CC_DEFAULTS_URGENT_DAYS=2
_CC_DEFAULTS_CA_MAX_LEN=30
_CC_DEFAULTS_MAX_JOBS=10

# configure_wrapper – load config file, then apply defaults for any
# variable not already set. Call this after sourcing, before state_init
# and install_escalation_hooks.
configure_wrapper() {
    # Load config file from the same directory as check-certs.sh
    local conf_file
    conf_file="$(dirname "${BASH_SOURCE[0]}")/check-certs.conf"
    # shellcheck source=check-certs.conf
    [ -f "$conf_file" ] && source "$conf_file"

    # Apply defaults for anything not set in the config file
    : "${SERVER_FILE:=$_CC_DEFAULTS_SERVER_FILE}"
    : "${STATE_FILE:=$_CC_DEFAULTS_STATE_FILE}"
    : "${TIMEOUT:=$_CC_DEFAULTS_TIMEOUT}"
    : "${WARN_DAYS:=$_CC_DEFAULTS_WARN_DAYS}"
    : "${CRIT_DAYS:=$_CC_DEFAULTS_CRIT_DAYS}"
    : "${URGENT_DAYS:=$_CC_DEFAULTS_URGENT_DAYS}"
    : "${CA_MAX_LEN:=$_CC_DEFAULTS_CA_MAX_LEN}"
    : "${MAX_JOBS:=$_CC_DEFAULTS_MAX_JOBS}"
    # Reset counters
    total=0; errors=0; warned=0; new_issues=0; reminders=0
}

# ── State functions ──────────────────────────────────────────
# All no-ops when STATE_FILE is empty.
#
# STATE_FILE is treated as a DIRECTORY path. Each host gets its own
# file inside it, named by sanitising the hostname (replacing every
# character that is not a letter, digit, dot, or hyphen with "_").
# This avoids rewriting a single shared file on every state change —
# each write touches only one small file, making the engine safe and
# fast even at hundreds of hosts.
#
# Key format used by callers:
#   "status:<hostname>"       – last known status string
#   "days:<hostname>"         – days left at last check
#   "last_notify:<hostname>"  – Unix timestamp of last notification
#
# The key is split on the first colon: the part before the colon is
# the field name stored inside the host file; the part after is the
# hostname used as the filename.

# _state_file <key>  →  prints the full path for a host's state file.
# Returns nothing (and callers short-circuit) when STATE_FILE is empty.
_state_file() {
    [ -z "$STATE_FILE" ] && return
    local host="${1#*:}"            # everything after the first colon
    local safe
    # Replace any character that is not a letter, digit, dot, or hyphen
    # with an underscore so the result is always a safe filename.
    safe="${host//[^a-zA-Z0-9.\-]/_}"
    printf '%s/%s' "$STATE_FILE" "$safe"
}

state_init() {
    [ -z "$STATE_FILE" ] && return
    # Migrate flat state file from v2.4.x to per-host directory layout
    # if needed. No-op on fresh installs or already-migrated setups.
    state_migrate
    mkdir -p "$STATE_FILE"
}

# state_get <key>  →  prints the stored value, or "" if absent.
state_get() {
    [ -z "$STATE_FILE" ] && echo "" && return
    local file field
    file=$(_state_file "$1")
    field="${1%%:*}"
    # Each host file holds lines of the form "field=value".
    grep "^${field}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2-
}

# state_set <key> <value>  →  writes value; creates host file if needed.
state_set() {
    [ -z "$STATE_FILE" ] && return
    local key="$1" value="$2"
    local file field tmpfile
    file=$(_state_file "$key")
    field="${key%%:*}"
    tmpfile=$(mktemp)
    grep -v "^${field}=" "$file" > "$tmpfile" 2>/dev/null || true
    printf '%s=%s\n' "$field" "$value" >> "$tmpfile"
    mv "$tmpfile" "$file"
}

# state_delete <key>  →  removes the field; leaves the host file in place.
state_delete() {
    [ -z "$STATE_FILE" ] && return
    local file field tmpfile
    file=$(_state_file "$1")
    field="${1%%:*}"
    [ -f "$file" ] || return
    tmpfile=$(mktemp)
    grep -v "^${field}=" "$file" > "$tmpfile" 2>/dev/null || true
    mv "$tmpfile" "$file"
}

# ── State migration helper ───────────────────────────────────
# state_migrate – silently upgrades a 2.4.x flat state file to the 2.5+
# per-host directory layout when a wrapper starts.
#
# Called by wrappers automatically from state_init.  Safe to call on a
# fresh install (the flat file won't exist) and on repeated runs after
# migration (already-migrated entries are skipped).
#
# Migration logic:
#   Old flat file:  /var/lib/check-certs/state-mail
#   New directory:  /var/lib/check-certs/state-mail/
#     containing:     /var/lib/check-certs/state-mail/<hostname>
#
# Old key format:  "status:mail.example.com=WARNING"
#   →  field "status", host "mail.example.com", value "WARNING"
# The three possible field prefixes are: status: days: last_notify:
state_migrate() {
    [ -z "$STATE_FILE" ] && return

    # If STATE_FILE does not exist as a regular file, nothing to migrate.
    # (Either it's already a directory, or this is a fresh install.)
    [ -f "$STATE_FILE" ] || return

    local old_flat="$STATE_FILE"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    # Parse the flat file and group entries by hostname into tmp files.
    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        local field host value safe
        # Lines look like: "status:mail.example.com=WARNING"
        field="${line%%:*}"          # "status"
        local rest="${line#*:}"      # "mail.example.com=WARNING"
        host="${rest%%=*}"           # "mail.example.com"
        value="${rest#*=}"           # "WARNING"
        safe="${host//[^a-zA-Z0-9.\-]/_}"
        printf '%s=%s\n' "$field" "$value" >> "$tmp_dir/$safe"
    done < "$old_flat"

    # Move per-host files into the state directory.
    # Rename the flat file to a backup first so the directory can take
    # the same path.
    local backup="${old_flat}.pre-2.5.bak"
    mv "$old_flat" "$backup"
    mkdir -p "$STATE_FILE"
    if [ -d "$tmp_dir" ]; then
        for hfile in "$tmp_dir"/*; do
            [ -f "$hfile" ] || continue
            cp "$hfile" "$STATE_FILE/$(basename "$hfile")"
        done
        rm -rf "$tmp_dir"
    fi

    printf 'check-certs: migrated state file to per-host directory layout\n' >&2
    printf 'check-certs: old flat file backed up to %s\n' "$backup" >&2
}

# ── CA name extraction ───────────────────────────────────────
# Prefers CN=, falls back to O=. Compatible with macOS and Linux
# openssl output formats (CN=value and CN = value).
extract_ca() {
    local issuer="$1" ca

    ca=$(echo "$issuer" | sed 's/.*[,= /]CN[[:space:]]*=[[:space:]]*//' \
                        | sed 's/[,/].*//'                              \
                        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [ -z "$ca" ] || echo "$ca" | grep -q "issuer="; then
        ca=$(echo "$issuer" | sed 's/.*[,= /]O[[:space:]]*=[[:space:]]*//' \
                            | sed 's/[,/].*//'                             \
                            | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fi

    if [ -z "$ca" ] || echo "$ca" | grep -q "issuer="; then
        ca="Unknown"
    fi

    echo "${ca:0:${CA_MAX_LEN:-30}}"
}


# ── Host spec parser ─────────────────────────────────────────
# parse_hostspec <spec> <var_host> <var_port> <var_proto>
#
# Parses a "hostspec" in one of these forms:
#   hostname:port
#   hostname:port:proto
#   [IPv6address]:port
#   [IPv6address]:port:proto
#
# On success, sets the three named variables in the caller's scope
# and returns 0.  On failure (invalid format) returns 1 without
# touching the variables.
#
# Examples:
#   parse_hostspec "mail.example.com:587:smtp"   h p pr  → h=mail.example.com p=587 pr=smtp
#   parse_hostspec "[::1]:443"                   h p pr  → h=::1              p=443 pr=
parse_hostspec() {
    local _spec="$1" _vhost="$2" _vport="$3" _vproto="$4"
    local _h="" _p="" _pr=""

    if [[ "$_spec" =~ ^\[([^]]+)\]:([0-9]+)(:([a-z]+))?$ ]]; then
        # IPv6 bracketed form: [addr]:port[:proto]
        _h="${BASH_REMATCH[1]}"
        _p="${BASH_REMATCH[2]}"
        _pr="${BASH_REMATCH[4]}"
    elif [[ "$_spec" =~ ^([^:]+):([0-9]+)(:([a-z]+))?$ ]]; then
        # Hostname or IPv4: host:port[:proto]
        _h="${BASH_REMATCH[1]}"
        _p="${BASH_REMATCH[2]}"
        _pr="${BASH_REMATCH[4]}"
    else
        return 1
    fi

    printf -v "$_vhost"  '%s' "$_h"
    printf -v "$_vport"  '%s' "$_p"
    printf -v "$_vproto" '%s' "$_pr"
    return 0
}

# ── STARTTLS protocol detection ──────────────────────────────
# Returns the -starttls argument for openssl s_client, or empty
# string for plain TLS. Explicit proto overrides port detection.
_starttls_proto() {
    local port="$1" proto="${2:-}"

    # Explicit protocol override
    # Plain-TLS aliases (self-documenting names that produce no -starttls arg)
    case "$proto" in
        tls|https|ldaps|imaps|pop3s|smtps|ftps) return ;;
        smtp|submission) echo "smtp"; return ;;
        imap)            echo "imap"; return ;;
        pop3)            echo "pop3"; return ;;
        ldap)            echo "ldap"; return ;;
        ftp)             echo "ftp";  return ;;
        xmpp)            echo "xmpp"; return ;;
    esac

    # No explicit proto – auto-detect by port number
    case "$port" in
        25|587)     echo "smtp" ;;
        143)        echo "imap" ;;
        110)        echo "pop3" ;;
        389)        echo "ldap" ;;
        21)         echo "ftp"  ;;
        5222)       echo "xmpp" ;;
        # 636=LDAPS, 993=IMAPS, 995=POP3S, 443, 8443 → plain TLS, no output
    esac
}

# ── Certificate check worker (runs in background) ────────────
# Writes KEY=value pairs to a temp file, one per line.
# RESULT fields: TYPE HOST PORT PROTO DAYS EXPIRY EXPIRY_TS CA STATUS CHAIN
# ERROR fields:  TYPE HOST PORT PROTO REASON
#
# Reading back with _worker_field <file> <KEY> is safe regardless
# of field order or future additions.
_check_cert_worker() {
    local hostname="$1" port="$2" outfile="$3" proto="${4:-}"
    # Per-host threshold overrides (fall back to globals if not set)
    local h_warn="${5:-$WARN_DAYS}"
    local h_crit="${6:-$CRIT_DAYS}"
    local h_urgent="${7:-$URGENT_DAYS}"
    local h_timeout="${8:-$TIMEOUT}"
    local timeout_cmd=""
    local current_ts
    current_ts=$($DATE_CMD +%s)

    if command -v gtimeout &>/dev/null; then
        timeout_cmd="gtimeout ${h_timeout:-5}"
    elif command -v timeout &>/dev/null; then
        timeout_cmd="timeout ${h_timeout:-5}"
    fi

    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        printf 'TYPE=ERROR\nHOST=%s\nPORT=%s\nPROTO=%s\nREASON=Invalid port\n' \
            "$hostname" "$port" "$proto" > "$outfile"
        return
    fi

    # ── Determine STARTTLS args ───────────────────────────────
    local starttls_proto starttls_args=()
    starttls_proto=$(_starttls_proto "$port" "$proto")
    [ -n "$starttls_proto" ] && starttls_args=(-starttls "$starttls_proto")

    # ── Leaf certificate ─────────────────────────────────────
    # SNI (-servername) is only meaningful for DNS hostnames.
    # Skip it for bare IPv4/IPv6 addresses to avoid openssl warnings.
    local sni_args=()
    if [[ ! "$hostname" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && \
       [[ ! "$hostname" =~ : ]]; then
        sni_args=(-servername "$hostname")
    fi

    local cert_data
    # shellcheck disable=SC2086  # timeout_cmd intentionally word-splits
    cert_data=$($timeout_cmd openssl s_client \
        -connect "$hostname:$port" "${sni_args[@]}" \
        "${starttls_args[@]}" \
        </dev/null 2>/dev/null \
        | openssl x509 -noout -enddate -issuer 2>/dev/null)

    if [ -z "$cert_data" ]; then
        printf 'TYPE=ERROR\nHOST=%s\nPORT=%s\nPROTO=%s\nREASON=Unreachable\n' \
            "$hostname" "$port" "$starttls_proto" > "$outfile"
        return
    fi

    # ── Full chain verification ──────────────────────────────
    local chain_output chain_status
    # shellcheck disable=SC2086  # timeout_cmd intentionally word-splits
    chain_output=$($timeout_cmd openssl s_client \
        -connect "$hostname:$port" "${sni_args[@]}" \
        "${starttls_args[@]}" \
        -verify 5 -verify_return_error \
        </dev/null 2>&1)

    if echo "$chain_output" | grep -q "Verify return code: 0 (ok)"; then
        chain_status="OK"
    else
        local reason
        reason=$(echo "$chain_output" \
            | grep "Verify return code:" \
            | sed 's/.*Verify return code: [0-9]* (\(.*\))/\1/' \
            | head -1)
        chain_status="${reason:-Chain invalid}"
    fi

    # ── Parse leaf cert data ─────────────────────────────────
    local expiry_date_raw issuer_raw ca_name
    expiry_date_raw=$(echo "$cert_data" | grep "^notAfter=" | cut -d= -f2)
    issuer_raw=$(echo "$cert_data" | grep "^issuer=")
    ca_name=$(extract_ca "$issuer_raw")

    local expiry_date_clean short_date expiry_ts days_left
    expiry_date_clean=$(echo "$expiry_date_raw" | sed 's/ GMT$//')
    short_date=$(echo "$expiry_date_raw" | awk '{print $1, $2, $4}')
    expiry_ts=$($DATE_CMD -d "$expiry_date_clean" +%s 2>/dev/null)
    if [ -z "$expiry_ts" ]; then
        printf 'TYPE=ERROR\nHOST=%s\nPORT=%s\nPROTO=%s\nREASON=Could not parse expiry date\n' \
            "$hostname" "$port" "$starttls_proto" > "$outfile"
        return
    fi
    days_left=$(( (expiry_ts - current_ts) / 86400 ))

    # ── Determine status ─────────────────────────────────────
    local status
    if   [ "$days_left" -lt 0 ]; then
        status="EXPIRED"
    elif [ "${h_urgent:-0}" -gt 0 ] && [ "$days_left" -lt "$h_urgent" ]; then
        status="URGENT"
    elif [ "$days_left" -lt "${h_crit:-0}" ]; then
        status="CRITICAL"
    elif [ "$days_left" -lt "${h_warn:-15}" ]; then
        status="WARNING"
    else
        status="OK"
    fi

    # Broken chain with otherwise-OK leaf → CRITICAL
    [ "$chain_status" != "OK" ] && [ "$status" = "OK" ] && status="CRITICAL"

    printf 'TYPE=RESULT\nHOST=%s\nPORT=%s\nPROTO=%s\nDAYS=%s\nEXPIRY=%s\nEXPIRY_TS=%s\nCA=%s\nSTATUS=%s\nCHAIN=%s\n' \
        "$hostname" "$port" "$starttls_proto" "$days_left" "$short_date" "$expiry_ts" \
        "$ca_name" "$status" "$chain_status" > "$outfile"
}

# ── Worker output reader ─────────────────────────────────────
# Reads a single KEY=value field from a worker output file.
# Usage: value=$(_worker_field "$file" KEY)
_worker_field() {
    grep "^${2}=" "$1" | cut -d= -f2-
}

# ── Dispatch result to hooks ─────────────────────────────────
# Reads a worker output file, increments the total counter, looks up
# prior state, and calls on_cert_result or on_cert_error with all
# args the escalation logic needs (including hours_since and current_ts).
_dispatch_result() {
    local outfile="$1"
    local current_ts type hostname port
    current_ts=$($DATE_CMD +%s)
    type=$(_worker_field "$outfile" TYPE)
    hostname=$(_worker_field "$outfile" HOST)
    port=$(_worker_field "$outfile" PORT)
    total=$((total + 1))

    local prev_status last_seen hours_since
    prev_status=$(state_get "status:${hostname}")
    last_seen=$(state_get "last_notify:${hostname}")
    hours_since=$(( (current_ts - ${last_seen:-0}) / 3600 ))

    if [ "$type" = "ERROR" ]; then
        local reason
        reason=$(_worker_field "$outfile" REASON)
        on_cert_error "$hostname" "$port" "$reason" "$prev_status" "$hours_since" "$current_ts"
        errors=$((errors + 1))
        return
    fi

    local days_left short_date ca_name status chain_status
    days_left=$(_worker_field "$outfile" DAYS)
    short_date=$(_worker_field "$outfile" EXPIRY)
    ca_name=$(_worker_field "$outfile" CA)
    status=$(_worker_field "$outfile" STATUS)
    chain_status=$(_worker_field "$outfile" CHAIN)

    [ "$status" != "OK" ] && warned=$((warned + 1))

    on_cert_result \
        "$hostname" "$port" "$days_left" "$short_date" \
        "$ca_name" "$status" "$prev_status" "$hours_since" "$chain_status" "$current_ts"
}

# ── Server loop ──────────────────────────────────────────────
# Reads a servers.conf-format file. Fires up to MAX_JOBS workers
# concurrently (phase 1), then replays results in original file
# order by calling on_cert_result / on_cert_error (phase 2).
# Group headers call on_group; format errors call on_format_error.
run_server_loop() {
    local file="$1"
    [ -f "$file" ] || { echo "Error: server file '$file' not found." >&2; exit 1; }

    local tmpdir
    tmpdir=$(mktemp -d)

    local -a order=() pids=()
    local idx=0 running=0
    local h p pr

    while IFS= read -r line || [ -n "$line" ]; do
        # Trim leading and trailing whitespace without forking a subshell
        line="${line#"${line%%[! $'\t']*}"}"
        line="${line%"${line##*[! $'\t']}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            order+=("GROUP:${BASH_REMATCH[1]}")
            continue
        fi

        # Parse host:port[:proto] then optional key=value overrides
        local _hostpart _overrides
        _hostpart="${line%% *}"
        _overrides="${line#"$_hostpart"}"
        _overrides="${_overrides# }"

        if parse_hostspec "$_hostpart" h p pr; then

            # Parse per-host overrides: warn=N crit=N urgent=N timeout=N
            local ow="" oc="" ou="" ot=""
            for _kv in $_overrides; do
                case "$_kv" in
                    warn=*)    ow="${_kv#warn=}"    ;;
                    crit=*)    oc="${_kv#crit=}"    ;;
                    urgent=*)  ou="${_kv#urgent=}"  ;;
                    timeout=*) ot="${_kv#timeout=}" ;;
                esac
            done
            # Validate override values are integers; discard if not
            [[ "$ow" =~ ^[0-9]+$ ]] || ow=""
            [[ "$oc" =~ ^[0-9]+$ ]] || oc=""
            [[ "$ou" =~ ^[0-9]+$ ]] || ou=""
            [[ "$ot" =~ ^[0-9]+$ ]] || ot=""

            # Store overrides alongside index so dispatch can read them
            order+=("HOST:$idx")

            # Semaphore: block until one job finishes before launching
            # another when MAX_JOBS concurrent workers are already running.
            # 'wait -n' (Bash 4.3+) waits for any child; the fallback
            # explicitly waits for the oldest dispatched pid.
            if [ "$running" -ge "${MAX_JOBS:-10}" ]; then
                if wait -n 2>/dev/null; then :
                else wait "${pids[$(( idx - running ))]}" 2>/dev/null || true
                fi
                running=$((running - 1))
            fi

            _check_cert_worker "$h" "$p" "$tmpdir/$idx" "$pr" \
                "${ow:-$WARN_DAYS}" "${oc:-$CRIT_DAYS}" \
                "${ou:-$URGENT_DAYS}" "${ot:-$TIMEOUT}" &
            pids+=($!); running=$((running + 1)); idx=$((idx + 1))
        else
            order+=("FORMAT_ERROR:$_hostpart")
        fi
    done < "$file"

    # Wait for all remaining workers
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done

    # Replay in original order; cache on_group availability once
    local entry kind value
    local _has_on_group=false
    declare -f on_group > /dev/null 2>&1 && _has_on_group=true
    for entry in "${order[@]}"; do
        kind="${entry%%:*}"; value="${entry#*:}"
        case "$kind" in
            GROUP)        [ "$_has_on_group" = true ] && on_group "$value" ;;
            HOST)         _dispatch_result "$tmpdir/$value" ;;
            FORMAT_ERROR) on_format_error "$value"; errors=$((errors + 1)) ;;
        esac
    done

    rm -rf "$tmpdir"
}

# ════════════════════════════════════════════════════════════
#  ESCALATION LOGIC
#  Shared by all automation wrappers. Decides whether a result
#  is a new finding or a reminder, updates state, and calls
#  the two delivery hooks that the wrapper must define:
#
#    deliver_finding  hostname status days_left short_date ca_name chain_status
#    deliver_reminder hostname status days_left short_date ca_name chain_status
#
#  Wrappers activate this by calling install_escalation_hooks
#  after sourcing and configuring.
# ════════════════════════════════════════════════════════════

_escalation_on_cert_error() {
    local hostname="$1" port="$2" reason="$3" prev_status="$4" hours_since="$5"
    local current_ts="${6:-}"
    [ -z "$current_ts" ] && current_ts=$($DATE_CMD +%s)

    if [ "$reason" = "Invalid port" ]; then
        if [ "$prev_status" != "ERROR_PORT" ]; then
            new_issues=$((new_issues + 1))
            state_set "status:${hostname}" "ERROR_PORT"
            state_set "last_notify:${hostname}" "$current_ts"
            deliver_finding "$hostname" "ERROR" "-" "-" "$reason" "OK"
        fi
        return
    fi

    # Unreachable – new or daily reminder
    if [ "$prev_status" != "ERROR_CONNECT" ]; then
        new_issues=$((new_issues + 1))
        state_set "status:${hostname}" "ERROR_CONNECT"
        state_set "last_notify:${hostname}" "$current_ts"
        deliver_finding "$hostname" "ERROR" "-" "-" "$reason" "OK"
    elif [ "$hours_since" -ge 23 ]; then
        reminders=$((reminders + 1))
        state_set "last_notify:${hostname}" "$current_ts"
        deliver_reminder "$hostname" "ERROR" "-" "-" "$reason" "OK"
    fi
}

_escalation_on_cert_result() {
    local hostname="$1" port="$2" days_left="$3" short_date="$4"
    local ca_name="$5" status="$6" prev_status="$7" hours_since="$8"
    local chain_status="${9:-OK}"
    local current_ts="${10:-}"
    [ -z "$current_ts" ] && current_ts=$($DATE_CMD +%s)

    # Renewed certificate
    if [ "$status" = "OK" ]; then
        if [ -n "$prev_status" ] && [ "$prev_status" != "OK" ]; then
            new_issues=$((new_issues + 1))
            deliver_finding \
                "$hostname" "RENEWED" "$days_left" "$short_date" \
                "$ca_name" "$chain_status"
        fi
        state_set "status:${hostname}" "OK"
        state_set "days:${hostname}" "$days_left"
        state_delete "last_notify:${hostname}"
        return
    fi

    # New escalation level or daily reminder for persistent issues
    local is_new=false
    if   [ "$prev_status" != "WARN"    ] && [ "$status" = "WARNING"  ]; then is_new=true
    elif [ "$prev_status" != "CRIT"    ] && [ "$status" = "CRITICAL" ]; then is_new=true
    elif [ "$prev_status" != "URGENT"  ] && [ "$status" = "URGENT"   ]; then is_new=true
    elif [ "$prev_status" != "EXPIRED" ] && [ "$status" = "EXPIRED"  ]; then is_new=true
    elif { [ "$status" = "CRITICAL" ] || [ "$status" = "URGENT" ] || \
           [ "$status" = "EXPIRED"  ]; } && [ "$hours_since" -ge 23 ]; then
        reminders=$((reminders + 1))
        state_set "last_notify:${hostname}" "$current_ts"
        deliver_reminder \
            "$hostname" "$status" "$days_left" "$short_date" \
            "$ca_name" "$chain_status"
    fi

    if [ "$is_new" = true ]; then
        new_issues=$((new_issues + 1))
        state_set "last_notify:${hostname}" "$current_ts"
        deliver_finding \
            "$hostname" "$status" "$days_left" "$short_date" \
            "$ca_name" "$chain_status"
    fi

    # Persist current status using abbreviated keys for CRITICAL and WARNING
    # (CRIT/WARN). Callers that read state must translate back — see the
    # state_status mapping in mail, notify, and pushover wrappers.
    case "$status" in
        EXPIRED)  state_set "status:${hostname}" "EXPIRED" ;;
        URGENT)   state_set "status:${hostname}" "URGENT"  ;;
        CRITICAL) state_set "status:${hostname}" "CRIT"    ;;
        *)        state_set "status:${hostname}" "WARN"    ;;
    esac
    state_set "days:${hostname}" "$days_left"
}

# install_escalation_hooks – defines on_cert_result, on_cert_error,
# and on_format_error as thin wrappers around the shared escalation
# logic. Call this after configure_wrapper and state_init, and before
# run_server_loop. Wrappers that need to log every cert (not just
# findings) can redefine on_cert_result after calling this function.
#
# _dispatch_result passes current_ts as arg 6 to on_cert_error and
# arg 10 to on_cert_result so the timestamp is computed once per host,
# not once per hook call.
install_escalation_hooks() {
    on_cert_error() { _escalation_on_cert_error "$@"; }
    on_cert_result() { _escalation_on_cert_result "$@"; }
    on_format_error() {
        # Note: run_server_loop also increments $errors for FORMAT_ERROR entries,
        # so we only deliver the finding here without double-counting.
        deliver_finding "$1" "ERROR" "-" "-" "Invalid format in servers.conf" "OK"
    }
}

# ════════════════════════════════════════════════════════════
#  TERMINAL OUTPUT
#  Everything below executes only when this script is run
#  directly. When sourced by a wrapper the BASH_SOURCE guard
#  prevents any output or side effects.
# ════════════════════════════════════════════════════════════
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

# ── Load config file ─────────────────────────────────────────
_conf="$(dirname "$0")/check-certs.conf"
# shellcheck source=check-certs.conf
[ -f "$_conf" ] && source "$_conf"
unset _conf

# ── Terminal defaults (only applied if not set by config) ────
: "${SERVER_FILE:=$(dirname "$0")/servers.conf}"
: "${STATE_FILE:=}"
: "${TIMEOUT:=5}"
: "${WARN_DAYS:=15}"
: "${CRIT_DAYS:=7}"
: "${URGENT_DAYS:=2}"
: "${CA_MAX_LEN:=22}"  # narrower than wrapper default (30) — fits the fixed-width table
: "${MAX_JOBS:=10}"

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; CYAN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ── Table layout ─────────────────────────────────────────────
HDR_L="╔"; HDR_M="╦"; HDR_R="╗"
MID_L="╠"; MID_M="╬"; MID_R="╣"
GRP_L="╠"; GRP_R="╣"
ROW_L="║"; ROW_M="║"; ROW_R="║"
FTR_L="╚"; FTR_M="╩"; FTR_R="╝"
H="═"
COL1=32; COL2=18; COL3=14; COL4=$CA_MAX_LEN; COL5=3
# COL5 is the chain status column: ✓ (OK) or ⚠ (broken chain)

ok=0; warn=0; crit=0

# ── Command-line options ─────────────────────────────────────
if [[ "$1" == "--version" || "$1" == "-v" ]]; then
    printf "check-certs %s\n" "$VERSION"
    exit 0
fi

if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    printf "\n"
    printf "${BOLD}check-certs${NC} %s – SSL certificate checker\n" "$VERSION"
    printf "\n"
    printf "${BOLD}Usage:${NC}\n"
    printf "  ${CYAN}check-certs${NC}                              Check all servers from servers.conf\n"
    printf "  ${CYAN}check-certs${NC} <host>[:<port>[:<proto>]]   Check a single server (terminal table)\n"
    printf "  ${CYAN}check-certs --check${NC} <host>[:<port>[:<proto>]]\n"
    printf "                                           key=value output (port defaults to 443)\n"
    printf "  ${CYAN}check-certs --check --nagios${NC} <host>[:<port>[:<proto>]]\n"
    printf "                                           Nagios/Icinga plugin output (OK/WARNING/CRITICAL/UNKNOWN)\n"
    printf "  ${CYAN}check-certs --check --json${NC}   <host>[:<port>[:<proto>]]\n"
    printf "                                           JSON output (one object to stdout)\n"
    printf "  ${CYAN}check-certs --scan${NC} <hostname>             Probe common TLS ports, print servers.conf snippet\n"
    printf "  ${CYAN}check-certs --list${NC}                       List all servers from servers.conf\n"
    printf "  ${CYAN}check-certs --clear-state${NC}                Remove all host state files (forces fresh notifications)\n"
    printf "  ${CYAN}check-certs --clear-state --state-dir${NC} <path>\n"
    printf "                                           Clear state files in a specific directory\n"
    printf "  ${CYAN}check-certs --version${NC}                    Show version\n"
    printf "  ${CYAN}check-certs --help${NC}                       Show this help\n"
    printf "\n"
    printf "${BOLD}servers.conf format:${NC}\n"
    printf "  ${DIM}[Group name]${NC}                    Section header\n"
    printf "  ${DIM}hostname:port${NC}                   TLS (STARTTLS auto-detected by port)\n"
    printf "  ${DIM}hostname:port:proto${NC}             Explicit protocol override\n"
    printf "  ${DIM}[IPv6address]:port[:proto]${NC}      IPv6 host (bracket notation)\n"
    printf "  ${DIM}hostname:port warn=N crit=N${NC}     Per-host threshold overrides\n"
    printf "  ${DIM}# comment${NC}                       Ignored\n"
    printf "\n"
    printf "${BOLD}Protocols:${NC}\n"
    printf "  STARTTLS: ${DIM}smtp submission imap pop3 ldap ftp xmpp${NC}\n"
    printf "  Plain TLS aliases: ${DIM}tls https ldaps imaps pop3s smtps ftps${NC}\n"
    printf "  Auto-detected: 25/587→smtp  143→imap  110→pop3  389→ldap  21→ftp  5222→xmpp\n"
    printf "\n"
    printf "${BOLD}Thresholds${NC} (set in check-certs.conf or per host in servers.conf):\n"
    printf "  WARN_DAYS=%s  CRIT_DAYS=%s  URGENT_DAYS=%s\n" \
        "$WARN_DAYS" "$CRIT_DAYS" "$URGENT_DAYS"
    printf "\n"
    exit 0
fi

if [[ "$1" == "--list" ]]; then
    [ -f "$SERVER_FILE" ] || { echo "Error: server file not found: $SERVER_FILE" >&2; exit 1; }
    printf "\n${BOLD}Servers in %s${NC}\n\n" "$SERVER_FILE"
    local_group=""; local_count=0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[! $'\t']*}"}"
        line="${line%"${line##*[! $'\t']}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            [ -n "$local_group" ] && printf "\n"
            printf "  ${BLUE}${BOLD}[%s]${NC}\n" "${BASH_REMATCH[1]}"
            local_group="${BASH_REMATCH[1]}"
        else
            _lhostpart="${line%% *}"
            _loverrides="${line#"$_lhostpart"}"
            _loverrides="${_loverrides# }"
            if parse_hostspec "$_lhostpart" _lh _lp _lpr; then
                if [ -n "$_lpr" ]; then
                    _proto_str="port $_lp, $_lpr"
                else
                    _auto=$(_starttls_proto "$_lp" "")
                    [ -n "$_auto" ] && _proto_str="port $_lp, starttls/$_auto auto" \
                                    || _proto_str="port $_lp"
                fi
                [ -n "$_loverrides" ] && _proto_str="$_proto_str | $_loverrides"
                printf "    %-38s ${DIM}(%s)${NC}\n" "$_lh" "$_proto_str"
                local_count=$((local_count + 1))
            fi
        fi
    done < "$SERVER_FILE"
    printf "\n  ${BOLD}%d server(s) total${NC}\n\n" "$local_count"
    exit 0
fi

# ── Clear state ───────────────────────────────────────────────
# Removes all per-host state files in the STATE_FILE directory.
# Accepts an optional --state-dir <path> override so the terminal
# user can target a specific variant's state directory without
# needing check-certs.conf to define STATE_FILE.
if [[ "$1" == "--clear-state" ]]; then
    # Allow: --clear-state [--state-dir <path>]
    _state_dir=""
    if [[ "${2:-}" == "--state-dir" && -n "${3:-}" ]]; then
        _state_dir="$3"
    elif [ -n "${STATE_FILE:-}" ]; then
        _state_dir="$STATE_FILE"
    fi
    if [ -z "$_state_dir" ]; then
        echo "Error: STATE_FILE is not configured." >&2
        echo "Set STATE_FILE in check-certs.conf, or use: --clear-state --state-dir <path>" >&2
        exit 1
    fi
    if [ ! -d "$_state_dir" ]; then
        echo "Error: state directory not found: $_state_dir" >&2
        exit 1
    fi
    _cleared=0
    # Each host has its own file in the state directory. Delete them all.
    for _sf in "$_state_dir"/*; do
        [ -f "$_sf" ] || continue
        rm -f "$_sf"
        printf "Cleared: %s\n" "$_sf"
        _cleared=$(( _cleared + 1 ))
    done
    if [ "$_cleared" -eq 0 ]; then
        printf "No state files found in %s\n" "$_state_dir"
    else
        printf "%d host state file(s) removed. Next run will send fresh notifications.\n" "$_cleared"
    fi
    exit 0
fi

# ── Port scan / discovery mode ───────────────────────────────
# --scan <hostname>  probes the most common TLS ports on a host and
# prints a servers.conf-ready snippet for every port that has a valid
# certificate. This makes onboarding a new host fast: run --scan, copy
# the output into servers.conf, and you're done.
#
# Ports probed (in order):
#   443   HTTPS          8443  HTTPS alt
#   465   SMTPS          587   Submission (STARTTLS)
#   993   IMAPS          143   IMAP (STARTTLS)
#   995   POP3S          110   POP3 (STARTTLS)
#   636   LDAPS          389   LDAP (STARTTLS)
#   25    SMTP (STARTTLS)
#
# Example output (ready to paste into servers.conf):
#   mail.example.com:443
#   mail.example.com:587:smtp
#   mail.example.com:993
if [[ "$1" == "--scan" ]]; then
    _sc_host="${2:-}"
    if [ -z "$_sc_host" ]; then
        printf 'Usage: check-certs --scan <hostname>\n' >&2
        exit 1
    fi

    # Ports to probe: port[:proto] where proto is needed only for STARTTLS
    _SCAN_PORTS=(
        443 8443
        465
        587:smtp
        993
        143:imap
        995
        110:pop3
        636
        389:ldap
        25:smtp
    )

    printf '\n%b%bScanning %s...%b\n\n' "$BOLD" "$CYAN" "$_sc_host" "$NC"

    _sc_found=0
    _sc_snippet=""

    for _portspec in "${_SCAN_PORTS[@]}"; do
        _sc_port="${_portspec%%:*}"
        _sc_proto="${_portspec#*:}"
        [ "$_sc_proto" = "$_sc_port" ] && _sc_proto=""   # no colon in spec → plain TLS

        # Run the worker into a temp file; ignore errors
        _sc_tmp=$(mktemp)
        _check_cert_worker "$_sc_host" "$_sc_port" "$_sc_tmp" "$_sc_proto"             "$WARN_DAYS" "$CRIT_DAYS" "$URGENT_DAYS" "$TIMEOUT" 2>/dev/null

        _sc_type=$(_worker_field "$_sc_tmp" TYPE)
        if [ "$_sc_type" = "RESULT" ]; then
            _sc_days=$(_worker_field "$_sc_tmp" DAYS)
            _sc_expiry=$(_worker_field "$_sc_tmp" EXPIRY)
            _sc_ca=$(_worker_field "$_sc_tmp" CA)
            _sc_status=$(_worker_field "$_sc_tmp" STATUS)
            _sc_chain=$(_worker_field "$_sc_tmp" CHAIN)

            # Colour the status
            case "$_sc_status" in
                EXPIRED|URGENT|CRITICAL) _sc_col="$RED"    ;;
                WARNING)                 _sc_col="$YELLOW" ;;
                *)                       _sc_col="$GREEN"  ;;
            esac

            # Format servers.conf line
            if [ -n "$_sc_proto" ]; then
                _sc_conf_line="${_sc_host}:${_sc_port}:${_sc_proto}"
            else
                _sc_conf_line="${_sc_host}:${_sc_port}"
            fi

            _sc_chain_note=""
            [ "$_sc_chain" != "OK" ] && _sc_chain_note=" ${YELLOW}⚠ chain${NC}"

            printf '  %b✓%b  %-8s  %b%-10s%b  %s  %b(CA: %s)%b%b\n'                 "$GREEN" "$NC"                 ":${_sc_port}"                 "$_sc_col" "$_sc_status" "$NC"                 "$_sc_expiry"                 "$DIM" "$_sc_ca" "$NC"                 "$_sc_chain_note"

            _sc_snippet+="${_sc_conf_line}"$'\n'
            _sc_found=$(( _sc_found + 1 ))
        fi
        rm -f "$_sc_tmp"
    done

    if [ "$_sc_found" -eq 0 ]; then
        printf '  No TLS certificates found on %s.\n' "$_sc_host"
        printf '  Check that the host is reachable and has TLS services running.\n\n'
        exit 1
    fi

    # Print a ready-to-paste servers.conf snippet
    printf '\n%b%bservers.conf snippet (copy and paste):%b\n' "$BOLD" "$DIM" "$NC"
    printf '  %s\n' "──────────────────────────────────────"
    printf '%s' "$_sc_snippet" | sed "s/^/  /"
    printf '  %s\n\n' "──────────────────────────────────────"

    exit 0
fi

# ── Structured single-server check ───────────────────────────
# --check [--nagios|--json] <hostspec>
#
# Outputs structured information about a single certificate.
# Useful for scripting, monitoring integrations, and STARTTLS testing.
#
# Output modes:
#   (default)  key=value, one field per line
#   --nagios   Nagios/Icinga plugin format, exit codes per plugin spec
#   --json     JSON object to stdout
#
# Exit codes (default and --json):
#   0  OK
#   1  WARNING
#   2  CRITICAL, URGENT, EXPIRED, or ERROR
#
# Exit codes (--nagios only):
#   0  OK  1  WARNING  2  CRITICAL  3  UNKNOWN (unreachable)
#
# URGENT and EXPIRED map to CRITICAL (exit 2) because they are more
# severe than WARNING — mapping them to UNKNOWN would suppress paging
# in most monitoring setups.
if [[ "$1" == "--check" ]]; then
    _ch_mode="kv"           # default: key=value
    _ch_arg=""
    shift                   # consume "--check"

    # Optional mode flag
    case "${1:-}" in
        --nagios) _ch_mode="nagios"; shift ;;
        --json)   _ch_mode="json";   shift ;;
    esac

    _ch_arg="${1:-}"
    if [ -z "$_ch_arg" ]; then
        printf 'Usage: check-certs --check [--nagios|--json] <host>[:<port>[:<proto>]]\n' >&2
        exit 1
    fi

    # Parse hostspec — supports IPv6 bracket notation [addr]:port[:proto].
    # Port is optional: a bare hostname defaults to port 443.
    _ch_host="" _ch_port="" _ch_proto=""
    if ! parse_hostspec "$_ch_arg" _ch_host _ch_port _ch_proto; then
        # No port given — treat the whole argument as a hostname and
        # default to port 443, matching terminal single-host behaviour.
        if [[ "$_ch_arg" =~ ^[^:[:space:]]+$ ]]; then
            _ch_host="$_ch_arg"
            _ch_port="443"
            _ch_proto=""
        else
            printf 'Error: invalid hostspec "%s"\n' "$_ch_arg" >&2
            printf 'Usage: check-certs --check [--nagios|--json] <host>[:<port>[:<proto>]]\n' >&2
            printf 'Examples:\n' >&2
            printf '  check-certs --check mail.example.com\n' >&2
            printf '  check-certs --check mail.example.com:587\n' >&2
            printf '  check-certs --check [2001:db8::1]:636:ldaps\n' >&2
            exit 1
        fi
    fi

    _ch_tmp=$(mktemp) || { echo "Error: mktemp failed" >&2; exit 2; }
    trap 'rm -f "$_ch_tmp"' EXIT
    _check_cert_worker "$_ch_host" "$_ch_port" "$_ch_tmp" "$_ch_proto"

    _ch_status=$(_worker_field "$_ch_tmp" STATUS)
    _ch_type=$(_worker_field "$_ch_tmp" TYPE)
    _ch_days=$(_worker_field "$_ch_tmp" DAYS)
    _ch_expiry=$(_worker_field "$_ch_tmp" EXPIRY)
    _ch_expiry_ts=$(_worker_field "$_ch_tmp" EXPIRY_TS)
    _ch_ca=$(_worker_field "$_ch_tmp" CA)
    _ch_chain=$(_worker_field "$_ch_tmp" CHAIN)
    _ch_reason=$(_worker_field "$_ch_tmp" REASON)
    _ch_proto_out="${_ch_proto:-tls}"

    # ── key=value output (default) ──────────────────────────
    if [ "$_ch_mode" = "kv" ]; then
        # Print all worker fields in lowercase, skipping TYPE=.
        # Fields include: host, port, proto, days, expiry (human-readable),
        # expiry_ts (Unix timestamp), ca, status, chain.
        # Use cut -d= -f2- to preserve = signs in values (e.g. CA names).
        while IFS= read -r _line; do
            _key="${_line%%=*}"
            _val="${_line#*=}"
            [ "$_key" = "TYPE" ] && continue
            [ "$_key" = "PROTO" ] && _val="${_val:-tls}"
            printf '%s=%s\n' "$(printf '%s' "$_key" | tr 'A-Z' 'a-z')" "$_val"
        done < "$_ch_tmp"
    fi

    # ── Nagios/Icinga-compatible output ─────────────────────
    # Format: STATUS - hostname:port: <human message>
    # Nagios exit codes: OK=0 WARNING=1 CRITICAL=2 UNKNOWN=3
    if [ "$_ch_mode" = "nagios" ]; then
        if [ "$_ch_type" = "ERROR" ]; then
            printf 'UNKNOWN - %s:%s: %s\n' "$_ch_host" "$_ch_port" "${_ch_reason:-unreachable}"
            exit 3
        fi
        case "$_ch_status" in
            OK)
                printf 'OK - %s:%s: certificate valid for %s days (expires %s, CA: %s)\n' \
                    "$_ch_host" "$_ch_port" "$_ch_days" "$_ch_expiry" "$_ch_ca"
                exit 0 ;;
            WARNING)
                printf 'WARNING - %s:%s: certificate expires in %s days (%s)\n' \
                    "$_ch_host" "$_ch_port" "$_ch_days" "$_ch_expiry"
                exit 1 ;;
            CRITICAL)
                printf 'CRITICAL - %s:%s: certificate expires in %s days (%s)\n' \
                    "$_ch_host" "$_ch_port" "$_ch_days" "$_ch_expiry"
                exit 2 ;;
            URGENT)
                printf 'CRITICAL - %s:%s: certificate expires in %s days — urgent (%s)\n' \
                    "$_ch_host" "$_ch_port" "$_ch_days" "$_ch_expiry"
                exit 2 ;;
            EXPIRED)
                printf 'CRITICAL - %s:%s: certificate EXPIRED %s days ago (%s)\n' \
                    "$_ch_host" "$_ch_port" "${_ch_days#-}" "$_ch_expiry"
                exit 2 ;;
            *)
                printf 'UNKNOWN - %s:%s: unexpected status %s\n' "$_ch_host" "$_ch_port" "$_ch_status"
                exit 3 ;;
        esac
    fi

    # ── JSON output ─────────────────────────────────────────
    # Emits a single JSON object. String values are escaped for
    # safety; numeric fields (days) are emitted without quotes.
    # Chain status is included so consumers can detect broken
    # intermediate CAs without parsing the ca field.
    _json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
    if [ "$_ch_mode" = "json" ]; then
        if [ "$_ch_type" = "ERROR" ]; then
            printf '{\n'
            printf '  "host": "%s",\n'   "$(_json_escape "$_ch_host")"
            printf '  "port": %s,\n'     "$_ch_port"
            printf '  "proto": "%s",\n'  "$(_json_escape "$_ch_proto_out")"
            printf '  "status": "ERROR",\n'
            printf '  "reason": "%s"\n'  "$(_json_escape "${_ch_reason:-unreachable}")"
            printf '}\n'
        else
            printf '{\n'
            printf '  "host": "%s",\n'         "$(_json_escape "$_ch_host")"
            printf '  "port": %s,\n'           "$_ch_port"
            printf '  "proto": "%s",\n'        "$(_json_escape "$_ch_proto_out")"
            printf '  "status": "%s",\n'       "$(_json_escape "$_ch_status")"
            printf '  "days": %s,\n'           "$_ch_days"
            printf '  "expiry": "%s",\n'       "$(_json_escape "$_ch_expiry")"
            printf '  "expiry_ts": %s,\n'      "$_ch_expiry_ts"
            printf '  "ca": "%s",\n'           "$(_json_escape "$_ch_ca")"
            printf '  "chain_status": "%s"\n'  "$(_json_escape "$_ch_chain")"
            printf '}\n'
        fi
    fi

    # ── Exit code ────────────────────────────────────────────
    # All modes share the same exit code logic:
    #   0=OK  1=WARNING  2=CRITICAL/URGENT/EXPIRED/ERROR
    # (--nagios exits earlier in the case above with proper exit 3 for UNKNOWN)
    [ "$_ch_type" = "ERROR" ] && exit 2
    case "$_ch_status" in
        OK)                        exit 0 ;;
        WARNING)                   exit 1 ;;
        CRITICAL|URGENT|EXPIRED)   exit 2 ;;
        *)                         exit 2 ;;
    esac
fi

# ── Table helpers ────────────────────────────────────────────
# Repeat a character N times without forking a subshell.
_repeat() {
    local char="$1" n="$2" out="" i
    for (( i=0; i<n; i++ )); do out+="$char"; done
    printf '%s' "$out"
}

hline() {
    local left=$1 mid=$2 right=$3
    printf "%s%s%s%s%s%s%s%s%s%s%s\n" \
        "$left" "$(_repeat "$H" $((COL1+2)))" \
        "$mid"  "$(_repeat "$H" $((COL2+2)))" \
        "$mid"  "$(_repeat "$H" $((COL3+2)))" \
        "$mid"  "$(_repeat "$H" $((COL4+2)))" \
        "$mid"  "$(_repeat "$H" $((COL5+2)))" \
        "$right"
}

print_group() {
    local name="$1"
    # Inner width = total chars between GRP_L and GRP_R in a normal hline row:
    # (COL1+2) + 1 + (COL2+2) + 1 + (COL3+2) + 1 + (COL4+2) + 1 + (COL5+2)
    local inner=$(( COL1 + COL2 + COL3 + COL4 + COL5 + 14 ))
    # Visible label including surrounding spaces: " Name "
    local label=" ${name} "
    local pad=$(( inner - ${#label} ))
    [ "$pad" -lt 0 ] && pad=0
    printf "%s ${BLUE}${BOLD}%s${NC} %s%s\n" \
        "$GRP_L" "$name" "$(_repeat "$H" $pad)" "$GRP_R"
}

print_error_row() {
    local hostname="$1" reason="$2"
    local pad=$(( COL3 - 5 ))
    printf "%s %-*s %s %-*s %s %b%-5s%b%*s %s %-*s %s %-*s %s\n" \
        "$ROW_L" $COL1 "$hostname" \
        "$ROW_M" $COL2 "-" \
        "$ROW_M" "$RED" "ERROR" "$NC" $pad "" \
        "$ROW_M" $COL4 "$reason" \
        "$ROW_M" $COL5 "" \
        "$ROW_R"
}

# ── Terminal hooks ───────────────────────────────────────────
on_group() {
    if [ "${_first_group:-true}" = true ]; then _first_group=false
    else hline "$MID_L" "$MID_M" "$MID_R"
    fi
    print_group "$1"
}

on_cert_error() { print_error_row "$1" "$3"; }

on_format_error() { print_error_row "$1" "Invalid format"; }

on_cert_result() {
    local hostname="$1" port="$2" days_left="$3" short_date="$4"
    local ca_name="$5" status="$6" chain_status="${9:-OK}"
    local color icon text

    case "$status" in
        EXPIRED)         color="$RED";    icon="✗"; text="EXP -${days_left#-}d";    crit=$((crit+1)) ;;
        URGENT|CRITICAL) color="$RED";    icon="✗"; text="${days_left}d";            crit=$((crit+1)) ;;
        WARNING)         color="$YELLOW"; icon="⚠"; text="${days_left}d";            warn=$((warn+1)) ;;
        *)               color="$GREEN";  icon="✓"; text="${days_left}d";            ok=$((ok+1))   ;;
    esac

    # Chain column: ✓ green for OK, ⚠ yellow for any broken chain.
    # Kept separate from the CA column so it never overflows the layout.
    local chain_icon chain_color
    if [ "$chain_status" = "OK" ]; then
        chain_icon="✓"; chain_color="$GREEN"
    else
        chain_icon="⚠"; chain_color="$YELLOW"
    fi

    # Note: chain_icon (✓/⚠) is a multi-byte UTF-8 character. bash printf
    # pads %-*s by bytes, not display columns, so unicode symbols end up
    # under-padded. We print the symbol directly and add explicit spaces.
    printf "%s %-*s %s %-*s %s %b%s%-*s%b %s %-*s %s %b%s%b  %s\n" \
        "$ROW_L" $COL1 "$hostname" \
        "$ROW_M" $COL2 "$short_date" \
        "$ROW_M" "${color}" "$icon " $((COL3-2)) "$text" "${NC}" \
        "$ROW_M" $COL4 "$ca_name" \
        "$ROW_M" "${chain_color}" "$chain_icon" "${NC}" \
        "$ROW_R"
}

# ── Run ──────────────────────────────────────────────────────
echo ""
hline "$HDR_L" "$HDR_M" "$HDR_R"
printf "%s ${BOLD}%-*s${NC} %s ${BOLD}%-*s${NC} %s ${BOLD}%-*s${NC} %s ${BOLD}%-*s${NC} %s ${BOLD}%-*s${NC} %s\n" \
    "$ROW_L" $COL1 "Server" \
    "$ROW_M" $COL2 "Expiry date" \
    "$ROW_M" $COL3 "Remaining" \
    "$ROW_M" $COL4 "Issued by" \
    "$ROW_M" $COL5 "Ch" \
    "$ROW_R"
hline "$MID_L" "$MID_M" "$MID_R"

_first_group=true

if [ $# -eq 1 ] && [[ "$1" != --* ]]; then
    local_host="$1"; local_port="443"; local_proto=""
    parse_hostspec "$1" local_host local_port local_proto || true
    _tmpconf=$(mktemp)
    trap 'rm -f "$_tmpconf"' EXIT
    if [ -n "$local_proto" ]; then
        echo "${local_host}:${local_port}:${local_proto}" > "$_tmpconf"
    else
        echo "${local_host}:${local_port}" > "$_tmpconf"
    fi
    run_server_loop "$_tmpconf"
    rm -f "$_tmpconf"; trap - EXIT
else
    run_server_loop "$SERVER_FILE"
fi

hline "$FTR_L" "$FTR_M" "$FTR_R"
printf "\n  ${BOLD}Summary:${NC}  %d checked  │  ${GREEN}✓ %d OK${NC}  │  ${YELLOW}⚠ %d Warning${NC}  │  ${RED}✗ %d Critical/Error${NC}\n\n" \
    "$total" "$ok" "$warn" "$((crit + errors))"

fi # end BASH_SOURCE guard
