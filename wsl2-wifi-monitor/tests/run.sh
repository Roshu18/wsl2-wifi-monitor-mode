#!/usr/bin/env bash
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
WIFIMON_ROOT="$(dirname "$TESTS_DIR")"
WIFIMON_LIB="${WIFIMON_ROOT}/lib"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/wifimon-tests.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

export WIFIMON_ETC="${TMPROOT}/etc"
export WIFIMON_CACHE="${TMPROOT}/cache"
export WIFIMON_STATE="${TMPROOT}/state"
export WIFIMON_LOG_DIR="${TMPROOT}/log"
export WIFIMON_STATE_FILE="${TMPROOT}/state/state"
export WIFIMON_NO_LOGFILE=1
export WIFIMON_VERBOSITY=0
export WIFIMON_COLOR=never
mkdir -p "$WIFIMON_ETC" "$WIFIMON_CACHE" "$WIFIMON_STATE" "$WIFIMON_LOG_DIR"

# shellcheck source=/dev/null
for f in core platform ksrc registry build load iface; do
    source "${WIFIMON_LIB}/${f}.sh"
done

PASS=0
FAIL=0
FAILED_NAMES=()

ok() {
    local name="$1"
    PASS=$(( PASS + 1 ))
    printf 'ok %d - %s\n' "$(( PASS + FAIL ))" "$name"
}

nok() {
    local name="$1" detail="${2:-}"
    FAIL=$(( FAIL + 1 ))
    FAILED_NAMES+=("$name")
    printf 'not ok %d - %s\n' "$(( PASS + FAIL ))" "$name"
    [[ -n $detail ]] && printf '  # %s\n' "$detail"
}

is() {
    local name="$1" got="$2" want="$3"
    if [[ $got == "$want" ]]; then
        ok "$name"
    else
        nok "$name" "got '${got}', want '${want}'"
    fi
}

truthy() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$name"; else nok "$name" "command failed: $*"; fi
}

falsy() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then nok "$name" "command unexpectedly succeeded: $*"; else ok "$name"; fi
}

echo "# version comparison"
is "ver_cmp equal"              "$(ver_cmp 6.6.87.2 6.6.87.2)" "0"
is "ver_cmp greater"            "$(ver_cmp 6.6.87.2 6.6.87.1)" "1"
is "ver_cmp less"               "$(ver_cmp 5.15.167.4 6.6)" "-1"
is "ver_cmp short vs long"      "$(ver_cmp 6.6 6.6.0.0)" "0"
is "ver_cmp numeric not lexical" "$(ver_cmp 5.15.9 5.15.10)" "-1"
is "ver_cmp leading zeros"      "$(ver_cmp 6.06 6.6)" "0"
is "ver_series 4 parts"         "$(ver_series 6.6.87.2)" "6.6"
is "ver_series with suffix"     "$(ver_series 5.15.167.4-microsoft-standard-WSL2)" "5.15"
truthy "ver_ge equal"           ver_ge 6.6 6.6
truthy "ver_ge greater"         ver_ge 6.12 6.6
falsy  "ver_ge less"            ver_ge 5.15 6.6
truthy "ver_lt"                 ver_lt 5.15.167.4 5.15.168

echo "# kernel tag resolution"
ksrc_list_tags() { printf '%s\n' 5.15.90.1 5.15.146.1 5.15.167.4 5.15.153.1; }
PLAT_KVER=5.15.167.4 PLAT_KSERIES=5.15
is "exact tag wins"             "$(ksrc_pick_tag 5.15.167.4 5.15)" "5.15.167.4"
is "nearest lower tag"          "$(ksrc_pick_tag 5.15.160.0 5.15)" "5.15.153.1"
is "nearest higher when none below" "$(ksrc_pick_tag 5.15.1 5.15)" "5.15.90.1"
is "highest when running is newer"  "$(ksrc_pick_tag 5.15.999 5.15)" "5.15.167.4"
ksrc_list_tags() { printf '%s\n' ''; }
falsy "no tags means failure"   ksrc_pick_tag 6.12.0 6.12
unset -f ksrc_list_tags

echo "# recipe registry"
RECIPE_COUNT="$(registry_list | wc -l)"
if (( RECIPE_COUNT >= 15 )); then ok "found ${RECIPE_COUNT} recipes"; else nok "recipe count" "only ${RECIPE_COUNT}"; fi

while read -r name; do
    if registry_load "$name" >/dev/null 2>&1; then
        ok "recipe ${name} validates"
    else
        nok "recipe ${name} validates"
    fi
