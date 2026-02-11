#!/usr/bin/env bash
# ============================================================================
#  USB TOOLKIT
#  USB Device Operations & Management
#  Version:  1.0
#  Date:     2026-02-12
#  Tested:   Ubuntu 24.04 / Zorin OS
#  Usage:    sudo bash usb-toolkit.sh
#
#  8 Categories:
#    1. USB Detection    — List and identify connected USB storage devices
#    2. Mount USB        — Mount USB partitions with various options
#    3. Unmount USB      — Safe unmount with sync and process check
#    4. Format USB       — Format with filesystem and partition table choice
#    5. Health Check     — badblocks, SMART, fsck, speed test
#    6. Backup & Clone   — Image backup, restore, USB-to-USB clone
#    7. Write ISO        — Write bootable ISO image to USB
#    8. Secure Wipe      — Quick, full, random, and multi-pass wipe
#
#  Quick Actions:
#    9. Safe Eject       — sync + unmount + power off
#   10. Device Info      — Quick summary of a selected USB device
#
# ============================================================================

set -uo pipefail

# ============================================================================
#  Configuration
# ============================================================================

readonly SCRIPT_VERSION="1.0"
readonly LOG_FILE="/var/log/usb-toolkit.log"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

# ============================================================================
#  Helper Functions
# ============================================================================

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] $1" >> "$LOG_FILE" 2>/dev/null || true
}

print_ok() {
    echo -e "    ${GREEN}[OK]${NC}      $1"
    log "OK: $1"
}

print_skip() {
    echo -e "    ${YELLOW}[SKIP]${NC}    $1"
    log "SKIP: $1"
}

print_fail() {
    echo -e "    ${RED}[FAIL]${NC}    $1"
    log "FAIL: $1"
}

print_info() {
    echo -e "    ${CYAN}[INFO]${NC}    $1"
}

print_warn() {
    echo -e "    ${YELLOW}[WARN]${NC}    $1"
}

print_header() {
    echo ""
    echo -e "${BLUE}${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}    $1${NC}"
    echo -e "${BLUE}${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_section() {
    echo ""
    echo -e "  ${CYAN}${BOLD}  [$1]  $2${NC}"
    echo -e "  ${CYAN}  ─────────────────────────────────────────────────${NC}"
}

