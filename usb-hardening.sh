#!/usr/bin/env bash
# ============================================================================
#  USB SECURITY MANAGER
#  Complete USB Device Security Management
#  Version:  2.0
#  Date:     2026-02-10
#  Tested:   Ubuntu 24.04 / Zorin OS
#  Usage:    sudo bash usb-hardening.sh
#
#  5 Categories:
#    1. USB Storage      — Block/unblock flash drives & disks (modprobe)
#    2. USB Automount    — Manage automatic mounting (udisks2)
#    3. USB Ports        — Full USB port enable/disable (kernel)
#    4. USB Guard Rules  — udev rules (allow/block specific devices)
#    5. USB Audit        — Current USB device audit & analysis
#
# ============================================================================

set -uo pipefail

# ============================================================================
#  Configuration
# ============================================================================

readonly SCRIPT_VERSION="2.0"
readonly LOG_FILE="/var/log/usb-hardening.log"

# File paths
readonly USB_STORAGE_BLACKLIST="/etc/modprobe.d/usb-storage-blacklist.conf"
readonly USB_UAS_BLACKLIST="/etc/modprobe.d/usb-uas-blacklist.conf"
readonly UDISKS2_OVERRIDE_DIR="/etc/systemd/system/udisks2.service.d"
readonly UDISKS2_OVERRIDE="${UDISKS2_OVERRIDE_DIR}/hardening.conf"
readonly UDISKS2_MOUNT_CONF="/etc/udisks2/mount_options.conf"
readonly UDEV_USB_BLOCK="/etc/udev/rules.d/10-usb-block.rules"
readonly UDEV_USB_WHITELIST="/etc/udev/rules.d/11-usb-whitelist.rules"
readonly UDEV_USB_LOG="/etc/udev/rules.d/90-usb-log.rules"

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

status_badge() {
    local label="$1"
    local is_active="$2"
    local desc_on="$3"
    local desc_off="$4"

    if [[ "$is_active" == "1" ]]; then
        printf "    ${RED}%-10s${NC} %-18s ${DIM}%s${NC}\n" "[BLOCKED]" "$label" "$desc_on"
    else
        printf "    ${GREEN}%-10s${NC} %-18s ${DIM}%s${NC}\n" "[OPEN]" "$label" "$desc_off"
    fi
}

confirm_action() {
    local msg="$1"
    echo ""
    read -rp "  ${msg} [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
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
    log "========== USB SECURITY MANAGER v${SCRIPT_VERSION} STARTED =========="
}

# ============================================================================
#  Status Display
# ============================================================================

show_full_status() {
    print_header "USB Security Status"

    # --- 1. USB Storage ---
    print_section "1" "USB Storage (Flash Drives / Disks)"

    local storage_blocked=0
    [[ -f "$USB_STORAGE_BLACKLIST" ]] && storage_blocked=1
    status_badge "USB Storage" "$storage_blocked" \
        "modprobe blacklist — flash drives/disks will not work" \
        "Flash drives allowed"

    local uas_blocked=0
    [[ -f "$USB_UAS_BLACKLIST" ]] && uas_blocked=1
    status_badge "USB UAS" "$uas_blocked" \
        "UAS (USB Attached SCSI) blocked" \
        "UAS allowed"

    if lsmod | grep -q usb_storage 2>/dev/null; then
        print_info "usb_storage module: loaded (active)"
    else
        print_info "usb_storage module: not loaded"
    fi

    # --- 2. Automount ---
    print_section "2" "USB Automount (udisks2)"

    local udisks_hardened=0
    [[ -f "$UDISKS2_OVERRIDE" ]] && udisks_hardened=1
    status_badge "udisks2 sandbox" "$udisks_hardened" \
        "Hardened — mount permission restricted" \
        "Normal mode"

    if systemctl is-active udisks2 &>/dev/null; then
        print_info "udisks2 service: active"
    else
        print_warn "udisks2 service: inactive"
    fi

    # --- 3. USB Ports ---
    print_section "3" "USB Ports (kernel authorization)"

    for bus in /sys/bus/usb/devices/usb*/; do
        [[ ! -d "$bus" ]] && continue
        local bus_name
        bus_name=$(basename "$bus")
        local auth_default
        auth_default=$(cat "${bus}/authorized_default" 2>/dev/null || echo "?")
        if [[ "$auth_default" == "0" ]]; then
            echo -e "    ${RED}[BLOCKED]${NC}  ${bus_name}: authorized_default=0 ${DIM}(new devices blocked)${NC}"
        else
            echo -e "    ${GREEN}[OPEN]${NC}     ${bus_name}: authorized_default=1 ${DIM}(all devices allowed)${NC}"
        fi
    done

    # --- 4. Guard Rules ---
    print_section "4" "USB Guard Rules (udev)"

    if [[ -f "$UDEV_USB_BLOCK" ]]; then
        echo -e "    ${RED}[ACTIVE]${NC}   USB block rule ${DIM}(new USB devices are blocked)${NC}"
    else
        echo -e "    ${GREEN}[NONE]${NC}     USB block rule ${DIM}(none — all devices allowed)${NC}"
    fi

    if [[ -f "$UDEV_USB_WHITELIST" ]]; then
        local wl_count
        wl_count=$(grep -c "^[^#]" "$UDEV_USB_WHITELIST" 2>/dev/null || echo "0")
        echo -e "    ${CYAN}[ACTIVE]${NC}   Whitelist ${DIM}(${wl_count} rules — permitted devices)${NC}"
    else
        echo -e "    ${GREEN}[NONE]${NC}     Whitelist ${DIM}(none)${NC}"
    fi

    if [[ -f "$UDEV_USB_LOG" ]]; then
        echo -e "    ${CYAN}[ACTIVE]${NC}   USB logging ${DIM}(recording new device connections)${NC}"
    else
        echo -e "    ${GREEN}[NONE]${NC}     USB logging ${DIM}(disabled)${NC}"
    fi

    # --- Connected devices ---
    print_section "5" "Connected USB Devices"

    local dev_count=0
    while IFS= read -r line; do
        # Skip root hubs
        if echo "$line" | grep -q "root hub"; then
            continue
        fi
        dev_count=$((dev_count + 1))
        local bus_id dev_id name
        bus_id=$(echo "$line" | grep -oP 'Bus \K\d+')
        dev_id=$(echo "$line" | grep -oP 'Device \K\d+')
        local vid_pid
        vid_pid=$(echo "$line" | grep -oP 'ID \K\S+')
        name=$(echo "$line" | sed 's/.*ID [0-9a-f:]* //')
        printf "    ${DIM}%s${NC}  %-12s  %s\n" "${vid_pid}" "Bus${bus_id}:Dev${dev_id}" "$name"
    done < <(lsusb 2>/dev/null)
    print_info "Total: ${dev_count} devices (excluding root hubs)"

    echo ""
}

