#!/usr/bin/env bash
# ============================================================================
#  USB TOOLKIT
#  USB Device Operations & Management
#  Version:  2.0
#  Date:     2026-02-24
#  Tested:   Ubuntu 24.04 / Zorin OS
#  Usage:    sudo bash usb-toolkit.sh [--help|--version|--list]
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

readonly SCRIPT_VERSION="2.0"
readonly LOG_FILE="/var/log/usb-toolkit.log"
readonly LOCK_FILE="/var/lock/usb-toolkit.lock"

# Cleanup tracking (arrays support multiple resources)
CLEANUP_TMPFILES=()
CLEANUP_MOUNTS=()

# TTY detection — disable colors when piped/redirected
if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly CYAN='\033[0;36m'
    readonly MAGENTA='\033[0;35m'
    readonly BOLD='\033[1m'
    readonly DIM='\033[2m'
    readonly NC='\033[0m'
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly CYAN=''
    readonly MAGENTA=''
    readonly BOLD=''
    readonly DIM=''
    readonly NC=''
fi

# ============================================================================
#  Gum Detection & Theme
# ============================================================================

HAS_GUM=false
if [[ -t 1 ]] && command -v gum &>/dev/null; then
    HAS_GUM=true
fi

# Gum color scheme — matches existing ANSI palette
readonly GUM_GREEN="#22c55e"
readonly GUM_RED="#ef4444"
readonly GUM_YELLOW="#eab308"
readonly GUM_CYAN="#06b6d4"
readonly GUM_BLUE="#3b82f6"
readonly GUM_MAGENTA="#a855f7"
readonly GUM_DIM="#6b7280"

# ============================================================================
#  Signal Trap & Cleanup
# ============================================================================

cleanup() {
    # Remove incomplete temp files
    for tmpf in "${CLEANUP_TMPFILES[@]}"; do
        if [[ -n "$tmpf" && -f "$tmpf" ]]; then
            rm -f "$tmpf" 2>/dev/null
            log "CLEANUP: Removed incomplete file ${tmpf}"
        fi
    done
    # Unmount temp mounts
    for mnt in "${CLEANUP_MOUNTS[@]}"; do
        if [[ -n "$mnt" ]] && findmnt -rn "$mnt" &>/dev/null; then
            sync
            umount "$mnt" 2>/dev/null || true
            rmdir "$mnt" 2>/dev/null || true
            log "CLEANUP: Unmounted ${mnt}"
        fi
    done
    # Release lockfile
    release_lock
    sync 2>/dev/null || true
}

trap cleanup EXIT
trap 'echo ""; echo -e "  ${YELLOW}Interrupted.${NC}"; exit 130' INT TERM

# ============================================================================
#  Lockfile
# ============================================================================

acquire_lock() {
    if mkdir "$LOCK_FILE" 2>/dev/null; then
        # Atomic PID write: write to tmp then rename
        echo $$ > "${LOCK_FILE}/pid.tmp" && mv "${LOCK_FILE}/pid.tmp" "${LOCK_FILE}/pid"
        return 0
    fi
    # Check for stale lock
    local lock_pid
    lock_pid=$(cat "${LOCK_FILE}/pid" 2>/dev/null || echo "")
    if [[ -z "$lock_pid" ]] || ! kill -0 "$lock_pid" 2>/dev/null; then
        # Stale lock — previous process died or PID file missing
        rm -rf "$LOCK_FILE" 2>/dev/null
        if mkdir "$LOCK_FILE" 2>/dev/null; then
            echo $$ > "${LOCK_FILE}/pid.tmp" && mv "${LOCK_FILE}/pid.tmp" "${LOCK_FILE}/pid"
            return 0
        fi
    fi
    echo -e "\n${RED}${BOLD}  ERROR: Another instance is running (PID: ${lock_pid:-unknown}).${NC}"
    echo -e "${RED}  If this is wrong, remove ${LOCK_FILE} and try again.${NC}\n"
    return 1
}

