# Advanced Diagnostics & Troubleshooting Reference: Promise Pegasus on Linux

This document supplements standard installation guides by providing advanced troubleshooting parameters, hardware diagnostic codes, and edge-case resolutions for managing a Promise Pegasus R4 (and similar R6/R8 units) on Linux environments. 

## 1. Physical Diagnostics: LEDs and Audible Alarms
If the AI agent or user cannot detect the arrays in the OS, physical hardware signals provide the first layer of diagnostics.

**Audible Alarms:**
*   **Two quick beeps (not repeated):** Normal behavior indicating the unit is powering up or is ready for use.
*   **Two beeps (continuously repeated):** Indicates a critical subsystem problem. The agent should instruct the user to check the System Status and Drive Carrier LEDs.

**LED Status Indicators:**
*   **System Status LED (Power Button):** 
    *   **Blue:** Normal operation.
    *   **Orange:** The system is booting up or shutting down.
    *   **Red:** Indicates a serious problem, such as an incomplete array or a failed hard disk drive.
*   **Drive Carrier LEDs:**
    *   **Solid Blue:** Power is present and the drive is functioning normally.
    *   **Flashing Blue:** Normal read/write activity.
    *   **Blinking Blue and Orange:** The drive is currently rebuilding, or the "Locate" feature has been triggered in the software to identify the drive.
    *   **Red:** Drive error or failure. 

## 2. Hardware and Connectivity Pitfalls
**Adapter Compatibility (Thunderbolt 1/2 to 3/4):**
If the device is completely invisible to `boltctl` and `lspci`, verify the exact hardware generation. Older original Pegasus1 R4 units (Thunderbolt 1) often fail to connect through Apple or StarTech Thunderbolt 1/2 to Thunderbolt 3 adapters on non-Mac hardware. While the Pegasus2 series has better adapter compatibility and newer drivers, the original Pegasus1 R4 is known to hit dead ends on PC/Linux hardware when adapted to newer Thunderbolt ports. 

**Daisy-Chaining Limitations:**
If multiple Pegasus enclosures are daisy-chained, the agent must be aware that shutting down a Pegasus unit in the middle of the chain will effectively disconnect all subsequent units below it from the host computer.

**Controller Power States (WMI Force Power):**
On some OEM platforms, the host Thunderbolt controller might power down if it thinks nothing is connected. Linux provides a WMI bus sysfs attribute (`force_power`) via the `intel-wmi-thunderbolt` driver to force the controller on. 
*   To force power on: `echo 1 > /sys/bus/wmi/devices/86CCFD48-205E-4A77-9C48-2021CBEDE341/force_power`.
*   To disable forced power: `echo 0 > /sys/bus/wmi/devices/.../force_power`.

## 3. PROMISE Utility Specific Error States
When querying the system via the PROMISE Utility, the coding agent must be prepared to handle specific proprietary error conditions on the physical drives. Before making administrative changes, the agent/user must unlock the UI by clicking the padlock icon and entering the system password.

**Stale and PFA Conditions:**
If a physical drive shows an "Offline" status, it may be locked in one of two conditions:
*   **Stale Condition:** The physical drive contains obsolete disk array information. This must be cleared manually or by deleting the associated obsolete array.
*   **PFA (Predictive Failure Analysis) Condition:** The drive has errors leading to a prediction of imminent failure. 
*   **Resolution:** If a drive has *both* conditions, the agent must issue the "Clear" command twice; the first clears the Stale condition, and the second clears the PFA condition.

**Incomplete Arrays and "Ajar" Drives:**
*   An "Incomplete Array" typically occurs if drives were moved between systems or slots (transport/migration) and not all drives are recognized. The agent should warn the user **not** to accept the incomplete array prompt until verifying all drives are present.
*   If the utility throws an **"ajar HDD from the backplane"** warning, the user must physically reseat the drives. The proper procedure is to power down the unit until the LED goes dark, pull the drive carrier part way out, press it firmly back in until it locks, and power the unit back on.

## 4. Boot-Level and Kernel Troubleshooting
**PCI ID Verification:**
To verify that the Linux kernel is actively binding to the Promise controller, the agent should search `lspci -nn` for Vendor ID `105a` (Promise Technology, Inc.). Common Pegasus controller Device IDs include `8350` (SuperTrak EX8350/EX16350) and `8760` (SuperTrak EX SAS/SATA 6G). The kernel module assigned to these devices is `stex`.

**Kernel Testing and Display Manager Hangs:**
If the user is testing different kernel versions (e.g., trying older 4.x or 5.x kernels to find a stable `stex` module) and the system boot hangs at the GUI level (e.g., "Started Gnome Display Monitor"), this is often a conflict with proprietary graphics drivers (like Nvidia) built for specific kernel headers. 
*   **Workaround for the Agent/User:** Intercept the GRUB bootloader and append `systemd.unit=multi-user.target` to the kernel command-line parameters. This forces the system to boot into text-mode, bypassing the display manager crash and allowing the user to manage the `stex` module, access Thunderbolt utilities, or rebuild Nvidia drivers from the terminal. 

## 5. Environmental Subsystem Halts
If the Pegasus controller experiences unexplained resets, offline events, or connection drops, evaluate the thermal environment. The system will protect itself if it detects overheating, which usually results from:
*   **Inadequate clearance:** The Pegasus requires a minimum of 13 cm (5 inches) of space between the back of the unit and the wall.
*   **Ambient Temperature:** The operating environment must remain below 35°C (95°F). Exceeding this can lead to drive failure and RAID controller malfunction.