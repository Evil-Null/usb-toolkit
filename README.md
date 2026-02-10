# USB Security Manager

Kernel-level USB device security management for Linux. Controls storage access, automount behavior, port authorization, and per-device policies through a single interactive interface.

## Architecture

**5 security layers | 7 menu options | ~1,160 lines**

```
┌─────────────────────────────────────────────────────┐
│              USB SECURITY MANAGER v2.0              │
│              Interactive Menu & Status               │
├───────────┬───────────┬───────────┬─────────────────┤
│  Storage  │ Automount │   Ports   │  Guard Rules    │
│ modprobe  │  udisks2  │  kernel   │     udev        │
├───────────┴───────────┴───────────┴─────────────────┤
│     USB Device Audit    │    Logging & Events       │
├─────────────────────────┴───────────────────────────┤
│  LOCKDOWN (one-click)   │   UNLOCK ALL (one-click)  │
└─────────────────────────┴───────────────────────────┘
```

## Security Layers

| Layer | Mechanism | Scope | Persistence |
|-------|-----------|-------|:-----------:|
| **USB Storage** | `modprobe` blacklist | Flash drives, external HDD/SSD, SD readers | Reboot-safe |
| **Automount** | `udisks2` systemd sandbox | ProtectHome, ProtectKernel, NoNewPrivileges | Reboot-safe |
| **USB Ports** | Kernel `authorized_default` | All USB device types (HID, storage, etc.) | Reboot-safe (udev) |
| **Guard Rules** | udev VID:PID rules | Per-device block/whitelist | Reboot-safe |
| **Logging** | udev event rules | Connect/disconnect audit trail | `/var/log/usb-events.log` |

## Menu

```
Categories:
  1) USB Storage       — Enable/disable flash drives & disks
  2) USB Automount     — Manage udisks2 mount service
  3) USB Ports         — Kernel-level USB port blocking
  4) USB Guard Rules   — Block/allow specific devices
  5) USB Audit         — Full device audit & analysis

Quick Actions:
  6) LOCKDOWN          — Harden everything in one step
  7) UNLOCK ALL        — Restore everything in one step
```

## Quick Start

```bash
sudo bash usb-hardening.sh
```

## Key Features

- **One-click lockdown** — blocks storage, hardens automount, enables logging
- **One-click unlock** — restores all settings to default
- **Per-device control** — block or whitelist specific devices by VID:PID
- **Manual authorization** — selectively allow blocked devices
- **Full audit** — connected devices, bus policy, kernel modules, blacklist files
- **Event logging** — records all USB connect/disconnect events with timestamps

## How It Works

| Action | What happens |
|--------|-------------|
| Block storage | `blacklist usb-storage` + `blacklist uas` in `/etc/modprobe.d/` |
| Harden automount | systemd override with ProtectHome, NoNewPrivileges |
| Block ports | `authorized_default=0` on all USB buses + persistent udev rule |
| Block device | udev rule: `ATTR{idVendor}=="xxxx"` → `authorized=0` |
| Whitelist device | udev rule: `ATTR{idVendor}=="xxxx"` → `authorized=1` |
| Logging | udev rule writes to `/var/log/usb-events.log` |

## Requirements

- Bash 4.0+
- Linux (Ubuntu / Debian / Zorin OS)
- Root access required

## License

Proprietary. All rights reserved.

Made in Georgia.