confirm_action() {
    local msg="$1"
    echo ""
    read -rp "  ${msg} [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

double_confirm() {
    local device="$1"
    echo ""
    echo -e "  ${RED}${BOLD}  ╔══════════════════════════════════════════════════╗${NC}"
    echo -e "  ${RED}${BOLD}  ║          *** DESTRUCTIVE OPERATION ***           ║${NC}"
    echo -e "  ${RED}${BOLD}  ║   ALL DATA ON ${device} WILL BE DESTROYED!   ║${NC}"
    echo -e "  ${RED}${BOLD}  ╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    read -rp "  Type the device name (e.g. ${device}) to confirm: " typed
    [[ "$typed" == "$device" ]]
}

get_current_user() {
    logname 2>/dev/null || echo "${SUDO_USER:-root}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "\n${RED}${BOLD}  ERROR: This script requires root privileges!${NC}"
        echo -e "${RED}  Run: sudo bash $0${NC}\n"
        exit 1
    fi
    touch "$LOG_FILE" 2>/dev/null && chmod 600 "$LOG_FILE" 2>/dev/null || true
    log "========== USB TOOLKIT v${SCRIPT_VERSION} STARTED =========="
}

check_dependencies() {
    local missing=()
    local optional_missing=()

    # Required tools
    local required=("lsblk" "blkid" "mount" "umount" "dd" "parted" "wipefs")
    for cmd in "${required[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "\n${RED}${BOLD}  ERROR: Missing required tools: ${missing[*]}${NC}"
        echo -e "${RED}  Install them before running this script.${NC}\n"
        exit 1
    fi

    # Optional tools
    local optional=("pv" "smartctl" "badblocks" "ntfs-3g" "mkfs.exfat" "mkfs.btrfs")
    for cmd in "${optional[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            optional_missing+=("$cmd")
        fi
    done

    if [[ ${#optional_missing[@]} -gt 0 ]]; then
        echo -e "  ${DIM}  Optional tools not found: ${optional_missing[*]}${NC}"
        echo -e "  ${DIM}  Some features may be limited.${NC}"
    fi
}

# ============================================================================
#  USB Device Discovery Helpers
# ============================================================================

# Get list of USB block devices (whole disks only, e.g. sdb, sdc)
get_usb_devices() {
    local devices=()
    for block in /sys/block/sd*; do
        [[ ! -d "$block" ]] && continue
        local dev_name
        dev_name=$(basename "$block")
        # Check if removable
        local removable
        removable=$(cat "${block}/removable" 2>/dev/null || echo "0")
        # Also check if it's on USB bus
        if [[ "$removable" == "1" ]] || readlink -f "${block}/device" 2>/dev/null | grep -q "usb"; then
            devices+=("$dev_name")
        fi
    done
    echo "${devices[@]}"
}

# Get USB partitions (e.g. sdb1, sdc1)
get_usb_partitions() {
    local partitions=()
    local usb_devs
    usb_devs=$(get_usb_devices)
    for dev in $usb_devs; do
        # Add whole device if it has no partitions
        local has_parts=0
        for part in /sys/block/"${dev}"/"${dev}"[0-9]*; do
            [[ ! -d "$part" ]] && continue
            has_parts=1
            partitions+=("$(basename "$part")")
        done
        if [[ $has_parts -eq 0 ]]; then
            partitions+=("$dev")
        fi
    done
    echo "${partitions[@]}"
}

# Get unmounted USB partitions
get_unmounted_usb_partitions() {
    local unmounted=()
    local parts
    parts=$(get_usb_partitions)
    for part in $parts; do
        if ! findmnt -rn "/dev/${part}" &>/dev/null; then
            unmounted+=("$part")
        fi
    done
    echo "${unmounted[@]}"
}

# Get mounted USB partitions
get_mounted_usb_partitions() {
    local mounted=()
    local parts
    parts=$(get_usb_partitions)
    for part in $parts; do
        if findmnt -rn "/dev/${part}" &>/dev/null; then
            mounted+=("$part")
        fi
    done
    echo "${mounted[@]}"
}

# Interactive device selection — returns selected device in $SELECTED_DEV
# Args: $1 = device list (space-separated), $2 = prompt label
SELECTED_DEV=""
select_device() {
    local dev_list=($1)
    local label="$2"

    SELECTED_DEV=""

    if [[ ${#dev_list[@]} -eq 0 ]]; then
        print_info "No ${label} found."
        return 1
    fi

    echo ""
    echo -e "  ${BOLD}Available ${label}:${NC}"
    echo ""

    local i=1
    for dev in "${dev_list[@]}"; do
        local size model fstype label_name
        size=$(lsblk -dnro SIZE "/dev/${dev}" 2>/dev/null || echo "?")
        model=$(lsblk -dnro MODEL "/dev/${dev}" 2>/dev/null || echo "")
        fstype=$(blkid -o value -s TYPE "/dev/${dev}" 2>/dev/null || echo "")
        label_name=$(blkid -o value -s LABEL "/dev/${dev}" 2>/dev/null || echo "")

        printf "    ${GREEN}%2d)${NC}  /dev/%-8s  ${BOLD}%6s${NC}" "$i" "$dev" "$size"
        [[ -n "$fstype" ]] && printf "  ${DIM}[%s]${NC}" "$fstype"
        [[ -n "$label_name" ]] && printf "  ${CYAN}%s${NC}" "$label_name"
        [[ -n "$model" ]] && printf "  ${DIM}%s${NC}" "$model"
        echo ""
        i=$((i + 1))
    done

    echo ""
    read -rp "  Select device [1-${#dev_list[@]}] (0 to cancel): " choice

    if [[ "$choice" == "0" || -z "$choice" ]]; then
        return 1
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#dev_list[@]} ]]; then
        SELECTED_DEV="${dev_list[$((choice - 1))]}"
        return 0
    fi

    echo -e "  ${RED}Invalid selection${NC}"
    return 1
}

# Check device is not a system disk
is_system_disk() {
    local dev="$1"
    # Strip partition number to get base device
    local base_dev
    base_dev=$(echo "$dev" | sed 's/[0-9]*$//')

    # Check if root filesystem is on this device
    local root_dev
    root_dev=$(findmnt -rno SOURCE / 2>/dev/null | sed 's/[0-9]*$//' | sed 's|/dev/||')

    if [[ "$base_dev" == "$root_dev" ]]; then
        return 0  # IS system disk
    fi
    return 1  # NOT system disk
}

# ============================================================================
#  Category 1: USB DEVICE DETECTION
#  List all connected USB storage devices with detailed info.
# ============================================================================

detect_list_devices() {
    print_header "USB Storage Devices"

    local usb_devs
    usb_devs=$(get_usb_devices)

    if [[ -z "$usb_devs" ]]; then
        print_info "No USB storage devices detected."
        echo ""
        return
    fi

    for dev in $usb_devs; do
        echo ""
        local size model serial vendor_id product_id
        size=$(lsblk -dnro SIZE "/dev/${dev}" 2>/dev/null || echo "Unknown")
        model=$(cat "/sys/block/${dev}/device/model" 2>/dev/null | xargs || echo "Unknown")
        serial=$(cat "/sys/block/${dev}/device/../../serial" 2>/dev/null | xargs || echo "N/A")
        vendor_id=$(cat "/sys/block/${dev}/device/../../idVendor" 2>/dev/null || echo "????")
        product_id=$(cat "/sys/block/${dev}/device/../../idProduct" 2>/dev/null || echo "????")
        local removable
        removable=$(cat "/sys/block/${dev}/removable" 2>/dev/null || echo "?")

        echo -e "    ${BOLD}${GREEN}/dev/${dev}${NC}  —  ${BOLD}${size}${NC}  ${DIM}[${vendor_id}:${product_id}]${NC}"
        echo -e "      ${DIM}Model:   ${model}${NC}"
        echo -e "      ${DIM}Serial:  ${serial}${NC}"
        echo -e "      ${DIM}Removable: ${removable}${NC}"

        # Show partitions
        local has_parts=0
        for part in /sys/block/"${dev}"/"${dev}"[0-9]*; do
            [[ ! -d "$part" ]] && continue
            has_parts=1
            local part_name
            part_name=$(basename "$part")
            local psize fstype plabel mountpoint
            psize=$(lsblk -dnro SIZE "/dev/${part_name}" 2>/dev/null || echo "?")
            fstype=$(blkid -o value -s TYPE "/dev/${part_name}" 2>/dev/null || echo "unknown")
            plabel=$(blkid -o value -s LABEL "/dev/${part_name}" 2>/dev/null || echo "")
            mountpoint=$(findmnt -rno TARGET "/dev/${part_name}" 2>/dev/null || echo "not mounted")

            printf "      ${CYAN}├─ %-8s${NC}  %6s  [%s]" "$part_name" "$psize" "$fstype"
            [[ -n "$plabel" ]] && printf "  label=\"%s\"" "$plabel"
            echo ""
            echo -e "      ${DIM}│  Mount: ${mountpoint}${NC}"
        done

        if [[ $has_parts -eq 0 ]]; then
            local fstype mountpoint
            fstype=$(blkid -o value -s TYPE "/dev/${dev}" 2>/dev/null || echo "no filesystem")
            mountpoint=$(findmnt -rno TARGET "/dev/${dev}" 2>/dev/null || echo "not mounted")
            echo -e "      ${CYAN}└─ No partitions${NC}  [${fstype}]  Mount: ${mountpoint}"
        fi
    done
    echo ""
}

detect_menu() {
    print_header "Category 1: USB Device Detection"
    echo ""
    echo -e "  ${DIM}  Detect and display information about connected USB storage devices.${NC}"
    echo ""
    echo -e "    ${GREEN}1)${NC}  List all USB storage devices"
    echo -e "    ${BLUE}0)${NC}  Back"
    echo ""
    read -rp "  Choice [0-1]: " choice

    case "$choice" in
        1) detect_list_devices ;;
        0) return ;;
        *) echo -e "  ${RED}Invalid choice${NC}" ;;
    esac
}

# ============================================================================
#  Category 2: MOUNT USB
#  Mount USB partitions with various options.
# ============================================================================

mount_usb() {
    print_header "Mount USB Device"
    log "ACTION: Mount USB"

    local unmounted
    unmounted=$(get_unmounted_usb_partitions)

    if ! select_device "$unmounted" "unmounted USB partitions"; then
        return
    fi

    local dev="$SELECTED_DEV"
    local fstype
    fstype=$(blkid -o value -s TYPE "/dev/${dev}" 2>/dev/null || echo "")
    local dev_label
    dev_label=$(blkid -o value -s LABEL "/dev/${dev}" 2>/dev/null || echo "$dev")

    echo ""
    echo -e "  ${BOLD}Device:${NC} /dev/${dev}"
    [[ -n "$fstype" ]] && echo -e "  ${BOLD}Filesystem:${NC} ${fstype}"
    echo -e "  ${BOLD}Label:${NC} ${dev_label}"

    # Mount options
    echo ""
    echo -e "  ${BOLD}Mount mode:${NC}"
    echo -e "    ${GREEN}1)${NC}  Read-Write ${DIM}(default)${NC}"
    echo -e "    ${CYAN}2)${NC}  Read-Only"
    echo -e "    ${YELLOW}3)${NC}  Read-Write + noexec + sync"
    echo -e "    ${MAGENTA}4)${NC}  Custom options"
    echo ""
    read -rp "  Choice [1-4]: " mode

    local mount_opts=""
    case "$mode" in
        1|"") mount_opts="" ;;
        2) mount_opts="-o ro" ;;
        3) mount_opts="-o noexec,sync" ;;
        4)
            read -rp "  Enter mount options (e.g. ro,noexec,sync): " custom_opts
            mount_opts="-o ${custom_opts}"
            ;;
        *)
            echo -e "  ${RED}Invalid choice${NC}"
            return
            ;;
    esac

    # Mount point
    local user
    user=$(get_current_user)
    local default_mount="/media/${user}/${dev_label}"
    echo ""
    read -rp "  Mount point [${default_mount}]: " custom_mount
    local mount_point="${custom_mount:-$default_mount}"

    # Create mount point
    mkdir -p "$mount_point"

    # Determine filesystem options
    local fs_opts=""
    if [[ "$fstype" == "vfat" || "$fstype" == "exfat" ]]; then
        local uid gid
        uid=$(id -u "$user" 2>/dev/null || echo "1000")
        gid=$(id -g "$user" 2>/dev/null || echo "1000")
        if [[ -n "$mount_opts" ]]; then
            mount_opts="${mount_opts},uid=${uid},gid=${gid}"
        else
            mount_opts="-o uid=${uid},gid=${gid}"
        fi
    fi

    # Mount
    local mount_cmd="mount"
    [[ -n "$mount_opts" ]] && mount_cmd="mount ${mount_opts}"
    [[ -n "$fstype" ]] && mount_cmd="${mount_cmd} -t ${fstype}"

    if eval "${mount_cmd} /dev/${dev} '${mount_point}'" 2>/dev/null; then
        print_ok "Mounted /dev/${dev} → ${mount_point}"
        log "MOUNT: /dev/${dev} → ${mount_point} [opts: ${mount_opts}]"
        # Fix permissions for user
        if [[ "$fstype" != "vfat" && "$fstype" != "exfat" && "$fstype" != "ntfs" ]]; then
            chown "${user}:${user}" "$mount_point" 2>/dev/null || true
        fi
    else
        print_fail "Failed to mount /dev/${dev}"
        rmdir "$mount_point" 2>/dev/null || true
    fi
    echo ""
}

