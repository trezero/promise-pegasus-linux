# promise-pegasus-linux

Configuration and operational notes for running a **Promise Pegasus3-R** Thunderbolt 3 RAID enclosure on **Ubuntu 22.04**. This repo documents the setup that was performed on `aiplusblack1`, captures the procedure step-by-step, and ships a `manage.sh` CLI for ongoing status checks and maintenance.

---

## Hardware

| Attribute | Value |
|---|---|
| Enclosure | Promise Pegasus3-R (4-bay Thunderbolt 3) |
| Connection | Thunderbolt 3 (40 Gb/s, 2 lanes × 20 Gb/s) |
| Hardware RAID | Configured on a macOS host using the PROMISE Utility (Advanced wizard, "Format" unchecked) |
| Logical drive | One ~18 TB volume |
| Linux driver | `stex` (Promise SuperTrak EX) — mainline kernel module since 2.6.19 |
| PCI ID | `105a:8870` at PCI address `0000:9f:00.0` |
| Thunderbolt UUID | `c9030000-0000-7d18-a271-27c448213116` |

---

## Linux configuration

| Attribute | Value |
|---|---|
| Block device | `/dev/sda` (whole disk), `/dev/sda1` (partition) |
| Partition table | GPT, single partition spanning the whole disk |
| Filesystem | ext4 |
| Filesystem label | `pegasus_raid` |
| Filesystem UUID | `833dd228-35bf-4069-94f9-d98f215b8092` |
| Mount point | `/media/pegasus` |
| Owner | `winadmin:winadmin` (writable without sudo) |
| Inodes | 274,704,384 (default ratio at 18 TB scale) |
| Auto-mount | Yes — `/etc/fstab` entry with `nofail` and `x-systemd.device-timeout=10` |

---

## Setup procedure that was performed

### 1. Hardware RAID built on macOS

The PROMISE Utility for Linux is not officially supported, so the array was created on a macOS host. The drive was set up using the **Advanced** wizard with the **Format** checkbox unchecked, leaving the array as a raw block device after Linux saw it. (The macOS Utility still wrote a small EFI System Partition + HFS+ volume, which we wiped in step 4.)

### 2. Thunderbolt enrollment on the Linux host

```bash
boltctl enroll c9030000-0000-7d18-a271-27c448213116
```

The device is now permanently enrolled with `policy: iommu` — `boltd` auto-authorizes it on every reconnect.

### 3. Kernel parameter `pci=realloc` added

A wedged-controller failure mode (see "Known issues" below) was traced to PCI bridge-window allocation. We added `pci=realloc` to GRUB to mitigate:

```
# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash pci=realloc"
```

Followed by `sudo update-grub` and a reboot. Verify it's active with:

```bash
grep -wo pci=realloc /proc/cmdline
```

### 4. Filesystem creation

The macOS-default GPT + HFS+ volume was wiped and replaced with ext4:

```bash
sudo wipefs -a /dev/sda
sudo parted /dev/sda -- mklabel gpt
sudo parted -a opt /dev/sda -- mkpart primary ext4 0% 100%
sudo mkfs.ext4 -L pegasus_raid /dev/sda1
```

### 5. Mount + permissions + persistent fstab

```bash
sudo mkdir -p /media/pegasus
sudo mount /dev/sda1 /media/pegasus
sudo chown $USER:$USER /media/pegasus
```

Then appended to `/etc/fstab`:

```
# Promise Pegasus3-R Thunderbolt RAID (ext4, 18 TB)
UUID=833dd228-35bf-4069-94f9-d98f215b8092  /media/pegasus  ext4  defaults,nofail,x-systemd.device-timeout=10  0  2
```

`nofail` lets the system boot when the Pegasus is disconnected. `x-systemd.device-timeout=10` caps the wait at 10 s instead of the default 90 s.

---

## Day-to-day usage

The drive auto-mounts on boot. Once mounted:

- Path: `/media/pegasus`
- Reads/writes work without `sudo`
- `df -h /media/pegasus` shows ~17 TB usable (after journal + 5% reserved blocks)

Use `./manage.sh` for status, diagnostics, and maintenance — see "Management CLI" below.

---

## Known issues and recovery

### Failure mode: "firmware not operational" / "handshake failed"

Under a specific (still-imperfectly-understood) interaction between modern Linux kernels (6.x) and the SuperTrak controller, a write — typically `mkfs.ext4`, `dd`, or large sequential writes — can trigger the controller firmware to hang. Symptoms:

