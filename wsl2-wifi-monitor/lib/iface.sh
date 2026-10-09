# shellcheck shell=bash
# shellcheck disable=SC2034

[[ -n ${_WIFIMON_IFACE_SH:-} ]] && return 0
_WIFIMON_IFACE_SH=1

MON_IFACE=""
MON_METHOD=""
MON_BASE=""

iface_list_wireless() {
    local d n
    for d in /sys/class/net/*; do
        [[ -e "${d}/wireless" || -e "${d}/phy80211" ]] || continue
        n="$(basename "$d")"
        printf '%s\n' "$n"
    done
}

iface_any_wireless() {
    local n
    n="$(iface_list_wireless | head -1)"
    [[ -n $n ]] || return 1
    printf '%s' "$n"
}

iface_exists() {
    [[ -e "/sys/class/net/$1" ]]
}

iface_phy() {
    local i="$1" p
    if [[ -L "/sys/class/net/${i}/phy80211" ]]; then
        p="$(basename "$(readlink -f "/sys/class/net/${i}/phy80211")")"
        [[ -n $p ]] && { printf '%s' "$p"; return 0; }
    fi
    have_cmd iw || return 1
    p="$(iw dev 2>/dev/null | awk -v want="$i" '/^phy#/{phy=$0; sub(/^phy#/,"phy",phy)} $1=="Interface" && $2==want {print phy; exit}')"
    [[ -n $p ]] || return 1
    printf '%s' "$p"
}

iface_type() {
    local i="$1"
    have_cmd iw || return 1
    iw dev "$i" info 2>/dev/null | awk '$1=="type"{print $2; exit}'
}

iface_is_monitor() {
    [[ "$(iface_type "$1")" == monitor ]]
}

iface_up()   { ip link set "$1" up 2>/dev/null; }
iface_down() { ip link set "$1" down 2>/dev/null; }

iface_rfkill_unblock() {
    local blocked=0 f
    for f in /sys/class/rfkill/rfkill*/soft /sys/class/rfkill/rfkill*/hard; do
        [[ -r $f ]] || continue
        [[ "$(<"$f")" == 1 ]] && blocked=1
    done
    (( blocked )) || return 0
    if have_cmd rfkill; then
        log_info "clearing rfkill block"
        rfkill unblock all 2>/dev/null || true
    else
        for f in /sys/class/rfkill/rfkill*/soft; do
            [[ -w $f ]] && echo 0 >"$f" 2>/dev/null || true
        done
    fi
    for f in /sys/class/rfkill/rfkill*/hard; do
        [[ -r $f ]] || continue
        if [[ "$(<"$f")" == 1 ]]; then
            log_warn "a hardware rfkill switch is engaged; monitor mode will not work until it is off"
        fi
    done
    return 0
}

iface_stop_interferers() {
    local svc
    for svc in NetworkManager wpa_supplicant; do
        if have_cmd systemctl && systemctl is-active --quiet "$svc" 2>/dev/null; then
            log_info "stopping ${svc} (it fights monitor mode)"
            systemctl stop "$svc" 2>/dev/null || true
        elif pgrep -x "$svc" >/dev/null 2>&1; then
            log_info "killing ${svc} (it fights monitor mode)"
            pkill -x "$svc" 2>/dev/null || true
        fi
    done
    return 0
}

iface_chan_to_freq() {
    local ch="$1" band="${2:-auto}"
    [[ $ch =~ ^[0-9]+$ ]] || return 1
    case "$band" in
        2.4|2) (( ch == 14 )) && { echo 2484; return 0; }
               (( ch >= 1 && ch <= 13 )) && { echo $(( 2407 + ch * 5 )); return 0; }
               return 1 ;;
        5)     (( ch >= 1 && ch <= 196 )) && { echo $(( 5000 + ch * 5 )); return 0; }
               return 1 ;;
        6)     (( ch >= 1 && ch <= 233 )) && { echo $(( 5950 + ch * 5 )); return 0; }
               return 1 ;;
        auto)
            if (( ch == 14 )); then echo 2484; return 0; fi
            if (( ch >= 1 && ch <= 13 )); then echo $(( 2407 + ch * 5 )); return 0; fi
            if (( ch >= 32 && ch <= 196 )); then echo $(( 5000 + ch * 5 )); return 0; fi
            return 1 ;;
    esac
    return 1
}

iface_center_freq() {
    local ch="$1" width="$2"
    local center=""
    case "$width" in
        80MHz)
            case "$ch" in
                36|40|44|48) center=42 ;;
                52|56|60|64) center=58 ;;
                100|104|108|112) center=106 ;;
                116|120|124|128) center=122 ;;
                132|136|140|144) center=138 ;;
                149|153|157|161) center=155 ;;
                165|169|173|177) center=171 ;;
            esac
            ;;
        160MHz)
            case "$ch" in
                36|40|44|48|52|56|60|64) center=50 ;;
                100|104|108|112|116|120|124|128) center=114 ;;
                149|153|157|161|165|169|173|177) center=163 ;;
            esac
            ;;
    esac
    [[ -z $center ]] && return 1
    echo $(( 5000 + center * 5 ))
}

