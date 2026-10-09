# shellcheck shell=bash
# shellcheck disable=SC2034  # variables here are consumed by other lib files

[[ -n ${_WIFIMON_PLATFORM_SH:-} ]] && return 0
_WIFIMON_PLATFORM_SH=1

PLAT_WSL=""
PLAT_KERNEL=""
PLAT_KVER=""
PLAT_KSERIES=""
PLAT_KSUFFIX=""
PLAT_MSFT_KERNEL=0
PLAT_DISTRO=""
PLAT_DISTRO_LIKE=""
PLAT_PKGMGR=""
PLAT_WSL_APP_VERSION=""
PLAT_WSL_KERNEL_REPORTED=""
PLAT_CONFIG_SRC=""
PLAT_MODULES_DIR=""

platform_detect() {
    PLAT_KERNEL="$(uname -r)"
    PLAT_KVER="${PLAT_KERNEL%%-*}"
    PLAT_KSUFFIX="${PLAT_KERNEL#"${PLAT_KVER}"}"
    PLAT_KSERIES="$(ver_series "$PLAT_KVER")"
    PLAT_MODULES_DIR="/lib/modules/${PLAT_KERNEL}"

    local osrelease="" procversion=""
    [[ -r /proc/sys/kernel/osrelease ]] && osrelease="$(</proc/sys/kernel/osrelease)"
    [[ -r /proc/version ]] && procversion="$(</proc/version)"

    case "${osrelease}" in
        *microsoft*|*Microsoft*|*WSL2*) PLAT_MSFT_KERNEL=1 ;;
    esac
    [[ $procversion == *[mM]icrosoft* ]] && PLAT_MSFT_KERNEL=1

    if [[ $osrelease == *-Microsoft ]] && [[ $osrelease != *WSL2* ]]; then
        PLAT_WSL="wsl1"
    elif platform_is_wsl_container; then
        PLAT_WSL="wsl2"
    else
        PLAT_WSL="native"
    fi

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        PLAT_DISTRO="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")"
        PLAT_DISTRO_LIKE="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID_LIKE:-}")"
    fi

    for mgr in apt-get dnf pacman zypper apk; do
        if have_cmd "$mgr"; then
            case "$mgr" in
                apt-get) PLAT_PKGMGR=apt ;;
                *)       PLAT_PKGMGR="$mgr" ;;
            esac
            break
        fi
    done

    PLAT_CONFIG_SRC="$(platform_find_kconfig || true)"
    platform_probe_wsl_app_version
    log_debug "platform: wsl=${PLAT_WSL} kernel=${PLAT_KERNEL} series=${PLAT_KSERIES} msft=${PLAT_MSFT_KERNEL} distro=${PLAT_DISTRO:-?} pkg=${PLAT_PKGMGR:-none}"
}

platform_is_wsl_container() {
    [[ -n ${WSL_DISTRO_NAME:-} ]] && return 0
    [[ -n ${WSL_INTEROP:-} ]] && return 0
    [[ -e /run/WSL ]] && return 0
    [[ -d /mnt/wsl ]] && return 0
    [[ -e /proc/sys/fs/binfmt_misc/WSLInterop ]] && return 0
    [[ -e /proc/sys/fs/binfmt_misc/WSLInterop-late ]] && return 0
    (( PLAT_MSFT_KERNEL )) && return 0
    return 1
}

platform_probe_wsl_app_version() {
    [[ $PLAT_WSL == wsl2 ]] || return 0
    have_cmd wsl.exe || return 0
    local out
    out="$(timeout 10 wsl.exe --version 2>/dev/null | tr -d '\000\r' || true)"
    [[ -z $out ]] && return 0
    PLAT_WSL_APP_VERSION="$(sed -n 's/^WSL version:[[:space:]]*\([0-9.]*\).*/\1/p' <<<"$out" | head -1)"
    PLAT_WSL_KERNEL_REPORTED="$(sed -n 's/^Kernel version:[[:space:]]*\([0-9._-]*\).*/\1/p' <<<"$out" | head -1)"
    log_debug "wsl.exe reports app=${PLAT_WSL_APP_VERSION:-?} kernel=${PLAT_WSL_KERNEL_REPORTED:-?}"
    return 0
}