- `dmesg` shows `stex(0000:9f:00.0): firmware not operational` and `resetting: handshake failed`
- `lspci -nn` shows the controller with revision `ff` (config space unreadable)
- `/dev/sda` disappears
- Subsequent Thunderbolt reconnects re-establish the link layer but never re-bind `stex`

### Recovery procedure

1. **Power-cycle the Pegasus** (front button → wait for all LEDs dark → power on, wait for two-quick-beeps "ready").
2. **Reboot the Linux host.** The host's PCI tree latches the wedged state; only a full bus re-enumeration clears it. The PCI hot-remove workaround (`echo 1 > /sys/bus/pci/devices/0000:9f:00.0/remove`) was tested and **hangs in `D` state** when the device is wedged — don't rely on it.
3. **Verify recovery before any write:**
   ```bash
   lspci -nn | grep 105a       # revision must NOT be 'ff'
   sudo dmesg | grep -i stex   # should show clean enumeration
   lsblk /dev/sda              # device should be present
   ```
4. **`pci=realloc`** in GRUB (already applied here) mitigates the original PCI bridge-window cause and reduces — but does not fully eliminate — the chance of recurrence.

### Other known caveats

- **Daisy-chaining**: powering off any Pegasus in the middle of a chain disconnects every device below it.
- **Thunderbolt adapters**: original Pegasus1 R4 (TB1) does not reliably bridge to TB3 ports on PC hardware. The Pegasus3-R is native TB3 and works directly.
- **Thermal**: the chassis needs ≥13 cm of rear clearance and an ambient temperature ≤ 35 °C; thermal events can offline the controller.
- **Audible alarms**: two quick beeps = ready (normal). Two beeps continuously repeating = critical subsystem fault — check the front-panel and drive-carrier LEDs.

See `docs/advancedDiagnosticesPromise.md` for the full LED/alarm reference and `docs/promiseResearch.md` for the kernel-level troubleshooting catalog.

---

## Management CLI — `manage.sh`

The repo ships a menu-driven bash script for routine operations. Run it from anywhere:

```bash
./manage.sh
```

No installation, dependencies, or environment setup — it uses only the stock Ubuntu 22.04 toolchain (`bash`, `boltctl`, `lspci`, `lsblk`, `parted`, `tune2fs`, `dmesg`, `mount`, `fsck`, `df`, `dd`). Per-command `sudo` is used only where strictly required (reading `dmesg`, calling `tune2fs`, `parted print`, mount/unmount, `fsck`, dropping caches for the speed test, and the sysfs writes for the PCI hot-remove); read-only checks run unprivileged.

The Performance menu uses optional helpers `hdparm` (raw-device read) and `fio` (4K random IOPS). Both are skipped gracefully when not installed; the script prints the corresponding `apt install` hint instead of failing.

### Menu

The CLI is organized as a top menu with six submenus. The top menu shows a live status line (mount state and percent used) and dispatches into each submenu, which loops until you choose `0` to go back.

```
╔══════════════════════════════════════════╗
║      Promise Pegasus3-R Management       ║
╚══════════════════════════════════════════╝
  Device: /dev/sda1   Mount: ✔ mounted (37% used)   Label: pegasus_raid

  1) Status & Health    — quick checks, full summary, kernel logs
  2) Mount Operations   — mount, unmount, verify fstab
  3) Diagnostics        — kernel args, enrollment, failure patterns
  4) Performance        — speed tests (sequential + IOPS)
  5) Maintenance        — fsck, LED reference card
  6) Recovery           — wedged-controller procedures
  0) Exit
```

Submenu contents:

| Submenu | Options |
|---|---|
| **Status & Health** | Full status summary · Thunderbolt link · PCI controller health · Block device + partition table · Filesystem details · Capacity / inodes · Mount status · Recent kernel logs |
| **Mount Operations** | Mount `/dev/sda1` at `/media/pegasus` · Unmount · Verify fstab entry |
| **Diagnostics** | Verify `pci=realloc` kernel arg · Verify Thunderbolt enrollment (`policy=iommu`, stored) · Check dmesg for `firmware not operational` / `handshake failed` |
| **Performance** | Quick (512 MiB) · Normal (2 GiB) · Long (8 GiB, more accurate) speed tests |
| **Maintenance** | Offline `fsck` (requires unmount) · LED / alarm reference card |
| **Recovery** | Print recovery procedure (read-only) · Attempt PCI hot-remove + rescan (may hang) |

