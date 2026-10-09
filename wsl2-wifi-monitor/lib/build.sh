# shellcheck shell=bash
# shellcheck disable=SC2034

[[ -n ${_WIFIMON_BUILD_SH:-} ]] && return 0
_WIFIMON_BUILD_SH=1

BUILD_EXTRA_SYMBOLS=""
BUILD_INSTALLED_MODULES=""
BUILD_FIRMWARE_BASE="${BUILD_FIRMWARE_BASE:-https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain}"

build_modules_target_dir() { printf '%s/updates/wifimon' "$PLAT_MODULES_DIR"; }
build_src_dir() { printf '%s/drivers/%s' "$WIFIMON_CACHE" "$1"; }

build_make() {
    local dir="$1"; shift
    local -a args=(make -C "$dir" ARCH=x86_64 CONFIG_SHELL=/bin/bash SHELL=/bin/bash)
    [[ -n $BUILD_EXTRA_SYMBOLS ]] && args+=("KBUILD_EXTRA_SYMBOLS=${BUILD_EXTRA_SYMBOLS}")
    (( KSRC_SYMVERS_SYMBOLS == 0 )) && args+=("KBUILD_MODPOST_WARN=1")
    args+=("$@")
    run_quiet "make $*" "${args[@]}"
}

build_dep_kconfig() {
    case "$1" in
        cfg80211) echo "CONFIG_WIRELESS=y CONFIG_CFG80211=m CONFIG_CFG80211_WEXT=y CONFIG_WEXT_CORE=y CONFIG_WEXT_PRIV=y CONFIG_WEXT_SPY=y CONFIG_LIB80211=m CONFIG_RFKILL=m" ;;
        mac80211) echo "CONFIG_MAC80211=m CONFIG_MAC80211_HAS_RC=y CONFIG_MAC80211_RC_MINSTREL=y CONFIG_MAC80211_RC_DEFAULT_MINSTREL=y" ;;
        *) echo "" ;;
    esac
}

build_dep_paths() {
    case "$1" in
        cfg80211) echo "net/rfkill net/wireless" ;;
        mac80211) echo "net/mac80211" ;;
        *) echo "" ;;
    esac
}

build_dep_modules() {
    case "$1" in
        cfg80211) echo "rfkill cfg80211" ;;
        mac80211) echo "mac80211" ;;
        *) echo "$1" ;;
    esac
}

build_dep_present() {
    local dep="$1" m
    for m in $(build_dep_modules "$dep"); do
        if module_builtin "$m"; then
            log_debug "${m} is built into the kernel"
            continue
        fi
        if module_available "$m"; then
            log_debug "${m} is available as a module"
            continue
        fi
        return 1
    done
    return 0
}

build_satisfy_deps() {
    local dep
    for dep in $RECIPE_DEPS; do
        if build_dep_present "$dep"; then
            log_ok "${dep} already provided by this kernel"
            build_collect_symbols_for "$dep"
            continue
        fi
        log_warn "${dep} is missing from this kernel; building it from the kernel source"
        local kconf paths
        kconf="$(build_dep_kconfig "$dep")"
        paths="$(build_dep_paths "$dep")"
        if [[ -z $paths ]]; then
            log_error "no build recipe for kernel dependency '${dep}'"
            return 1
        fi
        build_intree "$kconf" "$paths" || return 1
    done
    return 0
}

build_collect_symbols_for() {
    local dep="$1" p
    for p in $(build_dep_paths "$dep"); do
        [[ -s "${KSRC_DIR}/${p}/Module.symvers" ]] && build_add_symbols "${KSRC_DIR}/${p}/Module.symvers"
    done
    return 0
}

build_add_symbols() {
    local f="$1"
    [[ -s $f ]] || return 0
    case " ${BUILD_EXTRA_SYMBOLS} " in
        *" ${f} "*) return 0 ;;
    esac
    BUILD_EXTRA_SYMBOLS="${BUILD_EXTRA_SYMBOLS:+${BUILD_EXTRA_SYMBOLS} }${f}"
    log_debug "extra symbols: ${f}"
    return 0
}

