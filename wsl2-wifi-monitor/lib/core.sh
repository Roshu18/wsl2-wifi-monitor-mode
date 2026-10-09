# shellcheck shell=bash

[[ -n ${_WIFIMON_CORE_SH:-} ]] && return 0
_WIFIMON_CORE_SH=1

WIFIMON_VERSION="2.0.0"

WIFIMON_ETC="${WIFIMON_ETC:-/etc/wifimon}"
WIFIMON_CACHE="${WIFIMON_CACHE:-/var/cache/wifimon}"
WIFIMON_STATE="${WIFIMON_STATE:-/var/lib/wifimon}"
WIFIMON_LOG_DIR="${WIFIMON_LOG_DIR:-/var/log/wifimon}"
WIFIMON_LOG_FILE="${WIFIMON_LOG_FILE:-${WIFIMON_LOG_DIR}/wifimon.log}"
WIFIMON_LOCK_FILE="${WIFIMON_LOCK_FILE:-${WIFIMON_STATE}/wifimon.lock}"

WIFIMON_VERBOSITY="${WIFIMON_VERBOSITY:-1}"
WIFIMON_ASSUME_YES="${WIFIMON_ASSUME_YES:-0}"
WIFIMON_COLOR="${WIFIMON_COLOR:-auto}"

_C_RESET='' ; _C_RED='' ; _C_YEL='' ; _C_GRN='' ; _C_BLU='' ; _C_DIM='' ; _C_BLD=''
core_init_color() {
    local use=0
    case "$WIFIMON_COLOR" in
        always) use=1 ;;
        never)  use=0 ;;
        *)      [[ -t 2 && -z ${NO_COLOR:-} ]] && use=1 ;;
    esac
    if (( use )); then
        _C_RESET=$'\033[0m' ; _C_RED=$'\033[31m' ; _C_YEL=$'\033[33m'
        _C_GRN=$'\033[32m'  ; _C_BLU=$'\033[36m' ; _C_DIM=$'\033[2m'
        _C_BLD=$'\033[1m'
    else
        _C_RESET='' ; _C_RED='' ; _C_YEL='' ; _C_GRN='' ; _C_BLU='' ; _C_DIM='' ; _C_BLD=''
    fi
}
core_init_color

_log_to_file() {
    [[ -n ${WIFIMON_NO_LOGFILE:-} ]] && return 0
    local line="$1"
    if [[ -w ${WIFIMON_LOG_FILE} ]] 2>/dev/null; then
        printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$line" >>"${WIFIMON_LOG_FILE}" 2>/dev/null || true
    elif mkdir -p "${WIFIMON_LOG_DIR}" 2>/dev/null; then
        printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$line" >>"${WIFIMON_LOG_FILE}" 2>/dev/null || true
    fi
}

log_error() { _log_to_file "ERROR $*"; printf '%s[!]%s %s\n' "$_C_RED" "$_C_RESET" "$*" >&2; }
log_warn()  { _log_to_file "WARN  $*"; (( WIFIMON_VERBOSITY >= 1 )) && printf '%s[~]%s %s\n' "$_C_YEL" "$_C_RESET" "$*" >&2; return 0; }
log_info()  { _log_to_file "INFO  $*"; (( WIFIMON_VERBOSITY >= 1 )) && printf '%s[*]%s %s\n' "$_C_BLU" "$_C_RESET" "$*" >&2; return 0; }
log_ok()    { _log_to_file "OK    $*"; (( WIFIMON_VERBOSITY >= 1 )) && printf '%s[+]%s %s\n' "$_C_GRN" "$_C_RESET" "$*" >&2; return 0; }
log_debug() { _log_to_file "DEBUG $*"; (( WIFIMON_VERBOSITY >= 2 )) && printf '%s[d] %s%s\n' "$_C_DIM" "$*" "$_C_RESET" >&2; return 0; }
log_step()  { _log_to_file "STEP  $*"; (( WIFIMON_VERBOSITY >= 1 )) && printf '\n%s==>%s %s%s%s\n' "$_C_BLU" "$_C_RESET" "$_C_BLD" "$*" "$_C_RESET" >&2; return 0; }

log_hint() {
    (( WIFIMON_VERBOSITY >= 1 )) || return 0
    local line
    for line in "$@"; do printf '    %s%s%s\n' "$_C_DIM" "$line" "$_C_RESET" >&2; done
    return 0
}