release_lock() {
    if [[ -d "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "${LOCK_FILE}/pid" 2>/dev/null || echo "")
        if [[ "$lock_pid" == "$$" ]]; then
            rm -rf "$LOCK_FILE" 2>/dev/null
        fi
    fi
}

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
    log "INFO: $1"
}

print_warn() {
    echo -e "    ${YELLOW}[WARN]${NC}    $1"
    log "WARN: $1"
}

print_header() {
    if [[ "$HAS_GUM" == true ]]; then
        echo ""
        gum style \
            --border "rounded" \
            --border-foreground "$GUM_BLUE" \
            --foreground "$GUM_BLUE" \
            --bold \
            --padding "0 2" \
            --width 58 \
            "  $1"
    else
        echo ""
        echo -e "${BLUE}${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BLUE}${BOLD}    $1${NC}"
        echo -e "${BLUE}${BOLD}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    fi
}

print_section() {
    if [[ "$HAS_GUM" == true ]]; then
        echo ""
        gum style --foreground "$GUM_CYAN" --bold "  [$1]  $2"
        echo -e "  ${CYAN}  ─────────────────────────────────────────────────${NC}"
    else
        echo ""
        echo -e "  ${CYAN}${BOLD}  [$1]  $2${NC}"
        echo -e "  ${CYAN}  ─────────────────────────────────────────────────${NC}"
    fi
}

# ============================================================================
#  Input Validation
# ============================================================================

validate_volume_label() {
    local label="$1"
    local fs_type="${2:-}"

    if [[ -z "$label" ]]; then
        return 0
    fi

    # Only allow safe characters: alphanumeric, space, underscore, hyphen, dot
    if [[ ! "$label" =~ ^[a-zA-Z0-9\ _\.\-]+$ ]]; then
        print_fail "Invalid volume label: only [a-zA-Z0-9 _.-] allowed"
        return 1
    fi

    # FAT32: max 11 characters
    if [[ "$fs_type" == "fat32" || "$fs_type" == "vfat" ]] && [[ ${#label} -gt 11 ]]; then
        print_fail "FAT32 volume label max 11 characters (got ${#label})"
        return 1
    fi

    return 0
}

validate_mount_options() {
    local opts="$1"

    if [[ -z "$opts" ]]; then
        return 0
    fi

    # Only allow safe characters: alphanumeric, comma, equals, underscore
    if [[ ! "$opts" =~ ^[a-zA-Z0-9,=_]+$ ]]; then
        print_fail "Invalid mount options: only [a-zA-Z0-9,=_] allowed"
        return 1
    fi

    return 0
}

validate_filepath() {
    local path="$1"

    if [[ -z "$path" ]]; then
        return 1
    fi

    # Expand tilde using actual home directory (handles root, LDAP, etc.)
    local tilde="~"
    if [[ "$path" == "${tilde}/"* || "$path" == "${tilde}" ]]; then
        local home_dir
        home_dir=$(get_user_home)
        if [[ "$path" == "${tilde}" ]]; then
            path="$home_dir"
        else
            path="${home_dir}/${path:2}"
        fi
    fi

    # Reject shell metacharacters
    if [[ "$path" =~ [\;\|\&\$\`\(\)\{\}\<\>\\!\#\?\*\[] ]]; then
        print_fail "Invalid path: shell metacharacters not allowed"
        return 1
    fi

    echo "$path"
    return 0
}

# ============================================================================
#  Operation Timer
# ============================================================================

TIMER_START=0

timer_start() {
    TIMER_START=$(date +%s)
}

timer_stop() {
    local label="${1:-Operation}"
    local end
    end=$(date +%s)
    local elapsed=$((end - TIMER_START))
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))
    if [[ $mins -gt 0 ]]; then
        print_info "${label} completed in ${mins}m ${secs}s"
    else
        print_info "${label} completed in ${secs}s"
    fi
}

# ============================================================================
#  Sysfs Helper
# ============================================================================

read_sysfs() {
    local path="$1"
    local default="${2:-}"
    local value
    if [[ -f "$path" ]]; then
        value=$(< "$path" 2>/dev/null) || true
        # Trim whitespace
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ -n "$value" ]]; then
            echo "$value"
            return 0
        fi
    fi
    echo "$default"
    return 1
}

# ============================================================================
#  dd with progress (pv integration)
# ============================================================================

dd_with_progress() {
    local input="$1"
    local output="$2"
    local bs="${3:-4M}"
    local extra_args=("${@:4}")

    if command -v pv &>/dev/null; then
        local size=""
        if [[ -b "$input" ]]; then
            size=$(blockdev --getsize64 "$input" 2>/dev/null || echo "")
        elif [[ -f "$input" ]]; then
            size=$(stat -c%s "$input" 2>/dev/null || echo "")
        fi
        local pv_args=()
        [[ -n "$size" ]] && pv_args+=("-s" "$size")
        dd if="$input" bs="$bs" 2>/dev/null | pv "${pv_args[@]}" | dd of="$output" bs="$bs" "${extra_args[@]}" 2>/dev/null
        # Check all pipeline stages — any failure = overall failure
        local pipe_statuses=("${PIPESTATUS[@]}")
        for s in "${pipe_statuses[@]}"; do
            [[ "$s" -ne 0 ]] && return 1
        done
        return 0
    else
        dd if="$input" of="$output" bs="$bs" status=progress "${extra_args[@]}" 2>&1
        return $?
    fi
}

# ============================================================================
#  UI Helpers
# ============================================================================

confirm_action() {
    local msg="$1"
    if [[ "$HAS_GUM" == true ]]; then
        gum confirm \
            --prompt.foreground "$GUM_YELLOW" \
            --selected.background "$GUM_GREEN" \
            --unselected.background "$GUM_DIM" \
            --default=false \
            "$msg"
    else
        echo ""
        read -rp "  ${msg} [y/N]: " answer
        [[ "$answer" =~ ^[Yy]$ ]]
    fi
}

double_confirm() {
    local device="$1"
    local dev_display="/dev/${device}"
    local model size
    model=$(read_sysfs "/sys/block/${device}/device/model" || echo "")
    size=$(lsblk -dnro SIZE "/dev/${device}" 2>/dev/null || echo "?")

    if [[ "$HAS_GUM" == true ]]; then
        echo ""
        gum style \
            --border "double" \
            --border-foreground "$GUM_RED" \
            --foreground "$GUM_RED" \
            --bold \
            --padding "0 2" \
            --align "center" \
            "*** DESTRUCTIVE OPERATION ***" \
            "" \
            "ALL DATA ON ${dev_display} WILL BE DESTROYED!"
        [[ -n "$model" ]] && echo -e "  ${RED}  Device: ${model} (${size})${NC}"
        echo ""
        local typed
        typed=$(gum input \
            --prompt "  Type '${device}' to confirm: " \
            --prompt.foreground "$GUM_YELLOW" \
            --placeholder "${device}" \
            --width 40)
        if [[ "$typed" != "$device" ]]; then
            echo -e "  ${RED}  Input '${typed}' does not match '${device}' — cancelled.${NC}"
            return 1
        fi
    else
        local inner_text="ALL DATA ON ${dev_display} WILL BE DESTROYED!"
        local title="*** DESTRUCTIVE OPERATION ***"
        local text_len=${#inner_text}
        local title_len=${#title}
        local min_content=$(( text_len > title_len ? text_len : title_len ))
        local box_width=$(( min_content + 8 ))
        [[ $box_width -lt 52 ]] && box_width=52
        local pad_total=$((box_width - text_len - 2))
        local pad_left=$((pad_total / 2))
        local pad_right=$((pad_total - pad_left))
        local border_inner=""
        local title_pad_total=$((box_width - title_len - 2))
        local title_pad_left=$((title_pad_total / 2))
        local title_pad_right=$((title_pad_total - title_pad_left))

        printf -v border_inner '%*s' "$((box_width - 2))" ''
        border_inner="${border_inner// /═}"

        echo ""
        echo -e "  ${RED}${BOLD}  ╔${border_inner}╗${NC}"
        printf "  %b  ║%*s%s%*s║%b\n" "${RED}${BOLD}" "$title_pad_left" "" "$title" "$title_pad_right" "" "${NC}"
        printf "  %b  ║%*s%s%*s║%b\n" "${RED}${BOLD}" "$pad_left" "" "$inner_text" "$pad_right" "" "${NC}"
        echo -e "  ${RED}${BOLD}  ╚${border_inner}╝${NC}"
        [[ -n "$model" ]] && echo -e "  ${RED}  Device: ${model} (${size})${NC}"
        echo ""
        echo -e "  ${YELLOW}  Type '${BOLD}${device}${NC}${YELLOW}' to confirm:${NC}"
        read -rp "  > " typed
        if [[ "$typed" != "$device" ]]; then
            echo -e "  ${RED}  Input '${typed}' does not match '${device}' — cancelled.${NC}"
            return 1
        fi
    fi
    return 0
}

get_current_user() {
    logname 2>/dev/null || echo "${SUDO_USER:-$(whoami)}"
}

# Get actual home directory for a user (handles root=/root, LDAP, etc.)
get_user_home() {
    local user
    user=$(get_current_user)
    getent passwd "$user" 2>/dev/null | cut -d: -f6 || echo "${HOME:-/root}"
}

# ============================================================================
#  Gum UI Helpers (with fallback when gum is not installed)
# ============================================================================

# ui_choose: Interactive menu selection
# Args: $1 = header, remaining = options
# Returns: selected option text on stdout
ui_choose() {
    local header="$1"
    shift
    local -a options=("$@")

    if [[ "$HAS_GUM" == true ]]; then
        gum choose \
            --header "$header" \
            --header.foreground "$GUM_CYAN" \
            --cursor.foreground "$GUM_GREEN" \
            --selected.foreground "$GUM_GREEN" \
            --height 15 \
            "${options[@]}"
    else
        echo ""
        echo -e "  ${BOLD}${header}${NC}"
        echo ""
        local i=1
        for opt in "${options[@]}"; do
            printf "    %b%2d)%b  %s\n" "${GREEN}" "$i" "${NC}" "$opt"
            i=$((i + 1))
        done
        echo ""
        read -rp "  Choice [1-${#options[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#options[@]} ]]; then
            echo "${options[$((choice - 1))]}"
        fi
    fi
}

# ui_input: Single-line text input
# Args: $1 = prompt, $2 = default value (optional)
# Returns: user input on stdout
ui_input() {
    local prompt="$1"
    local default="${2:-}"

    if [[ "$HAS_GUM" == true ]]; then
        local -a args=(
            --prompt "  ${prompt}: "
            --prompt.foreground "$GUM_CYAN"
            --width 60
        )
        [[ -n "$default" ]] && args+=(--value "$default")
        gum input "${args[@]}"
    else
        local display_prompt="  ${prompt}"
        [[ -n "$default" ]] && display_prompt+=" [${default}]"
        display_prompt+=": "
        local value
        read -rp "$display_prompt" value
        echo "${value:-$default}"
    fi
}

# ui_file_input: File path input with optional gum file picker
# Args: $1 = prompt, $2 = starting directory (optional)
# Returns: selected file path on stdout
ui_file_input() {
    local prompt="$1"
    local start_dir="${2:-$(get_user_home)}"

    if [[ "$HAS_GUM" == true ]]; then
        local method
        method=$(gum choose \
            --header "$prompt" \
            --header.foreground "$GUM_CYAN" \
            --cursor.foreground "$GUM_GREEN" \
            "Browse files" \
            "Type path manually")
        case "$method" in
            "Browse files")
                gum file "$start_dir"
                ;;
            *)
                gum input \
                    --prompt "  Path: " \
                    --prompt.foreground "$GUM_CYAN" \
                    --placeholder "/path/to/file" \
                    --width 80
                ;;
        esac
    else
        local value
        read -rep "  ${prompt}: " value
        echo "$value"
    fi
}

# ui_pause: Wait for user to press Enter
ui_pause() {
    if [[ "$HAS_GUM" == true ]]; then
        echo ""
        gum input --prompt "  Press Enter to return to menu... " \
            --prompt.foreground "$GUM_DIM" \
            --placeholder "" \
            --width 50 > /dev/null 2>&1
    else
        echo ""
        read -rp "  Press Enter to return to menu... " _
    fi
}

# ============================================================================
#  Root & Dependency Checks
# ============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "\n${RED}${BOLD}  ERROR: This script requires root privileges!${NC}"
        echo -e "${RED}  Run: sudo bash $0${NC}\n"
        exit 1
    fi
    if touch "$LOG_FILE" 2>/dev/null; then
        chmod 600 "$LOG_FILE" 2>/dev/null
    else
        echo -e "  ${DIM}  Note: Cannot write to ${LOG_FILE} — logging disabled${NC}"
    fi
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
    local optional=("gum" "pv" "smartctl" "badblocks" "ntfs-3g" "mkfs.exfat" "mkfs.btrfs" "mkfs.f2fs" "mkfs.xfs" "zstd")
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

# Get USB bus speed for a device
get_usb_speed() {
    local dev="$1"
    local speed_file=""

    # Walk sysfs to find the USB speed attribute
    local device_path
    device_path=$(readlink -f "/sys/block/${dev}/device" 2>/dev/null || echo "")
    if [[ -z "$device_path" ]]; then
        echo "Unknown"
        return
    fi

    # Walk up the device tree to find the USB device with speed attribute
    local path="$device_path"
    while [[ "$path" != "/" ]]; do
        if [[ -f "${path}/speed" ]]; then
            speed_file="${path}/speed"
            break
        fi
        path=$(dirname "$path")
    done

    if [[ -z "$speed_file" ]]; then
        echo "Unknown"
        return
    fi

    local speed
    speed=$(read_sysfs "$speed_file" "0")

    case "$speed" in
        1.5)   echo "USB 1.0 (1.5 Mbps)" ;;
        12)    echo "USB 1.1 (12 Mbps)" ;;
        480)   echo "USB 2.0 (480 Mbps)" ;;
        5000)  echo "USB 3.0 (5 Gbps)" ;;
        10000) echo "USB 3.1 (10 Gbps)" ;;
        20000) echo "USB 3.2 (20 Gbps)" ;;
        *)     echo "USB (${speed} Mbps)" ;;
    esac
}

# Get list of USB block devices (whole disks only, e.g. sdb, sdc, nvme0n1)
get_usb_devices() {
    local devices=()

    # Traditional sd* devices
    for block in /sys/block/sd*; do
        [[ ! -d "$block" ]] && continue
        local dev_name
        dev_name=$(basename "$block")
        local removable
        removable=$(read_sysfs "${block}/removable" "0")
        if [[ "$removable" == "1" ]] || readlink -f "${block}/device" 2>/dev/null | grep -q "usb"; then
            devices+=("$dev_name")
        fi
    done

    # NVMe USB enclosures
    for block in /sys/block/nvme*; do
        [[ ! -d "$block" ]] && continue
        local dev_name
        dev_name=$(basename "$block")
        # Check if this NVMe is on USB bus
        if readlink -f "${block}/device" 2>/dev/null | grep -q "usb"; then
            devices+=("$dev_name")
        fi
    done

    echo "${devices[@]}"
}

# Get partition name for a device (handles NVMe p1 vs sd 1 naming)
get_partition_pattern() {
    local dev="$1"
    if [[ "$dev" == nvme* ]]; then
        echo "${dev}p"
    else
        echo "${dev}"
    fi
}

# Get USB partitions (e.g. sdb1, sdc1, nvme0n1p1)
get_usb_partitions() {
    local partitions=()
    local usb_devs
    usb_devs=$(get_usb_devices)
    for dev in $usb_devs; do
        local has_parts=0
        local part_prefix
        part_prefix=$(get_partition_pattern "$dev")
        for part in /sys/block/"${dev}"/"${part_prefix}"[0-9]*; do
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

# Interactive device selection — returns selected device via nameref
# Args: $1 = device list (space-separated), $2 = prompt label, $3 = nameref variable name
select_device() {
    local -a dev_list
    read -ra dev_list <<< "$1"
    local label="$2"
    local -n _result_var="$3"

    _result_var=""

    if [[ ${#dev_list[@]} -eq 0 ]]; then
        print_info "No ${label} found."
        return 1
    fi

    # Build display labels for each device
    local -a display_labels=()
    for dev in "${dev_list[@]}"; do
        local size model fstype label_name entry
        size=$(lsblk -dnro SIZE "/dev/${dev}" 2>/dev/null || echo "?")
        model=$(lsblk -dnro MODEL "/dev/${dev}" 2>/dev/null || echo "")
        fstype=$(blkid -o value -s TYPE "/dev/${dev}" 2>/dev/null || echo "")
        label_name=$(blkid -o value -s LABEL "/dev/${dev}" 2>/dev/null || echo "")

        entry="/dev/${dev}  ${size}"
        [[ -n "$fstype" ]] && entry+="  [${fstype}]"
        [[ -n "$label_name" ]] && entry+="  ${label_name}"
        [[ -n "$model" ]] && entry+="  ${model}"
        display_labels+=("$entry")
    done

    local selected=""
    if [[ "$HAS_GUM" == true ]]; then
        display_labels+=("Cancel")
        selected=$(gum choose \
            --header "Select ${label}:" \
            --header.foreground "$GUM_CYAN" \
            --cursor.foreground "$GUM_GREEN" \
            --selected.foreground "$GUM_GREEN" \
            --height 15 \
            "${display_labels[@]}")

        [[ -z "$selected" || "$selected" == "Cancel" ]] && return 1
    else
        echo ""
        echo -e "  ${BOLD}Available ${label}:${NC}"
        echo ""
        local i=1
        for entry in "${display_labels[@]}"; do
            printf "    %b%2d)%b  %s\n" "${GREEN}" "$i" "${NC}" "$entry"
            i=$((i + 1))
        done
        echo ""
        read -rp "  Select device [1-${#dev_list[@]}] (0 to cancel): " choice

        [[ "$choice" == "0" || -z "$choice" ]] && return 1

        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#dev_list[@]} ]]; then
            selected="${display_labels[$((choice - 1))]}"
        else
            echo -e "  ${RED}Invalid selection${NC}"
            return 1
        fi
    fi

    # Extract device name from display label ("/dev/sdb  ..." -> "sdb")
    local chosen_dev
    chosen_dev=$(echo "$selected" | awk '{print $1}' | sed 's|/dev/||')

    # Verify device still exists
    if [[ ! -b "/dev/${chosen_dev}" ]]; then
        echo -e "  ${RED}/dev/${chosen_dev} no longer exists — device may have been removed${NC}"
        return 1
    fi

    _result_var="$chosen_dev"
    return 0
}

# Unmount all partitions of a device. Returns 1 if any unmount fails.
# Also prevents TOCTOU race with desktop automount (GNOME/KDE).
unmount_all_partitions() {
    local dev="$1"
    local force="${2:-false}"
    local failed=0

    # Inhibit udev-triggered automounting during unmount operations
    if command -v udevadm &>/dev/null; then
        udevadm control --stop-exec-queue 2>/dev/null || true
    fi

    for part in $(lsblk -rno NAME "/dev/${dev}" 2>/dev/null | tail -n +2); do
        if findmnt -rn "/dev/${part}" &>/dev/null; then
            sync
            if ! umount "/dev/${part}" 2>/dev/null; then
                if [[ "$force" == "true" ]]; then
                    umount -l "/dev/${part}" 2>/dev/null || true
                    print_warn "Lazy unmounted /dev/${part}"
                else
                    print_fail "Could not unmount /dev/${part} — device busy"
                    failed=1
                fi
            else
                print_ok "Unmounted /dev/${part}"
            fi
        fi
    done

    # Re-enable udev exec queue
    if command -v udevadm &>/dev/null; then
        udevadm control --start-exec-queue 2>/dev/null || true
    fi

    # Verify nothing got re-mounted (TOCTOU check)
    if [[ $failed -eq 0 ]]; then
        for part in $(lsblk -rno NAME "/dev/${dev}" 2>/dev/null | tail -n +2); do
            if findmnt -rn "/dev/${part}" &>/dev/null; then
                print_fail "/dev/${part} was re-mounted by system (automount race)"
                failed=1
            fi
        done
    fi

    return $failed
}

# Check device is not a system disk.
# Handles LVM, dm-crypt, btrfs subvolumes, and standard partitions.
is_system_disk() {
    local dev="$1"

    # Method 1: Use lsblk PKNAME to walk parent chain from root device
    local root_source
    root_source=$(findmnt -rno SOURCE / 2>/dev/null)
    if [[ -n "$root_source" ]]; then
        # For LVM/dm-crypt: resolve to physical device via lsblk slaves
        local root_base
        root_base=$(lsblk -ndo PKNAME "$root_source" 2>/dev/null)
        # Walk up if PKNAME itself has a parent (e.g. dm → partition → disk)
        while [[ -n "$root_base" ]]; do
            local parent
            parent=$(lsblk -ndo PKNAME "/dev/${root_base}" 2>/dev/null)
            if [[ -n "$parent" && "$parent" != "$root_base" ]]; then
                root_base="$parent"
            else
                break
            fi
        done
        # If we couldn't resolve, fall back to sed method
        if [[ -z "$root_base" ]]; then
            root_base=$(echo "$root_source" | sed -e 's|/dev/||' -e 's/p[0-9]*$//' -e 's/[0-9]*$//')
        fi
        if [[ "$dev" == "$root_base" ]]; then
            return 0  # IS system disk
        fi
    fi

    # Method 2: Check if any partition on this device holds a critical mount
    local critical_mounts=("/" "/boot" "/boot/efi" "/home" "/var")
    for mnt in "${critical_mounts[@]}"; do
        local mnt_source
        mnt_source=$(findmnt -rno SOURCE "$mnt" 2>/dev/null)
        [[ -z "$mnt_source" ]] && continue
        if echo "$mnt_source" | grep -q "/dev/${dev}"; then
            return 0  # IS system disk
        fi
    done

    return 1  # NOT system disk
}

# ============================================================================
#  Device Details (shared between detect and device_info)
# ============================================================================

# Walk up sysfs tree to find a USB attribute (handles UAS, NVMe-over-USB, etc.)
find_usb_attr() {
    local dev="$1"
    local attr="$2"
    local default="${3:-}"
    local path
    path=$(readlink -f "/sys/block/${dev}/device" 2>/dev/null || echo "")
    while [[ -n "$path" && "$path" != "/" ]]; do
        if [[ -f "${path}/${attr}" ]]; then
            read_sysfs "${path}/${attr}" "$default"
            return 0
        fi
        path=$(dirname "$path")
    done
    echo "$default"
    return 1
}

print_device_details() {
    local dev="$1"

    local size model serial vendor_id product_id removable manufacturer usb_speed
    size=$(lsblk -dnro SIZE "/dev/${dev}" 2>/dev/null || echo "Unknown")
    model=$(read_sysfs "/sys/block/${dev}/device/model" "Unknown")
    serial=$(find_usb_attr "$dev" "serial" "N/A")
    vendor_id=$(find_usb_attr "$dev" "idVendor" "????")
    product_id=$(find_usb_attr "$dev" "idProduct" "????")
    removable=$(read_sysfs "/sys/block/${dev}/removable" "?")
    manufacturer=$(find_usb_attr "$dev" "manufacturer" "Unknown")
    usb_speed=$(get_usb_speed "$dev")

    echo -e "    ${BOLD}${GREEN}/dev/${dev}${NC}  —  ${BOLD}${size}${NC}  ${DIM}[${vendor_id}:${product_id}]${NC}"
    echo -e "      ${DIM}Model:        ${model}${NC}"
    echo -e "      ${DIM}Manufacturer: ${manufacturer}${NC}"
    echo -e "      ${DIM}Serial:       ${serial}${NC}"
    echo -e "      ${DIM}Removable:    ${removable}${NC}"
    echo -e "      ${DIM}USB Speed:    ${usb_speed}${NC}"
}

print_device_partitions() {
    local dev="$1"
    local part_prefix
    part_prefix=$(get_partition_pattern "$dev")

    local has_parts=0
    for part in /sys/block/"${dev}"/"${part_prefix}"[0-9]*; do
        [[ ! -d "$part" ]] && continue
        has_parts=1
        local part_name
        part_name=$(basename "$part")
        local psize fstype plabel mountpoint
        psize=$(lsblk -dnro SIZE "/dev/${part_name}" 2>/dev/null || echo "?")
        fstype=$(blkid -o value -s TYPE "/dev/${part_name}" 2>/dev/null || echo "unknown")
        plabel=$(blkid -o value -s LABEL "/dev/${part_name}" 2>/dev/null || echo "")
        mountpoint=$(findmnt -rno TARGET "/dev/${part_name}" 2>/dev/null || echo "not mounted")

        printf "      %b├─ %-8s%b  %6s  [%s]" "${CYAN}" "$part_name" "${NC}" "$psize" "$fstype"
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
        print_device_details "$dev"
        print_device_partitions "$dev"
    done
    echo ""
}

detect_menu() {
    print_header "Category 1: USB Device Detection"
    echo -e "  ${DIM}  Detect and display information about connected USB storage devices.${NC}"

    local choice
    choice=$(ui_choose "Select:" \
        "List all USB storage devices" \
        "Back")

    case "$choice" in
        *"List"*) detect_list_devices ;;
        *) return ;;
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

    local dev=""
    if ! select_device "$unmounted" "unmounted USB partitions" dev; then
        return
    fi

    local fstype
    fstype=$(blkid -o value -s TYPE "/dev/${dev}" 2>/dev/null || echo "")
    local dev_label
    dev_label=$(blkid -o value -s LABEL "/dev/${dev}" 2>/dev/null || echo "")
    [[ -z "$dev_label" ]] && dev_label="$dev"

    echo ""
    echo -e "  ${BOLD}Device:${NC} /dev/${dev}"
    [[ -n "$fstype" ]] && echo -e "  ${BOLD}Filesystem:${NC} ${fstype}"
    echo -e "  ${BOLD}Label:${NC} ${dev_label}"

    # Mount options
    local mode
    mode=$(ui_choose "Mount mode:" \
        "Read-Write (default)" \
        "Read-Only" \
        "Read-Write + noexec + sync" \
        "Custom options")

    local -a mount_args=()
    case "$mode" in
        *"Read-Write (default)"*|"") ;;
        *"Read-Only"*) mount_args+=("-o" "ro") ;;
        *"noexec"*) mount_args+=("-o" "noexec,sync") ;;
        *"Custom"*)
            local custom_opts
            custom_opts=$(ui_input "Mount options (e.g. ro,noexec,sync)")
            if ! validate_mount_options "$custom_opts"; then
                return
            fi
            mount_args+=("-o" "${custom_opts}")
            ;;
        *) return ;;
    esac

    # Mount point
    local user
    user=$(get_current_user)
    local default_mount="/media/${user}/${dev_label}"
    echo ""
    local custom_mount
    custom_mount=$(ui_input "Mount point" "$default_mount")
    local mount_point="${custom_mount:-$default_mount}"

    # Validate mount point — reject shell metacharacters
    if [[ -n "$custom_mount" ]]; then
        if [[ "$custom_mount" =~ [';|&$`(){}< >\\!#?*\['] ]]; then
            print_fail "Mount point contains invalid characters"
            return
        fi
        # Expand tilde
        local user_home
        user_home=$(get_user_home)
        mount_point="${mount_point/#\~/${user_home}}"
    fi

    # Create mount point
    mkdir -p "$mount_point"

    # Determine filesystem options
    if [[ "$fstype" == "vfat" || "$fstype" == "exfat" ]]; then
        local uid gid
        uid=$(id -u "$user" 2>/dev/null || echo "1000")
        gid=$(id -g "$user" 2>/dev/null || echo "1000")
        if [[ ${#mount_args[@]} -gt 0 ]]; then
            # Append to existing -o value
            mount_args[-1]="${mount_args[-1]},uid=${uid},gid=${gid}"
        else
            mount_args+=("-o" "uid=${uid},gid=${gid}")
        fi
    fi

    # Add filesystem type if known
    [[ -n "$fstype" ]] && mount_args+=("-t" "$fstype")

    # Mount — array-based, no eval
    if mount "${mount_args[@]}" "/dev/${dev}" "$mount_point" 2>/dev/null; then
        print_ok "Mounted /dev/${dev} → ${mount_point}"
        log "MOUNT: /dev/${dev} → ${mount_point} [opts: ${mount_args[*]}]"
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
    echo -e "  ${DIM}  Mount USB partitions with various options.${NC}"

    local choice
    choice=$(ui_choose "Select:" \
        "Mount a USB device" \
        "Back")

    case "$choice" in
        *"Mount"*) mount_usb ;;
        *) return ;;
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

    local dev=""
    if ! select_device "$mounted" "mounted USB partitions" dev; then
        return
    fi

    local mount_point
    mount_point=$(findmnt -rno TARGET "/dev/${dev}" 2>/dev/null)

    echo ""
    echo -e "  ${BOLD}Device:${NC}     /dev/${dev}"
    echo -e "  ${BOLD}Mounted at:${NC} ${mount_point}"

    local mode
    mode=$(ui_choose "Unmount mode:" \
        "Safe unmount    — sync then umount" \
        "Force unmount   — umount -f (busy devices)" \
        "Lazy unmount    — umount -l (detach now)" \
        "Show processes using this device")

    case "$mode" in
        *"Safe unmount"*)
            print_info "Syncing filesystem..."
            sync
            if [[ -n "$mount_point" ]] && umount "$mount_point" 2>/dev/null; then
                print_ok "Unmounted /dev/${dev} from ${mount_point}"
                log "UNMOUNT: /dev/${dev} from ${mount_point}"
                rmdir "$mount_point" 2>/dev/null || true
            elif umount "/dev/${dev}" 2>/dev/null; then
                print_ok "Unmounted /dev/${dev}"
                log "UNMOUNT: /dev/${dev}"
            else
                print_fail "Could not unmount /dev/${dev} — device may be busy"
                unmount_show_processes "$dev" "$mount_point"
            fi
            ;;
        *"Force unmount"*)
            print_warn "Force unmounting /dev/${dev}..."
            sync
            if [[ -n "$mount_point" ]] && umount -f "$mount_point" 2>/dev/null; then
                print_ok "Force unmounted /dev/${dev} from ${mount_point}"
                log "UNMOUNT (force): /dev/${dev} from ${mount_point}"
                rmdir "$mount_point" 2>/dev/null || true
            elif umount -f "/dev/${dev}" 2>/dev/null; then
                print_ok "Force unmounted /dev/${dev}"
                log "UNMOUNT (force): /dev/${dev}"
            else
                print_fail "Force unmount failed"
                print_info "Try lazy unmount"
            fi
            ;;
        *"Lazy unmount"*)
            print_warn "Lazy unmounting /dev/${dev}..."
            sync
            if [[ -n "$mount_point" ]] && umount -l "$mount_point" 2>/dev/null; then
                print_ok "Lazy unmounted /dev/${dev} from ${mount_point}"
                log "UNMOUNT (lazy): /dev/${dev} from ${mount_point}"
                rmdir "$mount_point" 2>/dev/null || true
            elif umount -l "/dev/${dev}" 2>/dev/null; then
                print_ok "Lazy unmounted /dev/${dev}"
                log "UNMOUNT (lazy): /dev/${dev}"
            else
                print_fail "Lazy unmount failed"
            fi
            ;;
        *"Show processes"*)
            unmount_show_processes "$dev" "$mount_point"
            ;;
        *) ;;
    esac
    echo ""
}

unmount_menu() {
    print_header "Category 3: Unmount USB"
    echo -e "  ${DIM}  Safely unmount USB devices with sync and process check.${NC}"

    local choice
    choice=$(ui_choose "Select:" \
        "Unmount a USB device" \
        "Back")

    case "$choice" in
        *"Unmount"*) unmount_usb ;;
        *) return ;;
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

    local dev=""
    if ! select_device "$usb_devs" "USB devices" dev; then
        return
    fi

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
        if ! unmount_all_partitions "$dev"; then
            print_fail "Could not unmount all partitions — aborting"
            return
        fi
    fi

    # Partition table
    local pt_choice
    pt_choice=$(ui_choose "Partition table:" \
        "MBR (dos) — compatible with most devices" \
        "GPT       — modern, supports >2TB")

    local pt_type="msdos"
    case "$pt_choice" in
        *"MBR"*|"") pt_type="msdos" ;;
        *"GPT"*) pt_type="gpt" ;;
    esac

    # Filesystem
    local fs_choice
    fs_choice=$(ui_choose "Filesystem:" \
        "FAT32   — universal compatibility (max 4GB file)" \
        "exFAT   — large file support, cross-platform" \
        "NTFS    — Windows compatible, large files" \
        "ext4    — Linux native, journaled" \
        "Btrfs   — Linux, COW, snapshots" \
        "F2FS    — Flash-Friendly FS (USB/SD optimized)" \
        "XFS     — High-performance journaling")

    local fs_type=""
    local -a mkfs_args=()
    case "$fs_choice" in
        *"FAT32"*|"")
            fs_type="fat32"
            mkfs_args=("mkfs.vfat" "-F" "32")
            ;;
        *"exFAT"*)
            if ! command -v mkfs.exfat &>/dev/null; then
                print_fail "mkfs.exfat not found. Install: sudo apt install exfat-utils"
                return
            fi
            fs_type="exfat"
            mkfs_args=("mkfs.exfat")
            ;;
        *"NTFS"*)
            if ! command -v mkfs.ntfs &>/dev/null; then
                print_fail "mkfs.ntfs not found. Install: sudo apt install ntfs-3g"
                return
            fi
            fs_type="ntfs"
            mkfs_args=("mkfs.ntfs" "-f")
            ;;
        *"ext4"*)
            fs_type="ext4"
            mkfs_args=("mkfs.ext4" "-F")
            ;;
        *"Btrfs"*)
            if ! command -v mkfs.btrfs &>/dev/null; then
                print_fail "mkfs.btrfs not found. Install: sudo apt install btrfs-progs"
                return
            fi
            fs_type="btrfs"
            mkfs_args=("mkfs.btrfs" "-f")
            ;;
        *"F2FS"*)
            if ! command -v mkfs.f2fs &>/dev/null; then
                print_fail "mkfs.f2fs not found. Install: sudo apt install f2fs-tools"
                return
            fi
            fs_type="f2fs"
            mkfs_args=("mkfs.f2fs" "-f")
            ;;
        *"XFS"*)
            if ! command -v mkfs.xfs &>/dev/null; then
                print_fail "mkfs.xfs not found. Install: sudo apt install xfsprogs"
                return
            fi
            fs_type="xfs"
            mkfs_args=("mkfs.xfs" "-f")
            ;;
        *)
            echo -e "  ${RED}Invalid choice${NC}"
            return
            ;;
    esac

    # Volume label
    local vol_label
    vol_label=$(ui_input "Volume label (leave empty for none)")

    if [[ -n "$vol_label" ]]; then
        if ! validate_volume_label "$vol_label" "$fs_type"; then
            return
        fi
    fi

    # Format type
    local fmt_choice
    fmt_choice=$(ui_choose "Format mode:" \
        "Quick format (default — fast)" \
        "Full format (zero disk first — slow but thorough)")
    local fmt_mode=""
    [[ "$fmt_choice" == *"Full"* ]] && fmt_mode="full"

    # Final confirmation
    echo ""
    echo -e "  ${BOLD}Summary:${NC}"
    echo -e "    Device:     /dev/${dev} (${size})"
    echo -e "    Partition:  ${pt_type}"
    echo -e "    Filesystem: ${fs_type}"
    [[ -n "$vol_label" ]] && echo -e "    Label:      ${vol_label}"
    echo -e "    Mode:       $([ "${fmt_mode}" == "full" ] && echo "Full (zero first)" || echo "Quick")"

    if ! double_confirm "$dev"; then
        echo -e "  ${YELLOW}Cancelled.${NC}"
        return
    fi

    log "FORMAT: /dev/${dev} pt=${pt_type} fs=${fs_type} label=${vol_label}"
    timer_start

    # Full format — zero disk first
    if [[ "$fmt_mode" == "full" ]]; then
        print_info "Zeroing disk (this may take a while)..."
        dd_with_progress "/dev/zero" "/dev/${dev}" "4M" || true
        sync
        print_ok "Disk zeroed"
    fi

    # Wipe old filesystem signatures
    print_info "Wiping old signatures..."
    wipefs -a "/dev/${dev}" &>/dev/null || true

    # Create partition table
    print_info "Creating ${pt_type} partition table..."
    local parted_err
    if ! parted_err=$(parted -s "/dev/${dev}" mklabel "$pt_type" 2>&1); then
        print_fail "Failed to create partition table"
        [[ -n "$parted_err" ]] && print_fail "$parted_err"
        return
    fi
    print_ok "Partition table created: ${pt_type}"

    # Filesystem type hint for parted (sets correct partition type ID)
    local parted_fs=""
    case "$fs_type" in
        fat32) parted_fs="fat32" ;;
        ntfs)  parted_fs="ntfs" ;;
        ext4)  parted_fs="ext4" ;;
        btrfs) parted_fs="btrfs" ;;
        xfs)   parted_fs="xfs" ;;
    esac

    # Create partition
    print_info "Creating partition..."
    if [[ -n "$parted_fs" ]]; then
        if ! parted_err=$(parted -s "/dev/${dev}" mkpart primary "$parted_fs" 1MiB 100% 2>&1); then
            print_fail "Failed to create partition"
            [[ -n "$parted_err" ]] && print_fail "$parted_err"
            return
        fi
    else
        if ! parted_err=$(parted -s "/dev/${dev}" mkpart primary 1MiB 100% 2>&1); then
            print_fail "Failed to create partition"
            [[ -n "$parted_err" ]] && print_fail "$parted_err"
            return
        fi
    fi
    print_ok "Partition created"

    # Wait for kernel to detect partition
    partprobe "/dev/${dev}" 2>/dev/null || true
    udevadm settle --timeout=5 2>/dev/null || sleep 2

    # Determine partition name (handles NVMe p1 naming)
    local part_dev="${dev}1"
    if [[ ! -b "/dev/${part_dev}" ]]; then
        part_dev="${dev}p1"
        if [[ ! -b "/dev/${part_dev}" ]]; then
            print_fail "Partition /dev/${dev}1 not found after creation"
            print_info "Try removing and reinserting the device"
            return
        fi
    fi

    # Format — array-based, no eval
    print_info "Formatting /dev/${part_dev} as ${fs_type}..."

    if [[ -n "$vol_label" ]]; then
        case "$fs_type" in
            fat32)   mkfs_args+=("-n" "$vol_label") ;;
            exfat)   mkfs_args+=("-L" "$vol_label") ;;
            ntfs)    mkfs_args+=("-L" "$vol_label") ;;
            ext4)    mkfs_args+=("-L" "$vol_label") ;;
            btrfs)   mkfs_args+=("-L" "$vol_label") ;;
            f2fs)    mkfs_args+=("-l" "$vol_label") ;;
            xfs)     mkfs_args+=("-L" "$vol_label") ;;
        esac
    fi

    if "${mkfs_args[@]}" "/dev/${part_dev}" 2>&1; then
        print_ok "Formatted /dev/${part_dev} as ${fs_type}"
    else
        print_fail "Formatting failed — see error above"
        return
    fi

    sync
    timer_stop "Format"
    print_ok "Format complete!"
    echo ""
    echo -e "  ${GREEN}${BOLD}  /dev/${dev} formatted successfully.${NC}"
    echo -e "  ${DIM}  Remove and reinsert the drive, or mount manually.${NC}"
    echo ""
}

