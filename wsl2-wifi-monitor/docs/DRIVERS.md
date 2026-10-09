# Adding a driver

A driver is one file: `drivers/<name>.recipe`, a shell fragment of `RECIPE_*` assignments. Drop it in
and it appears in `wifimon list-drivers` immediately. Local recipes in `/etc/wifimon/drivers/` are read
after the shipped ones and override them by name, so you can fork a driver's source URL without
editing the repository.

## Fields

| Field | Required | Meaning |
|---|---|---|
| `RECIPE_DESC` | yes | One line shown in `list-drivers` |
| `RECIPE_TYPE` | yes | `oot` (third-party source) or `intree` (built from the kernel tree) |
| `RECIPE_CHIPSETS` | yes | Space-separated chipset names, for humans |
| `RECIPE_MODULES` | yes | Modules this recipe produces, **in load order**. The last one is the driver that binds the device |
| `RECIPE_MONITOR` | yes | `type` to switch the interface itself, `vif` to add a separate monitor interface |
| `RECIPE_REPO` | oot | Git URL |
| `RECIPE_REF` | no | Branch or tag; falls back to the default branch if the ref does not exist |
| `RECIPE_MAKE_ARGS` | no | Extra arguments passed to `make` |
| `RECIPE_KCONFIG` | intree | Config symbols to set, as `CONFIG_X=m` / `CONFIG_Y=y`, including every parent symbol |
| `RECIPE_KPATHS` | intree | Kernel source directories to build, space separated, in dependency order |
| `RECIPE_DEPS` | no | `cfg80211` and/or `mac80211`; satisfied from the kernel or built on demand |
| `RECIPE_MODPARAMS` | no | Module parameters; unsupported ones are dropped automatically after checking `modinfo -p` |
| `RECIPE_CONFLICTS` | no | Modules to blacklist and unload first (e.g. the in-tree driver for the same chip) |
| `RECIPE_FIRMWARE` | no | Paths under `/lib/firmware`, fetched from linux-firmware when missing |
| `RECIPE_MIN_KERNEL` | no | Minimum kernel version, checked before building |
| `RECIPE_NOTES` | no | Anything a user should know — injection quality, known quirks |

Two optional hook functions may be defined in a recipe:

- `recipe_pre_build <srcdir>` — runs in the source directory before `make`, for patching.
- `recipe_post_fetch <srcdir>` — reserved for post-checkout fixups.

## Out-of-tree example

```sh
RECIPE_DESC="Realtek RTL8812BU / RTL8822BU (out-of-tree, morrownr)"
RECIPE_TYPE=oot
RECIPE_CHIPSETS="RTL8812BU RTL8822BU"
RECIPE_MODULES="88x2bu"
RECIPE_REPO="https://github.com/morrownr/88x2bu-20210702.git"
RECIPE_REF="main"
RECIPE_DEPS="cfg80211"
RECIPE_MODPARAMS="rtw_power_mgnt=0 rtw_enusbss=0"
RECIPE_CONFLICTS="rtw88_8822bu rtw_8822bu"
RECIPE_MONITOR="type"
RECIPE_NOTES="Mature vendor driver with frame injection."
```

## In-tree example

`RECIPE_KCONFIG` must list every symbol the driver needs, parents included — kconfig silently refuses
an option whose dependencies are unmet, and the build then fails confusingly. `wifimon` verifies each
symbol actually took and names the ones that were refused.

```sh
RECIPE_DESC="Atheros AR9271 / AR7010 (in-tree ath9k_htc)"
RECIPE_TYPE=intree
RECIPE_CHIPSETS="AR9271 AR7010"
RECIPE_MODULES="ath ath9k_hw ath9k_common ath9k_htc"
RECIPE_KCONFIG="CONFIG_WLAN=y CONFIG_WLAN_VENDOR_ATH=y CONFIG_ATH_COMMON=m CONFIG_ATH9K_HW=m CONFIG_ATH9K_COMMON=m CONFIG_ATH9K_HTC=m"
RECIPE_KPATHS="drivers/net/wireless/ath"
RECIPE_DEPS="cfg80211 mac80211"
RECIPE_FIRMWARE="ath9k_htc/htc_9271-1.4.0.fw ath9k_htc/htc_7010-1.4.0.fw"
RECIPE_MONITOR="vif"
```

Find the symbols and the path for a driver in the kernel source you already have cached:

```bash
grep -rn "RTL8188FU\|8188fu" /var/cache/wifimon/kernel/*/drivers/net/wireless/ --include=Kconfig
sed -n '1,40p' /var/cache/wifimon/kernel/*/drivers/net/wireless/realtek/rtw88/Kconfig
```

Module names come from the directory's `Makefile` (`obj-$(CONFIG_X) += name.o`), and the load order in
`RECIPE_MODULES` should follow the dependency order — `depmod` handles it at load time, but
`unload` walks the list backwards and a wrong order leaves modules behind.

## Then

```bash
bash tests/run.sh                 # validates every recipe, including the new one
sudo ./wifimon show <name>
sudo ./wifimon setup --driver <name>
```

Add the adapter's USB id to `data/adapters.tsv` so `detect` finds it — see
[ADAPTERS.md](ADAPTERS.md).

## What the test suite checks

`tests/run.sh` loads every recipe and fails if any is missing a required field, uses an invalid
`RECIPE_TYPE` or `RECIPE_MONITOR`, declares no modules, or references a driver in `adapters.tsv`
that has no recipe. It also checks the database for duplicate USB ids and malformed rows. A new
recipe that passes those checks is structurally sound; whether it drives the hardware is a separate
question that needs the hardware.