die() {
    local code=1
    [[ $1 =~ ^[0-9]+$ ]] && { code=$1; shift; }
    log_error "$*"
    exit "$code"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

need_cmd() {
    have_cmd "$1" && return 0
    die "required command '$1' not found${2:+ ($2)}"
}

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] && return 0
    if have_cmd sudo; then
        die "this command needs root: sudo ${WIFIMON_SELF:-wifimon} ${WIFIMON_ARGV:-...}"
    fi
    die "this command needs root (run it as root)"
}

ensure_dirs() {
    local d
    for d in "$WIFIMON_ETC" "$WIFIMON_CACHE" "$WIFIMON_STATE" "$WIFIMON_LOG_DIR"; do
        [[ -d $d ]] || mkdir -p "$d" 2>/dev/null || true
    done
}

run() {
    log_debug "+ $*"
    "$@"
}

run_quiet() {
    local label="$1"; shift
    log_debug "+ $*"
    if (( WIFIMON_VERBOSITY >= 2 )); then
        "$@" && return 0
        log_error "${label} failed"
        return 1
    fi
    local out rc=0
    out="$(mktemp "${TMPDIR:-/tmp}/wifimon.XXXXXX")"
    if "$@" >"$out" 2>&1; then
        _log_to_file "CMDOUT ${label}: $(wc -l <"$out") lines (ok)"
        rm -f "$out"
        return 0
    fi
    rc=$?
    log_error "${label} failed (exit ${rc}); last 40 lines:"
    tail -n 40 "$out" >&2 || true
    cat "$out" >>"${WIFIMON_LOG_FILE}" 2>/dev/null || true
    rm -f "$out"
    return "$rc"
}

retry() {
    local attempts="$1" delay="$2"; shift 2
    [[ ${1:-} == -- ]] && shift
    local n=1
    while true; do
        if "$@"; then return 0; fi
        if (( n >= attempts )); then
            log_debug "giving up after ${n} attempt(s): $*"
            return 1
        fi
        log_warn "attempt ${n}/${attempts} failed, retrying in ${delay}s"
        sleep "$delay"
        delay=$(( delay * 2 ))
        n=$(( n + 1 ))
    done
}

confirm() {
    local prompt="$1" default="${2:-n}"
    (( WIFIMON_ASSUME_YES )) && return 0
    [[ -t 0 ]] || { log_debug "no tty, assuming '$default' for: $prompt"; [[ $default == y ]]; return; }
    local reply
    read -r -p "$prompt $( [[ $default == y ]] && echo '[Y/n]' || echo '[y/N]' ) " reply || reply=''
    reply="${reply:-$default}"
    [[ ${reply,,} == y* ]]
}

with_lock() {
    if ! have_cmd flock; then
        log_debug "flock unavailable, running without lock"
        "$@"
        return
    fi
    mkdir -p "$(dirname "$WIFIMON_LOCK_FILE")" 2>/dev/null || true
    exec 9>"$WIFIMON_LOCK_FILE" 2>/dev/null || { "$@"; return; }
    if ! flock -w 300 9; then
        die "another wifimon instance holds the lock (${WIFIMON_LOCK_FILE})"
    fi
    "$@"
}

atomic_write() {
    local dest="$1" tmp
    tmp="${dest}.tmp.$$"
    mkdir -p "$(dirname "$dest")"
    cat >"$tmp"
    mv -f "$tmp" "$dest"
}