format_menu() {
    print_header "Category 4: Format USB"
    echo -e "  ${DIM}  Format USB drives with filesystem and partition table options.${NC}"

    local choice
    choice=$(ui_choose "Select:" \
        "Format a USB device" \
        "Back")

    case "$choice" in
        *"Format"*) format_usb ;;
        *) return ;;
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

    local dev=""
    if ! select_device "$usb_devs" "USB devices" dev; then
        return
    fi

    if ! command -v badblocks &>/dev/null; then
        print_fail "badblocks not found. Install: sudo apt install e2fsprogs"
        return
    fi

    if is_system_disk "$dev"; then
        print_fail "/dev/${dev} appears to be a system disk!"
        return
    fi

    # Warn if partitions are mounted — badblocks may report false positives
    local mounted_parts
    mounted_parts=$(lsblk -rno NAME,MOUNTPOINT "/dev/${dev}" 2>/dev/null | awk '$2 != "" {print "/dev/"$1}')
    if [[ -n "$mounted_parts" ]]; then
        print_warn "Device has mounted partitions — results may be unreliable"
        echo "$mounted_parts" | while IFS= read -r mp; do
            echo -e "    ${DIM}${mp}${NC}"
        done
        echo ""
        if ! confirm_action "Continue anyway?"; then
            return
        fi
    fi

    print_info "Running read-only bad blocks test on /dev/${dev}..."
    print_info "This may take a while depending on device size."
    echo ""
    timer_start

    local bad_count
    bad_count=$(badblocks -sv "/dev/${dev}" 2>&1 | tee /dev/stderr | grep -c "^[0-9]" || true)

    echo ""
    if [[ "$bad_count" -eq 0 ]]; then
        print_ok "No bad blocks found on /dev/${dev}"
    else
        print_warn "${bad_count} bad blocks found on /dev/${dev}"
    fi
    timer_stop "Bad blocks test"
    log "HEALTHCHECK: badblocks /dev/${dev} — ${bad_count} bad blocks"
}