done < <(registry_list)

while read -r name; do
    registry_load "$name" >/dev/null 2>&1 || continue
    if [[ -n ${RECIPE_DESC:-} && -n ${RECIPE_CHIPSETS:-} && -n ${RECIPE_MONITOR:-} ]]; then
        ok "recipe ${name} is fully described"
    else
        nok "recipe ${name} is fully described" "desc/chipsets/monitor missing"
    fi
done < <(registry_list)

is "primary module is the last one" "$(registry_load ath9k_htc >/dev/null && registry_primary_module)" "ath9k_htc"
truthy "88x2bu is out-of-tree"  bash -c "source '${WIFIMON_LIB}/core.sh'; source '${WIFIMON_LIB}/registry.sh'; WIFIMON_ROOT='${WIFIMON_ROOT}'; registry_load 88x2bu >/dev/null; [[ \$RECIPE_TYPE == oot ]]"
falsy "unknown recipe fails"    registry_load definitely_not_a_driver

echo "# recipe validation rejects bad input"
mkdir -p "${WIFIMON_ETC}/drivers"
cat >"${WIFIMON_ETC}/drivers/badtype.recipe" <<'EOF'
RECIPE_TYPE=wrong
RECIPE_MODULES="x"
EOF
cat >"${WIFIMON_ETC}/drivers/badoot.recipe" <<'EOF'
RECIPE_TYPE=oot
RECIPE_MODULES="x"
EOF
cat >"${WIFIMON_ETC}/drivers/badintree.recipe" <<'EOF'
RECIPE_TYPE=intree
RECIPE_MODULES="x"
EOF
cat >"${WIFIMON_ETC}/drivers/badmonitor.recipe" <<'EOF'
RECIPE_TYPE=oot
RECIPE_MODULES="x"
RECIPE_REPO="https://example.invalid/x.git"
RECIPE_MONITOR="telepathy"
EOF
cat >"${WIFIMON_ETC}/drivers/nomodules.recipe" <<'EOF'
RECIPE_TYPE=oot
RECIPE_REPO="https://example.invalid/x.git"
EOF
falsy "rejects bad RECIPE_TYPE"      registry_load badtype
falsy "rejects oot with no repo"     registry_load badoot
falsy "rejects intree with no paths" registry_load badintree
falsy "rejects bad RECIPE_MONITOR"   registry_load badmonitor
falsy "rejects empty RECIPE_MODULES" registry_load nomodules
rm -rf "${WIFIMON_ETC}/drivers"

echo "# user recipes override shipped ones"
mkdir -p "${WIFIMON_ETC}/drivers"
cat >"${WIFIMON_ETC}/drivers/88x2bu.recipe" <<'EOF'
RECIPE_DESC="overridden"
RECIPE_TYPE=oot
RECIPE_CHIPSETS="RTL8822BU"
RECIPE_MODULES="88x2bu"
RECIPE_REPO="https://example.invalid/fork.git"
RECIPE_MONITOR="type"
EOF
registry_load 88x2bu >/dev/null 2>&1
is "override takes precedence" "$RECIPE_REPO" "https://example.invalid/fork.git"
rm -rf "${WIFIMON_ETC}/drivers"
registry_load 88x2bu >/dev/null 2>&1
is "shipped recipe restored" "$RECIPE_REPO" "https://github.com/morrownr/88x2bu-20210702.git"

echo "# adapter database"
is "lookup known adapter"   "$(adapter_lookup 2357 0138 | cut -f4)" "88x2bu"
is "lookup is case folding" "$(adapter_lookup 0CF3 9271 | cut -f4)" "ath9k_htc"
is "lookup miss is empty"   "$(adapter_lookup ffff 0000)" ""
ID_COUNT="$(registry_ids_for_recipe 88x2bu | wc -l)"
if (( ID_COUNT >= 5 )); then ok "88x2bu has ${ID_COUNT} usb ids"; else nok "88x2bu usb ids" "only ${ID_COUNT}"; fi

DUPES="$(adapters_rows | awk -F'\t' '{print tolower($1":"$2)}' | sort | uniq -d)"
is "no duplicate usb ids in the database" "$DUPES" ""

BADCOLS="$(adapters_rows | awk -F'\t' 'NF < 5 || NF > 6 {print NR": "NF" columns"}')"
is "every database row has 5 or 6 columns" "$BADCOLS" ""