ver_cmp() {
    local a="$1" b="$2"
    local -a A B
    IFS='.' read -r -a A <<<"${a//[^0-9.]/}"
    IFS='.' read -r -a B <<<"${b//[^0-9.]/}"
    local i n=${#A[@]}
    (( ${#B[@]} > n )) && n=${#B[@]}
    for (( i = 0; i < n; i++ )); do
        local x=${A[i]:-0} y=${B[i]:-0}
        x=$(( 10#${x:-0} )); y=$(( 10#${y:-0} ))
        (( x > y )) && { echo 1; return 0; }
        (( x < y )) && { echo -1; return 0; }
    done
    echo 0
}

ver_ge() { [[ $(ver_cmp "$1" "$2") != -1 ]]; }
ver_gt() { [[ $(ver_cmp "$1" "$2") == 1 ]]; }
ver_lt() { [[ $(ver_cmp "$1" "$2") == -1 ]]; }

ver_series() {
    local v="${1//[^0-9.]/}"
    local -a p
    IFS='.' read -r -a p <<<"$v"
    printf '%s.%s' "${p[0]:-0}" "${p[1]:-0}"
}

http_get() {
    local url="$1" dest="$2"
    mkdir -p "$(dirname "$dest")"
    if have_cmd curl; then
        retry 4 2 -- curl -fL --retry 2 --connect-timeout 20 -C - \
            ${WIFIMON_VERBOSITY:+$( (( WIFIMON_VERBOSITY >= 1 )) && echo '--progress-bar' || echo '-s' )} \
            -o "$dest" "$url"
    elif have_cmd wget; then
        retry 4 2 -- wget -c -T 20 -O "$dest" "$url"
    else
        die "neither curl nor wget is installed"
    fi
}

http_ok() {
    local url="$1"
    if have_cmd curl; then
        curl -fsSL -I --connect-timeout 15 -o /dev/null "$url" 2>/dev/null
    elif have_cmd wget; then
        wget -q --spider -T 15 "$url" 2>/dev/null
    else
        return 1
    fi
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/}"
    printf '%s' "$s"
}

nproc_safe() {
    local n=1
    have_cmd nproc && n="$(nproc)"
    [[ $n =~ ^[0-9]+$ ]] || n=1
    local memkb=0
    [[ -r /proc/meminfo ]] && memkb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
    if [[ $memkb =~ ^[0-9]+$ ]] && (( memkb > 0 )); then
        local by_mem=$(( (memkb - 524288) / 716800 ))
        (( by_mem < 1 )) && by_mem=1
        (( by_mem < n )) && n=$by_mem
    fi
    echo "$n"
}

WIFIMON_STATE_FILE="${WIFIMON_STATE_FILE:-${WIFIMON_STATE}/state}"

state_set() {
    local key="$1" val="$2"
    mkdir -p "$(dirname "$WIFIMON_STATE_FILE")" 2>/dev/null || return 0
    local tmp="${WIFIMON_STATE_FILE}.tmp.$$"
    { [[ -r $WIFIMON_STATE_FILE ]] && grep -v "^${key}=" "$WIFIMON_STATE_FILE" || true; } >"$tmp" 2>/dev/null
    printf '%s=%s\n' "$key" "$val" >>"$tmp"
    mv -f "$tmp" "$WIFIMON_STATE_FILE" 2>/dev/null || rm -f "$tmp"
    return 0
}

state_get() {
    local key="$1"
    [[ -r $WIFIMON_STATE_FILE ]] || return 1
    local v
    v="$(sed -n "s/^${key}=\\(.*\\)$/\\1/p" "$WIFIMON_STATE_FILE" | tail -1)"
    [[ -n $v ]] && { printf '%s' "$v"; return 0; }
    return 1
}

config_load() {
    local f="${WIFIMON_ETC}/config"
    [[ -r $f ]] || return 0
    local line key val
    while IFS= read -r line; do
        line="${line%%#*}"
        [[ $line =~ ^[[:space:]]*$ ]] && continue
        key="${line%%=*}"; val="${line#*=}"
        key="${key//[[:space:]]/}"
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        val="${val%\"}"; val="${val#\"}"
        case "$key" in
            driver)    WIFIMON_DRIVER="${WIFIMON_DRIVER:-$val}" ;;
            interface) WIFIMON_IFACE="${WIFIMON_IFACE:-$val}" ;;
            monitor_iface) WIFIMON_MONIFACE="${WIFIMON_MONIFACE:-$val}" ;;
            channel)   WIFIMON_CHANNEL="${WIFIMON_CHANNEL:-$val}" ;;
            width)     WIFIMON_WIDTH="${WIFIMON_WIDTH:-$val}" ;;
            regdomain) WIFIMON_REG="${WIFIMON_REG:-$val}" ;;
            cache)     WIFIMON_CACHE="$val" ;;
            kernel_ref) WIFIMON_KERNEL_REF="${WIFIMON_KERNEL_REF:-$val}" ;;
            kernel_src) WIFIMON_KSRC="${WIFIMON_KSRC:-$val}" ;;
            *) log_debug "ignoring unknown config key '${key}'" ;;
        esac
    done <"$f"
    log_debug "loaded config from ${f}"
    return 0
}