# ============================================================================
#  Category 1: USB STORAGE
#  Blocks USB flash drives and external disks at the kernel module level.
#  Effect: usb-storage module cannot be loaded.
#  Blocked: flash drives, external HDD/SSD, USB SD card readers
#  Not blocked: keyboard, mouse, webcam, printer
# ============================================================================

storage_enable() {
    print_header "USB Storage — Enable"
    log "ACTION: USB Storage ENABLE"

    if [[ -f "$USB_STORAGE_BLACKLIST" ]]; then
        rm -f "$USB_STORAGE_BLACKLIST"
        print_ok "USB storage blacklist removed"
    else
        print_skip "USB storage blacklist did not exist"
    fi

    if [[ -f "$USB_UAS_BLACKLIST" ]]; then
        rm -f "$USB_UAS_BLACKLIST"
        print_ok "USB UAS blacklist removed"
    else
        print_skip "USB UAS blacklist did not exist"
    fi

    # Load module
    if ! lsmod | grep -q usb_storage; then
        modprobe usb_storage 2>/dev/null && print_ok "usb_storage module loaded" \
            || print_info "usb_storage will load after reboot"
    else
        print_skip "usb_storage already loaded"
    fi

    echo ""
    echo -e "  ${GREEN}${BOLD}  USB flash drives and external disks are now enabled.${NC}"
    echo ""
}

storage_disable() {
    print_header "USB Storage — Disable"
    log "ACTION: USB Storage DISABLE"

    # blacklist usb-storage
    if [[ -f "$USB_STORAGE_BLACKLIST" ]]; then
        print_skip "USB storage already blocked"
    else
        echo "blacklist usb-storage" > "$USB_STORAGE_BLACKLIST"
        print_ok "USB storage module blacklisted"
    fi

    # blacklist uas (USB Attached SCSI — some USB3 disks use this module)
    if [[ -f "$USB_UAS_BLACKLIST" ]]; then
        print_skip "USB UAS already blocked"
    else
        echo "blacklist uas" > "$USB_UAS_BLACKLIST"
        print_ok "USB UAS (USB3 SCSI) module blacklisted"
    fi

    # Unload module (if possible)
    if lsmod | grep -q usb_storage; then
        if rmmod usb_storage 2>/dev/null; then
            print_ok "usb_storage module unloaded immediately"
        else
            print_warn "usb_storage could not be unloaded (device in use) — will be blocked after reboot"
        fi
    fi

    echo ""
    echo -e "  ${RED}${BOLD}  USB flash drives and external disks are blocked.${NC}"
    echo -e "  ${DIM}  Keyboard, mouse and other HID devices still work.${NC}"
    echo ""
}

storage_menu() {
    print_header "Category 1: USB Storage (Flash Drives / Disks)"
    echo ""
    echo -e "  ${DIM}  USB mass storage module management at kernel level.${NC}"
    echo -e "  ${DIM}  Blocks: flash drives, external HDD/SSD, USB SD card reader${NC}"
    echo -e "  ${DIM}  Does not block: keyboard, mouse, webcam, printer${NC}"
    echo ""

    local status="Unblocked"
    [[ -f "$USB_STORAGE_BLACKLIST" ]] && status="Blocked"
    echo -e "  Current: ${BOLD}${status}${NC}"
    echo ""
    echo -e "    ${GREEN}1)${NC}  Enable  — Allow flash drives"
    echo -e "    ${RED}2)${NC}  Disable — Block flash drives"
    echo -e "    ${BLUE}0)${NC}  Back"
    echo ""
    read -rp "  Choice [0-2]: " choice

    case "$choice" in
        1) storage_enable ;;
        2) storage_disable ;;
        0) return ;;
        *) echo -e "  ${RED}Invalid choice${NC}" ;;
    esac
}

# ============================================================================
#  Category 2: USB AUTOMOUNT (udisks2)
#  udisks2 service sandbox hardening.
#  Effect: USB devices mount with root permissions
#          and user cannot access flash drive contents.
#  Useful for: servers where automount is not needed.
#  Issue on desktop: flash drive is visible but "Permission denied"
# ============================================================================