### Performance / speed test

The Performance submenu runs a self-contained benchmark against the mounted filesystem. Each test:

1. Verifies the volume is mounted and that there is enough free space (test size + 512 MiB headroom)
2. Drops the kernel page cache and runs **sequential write** with `dd … bs=1M oflag=direct conv=fsync`
3. Drops the cache again and runs **sequential read** with `dd … bs=1M iflag=direct`
4. If `hdparm` is installed, runs `hdparm -Tt /dev/sda` for **raw cached and uncached reads**
5. If `fio` is installed, runs **4K random read and write** at queue depth 32 for 10 s each, reporting IOPS and average latency
6. Cleans up the temporary test file (`/media/pegasus/.pegasus_speedtest.bin`)

Results are rendered in a colored table; sequential MB/s figures are colored against a baseline (`PERF_SEQ_GOOD` / `PERF_SEQ_OK` constants at the top of `manage.sh`, default 700 / 350 MB/s for a Pegasus3-R RAID5 of SSDs over Thunderbolt 3). Lower the thresholds if you have a spinning-disk array.

### Health verdict

`Status & Health → Full status` produces a single-line verdict at the bottom of the report. The verdict precedence is:

| Verdict | Trigger |
|---|---|
| `WEDGED` | PCI device shows `rev ff`, **or** dmesg has `firmware not operational` / `handshake failed` |
| `OFFLINE` | Thunderbolt is connected but unauthorized, **or** the device is fully disconnected |
| `DEGRADED` | Healthy connection but something is off — not mounted, fstab entry missing, `pci=realloc` not in kernel cmdline, or inode usage above 80% |
| `OK` | Everything as expected |

A wedged controller can never appear "OK" — the precedence is enforced explicitly.

### Sample output (Full status)

Status indicators render as colored bullets (`●`); reproduced here in plain text:

```
● Thunderbolt: authorized (rx/tx 40 Gb/s)
● PCI controller 0000:9f:00.0 [105a:8870] rev 01, driver=stex
● Block device sda1 present, FS=ext4 LABEL=pegasus_raid
● Filesystem clean, last check OK
● Mounted: /dev/sda1 /media/pegasus ext4 rw,relatime
● Capacity: 17T total, 11 of 274.7M inodes used
● pci=realloc is active
● fstab references UUID 833dd228-35bf-4069-94f9-d98f215b8092
● No firmware-not-operational / handshake-failed events

✔  Pegasus health: OK
```

### Destructive options — confirmation gated

Two actions can affect device state and require typed `y` confirmation (default no):

- **Maintenance → Offline fsck.** Unmounts the filesystem, runs `fsck.ext4 -fy /dev/sda1`, then re-mounts. On a full 18 TB drive this can take an hour or more; the script warns up front. Anything else accessing `/media/pegasus` will see I/O errors during the run.
- **Recovery → PCI hot-remove + rescan.** Writes `1` to `/sys/bus/pci/devices/0000:9f:00.0/remove` then to `/sys/bus/pci/rescan`. Documented as a community workaround for the wedged-controller case but observed in our own testing to hang in `D` state when the device is genuinely wedged — at which point only a host reboot recovers it. The script warns about this explicitly. The sibling **Print recovery procedure** option is the read-only counterpart that just shows the steps.

### Use as a one-liner

The script is designed to be interactive, but the path `Main → Status & Health → Full status` gives a fast non-interactive health check suitable for scripting. Each prompt eats one line of input; the blank line between selections acknowledges the "Press Enter to continue" pause:

```bash
printf '1\n1\n\n0\n0\n' | ./manage.sh
```

The two trailing `0`s exit the Status & Health submenu and then the main menu. Pipe to `grep -E '●|Pegasus health'` to extract just the bullet/verdict lines.

---

## Repository layout

```
.
├── README.md                              # this file
├── manage.sh                              # menu-driven management CLI
├── CLAUDE.md                              # repo guidance for AI coding assistants
└── docs/
    ├── reformatForLinuxGuide.md           # the format procedure that was followed
    ├── promiseResearch.md                 # driver, Thunderbolt, RAID prep, kernel troubleshooting
    ├── advancedDiagnosticesPromise.md     # LEDs, alarms, PCI verification, thermal halts
    └── boltctlMonitorOutput.md            # example session captures with annotations
```

New material should follow the existing pattern in `docs/`: paste the actual command and its output, then explain what it did and why. Real device IDs and `dmesg` lines are evidence — preserve them verbatim.
