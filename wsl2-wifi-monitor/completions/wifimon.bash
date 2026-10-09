_wifimon() {
    local cur prev cmds opts drivers
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    cmds="setup up build load unload monitor managed status detect list-drivers list-adapters show doctor install install-hooks uninstall-hooks clean version help"
    opts="--driver --iface --mon-iface --channel --width --band --reg --txpower --no-verify --force --json --yes --verbose --quiet --color --kernel-src --kernel-ref --help"

    case "$prev" in
        -d|--driver|show)
            drivers="$(wifimon list-drivers 2>/dev/null | awk 'NR>1{print $1}')"
            mapfile -t COMPREPLY < <(compgen -W "$drivers" -- "$cur")
            return 0
            ;;
        -i|--iface|-m|--mon-iface)
            mapfile -t COMPREPLY < <(compgen -W "$(ls /sys/class/net 2>/dev/null)" -- "$cur")
            return 0
            ;;
        -w|--width)
            mapfile -t COMPREPLY < <(compgen -W "HT20 HT40+ HT40- 80MHz 160MHz" -- "$cur")
            return 0
            ;;
        -b|--band)
            mapfile -t COMPREPLY < <(compgen -W "2.4 5 6" -- "$cur")
            return 0
            ;;
        --color)
            mapfile -t COMPREPLY < <(compgen -W "auto always never" -- "$cur")
            return 0
            ;;
        clean)
            mapfile -t COMPREPLY < <(compgen -W "--kernel --drivers --all" -- "$cur")
            return 0
            ;;
    esac

    if [[ $cur == -* ]]; then
        mapfile -t COMPREPLY < <(compgen -W "$opts" -- "$cur")
        return 0
    fi
    if (( COMP_CWORD == 1 )); then
        mapfile -t COMPREPLY < <(compgen -W "$cmds" -- "$cur")
        return 0
    fi
    return 0
}
complete -F _wifimon wifimon