automount_enable() {
    print_header "USB Automount — Enable (Normal Mode)"
    log "ACTION: Automount ENABLE (remove udisks2 hardening)"

    # Remove udisks2 override
    if [[ -f "$UDISKS2_OVERRIDE" ]]; then
        rm -f "$UDISKS2_OVERRIDE"
        rmdir "$UDISKS2_OVERRIDE_DIR" 2>/dev/null || true
        print_ok "udisks2 sandbox override removed"
    else
        print_skip "udisks2 sandbox override did not exist"
    fi

    # Clean up stale mount points
    local user
    user="$(get_current_user)"
    if [[ -n "$user" && -d "/media/${user}" ]]; then
        local cleaned=0
        for mnt_dir in /media/"${user}"/*/; do
            [[ ! -d "$mnt_dir" ]] && continue
            if ! mountpoint -q "$mnt_dir" 2>/dev/null; then
                rm -rf "$mnt_dir"
                cleaned=$((cleaned + 1))
            fi
        done
        [[ $cleaned -gt 0 ]] && print_ok "Cleaned ${cleaned} stale mount points"
    fi

    # Restart udisks2
    systemctl daemon-reload
    if systemctl is-active udisks2 &>/dev/null; then
        systemctl restart udisks2 &>/dev/null
        print_ok "udisks2 restarted in normal mode"
    fi

    echo ""
    echo -e "  ${GREEN}${BOLD}  Automount restored.${NC}"
    echo -e "  ${DIM}  Remove and reinsert the flash drive.${NC}"
    echo ""
}

automount_disable() {
    print_header "USB Automount — Harden"
    log "ACTION: Automount DISABLE (add udisks2 hardening)"

    if [[ -f "$UDISKS2_OVERRIDE" ]]; then
        print_skip "udisks2 already hardened"
    else
        mkdir -p "$UDISKS2_OVERRIDE_DIR"
        cat > "$UDISKS2_OVERRIDE" << 'EOF'
[Service]
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
PrivateTmp=yes
NoNewPrivileges=yes
EOF
        print_ok "udisks2 sandbox override created"
    fi

    systemctl daemon-reload
    if systemctl is-active udisks2 &>/dev/null; then
        systemctl restart udisks2 &>/dev/null
        print_ok "udisks2 restarted in hardened mode"
    fi

    echo ""
    echo -e "  ${YELLOW}${BOLD}  udisks2 is hardened.${NC}"
    echo -e "  ${YELLOW}  Flash drive mount may encounter permission issues.${NC}"
    echo -e "  ${DIM}  To restore: sudo bash $0 → Category 2 → Enable${NC}"
    echo ""
}

automount_menu() {
    print_header "Category 2: USB Automount (udisks2 Service)"
    echo ""
    echo -e "  ${DIM}  udisks2 — automatic USB device mounting service.${NC}"
    echo -e "  ${DIM}  Hardening adds sandbox: ProtectHome, ProtectKernel, NoNewPrivileges${NC}"
    echo ""
    echo -e "  ${YELLOW}  Warning: After hardening, flash drive is visible but cannot be opened${NC}"
    echo -e "  ${YELLOW}  (\"Permission denied\"). This is expected — that's what hardening does.${NC}"
    echo ""

    local status="Normal"
    [[ -f "$UDISKS2_OVERRIDE" ]] && status="Hardened"
    echo -e "  Current: ${BOLD}${status}${NC}"
    echo ""
    echo -e "    ${GREEN}1)${NC}  Enable  — Normal automount (flash drive opens automatically)"
    echo -e "    ${RED}2)${NC}  Disable — Sandbox hardening (mount will have permission issues)"
    echo -e "    ${BLUE}0)${NC}  Back"
    echo ""
    read -rp "  Choice [0-2]: " choice

    case "$choice" in
        1) automount_enable ;;
        2) automount_disable ;;
        0) return ;;
        *) echo -e "  ${RED}Invalid choice${NC}" ;;
    esac
}

# ============================================================================
#  Category 3: USB PORTS (kernel-level authorization)
#  USB authorization management at the kernel level.
#  authorized_default=0 → new USB devices are not automatically enabled
#  Effect: all new USB devices (keyboard, mouse, flash drive) are blocked
#  Already connected devices continue to work.
#
#  Warning: If keyboard is USB, after disabling
#  connecting a new keyboard will be impossible!
# ============================================================================

ports_enable() {
    print_header "USB Ports — Enable (Allow All Devices)"
    log "ACTION: USB Ports ENABLE"

    for bus in /sys/bus/usb/devices/usb*/; do
        [[ ! -d "$bus" ]] && continue
        local bus_name
        bus_name=$(basename "$bus")
        echo 1 > "${bus}/authorized_default" 2>/dev/null
        print_ok "${bus_name}: authorized_default=1 (all devices allowed)"
    done

    # Persistent change — udev rule
    if [[ -f /etc/udev/rules.d/99-usb-deny.rules ]]; then
        rm -f /etc/udev/rules.d/99-usb-deny.rules
        print_ok "USB deny udev rule removed"
    fi

    udevadm control --reload-rules &>/dev/null
    udevadm trigger &>/dev/null

    echo ""
    echo -e "  ${GREEN}${BOLD}  USB ports are open — all devices allowed.${NC}"
    echo ""
}

