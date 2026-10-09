# shellcheck shell=bash
# shellcheck disable=SC2034

[[ -n ${_WIFIMON_KSRC_SH:-} ]] && return 0
_WIFIMON_KSRC_SH=1

KSRC_REPO="${KSRC_REPO:-https://github.com/microsoft/WSL2-Linux-Kernel}"
KSRC_MAINLINE_CDN="${KSRC_MAINLINE_CDN:-https://cdn.kernel.org/pub/linux/kernel}"
KSRC_DIR=""
KSRC_REF=""
KSRC_ORIGIN=""
KSRC_SYMVERS_SYMBOLS=0
KSRC_VERMAGIC_EXACT=0

ksrc_cache_root() { printf '%s/kernel' "$WIFIMON_CACHE"; }
ksrc_stamp_file() { printf '%s/.wifimon-prepared' "$1"; }

ksrc_tree_is_usable() {
    local d="$1"
    [[ -n $d && -d $d ]] || return 1
    [[ -f "$d/Makefile" ]] || return 1
    [[ -f "$d/include/generated/autoconf.h" ]] || return 1
    [[ -f "$d/include/generated/utsrelease.h" ]] || return 1
    [[ -x "$d/scripts/mod/modpost" || -f "$d/scripts/mod/modpost" ]] || return 1
    return 0
}

ksrc_tree_utsrelease() {
    local d="$1" f="$1/include/generated/utsrelease.h"
    [[ -r $f ]] || return 1
    sed -n 's/^#define UTS_RELEASE "\(.*\)"$/\1/p' "$f" | head -1
}

ksrc_adopt_existing() {
    local candidates=() d
    [[ -n ${WIFIMON_KSRC:-} ]] && candidates+=("$WIFIMON_KSRC")
    candidates+=("${PLAT_MODULES_DIR}/build" "/usr/src/linux-headers-${PLAT_KERNEL}" "/usr/src/linux")
    for d in "${candidates[@]}"; do
        [[ -L $d ]] && d="$(readlink -f "$d" 2>/dev/null || printf '%s' "$d")"
        ksrc_tree_is_usable "$d" || continue
        local uts
        uts="$(ksrc_tree_utsrelease "$d" || true)"
        if [[ $uts == "$PLAT_KERNEL" ]]; then
            KSRC_DIR="$d"; KSRC_ORIGIN="existing"; KSRC_VERMAGIC_EXACT=1
            log_ok "using prepared kernel tree: $d"
            return 0
        fi
        log_debug "tree $d has UTS_RELEASE='${uts:-?}', expected '${PLAT_KERNEL}'"
    done
    return 1
}

ksrc_list_tags() {
    local series="$1"
    if have_cmd git; then
        local out
        if out="$(retry 3 2 -- git ls-remote --tags --refs "$KSRC_REPO" "refs/tags/linux-msft-wsl-${series}.*" 2>/dev/null)"; then
            sed -n 's#.*refs/tags/linux-msft-wsl-\(.*\)$#\1#p' <<<"$out" | awk 'NF'
            return 0
        fi
    fi
    local api="https://api.github.com/repos/microsoft/WSL2-Linux-Kernel/tags?per_page=100"
    local json=""
    if have_cmd curl; then
        json="$(retry 3 2 -- curl -fsSL --connect-timeout 20 "$api" 2>/dev/null || true)"
    elif have_cmd wget; then
        json="$(retry 3 2 -- wget -qO- -T 20 "$api" 2>/dev/null || true)"
    fi
    [[ -z $json ]] && return 1
    if have_cmd jq; then
        jq -r '.[].name' <<<"$json" 2>/dev/null | sed -n "s/^linux-msft-wsl-\(${series}\..*\)$/\1/p"
    else
        grep -o '"name": *"linux-msft-wsl-[0-9.]*"' <<<"$json" \
            | sed 's/.*linux-msft-wsl-//; s/"$//' | grep "^${series}\." || true
    fi
}

