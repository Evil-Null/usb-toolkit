# USB Toolkit

![Bash](https://img.shields.io/badge/Bash-5.x-4EAA25?logo=gnubash&logoColor=white)
![License](https://img.shields.io/badge/License-Proprietary-red)
![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen)

All-in-one USB device management tool for Linux — detect, mount, format, backup, health check, write ISOs, and securely wipe USB drives from a single interactive TUI.

## Features

| # | Category | Description |
|---|----------|-------------|
| 1 | **USB Detection** | List and identify connected USB storage devices with model, serial, and USB speed |
| 2 | **Mount USB** | Mount USB partitions with read-only, custom mount point, and filesystem options |
| 3 | **Unmount USB** | Safe unmount with sync and busy-process detection |
| 4 | **Format USB** | Format with 7 filesystems and GPT/MBR partition table choice |
| 5 | **Health Check** | badblocks surface scan, SMART data, fsck, read/write speed test |
| 6 | **Backup & Clone** | Image backup with gzip/zstd compression + SHA256 verification, restore, USB-to-USB clone |
| 7 | **Write ISO** | Write bootable ISO images to USB with progress |
| 8 | **Secure Wipe** | Quick zero, full zero, random, and multi-pass (DoD 5220.22-M) wipe |

**Quick Actions:** Safe Eject (sync + unmount + power off) and Device Info (one-screen device summary).

## Quick Start

```bash
git clone https://github.com/Evil-Null/usb-toolkit.git
cd usb-toolkit
sudo bash usb-toolkit.sh
```

## CLI Usage

```
sudo bash usb-toolkit.sh [OPTION]
```

| Option | Description |
|--------|-------------|
| `--help`, `-h` | Show help message and exit |
| `--version`, `-V` | Show version and exit |
| `--list`, `-l` | List connected USB storage devices (non-interactive) |

No arguments launches the interactive menu.

**Examples:**

```bash
# List all connected USB drives
sudo bash usb-toolkit.sh --list

# Check version
sudo bash usb-toolkit.sh --version
```

## Supported Filesystems

| Filesystem | Best For | Max File Size |
|------------|----------|---------------|
| FAT32 | Universal compatibility | 4 GB |
| exFAT | Large files, cross-platform (Windows/macOS/Linux) | 16 EB |
| NTFS | Windows compatibility, large files | 16 EB |
| ext4 | Linux native, journaled | 16 TB |
| Btrfs | Linux, copy-on-write, snapshots | 16 EB |
| F2FS | Flash-Friendly FS — optimized for USB/SD | 3.94 TB |
| XFS | High-performance journaling | 8 EB |

## Dependencies

**Required** (typically pre-installed):

| Tool | Package |
|------|---------|
| `lsblk` | util-linux |
| `blkid` | util-linux |
| `mount` / `umount` | util-linux |
| `dd` | coreutils |
| `parted` | parted |
| `wipefs` | util-linux |

**Optional** (for full functionality):

| Tool | Package | Used For |
|------|---------|----------|
| `pv` | pv | Progress bars |
| `smartctl` | smartmontools | SMART health data |
| `badblocks` | e2fsprogs | Surface scan |
| `ntfs-3g` | ntfs-3g | NTFS formatting |
| `mkfs.exfat` | exfatprogs | exFAT formatting |
| `mkfs.btrfs` | btrfs-progs | Btrfs formatting |
| `mkfs.f2fs` | f2fs-tools | F2FS formatting |
| `mkfs.xfs` | xfsprogs | XFS formatting |
| `zstd` | zstd | Zstandard compression |

Install all optional dependencies:

```bash
sudo apt install pv smartmontools e2fsprogs ntfs-3g exfatprogs btrfs-progs f2fs-tools xfsprogs zstd
```

## Requirements

- Bash 5.x
- Linux (Debian/Ubuntu, Fedora, Arch)
- Root access required

## License

Proprietary. All rights reserved.

Made in Georgia.