ports_disable() {
    print_header "USB Ports — Disable (Block New Devices)"
    log "ACTION: USB Ports DISABLE"

    echo ""
    echo -e "  ${RED}${BOLD}  Warning!${NC}"
    echo -e "  ${RED}  This will block all new USB devices:${NC}"
    echo -e "  ${RED}  keyboard, mouse, flash drive, printer...${NC}"
    echo -e "  ${RED}  Already connected devices will continue to work.${NC}"

    if ! confirm_action "Do you want to continue?"; then
        echo -e "  ${YELLOW}Cancelled.${NC}"
        return
    fi

    for bus in /sys/bus/usb/devices/usb*/; do
        [[ ! -d "$bus" ]] && continue
        local bus_name
        bus_name=$(basename "$bus")
        echo 0 > "${bus}/authorized_default" 2>/dev/null
        print_ok "${bus_name}: authorized_default=0 (new devices blocked)"
    done

    # Persistent change — udev rule (persists after reboot)
    cat > /etc/udev/rules.d/99-usb-deny.rules << 'EOF'
# USB Security: Block new USB devices by default
# Created by usb-hardening.sh
# Remove this file to restore: sudo rm /etc/udev/rules.d/99-usb-deny.rules
ACTION=="add", ATTR{authorized_default}=="*", ATTR{authorized_default}="0"
EOF
    print_ok "Persistent udev rule created (persists after reboot)"

    udevadm control --reload-rules &>/dev/null

    echo ""
    echo -e "  ${RED}${BOLD}  New USB devices are blocked.${NC}"
    echo -e "  ${DIM}  To manually authorize: echo 1 > /sys/bus/usb/devices/<device>/authorized${NC}"
    echo ""
}

ports_authorize_device() {
    print_header "Manually Authorize USB Device"

    echo ""
    echo -e "  ${DIM}  Blocked devices list:${NC}"
    echo ""

    local found=0
    for dev in /sys/bus/usb/devices/*/; do
        [[ ! -f "${dev}/authorized" ]] && continue
        local auth
        auth=$(cat "${dev}/authorized" 2>/dev/null)
        [[ "$auth" != "0" ]] && continue

        found=$((found + 1))
        local dev_name
        dev_name=$(basename "$dev")
        local product manufacturer
        product=$(cat "${dev}/product" 2>/dev/null || echo "Unknown")
        manufacturer=$(cat "${dev}/manufacturer" 2>/dev/null || echo "Unknown")
        local vid pid
        vid=$(cat "${dev}/idVendor" 2>/dev/null || echo "????")
        pid=$(cat "${dev}/idProduct" 2>/dev/null || echo "????")

        echo -e "    ${RED}[BLOCKED]${NC}  ${dev_name}  ${vid}:${pid}  ${manufacturer} — ${product}"
    done

    if [[ $found -eq 0 ]]; then
        print_info "No blocked devices found."
        echo ""
        return
    fi

    echo ""
    read -rp "  Device name (e.g. 1-7.3): " dev_name

    if [[ -z "$dev_name" ]]; then
        echo -e "  ${YELLOW}Cancelled.${NC}"
        return
    fi

    local dev_path="/sys/bus/usb/devices/${dev_name}"
    if [[ ! -f "${dev_path}/authorized" ]]; then
        print_fail "Device '${dev_name}' not found"
        return
    fi

    echo 1 > "${dev_path}/authorized" 2>/dev/null
    print_ok "${dev_name} authorized"
    echo ""
}

ports_menu() {
    print_header "Category 3: USB Ports (kernel-level authorization)"
    echo ""
    echo -e "  ${DIM}  USB authorization at kernel level — for all device types.${NC}"
    echo -e "  ${DIM}  authorized_default=0 → new devices are automatically blocked.${NC}"
    echo -e "  ${DIM}  Already connected devices continue to work.${NC}"
    echo ""

    local all_open=1
    for bus in /sys/bus/usb/devices/usb*/; do
        [[ ! -d "$bus" ]] && continue
        local auth_def
        auth_def=$(cat "${bus}/authorized_default" 2>/dev/null || echo "1")
        [[ "$auth_def" == "0" ]] && all_open=0
    done

    if [[ $all_open -eq 1 ]]; then
        echo -e "  Current: ${GREEN}${BOLD}Open${NC} ${DIM}(all new devices allowed)${NC}"
    else
        echo -e "  Current: ${RED}${BOLD}Blocked${NC} ${DIM}(new devices are blocked)${NC}"
    fi

    echo ""
    echo -e "    ${GREEN}1)${NC}  Enable    — Open all USB ports"
    echo -e "    ${RED}2)${NC}  Disable   — Block new devices"
    echo -e "    ${CYAN}3)${NC}  Authorize — Manually allow a specific device"
    echo -e "    ${BLUE}0)${NC}  Back"
    echo ""
    read -rp "  Choice [0-3]: " choice

    case "$choice" in
        1) ports_enable ;;
        2) ports_disable ;;
        3) ports_authorize_device ;;
        0) return ;;
        *) echo -e "  ${RED}Invalid choice${NC}" ;;
    esac
}

# ============================================================================
#  Category 4: USB GUARD RULES (udev-based)
#  Block or allow specific USB devices using udev rules.
#  Vendor ID / Product ID (VID:PID) filtering.
#  USB device connection logging.
# ============================================================================

