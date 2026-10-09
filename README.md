# WiFi Monitor Mode on WSL2

**Put your USB WiFi adapter into monitor mode inside WSL2 — in two commands. No custom kernel. No DKMS.**

![Platform](https://img.shields.io/badge/platform-WSL2%20%7C%20Windows%2010%2F11-blue)
![Kernels](https://img.shields.io/badge/WSL%20kernels-5.10%20%7C%205.15%20%7C%206.6%20%7C%206.12%2B-brightgreen)
![Drivers](https://img.shields.io/badge/drivers-18-orange)
![Adapters](https://img.shields.io/badge/adapters-79-orange)
![License](https://img.shields.io/badge/license-MIT-green)

Run `airodump-ng`, `tcpdump` and Wireshark on real 802.11 frames — from Kali (or Ubuntu, Debian,
Arch, Fedora) inside Windows. No dual boot. No virtual machine. No live USB.

---

## What this is

- A tool that builds the **right WiFi driver** for the **exact WSL kernel you are running**.
- It then **loads the driver** and **turns on monitor mode** for you.
- It also handles the Windows side: passing the USB adapter into WSL.

## Why use it

- **No kernel compiling.** You don't build or replace the WSL kernel.
- **Works on new WSL versions.** It finds matching kernel source by itself, even for brand-new kernels.
- **Works with many adapters.** 18 drivers, 79 known USB adapters — Realtek, Atheros, Ralink, MediaTek.
- **Finds your adapter for you.** It reads the USB ID and picks the driver.
- **Tells you when it fails.** Every step is checked, and `wifimon doctor` prints the exact fix.
- **Fast the second time.** Everything is cached. One command per session after setup.

## When to use it

Use it if you:

- are learning WiFi security, or doing a CTF, and only have a Windows laptop
- want `airodump-ng` / Wireshark captures without rebooting into Linux
- already use Kali on WSL2 and your adapter shows "no wireless interface"

**Do not use it if:**

- You want to use your **laptop's built-in WiFi card**. That is not possible in WSL — only **USB**
  adapters can be passed in. You need a USB WiFi adapter.
- You are on **WSL1**. It has no Linux kernel. Convert first: `wsl --set-version <distro> 2`

---

## Before you start

- Windows 10 (21H2 or newer) or Windows 11
- WSL2 with an updated kernel → run `wsl --update`
- A Linux distro in WSL2 (Kali, Ubuntu, Debian, Arch, Fedora, openSUSE, Alpine)
- A **USB** WiFi adapter that supports monitor mode ([see the list](wsl2-wifi-monitor/docs/ADAPTERS.md))
- About 3.5 GB free disk space for the first build (you can free it after)

---

## Quick start

### Step 1 — Get the files

```bash
git clone https://github.com/Roshu18/wsl2-wifi-monitor-mode.git
cd wsl2-wifi-monitor-mode
```

### Step 2 — Attach the adapter (on Windows)

- Plug the USB adapter into your PC.
- Open **PowerShell as Administrator**.
- Run:

```powershell
.\wsl2-wifi-monitor\windows\wifimon.ps1 attach
```

This installs `usbipd-win` if needed, finds your adapter, and hands it to WSL.

### Step 3 — Build the driver (inside WSL, first time only)

```bash
sudo ./wsl2-wifi-monitor/wifimon setup
```

- Takes 10–20 minutes. It downloads kernel source and compiles the driver.
- You only do this **once per kernel**. After a `wsl --update`, run it again.

### Step 4 — Turn on monitor mode

```bash
sudo ./wsl2-wifi-monitor/wifimon up
```

Done. You now have a monitor-mode interface.

---

## Every day after that

Two commands — one on each side:

```powershell
.\wsl2-wifi-monitor\windows\wifimon.ps1 attach
```

```bash
sudo ./wsl2-wifi-monitor/wifimon up
```

Tip: do both at once from Windows with `.\windows\wifimon.ps1 attach -Up`.

---

## Now capture packets

```bash
airodump-ng wlan0                   # scan nearby networks
airodump-ng --band abg wlan0        # 2.4 GHz + 5 GHz
tcpdump -i wlan0 -w capture.pcap    # save to a file
```

Pick a channel:

```bash
sudo ./wifimon up --channel 6              # 2.4 GHz
sudo ./wifimon monitor --channel 36 --width 80MHz   # 5 GHz, wide
sudo ./wifimon managed                     # turn monitor mode off again
```

---

## Useful commands

| Command | What it does |
|---|---|
| `wifimon detect` | Shows your adapter and which driver it needs |
| `wifimon up` | Loads the driver and enables monitor mode |
| `wifimon status` | Shows what is loaded and active right now |
| `wifimon doctor` | Checks everything and tells you how to fix it |
| `wifimon list-drivers` | All 18 supported drivers |
| `wifimon list-adapters` | All 79 known USB adapters |
| `wifimon install-hooks` | Auto-enable monitor mode when you plug the adapter in |
| `wifimon clean --kernel` | Free the disk space used by kernel source |

Add `--help` to any command.

---

## Supported adapters

**Best for monitor mode and injection:**

- **Atheros AR9271** — Alfa AWUS036NHA, TP-Link TL-WN722N v1
- **Ralink RT3070 / RT5372** — Alfa AWUS036NEH and most cheap dongles
- **MediaTek MT7612U** — Alfa AWUS036ACM, Netgear A6210
- **Realtek RTL8812AU** — Alfa AWUS036ACH
- **Realtek RTL8822BU** — TP-Link Archer T3U / T3U Plus / T4U v3

**Also supported:** RTL8814AU, RTL8811AU, RTL8821CU, RTL8188EUS, RTL8852AU/BU (WiFi 6),
RTL8188CU, RTL8192CU, RTL8192EU, RTL8187, AR7010, AR9170, MT7601U, MT7610U, MT7921AU (WiFi 6).

👉 **[Full list with USB IDs](wsl2-wifi-monitor/docs/ADAPTERS.md)** — your adapter not there?
`wifimon detect` can still find it, and [adding one](wsl2-wifi-monitor/docs/ADAPTERS.md#adding-an-adapter)
takes one line.

---

## If something breaks

Run this first — it checks everything and prints the fix:

```bash
sudo ./wifimon doctor
```

Common problems:

| Problem | Fix |
|---|---|
| No wireless interface | Adapter not attached. Run the Windows `attach` command again |
| `usbipd` not found | `.\windows\wifimon.ps1 install` |
| Nothing appears in WSL after attach | `wsl --update` then `wsl --shutdown` |
| Monitor mode on, but no packets | Try `--channel 6`, or `iw reg set US` |
| Worked yesterday, not today | WSL updated the kernel. Run `wifimon setup` again |

More detail: **[Troubleshooting guide](wsl2-wifi-monitor/docs/TROUBLESHOOTING.md)**

---

## FAQ

**Do I need to compile a kernel?**
No. The tool compiles only the driver, against your running kernel.

**Will this break my WSL or Windows WiFi?**
No. Your Windows WiFi keeps working. Only the USB adapter is passed to Linux, and
`wifimon.ps1 detach` gives it back.

**Does packet injection work?**
Yes, on chipsets that support it — AR9271, RT2800, MT7612U and the Realtek AU drivers are best.

**Can I use the WiFi card already inside my laptop?**
No. WSL can only receive USB devices. You need a USB adapter.

**Is Wireshark supported?**
Yes. Capture with `tcpdump` and open the file, or run Wireshark in WSL with WSLg.

---

## How it works (short version)

1. Detects your WSL version, kernel and distro.
2. Finds kernel source that matches your exact kernel, falling back through tags, branches and
   kernel.org.
3. Prepares it with normal kernel tooling, and pins the version magic so modules load **without**
   `insmod --force`.
4. Builds your driver — third-party vendor drivers, or in-tree drivers straight from kernel source.
5. Loads it with `modprobe`, enables monitor mode, and confirms real frames arrive.

Deep detail: **[INTERNALS.md](wsl2-wifi-monitor/docs/INTERNALS.md)** ·
Adding a driver: **[DRIVERS.md](wsl2-wifi-monitor/docs/DRIVERS.md)**

---

## Tested on

Confirmed working end to end on **TP-Link Archer T3U (`2357:0138`), Kali Linux WSL2, Windows 11**.

The other drivers and adapters come from each driver's own USB ID table and the kernel's own build
config, and are covered by a **146-case test suite** (`bash wsl2-wifi-monitor/tests/run.sh`).
They are not each hardware-tested. If one misbehaves, open an issue with your `wifimon doctor`
output and it can be fixed quickly.

---

## Contributing

Pull requests welcome, especially:

- new adapter USB IDs (one line in `data/adapters.tsv`)
- new driver recipes (one small file — see [DRIVERS.md](wsl2-wifi-monitor/docs/DRIVERS.md))
- "works for me" reports for adapters already listed

⭐ **If this saved you from dual booting, a star helps other people find it.**

---

## Credits

- Vendor drivers: [morrownr](https://github.com/morrownr), [aircrack-ng](https://github.com/aircrack-ng)
- USB passthrough: [dorssel/usbipd-win](https://github.com/dorssel/usbipd-win)
- Kernel source: [microsoft/WSL2-Linux-Kernel](https://github.com/microsoft/WSL2-Linux-Kernel)

## License

MIT — see [LICENSE](LICENSE). Driver and firmware sources keep their own licenses.

**Use this only on networks you own or have written permission to test.**