mount_menu() {
    print_header "Category 2: Mount USB"
    echo ""
    echo -e "  ${DIM}  Mount USB partitions with various options.${NC}"
    echo ""
    echo -e "    ${GREEN}1)${NC}  Mount a USB device"
    echo -e "    ${BLUE}0)${NC}  Back"
    echo ""
    read -rp "  Choice [0-1]: " choice

    case "$choice" in
        1) mount_usb ;;
        0) return ;;
        *) echo -e "  ${RED}Invalid choice${NC}" ;;
    esac
}

# ============================================================================
#  Category 3: UNMOUNT USB
#  Safe unmount with sync, process check, and force option.
# ============================================================================

unmount_show_processes() {
    local dev="$1"
    local mount_point="$2"

    echo ""
    echo -e "  ${BOLD}Processes using /dev/${dev}:${NC}"

    if command -v lsof &>/dev/null; then
        local procs
        procs=$(lsof "$mount_point" 2>/dev/null | tail -n +2)
        if [[ -n "$procs" ]]; then
            echo "$procs" | while IFS= read -r line; do
                echo -e "    ${DIM}${line}${NC}"
            done
        else
            print_info "No processes found using this device."
        fi
    elif command -v fuser &>/dev/null; then
        fuser -v "$mount_point" 2>&1 | while IFS= read -r line; do
            echo -e "    ${DIM}${line}${NC}"
        done
    else
        print_warn "Neither lsof nor fuser available."
    fi
}

unmount_usb() {
    print_header "Unmount USB Device"
    log "ACTION: Unmount USB"

    local mounted
    mounted=$(get_mounted_usb_partitions)

    if ! select_device "$mounted" "mounted USB partitions"; then
        return
    fi

    local dev="$SELECTED_DEV"
    local mount_point
    mount_point=$(findmnt -rno TARGET "/dev/${dev}" 2>/dev/null)

    echo ""
    echo -e "  ${BOLD}Device:${NC}     /dev/${dev}"
    echo -e "  ${BOLD}Mounted at:${NC} ${mount_point}"

    echo ""
    echo -e "  ${BOLD}Unmount mode:${NC}"
    echo -e "    ${GREEN}1)${NC}  Safe unmount ${DIM}(sync then umount)${NC}"
    echo -e "    ${YELLOW}2)${NC}  Force unmount ${DIM}(umount -f — for busy devices)${NC}"
    echo -e "    ${CYAN}3)${NC}  Show processes using this device"
    echo ""
    read -rp "  Choice [1-3]: " mode

    case "$mode" in
        1)
            print_info "Syncing filesystem..."
            sync
            if umount "/dev/${dev}" 2>/dev/null; then
                print_ok "Unmounted /dev/${dev} from ${mount_point}"
                log "UNMOUNT: /dev/${dev} from ${mount_point}"
                # Clean up empty mount point
                rmdir "$mount_point" 2>/dev/null || true
            else
                print_fail "Could not unmount /dev/${dev} — device may be busy"
                unmount_show_processes "$dev" "$mount_point"
            fi
            ;;
        2)
            print_warn "Force unmounting /dev/${dev}..."
            sync
            if umount -f "/dev/${dev}" 2>/dev/null; then
                print_ok "Force unmounted /dev/${dev}"
                log "UNMOUNT (force): /dev/${dev} from ${mount_point}"
                rmdir "$mount_point" 2>/dev/null || true
            else
                print_fail "Force unmount failed"
                print_info "Try: umount -l /dev/${dev} (lazy unmount)"
            fi
            ;;
        3)
            unmount_show_processes "$dev" "$mount_point"
            ;;
        *)
            echo -e "  ${RED}Invalid choice${NC}"
            ;;
    esac
    echo ""
}

unmount_menu() {
    print_header "Category 3: Unmount USB"
    echo ""
    echo -e "  ${DIM}  Safely unmount USB devices with sync and process check.${NC}"
    echo ""
    echo -e "    ${GREEN}1)${NC}  Unmount a USB device"
    echo -e "    ${BLUE}0)${NC}  Back"
    echo ""
    read -rp "  Choice [0-1]: " choice

    case "$choice" in
        1) unmount_usb ;;
        0) return ;;
        *) echo -e "  ${RED}Invalid choice${NC}" ;;
    esac
}

# ============================================================================
#  Category 4: FORMAT USB
#  Format USB drives with filesystem and partition table choice.
# ============================================================================