guard_enable_logging() {
    print_header "USB Logging — Enable"
    log "ACTION: USB Logging ENABLE"

    cat > "$UDEV_USB_LOG" << 'EOF'
# USB Security: Log all new USB device connections
# Created by usb-hardening.sh
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", \
    RUN+="/bin/sh -c 'echo \"USB CONNECT: $(date) vendor=$attr{idVendor} product=$attr{idProduct} serial=$attr{serial} manufacturer=$attr{manufacturer} product_name=$attr{product}\" >> /var/log/usb-events.log'"
ACTION=="remove", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", \
    RUN+="/bin/sh -c 'echo \"USB DISCONNECT: $(date) vendor=$attr{idVendor} product=$attr{idProduct}\" >> /var/log/usb-events.log'"
EOF

    touch /var/log/usb-events.log
    chmod 600 /var/log/usb-events.log

    udevadm control --reload-rules &>/dev/null
    print_ok "USB logging enabled → /var/log/usb-events.log"
    echo ""
}

guard_disable_logging() {
    print_header "USB Logging — Disable"
    log "ACTION: USB Logging DISABLE"

    if [[ -f "$UDEV_USB_LOG" ]]; then
        rm -f "$UDEV_USB_LOG"
        udevadm control --reload-rules &>/dev/null
        print_ok "USB logging udev rule removed"
    else
        print_skip "USB logging was not enabled"
    fi
    echo ""
}

guard_block_device() {
    print_header "Block Specific USB Device"

    echo ""
    echo -e "  ${DIM}  Connected devices:${NC}"
    echo ""

    while IFS= read -r line; do
        echo "$line" | grep -q "root hub" && continue
        local vid_pid
        vid_pid=$(echo "$line" | grep -oP 'ID \K\S+')
        local name
        name=$(echo "$line" | sed 's/.*ID [0-9a-f:]* //')
        echo -e "    ${BOLD}${vid_pid}${NC}  ${name}"
    done < <(lsusb 2>/dev/null)

    echo ""
    read -rp "  VID:PID to block (e.g. 0781:5567): " vidpid

    if [[ -z "$vidpid" ]]; then
        echo -e "  ${YELLOW}Cancelled.${NC}"
        return
    fi

    local vid pid
    vid=$(echo "$vidpid" | cut -d: -f1)
    pid=$(echo "$vidpid" | cut -d: -f2)

    if [[ -z "$vid" || -z "$pid" ]]; then
        print_fail "Invalid format. Use VID:PID (e.g. 0781:5567)"
        return
    fi

    # Add block rule
    local block_line="# Block ${vidpid}"$'\n'"ACTION==\"add\", ATTR{idVendor}==\"${vid}\", ATTR{idProduct}==\"${pid}\", RUN+=\"/bin/sh -c 'echo 0 > /sys\$devpath/authorized'\""

    if [[ -f "$UDEV_USB_BLOCK" ]]; then
        echo "" >> "$UDEV_USB_BLOCK"
        echo "$block_line" >> "$UDEV_USB_BLOCK"
    else
        {
            echo "# USB Security: Block specific USB devices"
            echo "# Created by usb-hardening.sh"
            echo ""
            echo "$block_line"
        } > "$UDEV_USB_BLOCK"
    fi

    udevadm control --reload-rules &>/dev/null
    print_ok "${vidpid} blocked (this device can no longer be used)"
    echo ""
}

guard_whitelist_device() {
    print_header "Add USB Device to Whitelist"

    echo ""
    echo -e "  ${DIM}  Connected devices:${NC}"
    echo ""

    while IFS= read -r line; do
        echo "$line" | grep -q "root hub" && continue
        local vid_pid
        vid_pid=$(echo "$line" | grep -oP 'ID \K\S+')
        local name
        name=$(echo "$line" | sed 's/.*ID [0-9a-f:]* //')
        echo -e "    ${BOLD}${vid_pid}${NC}  ${name}"
    done < <(lsusb 2>/dev/null)

    echo ""
    read -rp "  VID:PID to allow (e.g. 046d:c077): " vidpid

    if [[ -z "$vidpid" ]]; then
        echo -e "  ${YELLOW}Cancelled.${NC}"
        return
    fi

    local vid pid
    vid=$(echo "$vidpid" | cut -d: -f1)
    pid=$(echo "$vidpid" | cut -d: -f2)

    if [[ -z "$vid" || -z "$pid" ]]; then
        print_fail "Invalid format. Use VID:PID (e.g. 046d:c077)"
        return
    fi

    local wl_line="# Allow ${vidpid}"$'\n'"ACTION==\"add\", ATTR{idVendor}==\"${vid}\", ATTR{idProduct}==\"${pid}\", ATTR{authorized}=\"1\""

    if [[ -f "$UDEV_USB_WHITELIST" ]]; then
        echo "" >> "$UDEV_USB_WHITELIST"
        echo "$wl_line" >> "$UDEV_USB_WHITELIST"
    else
        {
            echo "# USB Security: Whitelisted USB devices (allowed even when ports blocked)"
            echo "# Created by usb-hardening.sh"
            echo ""
            echo "$wl_line"
        } > "$UDEV_USB_WHITELIST"
    fi

    udevadm control --reload-rules &>/dev/null
    print_ok "${vidpid} added to whitelist (always allowed)"
    echo ""
}

