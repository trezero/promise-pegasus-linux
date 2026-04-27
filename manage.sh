#!/usr/bin/env bash
# Pegasus3-R management CLI — status, diagnostics, maintenance.
# See docs/ for full setup procedure.
set -u

# ---- Hard-coded deployment values (edit here if drive is reconfigured) ----
DEV_DISK="/dev/sda"
DEV_PART="/dev/sda1"
MOUNT_POINT="/media/pegasus"
FS_LABEL="pegasus_raid"
FS_UUID="833dd228-35bf-4069-94f9-d98f215b8092"
TB_UUID="c9030000-0000-7d18-a271-27c448213116"
PCI_ADDR="0000:9f:00.0"
PCI_VENDOR_DEVICE="105a:8870"
PCI_VENDOR="105a"
SCSI_DRIVER="stex"
FS_TYPE="ext4"
KERNEL_PARAM="pci=realloc"

# ---- Colors (disabled when stdout is not a TTY) ----
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'
    C_BOLD=$'\033[1m'
else
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""
fi

ok()   { printf '%s[ OK ]%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
fail() { printf '%s[FAIL]%s %s\n' "$C_RED"    "$C_RESET" "$*"; }
hdr()  { printf '\n%s%s== %s ==%s\n' "$C_CYAN" "$C_BOLD" "$*" "$C_RESET"; }
info() { printf '       %s\n' "$*"; }

trap 'warn "Unexpected error on line $LINENO (continuing)"' ERR

pause() {
    printf '\n%sPress Enter to continue...%s' "$C_CYAN" "$C_RESET"
    read -r _ || true
}

confirm_yes() {
    local prompt="$1" reply
    printf '%s%s%s [y/N] ' "$C_YELLOW" "$prompt" "$C_RESET"
    read -r reply || reply=""
    [[ "$reply" == "y" ]]
}

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        warn "Missing command: $1"
        return 1
    fi
    return 0
}

# ---- Status checks (return 0=ok, 1=warn, 2=fail) ----

check_thunderbolt() {
    hdr "Thunderbolt link"
    if ! need_cmd boltctl; then
        fail "boltctl not installed"
        return 2
    fi
    local out
    out="$(boltctl 2>&1 || true)"
    printf '%s\n' "$out"
    if printf '%s' "$out" | grep -q "$TB_UUID"; then
        if printf '%s' "$out" | awk -v u="$TB_UUID" '
            $0 ~ u {found=1}
            found && /status:/ {print; exit}
        ' | grep -q "authorized"; then
            ok "Thunderbolt device $TB_UUID is authorized"
            return 0
        else
            warn "Thunderbolt device $TB_UUID present but not authorized"
            return 1
        fi
    else
        fail "Thunderbolt device $TB_UUID not present"
        return 2
    fi
}

check_pci() {
    hdr "PCI controller health"
    if ! need_cmd lspci; then
        fail "lspci not installed"
        return 2
    fi
    local line
    line="$(lspci -nn -d "${PCI_VENDOR}:" 2>/dev/null || true)"
    if [[ -z "$line" ]]; then
        fail "No PCI device for vendor ${PCI_VENDOR} found"
        return 2
    fi
    printf '%s\n' "$line"
    if printf '%s' "$line" | grep -qi "rev ff"; then
        fail "Controller at $PCI_ADDR shows rev=ff (config space unreadable — WEDGED)"
        return 2
    fi
    if printf '%s' "$line" | grep -q "$PCI_VENDOR_DEVICE"; then
        ok "Controller $PCI_VENDOR_DEVICE present, config space readable"
    else
        warn "PCI device for vendor ${PCI_VENDOR} found but device id differs from $PCI_VENDOR_DEVICE"
    fi
    if [[ -e "/sys/bus/pci/devices/${PCI_ADDR}/driver" ]]; then
        local drv
        drv="$(basename "$(readlink -f "/sys/bus/pci/devices/${PCI_ADDR}/driver")")"
        if [[ "$drv" == "$SCSI_DRIVER" ]]; then
            ok "Bound to kernel driver: $drv"
        else
            warn "Bound to unexpected driver: $drv (expected $SCSI_DRIVER)"
            return 1
        fi
    else
        warn "No driver bound at $PCI_ADDR"
        return 1
    fi
    return 0
}