format_usb() {
    print_header "Format USB Device"
    log "ACTION: Format USB"

    local usb_devs
    usb_devs=$(get_usb_devices)

    if ! select_device "$usb_devs" "USB devices"; then
        return
    fi

    local dev="$SELECTED_DEV"

    # Safety check — don't format system disk
    if is_system_disk "$dev"; then
        print_fail "/dev/${dev} appears to be a system disk! Refusing to format."
        return
    fi

    local size
    size=$(lsblk -dnro SIZE "/dev/${dev}" 2>/dev/null || echo "Unknown")

    echo ""
    echo -e "  ${BOLD}Selected:${NC} /dev/${dev}  (${size})"

    # Check if mounted
    local mounted_parts
    mounted_parts=$(lsblk -rno NAME,MOUNTPOINT "/dev/${dev}" 2>/dev/null | awk '$2 != "" {print "/dev/"$1}')
    if [[ -n "$mounted_parts" ]]; then
        echo ""
        echo -e "  ${YELLOW}Warning: Device has mounted partitions:${NC}"
        echo "$mounted_parts" | while IFS= read -r mp; do
            echo -e "    ${DIM}${mp}${NC}"
        done
        if ! confirm_action "Unmount all partitions and continue?"; then
            echo -e "  ${YELLOW}Cancelled.${NC}"
            return
        fi
        # Unmount all
        for part in $(lsblk -rno NAME "/dev/${dev}" 2>/dev/null | tail -n +2); do
            sync
            umount "/dev/${part}" 2>/dev/null || true
        done
        print_ok "All partitions unmounted"
    fi

    # Partition table
    echo ""
    echo -e "  ${BOLD}Partition table:${NC}"
    echo -e "    ${GREEN}1)${NC}  MBR (dos) ${DIM}— compatible with most devices (default)${NC}"
    echo -e "    ${CYAN}2)${NC}  GPT       ${DIM}— modern, supports >2TB${NC}"
    echo ""
    read -rp "  Choice [1-2]: " pt_choice

    local pt_type="msdos"
    case "$pt_choice" in
        1|"") pt_type="msdos" ;;
        2) pt_type="gpt" ;;
        *) echo -e "  ${RED}Invalid choice, using MBR${NC}"; pt_type="msdos" ;;
    esac

    # Filesystem
    echo ""
    echo -e "  ${BOLD}Filesystem:${NC}"
    echo -e "    ${GREEN}1)${NC}  FAT32   ${DIM}— universal compatibility (max 4GB file)${NC}"
    echo -e "    ${CYAN}2)${NC}  exFAT   ${DIM}— large file support, cross-platform${NC}"
    echo -e "    ${MAGENTA}3)${NC}  NTFS    ${DIM}— Windows compatible, large files${NC}"
    echo -e "    ${YELLOW}4)${NC}  ext4    ${DIM}— Linux native, journaled${NC}"
    echo -e "    ${BLUE}5)${NC}  Btrfs   ${DIM}— Linux, COW, snapshots${NC}"
    echo ""
    read -rp "  Choice [1-5]: " fs_choice

    local fs_type="" mkfs_cmd=""
    case "$fs_choice" in
        1|"")
            fs_type="fat32"
            mkfs_cmd="mkfs.vfat -F 32"
            ;;
        2)
            if ! command -v mkfs.exfat &>/dev/null; then
                print_fail "mkfs.exfat not found. Install: sudo apt install exfat-utils"
                return
            fi
            fs_type="exfat"
            mkfs_cmd="mkfs.exfat"
            ;;
        3)
            if ! command -v mkfs.ntfs &>/dev/null; then
                print_fail "mkfs.ntfs not found. Install: sudo apt install ntfs-3g"
                return
            fi
            fs_type="ntfs"
            mkfs_cmd="mkfs.ntfs -f"
            ;;
        4)
            fs_type="ext4"
            mkfs_cmd="mkfs.ext4 -F"
            ;;
        5)
            if ! command -v mkfs.btrfs &>/dev/null; then
                print_fail "mkfs.btrfs not found. Install: sudo apt install btrfs-progs"
                return
            fi
            fs_type="btrfs"
            mkfs_cmd="mkfs.btrfs -f"
            ;;
        *)
            echo -e "  ${RED}Invalid choice${NC}"
            return
            ;;
    esac

    # Volume label
    echo ""
    read -rp "  Volume label (leave empty for none): " vol_label

    # Format type
    echo ""
    echo -e "  ${BOLD}Format mode:${NC}"
    echo -e "    ${GREEN}1)${NC}  Quick format ${DIM}(default — fast)${NC}"
    echo -e "    ${RED}2)${NC}  Full format  ${DIM}(zero disk first — slow but thorough)${NC}"
    echo ""
    read -rp "  Choice [1-2]: " fmt_mode

    # Final confirmation
    echo ""
    echo -e "  ${BOLD}Summary:${NC}"
    echo -e "    Device:     /dev/${dev} (${size})"
    echo -e "    Partition:  ${pt_type}"
    echo -e "    Filesystem: ${fs_type}"
    [[ -n "$vol_label" ]] && echo -e "    Label:      ${vol_label}"
    echo -e "    Mode:       $([ "${fmt_mode}" == "2" ] && echo "Full (zero first)" || echo "Quick")"

    if ! double_confirm "$dev"; then
        echo -e "  ${YELLOW}Cancelled.${NC}"
        return
    fi

    log "FORMAT: /dev/${dev} pt=${pt_type} fs=${fs_type} label=${vol_label}"

    # Full format — zero disk first
    if [[ "$fmt_mode" == "2" ]]; then
        print_info "Zeroing disk (this may take a while)..."
        dd if=/dev/zero of="/dev/${dev}" bs=4M status=progress 2>&1 || true
        sync
        print_ok "Disk zeroed"
    fi

    # Create partition table
    print_info "Creating ${pt_type} partition table..."
    parted -s "/dev/${dev}" mklabel "$pt_type" 2>/dev/null
    print_ok "Partition table created: ${pt_type}"

    # Create partition
    print_info "Creating partition..."
    parted -s "/dev/${dev}" mkpart primary 1MiB 100% 2>/dev/null
    print_ok "Partition created"

    # Wait for kernel to detect partition
    partprobe "/dev/${dev}" 2>/dev/null || true
    sleep 1

    # Determine partition name
    local part_dev="${dev}1"
    if [[ ! -b "/dev/${part_dev}" ]]; then
        # Try without number (for devices like nvme)
        part_dev="${dev}p1"
        if [[ ! -b "/dev/${part_dev}" ]]; then
            part_dev="$dev"
        fi
    fi

    # Format
    print_info "Formatting /dev/${part_dev} as ${fs_type}..."

    local label_opt=""
    if [[ -n "$vol_label" ]]; then
        case "$fs_type" in
            fat32)   label_opt="-n ${vol_label}" ;;
            exfat)   label_opt="-L ${vol_label}" ;;
            ntfs)    label_opt="-L ${vol_label}" ;;
            ext4)    label_opt="-L ${vol_label}" ;;
            btrfs)   label_opt="-L ${vol_label}" ;;
        esac
    fi

    if eval "${mkfs_cmd} ${label_opt} /dev/${part_dev}" &>/dev/null; then
        print_ok "Formatted /dev/${part_dev} as ${fs_type}"
    else
        print_fail "Formatting failed"
        return
    fi

    sync
    print_ok "Format complete!"
    echo ""
    echo -e "  ${GREEN}${BOLD}  /dev/${dev} formatted successfully.${NC}"
    echo -e "  ${DIM}  Remove and reinsert the drive, or mount manually.${NC}"
    echo ""
}

format_menu() {
    print_header "Category 4: Format USB"
    echo ""
    echo -e "  ${DIM}  Format USB drives with filesystem and partition table options.${NC}"
    echo ""
    echo -e "    ${GREEN}1)${NC}  Format a USB device"
    echo -e "    ${BLUE}0)${NC}  Back"
    echo ""
    read -rp "  Choice [0-1]: " choice

    case "$choice" in
        1) format_usb ;;
        0) return ;;
        *) echo -e "  ${RED}Invalid choice${NC}" ;;
    esac
}

# ============================================================================
#  Category 5: USB HEALTH CHECK
#  badblocks, SMART data, fsck, speed test
# ============================================================================

health_badblocks() {
    print_header "Bad Blocks Test (Read-Only)"

    local usb_devs
    usb_devs=$(get_usb_devices)

    if ! select_device "$usb_devs" "USB devices"; then
        return
    fi

    local dev="$SELECTED_DEV"

    if ! command -v badblocks &>/dev/null; then
        print_fail "badblocks not found. Install: sudo apt install e2fsprogs"
        return
    fi

    if is_system_disk "$dev"; then
        print_fail "/dev/${dev} appears to be a system disk!"
        return
    fi

    print_info "Running read-only bad blocks test on /dev/${dev}..."
    print_info "This may take a while depending on device size."
    echo ""

    local bad_count
    bad_count=$(badblocks -sv "/dev/${dev}" 2>&1 | tee /dev/stderr | grep -c "^[0-9]" || echo "0")

    echo ""
    if [[ "$bad_count" -eq 0 ]]; then
        print_ok "No bad blocks found on /dev/${dev}"
    else
        print_warn "${bad_count} bad blocks found on /dev/${dev}"
    fi
    log "HEALTHCHECK: badblocks /dev/${dev} — ${bad_count} bad blocks"
}