health_smart() {
    print_header "SMART Data"

    local usb_devs
    usb_devs=$(get_usb_devices)

    local dev=""
    if ! select_device "$usb_devs" "USB devices" dev; then
        return
    fi

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

    local dev=""
    if ! select_device "$unmounted" "unmounted USB partitions" dev; then
        echo ""
        print_warn "Only unmounted partitions can be checked."
        return
    fi

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
    timer_start

    local fsck_exit=0
    case "$fstype" in
        ext2|ext3|ext4)
            e2fsck -fvy "/dev/${dev}" 2>&1 | while IFS= read -r line; do
                echo -e "    ${DIM}${line}${NC}"
            done
            fsck_exit=${PIPESTATUS[0]}
            ;;
        vfat)
            fsck.vfat -vy "/dev/${dev}" 2>&1 | while IFS= read -r line; do
                echo -e "    ${DIM}${line}${NC}"
            done
            fsck_exit=${PIPESTATUS[0]}
            ;;
        ntfs)
            if command -v ntfsfix &>/dev/null; then
                ntfsfix "/dev/${dev}" 2>&1 | while IFS= read -r line; do
                    echo -e "    ${DIM}${line}${NC}"
                done
                fsck_exit=${PIPESTATUS[0]}
            else
                print_fail "ntfsfix not found. Install: sudo apt install ntfs-3g"
                return
            fi
            ;;
        exfat)
            if command -v fsck.exfat &>/dev/null; then
                fsck.exfat "/dev/${dev}" 2>&1 | while IFS= read -r line; do
                    echo -e "    ${DIM}${line}${NC}"
                done
                fsck_exit=${PIPESTATUS[0]}
            else
                print_fail "fsck.exfat not found. Install: sudo apt install exfat-utils"
                return
            fi
            ;;
        btrfs)
            btrfs check "/dev/${dev}" 2>&1 | while IFS= read -r line; do
                echo -e "    ${DIM}${line}${NC}"
            done
            fsck_exit=${PIPESTATUS[0]}
            ;;
        f2fs)
            if command -v fsck.f2fs &>/dev/null; then
                fsck.f2fs "/dev/${dev}" 2>&1 | while IFS= read -r line; do
                    echo -e "    ${DIM}${line}${NC}"
                done
                fsck_exit=${PIPESTATUS[0]}
            else
                print_fail "fsck.f2fs not found. Install: sudo apt install f2fs-tools"
                return
            fi
            ;;
        xfs)
            if command -v xfs_repair &>/dev/null; then
                xfs_repair "/dev/${dev}" 2>&1 | while IFS= read -r line; do
                    echo -e "    ${DIM}${line}${NC}"
                done
                fsck_exit=${PIPESTATUS[0]}
            else
                print_fail "xfs_repair not found. Install: sudo apt install xfsprogs"
                return
            fi
            ;;
        *)
            print_warn "No fsck tool known for filesystem: ${fstype}"
            return
            ;;
    esac

    echo ""
    timer_stop "Filesystem check"

    if [[ $fsck_exit -eq 0 ]]; then
        print_ok "Filesystem check complete — no errors"
    elif [[ $fsck_exit -eq 1 ]]; then
        print_warn "Filesystem errors were corrected"
    else
        print_fail "Filesystem check failed (exit code: ${fsck_exit})"
    fi
    log "HEALTHCHECK: fsck /dev/${dev} (${fstype}) exit=${fsck_exit}"
}

