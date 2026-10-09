# Supported adapters

`wifimon detect` matches the USB id of an attached adapter against this database and
picks the driver for it. Anything not listed still works: pass `--driver <name>`, or let
`detect` fall back to resolving the device's modalias against the kernel's own module table.

79 USB ids across 15 drivers.

## 8188eu

Realtek RTL8188EU / RTL8188EUS (out-of-tree, aircrack-ng)  
Type: out-of-tree · monitor mode via `type`

TP-Link TL-WN722N v2/v3. Blacklist the in-tree r8188eu/rtl8xxxu to avoid a conflict.

| USB id | Chipset | Adapter | Alternative driver |
|---|---|---|---|
| `0bda:8179` | RTL8188EUS | Realtek RTL8188EUS | `rtl8xxxu` |
| `2357:010c` | RTL8188EUS | TP-Link TL-WN722N v2/v3 | `rtl8xxxu` |

## 8812au

Realtek RTL8812AU / RTL8821AU (out-of-tree, morrownr)  
Type: out-of-tree · monitor mode via `type`

Alfa AWUS036ACH and similar AC1200 adapters. Full injection support.

| USB id | Chipset | Adapter | Alternative driver |
|---|---|---|---|
| `050d:1109` | RTL8812AU | Belkin F9L1109 v2 | — |
| `0b05:17d2` | RTL8812AU | ASUS USB-AC56 | — |
| `0bda:8812` | RTL8812AU | Realtek RTL8812AU reference / Alfa AWUS036ACH | — |
| `0bda:881a` | RTL8812AU | Realtek RTL8812AU | — |
| `0bda:881b` | RTL8812AU | Realtek RTL8812AU | — |
| `0bda:881c` | RTL8812AU | Realtek RTL8812AU | — |
| `0e66:0022` | RTL8812AU | Hawking HW12ACU | — |
| `13b1:003f` | RTL8812AU | Linksys WUSB6300 | — |
| `2001:3316` | RTL8812AU | D-Link DWA-182 rev C | — |
| `2001:3318` | RTL8812AU | D-Link DWA-180 rev A1 | — |
| `20f4:805b` | RTL8812AU | TRENDnet TEW-805UB | — |
| `2357:0101` | RTL8812AU | TP-Link Archer T4U | — |
| `2357:0103` | RTL8812AU | TP-Link Archer T4UH | — |
| `2357:010d` | RTL8812AU | TP-Link Archer T4U v2 | — |
| `2357:010e` | RTL8812AU | TP-Link Archer T4UH v2 | — |
| `2357:010f` | RTL8812AU | TP-Link Archer T4U | — |
| `7392:a822` | RTL8812AU | Edimax EW-7822UAC | — |

## 8814au

Realtek RTL8814AU (out-of-tree, morrownr)  
Type: out-of-tree · monitor mode via `type`

Alfa AWUS1900 / AC1900 class adapters.

| USB id | Chipset | Adapter | Alternative driver |
|---|---|---|---|
| `0b05:1853` | RTL8814AU | ASUS USB-AC68 | — |
| `0bda:8813` | RTL8814AU | Realtek RTL8814AU / Alfa AWUS1900 | — |
| `2357:0106` | RTL8814AU | TP-Link Archer T9UH | — |

## 8821au

Realtek RTL8811AU / RTL8821AU (out-of-tree, morrownr)  
Type: out-of-tree · monitor mode via `type`

AC600 class nano adapters.

| USB id | Chipset | Adapter | Alternative driver |
|---|---|---|---|
| `0bda:0811` | RTL8811AU | Realtek RTL8811AU | — |
| `0bda:8811` | RTL8811AU | Realtek RTL8811AU | — |
| `0bda:a811` | RTL8821AU | Realtek RTL8821AU | — |

## 8821cu

Realtek RTL8811CU / RTL8821CU / RTL8731AU (out-of-tree, morrownr)  
Type: out-of-tree · monitor mode via `type`

Alfa AWUS036ACU and similar AC650 adapters.

| USB id | Chipset | Adapter | Alternative driver |
|---|---|---|---|
| `0bda:c811` | RTL8811CU | Realtek RTL8811CU | `rtw88_usb` |
| `0bda:c820` | RTL8821CU | Realtek RTL8821CU | `rtw88_usb` |
| `0bda:c821` | RTL8821CU | Realtek RTL8821CU | `rtw88_usb` |
| `0bda:c82a` | RTL8821CU | Realtek RTL8821CU | `rtw88_usb` |
| `0bda:c82b` | RTL8821CU | Realtek RTL8821CU | `rtw88_usb` |

