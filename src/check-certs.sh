#!/bin/bash

# ============================================================
#  check-certs.sh – SSL certificate checker
#  Version 2.3.1
#
#  STANDALONE USAGE (terminal table, macOS + Linux):
#    check-certs [hostname[:port]]
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
VERSION="2.3.1"

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

state_init() {
    [ -z "$STATE_FILE" ] && return
    mkdir -p "$(dirname "$STATE_FILE")"
    touch "$STATE_FILE"
}

state_get() {
    [ -z "$STATE_FILE" ] && echo "" && return
    grep "^${1}=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-
}

state_set() {
    [ -z "$STATE_FILE" ] && return
    local key="$1" value="$2" tmpfile
    tmpfile=$(mktemp)
    grep -v "^${key}=" "$STATE_FILE" > "$tmpfile" 2>/dev/null || true
    echo "${key}=${value}" >> "$tmpfile"
    mv "$tmpfile" "$STATE_FILE"
}

state_delete() {
    [ -z "$STATE_FILE" ] && return
    local tmpfile
    tmpfile=$(mktemp)
    grep -v "^${1}=" "$STATE_FILE" > "$tmpfile" 2>/dev/null || true
    mv "$tmpfile" "$STATE_FILE"
}

# ── CA name extraction ───────────────────────────────────────
# Prefers CN=, falls back to O=. Compatible with macOS and Linux
# openssl output formats (CN=value and CN = value).
extract_ca() {
    local issuer="$1" ca

    ca=$(echo "$issuer" | sed 's/.*[, /]CN[[:space:]]*=[[:space:]]*//' \
                        | sed 's/[,/].*//'                              \
                        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [ -z "$ca" ] || echo "$ca" | grep -q "issuer="; then
        ca=$(echo "$issuer" | sed 's/.*[, /]O[[:space:]]*=[[:space:]]*//' \
                            | sed 's/[,/].*//'                             \
                            | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fi

    if [ -z "$ca" ] || echo "$ca" | grep -q "issuer="; then
        ca="Unknown"
    fi

    echo "${ca:0:${CA_MAX_LEN:-30}}"
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
# Writes a structured result to a temp file (one field per line):
#   Line 1: TYPE        – RESULT or ERROR
#   Line 2: HOSTNAME
#   Line 3: PORT
#   Line 4: PROTO       – starttls protocol or empty for plain TLS
#   Line 5: DAYS_LEFT   (RESULT) | REASON (ERROR)
#   Line 6: SHORT_DATE  (RESULT only)
#   Line 7: CA_NAME     (RESULT only)
#   Line 8: STATUS      (RESULT only)
#   Line 9: CHAIN       (RESULT only) – OK or reason string
_check_cert_worker() {
    local hostname="$1" port="$2" outfile="$3" proto="${4:-}"
    local timeout_cmd=""
    local current_ts
    current_ts=$($DATE_CMD +%s)

    # Resolve timeout lazily so wrappers that set TIMEOUT after
    # sourcing get the correct value
    if command -v gtimeout &>/dev/null; then
        timeout_cmd="gtimeout ${TIMEOUT:-5}"
    elif command -v timeout &>/dev/null; then
        timeout_cmd="timeout ${TIMEOUT:-5}"
    fi

    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        printf 'ERROR\n%s\n%s\n%s\nInvalid port\n' "$hostname" "$port" "$proto" > "$outfile"
        return
    fi

    # ── Determine STARTTLS args ───────────────────────────────
    local starttls_proto starttls_args=()
    starttls_proto=$(_starttls_proto "$port" "$proto")
    [ -n "$starttls_proto" ] && starttls_args=(-starttls "$starttls_proto")

    # ── Leaf certificate ─────────────────────────────────────
    local cert_data
    # shellcheck disable=SC2086  # timeout_cmd intentionally word-splits
    cert_data=$($timeout_cmd openssl s_client \
        -connect "$hostname:$port" -servername "$hostname" \
        "${starttls_args[@]}" \
        </dev/null 2>/dev/null \
        | openssl x509 -noout -enddate -issuer 2>/dev/null)

    if [ -z "$cert_data" ]; then
        printf 'ERROR\n%s\n%s\n%s\nUnreachable\n' "$hostname" "$port" "$starttls_proto" > "$outfile"
        return
    fi

    # ── Full chain verification ──────────────────────────────
    local chain_output chain_status
    # shellcheck disable=SC2086  # timeout_cmd intentionally word-splits
    chain_output=$($timeout_cmd openssl s_client \
        -connect "$hostname:$port" -servername "$hostname" \
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
        printf 'ERROR\n%s\n%s\n%s\nCould not parse expiry date\n' \
            "$hostname" "$port" "$starttls_proto" > "$outfile"
        return
    fi
    days_left=$(( (expiry_ts - current_ts) / 86400 ))

    # ── Determine status ─────────────────────────────────────
    local status
    if   [ "$days_left" -lt 0 ]; then
        status="EXPIRED"
    elif [ "${URGENT_DAYS:-0}" -gt 0 ] && [ "$days_left" -lt "$URGENT_DAYS" ]; then
        status="URGENT"
    elif [ "$days_left" -lt "${CRIT_DAYS:-0}" ]; then
        status="CRITICAL"
    elif [ "$days_left" -lt "${WARN_DAYS:-15}" ]; then
        status="WARNING"
    else
        status="OK"
    fi

    # Broken chain with otherwise-OK leaf → CRITICAL
    [ "$chain_status" != "OK" ] && [ "$status" = "OK" ] && status="CRITICAL"

    printf 'RESULT\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
        "$hostname" "$port" "$starttls_proto" "$days_left" "$short_date" \
        "$ca_name" "$status" "$chain_status" > "$outfile"
}

# ── Dispatch result to hooks ─────────────────────────────────
# Reads a temp file written by _check_cert_worker, looks up state,
# and calls on_cert_result or on_cert_error.
_dispatch_result() {
    local outfile="$1"
    local current_ts type hostname port
    current_ts=$($DATE_CMD +%s)
    type=$(sed -n '1p' "$outfile")
    hostname=$(sed -n '2p' "$outfile")
    port=$(sed -n '3p' "$outfile")
    total=$((total + 1))

    local prev_status last_seen hours_since
    prev_status=$(state_get "status:${hostname}")
    last_seen=$(state_get "last_notify:${hostname}")
    hours_since=$(( (current_ts - ${last_seen:-0}) / 3600 ))

    if [ "$type" = "ERROR" ]; then
        local reason
        reason=$(sed -n '5p' "$outfile")
        on_cert_error "$hostname" "$port" "$reason" "$prev_status" "$hours_since"
        errors=$((errors + 1))
        return
    fi

    local days_left short_date ca_name status chain_status
    days_left=$(sed -n '5p' "$outfile")
    short_date=$(sed -n '6p' "$outfile")
    ca_name=$(sed -n '7p' "$outfile")
    status=$(sed -n '8p' "$outfile")
    chain_status=$(sed -n '9p' "$outfile")

    [ "$status" != "OK" ] && warned=$((warned + 1))

    on_cert_result \
        "$hostname" "$port" "$days_left" "$short_date" \
        "$ca_name" "$status" "$prev_status" "$hours_since" "$chain_status"
}

# ── Server loop ──────────────────────────────────────────────
# Reads servers.conf, fires up to MAX_JOBS parallel workers,
# then replays results in original file order via hooks.
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

        if [[ "$line" =~ ^([^:]+):([0-9]+)(:([a-z]+))?$ ]]; then
            h="${BASH_REMATCH[1]}" p="${BASH_REMATCH[2]}" pr="${BASH_REMATCH[4]}"
            order+=("HOST:$idx")

            # Semaphore: wait for one job to finish before launching
            # another when MAX_JOBS is reached
            if [ "$running" -ge "${MAX_JOBS:-10}" ]; then
                if wait -n 2>/dev/null; then :
                else wait "${pids[$(( idx - running ))]}" 2>/dev/null || true
                fi
                running=$((running - 1))
            fi

            _check_cert_worker "$h" "$p" "$tmpdir/$idx" "$pr" &
            pids+=($!); running=$((running + 1)); idx=$((idx + 1))
        else
            order+=("FORMAT_ERROR:$line")
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
    local current_ts
    current_ts=$($DATE_CMD +%s)

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
    local current_ts
    current_ts=$($DATE_CMD +%s)

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

    # Persist current status
    case "$status" in
        EXPIRED)  state_set "status:${hostname}" "EXPIRED" ;;
        URGENT)   state_set "status:${hostname}" "URGENT"  ;;
        CRITICAL) state_set "status:${hostname}" "CRIT"    ;;
        *)        state_set "status:${hostname}" "WARN"    ;;
    esac
    state_set "days:${hostname}" "$days_left"
}