health_read_speed_test() {
    print_header "USB Read Speed Test"

    local usb_devs
    usb_devs=$(get_usb_devices)

    local dev=""
    if ! select_device "$usb_devs" "USB devices" dev; then
        return
    fi

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
    timer_start

    # Drop caches for accurate measurement
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

    local dd_output
    dd_output=$(dd if="/dev/${dev}" of=/dev/null bs="${block_size}" count="${test_blocks}" 2>&1)

    echo ""
    # Extract and display speed from dd output
    local speed
    speed=$(echo "$dd_output" | grep -oE '[0-9.,]+ [MGKT]?B/s' | tail -1)
    if [[ -n "$speed" ]]; then
        echo -e "    ${BOLD}${GREEN}Read speed: ${speed}${NC}"
    else
        echo "$dd_output" | tail -1 | while IFS= read -r line; do
            echo -e "    ${line}"
        done
    fi

    echo ""
    timer_stop "Read speed test"
    log "HEALTHCHECK: read speed test /dev/${dev} — ${speed:-unknown}"
}

health_write_speed_test() {
    print_header "USB Write Speed Test (DESTRUCTIVE)"

    local usb_devs
    usb_devs=$(get_usb_devices)

    local dev=""
    if ! select_device "$usb_devs" "USB devices" dev; then
        return
    fi

    if is_system_disk "$dev"; then
        print_fail "/dev/${dev} appears to be a system disk!"
        return
    fi

    echo ""
    print_warn "This test WRITES data to /dev/${dev} and DESTROYS all data!"
    echo ""

    if ! double_confirm "$dev"; then
        echo -e "  ${YELLOW}Cancelled.${NC}"
        return
    fi

    # Unmount all partitions
    if ! unmount_all_partitions "$dev" true; then
        print_fail "Could not unmount all partitions — aborting"
        return
    fi

    local test_size="256MB"
    local test_blocks=64
    local block_size="4M"

    local size_bytes
    size_bytes=$(blockdev --getsize64 "/dev/${dev}" 2>/dev/null || echo "0")
    if [[ "$size_bytes" -lt 268435456 ]]; then
        test_blocks=$((size_bytes / 4194304))
        [[ $test_blocks -lt 1 ]] && test_blocks=1
        test_size="$((test_blocks * 4))MB"
    fi

    echo ""
    echo -e "  ${BOLD}Writing ${test_size} to /dev/${dev}...${NC}"
    echo ""
    timer_start

    # Drop caches
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

    local dd_output
    dd_output=$(dd if=/dev/zero of="/dev/${dev}" bs="${block_size}" count="${test_blocks}" conv=fdatasync 2>&1)

    echo ""
    local speed
    speed=$(echo "$dd_output" | grep -oE '[0-9.,]+ [MGKT]?B/s' | tail -1)
    if [[ -n "$speed" ]]; then
        echo -e "    ${BOLD}${GREEN}Write speed: ${speed}${NC}"
    else
        echo "$dd_output" | tail -1 | while IFS= read -r line; do
            echo -e "    ${line}"
        done
    fi

    echo ""
    timer_stop "Write speed test"
    print_warn "Data on /dev/${dev} has been destroyed. Format the device to use again."
    log "HEALTHCHECK: write speed test /dev/${dev} — ${speed:-unknown}"
}