guard_clear_rules() {
    print_header "USB Guard Rules — Clear All"
    log "ACTION: Guard Rules CLEAR"

    local removed=0

    if [[ -f "$UDEV_USB_BLOCK" ]]; then
        rm -f "$UDEV_USB_BLOCK"
        print_ok "USB block rules removed"
        removed=$((removed + 1))
    fi

    if [[ -f "$UDEV_USB_WHITELIST" ]]; then
        rm -f "$UDEV_USB_WHITELIST"
        print_ok "USB whitelist rules removed"
        removed=$((removed + 1))
    fi

    if [[ -f "$UDEV_USB_LOG" ]]; then
        rm -f "$UDEV_USB_LOG"
        print_ok "USB logging rule removed"
        removed=$((removed + 1))
    fi

    if [[ $removed -eq 0 ]]; then
        print_skip "No rules existed"
    else
        udevadm control --reload-rules &>/dev/null
        udevadm trigger &>/dev/null
        print_ok "udev rules reloaded"
    fi
    echo ""
}

guard_show_rules() {
    print_header "Active USB Guard Rules"

    echo ""
    if [[ -f "$UDEV_USB_BLOCK" ]]; then
        echo -e "  ${RED}${BOLD}Block Rules:${NC} ${UDEV_USB_BLOCK}"
        echo -e "  ${DIM}$(cat "$UDEV_USB_BLOCK" | grep -v "^#" | grep -v "^$" | sed 's/^/    /')${NC}"
        echo ""
    fi

    if [[ -f "$UDEV_USB_WHITELIST" ]]; then
        echo -e "  ${GREEN}${BOLD}Whitelist Rules:${NC} ${UDEV_USB_WHITELIST}"
        echo -e "  ${DIM}$(cat "$UDEV_USB_WHITELIST" | grep -v "^#" | grep -v "^$" | sed 's/^/    /')${NC}"
        echo ""
    fi

    if [[ -f "$UDEV_USB_LOG" ]]; then
        echo -e "  ${CYAN}${BOLD}Logging:${NC} ${UDEV_USB_LOG}"
        if [[ -f /var/log/usb-events.log ]]; then
            local log_lines
            log_lines=$(wc -l < /var/log/usb-events.log 2>/dev/null || echo "0")
            echo -e "  ${DIM}  Log entries: ${log_lines}${NC}"
            if [[ "$log_lines" -gt 0 ]]; then
                echo -e "  ${DIM}  Last 5:${NC}"
                tail -5 /var/log/usb-events.log 2>/dev/null | sed 's/^/    /'
            fi
        fi
        echo ""
    fi

    if [[ ! -f "$UDEV_USB_BLOCK" && ! -f "$UDEV_USB_WHITELIST" && ! -f "$UDEV_USB_LOG" ]]; then
        print_info "No USB Guard Rules exist — all devices are allowed."
    fi
    echo ""
}

guard_menu() {
    print_header "Category 4: USB Guard Rules (udev-based)"
    echo ""
    echo -e "  ${DIM}  Block/allow specific USB devices by VID:PID.${NC}"
    echo -e "  ${DIM}  USB device connect/disconnect logging.${NC}"
    echo ""
    echo -e "    ${RED}1)${NC}  Block specific device (VID:PID)"
    echo -e "    ${GREEN}2)${NC}  Add device to whitelist (VID:PID)"
    echo -e "    ${CYAN}3)${NC}  Enable USB logging"
    echo -e "    ${CYAN}4)${NC}  Disable USB logging"
    echo -e "    ${MAGENTA}5)${NC}  View active rules"
    echo -e "    ${YELLOW}6)${NC}  Clear all rules"
    echo -e "    ${BLUE}0)${NC}  Back"
    echo ""
    read -rp "  Choice [0-6]: " choice

    case "$choice" in
        1) guard_block_device ;;
        2) guard_whitelist_device ;;
        3) guard_enable_logging ;;
        4) guard_disable_logging ;;
        5) guard_show_rules ;;
        6) guard_clear_rules ;;
        0) return ;;
        *) echo -e "  ${RED}Invalid choice${NC}" ;;
    esac
}

# ============================================================================
#  Category 5: USB AUDIT
#  Full audit and analysis of currently connected USB devices
# ============================================================================