check_block_device() {
    hdr "Block device + partition"
    if [[ ! -b "$DEV_DISK" ]]; then
        fail "$DEV_DISK is not a block device"
        return 2
    fi
    ok "$DEV_DISK present"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINT "$DEV_DISK" 2>&1 || true
    if [[ ! -b "$DEV_PART" ]]; then
        fail "$DEV_PART partition missing"
        return 2
    fi
    printf '\n'
    sudo parted -s "$DEV_DISK" print 2>&1 || warn "parted print failed"
    return 0
}

check_filesystem() {
    hdr "Filesystem details"
    if ! need_cmd tune2fs; then
        fail "tune2fs not installed"
        return 2
    fi
    if [[ ! -b "$DEV_PART" ]]; then
        fail "$DEV_PART not present"
        return 2
    fi
    sudo tune2fs -l "$DEV_PART" 2>&1 | grep -E "Filesystem (UUID|volume name|features|state)|Inode count|Block count|Last (mount|write|check)|Mount count" || warn "tune2fs returned no expected fields"
    return 0
}

check_capacity() {
    hdr "Capacity / inode usage"
    if mountpoint -q "$MOUNT_POINT"; then
        df -h "$MOUNT_POINT" 2>&1 || true
        printf '\n'
        df -i "$MOUNT_POINT" 2>&1 || true
        # warn if inodes >80% used
        local ipct
        ipct="$(df -i "$MOUNT_POINT" --output=ipcent 2>/dev/null | tail -n1 | tr -dc '0-9')"
        if [[ -n "${ipct:-}" && "$ipct" -gt 80 ]]; then
            warn "Inode usage above 80% (${ipct}%)"
            return 1
        fi
        ok "Capacity check complete"
        return 0
    else
        warn "$MOUNT_POINT is not mounted — capacity unavailable"
        return 1
    fi
}

check_dmesg_recent() {
    hdr "Recent kernel logs (thunderbolt / stex / sda)"
    if ! need_cmd dmesg; then
        fail "dmesg not available"
        return 2
    fi
    sudo dmesg -T 2>/dev/null | grep -iE "thunderbolt|\bstex\b|\bsda\b" | tail -n 40 || info "No matching dmesg entries"
    return 0
}

check_mount() {
    hdr "Mount status"
    if mountpoint -q "$MOUNT_POINT"; then
        ok "Mounted: $(findmnt -n -o SOURCE,TARGET,FSTYPE,OPTIONS "$MOUNT_POINT")"
        return 0
    else
        warn "$MOUNT_POINT not mounted"
        return 1
    fi
}

check_pci_realloc() {
    hdr "Kernel arg: $KERNEL_PARAM"
    info "/proc/cmdline: $(cat /proc/cmdline)"
    if grep -qw "$KERNEL_PARAM" /proc/cmdline; then
        ok "$KERNEL_PARAM is active"
        return 0
    else
        fail "$KERNEL_PARAM NOT in /proc/cmdline — add to GRUB_CMDLINE_LINUX_DEFAULT and update-grub"
        return 1
    fi
}

check_boltctl_enrolled() {
    hdr "Thunderbolt enrollment policy"
    if ! need_cmd boltctl; then
        fail "boltctl not installed"
        return 2
    fi
    local out
    out="$(boltctl 2>&1 || true)"
    if ! printf '%s' "$out" | grep -q "$TB_UUID"; then
        fail "Device $TB_UUID not visible to boltctl"
        return 2
    fi
    local block
    block="$(printf '%s\n' "$out" | awk -v u="$TB_UUID" 'BEGIN{p=0} $0 ~ u {p=1} p {print} p && /^$/ {exit}')"
    printf '%s\n' "$block"
    local has_iommu=0 has_stored=0
    printf '%s' "$block" | grep -q "policy:.*iommu" && has_iommu=1
    printf '%s' "$block" | grep -qi "stored:" && has_stored=1
    if [[ $has_iommu -eq 1 && $has_stored -eq 1 ]]; then
        ok "Enrolled with policy=iommu and stored entry present"
        return 0
    fi
    warn "Enrollment incomplete (policy=iommu:$has_iommu  stored:$has_stored)"
    return 1
}