health_menu() {
    print_header "Category 5: USB Health Check"
    echo -e "  ${DIM}  Diagnose and test USB drive health.${NC}"

    local choice
    choice=$(ui_choose "Select test:" \
        "Bad blocks test      — read-only scan" \
        "SMART data           — if supported" \
        "Filesystem check     — fsck (must be unmounted)" \
        "Read speed test      — non-destructive" \
        "Write speed test     — DESTRUCTIVE!" \
        "Back")

    case "$choice" in
        *"Bad blocks"*)    health_badblocks ;;
        *"SMART"*)         health_smart ;;
        *"Filesystem"*)    health_fsck ;;
        *"Read speed"*)    health_read_speed_test ;;
        *"Write speed"*)   health_write_speed_test ;;
        *) return ;;
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

    local dev=""
    if ! select_device "$usb_devs" "USB devices" dev; then
        return
    fi

    local size
    size=$(lsblk -dnro SIZE "/dev/${dev}" 2>/dev/null || echo "Unknown")
    local size_bytes
    size_bytes=$(blockdev --getsize64 "/dev/${dev}" 2>/dev/null || echo "0")

    echo ""
    echo -e "  ${BOLD}Source:${NC} /dev/${dev} (${size})"

    # Compression choice
    local -a compress_opts=("None (raw .img — fastest, largest file)" "gzip (.img.gz — good compression, slower)")
    if command -v zstd &>/dev/null; then
        compress_opts+=("zstd (.img.zst — fast compression, good ratio)")
    fi
    local compress_choice
    compress_choice=$(ui_choose "Compression:" "${compress_opts[@]}")

    local compress="none"
    local ext=".img"
    case "$compress_choice" in
        *"None"*|"") compress="none"; ext=".img" ;;
        *"gzip"*) compress="gzip"; ext=".img.gz" ;;
        *"zstd"*)
            if command -v zstd &>/dev/null; then
                compress="zstd"; ext=".img.zst"
            else
                print_fail "zstd not found. Install: sudo apt install zstd"
                return
            fi
            ;;
        *) echo -e "  ${RED}Invalid choice, using no compression${NC}" ;;
    esac

    local default_img
    default_img="$(get_user_home)/usb-backup-${dev}-$(date +%Y%m%d-%H%M%S)${ext}"
    local custom_img
    custom_img=$(ui_input "Output file" "$default_img")
    local img_file="${custom_img:-$default_img}"

    # Validate and expand path
    local validated_path
    validated_path=$(validate_filepath "$img_file")
    if [[ $? -ne 0 || -z "$validated_path" ]]; then
        return
    fi
    img_file="$validated_path"

    # Check directory exists
    local img_dir
    img_dir=$(dirname "$img_file")
    if [[ ! -d "$img_dir" ]]; then
        print_fail "Directory ${img_dir} does not exist"
        return
    fi

    # Check available disk space
    local avail_bytes
    avail_bytes=$(df --output=avail -B1 "$img_dir" 2>/dev/null | tail -1 | tr -d ' ')
    if [[ "$avail_bytes" =~ ^[0-9]+$ ]] && [[ "$size_bytes" =~ ^[0-9]+$ ]]; then
        if [[ "$avail_bytes" -lt "$size_bytes" ]]; then
            local avail_human size_human
            avail_human=$(numfmt --to=iec "$avail_bytes" 2>/dev/null || echo "${avail_bytes} bytes")
            size_human=$(numfmt --to=iec "$size_bytes" 2>/dev/null || echo "${size_bytes} bytes")
            print_fail "Not enough disk space: ${avail_human} available, ${size_human} needed"
            if [[ "$compress" == "none" ]]; then
                print_info "Consider using compression to reduce file size."
            fi
            return
        fi
    fi

    echo ""
    echo -e "  ${BOLD}Backup:${NC} /dev/${dev} → ${img_file}"
    echo -e "  ${DIM}  Device size: ${size}. Compression: ${compress}.${NC}"

    if ! confirm_action "Start backup?"; then
        return
    fi

    CLEANUP_TMPFILES+=("$img_file")
    print_info "Backing up /dev/${dev} to ${img_file}..."
    echo ""
    timer_start

    local backup_ok=0
    case "$compress" in
        none)
            if dd_with_progress "/dev/${dev}" "$img_file" "4M"; then
                backup_ok=1
            fi
            ;;
        gzip)
            if command -v pv &>/dev/null; then
                dd if="/dev/${dev}" bs=4M 2>/dev/null | pv -s "$size_bytes" | gzip -c > "$img_file"
            else
                dd if="/dev/${dev}" bs=4M 2>/dev/null | gzip -c > "$img_file"
            fi
            local pipe_result=("${PIPESTATUS[@]}")
            local pipe_ok=1
            for s in "${pipe_result[@]}"; do [[ "$s" -ne 0 ]] && pipe_ok=0; done
            [[ $pipe_ok -eq 1 ]] && backup_ok=1
            ;;
        zstd)
            if command -v pv &>/dev/null; then
                dd if="/dev/${dev}" bs=4M 2>/dev/null | pv -s "$size_bytes" | zstd -c > "$img_file"
            else
                dd if="/dev/${dev}" bs=4M 2>/dev/null | zstd -c > "$img_file"
            fi
            local pipe_result2=("${PIPESTATUS[@]}")
            local pipe_ok2=1
            for s in "${pipe_result2[@]}"; do [[ "$s" -ne 0 ]] && pipe_ok2=0; done
            [[ $pipe_ok2 -eq 1 ]] && backup_ok=1
            ;;
    esac

    if [[ $backup_ok -eq 1 ]]; then
        sync
        CLEANUP_TMPFILES=()
        local img_size
        img_size=$(du -h "$img_file" 2>/dev/null | cut -f1)
        timer_stop "Backup"
        print_ok "Backup complete: ${img_file} (${img_size})"

        # Set ownership to user
        chown "$(get_current_user):$(get_current_user)" "$img_file" 2>/dev/null || true

        # Generate SHA256 checksum
        print_info "Generating SHA256 checksum..."
        local sha_file="${img_file}.sha256"
        if sha256sum "$img_file" > "$sha_file" 2>/dev/null; then
            chown "$(get_current_user):$(get_current_user)" "$sha_file" 2>/dev/null || true
            print_ok "Checksum saved: ${sha_file}"
        else
            rm -f "$sha_file" 2>/dev/null || true
            print_warn "Failed to generate SHA256 checksum"
        fi

        log "BACKUP: /dev/${dev} → ${img_file} (${img_size}) compress=${compress}"
    else
        rm -f "$img_file" 2>/dev/null || true
        CLEANUP_TMPFILES=()
        print_fail "Backup failed — partial file removed"
    fi
    echo ""
}