build_apply_kconfig() {
    local kconf="$1" entry sym val changed=0
    for entry in $kconf; do
        sym="${entry%%=*}"; val="${entry#*=}"
        local cur
        cur="$(sed -n "s/^${sym}=\\(.*\\)$/\\1/p" "${KSRC_DIR}/.config" | head -1)"
        [[ $cur == "$val" ]] && continue
        [[ $cur == y && $val == m ]] && { log_debug "${sym} is already built in"; continue; }
        case "$val" in
            y) ksrc_config_set enable "$sym" ;;
            m) ksrc_config_set module "$sym" ;;
            n) ksrc_config_set disable "$sym" ;;
        esac
        changed=1
    done
    (( changed )) || return 0

    log_info "regenerating module headers for the new config"
    build_make "$KSRC_DIR" olddefconfig || return 1
    build_make "$KSRC_DIR" -j"$(nproc_safe)" modules_prepare || return 1
    ksrc_pin_utsrelease

    local missing=""
    for entry in $kconf; do
        sym="${entry%%=*}"; val="${entry#*=}"
        [[ $val == n ]] && continue
        local cur
        cur="$(sed -n "s/^${sym}=\\(.*\\)$/\\1/p" "${KSRC_DIR}/.config" | head -1)"
        [[ -z $cur ]] && missing="${missing} ${sym}"
    done
    if [[ -n $missing ]]; then
        log_error "the kernel config refused these options:${missing}"
        log_hint "Their Kconfig dependencies are unmet in this kernel. Add the missing" \
                 "parent symbols to RECIPE_KCONFIG, or pick a different driver."
        return 1
    fi
    return 0
}

