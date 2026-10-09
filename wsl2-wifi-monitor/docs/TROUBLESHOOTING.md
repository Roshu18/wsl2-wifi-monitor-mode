# Troubleshooting

Start with `sudo wifimon doctor`. It checks everything below and prints the fix for whatever it finds.
The full output of every command it runs, including failed build logs, is in
`/var/log/wifimon/wifimon.log`.

## Windows side

**`usbipd: command not found`**
`.\windows\wifimon.ps1 install`. If winget is unavailable, install from
[usbipd-win releases](https://github.com/dorssel/usbipd-win/releases) and open a new terminal —
PATH changes do not reach an already-running shell.

**`no USB Wi-Fi adapter found`**
`.\windows\wifimon.ps1 list` shows every USB device usbipd can see, with known adapters named. If
yours is listed but unnamed, attach it by bus id: `.\windows\wifimon.ps1 attach -BusId 2-4`, and add
its id to `data/adapters.tsv`.

**`could not bind bus N-M`**
A Windows driver has the device. `.\windows\wifimon.ps1 attach -BusId N-M -Force` takes it away from
Windows until you detach. Binding needs Administrator; the script elevates itself unless `-NoElevate`.

**Attach succeeds but nothing appears in WSL**
The WSL kernel needs USB/IP support, which has shipped since kernel 5.10.60.1:

```powershell
wsl --update
wsl --shutdown
```

Then re-attach. `wifimon doctor` inside WSL reports whether `vhci_hcd` is present.

**The adapter drops after sleep or a replug**
`.\windows\wifimon.ps1 watch` — it uses usbipd's own `--auto-attach` on 4.x and polls on older versions.

**`'<distro>' runs on WSL1`**
`wsl --set-version <distro> 2`, and `wsl --set-default-version 2` so new distros are WSL2.

## Build failures

**`could not work out which kernel source matches <release>`**
The resolver tried the exact tag, the nearest tag in the series, the series branch and `master`.
Pin one yourself:

```bash
WIFIMON_KERNEL_REF=tag:linux-msft-wsl-6.6.87.2 sudo -E ./wifimon setup
```

Available tags: <https://github.com/microsoft/WSL2-Linux-Kernel/tags>. Or point at a tree you have:
`WIFIMON_KSRC=/usr/src/linux sudo -E ./wifimon setup`.

**`no kernel config found`**
The kernel lacks `CONFIG_IKCONFIG_PROC` and there is no `/boot/config-$(uname -r)`. Supply one:
`WIFIMON_KCONFIG=/path/to/config sudo -E ./wifimon setup`. A config that does not match the running
kernel can produce a module that loads and then misbehaves, so prefer the exact one.

**`only N MB free`**
The first run wants about 3.5 GB. Free space, grow the WSL disk
(`wsl --manage <distro> --resize 128GB` from Windows), or move the cache:
`WIFIMON_CACHE=/mnt/c/wifimon-cache sudo -E ./wifimon setup`. Afterwards `wifimon clean --kernel`
reclaims most of it — the built modules stay installed.

**`the kernel config refused these options`**
An in-tree recipe is missing a parent symbol in `RECIPE_KCONFIG`. The message names the refused
symbols; find their dependencies in the relevant `Kconfig` and add them. See [DRIVERS.md](DRIVERS.md).

**`kernel source has no directory '<path>'`**
The recipe targets a path that does not exist in this kernel version — usually a driver newer than
the kernel, or one that moved. Check `RECIPE_MIN_KERNEL` and the path in the kernel tree.

**`driver build failed`**
Read the tail that was printed, then the full log in `/var/log/wifimon/wifimon.log`. Vendor drivers
pinned to old kernels break on new ones; the usual fix is a newer upstream ref:

```bash
sudo ./wifimon setup --driver 88x2bu -v
```

or a fork, via a local recipe in `/etc/wifimon/drivers/` with a different `RECIPE_REPO`.

## Loading failures

**`disagrees about version of symbol <name>`**
Symbol CRCs do not match: the module was built against a different kernel, or CRC recovery failed.
Rebuild against the running kernel:

```bash
sudo ./wifimon clean --kernel
sudo ./wifimon setup
```

CRC recovery needs root and `CONFIG_MODVERSIONS`; `wifimon doctor` reports how many CRCs it
recovered. Fewer than 500 and it declines to use them.

**`Unknown symbol in module`**
A dependency module is missing. `wifimon doctor` shows whether `cfg80211` and `mac80211` are present;
`wifimon setup` builds them from the kernel source when they are not. If the symbol belongs to
something else entirely, name it in an issue — it probably needs adding to the dependency map in
`lib/build.sh`.

**`module loaded with --force`**
It worked, but version magic could not be made to match, so the ABI is unverified. Treat the result
as suspect: re-run `wifimon setup` after `wifimon clean --kernel`, and check `doctor` for a tree
prepared for a different kernel.

**Module loads but no interface appears**
The driver loaded without binding the device — usually the adapter is not attached, or a conflicting
driver claimed it:

```bash
lsusb                      # is the device visible here at all?
wifimon detect
dmesg | tail -30
```

`RECIPE_CONFLICTS` handles the common in-tree/out-of-tree clashes (`rtw88_8822bu` vs `88x2bu`,
`rtl8xxxu` vs `8188eu`) by blacklisting and unloading them.

## Monitor mode

**`could not put <iface> into monitor mode`**
Check what the hardware admits to supporting:

```bash
iw phy phy0 info | grep -A8 'Supported interface modes'
```

If `monitor` is absent, that driver cannot do it — pick a different recipe for the chipset
(`wifimon show <driver>` lists alternatives) or a different adapter. `ath9k_htc`, `rt2800usb` and
`mt76x2u` are the dependable ones.

**Monitor mode is on but no frames arrive**
This is what `wifimon up` reports as "no frames captured". In order of likelihood: the adapter is
parked on a quiet channel (`wifimon monitor --channel 6`), there is genuinely no traffic nearby, the
regulatory domain blocks the channel (`iw reg set US`), or USB power management is interfering
(the Realtek recipes already pass `rtw_power_mgnt=0`).

**`could not set channel N`**
The regulatory domain forbids it, or the adapter does not support that band. `iw reg set <CC>` needs
`regulatory.db` in `/lib/firmware` — package `wireless-regdb`. Check what is allowed:

```bash
iw phy phy0 channels
```

**5 GHz or 6 GHz channels are missing**
Many adapters only enable them after the regulatory domain is set. 6 GHz needs an AX adapter and
`--band 6`, since channel numbers overlap with 2.4 GHz.

**`a hardware rfkill switch is engaged`**
A physical switch on the adapter, or Windows still holding the radio. `rfkill list` shows which.

## Everything else

**It worked yesterday and now the module will not load**
WSL updated its kernel. `wifimon setup` notices and rebuilds; nothing needs cleaning first.

**`another wifimon instance holds the lock`**
A build is already running. Wait, or check for a stale process; the lock is
`/var/lib/wifimon/wifimon.lock` and it is released when the process exits.

**Reporting a problem**
Include `sudo wifimon doctor` output, the last 50 lines of `/var/log/wifimon/wifimon.log`, your
adapter's USB id and `uname -r`. That is almost always enough to tell exactly what happened.