do_audit() {
    print_header "Category 5: USB Device Audit"

    # Connected devices
    print_section "A" "Connected USB Devices (Detailed)"

    for dev in /sys/bus/usb/devices/*/; do
        [[ ! -f "${dev}/idVendor" ]] && continue

        local dev_name
        dev_name=$(basename "$dev")
        local vid pid product manufacturer serial authorized bus_num dev_num
        vid=$(cat "${dev}/idVendor" 2>/dev/null || echo "????")
        pid=$(cat "${dev}/idProduct" 2>/dev/null || echo "????")
        product=$(cat "${dev}/product" 2>/dev/null || echo "N/A")
        manufacturer=$(cat "${dev}/manufacturer" 2>/dev/null || echo "N/A")
        serial=$(cat "${dev}/serial" 2>/dev/null || echo "N/A")
        authorized=$(cat "${dev}/authorized" 2>/dev/null || echo "?")
        bus_num=$(cat "${dev}/busnum" 2>/dev/null || echo "?")
        dev_num=$(cat "${dev}/devnum" 2>/dev/null || echo "?")
        local dev_class
        dev_class=$(cat "${dev}/bDeviceClass" 2>/dev/null || echo "??")

        local auth_color="$GREEN"
        local auth_label="ALLOWED"
        if [[ "$authorized" == "0" ]]; then
            auth_color="$RED"
            auth_label="BLOCKED"
        fi

        echo -e "    ${BOLD}${vid}:${pid}${NC}  ${manufacturer} — ${product}"
        echo -e "      ${DIM}Device: ${dev_name} | Bus: ${bus_num} | Dev: ${dev_num} | Class: ${dev_class}${NC}"
        echo -e "      ${DIM}Serial: ${serial}${NC}"
        echo -e "      ${auth_color}Status: ${auth_label}${NC}"
        echo ""
    done

    # USB bus status
    print_section "B" "USB Bus Authorization Policy"

    for bus in /sys/bus/usb/devices/usb*/; do
        [[ ! -d "$bus" ]] && continue
        local bus_name
        bus_name=$(basename "$bus")
        local auth_def
        auth_def=$(cat "${bus}/authorized_default" 2>/dev/null || echo "?")
        local speed
        speed=$(cat "${bus}/speed" 2>/dev/null || echo "?")

        if [[ "$auth_def" == "1" ]]; then
            echo -e "    ${GREEN}${bus_name}${NC}: authorized_default=${auth_def} (OPEN) | Speed: ${speed} Mbps"
        else
            echo -e "    ${RED}${bus_name}${NC}: authorized_default=${auth_def} (BLOCKED) | Speed: ${speed} Mbps"
        fi
    done

    # kernel modules
    print_section "C" "USB Kernel Modules"

    local modules=("usb_storage" "uas" "usbhid" "usbcore" "ehci_hcd" "xhci_hcd" "ohci_hcd" "uhci_hcd")
    for mod in "${modules[@]}"; do
        if lsmod | grep -q "^${mod} " 2>/dev/null; then
            echo -e "    ${GREEN}[LOADED]${NC}    ${mod}"
        else
            echo -e "    ${DIM}[NOT LOADED]${NC} ${mod}"
        fi
    done

    # blacklist files
    print_section "D" "USB-related Blacklist Files"

    local bl_files=("$USB_STORAGE_BLACKLIST" "$USB_UAS_BLACKLIST")
    for f in "${bl_files[@]}"; do
        if [[ -f "$f" ]]; then
            echo -e "    ${RED}[EXISTS]${NC}  ${f}"
            echo -e "    ${DIM}           $(cat "$f" 2>/dev/null)${NC}"
        fi
    done

    local other_bl
    other_bl=$(grep -rl "usb" /etc/modprobe.d/ 2>/dev/null | grep -v "$USB_STORAGE_BLACKLIST" | grep -v "$USB_UAS_BLACKLIST")
    if [[ -n "$other_bl" ]]; then
        for f in $other_bl; do
            echo -e "    ${YELLOW}[OTHER]${NC}   ${f}"
        done
    fi

    if [[ ! -f "$USB_STORAGE_BLACKLIST" && ! -f "$USB_UAS_BLACKLIST" && -z "$other_bl" ]]; then
        echo -e "    ${GREEN}[NONE]${NC}    No USB blacklist files found"
    fi

    echo ""
}

# ============================================================================
#  Quick Actions: Enable / Disable Everything
# ============================================================================

quick_lockdown() {
    print_header "LOCKDOWN — Full Hardening"
    log "ACTION: FULL LOCKDOWN"

    echo ""
    echo -e "  ${RED}${BOLD}  Full USB lockdown will:${NC}"
    echo -e "  ${RED}    1. Block USB storage (flash drives/disks)${NC}"
    echo -e "  ${RED}    2. Harden udisks2 sandbox${NC}"
    echo -e "  ${RED}    3. Enable USB logging${NC}"

    if ! confirm_action "Proceed with full lockdown?"; then
        echo -e "  ${YELLOW}Cancelled.${NC}"
        return
    fi

    echo ""

    # 1. Storage
    if [[ ! -f "$USB_STORAGE_BLACKLIST" ]]; then
        echo "blacklist usb-storage" > "$USB_STORAGE_BLACKLIST"
        print_ok "USB storage blocked"
    else
        print_skip "USB storage was already blocked"
    fi

    if [[ ! -f "$USB_UAS_BLACKLIST" ]]; then
        echo "blacklist uas" > "$USB_UAS_BLACKLIST"
        print_ok "USB UAS blocked"
    else
        print_skip "USB UAS was already blocked"
    fi

    # 2. Automount
    if [[ ! -f "$UDISKS2_OVERRIDE" ]]; then
        mkdir -p "$UDISKS2_OVERRIDE_DIR"
        cat > "$UDISKS2_OVERRIDE" << 'EOF'
[Service]
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
PrivateTmp=yes
NoNewPrivileges=yes
EOF
        print_ok "udisks2 hardened"
    else
        print_skip "udisks2 was already hardened"
    fi

    # 3. Logging
    if [[ ! -f "$UDEV_USB_LOG" ]]; then
        cat > "$UDEV_USB_LOG" << 'EOF'
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", \
    RUN+="/bin/sh -c 'echo \"USB CONNECT: $(date) vendor=$attr{idVendor} product=$attr{idProduct} serial=$attr{serial} manufacturer=$attr{manufacturer} product_name=$attr{product}\" >> /var/log/usb-events.log'"
ACTION=="remove", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", \
    RUN+="/bin/sh -c 'echo \"USB DISCONNECT: $(date) vendor=$attr{idVendor} product=$attr{idProduct}\" >> /var/log/usb-events.log'"
EOF
        touch /var/log/usb-events.log && chmod 600 /var/log/usb-events.log
        print_ok "USB logging enabled"
    else
        print_skip "USB logging was already enabled"
    fi

    # Reload
    systemctl daemon-reload
    systemctl restart udisks2 &>/dev/null 2>&1 || true
    udevadm control --reload-rules &>/dev/null
    udevadm trigger &>/dev/null

    echo ""
    echo -e "  ${RED}${BOLD}  LOCKDOWN enabled.${NC}"
    echo -e "  ${DIM}  To restore: sudo bash $0 → Option 7 (Unlock All)${NC}"
    echo ""
}

