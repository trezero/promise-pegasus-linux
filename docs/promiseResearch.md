# Promise Pegasus R4 Linux Management & Integration Guide (Ubuntu 22.04)

This document is an authoritative RAG resource designed for a coding agent building a utility to manage and mount a Promise Pegasus R4 unit on Ubuntu 22.04. It covers Thunderbolt connectivity, kernel driver management, filesystem preparation (APFS/HFS+), and known troubleshooting steps.

## 1. Hardware & Driver Architecture
The Promise Pegasus R4 is a Direct Attached Storage (DAS) unit natively operating over Thunderbolt 1 or 2. It utilizes a PMC Sierra 8011 I/O processor and 512 MB of DDR2 SDRAM to handle hardware RAID configurations (RAID 0, 1, 1E, 5, 6, 10).

**Kernel Driver:** 
Linux supports Promise SuperTrak EX series storage controllers through the `stex` kernel module (`CONFIG_SCSI_STEX`). 
*   This driver has been mainlined into the Linux kernel since version 2.6.19 and remains available in modern 5.x, 6.x, and 7.x kernels. 
*   Ubuntu 22.04 uses a 5.15+ kernel, meaning the `stex` driver should be available natively without requiring manual compilation. 
*   **Important note for older Pegasus models:** If connecting an older Pegasus R4/R6, it is highly recommended to use the Pegasus2 driver versions, as they maintain backward compatibility.

## 2. Thunderbolt Connection and Device Authorization
Ubuntu (and Linux generally) handles Thunderbolt connections securely via the connection manager daemon (`boltd`) and its CLI tool (`boltctl`). Depending on the system's Thunderbolt security level (typically `user` or `secure`), PCIe tunnels for the Pegasus R4 will not be created automatically when plugged in.

### Manual Authorization using `boltctl`
To authorize the device upon connection:
1.  List all connected Thunderbolt devices and retrieve the device UUID:
    ```bash
    boltctl list
    ```
2.  Enroll and authorize the device (this generates and stores a secure key if supported):
    ```bash
    boltctl enroll <DEVICE_UUID>
    ```
    Alternatively, to authorize it instantly without permanent enrollment:
    ```bash
    boltctl authorize <DEVICE_UUID>
    ```
    Once authorized, the PCIe tunnels are created, and the `stex` driver can initialize the block devices.

### Automated Authorization (For Utilities)
To allow the coding agent to handle the Pegasus unit without manual intervention, you can bypass the security prompt by configuring a `udev` rule. 
Create a file at `/etc/udev/rules.d/99-local.rules` with the following content:
```udev
ACTION=="add", SUBSYSTEM=="thunderbolt", ATTR{authorized}=="0", ATTR{authorized}="1"
```
*Note: This automatically authorizes all Thunderbolt devices and bypasses DMA security levels, which should be assessed for security risks on the target system.*

## 3. Filesystem Mounting Guides (HFS+ and APFS)
Because the Pegasus R4 is historically Mac-centric, drives coming from a macOS environment will likely be formatted in HFS+ or APFS.

### Mounting HFS+ Drives
Ubuntu requires the `hfsprogs` package to read from HFS+ drives properly. 
1.  Install the necessary package:
    ```bash
    sudo apt install hfsprogs
    ```
2.  Identify the drive partition (e.g., `/dev/sdb2`):
    ```bash
    lsblk -f
    ```
3.  Create a mount point and mount the drive:
    ```bash
    sudo mkdir -p /media/machd
    sudo mount -t hfsplus /dev/sdb2 /media/machd
    ```
4.  To unmount safely:
    ```bash
    sudo umount /media/machd
    ```
    *(Note: Ubuntu can generally only provide read access to journaled HFS+ drives without disabling the journal).*

### Mounting APFS Drives
Linux does not have official native support for the Apple File System (APFS); however, it can be mounted using the community-built `apfs-fuse` driver, which provides **read-only access**. 
1.  Install compilation dependencies via `apt` (requires `fuse`, `git`, `cmake`, and standard C++ build tools).
2.  Clone and compile the driver:
    ```bash
    git clone https://github.com/sgan81/apfs-fuse.git
    cd apfs-fuse
    git submodule update --init
    mkdir build && cd build
    cmake ..
    make
    ```
3.  Mount the APFS drive:
    ```bash
    sudo ./apfs-fuse -o allow_other /dev/sdb2 /media/machd
    ```
4.  Unmount using the standard fuse utility:
    ```bash
    fusermount -u /media/machd
    ```
    *Alternatively, root can use the standard `umount` command.*

## 4. RAID Configuration & System Preparation Best Practices
While Promise provides "Open Linux Support" for the `stex` driver, the dedicated graphical "PROMISE Utility" is packaged natively as a `.pkg` for macOS. 

**Configuration Prerequisites:**
*   **Pre-Provisioning:** If the coding agent needs to define specific hardware RAID arrays (e.g., RAID 5) or set drives to "PassThru" (JBOD) mode, it is highly recommended to perform the initial array setup by connecting the Pegasus R4 to a macOS machine utilizing the PROMISE Utility. 
*   Once the arrays are committed to the hardware, Linux and Ubuntu 22.04 will natively recognize the logical drives via the `stex` driver.

## 5. Known Instability & Troubleshooting on Modern Linux
When working with modern Linux kernels (like Debian-based Proxmox or Ubuntu 22) and Thunderbolt 2 devices like the Pegasus R4/R6, some users have encountered severe stability issues. **Be aware of the following known behaviors and GRUB workarounds:**

*   **PCI Allocation Errors:** During boot, the system may struggle with bridge window allocations. This can be resolved by editing `/etc/default/grub` and appending `pci=realloc` to `GRUB_CMDLINE_LINUX_DEFAULT`, then updating GRUB.
*   **Kernel Panic / Handshake Failures on Write:** Users on kernel 6.x have reported that while read operations work perfectly, write operations (like `dd` or `mkfs.ext4`) can trigger an immediate "no signature after handshake frame" error, causing the `stex` driver to offline the device. 
*   **Attempted mitigations:** Disabling MSI/AER via boot parameters (`pci=nomsi pci=noaer`) or forcing a PCI rescan (`echo 1 > /sys/bus/pci/rescan`) have been attempted by the community, but write instability may persist on certain newer kernels handling older Thunderbolt 2 bridging. Utilizing a Thunderbolt 3 adapter may also lead to unrecognized devices, especially on Windows/Linux PC implementations compared to native Mac hardware.