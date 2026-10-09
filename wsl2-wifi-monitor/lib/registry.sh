# shellcheck shell=bash
# shellcheck disable=SC2034

[[ -n ${_WIFIMON_REGISTRY_SH:-} ]] && return 0
_WIFIMON_REGISTRY_SH=1

RECIPE_NAME="" RECIPE_DESC="" RECIPE_TYPE="" RECIPE_CHIPSETS=""
RECIPE_MODULES="" RECIPE_REPO="" RECIPE_REF="" RECIPE_MAKE_ARGS=""
RECIPE_KCONFIG="" RECIPE_KPATHS="" RECIPE_DEPS="" RECIPE_MODPARAMS=""
RECIPE_FIRMWARE="" RECIPE_MONITOR="" RECIPE_NOTES="" RECIPE_MIN_KERNEL=""
RECIPE_CONFLICTS=""

registry_dirs() {
    local d
    for d in "${WIFIMON_ROOT}/drivers" "${WIFIMON_ETC}/drivers"; do
        [[ -d $d ]] && printf '%s\n' "$d"
    done
}

registry_list() {
    local d f
    while read -r d; do
        for f in "$d"/*.recipe; do
            [[ -e $f ]] || continue
            basename "$f" .recipe
        done
    done < <(registry_dirs) | sort -u
}

registry_path() {
    local name="$1" d
    while read -r d; do
        [[ -r "${d}/${name}.recipe" ]] && { printf '%s' "${d}/${name}.recipe"; return 0; }
    done < <(registry_dirs | tac)
    return 1
}

registry_reset() {
    RECIPE_NAME="" RECIPE_DESC="" RECIPE_TYPE="" RECIPE_CHIPSETS=""
    RECIPE_MODULES="" RECIPE_REPO="" RECIPE_REF="" RECIPE_MAKE_ARGS=""
    RECIPE_KCONFIG="" RECIPE_KPATHS="" RECIPE_DEPS="" RECIPE_MODPARAMS=""
    RECIPE_FIRMWARE="" RECIPE_MONITOR="" RECIPE_NOTES="" RECIPE_MIN_KERNEL=""
    RECIPE_CONFLICTS=""
    unset -f recipe_post_fetch recipe_pre_build 2>/dev/null || true
}

registry_load() {
    local name="$1" path
    path="$(registry_path "$name")" || { log_error "unknown driver recipe '${name}'"; return 1; }
    registry_reset
    # shellcheck disable=SC1090
    source "$path" || { log_error "failed to read recipe ${path}"; return 1; }
    RECIPE_NAME="${RECIPE_NAME:-$name}"
    registry_validate || return 1
    log_debug "loaded recipe ${RECIPE_NAME} (${RECIPE_TYPE}) from ${path}"
    return 0
}

registry_validate() {
    local ok=1
    [[ -n $RECIPE_NAME ]]    || { log_error "recipe has no RECIPE_NAME"; ok=0; }
    [[ -n $RECIPE_MODULES ]] || { log_error "${RECIPE_NAME}: RECIPE_MODULES is empty"; ok=0; }
    case "$RECIPE_TYPE" in
        oot)
            [[ -n $RECIPE_REPO ]] || { log_error "${RECIPE_NAME}: out-of-tree recipe needs RECIPE_REPO"; ok=0; }
            ;;
        intree)
            [[ -n $RECIPE_KPATHS ]] || { log_error "${RECIPE_NAME}: in-tree recipe needs RECIPE_KPATHS"; ok=0; }
            [[ -n $RECIPE_KCONFIG ]] || { log_error "${RECIPE_NAME}: in-tree recipe needs RECIPE_KCONFIG"; ok=0; }
            ;;
        *) log_error "${RECIPE_NAME}: RECIPE_TYPE must be 'oot' or 'intree' (got '${RECIPE_TYPE}')"; ok=0 ;;
    esac
    case "${RECIPE_MONITOR:-type}" in
        type|vif) ;;
        *) log_error "${RECIPE_NAME}: RECIPE_MONITOR must be 'type' or 'vif'"; ok=0 ;;
    esac
    (( ok ))
}

registry_primary_module() {
    local -a mods
    read -r -a mods <<<"$RECIPE_MODULES"
    printf '%s' "${mods[-1]}"
}

registry_show() {
    local name="$1"
    registry_load "$name" || return 1
    printf '%s\n' "$RECIPE_NAME"
    printf '  description : %s\n' "${RECIPE_DESC:-}"
    printf '  type        : %s\n' "$RECIPE_TYPE"
    printf '  chipsets    : %s\n' "${RECIPE_CHIPSETS:-}"
    printf '  modules     : %s\n' "$RECIPE_MODULES"
    [[ -n $RECIPE_REPO ]]      && printf '  source      : %s (%s)\n' "$RECIPE_REPO" "${RECIPE_REF:-default branch}"
    [[ -n $RECIPE_KPATHS ]]    && printf '  kernel paths: %s\n' "$RECIPE_KPATHS"
    [[ -n $RECIPE_DEPS ]]      && printf '  needs       : %s\n' "$RECIPE_DEPS"
    [[ -n $RECIPE_FIRMWARE ]]  && printf '  firmware    : %s\n' "$RECIPE_FIRMWARE"
    [[ -n $RECIPE_MODPARAMS ]] && printf '  parameters  : %s\n' "$RECIPE_MODPARAMS"
    [[ -n $RECIPE_CONFLICTS ]] && printf '  conflicts   : %s\n' "$RECIPE_CONFLICTS"
    [[ -n $RECIPE_MIN_KERNEL ]] && printf '  min kernel  : %s\n' "$RECIPE_MIN_KERNEL"
    printf '  monitor via : %s\n' "${RECIPE_MONITOR:-type}"
    [[ -n $RECIPE_NOTES ]]     && printf '  notes       : %s\n' "$RECIPE_NOTES"
    local ids
    ids="$(registry_ids_for_recipe "$name" | tr '\n' ' ')"
    [[ -n $ids ]] && printf '  usb ids     : %s\n' "$ids"
    return 0
}

registry_recipe_supported() {
    [[ -z $RECIPE_MIN_KERNEL ]] && return 0
    ver_ge "$PLAT_KVER" "$RECIPE_MIN_KERNEL"
}

adapters_files() {
    local f
    for f in "${WIFIMON_ROOT}/data/adapters.tsv" "${WIFIMON_ETC}/adapters.tsv"; do
        [[ -r $f ]] && printf '%s\n' "$f"
    done
}

adapters_rows() {
    local f
    while read -r f; do
        awk 'NF && $0 !~ /^[[:space:]]*#/' "$f"
    done < <(adapters_files)
}

adapter_lookup() {
    local vid="${1,,}" pid="${2,,}"
    adapters_rows | awk -F'\t' -v v="$vid" -v p="$pid" '
        { gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $2) }
        tolower($1) == v && tolower($2) == p { print; exit }'
}

registry_ids_for_recipe() {
    local name="$1"
    adapters_rows | awk -F'\t' -v r="$name" '$4 == r { printf "%s:%s\n", tolower($1), tolower($2) }' | sort -u
}

usb_devices() {
    local dev vid pid
    for dev in /sys/bus/usb/devices/*; do
        [[ -r "${dev}/idVendor" && -r "${dev}/idProduct" ]] || continue
        vid="$(<"${dev}/idVendor")"; pid="$(<"${dev}/idProduct")"
        [[ $vid == 0000 ]] && continue
        local manuf="" prod=""
        [[ -r "${dev}/manufacturer" ]] && manuf="$(tr -d '\n' <"${dev}/manufacturer" 2>/dev/null || true)"
        [[ -r "${dev}/product" ]] && prod="$(tr -d '\n' <"${dev}/product" 2>/dev/null || true)"
        printf '%s\t%s\t%s\t%s\t%s\n' "${vid,,}" "${pid,,}" "$(basename "$dev")" "$manuf" "$prod"
    done
}

usb_devices_lsusb() {
    have_cmd lsusb || return 1
    lsusb 2>/dev/null | sed -n 's/^Bus \([0-9]*\) Device \([0-9]*\): ID \([0-9a-fA-F]*\):\([0-9a-fA-F]*\) \(.*\)$/\3\t\4\t\1-\2\t\t\5/p'
}

device_modalias_recipe() {
    local syspath="$1"
    local alias_file="/sys/bus/usb/devices/${syspath}/modalias"
    [[ -r $alias_file ]] || return 1
    local alias mod
    alias="$(<"$alias_file")"
    mod="$(modprobe -R "$alias" 2>/dev/null | head -1 || true)"
    [[ -z $mod ]] && return 1
    local name
    while read -r name; do
        registry_load "$name" >/dev/null 2>&1 || continue
        local m
        for m in $RECIPE_MODULES; do
            [[ ${m//-/_} == "${mod//-/_}" ]] && { printf '%s' "$name"; return 0; }
        done
    done < <(registry_list)
    printf 'module:%s' "$mod"
    return 0
}

registry_detect() {
    local found=0 row vid pid syspath manuf prod hit chipset recipe name
    while IFS=$'\t' read -r vid pid syspath manuf prod; do
        [[ -z $vid ]] && continue
        hit="$(adapter_lookup "$vid" "$pid" || true)"
        if [[ -n $hit ]]; then
            IFS=$'\t' read -r _ _ chipset recipe name <<<"$hit"
            printf '%s:%s\t%s\t%s\t%s\n' "$vid" "$pid" "$chipset" "$recipe" "${name:-${prod:-unknown}}"
            found=1
            continue
        fi
        local guess
        guess="$(device_modalias_recipe "$syspath" || true)"
        if [[ -n $guess ]]; then
            printf '%s:%s\t%s\t%s\t%s\n' "$vid" "$pid" "unknown" "$guess" "${prod:-${manuf:-unknown}}"
            found=1
            continue
        fi
        case "${prod} ${manuf}" in
            *[Ww][Ll][Aa][Nn]*|*[Ww][Ii]-[Ff][Ii]*|*[Ww][Ii][Ff][Ii]*|*802.11*|*[Ww][Ii][Rr][Ee][Ll][Ee][Ss][Ss]*)
                printf '%s:%s\t%s\t%s\t%s\n' "$vid" "$pid" "unknown" "" "${prod:-${manuf}}"
                found=1
                ;;
        esac
    done < <(usb_devices)
    (( found ))
}