iface_set_channel() {
    local i="$1" ch="$2" width="${3:-}" band="${4:-auto}"
    [[ -z $ch ]] && return 0
    have_cmd iw || { log_warn "iw is not installed; cannot set a channel"; return 1; }

    case "$width" in
        80MHz|160MHz)
            local f center
            f="$(iface_chan_to_freq "$ch" "$band")" || { log_error "channel ${ch} is not valid for band ${band}"; return 1; }
            if center="$(iface_center_freq "$ch" "$width")"; then
                if iw dev "$i" set freq "$f" "$width" "$center" 2>/dev/null; then
                    log_ok "channel ${ch} (${f} MHz, ${width}, centre ${center} MHz)"
                    return 0
                fi
            else
                log_warn "no standard ${width} centre frequency for channel ${ch}"
            fi
            log_warn "${width} failed; falling back to a 20 MHz channel"
            width=""
            ;;
    esac

    if [[ -n $width ]]; then
        if iw dev "$i" set channel "$ch" "$width" 2>/dev/null; then
            log_ok "channel ${ch} (${width})"
            return 0
        fi
        log_warn "channel ${ch} ${width} rejected; trying plain 20 MHz"
    fi

    if iw dev "$i" set channel "$ch" 2>/dev/null; then
        log_ok "channel ${ch}"
        return 0
    fi

    local f
    if f="$(iface_chan_to_freq "$ch" "$band")" && iw dev "$i" set freq "$f" 2>/dev/null; then
        log_ok "channel ${ch} (${f} MHz)"
        return 0
    fi

    log_warn "could not set channel ${ch}"
    log_hint "The regulatory domain may forbid it. Try: iw reg set US" \
             "Check what the adapter allows: iw phy $(iface_phy "$i" 2>/dev/null || echo phy0) channels"
    return 1
}

iface_set_regdomain() {
    local cc="$1"
    [[ -z $cc ]] && return 0
    have_cmd iw || return 1
    if iw reg set "$cc" 2>/dev/null; then
        log_ok "regulatory domain set to ${cc}"
        return 0
    fi
    log_warn "could not set the regulatory domain to ${cc}"
    log_hint "The kernel needs regulatory.db in /lib/firmware (package: wireless-regdb)."
    return 1
}

iface_set_txpower() {
    local i="$1" mbm="$2"
    [[ -z $mbm ]] && return 0
    have_cmd iw || return 1
    if iw dev "$i" set txpower fixed "$mbm" 2>/dev/null; then
        log_ok "transmit power fixed at ${mbm} mBm"
    else
        log_warn "this driver does not allow a fixed transmit power"
    fi
    return 0
}

monitor_via_type() {
    local i="$1"
    have_cmd iw || return 1
    iface_down "$i"
    if iw dev "$i" set type monitor 2>/dev/null; then
        iface_up "$i"
        iface_is_monitor "$i" && { MON_IFACE="$i"; MON_METHOD="type"; return 0; }
    fi
    if iw dev "$i" set monitor control 2>/dev/null; then
        iface_up "$i"
        iface_is_monitor "$i" && { MON_IFACE="$i"; MON_METHOD="type-control"; return 0; }
    fi
    iface_up "$i"
    return 1
}

monitor_via_vif() {
    local base="$1" mon="$2" phy
    have_cmd iw || return 1
    phy="$(iface_phy "$base")" || return 1
    if iface_exists "$mon"; then
        log_debug "${mon} already exists"
    elif ! iw phy "$phy" interface add "$mon" type monitor 2>/dev/null; then
        return 1
    fi
    iface_down "$base" 2>/dev/null || true
    iface_up "$mon"
    if iface_is_monitor "$mon"; then
        MON_IFACE="$mon"; MON_METHOD="vif"
        return 0
    fi
    iw dev "$mon" del 2>/dev/null || true
    return 1
}

monitor_via_iwconfig() {
    local i="$1"
    have_cmd iwconfig || return 1
    iface_down "$i"
    if iwconfig "$i" mode monitor 2>/dev/null; then
        iface_up "$i"
        MON_IFACE="$i"; MON_METHOD="iwconfig"
        return 0
    fi
    iface_up "$i"
    return 1
}