platform_require_wsl2() {
    case "$PLAT_WSL" in
        wsl2) return 0 ;;
        wsl1)
            log_error "this is WSL1, which has no Linux kernel and cannot load kernel modules"
            log_hint "Convert the distro to WSL2 from Windows PowerShell:" \
                     "  wsl --set-version ${WSL_DISTRO_NAME:-<distro>} 2" \
                     "  wsl --set-default-version 2"
            exit 2
            ;;
        *)
            log_warn "not running under WSL - continuing anyway (driver builds work on native Linux too)"
            return 0
            ;;
    esac
}

platform_find_kconfig() {
    local c
    for c in "/proc/config.gz" "/boot/config-${PLAT_KERNEL}" \
             "${PLAT_MODULES_DIR}/config" "/lib/modules/${PLAT_KERNEL}/build/.config"; do
        [[ -r $c ]] && { printf '%s' "$c"; return 0; }
    done
    if [[ -r /proc/config ]]; then printf '%s' /proc/config; return 0; fi
    return 1
}

platform_kconfig_cat() {
    local src="${PLAT_CONFIG_SRC:-}"
    [[ -z $src ]] && return 1
    if [[ $src == *.gz ]]; then
        if have_cmd zcat; then zcat "$src"; else gunzip -c "$src"; fi
    else
        cat "$src"
    fi
}

kconfig_get() {
    local sym="$1"
    platform_kconfig_cat 2>/dev/null | sed -n "s/^${sym}=\\(.*\\)$/\\1/p" | head -1
}

kconfig_is() {
    local sym="$1" want="$2"
    [[ "$(kconfig_get "$sym")" == "$want" ]]
}

module_loaded() {
    local m="${1//-/_}"
    if [[ -r /sys/module/${m}/initstate ]]; then
        [[ "$(</sys/module/${m}/initstate)" == live ]] && return 0
    fi
    awk -v m="$m" '{gsub(/-/,"_",$1); if ($1 == m) found=1} END{exit !found}' /proc/modules 2>/dev/null
}

module_available() {
    local m="$1"
    modinfo "$m" >/dev/null 2>&1
}

module_builtin() {
    local m="${1//-/_}"
    local f="${PLAT_MODULES_DIR}/modules.builtin"
    if [[ -r $f ]] && \
       awk -v m="$m" -F/ '{n=$NF; sub(/\.ko$/,"",n); gsub(/-/,"_",n); if (n == m) found=1} END{exit !found}' "$f"; then
        return 0
    fi
    [[ -d /sys/module/${m} && ! -e /sys/module/${m}/initstate ]] && return 0
    return 1
}

module_present() {
    module_loaded "$1" || module_builtin "$1"
}

platform_usbip_ready() {
    [[ -d /sys/devices/platform/vhci_hcd.0 ]] && return 0
    compgen -G "/sys/devices/platform/vhci_hcd*" >/dev/null 2>&1 && return 0
    module_loaded vhci_hcd && return 0
    module_builtin vhci_hcd && return 0
    module_available vhci-hcd && return 0
    return 1
}