ksrc_pick_tag() {
    local want="$1" series="$2"
    local -a tags=()
    mapfile -t tags < <(ksrc_list_tags "$series" | sort -u)
    (( ${#tags[@]} == 0 )) && return 1

    local t
    for t in "${tags[@]}"; do
        [[ $t == "$want" ]] && { printf '%s' "$t"; return 0; }
    done

    local best_le="" best_gt=""
    for t in "${tags[@]}"; do
        if ver_ge "$want" "$t"; then
            if [[ -z $best_le ]] || ver_gt "$t" "$best_le"; then
                best_le="$t"
            fi
        else
            if [[ -z $best_gt ]] || ver_lt "$t" "$best_gt"; then
                best_gt="$t"
            fi
        fi
    done
    if [[ -n $best_le ]]; then printf '%s' "$best_le"; return 0; fi
    if [[ -n $best_gt ]]; then printf '%s' "$best_gt"; return 0; fi
    return 1
}

ksrc_resolve_ref() {
    local want="$PLAT_KVER" series="$PLAT_KSERIES"

    if [[ -n ${WIFIMON_KERNEL_REF:-} ]]; then
        KSRC_REF="${WIFIMON_KERNEL_REF}"
        log_info "using pinned kernel ref: ${KSRC_REF}"
        return 0
    fi

    if (( ! PLAT_MSFT_KERNEL )); then
        KSRC_REF="mainline:${want}"
        log_info "non-Microsoft kernel ${PLAT_KERNEL}; will try mainline source ${want}"
        return 0
    fi

    log_info "resolving kernel source for ${PLAT_KERNEL} (series ${series})"
    local tag
    if tag="$(ksrc_pick_tag "$want" "$series")"; then
        KSRC_REF="tag:linux-msft-wsl-${tag}"
        if [[ $tag == "$want" ]]; then
            log_ok "exact source tag: linux-msft-wsl-${tag}"
        else
            log_warn "no tag for ${want}; closest in series is linux-msft-wsl-${tag}"
        fi
        return 0
    fi

    local branch="linux-msft-wsl-${series}.y"
    if ksrc_ref_exists "heads/${branch}"; then
        KSRC_REF="branch:${branch}"
        log_warn "no tags for series ${series}; using branch ${branch}"
        return 0
    fi

    if ksrc_ref_exists "heads/master"; then
        KSRC_REF="branch:master"
        log_warn "falling back to the master branch of the WSL2 kernel repo"
        return 0
    fi
    return 1
}

ksrc_ref_exists() {
    local ref="$1"
    have_cmd git || return 1
    local out
    out="$(git ls-remote "$KSRC_REPO" "refs/${ref}" 2>/dev/null || true)"
    [[ -n $out ]]
}

ksrc_check_space() {
    local need_mb="${1:-3500}" dir="$2"
    mkdir -p "$dir" 2>/dev/null || true
    local avail_mb
    avail_mb="$(df -Pm "$dir" 2>/dev/null | awk 'NR==2{print $4}')"
    [[ $avail_mb =~ ^[0-9]+$ ]] || return 0
    if (( avail_mb < need_mb )); then
        log_error "only ${avail_mb} MB free on $(df -P "$dir" | awk 'NR==2{print $6}'), need about ${need_mb} MB"
        log_hint "Free space, or point the cache at a bigger filesystem:" \
                 "  WIFIMON_CACHE=/mnt/c/wifimon-cache wifimon setup" \
                 "In Windows, a WSL disk can also be grown with: wsl --manage <distro> --resize <size>"
        return 1
    fi
    log_debug "disk check ok: ${avail_mb} MB free in ${dir}"
    return 0
}

ksrc_fetch() {
    local ref="$KSRC_REF" kind="${KSRC_REF%%:*}" name="${KSRC_REF#*:}"
    local dest
    dest="$(ksrc_cache_root)/${name//\//_}"
    KSRC_DIR="$dest"

    if [[ -f "$dest/Makefile" ]]; then
        log_info "reusing cached source: $dest"
        KSRC_ORIGIN="cache"
        return 0
    fi

    ksrc_check_space 3500 "$(ksrc_cache_root)" || return 1

    local url tarball
    case "$kind" in
        tag)      url="${KSRC_REPO}/archive/refs/tags/${name}.tar.gz" ;;
        branch)   url="${KSRC_REPO}/archive/refs/heads/${name}.tar.gz" ;;
        mainline)
            local major="${name%%.*}"
            url="${KSRC_MAINLINE_CDN}/v${major}.x/linux-${name}.tar.xz"
            ;;
        *) log_error "unknown kernel ref '${ref}'"; return 1 ;;
    esac

    tarball="${WIFIMON_CACHE}/downloads/$(basename "$url")"
    log_info "downloading kernel source: ${url}"
    if http_get "$url" "$tarball"; then
        local tmp="${dest}.incoming.$$"
        rm -rf "$tmp"; mkdir -p "$tmp"
        log_info "extracting $(basename "$tarball")"
        if tar -xf "$tarball" --strip-components=1 -C "$tmp" 2>/dev/null; then
            rm -rf "$dest"
            mv "$tmp" "$dest"
            KSRC_ORIGIN="tarball"
            log_ok "kernel source at ${dest}"
            return 0
        fi
        log_warn "extraction failed; falling back to git"
        rm -rf "$tmp" "$tarball"
    else
        log_warn "download failed; falling back to git"
    fi

    [[ $kind == mainline ]] && { log_error "could not fetch mainline source for ${name}"; return 1; }
    have_cmd git || { log_error "git is required for the fallback clone"; return 1; }

    log_info "cloning ${name} (shallow)"
    rm -rf "$dest"
    if retry 3 4 -- run_quiet "git clone" git clone --depth=1 --branch "$name" "${KSRC_REPO}.git" "$dest"; then
        KSRC_ORIGIN="git"
        log_ok "kernel source at ${dest}"
        return 0
    fi
    log_error "could not obtain kernel source for ${name}"
    return 1
}