health_smart() {
    print_header "SMART Data"

    local usb_devs
    usb_devs=$(get_usb_devices)

    if ! select_device "$usb_devs" "USB devices"; then
        return
    fi

    local dev="$SELECTED_DEV"

    if ! command -v smartctl &>/dev/null; then
        print_fail "smartctl not found. Install: sudo apt install smartmontools"
        return
    fi

    echo ""
    print_info "Querying SMART data for /dev/${dev}..."
    echo ""

    local smart_output
    smart_output=$(smartctl -a "/dev/${dev}" 2>&1)

    if echo "$smart_output" | grep -q "SMART support is: Available"; then
        echo "$smart_output" | while IFS= read -r line; do
            echo -e "    ${DIM}${line}${NC}"
        done
    elif echo "$smart_output" | grep -q "Unknown USB bridge"; then
        print_warn "SMART not available through USB bridge."
        print_info "Try: smartctl -a -d sat /dev/${dev}"
        echo ""
        smartctl -a -d sat "/dev/${dev}" 2>&1 | while IFS= read -r line; do
            echo -e "    ${DIM}${line}${NC}"
        done
    else
        print_warn "SMART not supported on this device."
        echo "$smart_output" | head -10 | while IFS= read -r line; do
            echo -e "    ${DIM}${line}${NC}"
        done
    fi
    echo ""
}

health_fsck() {
    print_header "Filesystem Check (fsck)"

    local unmounted
    unmounted=$(get_unmounted_usb_partitions)

    if ! select_device "$unmounted" "unmounted USB partitions"; then
        echo ""
        print_warn "Only unmounted partitions can be checked."
        return
    fi

    local dev="$SELECTED_DEV"
    local fstype
    fstype=$(blkid -o value -s TYPE "/dev/${dev}" 2>/dev/null || echo "")

    if [[ -z "$fstype" ]]; then
        print_fail "Could not determine filesystem type for /dev/${dev}"
        return
    fi

    echo ""
    echo -e "  ${BOLD}Device:${NC}     /dev/${dev}"
    echo -e "  ${BOLD}Filesystem:${NC} ${fstype}"

    if ! confirm_action "Run filesystem check on /dev/${dev}?"; then
        return
    fi

    print_info "Running fsck on /dev/${dev}..."
    echo ""

    case "$fstype" in
        ext2|ext3|ext4)
            e2fsck -fvy "/dev/${dev}" 2>&1 | while IFS= read -r line; do
                echo -e "    ${DIM}${line}${NC}"
            done
            ;;
        vfat)
            fsck.vfat -vy "/dev/${dev}" 2>&1 | while IFS= read -r line; do
                echo -e "    ${DIM}${line}${NC}"
            done
            ;;
        ntfs)
            if command -v ntfsfix &>/dev/null; then
                ntfsfix "/dev/${dev}" 2>&1 | while IFS= read -r line; do
                    echo -e "    ${DIM}${line}${NC}"
                done
            else
                print_fail "ntfsfix not found. Install: sudo apt install ntfs-3g"
            fi
            ;;
        exfat)
            if command -v fsck.exfat &>/dev/null; then
                fsck.exfat "/dev/${dev}" 2>&1 | while IFS= read -r line; do
                    echo -e "    ${DIM}${line}${NC}"
                done
            else
                print_fail "fsck.exfat not found. Install: sudo apt install exfat-utils"
            fi
            ;;
        btrfs)
            btrfs check "/dev/${dev}" 2>&1 | while IFS= read -r line; do
                echo -e "    ${DIM}${line}${NC}"
            done
            ;;
        *)
            print_warn "No fsck tool known for filesystem: ${fstype}"
            ;;
    esac

    echo ""
    print_ok "Filesystem check complete"
    log "HEALTHCHECK: fsck /dev/${dev} (${fstype})"
}

health_speed_test() {
    print_header "USB Speed Test"

    local usb_devs
    usb_devs=$(get_usb_devices)

    if ! select_device "$usb_devs" "USB devices"; then
        return
    fi

    local dev="$SELECTED_DEV"
    local size_bytes
    size_bytes=$(blockdev --getsize64 "/dev/${dev}" 2>/dev/null || echo "0")

    echo ""
    echo -e "  ${BOLD}Testing read speed on /dev/${dev}...${NC}"
    echo ""

    # Read speed test (256MB or device size, whichever is smaller)
    local test_blocks=64
    local block_size="4M"
    local test_size="256MB"

    if [[ "$size_bytes" -lt 268435456 ]]; then
        test_blocks=$((size_bytes / 4194304))
        [[ $test_blocks -lt 1 ]] && test_blocks=1
        test_size="$((test_blocks * 4))MB"
    fi

    print_info "Reading ${test_size} from /dev/${dev}..."
    echo ""

    dd if="/dev/${dev}" of=/dev/null bs="${block_size}" count="${test_blocks}" status=progress 2>&1 | while IFS= read -r line; do
        echo -e "    ${line}"
    done

    echo ""
    print_ok "Speed test complete"
    log "HEALTHCHECK: speed test /dev/${dev}"
}

health_menu() {
    print_header "Category 5: USB Health Check"
    echo ""
    echo -e "  ${DIM}  Diagnose and test USB drive health.${NC}"
    echo ""
    echo -e "    ${GREEN}1)${NC}  Bad blocks test    ${DIM}(read-only scan)${NC}"
    echo -e "    ${CYAN}2)${NC}  SMART data          ${DIM}(if supported)${NC}"
    echo -e "    ${YELLOW}3)${NC}  Filesystem check    ${DIM}(fsck — device must be unmounted)${NC}"
    echo -e "    ${MAGENTA}4)${NC}  Read speed test     ${DIM}(dd-based benchmark)${NC}"
    echo -e "    ${BLUE}0)${NC}  Back"
    echo ""
    read -rp "  Choice [0-4]: " choice

    case "$choice" in
        1) health_badblocks ;;
        2) health_smart ;;
        3) health_fsck ;;
        4) health_speed_test ;;
        0) return ;;
        *) echo -e "  ${RED}Invalid choice${NC}" ;;
    esac
}

# ============================================================================
#  Category 6: USB BACKUP & CLONE
#  Image backup, restore, and USB-to-USB clone
# ============================================================================

backup_to_image() {
    print_header "Backup USB to Image"
    log "ACTION: Backup USB to image"

    local usb_devs
    usb_devs=$(get_usb_devices)

    if ! select_device "$usb_devs" "USB devices"; then
        return
    fi

    local dev="$SELECTED_DEV"
    local size
    size=$(lsblk -dnro SIZE "/dev/${dev}" 2>/dev/null || echo "Unknown")

    echo ""
    echo -e "  ${BOLD}Source:${NC} /dev/${dev} (${size})"
    echo ""

    local default_img="/home/$(get_current_user)/usb-backup-${dev}-$(date +%Y%m%d-%H%M%S).img"
    read -rp "  Output file [${default_img}]: " custom_img
    local img_file="${custom_img:-$default_img}"

    # Check available space
    local img_dir
    img_dir=$(dirname "$img_file")
    if [[ ! -d "$img_dir" ]]; then
        print_fail "Directory ${img_dir} does not exist"
        return
    fi

    echo ""
    echo -e "  ${BOLD}Backup:${NC} /dev/${dev} → ${img_file}"
    echo -e "  ${DIM}  This will create a file approximately ${size} in size.${NC}"

    if ! confirm_action "Start backup?"; then
        return
    fi

    print_info "Backing up /dev/${dev} to ${img_file}..."
    echo ""

    if dd if="/dev/${dev}" of="$img_file" bs=4M status=progress 2>&1; then
        sync
        local img_size
        img_size=$(du -h "$img_file" 2>/dev/null | cut -f1)
        print_ok "Backup complete: ${img_file} (${img_size})"
        # Set ownership to user
        chown "$(get_current_user):$(get_current_user)" "$img_file" 2>/dev/null || true
        log "BACKUP: /dev/${dev} → ${img_file} (${img_size})"
    else
        print_fail "Backup failed"
    fi
    echo ""
}