monitor_enable() {
    local base="${1:-}" mon="${2:-}" strategy="${3:-auto}"

    if [[ -z $base ]]; then
        base="$(iface_any_wireless)" || {
            log_error "no wireless interface found"
            log_hint "The driver is loaded but no interface appeared. Usually the adapter is" \
                     "not attached to WSL yet. On Windows, run:" \
                     "  wifimon.ps1 attach" \
                     "then check here with: ip link && wifimon status"
            return 1
        }
        log_debug "auto-selected interface ${base}"
    fi
    iface_exists "$base" || { log_error "interface ${base} does not exist"; return 1; }

    MON_BASE="$base"
    if iface_is_monitor "$base"; then
        log_ok "${base} is already in monitor mode"
        MON_IFACE="$base"; MON_METHOD="pre-existing"
        return 0
    fi
    if [[ -n $mon ]] && iface_exists "$mon" && iface_is_monitor "$mon"; then
        log_ok "${mon} is already in monitor mode"
        MON_IFACE="$mon"; MON_METHOD="pre-existing"
        return 0
    fi

    MON_BASE="$base"
    iface_rfkill_unblock
    iface_stop_interferers

    [[ $strategy == auto ]] && strategy="${RECIPE_MONITOR:-type}"
    log_info "enabling monitor mode on ${base} (strategy: ${strategy})"

    if [[ $strategy == vif ]]; then
        mon="${mon:-${base}mon}"
        monitor_via_vif "$base" "$mon" && { log_ok "monitor interface ${MON_IFACE} up"; return 0; }
        log_warn "could not add a monitor interface; switching ${base} over instead"
    fi

    monitor_via_type "$base" && { log_ok "${MON_IFACE} is in monitor mode"; return 0; }

    if [[ $strategy != vif ]]; then
        mon="${mon:-${base}mon}"
        monitor_via_vif "$base" "$mon" && { log_ok "monitor interface ${MON_IFACE} up"; return 0; }
    fi

    monitor_via_iwconfig "$base" && { log_ok "${MON_IFACE} is in monitor mode (legacy ioctl)"; return 0; }

    log_error "could not put ${base} into monitor mode"
    log_hint "Kernel messages:"
    load_dmesg_tail 12
    log_hint "This driver may not support monitor mode. Check what it allows:" \
             "  iw phy $(iface_phy "$base" 2>/dev/null || echo phy0) info | grep -A8 'Supported interface modes'"
    return 1
}

monitor_disable() {
    local i="${1:-}"
    if [[ -z $i ]]; then
        i="$(state_get monitor_iface 2>/dev/null || true)"
        [[ -z $i ]] && i="$(iface_any_wireless || true)"
    fi
    [[ -z $i ]] && { log_error "no interface to restore"; return 1; }
    iface_exists "$i" || { log_warn "${i} is gone already"; return 0; }

    local base
    base="$(state_get base_iface 2>/dev/null || true)"
    if [[ "$(state_get monitor_method 2>/dev/null || true)" == vif ]]; then
        log_info "removing monitor interface ${i}"
        iface_down "$i"
        iw dev "$i" del 2>/dev/null || log_warn "could not remove ${i}"
        [[ -n $base ]] && iface_exists "$base" && iface_up "$base"
        log_ok "restored ${base:-base interface}"
        return 0
    fi

    log_info "returning ${i} to managed mode"
    iface_down "$i"
    if iw dev "$i" set type managed 2>/dev/null; then
        iface_up "$i"
        log_ok "${i} is back in managed mode"
        return 0
    fi
    iface_up "$i"
    log_warn "could not switch ${i} back; unloading and reloading the driver will reset it"
    return 1
}

iface_rx_packets() {
    local i="$1" f="/sys/class/net/$1/statistics/rx_packets"
    [[ -r $f ]] && { cat "$f"; return 0; }
    echo 0
}

monitor_verify() {
    local i="$1" seconds="${2:-4}"
    local type
    type="$(iface_type "$i" || true)"
    if [[ $type != monitor ]]; then
        log_error "${i} reports type '${type:-unknown}', not monitor"
        return 1
    fi
    if [[ "$(cat "/sys/class/net/${i}/operstate" 2>/dev/null || echo down)" == down ]]; then
        log_warn "${i} is administratively down; bringing it up"
        iface_up "$i"
    fi

    local before after delta
    before="$(iface_rx_packets "$i")"
    log_info "listening on ${i} for ${seconds}s to confirm frames are arriving"
    sleep "$seconds"
    after="$(iface_rx_packets "$i")"
    delta=$(( after - before ))

    if (( delta > 0 )); then
        log_ok "${delta} frame(s) captured in ${seconds}s - monitor mode is working"
        return 0
    fi

    log_warn "no frames captured in ${seconds}s"
    log_hint "Monitor mode is set but nothing is arriving. Usually one of:" \
             "  - the adapter is parked on a quiet channel: wifimon monitor --channel 6" \
             "  - no 802.11 traffic nearby on that channel" \
             "  - the antenna or USB connection is bad"
    return 1
}

monitor_summary() {
    local i="$1"
    (( WIFIMON_VERBOSITY >= 1 )) || return 0
    if have_cmd iw; then
        iw dev "$i" info 2>/dev/null | sed 's/^/    /' >&2
    else
        ip -brief link show "$i" 2>/dev/null | sed 's/^/    /' >&2
    fi
    printf '\n'  >&2
    log_hint "Capture with:" \
             "  airodump-ng ${i}" \
             "  airodump-ng --band abg ${i}" \
             "  tcpdump -i ${i} -w capture.pcap" \
             "  tshark -i ${i} -Y wlan.fc.type_subtype==8"
    return 0
}