# install_escalation_hooks – wire on_cert_result / on_cert_error /
# on_format_error to the shared escalation logic. Call this after
# configure_wrapper and state_init, before run_server_loop.
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
: "${CA_MAX_LEN:=22}"  # narrower than wrapper default (30) to fit the fixed table width
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
COL1=32; COL2=18; COL3=14; COL4=$CA_MAX_LEN

ok=0; warn=0; crit=0

# ── Flags ─────────────────────────────────────────────────────
if [[ "$1" == "--version" || "$1" == "-v" ]]; then
    printf "check-certs %s\n" "$VERSION"
    exit 0
fi

if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    printf "\n"
    printf "${BOLD}check-certs${NC} %s – SSL certificate checker\n" "$VERSION"
    printf "\n"
    printf "  ${CYAN}check-certs${NC}                   Check all servers from servers.conf\n"
    printf "  ${CYAN}check-certs${NC} <host>            Check a single server (port defaults to 443)\n"
    printf "  ${CYAN}check-certs${NC} <host>:<port>     Check a single server on a specific port\n"
    printf "  ${CYAN}check-certs${NC} <host>:<port>:<proto>  Check with explicit STARTTLS protocol\n"
    printf "  ${CYAN}check-certs${NC} <host> <port>     Same as above, port as a second argument\n"
    printf "  ${CYAN}check-certs --list${NC}             List all servers from servers.conf\n"
    printf "  ${CYAN}check-certs --version${NC}          Show version\n"
    printf "  ${CYAN}check-certs --help${NC}             Show this help\n"
    printf "\n"
    printf "  ${BOLD}servers.conf format:${NC}\n"
    printf "    ${DIM}[Group name]${NC}               Section header\n"
    printf "    ${DIM}hostname:port${NC}              TLS (STARTTLS auto-detected by port)\n"
    printf "    ${DIM}hostname:port:proto${NC}        Explicit protocol override\n"
    printf "    ${DIM}# comment${NC}                  Ignored\n"
    printf "\n"
    printf "  ${BOLD}Protocols:${NC}\n"
    printf "    STARTTLS: ${DIM}smtp submission imap pop3 ldap ftp xmpp${NC}\n"
    printf "    Plain TLS aliases: ${DIM}tls https ldaps imaps pop3s smtps ftps${NC}\n"
    printf "    Auto-detected: 25/587→smtp  143→imap  110→pop3\n"
    printf "                   389→ldap  21→ftp  5222→xmpp\n"
    printf "\n"
    printf "  ${BOLD}Thresholds${NC} (set in check-certs.conf):\n"
    printf "    WARN_DAYS=%s  CRIT_DAYS=%s  URGENT_DAYS=%s\n" \
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
        elif [[ "$line" =~ ^([^:]+):([0-9]+)(:([a-z]+))?$ ]]; then
            _lh="${BASH_REMATCH[1]}" _lp="${BASH_REMATCH[2]}" _lpr="${BASH_REMATCH[4]}"
            if [ -n "$_lpr" ]; then
                printf "    %-38s ${DIM}(port %s, %s)${NC}\n" "$_lh" "$_lp" "$_lpr"
            else
                _auto=$(_starttls_proto "$_lp" "")
                if [ -n "$_auto" ]; then
                    printf "    %-38s ${DIM}(port %s, starttls/%s auto)${NC}\n" "$_lh" "$_lp" "$_auto"
                else
                    printf "    %-38s ${DIM}(port %s)${NC}\n" "$_lh" "$_lp"
                fi
            fi
            local_count=$((local_count + 1))
        fi
    done < "$SERVER_FILE"
    printf "\n  ${BOLD}%d server(s) total${NC}\n\n" "$local_count"
    exit 0
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
    printf "%s%s%s%s%s%s%s%s%s\n" \
        "$left" "$(_repeat "$H" $((COL1+2)))" \
        "$mid"  "$(_repeat "$H" $((COL2+2)))" \
        "$mid"  "$(_repeat "$H" $((COL3+2)))" \
        "$mid"  "$(_repeat "$H" $((COL4+2)))" \
        "$right"
}