restore_from_image() {
    print_header "Restore Image to USB"
    log "ACTION: Restore image to USB"

    echo ""
    read -rp "  Path to image file: " img_file

    if [[ -z "$img_file" || ! -f "$img_file" ]]; then
        print_fail "Image file not found: ${img_file}"
        return
    fi

    local img_size
    img_size=$(du -h "$img_file" 2>/dev/null | cut -f1)
    echo -e "  ${BOLD}Image:${NC} ${img_file} (${img_size})"

    local usb_devs
    usb_devs=$(get_usb_devices)

    echo ""
    echo -e "  ${BOLD}Select target USB device:${NC}"

    if ! select_device "$usb_devs" "USB devices"; then
        return
    fi

    local dev="$SELECTED_DEV"

    if is_system_disk "$dev"; then
        print_fail "/dev/${dev} appears to be a system disk!"
        return
    fi

    # Unmount if needed
    for part in $(lsblk -rno NAME "/dev/${dev}" 2>/dev/null | tail -n +2); do
        sync
        umount "/dev/${part}" 2>/dev/null || true
    done

    if ! double_confirm "$dev"; then
        echo -e "  ${YELLOW}Cancelled.${NC}"
        return
    fi

    print_info "Restoring ${img_file} → /dev/${dev}..."
    echo ""

    if dd if="$img_file" of="/dev/${dev}" bs=4M status=progress conv=fdatasync 2>&1; then
        sync
        print_ok "Restore complete: ${img_file} → /dev/${dev}"
        log "RESTORE: ${img_file} → /dev/${dev}"
    else
        print_fail "Restore failed"
    fi
    echo ""
}

clone_usb_to_usb() {
    print_header "Clone USB to USB"
    log "ACTION: Clone USB-to-USB"

    local usb_devs
    usb_devs=$(get_usb_devices)

    local dev_arr=($usb_devs)
    if [[ ${#dev_arr[@]} -lt 2 ]]; then
        print_fail "Need at least 2 USB devices connected for cloning."
        return
    fi

    echo ""
    echo -e "  ${BOLD}Select SOURCE device:${NC}"

    if ! select_device "$usb_devs" "USB devices (source)"; then
        return
    fi
    local source_dev="$SELECTED_DEV"

    echo ""
    echo -e "  ${BOLD}Select TARGET device:${NC}"

    # Remove source from list
    local target_list=""
    for d in $usb_devs; do
        [[ "$d" != "$source_dev" ]] && target_list="${target_list} ${d}"
    done
    target_list=$(echo "$target_list" | xargs)

    if ! select_device "$target_list" "USB devices (target)"; then
        return
    fi
    local target_dev="$SELECTED_DEV"

    if is_system_disk "$target_dev"; then
        print_fail "/dev/${target_dev} appears to be a system disk!"
        return
    fi

    local src_size tgt_size
    src_size=$(lsblk -dnro SIZE "/dev/${source_dev}" 2>/dev/null)
    tgt_size=$(lsblk -dnro SIZE "/dev/${target_dev}" 2>/dev/null)

    echo ""
    echo -e "  ${BOLD}Clone:${NC} /dev/${source_dev} (${src_size}) → /dev/${target_dev} (${tgt_size})"

    # Unmount target
    for part in $(lsblk -rno NAME "/dev/${target_dev}" 2>/dev/null | tail -n +2); do
        sync
        umount "/dev/${part}" 2>/dev/null || true
    done

    if ! double_confirm "$target_dev"; then
        echo -e "  ${YELLOW}Cancelled.${NC}"
        return
    fi

    print_info "Cloning /dev/${source_dev} → /dev/${target_dev}..."
    echo ""

    if dd if="/dev/${source_dev}" of="/dev/${target_dev}" bs=4M status=progress conv=fdatasync 2>&1; then
        sync
        print_ok "Clone complete: /dev/${source_dev} → /dev/${target_dev}"
        log "CLONE: /dev/${source_dev} → /dev/${target_dev}"
    else
        print_fail "Clone failed"
    fi
    echo ""
}

backup_menu() {
    print_header "Category 6: USB Backup & Clone"
    echo ""
    echo -e "  ${DIM}  Create disk images, restore from images, and clone USB drives.${NC}"
    echo ""
    echo -e "    ${GREEN}1)${NC}  Backup USB → image file   ${DIM}(dd)${NC}"
    echo -e "    ${CYAN}2)${NC}  Restore image → USB       ${DIM}(dd)${NC}"
    echo -e "    ${MAGENTA}3)${NC}  Clone USB → USB           ${DIM}(direct copy)${NC}"
    echo -e "    ${BLUE}0)${NC}  Back"
    echo ""
    read -rp "  Choice [0-3]: " choice

    case "$choice" in
        1) backup_to_image ;;
        2) restore_from_image ;;
        3) clone_usb_to_usb ;;
        0) return ;;
        *) echo -e "  ${RED}Invalid choice${NC}" ;;
    esac
}

# ============================================================================
#  Category 7: WRITE ISO (Bootable USB)
#  Write ISO image to USB with verification.
# ============================================================================

write_iso() {
    print_header "Write ISO to USB"
    log "ACTION: Write ISO to USB"

    echo ""
    read -rp "  Path to ISO file: " iso_file

    if [[ -z "$iso_file" || ! -f "$iso_file" ]]; then
        print_fail "ISO file not found: ${iso_file}"
        return
    fi

    local iso_size
    iso_size=$(du -h "$iso_file" 2>/dev/null | cut -f1)
    echo -e "  ${BOLD}ISO:${NC} ${iso_file} (${iso_size})"

    local usb_devs
    usb_devs=$(get_usb_devices)

    echo ""
    echo -e "  ${BOLD}Select target USB device:${NC}"

    if ! select_device "$usb_devs" "USB devices"; then
        return
    fi

    local dev="$SELECTED_DEV"

    if is_system_disk "$dev"; then
        print_fail "/dev/${dev} appears to be a system disk!"
        return
    fi

    local dev_size
    dev_size=$(lsblk -dnro SIZE "/dev/${dev}" 2>/dev/null)

    echo ""
    echo -e "  ${BOLD}Summary:${NC}"
    echo -e "    ISO:    ${iso_file} (${iso_size})"
    echo -e "    Target: /dev/${dev} (${dev_size})"

    # Unmount if needed
    for part in $(lsblk -rno NAME "/dev/${dev}" 2>/dev/null | tail -n +2); do
        sync
        umount "/dev/${part}" 2>/dev/null || true
    done

    if ! double_confirm "$dev"; then
        echo -e "  ${YELLOW}Cancelled.${NC}"
        return
    fi

    print_info "Writing ISO to /dev/${dev}..."
    echo ""

    if dd if="$iso_file" of="/dev/${dev}" bs=4M status=progress conv=fdatasync 2>&1; then
        sync
        print_ok "ISO written to /dev/${dev}"
        log "WRITE ISO: ${iso_file} → /dev/${dev}"
    else
        print_fail "ISO write failed"
        return
    fi

    # Verify
    echo ""
    echo -e "  ${BOLD}Verify write?${NC}"
    echo -e "    ${GREEN}1)${NC}  Yes — compare checksums ${DIM}(recommended)${NC}"
    echo -e "    ${CYAN}2)${NC}  No  — skip verification"
    echo ""
    read -rp "  Choice [1-2]: " verify

    if [[ "$verify" == "1" || -z "$verify" ]]; then
        print_info "Calculating ISO checksum..."
        local iso_md5
        iso_md5=$(md5sum "$iso_file" 2>/dev/null | cut -d' ' -f1)
        echo -e "    ISO:    ${iso_md5}"

        print_info "Calculating USB checksum (reading same size as ISO)..."
        local iso_bytes
        iso_bytes=$(stat -c%s "$iso_file" 2>/dev/null)
        local usb_md5
        usb_md5=$(dd if="/dev/${dev}" bs=4M count=$((iso_bytes / 4194304 + 1)) 2>/dev/null | head -c "$iso_bytes" | md5sum | cut -d' ' -f1)
        echo -e "    USB:    ${usb_md5}"

        echo ""
        if [[ "$iso_md5" == "$usb_md5" ]]; then
            print_ok "Checksums match — write verified!"
        else
            print_fail "Checksums DO NOT match! Write may be corrupted."
        fi
    fi

    echo ""
    echo -e "  ${GREEN}${BOLD}  Bootable USB created.${NC}"
    echo ""
}

