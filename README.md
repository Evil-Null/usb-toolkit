<p align="center">
  <h1 align="center">USB Toolkit</h1>
  <p align="center">All-in-one USB device management tool for Linux</p>
  <p align="center">
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License"></a>
    <img src="https://img.shields.io/badge/version-2.0-green.svg" alt="Version">
    <img src="https://img.shields.io/badge/platform-Linux-lightgrey.svg" alt="Platform">
    <img src="https://img.shields.io/badge/bash-4.0%2B-orange.svg" alt="Bash">
    <img src="https://img.shields.io/badge/UI-gum-ff69b4.svg" alt="Gum UI">
  </p>
</p>

---

Format, mount, backup, write ISOs, health check, secure wipe — all from a single interactive terminal UI powered by [gum](https://github.com/charmbracelet/gum). Works without gum too — falls back to classic terminal UI.

![USB Toolkit Screenshot](assets/screenshot.png)

## Features

| Category | Description |
|----------|-------------|
| **USB Detection** | List connected USB storage devices with full details |
| **Mount USB** | Mount partitions with read-only, custom options, or specific mount point |
| **Unmount USB** | Safe unmount with sync, force unmount, or unmount all |
| **Format USB** | MBR/GPT partition table, 7 filesystems (FAT32, exFAT, NTFS, ext4, Btrfs, F2FS, XFS) |
| **Health Check** | badblocks, SMART status, fsck, read/write speed test |
| **Backup & Clone** | Image backup (none/gzip/zstd compression), restore, device clone |
| **Write ISO** | Write bootable ISO to USB with SHA256 verification |
| **Secure Wipe** | Quick wipe, full zero, random wipe, 3-pass multi-pass |
| **Safe Eject** | sync + unmount + USB power off |
| **Device Info** | Detailed device summary, partitions, block info |

## Installation

```bash
git clone https://github.com/Evil-Null/usb-toolkit.git
cd usb-toolkit
sudo bash usb-toolkit.sh
```

### Install gum (optional, for modern UI)

```bash
# Debian/Ubuntu
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
sudo apt update && sudo apt install gum

# Arch
pacman -S gum

# Fedora
dnf install gum
```

## Dependencies

| Type | Packages |
|------|----------|
| **Required** | `parted` `lsblk` `blkid` `wipefs` `dd` `mkfs.*` |
| **Optional** | `gum` (interactive UI) · `smartctl` (SMART health) · `pv` (progress bars) · `zstd` (compression) · `badblocks` (disk test) |

## Usage

```bash
# Interactive mode (full menu)
sudo bash usb-toolkit.sh

# CLI mode
sudo bash usb-toolkit.sh --list       # List USB devices
sudo bash usb-toolkit.sh --help       # Show help
sudo bash usb-toolkit.sh --version    # Show version
```

## How It Works

```
┌──────────────────────────────────────────────────────────┐
│                  USB TOOLKIT v2.0                        │
│           Device Operations & Management                 │
├──────────────────────────────────────────────────────────┤
│  1. Detect    │  2. Mount     │  3. Unmount              │
│  4. Format    │  5. Health    │  6. Backup & Clone       │
│  7. Write ISO │  8. Wipe      │  9. Safe Eject           │
├──────────────────────────────────────────────────────────┤
│  Interactive UI (gum)  ←→  Fallback UI (ANSI)           │
├──────────────────────────────────────────────────────────┤
│  parted · mkfs · dd · lsblk · blkid · smartctl · pv     │
└──────────────────────────────────────────────────────────┘
```

## License

[MIT](LICENSE)