## 88x2bu

Realtek RTL8812BU / RTL8822BU (out-of-tree, morrownr)  
Type: out-of-tree · monitor mode via `type`

Mature vendor driver with frame injection. TP-Link Archer T3U/T3U Plus/T4U v3.

| USB id | Chipset | Adapter | Alternative driver |
|---|---|---|---|
| `0846:9055` | RTL8822BU | Netgear A6150 | `rtw88_usb` |
| `0b05:184c` | RTL8822BU | ASUS USB-AC53 Nano | `rtw88_usb` |
| `0b05:1870` | RTL8822BU | ASUS USB-AC53 | `rtw88_usb` |
| `0bda:b812` | RTL8822BU | Realtek RTL8822BU | `rtw88_usb` |
| `0bda:b81a` | RTL8822BU | Realtek RTL8822BU | `rtw88_usb` |
| `2001:331e` | RTL8822BU | D-Link DWA-181 | `rtw88_usb` |
| `2357:0115` | RTL8812BU | TP-Link Archer T4U v3 | `rtw88_usb` |
| `2357:012d` | RTL8822BU | TP-Link Archer T3U | `rtw88_usb` |
| `2357:0138` | RTL8822BU | TP-Link Archer T3U | `rtw88_usb` |
| `2357:013f` | RTL8822BU | TP-Link Archer T3U Plus | `rtw88_usb` |
| `7392:c822` | RTL8822BU | Edimax EW-7822ULC | `rtw88_usb` |

## ath9k_htc

Atheros AR9271 / AR7010 (in-tree ath9k_htc)  
Type: in-tree · monitor mode via `vif`

The reference monitor-mode chipset (Alfa AWUS036NHA, TL-WN722N v1). Excellent injection.

| USB id | Chipset | Adapter | Alternative driver |
|---|---|---|---|
| `040d:3801` | AR9271 | Atheros AR9271 | — |
| `0cf3:1006` | AR9271 | Atheros AR9271 | — |
| `0cf3:7015` | AR7010 | Atheros AR7010 | — |
| `0cf3:9018` | AR7010 | Atheros AR7010 | — |
| `0cf3:9271` | AR9271 | Atheros AR9271 / Alfa AWUS036NHA / TL-WN722N v1 | — |
| `0cf3:b002` | AR9271 | Atheros AR9271 | — |

## carl9170

Atheros AR9170 (in-tree carl9170)  
Type: in-tree · monitor mode via `vif`

carl9170-1.fw is not in linux-firmware; fetch it from the carl9170 project if the download fails.

| USB id | Chipset | Adapter | Alternative driver |
|---|---|---|---|
| `0cf3:1001` | AR9170 | Atheros AR9170 | — |
| `0cf3:1002` | AR9170 | Atheros AR9170 | — |
| `0cf3:9170` | AR9170 | Atheros AR9170 | — |

## mt7601u

MediaTek MT7601U (in-tree mt7601u)  
Type: in-tree · monitor mode via `vif`

Very common 2.4 GHz N150 dongle.

| USB id | Chipset | Adapter | Alternative driver |
|---|---|---|---|
| `148f:7601` | MT7601U | MediaTek MT7601U | — |
| `148f:760a` | MT7601U | MediaTek MT7601U | — |
| `148f:760b` | MT7601U | MediaTek MT7601U | — |

## mt76x0u

MediaTek MT7610U / MT7630U (in-tree mt76x0u)  
Type: in-tree · monitor mode via `vif`

Single-stream AC600 MediaTek dongles.

| USB id | Chipset | Adapter | Alternative driver |
|---|---|---|---|
| `0e8d:7610` | MT7610U | MediaTek MT7610U | — |
| `0e8d:7630` | MT7630U | MediaTek MT7630U | — |
| `7392:a711` | MT7610U | Edimax EW-7811UTC | — |

## mt76x2u

MediaTek MT7612U / MT7662U (in-tree mt76x2u)  
Type: in-tree · monitor mode via `vif`

Alfa AWUS036ACM, Netgear A6210. Dual-band mac80211 driver with good injection.

