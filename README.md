# 💡 Dimmer - The Disk Imager

> *Realize bright ideas with less energy!*

Dimmer is a tool that uses a simple textual description of a disk image to create actual images.

This tool is incredibly valuable when implementing your own operating system, embedded systems or other kinds of deployment.

## Example

```rb
mbr-part
    bootloader paste-file "./syslinux.bin"
    part # partition 1
        type fat16-lba
        size 25M
        contains vfat fat16
            label "BOOT"
            copy-dir "/syslinux" "./bootfs/syslinux"
        endfat
    endpart
    part # partition 2
        type fat32-lba
        contains vfat fat32
            label "OS"
            mkdir "/home/dimmer"
            copy-file "/home/dimmer/.config/dimmer.cfg" "./dimmer.cfg"
            !include "./rootfs/files.dis"
        endfat
    endpart
    ignore # partition 3
    ignore # partition 4
```

## Available Content Types

### Empty Content (`empty`)

This type of content does not change its range at all and keeps it empty. No bytes will be emitted.

```plain
empty
```

### Fill (`fill`)

The *Fill* type will fill the remaining size in its space with the given `<byte>` value.

```plain
fill <byte>
```

### Paste File Contents (`paste-file`)

The *Raw* type will include the file at `<path>` verbatim and will error, if not enough space is available.

`<path>` is relative to the current file.

```plain
paste-file <path>
```

### MBR Partition Table (`mbr-part`)

```plain
mbr-part
    [bootloader <content>]
    [part <…> | ignore] # partition 1
    [part <…> | ignore] # partition 2
    [part <…> | ignore] # partition 3
    [part <…> | ignore] # partition 4
```

```plain
part
    type <type-id>
    [bootable]
    [size <bytes>]
    [offset <bytes>]
    contains <content>
endpart
```

If `bootloader <content>` is given, will copy the `<content>` into the boot block, setting the boot code.

The `mbr-part` component will end after all 4 partitions are specified.

- Each partition must specify the `<type-id>` (see table below) to mark the partition type as well as `contains <content>` which defines what's stored in the partition.
- If `bootable` is present, the partition is marked as bootable.
- `size <bytes>` is required for all but the last partition and defines the size in bytes. It can use disk-size specifiers.
- `offset <bytes>` is required for either all or no partition and defines the disk offset for the partitions. This can be used to explicitly place the partitions.

#### Partition Types

| Type         | ID   | Description                                                                                                                                        |
| ------------ | ---- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `empty`      | 0x00 | No content                                                                                                                                         |
| `fat12`      | 0x01 | [FAT12](https://en.wikipedia.org/wiki/FAT12)                                                                                                       |
| `ntfs`       | 0x07 | [NTFS](https://en.wikipedia.org/wiki/NTFS)                                                                                                         |
| `fat32-chs`  | 0x0B | [FAT32](https://en.wikipedia.org/wiki/FAT32) with [CHS](https://en.wikipedia.org/wiki/Cylinder-head-sector) addressing                             |
| `fat32-lba`  | 0x0C | [FAT32](https://en.wikipedia.org/wiki/FAT32) with [LBA](https://en.wikipedia.org/wiki/Logical_block_addressing) addressing                         |
| `fat16-lba`  | 0x0E | [FAT16B](https://en.wikipedia.org/wiki/File_Allocation_Table#FAT16B) with [LBA](https://en.wikipedia.org/wiki/Logical_block_addressing) addressing |
| `linux-swap` | 0x82 | [Linux swap space](https://en.wikipedia.org/wiki/Swap_space#Linux)                                                                                 |
| `linux-fs`   | 0x83 | Any [Linux file system](https://en.wikipedia.org/wiki/File_system#Linux)                                                                           |
| `linux-lvm`  | 0x8E | [Linux LVM](https://en.wikipedia.org/wiki/Logical_Volume_Manager_(Linux))                                                                          |

A complete list can be [found on Wikipedia](https://en.wikipedia.org/wiki/Partition_type), but [we do not support that yet](https://github.com/zig-osdev/disk-image-step/issues/8).

### GPT Partition Table (`gpt-part`)

```plain

```

### FAT File System (`vfat`)

```plain
vfat <type>
    [label <fs-label>]
    [fats <fatcount>]
    [root-size <count>]
    [sector-align <align>]
    [cluster-size <size>]
    <fs-ops...>
endfat
```

| Parameter    | Values                         | Description                                                                                                                                                                                                                                                                                                                                                           |
| ------------ | ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `<type>`     | `fat12`, `fat16`, `fat32`      | Selects the type of FAT filesystem that is created                                                                                                                                                                                                                                                                                                                    |
| `<fatcount>` | `one`, `two`                   | Number of FAT count. Select between small and safe.                                                                                                                                                                                                                                                                                                                   |
| `<fs-label>` | ascii string <= 11 chars       | Display name of the volume.                                                                                                                                                                                                                                                                                                                                           |
| `<count>`    | integers <= 32768              | Number of entries in the root directory.                                                                                                                                                                                                                                                                                                                              |
| `<align>`    | power of two >= 1 and <= 32768 | Specifies alignment of the volume data area (file allocation pool, usually erase block boundary of flash memory media) in unit of sector. The valid value for this member is between 1 and 32768 inclusive in power of 2. If a zero (the default value) or any invalid value is given, the function obtains the block size from lower layer with disk_ioctl function. |
| `<size>`     | powers of two                  | Specifies size of the allocation unit (cluter) in unit of byte.                                                                                                                                                                                                                                                                                                       |

## Standard Filesystem Operations

All `<path>` values use an absolute unix-style path, starting with a `/` and using `/` as a file separator.

All operations do create the parent directories if necessary.

### Create Directory (`mkdir`)

```plain
mkdir <path>
```

Creates a directory.

### Create File (`create-file`)

```plain
create-file <path> <size> <content>
```

Creates a file in the file system with `<size>` bytes (can use sized spec) and embeds another `<content>` element.

This can be used to construct special or nested files ad-hoc.

### Copy File (`copy-file`)

```plain
copy-file <path> <host-path>
```

Copies a file from `<host-path>` (relative to the current file) into the filesystem at `<path>`.

### Copy Directory (`copy-dir`)

```plain
copy-file <path> <host-path>
```

Copies a directory from `<host-path>` (relative to the current file) *recursively* into the filesystem at `<path>`.

This will include *all files* from `<host-path>`.

## Compiling


- Install [Zig 0.14.0](https://ziglang.org/download/).
- Invoke `zig build -Drelease` in the repository root.
- Execute `./zig-out/bin/dim --help` to verify your compilation worked.