check_dmesg_failure_pattern() {
    hdr "dmesg failure pattern (firmware not operational / handshake failed)"
    if ! need_cmd dmesg; then
        fail "dmesg not available"
        return 2
    fi
    local matches
    matches="$(sudo dmesg -T 2>/dev/null | grep -E "stex.*firmware not operational|stex.*handshake failed" || true)"
    if [[ -n "$matches" ]]; then
        warn "Failure pattern present in dmesg buffer:"
        printf '%s\n' "$matches" | tail -n 20
        return 1
    fi
    ok "No firmware-not-operational / handshake-failed events in dmesg buffer"
    return 0
}

check_fstab() {
    hdr "fstab entry"
    if grep -q "$FS_UUID" /etc/fstab; then
        ok "fstab references UUID $FS_UUID"
        grep "$FS_UUID" /etc/fstab
        return 0
    else
        warn "No fstab entry for UUID $FS_UUID"
        info "Recommended: UUID=${FS_UUID}  ${MOUNT_POINT}  ${FS_TYPE}  defaults,nofail,x-systemd.device-timeout=10  0  2"
        return 1
    fi
}

# ---- Menu actions ----

do_show_thunderbolt() { check_thunderbolt || true; pause; }
do_show_pci()         { check_pci || true; pause; }
do_show_block()       { check_block_device || true; pause; }
do_show_fs()          { check_filesystem || true; pause; }
do_show_capacity()    { check_capacity || true; pause; }
do_show_dmesg()       { check_dmesg_recent || true; pause; }

do_mount() {
    hdr "Mount $DEV_PART at $MOUNT_POINT"
    if mountpoint -q "$MOUNT_POINT"; then
        warn "Already mounted"
        pause; return
    fi
    [[ -d "$MOUNT_POINT" ]] || sudo mkdir -p "$MOUNT_POINT"
    if sudo mount "$DEV_PART" "$MOUNT_POINT"; then
        ok "Mounted"
    else
        fail "mount failed"
    fi
    pause
}

do_unmount() {
    hdr "Unmount $MOUNT_POINT"
    if ! mountpoint -q "$MOUNT_POINT"; then
        warn "Not mounted"
        pause; return
    fi
    if sudo umount "$MOUNT_POINT"; then
        ok "Unmounted"
    else
        fail "umount failed (busy?)  Use 'lsof $MOUNT_POINT' to find holders"
    fi
    pause
}

do_verify_fstab()      { check_fstab || true; pause; }
do_verify_pci_realloc(){ check_pci_realloc || true; pause; }
do_verify_enrollment() { check_boltctl_enrolled || true; pause; }
do_check_failure()     { check_dmesg_failure_pattern || true; pause; }

do_fsck() {
    hdr "Offline fsck of $DEV_PART"
    cat <<EOF
This will run: sudo fsck.ext4 -fy $DEV_PART

Requirements:
  - $MOUNT_POINT MUST be unmounted first
  - On a 16 TiB filesystem this can take 30 minutes to several hours
  - Do not interrupt; do not disconnect Thunderbolt cable

EOF
    if mountpoint -q "$MOUNT_POINT"; then
        fail "$MOUNT_POINT is currently mounted. Unmount first (option 9)."
        pause; return
    fi
    if ! confirm_yes "Proceed with fsck?"; then
        info "Cancelled"
        pause; return
    fi
    sudo fsck.ext4 -fy "$DEV_PART"
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        ok "fsck clean"
    elif [[ $rc -eq 1 ]]; then
        warn "fsck corrected errors (rc=1)"
    else
        fail "fsck rc=$rc — manual review needed"
    fi
    pause
}