restore_from_image() {
    print_header "Restore Image to USB"
    log "ACTION: Restore image to USB"

    local img_file_raw
    img_file_raw=$(ui_file_input "Select image file")

    # Validate and expand path
    local img_file
    img_file=$(validate_filepath "$img_file_raw")
    if [[ $? -ne 0 || -z "$img_file" ]]; then
        return
    fi

    if [[ ! -f "$img_file" ]]; then
        print_fail "Image file not found: ${img_file}"
        return
    fi

    local img_size
    img_size=$(du -h "$img_file" 2>/dev/null | cut -f1)
    echo -e "  ${BOLD}Image:${NC} ${img_file} (${img_size})"

    # Auto-detect compression
    local compress="none"
    case "$img_file" in
        *.gz)  compress="gzip" ;;
        *.zst) compress="zstd" ;;
    esac
    [[ "$compress" != "none" ]] && echo -e "  ${BOLD}Compression:${NC} ${compress} (auto-detected)"

    local usb_devs
    usb_devs=$(get_usb_devices)

    echo ""
    echo -e "  ${BOLD}Select target USB device:${NC}"

    local dev=""
    if ! select_device "$usb_devs" "USB devices" dev; then
        return
    fi

    if is_system_disk "$dev"; then
        print_fail "/dev/${dev} appears to be a system disk!"
        return
    fi

    # Unmount if needed
    if ! unmount_all_partitions "$dev" true; then
        print_fail "Could not unmount all partitions — aborting"
        return
    fi

    if ! double_confirm "$dev"; then
        echo -e "  ${YELLOW}Cancelled.${NC}"
        return
    fi

    print_info "Restoring ${img_file} → /dev/${dev}..."
    echo ""
    timer_start

    local restore_ok=0
    case "$compress" in
        none)
            if dd_with_progress "$img_file" "/dev/${dev}" "4M" "conv=fdatasync"; then
                restore_ok=1
            fi
            ;;
        gzip)
            if command -v pv &>/dev/null; then
                pv "$img_file" | gunzip -c | dd of="/dev/${dev}" bs=4M conv=fdatasync 2>/dev/null
            else
                gunzip -c "$img_file" | dd of="/dev/${dev}" bs=4M conv=fdatasync status=progress 2>&1
            fi
            local pipe_gz=("${PIPESTATUS[@]}")
            local gz_ok=1
            for s in "${pipe_gz[@]}"; do [[ "$s" -ne 0 ]] && gz_ok=0; done
            [[ $gz_ok -eq 1 ]] && restore_ok=1
            ;;
        zstd)
            if ! command -v zstd &>/dev/null; then
                print_fail "zstd not found. Install: sudo apt install zstd"
                return
            fi
            if command -v pv &>/dev/null; then
                pv "$img_file" | zstd -dc | dd of="/dev/${dev}" bs=4M conv=fdatasync 2>/dev/null
            else
                zstd -dc "$img_file" | dd of="/dev/${dev}" bs=4M conv=fdatasync status=progress 2>&1
            fi
            local pipe_zst=("${PIPESTATUS[@]}")
            local zst_ok=1
            for s in "${pipe_zst[@]}"; do [[ "$s" -ne 0 ]] && zst_ok=0; done
            [[ $zst_ok -eq 1 ]] && restore_ok=1
            ;;
    esac

    if [[ $restore_ok -eq 1 ]]; then
        sync
        timer_stop "Restore"
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

    local -a dev_arr
    read -ra dev_arr <<< "$usb_devs"
    if [[ ${#dev_arr[@]} -lt 2 ]]; then
        print_fail "Need at least 2 USB devices connected for cloning."
        return
    fi

    echo ""
    echo -e "  ${BOLD}Select SOURCE device:${NC}"

    local source_dev=""
    if ! select_device "$usb_devs" "USB devices (source)" source_dev; then
        return
    fi

    echo ""
    echo -e "  ${BOLD}Select TARGET device:${NC}"

    # Remove source from list
    local target_list=""
    for d in $usb_devs; do
        [[ "$d" != "$source_dev" ]] && target_list="${target_list} ${d}"
    done
    target_list=$(echo "$target_list" | xargs)

    local target_dev=""
    if ! select_device "$target_list" "USB devices (target)" target_dev; then
        return
    fi

    if is_system_disk "$target_dev"; then
        print_fail "/dev/${target_dev} appears to be a system disk!"
        return
    fi

    local src_size tgt_size src_bytes tgt_bytes
    src_size=$(lsblk -dnro SIZE "/dev/${source_dev}" 2>/dev/null)
    tgt_size=$(lsblk -dnro SIZE "/dev/${target_dev}" 2>/dev/null)
    src_bytes=$(blockdev --getsize64 "/dev/${source_dev}" 2>/dev/null || echo "0")
    tgt_bytes=$(blockdev --getsize64 "/dev/${target_dev}" 2>/dev/null || echo "0")

    # Check target is large enough
    if [[ "$src_bytes" =~ ^[0-9]+$ ]] && [[ "$tgt_bytes" =~ ^[0-9]+$ ]]; then
        if [[ "$src_bytes" -gt "$tgt_bytes" ]]; then
            print_fail "Source (${src_size}) is larger than target (${tgt_size}) — clone would be truncated"
            return
        fi
    fi

    echo ""
    echo -e "  ${BOLD}Clone:${NC} /dev/${source_dev} (${src_size}) → /dev/${target_dev} (${tgt_size})"

    # Unmount target
    if ! unmount_all_partitions "$target_dev" true; then
        print_fail "Could not unmount target partitions — aborting"
        return
    fi

    if ! double_confirm "$target_dev"; then
        echo -e "  ${YELLOW}Cancelled.${NC}"
        return
    fi

    print_info "Cloning /dev/${source_dev} → /dev/${target_dev}..."
    echo ""
    timer_start

    if dd_with_progress "/dev/${source_dev}" "/dev/${target_dev}" "4M" "conv=fdatasync"; then
        sync
        timer_stop "Clone"
        print_ok "Clone complete: /dev/${source_dev} → /dev/${target_dev}"
        log "CLONE: /dev/${source_dev} → /dev/${target_dev}"
    else
        print_fail "Clone failed"
    fi
    echo ""
}

backup_menu() {
    print_header "Category 6: USB Backup & Clone"
    echo -e "  ${DIM}  Create disk images, restore from images, and clone USB drives.${NC}"

    local choice
    choice=$(ui_choose "Select operation:" \
        "Backup USB → image file    (dd, optional compression)" \
        "Restore image → USB        (dd, auto-decompression)" \
        "Clone USB → USB            (direct copy)" \
        "Back")

    case "$choice" in
        *"Backup"*) backup_to_image ;;
        *"Restore"*) restore_from_image ;;
        *"Clone"*) clone_usb_to_usb ;;
        *) return ;;
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

    local iso_file_raw
    iso_file_raw=$(ui_file_input "Select ISO file")

    # Validate and expand path
    local iso_file
    iso_file=$(validate_filepath "$iso_file_raw")
    if [[ $? -ne 0 || -z "$iso_file" ]]; then
        return
    fi

    if [[ ! -f "$iso_file" ]]; then
        print_fail "ISO file not found: ${iso_file}"
        return
    fi

    local iso_size iso_bytes
    iso_size=$(du -h "$iso_file" 2>/dev/null | cut -f1)
    iso_bytes=$(stat -c%s "$iso_file" 2>/dev/null || echo "0")
    echo -e "  ${BOLD}ISO:${NC} ${iso_file} (${iso_size})"

    local usb_devs
    usb_devs=$(get_usb_devices)

    echo ""
    echo -e "  ${BOLD}Select target USB device:${NC}"

    local dev=""
    if ! select_device "$usb_devs" "USB devices" dev; then
        return
    fi

    if is_system_disk "$dev"; then
        print_fail "/dev/${dev} appears to be a system disk!"
        return
    fi

    local dev_size_bytes
    dev_size_bytes=$(blockdev --getsize64 "/dev/${dev}" 2>/dev/null || echo "0")
    local dev_size
    dev_size=$(lsblk -dnro SIZE "/dev/${dev}" 2>/dev/null)

    # Check ISO fits on USB
    if [[ "$iso_bytes" =~ ^[0-9]+$ ]] && [[ "$dev_size_bytes" =~ ^[0-9]+$ ]]; then
        if [[ "$iso_bytes" -gt "$dev_size_bytes" ]]; then
            local iso_human dev_human
            iso_human=$(numfmt --to=iec "$iso_bytes" 2>/dev/null || echo "$iso_size")
            dev_human=$(numfmt --to=iec "$dev_size_bytes" 2>/dev/null || echo "$dev_size")
            print_fail "ISO (${iso_human}) is larger than USB device (${dev_human})"
            return
        fi
    fi

    echo ""
    echo -e "  ${BOLD}Summary:${NC}"
    echo -e "    ISO:    ${iso_file} (${iso_size})"
    echo -e "    Target: /dev/${dev} (${dev_size})"

    # Unmount if needed
    if ! unmount_all_partitions "$dev" true; then
        print_fail "Could not unmount all partitions — aborting"
        return
    fi

    if ! double_confirm "$dev"; then
        echo -e "  ${YELLOW}Cancelled.${NC}"
        return
    fi

    print_info "Writing ISO to /dev/${dev}..."
    echo ""
    timer_start

    if dd_with_progress "$iso_file" "/dev/${dev}" "4M" "conv=fdatasync"; then
        sync
        timer_stop "ISO write"
        print_ok "ISO written to /dev/${dev}"
        log "WRITE ISO: ${iso_file} → /dev/${dev}"
    else
        print_fail "ISO write failed"
        return
    fi

    # Verify
    local verify
    verify=$(ui_choose "Verify write?" \
        "Yes — compare SHA256 checksums (recommended)" \
        "No — skip verification")

    if [[ "$verify" == *"Yes"* || -z "$verify" ]]; then
        if [[ ! "$iso_bytes" =~ ^[0-9]+$ ]] || [[ "$iso_bytes" -eq 0 ]]; then
            print_fail "Cannot determine ISO file size — skipping verification"
        else
            print_info "Calculating ISO SHA256 checksum..."
            local iso_sha
            iso_sha=$(sha256sum "$iso_file" 2>/dev/null | cut -d' ' -f1)
            if [[ -z "$iso_sha" ]]; then
                print_fail "Failed to calculate ISO checksum"
            else
                echo -e "    ISO:    ${iso_sha}"

                print_info "Calculating USB SHA256 checksum (reading same size as ISO)..."
                local usb_sha
                local dd_count=$(( (iso_bytes + 4194303) / 4194304 ))
                usb_sha=$(dd if="/dev/${dev}" bs=4M count="${dd_count}" 2>/dev/null | head -c "$iso_bytes" | sha256sum | cut -d' ' -f1)
                echo -e "    USB:    ${usb_sha}"

                echo ""
                if [[ "$iso_sha" == "$usb_sha" ]]; then
                    print_ok "SHA256 checksums match — write verified!"
                else
                    print_fail "SHA256 checksums DO NOT match! Write may be corrupted."
                fi
            fi
        fi
    fi

    echo ""
    echo -e "  ${GREEN}${BOLD}  Bootable USB created.${NC}"
    echo ""
}

iso_menu() {
    print_header "Category 7: Write ISO (Bootable USB)"
    echo -e "  ${DIM}  Write bootable ISO images to USB devices.${NC}"

    local choice
    choice=$(ui_choose "Select:" \
        "Write ISO to USB" \
        "Back")

    case "$choice" in
        *"Write"*) write_iso ;;
        *) return ;;
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
    if ! dd if=/dev/zero of="/dev/${dev}" bs=1M count=1 status=progress 2>&1; then
        print_fail "Failed to zero start of /dev/${dev}"
        return
    fi
    # Zero last 1MB (backup GPT table)
    local size_bytes
    size_bytes=$(blockdev --getsize64 "/dev/${dev}" 2>/dev/null || echo "0")
    if [[ "$size_bytes" -gt 1048576 ]]; then
        local seek_mb=$(( (size_bytes - 1048576) / 1048576 ))
        dd if=/dev/zero of="/dev/${dev}" bs=1M seek="${seek_mb}" count=1 conv=notrunc status=progress 2>&1 || true
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

    # dd returns nonzero when hitting end-of-device (expected)
    # but I/O errors should be reported
    if dd_with_progress "/dev/zero" "/dev/${dev}" "4M"; then
        sync
        print_ok "Full zero wipe complete on /dev/${dev}"
    else
        sync
        # Check if device still exists (dd error vs end-of-device)
        if [[ -b "/dev/${dev}" ]]; then
            print_warn "Wipe finished with warnings on /dev/${dev} (may be normal for end-of-device)"
        else
            print_fail "Device /dev/${dev} disappeared during wipe — device may have been removed"
        fi
    fi
}

wipe_random() {
    local dev="$1"
    print_info "Random wipe: writing random data to entire disk..."
    log "WIPE (random): /dev/${dev}"

    if dd_with_progress "/dev/urandom" "/dev/${dev}" "4M"; then
        sync
        print_ok "Random wipe complete on /dev/${dev}"
    else
        sync
        if [[ -b "/dev/${dev}" ]]; then
            print_warn "Wipe finished with warnings on /dev/${dev} (may be normal for end-of-device)"
        else
            print_fail "Device /dev/${dev} disappeared during wipe — device may have been removed"
        fi
    fi
}

wipe_multipass() {
    local dev="$1"
    print_info "Multi-pass wipe (3 passes): random → zeros → random..."
    log "WIPE (multi-pass): /dev/${dev}"

    local pass_fail=0

    echo ""
    echo -e "    ${BOLD}Pass 1/3: Random data...${NC}"
    dd_with_progress "/dev/urandom" "/dev/${dev}" "4M" || pass_fail=1
    sync
    [[ ! -b "/dev/${dev}" ]] && { print_fail "Device removed during wipe"; return; }

    echo ""
    echo -e "    ${BOLD}Pass 2/3: Zero fill...${NC}"
    dd_with_progress "/dev/zero" "/dev/${dev}" "4M" || pass_fail=1
    sync
    [[ ! -b "/dev/${dev}" ]] && { print_fail "Device removed during wipe"; return; }

    echo ""
    echo -e "    ${BOLD}Pass 3/3: Random data...${NC}"
    dd_with_progress "/dev/urandom" "/dev/${dev}" "4M" || pass_fail=1
    sync

    if [[ $pass_fail -eq 0 ]]; then
        print_ok "Multi-pass wipe complete on /dev/${dev} (3 passes)"
    else
        print_warn "Multi-pass wipe finished with warnings on /dev/${dev} (may be normal for end-of-device)"
    fi
}

secure_wipe() {
    print_header "Secure Wipe USB"
    log "ACTION: Secure Wipe"

    local usb_devs
    usb_devs=$(get_usb_devices)

    local dev=""
    if ! select_device "$usb_devs" "USB devices" dev; then
        return
    fi

    if is_system_disk "$dev"; then
        print_fail "/dev/${dev} appears to be a system disk!"
        return
    fi

    local size
    size=$(lsblk -dnro SIZE "/dev/${dev}" 2>/dev/null || echo "Unknown")

    echo ""
    echo -e "  ${BOLD}Device:${NC} /dev/${dev} (${size})"

    # Unmount all partitions
    if ! unmount_all_partitions "$dev" true; then
        print_fail "Could not unmount all partitions — aborting"
        return
    fi

    local wipe_choice
    wipe_choice=$(ui_choose "Wipe method:" \
        "Quick wipe — zero first/last 1MB + wipe signatures (fast)" \
        "Full zero — write zeros to entire disk" \
        "Random wipe — write random data to entire disk" \
        "Multi-pass — 3 passes: random → zeros → random (slowest)")

    if [[ -z "$wipe_choice" ]]; then
        echo -e "  ${RED}Invalid choice${NC}"
        return
    fi

    local wipe_mode
    case "$wipe_choice" in
        *"Quick"*) wipe_mode=1 ;;
        *"Full zero"*) wipe_mode=2 ;;
        *"Random"*) wipe_mode=3 ;;
        *"Multi-pass"*) wipe_mode=4 ;;
        *) echo -e "  ${RED}Invalid choice${NC}"; return ;;
    esac

    if ! double_confirm "$dev"; then
        echo -e "  ${YELLOW}Cancelled.${NC}"
        return
    fi

    echo ""
    timer_start

    case "$wipe_mode" in
        1) wipe_quick "$dev" ;;
        2) wipe_full_zero "$dev" ;;
        3) wipe_random "$dev" ;;
        4) wipe_multipass "$dev" ;;
    esac

    timer_stop "Wipe"
    echo ""
    echo -e "  ${GREEN}${BOLD}  Wipe complete on /dev/${dev}.${NC}"
    echo -e "  ${DIM}  The device is now empty. Format it to use again.${NC}"
    echo ""
}

