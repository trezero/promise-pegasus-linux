 sudo boltctl monitor 
Bolt Version  : 0.9
Daemon API    : 1
Client API    : 1
Security Level: user
Auth Mode     : enabled
Ready
1777312563418729 [c9030000-0000-7d18-a271-27c448213116]                     Pegasus3-R |     status -> BOLT_STATUS_DISCONNECTED
1777312563418742 [c9030000-0000-7d18-a271-27c448213116]                     Pegasus3-R |     domain -> 
1777312563418746 [c9030000-0000-7d18-a271-27c448213116]                     Pegasus3-R |    syspath -> 
1777312563418748 [c9030000-0000-7d18-a271-27c448213116]                     Pegasus3-R |     parent -> 
1777312568828256 Probing started
1777312568828325 [c9030000-0000-7d18-a271-27c448213116]                     Pegasus3-R |  linkspeed -> ((BoltLinkSpeed*) 0x733b0800ad30)
1777312568828343 [c9030000-0000-7d18-a271-27c448213116]                     Pegasus3-R |   authtime -> 0
1777312568828349 [c9030000-0000-7d18-a271-27c448213116]                     Pegasus3-R |   conntime -> 1777312568
1777312568828352 [c9030000-0000-7d18-a271-27c448213116]                     Pegasus3-R |  authflags -> BOLT_AUTH_NONE
1777312568828357 [c9030000-0000-7d18-a271-27c448213116]                     Pegasus3-R |     status -> BOLT_STATUS_CONNECTED
1777312568828361 [c9030000-0000-7d18-a271-27c448213116]                     Pegasus3-R |     domain -> e0d70000-0034-19e1-ffff-ffffffffffff
1777312568828363 [c9030000-0000-7d18-a271-27c448213116]                     Pegasus3-R |    syspath -> /sys/devices/pci0000:80/0000:80:1d.0/0000:87:00.0/0000:88:00.0/0000:89:00.0/domain0/0-0/0-3
1777312568828367 [c9030000-0000-7d18-a271-27c448213116]                     Pegasus3-R |     parent -> e0d70000-0034-19e1-ffff-ffffffffffff
1777312568828369 [c9030000-0000-7d18-a271-27c448213116]                     Pegasus3-R | generation -> 3
1777312568828566 [c9030000-0000-7d18-a271-27c448213116]                     Pegasus3-R |     status -> BOLT_STATUS_AUTHORIZING
1777312570138893 [c9030000-0000-7d18-a271-27c448213116]                     Pegasus3-R |     status -> BOLT_STATUS_AUTHORIZED
1777312570138909 [c9030000-0000-7d18-a271-27c448213116]                     Pegasus3-R |   authtime -> 1777312570
1777312572832370 Probing done

 sudo boltctl enroll c9030000-0000-7d18-a271-27c448213116
device with id 'c9030000-0000-7d18-a271-27c448213116' already enrolled.

 lsblk -o NAME,SIZE,TYPE,MODEL
NAME          SIZE TYPE MODEL
loop0        49.1M loop 
loop1           4K loop 
loop3        55.5M loop 
loop4        55.5M loop 
loop5        63.8M loop 
loop6        63.8M loop 
loop7          74M loop 
loop8          74M loop 
loop9        66.8M loop 
loop10       66.8M loop 
loop11       49.3M loop 
loop12       49.1M loop 
loop13      255.2M loop 
loop14      273.5M loop 
loop15      164.8M loop 
loop16      349.7M loop 
loop17      516.2M loop 
loop18      531.4M loop 
loop19      669.8M loop 
loop20      606.1M loop 
loop21       91.7M loop 
loop22        395M loop 
loop23       12.2M loop 
loop24       12.3M loop 
loop25       48.4M loop 
loop26      184.4M loop 
loop27      184.4M loop 
loop28        580K loop 
loop29        940K loop 
loop30        940K loop 
loop31        6.4M loop 
loop32        7.6M loop 
loop33        7.6M loop 
loop34        580K loop 
nvme1n1       1.8T disk Corsair MP700 PRO                       
├─nvme1n1p1   487M part 
└─nvme1n1p2   1.8T part 
nvme0n1       1.8T disk CT2000T705SSD3                          
├─nvme0n1p1    16M part 
└─nvme0n1p2   1.8T part 
nvme2n1     931.5G disk Sabrent SB-RKT5-1TB                     
├─nvme2n1p1   100M part 
├─nvme2n1p2    16M part 
├─nvme2n1p3 930.7G part 
└─nvme2n1p4   730M part 

 sudo dmesg | egrep -i 'scsi|sd[a-z]|pegasus'
