#!/usr/bin/env bash
# Pegasus3-R management CLI — status, diagnostics, maintenance, performance.
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

# Performance baselines (Pegasus3-R over Thunderbolt 2/3, RAID5 of 4x SSDs)
# Used purely to colorize speed-test output.
PERF_SEQ_GOOD=700      # MB/s — green at/above
PERF_SEQ_OK=350        # MB/s — yellow at/above, red below

# ---- Colors (disabled when stdout is not a TTY) ----
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_MAGENTA=$'\033[35m'
    C_CYAN=$'\033[36m'
    C_GRAY=$'\033[90m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
else
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
    C_MAGENTA=""; C_CYAN=""; C_GRAY=""; C_BOLD=""; C_DIM=""
fi

ok()    { printf '  %s●%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf '  %s●%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
fail()  { printf '  %s●%s %s\n' "$C_RED"    "$C_RESET" "$*"; }
info()  { printf '    %s%s%s\n' "$C_GRAY" "$*" "$C_RESET"; }

hdr() {
    local title="$*"
    local line
    printf -v line '%*s' $((${#title} + 4)) ''
    line="${line// /─}"
    printf '\n%s┌%s┐%s\n'      "$C_CYAN" "$line" "$C_RESET"
    printf '%s│%s  %s%s%s  %s│%s\n' \
        "$C_CYAN" "$C_RESET" "$C_BOLD" "$title" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf '%s└%s┘%s\n\n'      "$C_CYAN" "$line" "$C_RESET"
}

trap 'warn "Unexpected error on line $LINENO (continuing)"' ERR

pause() {
    printf '\n%s↵ Press Enter to continue...%s' "$C_DIM" "$C_RESET"
    read -r _ || true
}

confirm_yes() {
    local prompt="$1" reply
    printf '%s%s%s [y/N] ' "$C_YELLOW" "$prompt" "$C_RESET"
    read -r reply || reply=""
    [[ "$reply" == "y" || "$reply" == "Y" ]]
}

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        warn "Missing command: $1"
        return 1
    fi
    return 0
}

# Format MB/s with color depending on baseline.
fmt_mbs() {
    local mbs="$1"
    local int=${mbs%.*}
    local color="$C_RED"
    if   (( int >= PERF_SEQ_GOOD )); then color="$C_GREEN"
    elif (( int >= PERF_SEQ_OK ));   then color="$C_YELLOW"
    fi
    printf '%s%8.1f MB/s%s' "$color" "$mbs" "$C_RESET"
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

# ---- Mount actions ----

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

# ---- Maintenance ----

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
        fail "$MOUNT_POINT is currently mounted. Unmount first."
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

# ---- Recovery ----

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
  5. After reboot, run "Show full status" to confirm OK.

Optional (lower-success) attempts before reboot:
  - PCI hot-remove + rescan from the Recovery menu.  May hang.
  - sudo modprobe -r stex && sudo modprobe stex
        Often blocked because the module is in use by the wedged host.

Prevention:
  - Keep $KERNEL_PARAM in GRUB_CMDLINE_LINUX_DEFAULT.
  - Maintain >=13 cm clearance behind enclosure; ambient <35 C.
  - Avoid sleep/suspend on the host while Pegasus is mounted.
EOF
    pause
}

# ---- Performance / speed test ----

# Parse an MB/s number out of dd's stderr line. dd may report KB/s, MB/s, GB/s.
# Echoes a plain MB/s float.
parse_dd_mbs() {
    local line="$1"
    awk '
        BEGIN { mbs = 0 }
        {
            # find the "<num> <unit>/s" pair near the end
            for (i = 1; i <= NF; i++) {
                if ($i ~ /\/s,?$/) {
                    gsub(",", "", $i)
                    val = $(i-1)
                    unit = $i
                    if      (unit ~ /^GB/)  mbs = val * 1000
                    else if (unit ~ /^MB/)  mbs = val
                    else if (unit ~ /^kB/)  mbs = val / 1000
                    else if (unit ~ /^B/)   mbs = val / 1000000
                }
            }
            print mbs
        }
    ' <<<"$line"
}

# Drop OS caches so subsequent reads hit the device, not RAM.
drop_caches() {
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
}

run_speed_test() {
    local size_label="$1" size_mb="$2"

    if ! mountpoint -q "$MOUNT_POINT"; then
        fail "$MOUNT_POINT is not mounted — cannot run speed test"
        pause; return 1
    fi

    local avail_mb
    avail_mb="$(df -BM --output=avail "$MOUNT_POINT" | tail -n1 | tr -dc '0-9')"
    if [[ -n "$avail_mb" && "$avail_mb" -lt $((size_mb + 512)) ]]; then
        fail "Insufficient free space (${avail_mb} MiB free, need ~$((size_mb + 512)) MiB)"
        pause; return 1
    fi

    local test_file="${MOUNT_POINT}/.pegasus_speedtest.bin"
    local t0 t1 dur

    hdr "Speed test — $size_label (${size_mb} MiB, O_DIRECT)"
    info "Test file: $test_file"
    info "Caching:   bypassed via O_DIRECT and drop_caches"
    printf '\n'

    # Sequential write
    info "Running sequential write..."
    drop_caches
    t0=$(date +%s)
    local wline
    wline="$(dd if=/dev/zero of="$test_file" bs=1M count="$size_mb" \
            oflag=direct conv=fsync 2>&1 | tail -n1)"
    t1=$(date +%s)
    local w_mbs
    w_mbs="$(parse_dd_mbs "$wline")"
    local w_dur=$((t1 - t0))

    # Sequential read
    info "Running sequential read..."
    drop_caches
    t0=$(date +%s)
    local rline
    rline="$(dd if="$test_file" of=/dev/null bs=1M count="$size_mb" \
            iflag=direct 2>&1 | tail -n1)"
    t1=$(date +%s)
    local r_mbs
    r_mbs="$(parse_dd_mbs "$rline")"
    local r_dur=$((t1 - t0))

    # Raw device reads via hdparm (cached + uncached)
    local hd_cached="" hd_uncached=""
    if command -v hdparm >/dev/null 2>&1; then
        info "Running hdparm raw-device probes..."
        local hdout
        hdout="$(sudo hdparm -Tt "$DEV_DISK" 2>/dev/null || true)"
        # Lines look like: " Timing cached reads:   1234 MB in  2.00 seconds = 617.32 MB/sec"
        hd_cached="$(  printf '%s\n' "$hdout" | awk -F'= *' '/cached reads/   {print $2}' | awk '{print $1}')"
        hd_uncached="$(printf '%s\n' "$hdout" | awk -F'= *' '/buffered disk/  {print $2}' | awk '{print $1}')"
    fi

    # Optional fio random IOPS
    local iops_r="" iops_w="" lat_r="" lat_w=""
    if command -v fio >/dev/null 2>&1; then
        info "Running fio 4K random read/write (10 s each, qd=32)..."
        local fio_size_mb=$(( size_mb < 512 ? size_mb : 512 ))
        local fio_out
        fio_out="$(fio --name=peg-randread \
            --filename="$test_file" --size="${fio_size_mb}M" --rw=randread \
            --bs=4k --iodepth=32 --ioengine=libaio --direct=1 \
            --time_based --runtime=10 --output-format=terse 2>/dev/null || true)"
        # terse field 8 = read iops, field 40 = read clat mean (us)
        iops_r="$(awk -F';' '{printf "%.0f", $8}'  <<<"$fio_out")"
        lat_r="$( awk -F';' '{printf "%.2f", $40/1000}' <<<"$fio_out")"

        fio_out="$(fio --name=peg-randwrite \
            --filename="$test_file" --size="${fio_size_mb}M" --rw=randwrite \
            --bs=4k --iodepth=32 --ioengine=libaio --direct=1 \
            --time_based --runtime=10 --output-format=terse 2>/dev/null || true)"
        # terse field 49 = write iops, field 81 = write clat mean (us)
        iops_w="$(awk -F';' '{printf "%.0f", $49}'  <<<"$fio_out")"
        lat_w="$( awk -F';' '{printf "%.2f", $81/1000}' <<<"$fio_out")"
    fi

    # Cleanup
    rm -f "$test_file" 2>/dev/null || sudo rm -f "$test_file"

    # Pretty results table
    printf '\n'
    printf '%s┌──────────────────────────────────────────────────────────────┐%s\n' "$C_MAGENTA" "$C_RESET"
    printf '%s│  %sPegasus3-R Speed Test Results%s%s                              │%s\n' \
        "$C_MAGENTA" "$C_BOLD" "$C_RESET" "$C_MAGENTA" "$C_RESET"
    printf '%s├──────────────────────────────────────────────────────────────┤%s\n' "$C_MAGENTA" "$C_RESET"
    printf '%s│%s  %-32s %s   %s│%s\n' \
        "$C_MAGENTA" "$C_RESET" \
        "Sequential Write (${size_mb} MiB)" \
        "$(fmt_mbs "$w_mbs")" \
        "$C_MAGENTA" "$C_RESET"
    printf '%s│%s  %-32s %s   %s│%s\n' \
        "$C_MAGENTA" "$C_RESET" \
        "Sequential Read  (${size_mb} MiB)" \
        "$(fmt_mbs "$r_mbs")" \
        "$C_MAGENTA" "$C_RESET"
    if [[ -n "$hd_cached" ]]; then
        printf '%s│%s  %-32s %s   %s│%s\n' \
            "$C_MAGENTA" "$C_RESET" \
            "Raw Read  (cached, hdparm)" \
            "$(fmt_mbs "$hd_cached")" \
            "$C_MAGENTA" "$C_RESET"
    fi
    if [[ -n "$hd_uncached" ]]; then
        printf '%s│%s  %-32s %s   %s│%s\n' \
            "$C_MAGENTA" "$C_RESET" \
            "Raw Read  (uncached, hdparm)" \
            "$(fmt_mbs "$hd_uncached")" \
            "$C_MAGENTA" "$C_RESET"
    fi
    if [[ -n "$iops_r" ]]; then
        printf '%s├──────────────────────────────────────────────────────────────┤%s\n' "$C_MAGENTA" "$C_RESET"
        printf '%s│%s  %-32s %s%10s IOPS%s   %s│%s\n' \
            "$C_MAGENTA" "$C_RESET" \
            "Random Read  (4K, qd=32)" \
            "$C_CYAN" "$iops_r" "$C_RESET" \
            "$C_MAGENTA" "$C_RESET"
        printf '%s│%s  %-32s %s%10s IOPS%s   %s│%s\n' \
            "$C_MAGENTA" "$C_RESET" \
            "Random Write (4K, qd=32)" \
            "$C_CYAN" "$iops_w" "$C_RESET" \
            "$C_MAGENTA" "$C_RESET"
        printf '%s│%s  %-32s %s%10s ms  %s   %s│%s\n' \
            "$C_MAGENTA" "$C_RESET" \
            "Avg Read Latency" \
            "$C_CYAN" "$lat_r" "$C_RESET" \
            "$C_MAGENTA" "$C_RESET"
        printf '%s│%s  %-32s %s%10s ms  %s   %s│%s\n' \
            "$C_MAGENTA" "$C_RESET" \
            "Avg Write Latency" \
            "$C_CYAN" "$lat_w" "$C_RESET" \
            "$C_MAGENTA" "$C_RESET"
    fi
    printf '%s└──────────────────────────────────────────────────────────────┘%s\n' "$C_MAGENTA" "$C_RESET"

    printf '\n  %sBaseline:%s green ≥ %d MB/s · yellow ≥ %d MB/s · red below.\n' \
        "$C_DIM" "$C_RESET" "$PERF_SEQ_GOOD" "$PERF_SEQ_OK"
    printf '  %sWrote/read in:%s %ds write + %ds read.\n' \
        "$C_DIM" "$C_RESET" "$w_dur" "$r_dur"

    if [[ -z "$hd_cached" ]]; then
        printf '\n'; warn "hdparm not installed — install with: sudo apt install hdparm"
    fi
    if [[ -z "$iops_r" ]]; then
        warn "fio not installed — install with: sudo apt install fio  (for IOPS test)"
    fi
}

do_speed_quick()  { run_speed_test "Quick"  512;  pause; }
do_speed_normal() { run_speed_test "Normal" 2048; pause; }
do_speed_long()   { run_speed_test "Long"   8192; pause; }

# ---- Full status summary ----

do_status_full() {
    local tb_rc pci_rc blk_rc mnt_rc cap_rc realloc_rc fstab_rc dmesg_rc enroll_rc

    check_thunderbolt;          tb_rc=$?
    check_boltctl_enrolled;     enroll_rc=$?
    check_pci;                  pci_rc=$?
    check_block_device;         blk_rc=$?
    check_filesystem || true
    check_mount;                mnt_rc=$?
    check_capacity;             cap_rc=$?
    check_pci_realloc;          realloc_rc=$?
    check_fstab;                fstab_rc=$?
    check_dmesg_failure_pattern; dmesg_rc=$?

    hdr "Summary"
    local verdict color icon
    if   [[ $pci_rc -eq 2 ]]; then          verdict="WEDGED";   color="$C_RED";    icon="✘"
    elif [[ $dmesg_rc -eq 1 ]]; then        verdict="WEDGED";   color="$C_RED";    icon="✘"
    elif [[ $tb_rc -eq 2 || $blk_rc -eq 2 ]]; then verdict="OFFLINE"; color="$C_RED"; icon="✘"
    elif [[ $tb_rc -eq 1 ]]; then           verdict="OFFLINE";  color="$C_RED";    icon="✘"
    elif [[ $mnt_rc -ne 0 || $realloc_rc -ne 0 || $fstab_rc -ne 0 || $cap_rc -eq 1 || $enroll_rc -ne 0 ]]; then
        verdict="DEGRADED"; color="$C_YELLOW"; icon="!"
    else
        verdict="OK"; color="$C_GREEN"; icon="✔"
    fi
    printf '  %s%s  %s  Pegasus health: %s%s\n\n' \
        "$color" "$C_BOLD" "$icon" "$verdict" "$C_RESET"
    pause
}

# ---- Menu rendering ----

# Render a menu from a label/handler list, prompt, dispatch, repeat until "back".
# Args: menu_title  back_label  label1 handler1  label2 handler2 ...
run_menu() {
    local title="$1"; shift
    local back_label="$1"; shift
    local labels=() handlers=()
    while (( $# >= 2 )); do
        labels+=("$1"); handlers+=("$2")
        shift 2
    done

    local choice i
    while true; do
        printf '\n%s%s┌─ %s ──────────────────────────%s\n' "$C_BLUE" "$C_BOLD" "$title" "$C_RESET"
        for (( i=0; i<${#labels[@]}; i++ )); do
            printf '  %s%2d)%s %s\n' "$C_CYAN" $((i+1)) "$C_RESET" "${labels[i]}"
        done
        printf '  %s 0)%s %s\n\n' "$C_CYAN" "$C_RESET" "$back_label"
        printf '%s%s ▸%s ' "$C_BLUE" "$title" "$C_RESET"
        if ! read -r choice; then printf '\n'; return 0; fi
        case "$choice" in
            0|b|B|q|Q|"") return 0 ;;
            *[!0-9]*) warn "Not a number: $choice" ;;
            *)
                if (( choice >= 1 && choice <= ${#labels[@]} )); then
                    # Handlers may be "func arg" strings — eval to allow word splitting.
                    eval "${handlers[$((choice-1))]}"
                else
                    warn "Out of range: $choice"
                fi
                ;;
        esac
    done
}

# ---- Submenus ----

menu_status() {
    run_menu "Status & Health" "Back to main" \
        "Full status (one-shot summary)"               do_status_full \
        "Thunderbolt link (boltctl)"                   "do_check check_thunderbolt" \
        "PCI controller health (lspci + rev check)"    "do_check check_pci" \
        "Block device + partition table"               "do_check check_block_device" \
        "Filesystem details (tune2fs -l)"              "do_check check_filesystem" \
        "Capacity and inode usage (df -h, df -i)"      "do_check check_capacity" \
        "Mount status"                                 "do_check check_mount" \
        "Recent kernel logs (thunderbolt/stex/sda)"    "do_check check_dmesg_recent"
}

menu_mount() {
    run_menu "Mount Operations" "Back to main" \
        "Mount $DEV_PART at $MOUNT_POINT"   do_mount \
        "Unmount $MOUNT_POINT"              do_unmount \
        "Verify fstab entry"                "do_check check_fstab"
}

menu_diagnostics() {
    run_menu "Diagnostics" "Back to main" \
        "Verify $KERNEL_PARAM kernel arg is active"               "do_check check_pci_realloc" \
        "Verify Thunderbolt enrollment (policy=iommu, stored)"    "do_check check_boltctl_enrolled" \
        "Check dmesg for firmware-not-operational pattern"        "do_check check_dmesg_failure_pattern"
}

menu_performance() {
    run_menu "Performance" "Back to main" \
        "Quick speed test (512 MiB)"          do_speed_quick \
        "Normal speed test (2 GiB)"           do_speed_normal \
        "Long speed test (8 GiB, more accurate)" do_speed_long
}

menu_maintenance() {
    run_menu "Maintenance" "Back to main" \
        "Run offline fsck (requires unmount)"  do_fsck \
        "LED / alarm reference card"           do_led_card
}

menu_recovery() {
    run_menu "Recovery (use only if controller is wedged)" "Back to main" \
        "Print recovery procedure (does not execute)"    do_recovery_steps \
        "Attempt PCI hot-remove + rescan (may hang)"     do_pci_hotremove
}

# Wrapper: call a check function then pause.
do_check() { "$1" || true; pause; }

# ---- Main menu ----

print_main_banner() {
    printf '\n%s%s╔══════════════════════════════════════════╗%s\n' "$C_CYAN" "$C_BOLD" "$C_RESET"
    printf '%s%s║      Promise Pegasus3-R Management       ║%s\n' "$C_CYAN" "$C_BOLD" "$C_RESET"
    printf '%s%s╚══════════════════════════════════════════╝%s\n' "$C_CYAN" "$C_BOLD" "$C_RESET"
    # tiny live status line
    local mnt="$C_RED✘ unmounted$C_RESET"
    if mountpoint -q "$MOUNT_POINT"; then
        local used
        used="$(df -h --output=pcent "$MOUNT_POINT" 2>/dev/null | tail -n1 | tr -d ' %')"
        mnt="$C_GREEN✔ mounted$C_RESET ${C_DIM}(${used:-?}% used)$C_RESET"
    fi
    printf '  %sDevice:%s %s   %sMount:%s %s   %sLabel:%s %s\n' \
        "$C_DIM" "$C_RESET" "$DEV_PART" \
        "$C_DIM" "$C_RESET" "$mnt" \
        "$C_DIM" "$C_RESET" "$FS_LABEL"
}

main() {
    local choice
    while true; do
        print_main_banner
        cat <<EOF

  ${C_CYAN}1)${C_RESET} ${C_BOLD}Status & Health${C_RESET}    ${C_DIM}— quick checks, full summary, kernel logs${C_RESET}
  ${C_CYAN}2)${C_RESET} ${C_BOLD}Mount Operations${C_RESET}   ${C_DIM}— mount, unmount, verify fstab${C_RESET}
  ${C_CYAN}3)${C_RESET} ${C_BOLD}Diagnostics${C_RESET}        ${C_DIM}— kernel args, enrollment, failure patterns${C_RESET}
  ${C_CYAN}4)${C_RESET} ${C_BOLD}Performance${C_RESET}        ${C_DIM}— speed tests (sequential + IOPS)${C_RESET}
  ${C_CYAN}5)${C_RESET} ${C_BOLD}Maintenance${C_RESET}        ${C_DIM}— fsck, LED reference card${C_RESET}
  ${C_CYAN}6)${C_RESET} ${C_BOLD}Recovery${C_RESET}           ${C_DIM}— wedged-controller procedures${C_RESET}

  ${C_CYAN}0)${C_RESET} Exit

EOF
        printf '%sMain ▸%s ' "$C_CYAN" "$C_RESET"
        if ! read -r choice; then printf '\n'; exit 0; fi
        case "$choice" in
            1) menu_status ;;
            2) menu_mount ;;
            3) menu_diagnostics ;;
            4) menu_performance ;;
            5) menu_maintenance ;;
            6) menu_recovery ;;
            0|q|Q|"") info "Bye."; exit 0 ;;
            *) warn "Unknown choice: $choice" ;;
        esac
    done
}

main "$@"