ksrc_place_config() {
    local src="$KSRC_DIR"
    if platform_kconfig_cat >"${src}/.config" 2>/dev/null && [[ -s "${src}/.config" ]]; then
        log_ok "config taken from ${PLAT_CONFIG_SRC}"
        return 0
    fi
    rm -f "${src}/.config"
    local shipped
    for shipped in "${src}/Microsoft/config-wsl" "${src}/arch/x86/configs/wsl_defconfig" \
                   "${src}/Microsoft/config-wsl-arm64"; do
        if [[ -r $shipped ]]; then
            cp "$shipped" "${src}/.config"
            log_warn "running kernel config unavailable; using shipped $(basename "$shipped")"
            log_hint "This can produce an ABI mismatch. Rebuild WSL's kernel config into the" \
                     "guest by enabling CONFIG_IKCONFIG_PROC, or pass a known-good config:" \
                     "  WIFIMON_KCONFIG=/path/to/config wifimon setup"
            return 0
        fi
    done
    log_error "no kernel config found (tried /proc/config.gz, /boot, and the source tree)"
    return 1
}

ksrc_config_set() {
    local src="$KSRC_DIR" op="$1" sym="$2" val="${3:-}"
    local scfg="${src}/scripts/config"
    local bare="${sym#CONFIG_}"
    if [[ -x $scfg ]]; then
        case "$op" in
            disable) "$scfg" --file "${src}/.config" --disable "$bare" 2>/dev/null && return 0 ;;
            enable)  "$scfg" --file "${src}/.config" --enable "$bare" 2>/dev/null && return 0 ;;
            module)  "$scfg" --file "${src}/.config" --module "$bare" 2>/dev/null && return 0 ;;
            string)  "$scfg" --file "${src}/.config" --set-str "$bare" "$val" 2>/dev/null && return 0 ;;
        esac
    fi
    local f="${src}/.config"
    case "$op" in
        disable)
            sed -i "s|^${sym}=.*|# ${sym} is not set|" "$f"
            grep -q "^# ${sym} is not set" "$f" || printf '# %s is not set\n' "$sym" >>"$f"
            ;;
        enable)  ksrc_config_put "$f" "$sym" "y" ;;
        module)  ksrc_config_put "$f" "$sym" "m" ;;
        string)  ksrc_config_put "$f" "$sym" "\"${val}\"" ;;
    esac
}

ksrc_config_put() {
    local f="$1" sym="$2" val="$3"
    sed -i "/^${sym}=/d; /^# ${sym} is not set$/d" "$f"
    printf '%s=%s\n' "$sym" "$val" >>"$f"
}