do_led_card() {
    hdr "Promise Pegasus3-R LED / Audible Alarm Reference"
    cat <<'EOF'
Audible alarms:
  - Two quick beeps (not repeated):     Normal — power-up / ready
  - Two beeps continuously repeated:    Critical subsystem problem;
                                        check System Status + Drive LEDs

System Status LED (the power button on front):
  - Blue:    Normal operation
  - Orange:  Booting up or shutting down
  - Red:     Serious problem — incomplete array or failed drive

Drive Carrier LEDs (per bay):
  - Solid Blue:                Power present, drive functioning normally
  - Flashing Blue:             Normal read/write activity
  - Blinking Blue + Orange:    Rebuilding, OR "Locate" triggered in software
  - Red:                       Drive error or failure

Environmental halt triggers:
  - <13 cm (5 in) clearance behind unit -> overheating shutdown
  - Ambient >35 C / 95 F        -> drive failure / controller malfunction

If the unit is completely silent and dark on power-up, suspect PSU or
the rear power switch.  If LEDs are normal but the host cannot see the
device, problem is on the Thunderbolt / PCI side, not the enclosure.
EOF
    pause
}

do_pci_hotremove() {
    hdr "PCI hot-remove + rescan (RECOVERY)"
    cat <<EOF
This will run:
  echo 1 | sudo tee /sys/bus/pci/devices/${PCI_ADDR}/remove
  echo 1 | sudo tee /sys/bus/pci/rescan

WARNING:
  - If the controller is wedged (rev=ff), the 'remove' write commonly
    hangs in uninterruptible (D) state. Ctrl-C will NOT recover the
    process and a reboot may be required.
  - The reliable recovery for a wedged Pegasus is: power-cycle the
    enclosure (rear switch off, wait 10 s, on) AND reboot the host.
  - Use this option only if you understand both warnings above.
EOF
    if ! confirm_yes "Proceed with PCI hot-remove?"; then
        info "Cancelled"
        pause; return
    fi
    info "Removing $PCI_ADDR ..."
    if echo 1 | sudo tee "/sys/bus/pci/devices/${PCI_ADDR}/remove" >/dev/null; then
        ok "remove write returned"
    else
        fail "remove write failed"
        pause; return
    fi
    sleep 2
    info "Rescanning PCI bus ..."
    if echo 1 | sudo tee /sys/bus/pci/rescan >/dev/null; then
        ok "rescan write returned"
    else
        fail "rescan write failed"
    fi
    sleep 2
    info "Re-checking controller:"
    lspci -nn -d "${PCI_VENDOR}:" || true
    pause
}

do_recovery_steps() {
    hdr "Recovery procedure for a wedged Pegasus controller"
    cat <<EOF
Symptoms of a wedged controller:
  - dmesg shows "stex: firmware not operational" or "handshake failed"
  - lspci shows "(rev ff)" for vendor 105a
  - I/O on $MOUNT_POINT hangs in D-state
  - boltctl may still show the device as authorized (Thunderbolt link
    is independent of the SCSI controller state)

Reliable recovery (do these IN ORDER):
  1. Stop new I/O.  If a process is hung in D-state, do not try to
     kill -9 it; it will not respond.
  2. If safely possible, sync filesystems on other disks:
        sync
  3. Power-cycle the Pegasus enclosure:
        - press the front power button to start a graceful shutdown,
          OR if unresponsive, use the rear hard switch
        - wait at least 10 seconds with all LEDs dark
        - power back on; wait for the System Status LED to go solid blue
  4. Reboot the host:
        sudo reboot
     A simple unmount/remount is NOT enough — the kernel SCSI layer
     keeps the dead host attached until reboot.
  5. After reboot, run option 1 (Show full status) to confirm OK.

Optional (lower-success) attempts before reboot:
  - Option 16 in this menu (PCI hot-remove + rescan).  May hang.
  - sudo modprobe -r stex && sudo modprobe stex
        Often blocked because the module is in use by the wedged host.

Prevention:
  - Keep $KERNEL_PARAM in GRUB_CMDLINE_LINUX_DEFAULT (option 11).
  - Maintain >=13 cm clearance behind enclosure; ambient <35 C.
  - Avoid sleep/suspend on the host while Pegasus is mounted.
EOF
    pause
}