print_group() {
    local name="$1"
    # Inner width = total chars between GRP_L and GRP_R in a normal hline row:
    # (COL1+2) + 1 + (COL2+2) + 1 + (COL3+2) + 1 + (COL4+2)
    local inner=$(( COL1 + COL2 + COL3 + COL4 + 11 ))
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
    printf "%s %-*s %s %-*s %s %b%-5s%b%*s %s %-*s %s\n" \
        "$ROW_L" $COL1 "$hostname" \
        "$ROW_M" $COL2 "-" \
        "$ROW_M" "$RED" "ERROR" "$NC" $pad "" \
        "$ROW_M" $COL4 "$reason" \
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

    local ca_display="$ca_name"
    [ "$chain_status" != "OK" ] && ca_display="${ca_name} ⚠chain"

    printf "%s %-*s %s %-*s %s %b%s%-*s%b %s %-*s %s\n" \
        "$ROW_L" $COL1 "$hostname" \
        "$ROW_M" $COL2 "$short_date" \
        "$ROW_M" "${color}" "$icon " $((COL3-2)) "$text" "${NC}" \
        "$ROW_M" $COL4 "$ca_display" \
        "$ROW_R"
}

# ── Run ──────────────────────────────────────────────────────
echo ""
hline "$HDR_L" "$HDR_M" "$HDR_R"
printf "%s ${BOLD}%-*s${NC} %s ${BOLD}%-*s${NC} %s ${BOLD}%-*s${NC} %s ${BOLD}%-*s${NC} %s\n" \
    "$ROW_L" $COL1 "Server" \
    "$ROW_M" $COL2 "Expiry date" \
    "$ROW_M" $COL3 "Remaining" \
    "$ROW_M" $COL4 "Issued by" \
    "$ROW_R"
