# shellcheck shell=bash
# shellcheck disable=SC2034

[[ -n ${_WIFIMON_DOCTOR_SH:-} ]] && return 0
_WIFIMON_DOCTOR_SH=1

DOC_PROBLEMS=0
DOC_WARNINGS=0
DOC_JSON=""

doc_row() {
    local status="$1" label="$2" value="$3" advice="${4:-}"
    local mark colour
    case "$status" in
        ok)   mark="ok  "; colour="$_C_GRN" ;;
        warn) mark="warn"; colour="$_C_YEL"; DOC_WARNINGS=$(( DOC_WARNINGS + 1 )) ;;
        fail) mark="FAIL"; colour="$_C_RED"; DOC_PROBLEMS=$(( DOC_PROBLEMS + 1 )) ;;
        *)    mark="info"; colour="$_C_DIM" ;;
    esac
    if [[ -n $DOC_JSON ]]; then
        printf '%s{"check":"%s","status":"%s","value":"%s","advice":"%s"}' \
            "$DOC_JSON_SEP" "$(json_escape "$label")" "$status" \
            "$(json_escape "$value")" "$(json_escape "$advice")"
        DOC_JSON_SEP=","
        return 0
    fi
    printf '  %s[%s]%s %-26s %s\n' "$colour" "$mark" "$_C_RESET" "$label" "$value"
    [[ -n $advice ]] && printf '         %s%s%s\n' "$_C_DIM" "$advice" "$_C_RESET"
    return 0
}

doc_section() {
    [[ -n $DOC_JSON ]] && return 0
    printf '\n%s%s%s\n' "$_C_BLD" "$1" "$_C_RESET"
    return 0
}

doctor_environment() {
    doc_section "Environment"
    case "$PLAT_WSL" in
        wsl2) doc_row ok "WSL flavour" "WSL2${PLAT_WSL_APP_VERSION:+ (app ${PLAT_WSL_APP_VERSION})}" ;;
        wsl1) doc_row fail "WSL flavour" "WSL1" "WSL1 has no kernel. Run: wsl --set-version ${WSL_DISTRO_NAME:-<distro>} 2" ;;
        *)    doc_row warn "WSL flavour" "not WSL (native Linux)" "Driver builds still work; USB passthrough is not needed." ;;
    esac
    doc_row info "Kernel" "$PLAT_KERNEL"
    if (( PLAT_MSFT_KERNEL )); then
        doc_row ok "Kernel origin" "Microsoft WSL kernel (series ${PLAT_KSERIES})"
    else
        doc_row warn "Kernel origin" "custom kernel ${PLAT_KVER}" "Source is taken from kernel.org; set WIFIMON_KSRC if you have the tree."
    fi
    doc_row info "Distro" "${PLAT_DISTRO:-unknown}${PLAT_PKGMGR:+ (${PLAT_PKGMGR})}"
    [[ -n $PLAT_WSL_KERNEL_REPORTED ]] && doc_row info "Windows reports kernel" "$PLAT_WSL_KERNEL_REPORTED"
    return 0
}

doctor_kernel_support() {
    doc_section "Kernel capabilities"
    if [[ -n $PLAT_CONFIG_SRC ]]; then
        doc_row ok "Kernel config" "$PLAT_CONFIG_SRC"
    else
        doc_row fail "Kernel config" "not found" "Need /proc/config.gz (CONFIG_IKCONFIG_PROC) or /boot/config-${PLAT_KERNEL}. Pass WIFIMON_KCONFIG=<file> to work around it."
    fi

    local modules
    modules="$(kconfig_get CONFIG_MODULES)"
    if [[ $modules == y ]]; then
        doc_row ok "Loadable modules" "enabled"
    else
        doc_row fail "Loadable modules" "${modules:-not enabled}" "This kernel cannot load out-of-tree drivers at all."
    fi

    if kconfig_is CONFIG_MODVERSIONS y; then
        if [[ -s "${KSRC_DIR:-}/Module.symvers" ]]; then
            doc_row ok "Symbol versioning" "on, CRCs recovered ($(wc -l <"${KSRC_DIR}/Module.symvers") symbols)"
        else
            doc_row warn "Symbol versioning" "on, CRCs not recovered" "Modules may need a forced load. Re-run: wifimon setup"
        fi
    else
        doc_row ok "Symbol versioning" "off (no CRC checks)"
    fi

    local cfg
    cfg="$(kconfig_get CONFIG_CFG80211)"
    case "$cfg" in
        y) doc_row ok "cfg80211" "built into the kernel" ;;
        m) doc_row ok "cfg80211" "available as a module" ;;
        *) if module_available cfg80211; then
               doc_row ok "cfg80211" "module present"
           else
               doc_row warn "cfg80211" "missing" "wifimon builds it from the kernel source when a driver needs it."
           fi ;;
    esac
    local mac
    mac="$(kconfig_get CONFIG_MAC80211)"
    case "$mac" in
        y) doc_row ok "mac80211" "built into the kernel" ;;
        m) doc_row ok "mac80211" "available as a module" ;;
        *) if module_available mac80211; then
               doc_row ok "mac80211" "module present"
           else
               doc_row warn "mac80211" "missing" "Needed by in-tree drivers; wifimon builds it on demand."
           fi ;;
    esac

    if platform_usbip_ready; then
        doc_row ok "USB/IP (vhci_hcd)" "supported"
    else
        doc_row warn "USB/IP (vhci_hcd)" "not detected" "WSL kernels 5.10.60.1+ include it. A very old kernel needs: wsl --update"
    fi
    return 0
}