iso_menu() {
    print_header "Category 7: Write ISO (Bootable USB)"
    echo ""
    echo -e "  ${DIM}  Write bootable ISO images to USB devices.${NC}"
    echo ""
    echo -e "    ${GREEN}1)${NC}  Write ISO to USB"
    echo -e "    ${BLUE}0)${NC}  Back"
    echo ""
    read -rp "  Choice [0-1]: " choice

    case "$choice" in
        1) write_iso ;;
        0) return ;;
        *) echo -e "  ${RED}Invalid choice${NC}" ;;
    esac
}

# ============================================================================
#  Category 8: SECURE WIPE
#  Quick, full, random, and multi-pass wipe options.
# ============================================================================

wipe_quick() {
    local dev="$1"
    print_info "Quick wipe: zeroing first and last 1MB + partition table..."
    log "WIPE (quick): /dev/${dev}"

    # Zero first 1MB (includes partition table and boot sector)
    dd if=/dev/zero of="/dev/${dev}" bs=1M count=1 status=progress 2>&1
    # Zero last 1MB (backup GPT table)
    local size_bytes
    size_bytes=$(blockdev --getsize64 "/dev/${dev}" 2>/dev/null || echo "0")
    if [[ "$size_bytes" -gt 1048576 ]]; then
        local skip_mb=$(( (size_bytes - 1048576) / 1048576 ))
        dd if=/dev/zero of="/dev/${dev}" bs=1M seek="${skip_mb}" status=progress 2>&1 || true
    fi
    # Wipe signatures
    wipefs -a "/dev/${dev}" &>/dev/null || true
    sync
    print_ok "Quick wipe complete on /dev/${dev}"
}

wipe_full_zero() {
    local dev="$1"
    print_info "Full zero wipe: writing zeros to entire disk..."
    log "WIPE (full zero): /dev/${dev}"

    dd if=/dev/zero of="/dev/${dev}" bs=4M status=progress 2>&1 || true
    sync
    print_ok "Full zero wipe complete on /dev/${dev}"
}

wipe_random() {
    local dev="$1"
    print_info "Random wipe: writing random data to entire disk..."
    log "WIPE (random): /dev/${dev}"

    dd if=/dev/urandom of="/dev/${dev}" bs=4M status=progress 2>&1 || true
    sync
    print_ok "Random wipe complete on /dev/${dev}"
}

wipe_multipass() {
    local dev="$1"
    print_info "Multi-pass wipe (3 passes): random → zeros → random..."
    log "WIPE (multi-pass): /dev/${dev}"

    echo ""
    echo -e "    ${BOLD}Pass 1/3: Random data...${NC}"
    dd if=/dev/urandom of="/dev/${dev}" bs=4M status=progress 2>&1 || true
    sync

    echo ""
    echo -e "    ${BOLD}Pass 2/3: Zero fill...${NC}"
    dd if=/dev/zero of="/dev/${dev}" bs=4M status=progress 2>&1 || true
    sync

    echo ""
    echo -e "    ${BOLD}Pass 3/3: Random data...${NC}"
    dd if=/dev/urandom of="/dev/${dev}" bs=4M status=progress 2>&1 || true
    sync

    print_ok "Multi-pass wipe complete on /dev/${dev} (3 passes)"
}

secure_wipe() {
    print_header "Secure Wipe USB"
    log "ACTION: Secure Wipe"

    local usb_devs
    usb_devs=$(get_usb_devices)

    if ! select_device "$usb_devs" "USB devices"; then
        return
    fi

    local dev="$SELECTED_DEV"

    if is_system_disk "$dev"; then
        print_fail "/dev/${dev} appears to be a system disk!"
        return
    fi

    local size
    size=$(lsblk -dnro SIZE "/dev/${dev}" 2>/dev/null || echo "Unknown")

    echo ""
    echo -e "  ${BOLD}Device:${NC} /dev/${dev} (${size})"

    # Unmount all partitions
    for part in $(lsblk -rno NAME "/dev/${dev}" 2>/dev/null | tail -n +2); do
        sync
        umount "/dev/${part}" 2>/dev/null || true
    done

    echo ""
    echo -e "  ${BOLD}Wipe method:${NC}"
    echo -e "    ${GREEN}1)${NC}  Quick wipe     ${DIM}— zero first/last 1MB + wipe signatures (fast)${NC}"
    echo -e "    ${YELLOW}2)${NC}  Full zero      ${DIM}— write zeros to entire disk${NC}"
    echo -e "    ${RED}3)${NC}  Random wipe    ${DIM}— write random data to entire disk${NC}"
    echo -e "    ${MAGENTA}4)${NC}  Multi-pass     ${DIM}— 3 passes: random → zeros → random (slowest)${NC}"
    echo ""
    read -rp "  Choice [1-4]: " wipe_mode

    case "$wipe_mode" in
        1|2|3|4) ;;
        *)
            echo -e "  ${RED}Invalid choice${NC}"
            return
            ;;
    esac

    if ! double_confirm "$dev"; then
        echo -e "  ${YELLOW}Cancelled.${NC}"
        return
    fi

    echo ""

    case "$wipe_mode" in
        1) wipe_quick "$dev" ;;
        2) wipe_full_zero "$dev" ;;
        3) wipe_random "$dev" ;;
        4) wipe_multipass "$dev" ;;
    esac

    echo ""
    echo -e "  ${GREEN}${BOLD}  Wipe complete on /dev/${dev}.${NC}"
    echo -e "  ${DIM}  The device is now empty. Format it to use again.${NC}"
    echo ""
}

wipe_menu() {
    print_header "Category 8: Secure Wipe"
    echo ""
    echo -e "  ${DIM}  Securely erase USB drives with various wipe methods.${NC}"
    echo ""
    echo -e "    ${GREEN}1)${NC}  Wipe a USB device"
    echo -e "    ${BLUE}0)${NC}  Back"
    echo ""
    read -rp "  Choice [0-1]: " choice

    case "$choice" in
        1) secure_wipe ;;
        0) return ;;
        *) echo -e "  ${RED}Invalid choice${NC}" ;;
    esac
}

# ============================================================================
#  Quick Actions
# ============================================================================