ORPHANS=""
while read -r r; do
    [[ -z $r ]] && continue
    registry_path "$r" >/dev/null 2>&1 || ORPHANS="${ORPHANS} ${r}"
done < <(adapters_rows | awk -F'\t' '{print $4}' | sort -u)
is "every database driver has a recipe" "$ORPHANS" ""

ALT_ORPHANS=""
while read -r r; do
    [[ -z $r ]] && continue
    registry_path "$r" >/dev/null 2>&1 || ALT_ORPHANS="${ALT_ORPHANS} ${r}"
done < <(adapters_rows | awk -F'\t' '{print $6}' | tr ' ' '\n' | sort -u)
is "every alternative driver has a recipe" "$ALT_ORPHANS" ""

echo "# channel and frequency maths"
is "2.4 GHz channel 1"   "$(iface_chan_to_freq 1)" "2412"
is "2.4 GHz channel 6"   "$(iface_chan_to_freq 6)" "2437"
is "2.4 GHz channel 13"  "$(iface_chan_to_freq 13)" "2472"
is "2.4 GHz channel 14"  "$(iface_chan_to_freq 14)" "2484"
is "5 GHz channel 36"    "$(iface_chan_to_freq 36)" "5180"
is "5 GHz channel 165"   "$(iface_chan_to_freq 165)" "5825"
is "6 GHz channel 37"    "$(iface_chan_to_freq 37 6)" "6135"
is "band forces 5 GHz"   "$(iface_chan_to_freq 6 5)" "5030"
falsy "rejects channel 0"      iface_chan_to_freq 0
falsy "rejects channel 20 auto" iface_chan_to_freq 20
falsy "rejects non-numeric"     iface_chan_to_freq abc
is "80MHz centre for ch 36"  "$(iface_center_freq 36 80MHz)" "5210"
is "80MHz centre for ch 149" "$(iface_center_freq 149 80MHz)" "5775"
is "160MHz centre for ch 36" "$(iface_center_freq 36 160MHz)" "5250"
falsy "no 80MHz centre for ch 1" iface_center_freq 1 80MHz

echo "# kernel config editing"
KSRC_DIR="${TMPROOT}/ksrc"
mkdir -p "$KSRC_DIR"
cat >"${KSRC_DIR}/.config" <<'EOF'
CONFIG_MODULES=y
CONFIG_DEBUG_INFO_BTF=y
CONFIG_LOCALVERSION=""
# CONFIG_CFG80211 is not set
CONFIG_MODVERSIONS=y
EOF
ksrc_config_set disable CONFIG_DEBUG_INFO_BTF
is "disable rewrites an enabled symbol" "$(grep -c '^# CONFIG_DEBUG_INFO_BTF is not set' "${KSRC_DIR}/.config")" "1"
is "disable removes the old line"       "$(grep -c '^CONFIG_DEBUG_INFO_BTF=' "${KSRC_DIR}/.config")" "0"
ksrc_config_set module CONFIG_CFG80211
is "module sets =m"                     "$(sed -n 's/^CONFIG_CFG80211=//p' "${KSRC_DIR}/.config")" "m"
is "module clears the not-set comment"  "$(grep -c '^# CONFIG_CFG80211 is not set' "${KSRC_DIR}/.config")" "0"
ksrc_config_set string CONFIG_LOCALVERSION "-microsoft-standard-WSL2"
is "string set"                         "$(sed -n 's/^CONFIG_LOCALVERSION=//p' "${KSRC_DIR}/.config")" '"-microsoft-standard-WSL2"'
ksrc_config_set enable CONFIG_BRAND_NEW
is "enable appends a missing symbol"    "$(sed -n 's/^CONFIG_BRAND_NEW=//p' "${KSRC_DIR}/.config")" "y"
is "no duplicate keys after edits"      "$(grep -oE '^CONFIG_[A-Z0-9_]+=' "${KSRC_DIR}/.config" | sort | uniq -d)" ""

echo "# prepared-tree detection"
falsy "empty dir is not a usable tree" ksrc_tree_is_usable "$KSRC_DIR"
mkdir -p "${KSRC_DIR}/include/generated" "${KSRC_DIR}/scripts/mod"
touch "${KSRC_DIR}/Makefile" "${KSRC_DIR}/include/generated/autoconf.h" "${KSRC_DIR}/scripts/mod/modpost"
printf '#define UTS_RELEASE "6.6.87.2-microsoft-standard-WSL2"\n' >"${KSRC_DIR}/include/generated/utsrelease.h"
truthy "complete tree is usable"       ksrc_tree_is_usable "$KSRC_DIR"
is "reads UTS_RELEASE"                 "$(ksrc_tree_utsrelease "$KSRC_DIR")" "6.6.87.2-microsoft-standard-WSL2"
rm -f "${KSRC_DIR}/scripts/mod/modpost"
falsy "tree without modpost is unusable" ksrc_tree_is_usable "$KSRC_DIR"