do_status_full() {
    local tb_rc pci_rc blk_rc mnt_rc cap_rc realloc_rc fstab_rc dmesg_rc enroll_rc
    tb_rc=0; pci_rc=0; blk_rc=0; mnt_rc=0; cap_rc=0
    realloc_rc=0; fstab_rc=0; dmesg_rc=0; enroll_rc=0

    check_thunderbolt;          tb_rc=$?
    check_boltctl_enrolled;     enroll_rc=$?
    check_pci;                  pci_rc=$?
    check_block_device;         blk_rc=$?
    check_filesystem;           : # informational only
    check_mount;                mnt_rc=$?
    check_capacity;             cap_rc=$?
    check_pci_realloc;          realloc_rc=$?
    check_fstab;                fstab_rc=$?
    check_dmesg_failure_pattern; dmesg_rc=$?

    hdr "Summary"
    local verdict color
    if [[ $pci_rc -eq 2 ]]; then
        # WEDGED if rev=ff was detected (check_pci returns 2 for that)
        # also WEDGED if dmesg failure pattern present
        verdict="WEDGED"
        color="$C_RED"
    elif [[ $dmesg_rc -eq 1 ]]; then
        verdict="WEDGED"
        color="$C_RED"
    elif [[ $tb_rc -eq 2 || $blk_rc -eq 2 ]]; then
        verdict="OFFLINE"
        color="$C_RED"
    elif [[ $tb_rc -eq 1 ]]; then
        verdict="OFFLINE"
        color="$C_RED"
    elif [[ $mnt_rc -ne 0 || $realloc_rc -ne 0 || $fstab_rc -ne 0 || $cap_rc -eq 1 || $enroll_rc -ne 0 ]]; then
        verdict="DEGRADED"
        color="$C_YELLOW"
    else
        verdict="OK"
        color="$C_GREEN"
    fi
    printf '%s%sPegasus health: %s%s\n' "$color" "$C_BOLD" "$verdict" "$C_RESET"
    pause
}

# ---- Main menu loop ----

print_menu() {
    cat <<EOF

${C_CYAN}${C_BOLD}=== Promise Pegasus3-R Management ===${C_RESET}

  ${C_BOLD}--- Status ---${C_RESET}
  1) Show full status (one-shot summary of everything below)
  2) Thunderbolt link status (boltctl)
  3) PCI controller health (lspci + rev check)
  4) Block device + partition table (lsblk + parted print)
  5) Filesystem details (tune2fs -l)
  6) Capacity and inode usage (df -h, df -i)
  7) Recent kernel logs (last thunderbolt/stex/sda events)

  ${C_BOLD}--- Mount ---${C_RESET}
  8) Mount $DEV_PART at $MOUNT_POINT
  9) Unmount $MOUNT_POINT
 10) Verify fstab entry

  ${C_BOLD}--- Diagnostics ---${C_RESET}
 11) Verify $KERNEL_PARAM kernel arg is active
 12) Verify Thunderbolt enrollment (boltctl shows policy=iommu, stored)
 13) Check for the "firmware not operational" / "handshake failed" failure pattern in dmesg

  ${C_BOLD}--- Maintenance ---${C_RESET}
 14) Run offline fsck (requires unmount; can take an hour+ on a full drive)
 15) Show LED/alarm meaning reference card

  ${C_BOLD}--- Recovery (use only if controller is wedged) ---${C_RESET}
 16) Attempt PCI hot-remove + rescan (may hang in D-state)
 17) Print recovery procedure for wedged controller (don't execute — just show steps)

  0) Exit

EOF
}

main() {
    local choice
    while true; do
        print_menu
        printf '%sChoose:%s ' "$C_CYAN" "$C_RESET"
        if ! read -r choice; then
            printf '\n'
            exit 0
        fi
        case "$choice" in
            1)  do_status_full ;;
            2)  do_show_thunderbolt ;;
            3)  do_show_pci ;;
            4)  do_show_block ;;
            5)  do_show_fs ;;
            6)  do_show_capacity ;;
            7)  do_show_dmesg ;;
            8)  do_mount ;;
            9)  do_unmount ;;
            10) do_verify_fstab ;;
            11) do_verify_pci_realloc ;;
            12) do_verify_enrollment ;;
            13) do_check_failure ;;
            14) do_fsck ;;
            15) do_led_card ;;
            16) do_pci_hotremove ;;
            17) do_recovery_steps ;;
            0|q|Q|"") info "Bye."; exit 0 ;;
            *)  warn "Unknown choice: $choice" ;;
        esac
    done
}

main "$@"