ksrc_sanitize_config() {
    local src="$KSRC_DIR" sym
    log_info "adjusting config for out-of-tree module builds"

    for sym in CONFIG_DEBUG_INFO_BTF CONFIG_DEBUG_INFO_BTF_MODULES CONFIG_MODULE_SIG_ALL \
               CONFIG_MODULE_SIG_FORCE CONFIG_GCC_PLUGINS CONFIG_RUST CONFIG_WERROR \
               CONFIG_LTO_CLANG CONFIG_LTO_CLANG_FULL CONFIG_LTO_CLANG_THIN \
               CONFIG_LOCALVERSION_AUTO CONFIG_IKHEADERS; do
        ksrc_config_set disable "$sym"
    done

    ksrc_config_set string CONFIG_SYSTEM_TRUSTED_KEYS ""
    ksrc_config_set string CONFIG_SYSTEM_REVOCATION_KEYS ""
    ksrc_config_set string CONFIG_LOCALVERSION "${PLAT_KSUFFIX}"
    ksrc_config_set enable CONFIG_MODULES
    ksrc_config_set enable CONFIG_MODULE_UNLOAD
    ksrc_config_set enable CONFIG_MODULE_FORCE_UNLOAD

    if grep -qE '^CONFIG_DEBUG_INFO=y' "${src}/.config" 2>/dev/null; then
        ksrc_config_set enable CONFIG_DEBUG_INFO_NONE
        log_debug "disabled kernel debug info to speed the build up"
    fi

    if grep -qE '^CONFIG_(GCC_PLUGIN_)?RANDSTRUCT' "${src}/.config" 2>/dev/null; then
        log_warn "this kernel uses structure layout randomisation (RANDSTRUCT)"
        log_hint "Out-of-tree modules cannot match the randomisation seed, so a module may" \
                 "load and then misbehave. Microsoft's own WSL kernels do not enable this."
    fi
}

ksrc_prepare() {
    local src="$KSRC_DIR"
    local stamp
    stamp="$(ksrc_stamp_file "$src")"

    if [[ -r $stamp ]] && grep -qx "${PLAT_KERNEL}" "$stamp" 2>/dev/null && ksrc_tree_is_usable "$src"; then
        log_ok "kernel tree already prepared for ${PLAT_KERNEL}"
        [[ "$(ksrc_tree_utsrelease "$src")" == "$PLAT_KERNEL" ]] && KSRC_VERMAGIC_EXACT=1
        ksrc_build_symvers
        ksrc_link_build_dir
        return 0
    fi

    [[ -n ${WIFIMON_KCONFIG:-} ]] && PLAT_CONFIG_SRC="$WIFIMON_KCONFIG"
    ksrc_place_config || return 1
    ksrc_sanitize_config

    local jobs
    jobs="$(nproc_safe)"
    local -a mk=(make -C "$src" ARCH=x86_64)
    have_cmd ccache && mk+=("CC=ccache gcc")

    log_info "normalising config (olddefconfig)"
    run_quiet "olddefconfig" "${mk[@]}" olddefconfig || {
        log_error "olddefconfig failed"
        return 1
    }

    local srcver
    srcver="$(make -C "$src" -s kernelversion 2>/dev/null || true)"
    if [[ -n $srcver && $srcver != "$PLAT_KVER" ]]; then
        log_warn "source tree is ${srcver} but the running kernel is ${PLAT_KVER}"
    fi

    log_info "building kernel scripts and module headers (-j${jobs}, this is the slow part)"
    if ! run_quiet "modules_prepare" "${mk[@]}" -j"$jobs" modules_prepare; then
        log_warn "modules_prepare failed; retrying serially for a clearer error"
        run_quiet "modules_prepare (serial)" "${mk[@]}" modules_prepare || {
            log_error "could not prepare the kernel tree"
            log_hint "The full build log is in ${WIFIMON_LOG_FILE}"
            return 1
        }
    fi

    ksrc_pin_utsrelease
    ksrc_build_symvers
    ksrc_link_build_dir

    printf '%s\n' "$PLAT_KERNEL" | atomic_write "$stamp"
    log_ok "kernel tree prepared"
    return 0
}

ksrc_pin_utsrelease() {
    local f="${KSRC_DIR}/include/generated/utsrelease.h"
    local have
    have="$(ksrc_tree_utsrelease "$KSRC_DIR" || true)"
    if [[ $have == "$PLAT_KERNEL" ]]; then
        KSRC_VERMAGIC_EXACT=1
        log_ok "version magic matches the running kernel (${PLAT_KERNEL})"
        return 0
    fi
    log_info "pinning UTS_RELEASE: '${have:-unset}' -> '${PLAT_KERNEL}'"
    printf '#define UTS_RELEASE "%s"\n' "$PLAT_KERNEL" | atomic_write "$f"
    if [[ "$(ksrc_tree_utsrelease "$KSRC_DIR")" == "$PLAT_KERNEL" ]]; then
        KSRC_VERMAGIC_EXACT=1
        log_ok "version magic pinned to ${PLAT_KERNEL}"
    else
        log_warn "could not pin version magic; modules may need a forced load"
    fi
}