wipe_menu() {
    print_header "Category 8: Secure Wipe"
    echo -e "  ${DIM}  Securely erase USB drives with various wipe methods.${NC}"

    local choice
    choice=$(ui_choose "Select:" \
        "Wipe a USB device" \
        "Back")

    case "$choice" in
        *"Wipe"*) secure_wipe ;;
        *) return ;;
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

    local dev=""
    if ! select_device "$usb_devs" "USB devices" dev; then
        return
    fi

    echo ""
    echo -e "  ${BOLD}Ejecting /dev/${dev}...${NC}"

    # Sync
    print_info "Syncing all filesystems..."
    sync

    # Unmount all partitions
    local unmount_ok=true
    if ! unmount_all_partitions "$dev"; then
        print_warn "Some partitions could not be unmounted"
        unmount_ok=false
    fi

    # Power off USB device (try udisksctl first, then sysfs)
    local poweroff_ok=false
    if command -v udisksctl &>/dev/null; then
        if udisksctl power-off -b "/dev/${dev}" 2>/dev/null; then
            print_ok "Device powered off (udisksctl)"
            poweroff_ok=true
        else
            print_info "udisksctl failed — trying sysfs..."
            local sys_dev="/sys/block/${dev}/device"
            if [[ -f "${sys_dev}/delete" ]]; then
                echo 1 > "${sys_dev}/delete" 2>/dev/null
                print_ok "Device powered off (sysfs)"
                poweroff_ok=true
            elif [[ -f "${sys_dev}/../../remove" ]]; then
                echo 1 > "${sys_dev}/../../remove" 2>/dev/null
                print_ok "USB port deauthorized"
                poweroff_ok=true
            fi
        fi
    else
        local sys_dev="/sys/block/${dev}/device"
        if [[ -f "${sys_dev}/delete" ]]; then
            echo 1 > "${sys_dev}/delete" 2>/dev/null
            print_ok "Device powered off"
            poweroff_ok=true
        elif [[ -f "${sys_dev}/../../remove" ]]; then
            echo 1 > "${sys_dev}/../../remove" 2>/dev/null
            print_ok "USB port deauthorized"
            poweroff_ok=true
        fi
    fi

    echo ""
    if [[ "$unmount_ok" == "true" ]]; then
        if [[ "$poweroff_ok" == "true" ]]; then
            echo -e "  ${GREEN}${BOLD}  Safe to remove /dev/${dev}.${NC}"
        else
            echo -e "  ${YELLOW}${BOLD}  Could not power off — safe to remove after sync.${NC}"
        fi
        log "EJECT: /dev/${dev}"
    else
        echo -e "  ${RED}${BOLD}  WARNING: Some partitions still mounted — do NOT remove /dev/${dev}!${NC}"
        log "EJECT FAILED: /dev/${dev} — partitions still mounted"
    fi
    echo ""
}

quick_device_info() {
    print_header "Quick Device Info"

    local usb_devs
    usb_devs=$(get_usb_devices)

    local dev=""
    if ! select_device "$usb_devs" "USB devices" dev; then
        return
    fi

    echo ""
    print_section "A" "Device Summary: /dev/${dev}"
    echo ""
    print_device_details "$dev"

    print_section "B" "Partitions"

    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,UUID "/dev/${dev}" 2>/dev/null | while IFS= read -r line; do
        echo -e "    ${DIM}${line}${NC}"
    done

    print_section "C" "Block Device Info"

    echo ""
    local ro sched logical_bs physical_bs
    ro=$(read_sysfs "/sys/block/${dev}/ro" "?")
    sched=$(read_sysfs "/sys/block/${dev}/queue/scheduler" "?")
    logical_bs=$(read_sysfs "/sys/block/${dev}/queue/logical_block_size" "?")
    physical_bs=$(read_sysfs "/sys/block/${dev}/queue/physical_block_size" "?")

    echo -e "    ${BOLD}Read-only:${NC}       ${ro}"
    echo -e "    ${BOLD}Scheduler:${NC}       ${sched}"
    echo -e "    ${BOLD}Logical BS:${NC}      ${logical_bs}"
    echo -e "    ${BOLD}Physical BS:${NC}     ${physical_bs}"

    echo ""
}

# ============================================================================
#  CLI Arguments
# ============================================================================

cli_help() {
    cat <<HELPEOF
USB TOOLKIT v${SCRIPT_VERSION} — USB Device Operations & Management

Usage: sudo bash usb-toolkit.sh [OPTION]

Options:
  --help       Show this help message and exit
  --version    Show version and exit
  --list       List connected USB storage devices (non-interactive)

Interactive mode (no arguments):
  Launches the full interactive menu with all operations.

Categories:
  1. USB Detection    — List and identify connected USB storage devices
  2. Mount USB        — Mount USB partitions with various options
  3. Unmount USB      — Safe unmount with sync and process check
  4. Format USB       — Format with filesystem and partition table choice
  5. Health Check     — badblocks, SMART, fsck, read/write speed test
  6. Backup & Clone   — Image backup (with compression), restore, clone
  7. Write ISO        — Write bootable ISO image to USB
  8. Secure Wipe      — Quick, full, random, and multi-pass wipe

Quick Actions:
  9. Safe Eject       — sync + unmount + power off
 10. Device Info      — Quick summary of a selected USB device

Requires: root privileges (sudo)
HELPEOF
}

cli_version() {
    echo "USB TOOLKIT v${SCRIPT_VERSION}"
}

cli_list() {
    check_root
    local usb_devs
    usb_devs=$(get_usb_devices)

    if [[ -z "$usb_devs" ]]; then
        echo "No USB storage devices detected."
        exit 0
    fi

    printf "%-12s  %-8s  %-20s  %-16s  %-10s\n" "DEVICE" "SIZE" "MODEL" "SERIAL" "USB SPEED"
    printf "%-12s  %-8s  %-20s  %-16s  %-10s\n" "------" "----" "-----" "------" "---------"

    for dev in $usb_devs; do
        local size model serial usb_speed
        size=$(lsblk -dnro SIZE "/dev/${dev}" 2>/dev/null || echo "?")
        model=$(read_sysfs "/sys/block/${dev}/device/model" "Unknown")
        serial=$(find_usb_attr "$dev" "serial" "N/A")
        usb_speed=$(get_usb_speed "$dev")
        printf "%-12s  %-8s  %-20s  %-16s  %s\n" "/dev/${dev}" "$size" "$model" "$serial" "$usb_speed"
    done
}

# Handle CLI arguments before interactive mode
handle_cli_args() {
    case "${1:-}" in
        --help|-h)
            cli_help
            exit 0
            ;;
        --version|-V)
            cli_version
            exit 0
            ;;
        --list|-l)
            cli_list
            exit 0
            ;;
        "")
            # No args — continue to interactive mode
            return 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: sudo bash usb-toolkit.sh [--help|--version|--list]"
            exit 1
            ;;
    esac
}

# ============================================================================
#  Main Menu
# ============================================================================

main_menu() {
    while true; do
        clear

        # Banner
        if [[ "$HAS_GUM" == true ]]; then
            echo ""
            gum style \
                --border "double" \
                --border-foreground "$GUM_BLUE" \
                --foreground "$GUM_BLUE" \
                --bold \
                --padding "1 4" \
                --align "center" \
                --width 60 \
                "USB TOOLKIT v${SCRIPT_VERSION}" \
                "Device Operations & Management"
        else
            echo ""
            echo -e "${BLUE}${BOLD}"
            echo "  ╔═══════════════════════════════════════════════════════════╗"
            echo "  ║                                                           ║"
            echo "  ║             USB TOOLKIT v${SCRIPT_VERSION}                          ║"
            echo "  ║          Device Operations & Management                   ║"
            echo "  ║                                                           ║"
            echo "  ╚═══════════════════════════════════════════════════════════╝"
            echo -e "${NC}"
        fi

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
                mdl=$(read_sysfs "/sys/block/${d}/device/model" "")
                echo -e "    ${DIM}/dev/${d}  ${sz}  ${mdl}${NC}"
            done
        fi
        echo ""

        # Main menu selection
        local choice
        choice=$(ui_choose "Select operation:" \
            "USB Detection    — List connected USB storage devices" \
            "Mount USB        — Mount USB partitions" \
            "Unmount USB      — Safe unmount with sync" \
            "Format USB       — Format with filesystem choice" \
            "Health Check     — badblocks, SMART, fsck, speed test" \
            "Backup & Clone   — Image backup, restore, clone" \
            "Write ISO        — Write bootable ISO to USB" \
            "Secure Wipe      — Quick, full, random, multi-pass wipe" \
            "Safe Eject       — sync + unmount + power off" \
            "Device Info      — Quick summary of a USB device" \
            "Exit")

        case "$choice" in
            *"USB Detection"*)  detect_menu ;;
            *"Mount USB"*)      mount_menu ;;
            *"Unmount USB"*)    unmount_menu ;;
            *"Format USB"*)     format_menu ;;
            *"Health Check"*)   health_menu ;;
            *"Backup & Clone"*) backup_menu ;;
            *"Write ISO"*)      iso_menu ;;
            *"Secure Wipe"*)    wipe_menu ;;
            *"Safe Eject"*)     quick_safe_eject ;;
            *"Device Info"*)    quick_device_info ;;
            *"Exit"*)
                echo ""
                log "========== USB TOOLKIT EXITED =========="
                exit 0
                ;;
            *) ;;
        esac

        ui_pause
    done
}

# ============================================================================
#  Launch
# ============================================================================

handle_cli_args "$@"
check_root
check_dependencies
acquire_lock || exit 1
log "========== USB TOOLKIT v${SCRIPT_VERSION} STARTED =========="
main_menu