[1982841.447021] sd 0:0:0:0: [sda] Synchronizing SCSI cache
[1982841.453112] scsi host0: resetting host
[1982846.830647] thunderbolt 0-3: Promise Technology, Inc. Pegasus3-R

Here’s what each of those commands does, step by step, and what’s happening under the hood.

***

## `sudo lsblk -f`

`lsblk` = “list block devices.” It queries the kernel (via `/sys` and udev) and prints a tree of all disks and partitions attached to the system. [ioflood](https://ioflood.com/blog/install-lsblk-command-linux/)

- With `-f` (“filesystems”), it adds filesystem-related columns: `FSTYPE` (ext4, ntfs, etc.), `LABEL`, `UUID`, and `MOUNTPOINT`. [scaler](https://www.scaler.com/topics/lsblk-command-in-linux/)
- You use this to:
  - See which `/dev/sdX` is the Pegasus logical disk (size/model help identify it). [kodekloud](https://kodekloud.com/blog/linux-list-disks/)
  - Check if it already has a partition table and filesystem (so you don’t nuke the wrong disk).

Running it with `sudo` isn’t strictly required for basic info, but it ensures you see all devices and metadata.

***

## `sudo parted /dev/sdb -- mklabel gpt`

`parted` is a partition-table editor. [mankier](https://www.mankier.com/8/parted)

- `/dev/sdb` is the whole disk you want to operate on (the Pegasus RAID volume in this example).  
- `mklabel gpt` tells `parted` to create a new GUID Partition Table (GPT) on that disk. [oneuptime](https://oneuptime.com/blog/post/2026-03-04-create-gpt-partitions-parted-rhel-9/view)
- The `--` separates the device from subsequent commands; everything after it is a parted command. [wiki.archlinux](https://wiki.archlinux.org/title/Parted)

Effect:

- It **wipes the existing partition table** (MBR/GPT) and replaces it with a fresh GPT. [access.redhat](https://access.redhat.com/sites/default/files/attachments/parted_0.pdf)
- Any existing partitions and data on `/dev/sdb` become inaccessible and are effectively destroyed.

You only do this on a disk you are OK completely reinitializing.

***

## `sudo parted -a opt /dev/sdb -- mkpart primary ext4 0% 100%`

Still using `parted`, this time to create a partition. [mankier](https://www.mankier.com/8/parted)

- `-a opt` = optimal alignment. It aligns partitions to the disk’s preferred boundaries for performance and SSD/RAID friendliness. [oneuptime](https://oneuptime.com/blog/post/2026-03-04-create-gpt-partitions-parted-rhel-9/view)
- `/dev/sdb` again specifies the target disk.  
- `mkpart primary ext4 0% 100%` breaks down as:
  - `mkpart` = make a new partition. [mankier](https://www.mankier.com/8/parted)
  - `primary` = a label in this context (older MBR terminology; for GPT it becomes the partition’s name if supported, but is mostly syntactic sugar). [wiki.archlinux](https://wiki.archlinux.org/title/Parted)
  - `ext4` = the intended filesystem type; parted stores this as a partition-type hint, but does not actually format the filesystem. [wiki.archlinux](https://wiki.archlinux.org/title/Parted)
  - `0% 100%` = start at the beginning of the free space on the disk, end at the end of the disk, so it uses all available space. [oneuptime](https://oneuptime.com/blog/post/2026-03-04-create-gpt-partitions-parted-rhel-9/view)

Effect:

- Creates one big partition (`/dev/sdb1`) spanning the whole disk, properly aligned, ready to be formatted. [oneuptime](https://oneuptime.com/blog/post/2026-03-04-create-gpt-partitions-parted-rhel-9/view)

Important: this still does **not** create a usable filesystem; it just defines the partition boundaries and metadata in the GPT.

***

## `sudo mkfs.ext4 -L pegasus_raid /dev/sdb1`

`mkfs.ext4` actually creates the filesystem. [archive.phocean](https://archive.phocean.net/2016/03/20/a-journey-with-btrfs.html)

- `mkfs.ext4` = “make filesystem, ext4 type.” It lays down all ext4 on-disk structures (superblocks, inodes, journal, etc.) inside `/dev/sdb1`.  
- `-L pegasus_raid` sets the filesystem **label** to `pegasus_raid`, which shows up in `lsblk -f` and can be used in `/etc/fstab` instead of UUID. [facebook](https://www.facebook.com/groups/archlinuxen/posts/10159296352923393/)
- `/dev/sdb1` is the partition you just created.

Effect:

- Completely overwrites `/dev/sdb1`’s contents with a brand-new empty ext4 filesystem.  
- After this, Linux can mount it, and it will appear as a normal ext4 volume with label `pegasus_raid`.

***

## Putting it together

In order:

1. `lsblk -f` – discover the right disk and see its current layout/filesystems. [ioflood](https://ioflood.com/blog/install-lsblk-command-linux/)
2. `parted ... mklabel gpt` – wipe existing partitioning and create a modern GPT table on that disk. [access.redhat](https://access.redhat.com/sites/default/files/attachments/parted_0.pdf)
3. `parted ... mkpart ... 0% 100%` – create a single, maximally sized partition on that GPT disk. [mankier](https://www.mankier.com/8/parted)
4. `mkfs.ext4 -L pegasus_raid /dev/sdb1` – format that partition with ext4 so you can mount and use it. [archive.phocean](https://archive.phocean.net/2016/03/20/a-journey-with-btrfs.html)


lsblk -f
NAME        FSTYPE FSVER LABEL UUID FSAVAIL FSUSE% MOUNTPOINTS
loop0                                     0   100% /snap/cups/1183
loop1                                     0   100% /snap/bare/5
loop3                                     0   100% /snap/core18/2979
loop4                                     0   100% /snap/core18/2999
loop5                                     0   100% /snap/core20/2717
loop6                                     0   100% /snap/core20/2769
loop7                                     0   100% /snap/core22/2339
loop8                                     0   100% /snap/core22/2411
loop9                                     0   100% /snap/core24/1499
loop10                                    0   100% /snap/core24/1587
loop11                                    0   100% /snap/snapd/26865
loop12                                    0   100% /snap/cups/1170
loop13                                    0   100% /snap/firefox/8030
loop14                                    0   100% /snap/firefox/8054
loop15                                    0   100% /snap/gnome-3-28-1804/198
loop16                                    0   100% /snap/gnome-3-38-2004/143
loop17                                    0   100% /snap/gnome-42-2204/226
loop18                                    0   100% /snap/gnome-42-2204/247
loop19                                    0   100% /snap/gnome-46-2404/145
loop20                                    0   100% /snap/gnome-46-2404/153
loop21                                    0   100% /snap/gtk-common-themes/1535
loop22                                    0   100% /snap/mesa-2404/1165
loop23                                    0   100% /snap/snap-store/1216
loop24                                    0   100% /snap/snap-store/959
loop25                                    0   100% /snap/snapd/26382
loop26                                    0   100% /snap/chromium/3423
loop27                                    0   100% /snap/chromium/3411
loop28                                    0   100% /snap/snapd-desktop-integration/357
loop29                                    0   100% /snap/speedtest/12
loop30                                    0   100% /snap/speedtest/9
loop31                                    0   100% /snap/system-information/6
loop32                                    0   100% /snap/yq/2759
loop33                                    0   100% /snap/yq/2748
loop34                                    0   100% /snap/snapd-desktop-integration/361
nvme1n1                                            
├─nvme1n1p1                          479.9M     1% /boot/efi
└─nvme1n1p2                          197.3G    84% /var/snap/firefox/common/host-hunspell
                                                   /
nvme0n1                                            
├─nvme0n1p1                                        
└─nvme0n1p2                                        
nvme2n1                                            
├─nvme2n1p1                                        
├─nvme2n1p2                                        
├─nvme2n1p3                                        
└─nvme2n1p4                                        


[1983288.644439] thunderbolt 0-3: device disconnected
[1983294.551490] usb 1-12.2: new low-speed USB device number 52 using xhci_hcd
[1983294.617761] usb 1-12.2: device descriptor read/64, error -32
[1983294.785794] usb 1-12.2: device descriptor read/64, error -32
[1983294.951556] usb 1-12.2: new low-speed USB device number 53 using xhci_hcd
[1983295.017811] usb 1-12.2: device descriptor read/64, error -32
[1983295.185559] usb 1-12.2: device descriptor read/64, error -32
[1983295.287759] usb 1-12-port2: attempt power cycle
[1983295.433234] thunderbolt 0000:89:00.0: 3: DROM device_rom_revision 0x2 unknown
[1983295.444680] thunderbolt 0-3: new device found, vendor=0x2 device=0x11
[1983295.444681] thunderbolt 0-3: Promise Technology, Inc. Pegasus3-R
[1983295.867457] usb 1-12.2: new low-speed USB device number 54 using xhci_hcd
[1983295.868219] usb 1-12.2: Device not responding to setup address.
[1983296.071946] usb 1-12.2: Device not responding to setup address.
[1983296.279535] usb 1-12.2: device not accepting address 54, error -71
[1983296.343445] usb 1-12.2: new low-speed USB device number 55 using xhci_hcd
[1983296.344115] usb 1-12.2: Device not responding to setup address.
[1983296.552250] usb 1-12.2: Device not responding to setup address.
[1983296.759446] usb 1-12.2: device not accepting address 55, error -71
[1983296.759525] usb 1-12-port2: unable to enumerate USB device