echo "# module parameter filtering"
STUBBIN="${TMPROOT}/bin"
mkdir -p "$STUBBIN"
cat >"${STUBBIN}/modinfo" <<'EOF'
#!/bin/bash
if [[ ${1:-} == -p ]]; then
    printf 'rtw_power_mgnt:int\n'
    printf 'rtw_vht_enable:int\n'
    exit 0
fi
exit 0
EOF
chmod +x "${STUBBIN}/modinfo"
PATH="${STUBBIN}:${PATH}"
is "keeps supported parameters"    "$(load_filter_params fake.ko 'rtw_power_mgnt=0 rtw_vht_enable=1')" "rtw_power_mgnt=0 rtw_vht_enable=1"
is "drops unsupported parameters"  "$(load_filter_params fake.ko 'rtw_power_mgnt=0 nonsense=7')" "rtw_power_mgnt=0"
is "empty parameters stay empty"   "$(load_filter_params fake.ko '')" ""
cat >"${STUBBIN}/modinfo" <<'EOF'
#!/bin/bash
exit 1
EOF
is "keeps parameters when modinfo fails" "$(load_filter_params fake.ko 'a=1 b=2')" "a=1 b=2"
rm -f "${STUBBIN}/modinfo"

echo "# symbol CRC reconstruction"
cat >"${TMPROOT}/kallsyms" <<'EOF'
ffffffff81000000 T _stext
00000000a1b2c3d4 A __crc_module_put
00000000deadbeef A __crc_cfg80211_register
ffffffffc0001234 t some_local_symbol
0000000012345678 A __crc_ieee80211_rx	[mac80211]
0000000000000000 A __crc_zero_is_skipped
EOF
SYMOUT="${TMPROOT}/Module.symvers"
if python3 -I "${WIFIMON_LIB}/symvers.py" --kallsyms "${TMPROOT}/kallsyms" --out "$SYMOUT" >/dev/null 2>&1; then
    ok "symvers.py runs"
else
    nok "symvers.py runs"
fi
is "three usable CRCs"        "$(wc -l <"$SYMOUT")" "3"
is "zero CRC is skipped"      "$(grep -c zero_is_skipped "$SYMOUT")" "0"
is "CRC is masked to 32 bits" "$(awk -F'\t' '$2=="module_put"{print $1}' "$SYMOUT")" "0xa1b2c3d4"
is "owner is vmlinux"         "$(awk -F'\t' '$2=="module_put"{print $4}' "$SYMOUT")" "vmlinux"
is "module owner is recorded" "$(awk -F'\t' '$2=="ieee80211_rx"{print $4}' "$SYMOUT")" "mac80211"
is "five tab-separated fields" "$(awk -F'\t' 'NF!=5{c++} END{print c+0}' "$SYMOUT")" "0"
is "export type is set"       "$(awk -F'\t' '$2=="module_put"{print $5}' "$SYMOUT")" "EXPORT_SYMBOL_GPL"
is "namespace field is empty" "$(awk -F'\t' '$2=="module_put"{print "["$3"]"}' "$SYMOUT")" "[]"
printf 'ffffffff81000000 T _stext\n' >"${TMPROOT}/empty-kallsyms"
falsy "fails when there are no CRCs" python3 -I "${WIFIMON_LIB}/symvers.py" --kallsyms "${TMPROOT}/empty-kallsyms" --out "${TMPROOT}/none.symvers"

echo "# state and config files"
state_set driver 88x2bu
state_set monitor_iface wlan0mon
is "state round-trips"          "$(state_get driver)" "88x2bu"
is "state keeps other keys"     "$(state_get monitor_iface)" "wlan0mon"
state_set driver ath9k_htc
is "state overwrite wins"       "$(state_get driver)" "ath9k_htc"
is "state has no duplicate keys" "$(grep -c '^driver=' "$WIFIMON_STATE_FILE")" "1"
falsy "missing state key fails"  state_get nothing_here

cat >"${WIFIMON_ETC}/config" <<'EOF'
driver=mt76x2u
channel=36
width=80MHz
regdomain=US