| USB id | Chipset | Adapter | Alternative driver |
|---|---|---|---|
| `0846:9053` | MT7612U | Netgear A6210 | — |
| `0e8d:7612` | MT7612U | MediaTek MT7612U / Alfa AWUS036ACM | — |
| `0e8d:7662` | MT7662U | MediaTek MT7662U | — |

## mt7921u

MediaTek MT7921AU Wi-Fi 6 (in-tree mt7921u)  
Type: in-tree · monitor mode via `vif` · needs kernel 5.17+

Alfa AWUS036AXML and similar AX adapters. Needs kernel 5.17 or newer.

| USB id | Chipset | Adapter | Alternative driver |
|---|---|---|---|
| `0e8d:7961` | MT7921AU | MediaTek MT7921AU / Alfa AWUS036AXML | — |

## rt2800usb

Ralink/MediaTek RT2770-RT5572 (in-tree rt2800usb)  
Type: in-tree · monitor mode via `vif`

Alfa AWUS036NEH/NH and most cheap Ralink dongles. Reliable injection.

| USB id | Chipset | Adapter | Alternative driver |
|---|---|---|---|
| `148f:2070` | RT2070 | Ralink RT2070 | — |
| `148f:2770` | RT2770 | Ralink RT2770 | — |
| `148f:3070` | RT3070 | Ralink RT3070 / Alfa AWUS036NEH | — |
| `148f:3071` | RT3071 | Ralink RT3071 | — |
| `148f:3072` | RT3072 | Ralink RT3072 | — |
| `148f:3370` | RT3370 | Ralink RT3370 | — |
| `148f:3572` | RT3572 | Ralink RT3572 | — |
| `148f:5370` | RT5370 | Ralink RT5370 | — |
| `148f:5372` | RT5372 | Ralink RT5372 | — |
| `148f:5572` | RT5572 | Ralink RT5572 | — |

## rtl8187

Realtek RTL8187 / RTL8187B (in-tree rtl8187)  
Type: in-tree · monitor mode via `vif`

Legacy Alfa AWUS036H. 2.4 GHz b/g only.

| USB id | Chipset | Adapter | Alternative driver |
|---|---|---|---|
| `0789:010c` | RTL8187B | Logitec LAN-W150N | — |
| `0bda:8187` | RTL8187 | Realtek RTL8187 / Alfa AWUS036H | — |
| `0bda:8189` | RTL8187B | Realtek RTL8187B | — |
| `0bda:8197` | RTL8187B | Realtek RTL8187B | — |
| `0bda:8198` | RTL8187B | Realtek RTL8187B | — |

## rtl8xxxu

Realtek RTL8188CU / RTL8192CU / RTL8188EU / RTL8192EU (in-tree rtl8xxxu)  
Type: in-tree · monitor mode via `vif`

Mainline driver for older Realtek N dongles. Monitor mode works, injection is limited.

| USB id | Chipset | Adapter | Alternative driver |
|---|---|---|---|
| `0bda:8176` | RTL8188CUS | Realtek RTL8188CUS | — |
| `0bda:8178` | RTL8192CU | Realtek RTL8192CU | — |
| `0bda:817f` | RTL8188RU | Realtek RTL8188RU | — |
| `0bda:818b` | RTL8192EU | Realtek RTL8192EU | — |

## Drivers with no USB ids in the database

These are selected by hand with `--driver <name>`. Their USB ids were left out
rather than guessed; add yours to `data/adapters.tsv` and send a pull request.

- **8852au** — Realtek RTL8852AU Wi-Fi 6 (out-of-tree, morrownr)
- **8852bu** — Realtek RTL8852BU Wi-Fi 6 (out-of-tree, morrownr)
- **rtw88_usb** — Realtek RTL8822BU / RTL8821CU / RTL8811CU (in-tree rtw88 USB)

## Adding an adapter

Find the id, then add a row to `data/adapters.tsv` (tab separated):

```bash
lsusb                      # inside WSL, once attached
wifimon detect             # shows the id and what it guessed
```

```
vid<TAB>pid<TAB>chipset<TAB>driver<TAB>adapter name<TAB>alternative drivers
```

A local file at `/etc/wifimon/adapters.tsv` is read after the shipped one, so you can
add or override rows without touching the repository.