ksrc_build_symvers() {
    local src="$KSRC_DIR"
    if ! grep -qx 'CONFIG_MODVERSIONS=y' "${src}/.config" 2>/dev/null; then
        log_debug "CONFIG_MODVERSIONS is off; no symbol CRCs needed"
        KSRC_SYMVERS_SYMBOLS=-1
        return 0
    fi
    if [[ -s "${src}/Module.symvers" ]]; then
        KSRC_SYMVERS_SYMBOLS="$(wc -l <"${src}/Module.symvers")"
        log_debug "Module.symvers already present (${KSRC_SYMVERS_SYMBOLS} symbols)"
        return 0
    fi

    log_info "reconstructing symbol CRCs from the running kernel"
    local out="${src}/Module.symvers" stats
    if stats="$(python3 -I "${WIFIMON_LIB}/symvers.py" --modules-dir "${PLAT_MODULES_DIR}" --out "$out" 2>&1)"; then
        KSRC_SYMVERS_SYMBOLS="$(sed -n 's/^symbols=\([0-9]*\).*/\1/p' <<<"$stats" | head -1)"
        KSRC_SYMVERS_SYMBOLS="${KSRC_SYMVERS_SYMBOLS:-0}"
        log_debug "symvers: ${stats//$'\n'/ }"
        if (( KSRC_SYMVERS_SYMBOLS >= 500 )); then
            log_ok "recovered ${KSRC_SYMVERS_SYMBOLS} symbol CRCs; modules can load without --force"
        else
            log_warn "only ${KSRC_SYMVERS_SYMBOLS} symbol CRCs recovered; a forced load may be required"
            rm -f "$out"
        fi
    else
        log_warn "symbol CRC reconstruction failed: ${stats//$'\n'/ }"
        KSRC_SYMVERS_SYMBOLS=0
    fi
    return 0
}

ksrc_link_build_dir() {
    local md="$PLAT_MODULES_DIR"
    mkdir -p "$md" 2>/dev/null || true
    local f
    for f in modules.builtin modules.order; do
        [[ -e "${md}/${f}" ]] || : >"${md}/${f}" 2>/dev/null || true
    done
    if [[ -e "${md}/build" && ! -L "${md}/build" ]]; then
        log_debug "${md}/build exists and is not a symlink; leaving it alone"
        return 0
    fi
    ln -sfn "$KSRC_DIR" "${md}/build" 2>/dev/null \
        && log_debug "linked ${md}/build -> ${KSRC_DIR}"
    ln -sfn "$KSRC_DIR" "${md}/source" 2>/dev/null || true
    return 0
}

ksrc_ensure() {
    platform_require_wsl2
    if [[ -n ${WIFIMON_KSRC:-} ]] && ksrc_tree_is_usable "$WIFIMON_KSRC"; then
        KSRC_DIR="$WIFIMON_KSRC"; KSRC_ORIGIN="override"
        [[ "$(ksrc_tree_utsrelease "$KSRC_DIR")" == "$PLAT_KERNEL" ]] && KSRC_VERMAGIC_EXACT=1
        log_ok "using kernel tree from WIFIMON_KSRC: ${KSRC_DIR}"
        ksrc_build_symvers
        ksrc_link_build_dir
        return 0
    fi
    if [[ -z ${WIFIMON_FORCE_KSRC:-} ]] && ksrc_adopt_existing; then
        ksrc_build_symvers
        return 0
    fi
    ksrc_resolve_ref || {
        log_error "could not work out which kernel source matches ${PLAT_KERNEL}"
        log_hint "Check the tags at ${KSRC_REPO}/tags and pin one:" \
                 "  WIFIMON_KERNEL_REF=tag:linux-msft-wsl-6.6.87.2 wifimon setup" \
                 "or point at a source tree you already have:" \
                 "  WIFIMON_KSRC=/usr/src/linux wifimon setup"
        return 1
    }
    ksrc_fetch || return 1
    ksrc_prepare || return 1
    return 0
}