bogus_key=ignored
EOF
( WIFIMON_DRIVER="" WIFIMON_CHANNEL="" WIFIMON_WIDTH="" WIFIMON_REG=""
  config_load
  [[ $WIFIMON_DRIVER == mt76x2u && $WIFIMON_CHANNEL == 36 && $WIFIMON_WIDTH == 80MHz && $WIFIMON_REG == US ]] ) \
    && ok "config file is parsed" || nok "config file is parsed"
( WIFIMON_DRIVER="override" ; config_load ; [[ $WIFIMON_DRIVER == override ]] ) \
    && ok "command line beats config file" || nok "command line beats config file"
rm -f "${WIFIMON_ETC}/config"

echo "# dependency plumbing"
is "cfg80211 builds rfkill first" "$(build_dep_paths cfg80211)" "net/rfkill net/wireless"
is "mac80211 path"                "$(build_dep_paths mac80211)" "net/mac80211"
is "cfg80211 modules"             "$(build_dep_modules cfg80211)" "rfkill cfg80211"
is "unknown dep maps to itself"   "$(build_dep_modules weird)" "weird"
BUILD_EXTRA_SYMBOLS=""
printf 'x\n' >"${TMPROOT}/sym1"
build_add_symbols "${TMPROOT}/sym1"
build_add_symbols "${TMPROOT}/sym1"
is "symbol files are not duplicated" "$BUILD_EXTRA_SYMBOLS" "${TMPROOT}/sym1"
build_add_symbols "${TMPROOT}/missing-file"
is "missing symbol files are ignored" "$BUILD_EXTRA_SYMBOLS" "${TMPROOT}/sym1"

echo "# misc helpers"
JOBS="$(nproc_safe)"
if [[ $JOBS =~ ^[0-9]+$ ]] && (( JOBS >= 1 )); then ok "nproc_safe returns ${JOBS}"; else nok "nproc_safe" "got '${JOBS}'"; fi
is "json_escape quotes"   "$(json_escape 'say "hi"')" 'say \"hi\"'
is "json_escape backslash" "$(json_escape 'a\b')" 'a\\b'
truthy "have_cmd finds bash" have_cmd bash
falsy  "have_cmd misses junk" have_cmd definitely_not_a_command_xyz

echo "# retry backoff"
ATTEMPTS=0
flaky() { ATTEMPTS=$(( ATTEMPTS + 1 )); (( ATTEMPTS >= 3 )); }
truthy "retry succeeds on the third try" retry 4 0 -- flaky
is "retry stopped at three attempts" "$ATTEMPTS" "3"
ATTEMPTS=0
always_fail() { ATTEMPTS=$(( ATTEMPTS + 1 )); return 1; }
falsy "retry gives up" retry 2 0 -- always_fail
is "retry honoured the attempt limit" "$ATTEMPTS" "2"

echo "# cli surface"
CLI="${WIFIMON_ROOT}/wifimon"
truthy "wifimon version"       "$CLI" version
truthy "wifimon help"          "$CLI" help
truthy "wifimon list-drivers"  "$CLI" list-drivers
truthy "wifimon list-adapters" "$CLI" list-adapters
truthy "wifimon show 88x2bu"   "$CLI" show 88x2bu
truthy "wifimon status"        "$CLI" status
falsy  "unknown command fails" "$CLI" not-a-command
falsy  "unknown option fails"  "$CLI" status --not-an-option
falsy  "show needs an argument" "$CLI" show
"$CLI" doctor --json >"${TMPROOT}/doctor.json" 2>/dev/null
if have_cmd jq; then
    truthy "doctor --json is valid json" jq -e . "${TMPROOT}/doctor.json"
    is "doctor json reports the kernel" "$(jq -r .kernel "${TMPROOT}/doctor.json")" "$(uname -r)"
    CHECKS="$(jq '.checks | length' "${TMPROOT}/doctor.json")"
    if (( CHECKS > 10 )); then ok "doctor ran ${CHECKS} checks"; else nok "doctor check count" "only ${CHECKS}"; fi
else
    printf '  # jq not installed, skipping json checks\n'
fi

echo
printf '1..%d\n' "$(( PASS + FAIL ))"
printf '# passed %d, failed %d\n' "$PASS" "$FAIL"
if (( FAIL )); then
    printf '# failures:\n'
    for n in "${FAILED_NAMES[@]}"; do printf '#   - %s\n' "$n"; done
    exit 1
fi
exit 0
