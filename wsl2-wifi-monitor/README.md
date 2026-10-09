# wifimon — quick reference

Full guide: [../README.md](../README.md)

## Setup once

```powershell
.\windows\wifimon.ps1 attach
```

```bash
sudo ./wifimon setup
```

## Every session

```powershell
.\windows\wifimon.ps1 attach
```

```bash
sudo ./wifimon up
```

Or do both from Windows: `.\windows\wifimon.ps1 attach -Up`

## Commands

```bash
wifimon setup            # build the driver for this kernel
wifimon up               # load driver + monitor mode + verify
wifimon monitor -c 6     # monitor mode on channel 6
wifimon managed          # back to normal mode
wifimon status           # what is loaded now
wifimon detect           # which adapter is attached, and its driver
wifimon doctor           # check everything, print fixes
wifimon list-drivers     # 18 drivers
wifimon list-adapters    # 79 adapters
wifimon install          # put wifimon on PATH + bash completion
wifimon install-hooks    # auto monitor mode on plug-in
wifimon clean --kernel   # free the kernel source cache
```

```powershell
.\windows\wifimon.ps1 attach   # bind + attach the adapter to WSL2
.\windows\wifimon.ps1 detach   # give it back to Windows
.\windows\wifimon.ps1 list     # all USB devices
.\windows\wifimon.ps1 watch    # keep attached across replug and sleep
.\windows\wifimon.ps1 status   # usbipd + WSL state
.\windows\wifimon.ps1 doctor   # check both sides
```

## Options worth knowing

| Option | Meaning |
|---|---|
| `-d, --driver NAME` | Pick the driver instead of auto-detecting |
| `-i, --iface NAME` | Pick the interface instead of the first one |
| `-c, --channel N` | Channel to use |
| `-w, --width W` | `HT20`, `HT40+`, `HT40-`, `80MHz`, `160MHz` |
| `-b, --band B` | `2.4`, `5`, `6` — needed for 6 GHz |
| `--reg CC` | Regulatory domain, e.g. `US` |
| `--no-verify` | Skip the frame check |
| `-v` / `-q` | More / less output |

## Docs

- [ADAPTERS.md](docs/ADAPTERS.md) — every supported adapter and USB ID
- [DRIVERS.md](docs/DRIVERS.md) — add a driver with one recipe file
- [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — error → fix
- [INTERNALS.md](docs/INTERNALS.md) — how it finds kernel source and makes modules load

## Config

`/etc/wifimon/config` sets defaults so you can just run `wifimon up`:

```
driver=88x2bu
channel=6
width=HT20
regdomain=US
```

## Layout

```
wifimon              CLI
lib/                 core, platform, kernel source, registry, build, load, iface, doctor
drivers/*.recipe     one file per driver
data/adapters.tsv    USB ID -> driver
windows/wifimon.ps1  Windows USB passthrough
tests/run.sh         146 checks
setup.sh monitor.sh  old names, forward to wifimon
```