hline "$MID_L" "$MID_M" "$MID_R"

_first_group=true

if [ $# -eq 1 ] && [[ "$1" != --* ]]; then
    local_host="$1"; local_port="443"; local_proto=""
    [[ "$1" =~ ^([^:]+):([0-9]+)(:([a-z]+))?$ ]] \
        && local_host="${BASH_REMATCH[1]}" \
        && local_port="${BASH_REMATCH[2]}" \
        && local_proto="${BASH_REMATCH[4]}"
    _tmpconf=$(mktemp)
    trap 'rm -f "$_tmpconf"' EXIT
    if [ -n "$local_proto" ]; then
        echo "${local_host}:${local_port}:${local_proto}" > "$_tmpconf"
    else
        echo "${local_host}:${local_port}" > "$_tmpconf"
    fi
    run_server_loop "$_tmpconf"
    rm -f "$_tmpconf"; trap - EXIT
elif [ $# -eq 2 ]; then
    _tmpconf=$(mktemp)
    trap 'rm -f "$_tmpconf"' EXIT
    echo "${1}:${2}" > "$_tmpconf"
    run_server_loop "$_tmpconf"
    rm -f "$_tmpconf"; trap - EXIT
else
    run_server_loop "$SERVER_FILE"
fi

hline "$FTR_L" "$FTR_M" "$FTR_R"
printf "\n  ${BOLD}Summary:${NC}  %d checked  │  ${GREEN}✓ %d OK${NC}  │  ${YELLOW}⚠ %d Warning${NC}  │  ${RED}✗ %d Critical/Error${NC}\n\n" \
    "$total" "$ok" "$warn" "$((crit + errors))"

fi # end BASH_SOURCE guard