platform_pkg_names() {
    local generic="$1"
    case "${PLAT_PKGMGR}:${generic}" in
        apt:toolchain)   echo "build-essential" ;;
        apt:ssl)         echo "libssl-dev" ;;
        apt:elf)         echo "libelf-dev" ;;
        apt:pahole)      echo "dwarves" ;;
        apt:python)      echo "python3" ;;
        apt:xz)          echo "xz-utils" ;;
        apt:usbutils)    echo "usbutils" ;;
        apt:ncurses)     echo "libncurses-dev" ;;

        dnf:toolchain)   echo "gcc gcc-c++ make" ;;
        dnf:ssl)         echo "openssl-devel" ;;
        dnf:elf)         echo "elfutils-libelf-devel" ;;
        dnf:pahole)      echo "dwarves" ;;
        dnf:python)      echo "python3" ;;
        dnf:xz)          echo "xz" ;;
        dnf:usbutils)    echo "usbutils" ;;
        dnf:ncurses)     echo "ncurses-devel" ;;

        pacman:toolchain) echo "base-devel" ;;
        pacman:ssl)       echo "openssl" ;;
        pacman:elf)       echo "libelf" ;;
        pacman:pahole)    echo "pahole" ;;
        pacman:python)    echo "python" ;;
        pacman:xz)        echo "xz" ;;
        pacman:usbutils)  echo "usbutils" ;;
        pacman:ncurses)   echo "ncurses" ;;

        zypper:toolchain) echo "gcc gcc-c++ make" ;;
        zypper:ssl)       echo "libopenssl-devel" ;;
        zypper:elf)       echo "libelf-devel" ;;
        zypper:pahole)    echo "pahole" ;;
        zypper:python)    echo "python3" ;;
        zypper:xz)        echo "xz" ;;
        zypper:usbutils)  echo "usbutils" ;;
        zypper:ncurses)   echo "ncurses-devel" ;;

        apk:toolchain)    echo "build-base" ;;
        apk:ssl)          echo "openssl-dev" ;;
        apk:elf)          echo "elfutils-dev" ;;
        apk:pahole)       echo "" ;;
        apk:python)       echo "python3" ;;
        apk:xz)           echo "xz" ;;
        apk:usbutils)     echo "usbutils" ;;
        apk:ncurses)      echo "ncurses-dev" ;;

        *) echo "$generic" ;;
    esac
}

platform_missing_tools() {
    local -a missing=()
    local pair cmd dep
    for pair in "gcc:toolchain" "make:toolchain" "flex:flex" "bison:bison" \
                "bc:bc" "git:git" "iw:iw" "python3:python" "tar:tar" \
                "xz:xz" "modinfo:kmod" "lsusb:usbutils" "rfkill:rfkill" \
                "pahole:pahole" "cpio:cpio" "perl:perl" "openssl:openssl"; do
        cmd="${pair%%:*}"; dep="${pair##*:}"
        have_cmd "$cmd" || missing+=("$dep")
    done
    [[ -e /usr/include/openssl/ssl.h ]] || missing+=("ssl")
    { [[ -e /usr/include/libelf.h ]] || [[ -e /usr/include/elfutils/libelf.h ]]; } || missing+=("elf")
    printf '%s\n' "${missing[@]}" | awk 'NF' | sort -u
}

platform_install_deps() {
    local -a generic
    mapfile -t generic < <(platform_missing_tools)
    if (( ${#generic[@]} == 0 )); then
        log_info "build dependencies already satisfied"
        return 0
    fi
    log_info "missing build dependencies: ${generic[*]}"

    if [[ -z ${PLAT_PKGMGR} ]]; then
        log_warn "no supported package manager found; install these manually: ${generic[*]}"
        return 0
    fi

    local -a pkgs=() _tmp=()
    local g n
    for g in "${generic[@]}"; do
        n="$(platform_pkg_names "$g")"
        [[ -n $n ]] && read -r -a _tmp <<<"$n" && pkgs+=("${_tmp[@]}")
    done
    (( ${#pkgs[@]} == 0 )) && return 0

    log_info "installing: ${pkgs[*]}"
    case "$PLAT_PKGMGR" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            retry 3 3 -- run_quiet "apt-get update" apt-get update -qq || \
                log_warn "apt-get update failed; trying to install with the current index"
            run_quiet "apt-get install" apt-get install -y --no-install-recommends "${pkgs[@]}" \
                || die "dependency installation failed"
            ;;
        dnf)    run_quiet "dnf install" dnf install -y "${pkgs[@]}" || die "dependency installation failed" ;;
        pacman) run_quiet "pacman -S" pacman -Sy --noconfirm --needed "${pkgs[@]}" || die "dependency installation failed" ;;
        zypper) run_quiet "zypper install" zypper --non-interactive install -y "${pkgs[@]}" || die "dependency installation failed" ;;
        apk)    run_quiet "apk add" apk add --no-cache "${pkgs[@]}" || die "dependency installation failed" ;;
    esac
    log_ok "dependencies installed"
}

platform_suggest_runtime_tools() {
    local -a want=()
    have_cmd iw        || want+=("iw")
    have_cmd airodump-ng || want+=("aircrack-ng")
    have_cmd tcpdump   || want+=("tcpdump")
    (( ${#want[@]} )) && log_hint "optional capture tools not installed: ${want[*]}"
    return 0
}
