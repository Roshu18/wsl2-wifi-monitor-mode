# shellcheck shell=bash
# shellcheck disable=SC2034

[[ -n ${_WIFIMON_LOAD_SH:-} ]] && return 0
_WIFIMON_LOAD_SH=1

LOAD_METHOD=""

load_module_file() {
    local mod="$1" dest f
    dest="$(build_modules_target_dir)"
    for f in "${dest}/${mod}.ko" "${dest}/${mod//-/_}.ko" "${dest}/${mod//_/-}.ko"; do
        [[ -f $f ]] && { printf '%s' "$f"; return 0; }
    done
    f="$(modinfo -n "$mod" 2>/dev/null || true)"
    [[ -n $f && -f $f ]] && { printf '%s' "$f"; return 0; }
    return 1
}

load_expected_vermagic() {
    local ko="$1"
    modinfo -F vermagic "$ko" 2>/dev/null | head -1
}

load_check_vermagic() {
    local ko="$1" vm
    vm="$(load_expected_vermagic "$ko")"
    [[ -z $vm ]] && { log_debug "no vermagic in $(basename "$ko")"; return 0; }
    local rel="${vm%% *}"
    if [[ $rel == "$PLAT_KERNEL" ]]; then
        log_debug "vermagic release matches: ${vm}"
        return 0
    fi
    log_warn "version magic mismatch: module says '${rel}', kernel is '${PLAT_KERNEL}'"
    return 1
}

load_filter_params() {
    local ko="$1" params="$2"
    [[ -z $params ]] && return 0
    local -a known=() keep=()
    mapfile -t known < <(modinfo -p "$ko" 2>/dev/null | sed 's/:.*//' | awk 'NF')
    local p name
    for p in $params; do
        name="${p%%=*}"
        if (( ${#known[@]} == 0 )); then
            keep+=("$p")
            continue
        fi
        local found=0 k
        for k in "${known[@]}"; do
            [[ $k == "$name" ]] && { found=1; break; }
        done
        if (( found )); then
            keep+=("$p")
        else
            log_debug "dropping unsupported module parameter '${name}'"
        fi
    done
    printf '%s' "${keep[*]}"
}

load_unload_conflicts() {
    local m
    for m in ${RECIPE_CONFLICTS:-}; do
        if module_loaded "$m"; then
            log_info "unloading conflicting module ${m}"
            rmmod "$m" 2>/dev/null || rmmod -f "$m" 2>/dev/null || \
                log_warn "could not unload ${m}; it may keep the device busy"
        fi
    done
    return 0
}

load_deps() {
    local dep m
    for dep in ${RECIPE_DEPS:-}; do
        for m in $(build_dep_modules "$dep"); do
            module_builtin "$m" && continue
            module_loaded "$m" && continue
            if modprobe "$m" 2>/dev/null; then
                log_debug "loaded dependency ${m}"
            else
                local ko
                if ko="$(load_module_file "$m")" && insmod "$ko" 2>/dev/null; then
                    log_debug "inserted dependency ${m} directly"
                else
                    log_warn "could not load dependency ${m}"
                fi
            fi
        done
    done
    return 0
}

load_dmesg_tail() {
    local n="${1:-15}"
    have_cmd dmesg || return 0
    dmesg 2>/dev/null | tail -n "$n" | sed 's/^/    /' >&2 || true
    return 0
}

load_recipe() {
    local name="${1:-}"
    if [[ -n $name ]]; then
        registry_load "$name" || return 1
    elif [[ -z ${RECIPE_NAME:-} ]]; then
        log_error "no driver selected"
        return 1
    fi

    local primary
    primary="$(registry_primary_module)"

    if module_present "$primary"; then
        log_ok "${primary} is already available (loaded or built into the kernel)"
        LOAD_METHOD="already-loaded"
        return 0
    fi

    load_unload_conflicts
    load_deps

    local ko params=""
    if ko="$(load_module_file "$primary")"; then
        params="$(load_filter_params "$ko" "${RECIPE_MODPARAMS:-}")"
        load_check_vermagic "$ko" || true
    else
        log_warn "no module file found for ${primary}; trying modprobe anyway"
    fi

    log_info "loading ${primary}${params:+ ${params}}"
    # shellcheck disable=SC2086
    if modprobe "$primary" $params 2>/dev/null; then
        LOAD_METHOD="modprobe"
        log_ok "${primary} loaded"
        load_settle
        return 0
    fi

    if [[ -n $ko ]]; then
        log_warn "modprobe failed; inserting ${ko} directly"
        # shellcheck disable=SC2086
        if insmod "$ko" $params 2>/dev/null; then
            LOAD_METHOD="insmod"
            log_ok "${primary} loaded"
            load_settle
            return 0
        fi
        log_warn "clean insert failed; retrying with --force (version magic override)"
        # shellcheck disable=SC2086
        if insmod --force "$ko" $params 2>/dev/null; then
            LOAD_METHOD="insmod-force"
            log_warn "${primary} loaded with --force; it may be unstable if the kernel ABI differs"
            load_settle
            return 0
        fi
    fi

    log_error "could not load ${primary}"
    log_hint "Kernel messages:"
    load_dmesg_tail 15
    log_hint "If this says 'disagrees about version of symbol', rebuild against the running kernel:" \
             "  wifimon clean --kernel && wifimon setup" \
             "If it says 'Unknown symbol', a dependency module is missing: wifimon doctor"
    return 1
}

load_settle() {
    local tries=0
    while (( tries < 10 )); do
        if iface_any_wireless >/dev/null 2>&1; then
            log_debug "wireless interface appeared after ${tries} check(s)"
            return 0
        fi
        sleep 0.5
        tries=$(( tries + 1 ))
    done
    log_debug "no wireless interface yet after module load"
    return 0
}

unload_recipe() {
    local name="${1:-}"
    if [[ -n $name ]]; then
        registry_load "$name" || return 1
    fi
    local -a mods=()
    read -r -a mods <<<"${RECIPE_MODULES:-}"
    local i m rc=0
    for (( i = ${#mods[@]} - 1; i >= 0; i-- )); do
        m="${mods[i]}"
        module_loaded "$m" || continue
        log_info "unloading ${m}"
        if ! rmmod "$m" 2>/dev/null; then
            if rmmod -f "$m" 2>/dev/null; then
                log_warn "${m} needed a forced unload"
            else
                log_error "could not unload ${m} (still in use?)"
                rc=1
            fi
        fi
    done
    return "$rc"
}