doctor_toolchain() {
    doc_section "Toolchain"
    local -a missing=()
    mapfile -t missing < <(platform_missing_tools)
    if (( ${#missing[@]} == 0 )); then
        doc_row ok "Build dependencies" "all present"
    else
        doc_row warn "Build dependencies" "missing: ${missing[*]}" "Install them with: wifimon setup"
    fi
    local t
    for t in iw ip rfkill lsusb airodump-ng tcpdump; do
        if have_cmd "$t"; then
            doc_row ok "tool: ${t}" "$(command -v "$t")"
        else
            case "$t" in
                iw|ip) doc_row fail "tool: ${t}" "missing" "Required. Install: iw iproute2" ;;
                *)     doc_row warn "tool: ${t}" "missing" "Optional, used for capture and diagnostics." ;;
            esac
        fi
    done
    local avail
    avail="$(df -Pm "$WIFIMON_CACHE" 2>/dev/null | awk 'NR==2{print $4}')"
    if [[ $avail =~ ^[0-9]+$ ]]; then
        if (( avail < 3500 )); then
            doc_row warn "Free disk (cache)" "${avail} MB" "A first-time kernel source build wants about 3.5 GB."
        else
            doc_row ok "Free disk (cache)" "${avail} MB"
        fi
    fi
    return 0
}

doctor_kernel_tree() {
    doc_section "Kernel source"
    local tree=""
    if [[ -n ${KSRC_DIR:-} ]] && ksrc_tree_is_usable "$KSRC_DIR"; then
        tree="$KSRC_DIR"
    elif ksrc_tree_is_usable "${PLAT_MODULES_DIR}/build"; then
        tree="$(readlink -f "${PLAT_MODULES_DIR}/build")"
    fi
    if [[ -z $tree ]]; then
        doc_row warn "Prepared tree" "none" "Run: wifimon setup"
        return 0
    fi
    local uts
    uts="$(ksrc_tree_utsrelease "$tree" || echo unknown)"
    if [[ $uts == "$PLAT_KERNEL" ]]; then
        doc_row ok "Prepared tree" "$tree"
        doc_row ok "Version magic" "$uts"
    else
        doc_row warn "Prepared tree" "$tree" "Built for ${uts}, running ${PLAT_KERNEL}. Re-run: wifimon setup"
    fi
    return 0
}

doctor_drivers() {
    doc_section "Drivers"
    local dest
    dest="$(build_modules_target_dir)"
    local -a kos=()
    [[ -d $dest ]] && mapfile -t kos < <(find "$dest" -name '*.ko' -printf '%f\n' 2>/dev/null | sort)
    if (( ${#kos[@]} )); then
        doc_row ok "Built modules" "${#kos[@]} in ${dest}"
        local k
        for k in "${kos[@]}"; do
            local vm rel
            vm="$(modinfo -F vermagic "${dest}/${k}" 2>/dev/null | head -1)"
            rel="${vm%% *}"
            if [[ -z $vm ]]; then
                doc_row info "  ${k}" "no version magic"
            elif [[ $rel == "$PLAT_KERNEL" ]]; then
                doc_row ok "  ${k}" "matches running kernel"
            else
                doc_row warn "  ${k}" "built for ${rel}" "Rebuild: wifimon build --force"
            fi
        done
    else
        doc_row warn "Built modules" "none" "Run: wifimon setup"
    fi

    local loaded=""
    local name
    while read -r name; do
        registry_load "$name" >/dev/null 2>&1 || continue
        local m
        for m in $RECIPE_MODULES; do
            module_loaded "$m" && loaded="${loaded:+${loaded} }${m}"
        done
    done < <(registry_list)
    if [[ -n $loaded ]]; then
        doc_row ok "Loaded driver modules" "$loaded"
    else
        doc_row warn "Loaded driver modules" "none" "Run: wifimon load"
    fi
    return 0
}

doctor_devices() {
    doc_section "USB adapters"
    local rows=0 line
    while IFS= read -r line; do
        rows=$(( rows + 1 ))
        local ids chipset recipe name
        IFS=$'\t' read -r ids chipset recipe name <<<"$line"
        if [[ -n $recipe && $recipe != module:* ]]; then
            doc_row ok "${ids}" "${name} -> driver '${recipe}'"
        elif [[ $recipe == module:* ]]; then
            doc_row ok "${ids}" "${name} -> kernel module '${recipe#module:}'"
        else
            doc_row warn "${ids}" "${name:-unknown wireless device}" "Not in the adapter database. Pick a driver by hand: wifimon list-drivers"
        fi
    done < <(registry_detect || true)
    if (( rows == 0 )); then
        doc_row warn "Attached adapters" "none detected" "On Windows run: wifimon.ps1 attach   (or: usbipd attach --wsl --busid <id>)"
    fi
    return 0
}

doctor_interfaces() {
    doc_section "Interfaces"
    local -a ifs=()
    mapfile -t ifs < <(iface_list_wireless)
    if (( ${#ifs[@]} == 0 )); then
        doc_row warn "Wireless interfaces" "none" "Load a driver (wifimon load) after attaching the adapter."
        return 0
    fi
    local i
    for i in "${ifs[@]}"; do
        local t phy state
        t="$(iface_type "$i" || echo unknown)"
        phy="$(iface_phy "$i" || echo '?')"
        state="$(cat "/sys/class/net/${i}/operstate" 2>/dev/null || echo unknown)"
        if [[ $t == monitor ]]; then
            doc_row ok "${i} (${phy})" "monitor, link ${state}"
        else
            doc_row info "${i} (${phy})" "${t}, link ${state}"
        fi
    done
    local f blocked=0
    for f in /sys/class/rfkill/rfkill*/soft /sys/class/rfkill/rfkill*/hard; do
        [[ -r $f ]] && [[ "$(<"$f")" == 1 ]] && blocked=1
    done
    if (( blocked )); then
        doc_row warn "rfkill" "a radio is blocked" "Clear it with: rfkill unblock all"
    else
        doc_row ok "rfkill" "no blocks"
    fi
    return 0
}

doctor_run() {
    local json="${1:-0}"
    if (( json )); then
        DOC_JSON=1
        DOC_JSON_SEP=""
        printf '{"kernel":"%s","wsl":"%s","distro":"%s","checks":[' \
            "$(json_escape "$PLAT_KERNEL")" "$(json_escape "$PLAT_WSL")" "$(json_escape "${PLAT_DISTRO:-}")"
    else
        printf '%swifimon %s diagnostics%s\n' "$_C_BLD" "$WIFIMON_VERSION" "$_C_RESET"
    fi

    doctor_environment
    doctor_kernel_support
    doctor_toolchain
    doctor_kernel_tree
    doctor_drivers
    doctor_devices
    doctor_interfaces

    if (( json )); then
        printf '],"problems":%d,"warnings":%d}\n' "$DOC_PROBLEMS" "$DOC_WARNINGS"
        return 0
    fi

    printf '\n'
    if (( DOC_PROBLEMS )); then
        log_error "${DOC_PROBLEMS} problem(s), ${DOC_WARNINGS} warning(s)"
        return 1
    fi
    if (( DOC_WARNINGS )); then
        log_warn "no blocking problems, ${DOC_WARNINGS} warning(s)"
        return 0
    fi
    log_ok "everything checks out"
    return 0
}