quick_unlock() {
    print_header "UNLOCK ALL — Restore Everything"
    log "ACTION: FULL UNLOCK"

    echo ""

    # 1. Storage
    [[ -f "$USB_STORAGE_BLACKLIST" ]] && rm -f "$USB_STORAGE_BLACKLIST" && print_ok "USB storage blacklist removed"
    [[ -f "$USB_UAS_BLACKLIST" ]] && rm -f "$USB_UAS_BLACKLIST" && print_ok "USB UAS blacklist removed"

    if ! lsmod | grep -q usb_storage; then
        modprobe usb_storage 2>/dev/null && print_ok "usb_storage module loaded" || true
    fi

    # 2. Automount
    if [[ -f "$UDISKS2_OVERRIDE" ]]; then
        rm -f "$UDISKS2_OVERRIDE"
        rmdir "$UDISKS2_OVERRIDE_DIR" 2>/dev/null || true
        print_ok "udisks2 sandbox override removed"
    fi

    # 3. USB Ports
    for bus in /sys/bus/usb/devices/usb*/; do
        [[ ! -d "$bus" ]] && continue
        echo 1 > "${bus}/authorized_default" 2>/dev/null
    done
    [[ -f /etc/udev/rules.d/99-usb-deny.rules ]] && rm -f /etc/udev/rules.d/99-usb-deny.rules && print_ok "USB deny rule removed"
    print_ok "USB ports opened"

    # 4. Guard rules
    [[ -f "$UDEV_USB_BLOCK" ]] && rm -f "$UDEV_USB_BLOCK" && print_ok "USB block rules removed"
    [[ -f "$UDEV_USB_WHITELIST" ]] && rm -f "$UDEV_USB_WHITELIST" && print_ok "USB whitelist rules removed"
    [[ -f "$UDEV_USB_LOG" ]] && rm -f "$UDEV_USB_LOG" && print_ok "USB logging rule removed"

    # 5. Mount point cleanup
    local user
    user="$(get_current_user)"
    if [[ -n "$user" && -d "/media/${user}" ]]; then
        for mnt_dir in /media/"${user}"/*/; do
            [[ ! -d "$mnt_dir" ]] && continue
            if ! mountpoint -q "$mnt_dir" 2>/dev/null; then
                rm -rf "$mnt_dir"
            fi
        done
        print_ok "Stale mount points cleaned"
    fi

    # Reload
    systemctl daemon-reload
    systemctl restart udisks2 &>/dev/null 2>&1 || true
    udevadm control --reload-rules &>/dev/null
    udevadm trigger &>/dev/null
    print_ok "udev and systemd reloaded"

    echo ""
    echo -e "  ${GREEN}${BOLD}  Everything restored!${NC}"
    echo -e "  ${GREEN}  USB devices are fully operational.${NC}"
    echo -e "  ${DIM}  Remove and reinsert the flash drive.${NC}"
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
        echo "  ║          USB SECURITY MANAGER v${SCRIPT_VERSION}                    ║"
        echo "  ║                                                           ║"
        echo "  ╚═══════════════════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo -e "  ${DIM}$(date '+%Y-%m-%d %H:%M:%S') | $(hostname) | $(uname -r)${NC}"

        show_full_status

        echo -e "${BOLD}  Categories:${NC}"
        echo ""
        echo -e "    ${GREEN}1)${NC}  USB Storage      ${DIM}— Enable/disable flash drives & disks${NC}"
        echo -e "    ${GREEN}2)${NC}  USB Automount    ${DIM}— Manage udisks2 mount service${NC}"
        echo -e "    ${GREEN}3)${NC}  USB Ports        ${DIM}— Kernel-level USB port blocking${NC}"
        echo -e "    ${GREEN}4)${NC}  USB Guard Rules  ${DIM}— Block/allow specific devices${NC}"
        echo -e "    ${CYAN}5)${NC}  USB Audit        ${DIM}— Full device audit & analysis${NC}"
        echo ""
        echo -e "  ${BOLD}Quick Actions:${NC}"
        echo ""
        echo -e "    ${RED}6)${NC}  LOCKDOWN         ${DIM}— Harden everything in one step${NC}"
        echo -e "    ${GREEN}7)${NC}  UNLOCK ALL       ${DIM}— Restore everything in one step${NC}"
        echo ""
        echo -e "    ${BLUE}0)${NC}  Exit"
        echo ""
        read -rp "  Choice [0-7]: " choice

        case "$choice" in
            1) storage_menu ;;
            2) automount_menu ;;
            3) ports_menu ;;
            4) guard_menu ;;
            5) do_audit ;;
            6) quick_lockdown ;;
            7) quick_unlock ;;
            0)
                echo ""
                log "========== USB SECURITY MANAGER EXITED =========="
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
main_menu