build_intree() {
    local kconf="$1" paths="$2" p
    build_apply_kconfig "$kconf" || return 1
    local jobs
    jobs="$(nproc_safe)"
    for p in $paths; do
        if [[ ! -d "${KSRC_DIR}/${p}" ]]; then
            log_error "kernel source has no directory '${p}' (wrong kernel version for this recipe?)"
            return 1
        fi
        log_info "building ${p}"
        (( ${WIFIMON_FORCE:-0} )) && find "${KSRC_DIR}/${p}" -name '*.ko' -delete 2>/dev/null
        build_make "$KSRC_DIR" -j"$jobs" M="$p" modules || {
            log_error "build failed for ${p}"
            return 1
        }
        build_add_symbols "${KSRC_DIR}/${p}/Module.symvers"
        local -a kos=()
        mapfile -t kos < <(find "${KSRC_DIR}/${p}" -name '*.ko' -newer "${KSRC_DIR}/.config" 2>/dev/null)
        (( ${#kos[@]} == 0 )) && mapfile -t kos < <(find "${KSRC_DIR}/${p}" -name '*.ko' 2>/dev/null)
        if (( ${#kos[@]} == 0 )); then
            log_error "no modules were produced in ${p}"
            return 1
        fi
        build_install "${kos[@]}" || return 1
    done
    return 0
}

build_fetch_oot() {
    local dir
    dir="$(build_src_dir "$RECIPE_NAME")"
    if [[ -d "${dir}/.git" ]]; then
        log_info "updating ${RECIPE_NAME} source"
        if ! retry 3 3 -- run_quiet "git fetch" git -C "$dir" fetch --depth=1 origin "${RECIPE_REF:-HEAD}"; then
            log_warn "could not refresh the source; building the cached copy"
            printf '%s' "$dir"
            return 0
        fi
        run_quiet "git reset" git -C "$dir" reset --hard FETCH_HEAD || true
        printf '%s' "$dir"
        return 0
    fi

    need_cmd git
    log_info "cloning ${RECIPE_REPO} (${RECIPE_REF:-default branch})"
    rm -rf "$dir"
    mkdir -p "$(dirname "$dir")"
    if [[ -n ${RECIPE_REF:-} ]] && retry 3 3 -- run_quiet "git clone" git clone --depth=1 --branch "$RECIPE_REF" "$RECIPE_REPO" "$dir"; then
        printf '%s' "$dir"
        return 0
    fi
    log_warn "could not clone ref '${RECIPE_REF}'; trying the default branch"
    rm -rf "$dir"
    if retry 3 3 -- run_quiet "git clone" git clone --depth=1 "$RECIPE_REPO" "$dir"; then
        printf '%s' "$dir"
        return 0
    fi
    log_error "could not fetch ${RECIPE_REPO}"
    log_hint "Check network access, or override the URL in ${WIFIMON_ETC}/drivers/${RECIPE_NAME}.recipe"
    return 1
}

build_oot() {
    local dir
    dir="$(build_fetch_oot)" || return 1
    [[ -f "${dir}/Makefile" ]] || { log_error "${dir} has no Makefile"; return 1; }

    if declare -F recipe_pre_build >/dev/null; then
        log_debug "running recipe_pre_build hook"
        ( cd "$dir" && recipe_pre_build "$dir" ) || { log_error "recipe_pre_build failed"; return 1; }
    fi

    if (( ${WIFIMON_FORCE:-0} )); then
        log_info "forcing a clean rebuild"
        run_quiet "make clean" make -C "$dir" clean || true
    fi

    local jobs
    jobs="$(nproc_safe)"
    log_info "compiling ${RECIPE_NAME} (-j${jobs})"
    local -a mk=(make -C "$dir" -j"$jobs" ARCH=x86_64 CONFIG_SHELL=/bin/bash SHELL=/bin/bash
                 "KSRC=${KSRC_DIR}" "KVER=${PLAT_KERNEL}" "KERNELDIR=${KSRC_DIR}")
    [[ -n $BUILD_EXTRA_SYMBOLS ]] && mk+=("KBUILD_EXTRA_SYMBOLS=${BUILD_EXTRA_SYMBOLS}")
    (( KSRC_SYMVERS_SYMBOLS == 0 )) && mk+=("KBUILD_MODPOST_WARN=1")
    [[ -n ${RECIPE_MAKE_ARGS:-} ]] && read -r -a _extra <<<"$RECIPE_MAKE_ARGS" && mk+=("${_extra[@]}")

    if ! run_quiet "make ${RECIPE_NAME}" "${mk[@]}"; then
        log_error "driver build failed"
        log_hint "Full log: ${WIFIMON_LOG_FILE}" \
                 "Common causes: a driver that predates this kernel, or a kernel tree that" \
                 "does not match the running kernel. Try: wifimon doctor"
        return 1
    fi

    local -a kos=()
    mapfile -t kos < <(find "$dir" -maxdepth 2 -name '*.ko' 2>/dev/null)
    if (( ${#kos[@]} == 0 )); then
        log_error "the build produced no .ko file in ${dir}"
        return 1
    fi
    build_install "${kos[@]}"
}

build_install() {
    local dest
    dest="$(build_modules_target_dir)"
    mkdir -p "$dest"
    local ko base
    for ko in "$@"; do
        base="$(basename "$ko")"
        install -m 0644 "$ko" "${dest}/${base}" || { log_error "could not install ${base}"; return 1; }
        have_cmd strip && strip --strip-debug "${dest}/${base}" 2>/dev/null || true
        BUILD_INSTALLED_MODULES="${BUILD_INSTALLED_MODULES:+${BUILD_INSTALLED_MODULES} }${base%.ko}"
        log_debug "installed ${base} -> ${dest}"
    done
    log_ok "installed $# module(s) into ${dest}"
    build_depmod
}

build_depmod() {
    have_cmd depmod || { log_warn "depmod not found; modules will need a manual insmod"; return 0; }
    if run_quiet "depmod" depmod -a "$PLAT_KERNEL"; then
        log_debug "module dependencies refreshed"
    else
        log_warn "depmod reported problems; modprobe may not resolve dependencies"
    fi
    return 0
}

build_firmware() {
    [[ -n ${RECIPE_FIRMWARE:-} ]] || return 0
    local f missing=() present=0
    for f in $RECIPE_FIRMWARE; do
        if [[ -e "/lib/firmware/${f}" ]] || compgen -G "/lib/firmware/${f%.bin}*" >/dev/null 2>&1; then
            present=$(( present + 1 ))
        else
            missing+=("$f")
        fi
    done
    (( ${#missing[@]} == 0 )) && { log_ok "firmware present (${present} file(s))"; return 0; }

    log_info "fetching ${#missing[@]} firmware file(s)"
    local failed=()
    for f in "${missing[@]}"; do
        local dest="/lib/firmware/${f}"
        mkdir -p "$(dirname "$dest")"
        if http_get "${BUILD_FIRMWARE_BASE}/${f}" "$dest" && [[ -s $dest ]]; then
            log_ok "firmware: ${f}"
        else
            rm -f "$dest"
            failed+=("$f")
        fi
    done
    if (( ${#failed[@]} )); then
        log_warn "could not fetch: ${failed[*]}"
        log_hint "Install your distro's linux-firmware package instead:" \
                 "  apt-get install firmware-linux-free firmware-misc-nonfree  (Debian/Kali)" \
                 "  pacman -S linux-firmware                                   (Arch)" \
                 "The driver may still work if the device has its firmware on board."
    fi
    return 0
}

build_write_conflict_blacklist() {
    [[ -n ${RECIPE_CONFLICTS:-} ]] || return 0
    local f="/etc/modprobe.d/wifimon-${RECIPE_NAME}.conf" m
    mkdir -p /etc/modprobe.d
    {
        for m in $RECIPE_CONFLICTS; do
            printf 'blacklist %s\n' "$m"
        done
    } | atomic_write "$f"
    log_debug "wrote ${f}"
    return 0
}

build_recipe() {
    local name="$1"
    registry_load "$name" || return 1
    if ! registry_recipe_supported; then
        log_error "${RECIPE_NAME} needs kernel ${RECIPE_MIN_KERNEL} or newer (running ${PLAT_KVER})"
        return 1
    fi

    log_step "Building ${RECIPE_NAME}: ${RECIPE_DESC}"
    ksrc_ensure || return 1
    build_satisfy_deps || return 1

    case "$RECIPE_TYPE" in
        intree) build_intree "$RECIPE_KCONFIG" "$RECIPE_KPATHS" || return 1 ;;
        oot)    build_oot || return 1 ;;
    esac

    build_firmware
    build_write_conflict_blacklist
    state_set driver "$RECIPE_NAME"
    log_ok "${RECIPE_NAME} built and installed"
    return 0
}