quick_safe_eject() {
    print_header "Safe Eject USB"
    log "ACTION: Safe Eject"

    local usb_devs
    usb_devs=$(get_usb_devices)

    if ! select_device "$usb_devs" "USB devices"; then
        return
    fi

    local dev="$SELECTED_DEV"

    echo ""
    echo -e "  ${BOLD}Ejecting /dev/${dev}...${NC}"

    # Sync
    print_info "Syncing all filesystems..."
    sync

    # Unmount all partitions
    local unmounted=0
    for part in $(lsblk -rno NAME,MOUNTPOINT "/dev/${dev}" 2>/dev/null | awk '$2 != "" {print $1}'); do
        if umount "/dev/${part}" 2>/dev/null; then
            print_ok "Unmounted /dev/${part}"
            unmounted=$((unmounted + 1))
        fi
    done

    if [[ $unmounted -eq 0 ]]; then
        print_info "No mounted partitions to unmount."
    fi

    # Power off USB device
    local sys_dev="/sys/block/${dev}/device"
    if [[ -f "${sys_dev}/delete" ]]; then
        echo 1 > "${sys_dev}/delete" 2>/dev/null
        print_ok "Device powered off"
    elif [[ -f "${sys_dev}/../../remove" ]]; then
        echo 1 > "${sys_dev}/../../remove" 2>/dev/null
        print_ok "USB port deauthorized"
    else
        print_info "Could not power off device — safe to remove after sync."
    fi

    echo ""
    echo -e "  ${GREEN}${BOLD}  Safe to remove /dev/${dev}.${NC}"
    log "EJECT: /dev/${dev}"
    echo ""
}

quick_device_info() {
    print_header "Quick Device Info"

    local usb_devs
    usb_devs=$(get_usb_devices)

    if ! select_device "$usb_devs" "USB devices"; then
        return
    fi

    local dev="$SELECTED_DEV"

    echo ""
    print_section "A" "Device Summary: /dev/${dev}"

    local size model serial vendor_id product_id removable
    size=$(lsblk -dnro SIZE "/dev/${dev}" 2>/dev/null || echo "Unknown")
    model=$(cat "/sys/block/${dev}/device/model" 2>/dev/null | xargs || echo "Unknown")
    serial=$(cat "/sys/block/${dev}/device/../../serial" 2>/dev/null | xargs || echo "N/A")
    vendor_id=$(cat "/sys/block/${dev}/device/../../idVendor" 2>/dev/null || echo "????")
    product_id=$(cat "/sys/block/${dev}/device/../../idProduct" 2>/dev/null || echo "????")
    removable=$(cat "/sys/block/${dev}/removable" 2>/dev/null || echo "?")

    local manufacturer
    manufacturer=$(cat "/sys/block/${dev}/device/../../manufacturer" 2>/dev/null | xargs || echo "Unknown")

    echo ""
    echo -e "    ${BOLD}Model:${NC}        ${model}"
    echo -e "    ${BOLD}Manufacturer:${NC} ${manufacturer}"
    echo -e "    ${BOLD}Size:${NC}         ${size}"
    echo -e "    ${BOLD}VID:PID:${NC}      ${vendor_id}:${product_id}"
    echo -e "    ${BOLD}Serial:${NC}       ${serial}"
    echo -e "    ${BOLD}Removable:${NC}    ${removable}"

    print_section "B" "Partitions"

    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,UUID "/dev/${dev}" 2>/dev/null | while IFS= read -r line; do
        echo -e "    ${DIM}${line}${NC}"
    done

    print_section "C" "Block Device Info"

    echo ""
    local ro sched
    ro=$(cat "/sys/block/${dev}/ro" 2>/dev/null || echo "?")
    sched=$(cat "/sys/block/${dev}/queue/scheduler" 2>/dev/null || echo "?")
    local logical_bs physical_bs
    logical_bs=$(cat "/sys/block/${dev}/queue/logical_block_size" 2>/dev/null || echo "?")
    physical_bs=$(cat "/sys/block/${dev}/queue/physical_block_size" 2>/dev/null || echo "?")

    echo -e "    ${BOLD}Read-only:${NC}       ${ro}"
    echo -e "    ${BOLD}Scheduler:${NC}       ${sched}"
    echo -e "    ${BOLD}Logical BS:${NC}      ${logical_bs}"
    echo -e "    ${BOLD}Physical BS:${NC}     ${physical_bs}"

    echo ""
}

# ============================================================================
#  Main Menu
# ============================================================================

main_menu() {
    while true; do
        clear
        echo ""
        echo -e "${BLUE}${BOLD}"
        echo "  ╔═══════════════════════════════════════════════════════════╗"
        echo "  ║                                                           ║"
        echo "  ║             USB TOOLKIT v${SCRIPT_VERSION}                          ║"
        echo "  ║          Device Operations & Management                   ║"
        echo "  ║                                                           ║"
        echo "  ╚═══════════════════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo -e "  ${DIM}$(date '+%Y-%m-%d %H:%M:%S') | $(hostname) | $(uname -r)${NC}"

        # Quick summary of connected USB devices
        local usb_devs
        usb_devs=$(get_usb_devices)
        local dev_count=0
        for d in $usb_devs; do
            dev_count=$((dev_count + 1))
        done
        echo ""
        echo -e "  ${CYAN}USB storage devices connected: ${BOLD}${dev_count}${NC}"
        if [[ $dev_count -gt 0 ]]; then
            for d in $usb_devs; do
                local sz mdl
                sz=$(lsblk -dnro SIZE "/dev/${d}" 2>/dev/null || echo "?")
                mdl=$(cat "/sys/block/${d}/device/model" 2>/dev/null | xargs || echo "")
                echo -e "    ${DIM}/dev/${d}  ${sz}  ${mdl}${NC}"
            done
        fi

        echo ""
        echo -e "  ${BOLD}Categories:${NC}"
        echo ""
        echo -e "    ${GREEN}1)${NC}  USB Detection    ${DIM}— List connected USB storage devices${NC}"
        echo -e "    ${GREEN}2)${NC}  Mount USB        ${DIM}— Mount USB partitions${NC}"
        echo -e "    ${GREEN}3)${NC}  Unmount USB      ${DIM}— Safe unmount with sync${NC}"
        echo -e "    ${YELLOW}4)${NC}  Format USB       ${DIM}— Format with filesystem choice${NC}"
        echo -e "    ${CYAN}5)${NC}  Health Check     ${DIM}— badblocks, SMART, fsck, speed test${NC}"
        echo -e "    ${CYAN}6)${NC}  Backup & Clone   ${DIM}— Image backup, restore, clone${NC}"
        echo -e "    ${MAGENTA}7)${NC}  Write ISO        ${DIM}— Write bootable ISO to USB${NC}"
        echo -e "    ${RED}8)${NC}  Secure Wipe      ${DIM}— Quick, full, random, multi-pass wipe${NC}"
        echo ""
        echo -e "  ${BOLD}Quick Actions:${NC}"
        echo ""
        echo -e "    ${GREEN}9)${NC}  Safe Eject       ${DIM}— sync + unmount + power off${NC}"
        echo -e "    ${CYAN}10)${NC} Device Info       ${DIM}— Quick summary of a USB device${NC}"
        echo ""
        echo -e "    ${BLUE}0)${NC}  Exit"
        echo ""
        read -rp "  Choice [0-10]: " choice

        case "$choice" in
            1) detect_menu ;;
            2) mount_menu ;;
            3) unmount_menu ;;
            4) format_menu ;;
            5) health_menu ;;
            6) backup_menu ;;
            7) iso_menu ;;
            8) wipe_menu ;;
            9) quick_safe_eject ;;
            10) quick_device_info ;;
            0)
                echo ""
                log "========== USB TOOLKIT EXITED =========="
                exit 0
                ;;
            *)
                echo -e "  ${RED}Invalid choice${NC}"
                ;;
        esac

        echo ""
        read -rp "  Press Enter to return to menu... " _
    done
}

# ============================================================================
#  Launch
# ============================================================================

check_root
check_dependencies
main_menu
