**Step 1: Connect to a macOS System for Hardware Configuration**
To configure the raw hardware arrays on the Promise Pegasus R4, you should connect the unit to a macOS machine. The dedicated graphical PROMISE Utility is natively packaged for macOS, making it the most reliable way to clear the old Windows arrays and establish the physical drives for Linux. 

**Step 2: Clear the Old Windows Configurations**
You must delete the existing disk arrays containing the Windows file system. 
1. Open the PROMISE Utility on the Mac and click the **lock icon** at the bottom left to unlock the user interface using your Mac administrator password.
2. Click the **Logical Drive** icon, mouse-over the existing logical drive(s), and click **Delete**.
3. Click the **Disk Array** icon, mouse-over the existing array(s), and click **Delete** to completely clear the old Windows setup.

**Step 3: Create a New Hardware RAID Array (Do NOT use PassThru)**
You must commit the physical drives to a hardware RAID array. **Do not set the drives to "PassThru" (JBOD) mode.** While PassThru exposes the raw drives to the OS, attempting write operations (like formatting or using `dd`) on PassThru drives over modern Linux kernels causes the `stex` controller to fail handshakes and trigger a kernel panic.
1. In the PROMISE Utility, click the **Wizard** icon and select **Advanced** configuration.
2. Select your physical drives to create a new disk array.
3. Choose a RAID level for your logical drive. For the absolute **best read/write performance**, choose **RAID 0**. If you want a balance of performance and fault tolerance, choose **RAID 5**. 
4. **CRITICAL:** Under the Logical Drive Creation options, **UNcheck the "Format" box**. If you leave this checked, the PROMISE Utility will automatically format the array in an Apple-centric format (GPT/Journaled HFS+) which is not native to Linux and only easily accessible as read-only. 
5. Submit the configuration and let the hardware build the array.

**Step 4: Connect the Pegasus R4 to your Linux Machine**
1. Disconnect the Pegasus from the Mac and connect it to your Linux machine via a Thunderbolt cable. 
2. Because Linux utilizes Thunderbolt security, you may need to manually authorize the connection before the PCIe tunnels are created and the `stex` driver can see the drive. 
3. Open your Linux terminal and use the `boltctl` utility to find the device UUID and enroll it:
   ```bash
   boltctl enroll <DEVICE_UUID>
   ```
   *Note: Enrolling the device stores a secure key so it authorizes automatically in the future. You can also use `boltctl authorize <DEVICE_UUID>` for a one-time connection*.

**Step 5: Format the Array with a Native Linux File System**
Now that the hardware RAID array is passed to Linux as a single unformatted block device, you can format it with a native Linux file system (like `ext4`) to guarantee the best read/write performance.
1. Identify the new logical drive block device using `lsblk` (it will likely appear as something like `/dev/sdb` or `/dev/sdc`).
2. Reformat the drive using standard Linux partitioning and formatting tools. For an `ext4` file system, use:
   ```bash
   sudo mkfs.ext4 /dev/sdX
   ```
   *(Replace `sdX` with the correct device identifier)*.

**Step 6: Mount the New File System**
1. Create a persistent mount point on your Linux system:
   ```bash
   sudo mkdir -p /media/pegasus
   ```
2. Mount the freshly formatted drive for read and write access:
   ```bash
   sudo mount /dev/sdX /media/pegasus
   ```
   *(To make this permanent, you would add the drive's UUID to your `/etc/fstab` file).*

   If you did not see the "Format" checkbox, it is likely because you used the **Automatic** or **Express** configuration option in the PROMISE Utility Wizard, which always formats the logical drives for macOS automatically. The checkbox allowing you to skip formatting only appears if you select the **Advanced** configuration path.

**Do not worry—this is completely fine and will not prevent you from using the array in Linux.** The underlying hardware RAID array has still been built successfully. The macOS volume is merely a software-level filesystem partition that was placed on top of your new hardware array. You can easily wipe and overwrite it once connected to your Linux machine.

Here is how to seamlessly overwrite the macOS volume and prepare the drive for Linux:

**1. Connect and Authorize on Linux**
Disconnect the Pegasus from the Mac, plug it into your Linux machine, and authorize the Thunderbolt connection using `boltctl`.
```bash
boltctl enroll <DEVICE_UUID>
```

**2. Identify the Drive and the macOS Partitions**
Find out what block device identifier Linux has assigned your new logical drive using:
```bash
lsblk -f
```
You will likely see the drive (e.g., `/dev/sdb` or `/dev/sdc`) along with the macOS partitions the PROMISE utility just created (e.g., `/dev/sdb1`, `/dev/sdb2` containing an HFS+ or APFS volume).

**3. Wipe the macOS Partition Data**
To ensure a clean slate and prevent any conflicts with the macOS GUID Partition Table (GPT), it is best practice to wipe the existing macOS filesystem signatures before reformatting. You can do this using the `wipefs` utility:
```bash
sudo wipefs -a /dev/sdX
```
*(Warning: Ensure you replace `sdX` with the exact drive letter of your Pegasus unit, as this will instantly destroy the partition table on the targeted drive).*

**4. Format with a Native Linux Filesystem**
With the macOS volume signatures wiped, the hardware RAID array is a blank block device again. Proceed to format it directly with `ext4` for optimal read/write Linux performance:
```bash
sudo mkfs.ext4 /dev/sdX
```

**5. Mount the Drive**
Finally, create your mount point and mount the freshly formatted Linux drive:
```bash
sudo mkdir -p /media/pegasus
sudo mount /dev/sdX /media/pegasus
```

By completing these steps, the macOS volume is permanently overwritten, leaving you with a clean, high-performance Linux filesystem.