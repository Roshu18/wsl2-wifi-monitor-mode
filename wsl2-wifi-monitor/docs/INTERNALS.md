# How it works

Reference for the parts that are not obvious, and the reasoning behind them. Read this before
changing `lib/ksrc.sh`, `lib/build.sh` or `lib/load.sh`.

## The actual problem

Compiling a kernel module is easy. Getting it to *load* into a kernel whose build tree you do not
have is the hard part, and WSL is the awkward case: Microsoft ships a kernel binary with no matching
`linux-headers` package, no `Module.symvers`, and a version string that no upstream tag produces.

A module is accepted by the kernel only if:

1. its **version magic** matches — `UTS_RELEASE` plus SMP, preempt, module-unload and modversions flags;
2. on a `CONFIG_MODVERSIONS` kernel, every **symbol CRC** it imports matches the kernel's;
3. every symbol it imports **exists**;
4. its **struct layouts** match, which means the config it was built against must agree with the
   running kernel on everything ABI-visible.

`insmod --force` skips checks 1 and 2. That is why the naive approach appears to work and then
crashes or corrupts memory later — the checks exist to catch exactly the mismatch being ignored.
This toolkit satisfies the checks instead.

## 1. Finding kernel source for any WSL kernel

`lib/ksrc.sh`, in order:

1. **Reuse an existing prepared tree.** `WIFIMON_KSRC`, then `/lib/modules/$(uname -r)/build`, then
   `/usr/src/linux-headers-$(uname -r)`, then `/usr/src/linux`. A tree counts only if it has a
   `Makefile`, `include/generated/autoconf.h`, `include/generated/utsrelease.h`, a built
   `scripts/mod/modpost`, *and* a `UTS_RELEASE` equal to the running kernel. This is the fast path:
   Arch WSL and custom kernels with headers installed skip everything below.
2. **Exact tag** — `linux-msft-wsl-<numeric version>`, e.g. `6.6.87.2` → `linux-msft-wsl-6.6.87.2`.
3. **Nearest tag in the same series.** Tags are listed with `git ls-remote` (GitHub API as fallback)
   and compared numerically by `ver_cmp`, never lexically — `5.15.9` is older than `5.15.10`. The
   highest tag at or below the running version wins; failing that, the lowest above it.
4. **Series branch** — `linux-msft-wsl-<series>.y`, which is where a kernel newer than every tag lands.
5. **`master`** of the WSL kernel repo.
6. **Mainline from kernel.org** when the running kernel is not a Microsoft build.

Fetching prefers the GitHub tarball (one resumable HTTPS GET, no history) and falls back to a shallow
`git clone`. Trees are cached under `/var/cache/wifimon/kernel/<ref>` and a stamp file records which
`uname -r` the tree was prepared for, so a second run is nearly free and a WSL kernel update is
detected automatically.

## 2. Preparing the tree

Config comes from `/proc/config.gz`, else `/boot/config-$(uname -r)`, else
`/lib/modules/$(uname -r)/config`, else the tree's own `Microsoft/config-wsl` (which is reported as
an ABI risk, because it is a guess at what the running kernel was built with).

Only build-infrastructure options are then changed, because anything else risks the ABI:

| Turned off | Why |
|---|---|
| `DEBUG_INFO_BTF`, `DEBUG_INFO_BTF_MODULES` | needs `pahole` over a `vmlinux` we do not have |
| `MODULE_SIG_ALL`, `MODULE_SIG_FORCE` | we have no signing key, and the running kernel does not require one |
| `SYSTEM_TRUSTED_KEYS`, `SYSTEM_REVOCATION_KEYS` | point at certificates absent from the source tarball |
| `GCC_PLUGINS` | needs the plugin development headers |
| `RUST`, `LTO_CLANG*`, `WERROR`, `IKHEADERS` | unavailable or pointless for an out-of-tree build |
| `DEBUG_INFO` → `DEBUG_INFO_NONE` | cuts build time and disk use by a large factor; no ABI effect |

Deliberately **not** touched: `SMP`, `PREEMPT*`, `MODULE_UNLOAD`, `MODVERSIONS` (all vermagic
inputs), `X86_KERNEL_IBT` (disabling it would emit modules without `endbr` prologues, which faults on
an IBT kernel), and anything else that changes code generation or struct layout. `RANDSTRUCT` is
detected and reported, because its randomisation seed cannot be reproduced from a tarball.

Then plain `make olddefconfig` followed by `make modules_prepare`, with `CONFIG_SHELL=/bin/bash` so
a `/bin/sh` that is `dash` cannot break the kernel's shell scripts. No Makefile is patched and no
`autoconf.h` is hand-written; the kernel's own build system produces both.

## 3. Making version magic match

After `modules_prepare`, `include/generated/utsrelease.h` holds whatever the source tree's version
plus `CONFIG_LOCALVERSION` produced. `CONFIG_LOCALVERSION` is set from the running kernel's suffix
(`-microsoft-standard-WSL2`) and `CONFIG_LOCALVERSION_AUTO` is disabled; if the result still differs
from `uname -r`, the header is overwritten with the exact running release and read back to confirm.

Module builds (`make M=…`) do not regenerate that header, so the pin holds for every driver built
afterwards. The result is a module whose vermagic release field is correct — check 1 satisfied
without `--force`.

## 4. Recovering symbol CRCs

If the running kernel has `CONFIG_MODVERSIONS=y`, `modpost` needs the kernel's `Module.symvers` to
stamp each imported symbol with a CRC. WSL does not ship one. `lib/symvers.py` rebuilds it from two
sources on the running system:

- **`/proc/kallsyms`** — with modversions enabled, each exported symbol's CRC is present as an
  absolute symbol `__crc_<name>` whose value *is* the CRC. The trailing `[module]` annotation also
  gives the owning module, so symbols exported by modules are attributed correctly rather than all
  being claimed by `vmlinux`. Needs root, since `kptr_restrict` zeroes these values otherwise.
- **`modprobe --dump-modversions`** on the kernel's own shipped modules, which prints the CRC of every
  symbol each one imports. Used to fill gaps; disagreements with kallsyms are counted and kallsyms wins.

Output is the five-field format `modpost` expects: `crc`, symbol, namespace (empty), owner, export type.
Zero CRCs are dropped. Fewer than 500 recovered symbols is treated as failure and the file is removed,
because a half-populated `Module.symvers` is worse than none — it produces modules with CRC 0 for the
missing symbols, which the kernel then rejects one by one.

When CRCs cannot be recovered, `KBUILD_MODPOST_WARN=1` keeps the build going and the load path falls
back through `modprobe` → `insmod` → `insmod --force`, logging which one worked. `--force` always
warns that the module may be unstable.

## 5. Building the driver

**Out-of-tree** recipes are shallow-cloned and built with `KSRC`, `KVER` and `KERNELDIR` pointed at
the prepared tree.

**In-tree** recipes are built from the kernel source itself: the recipe's `RECIPE_KCONFIG` symbols are
set in `.config`, `olddefconfig` and `modules_prepare` are re-run (cheap the second time), each symbol
is verified to have actually taken — kconfig silently refuses options whose dependencies are unmet, so
this is checked rather than hoped for — and then `make M=<path> modules` builds just that directory.

`cfg80211` and `mac80211` are resolved before the driver: built into the kernel, available as a
module, or built from `net/wireless`, `net/rfkill` and `net/mac80211` on demand. Each built directory
contributes its `Module.symvers` to `KBUILD_EXTRA_SYMBOLS` for the next build, which is how
`ath9k_htc` resolves `mac80211` symbols that live in a module we built a moment earlier.

Modules are installed to `/lib/modules/$(uname -r)/updates/wifimon/`, stripped of debug sections, and
registered with `depmod` — so `modprobe` works normally and pulls dependencies in the right order.
Firmware named by a recipe is fetched from linux-firmware only when it is missing, and a failure there
is a warning, not an error, since many adapters carry firmware on board.

## 6. Monitor mode

`lib/iface.sh` clears rfkill, stops NetworkManager and `wpa_supplicant` if they are running, and then
tries, in the order the recipe prefers:

1. `iw dev <if> set type monitor` — what vendor Realtek drivers want (`RECIPE_MONITOR=type`);
2. `iw phy <phy> interface add <if>mon type monitor` — a separate monitor vif, which is what mac80211
   drivers want (`RECIPE_MONITOR=vif`) and which leaves the managed interface intact;
3. `iwconfig <if> mode monitor` — the legacy ioctl, for drivers with incomplete nl80211 support.

Whichever path is used, the result is verified by reading the interface type back and sampling
`/sys/class/net/<if>/statistics/rx_packets` over a few seconds. Zero frames is reported with the
likely causes rather than passed off as success. Channel, width (including 80/160 MHz, where the
control and centre frequencies are computed), regulatory domain and fixed transmit power are applied
after the mode switch, each degrading to a narrower setting rather than failing outright.

## Layout

```
wifimon                 CLI entry point and subcommand dispatch
lib/core.sh             logging, retry with backoff, flock, versions, state, config
lib/platform.sh         WSL1/WSL2/native detection, kernel facts, kconfig, package install
lib/ksrc.sh             source resolution, fetch, config sanitising, prepare, vermagic, symvers
lib/registry.sh         recipe loading and validation, adapter database, device detection
lib/build.sh            dependency resolution, in-tree and out-of-tree builds, install, firmware
lib/load.sh             conflict handling, parameter filtering, load with fallbacks
lib/iface.sh            monitor mode, channels, verification
lib/doctor.sh           diagnostics
lib/symvers.py          Module.symvers reconstruction
drivers/*.recipe        one file per driver
data/adapters.tsv       USB id -> chipset -> driver
windows/wifimon.ps1     usbipd-win driving, device selection, WSL distro handling
tests/run.sh            146 checks over the pure logic and the CLI surface
```

## Paths used at runtime

| Path | Contents |
|---|---|
| `/var/cache/wifimon/kernel/<ref>` | prepared kernel source trees |
| `/var/cache/wifimon/downloads` | source tarballs |
| `/var/cache/wifimon/drivers/<recipe>` | out-of-tree driver checkouts |
| `/lib/modules/<release>/updates/wifimon` | built modules |
| `/etc/wifimon/config` | defaults for driver, interface, channel, width, regdomain |
| `/etc/wifimon/drivers/*.recipe` | local recipes, override the shipped ones |
| `/etc/wifimon/adapters.tsv` | extra adapter rows |
| `/var/lib/wifimon/state` | last used driver, monitor interface and method |
| `/var/log/wifimon/wifimon.log` | full command output, including failed build logs |

Every one of these honours an environment override (`WIFIMON_CACHE`, `WIFIMON_ETC`,
`WIFIMON_STATE`, `WIFIMON_LOG_DIR`), which is also how the test suite stays out of the real system.
