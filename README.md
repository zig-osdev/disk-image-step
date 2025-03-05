# Disk Image Creator

The Disk Image Creator is a tool that uses a simple textual description of a disk image to create actual images.

This tool is incredibly valuable when implementing your own operating system or deployments.

## Example

```plain

```

## Available Content Types

```plain

```

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

### Raw Binary Content (`raw`)

The *Raw* type will include the file at `<path>` verbatim and will error, if not enough space is available.

`<path>` is relative to the current file.

```plain
raw <path>
```

### MBR Partition Table (`mbr-part`)

```plain

```

### GPT Partition Table (`gpt-part`)

```plain

```

### FAT File System (`fat`)

```plain

```

## Compiling

- Install [Zig 0.14.0](https://ziglang.org/download/).
- Invoke `zig build -Drelease` in the repository root.
- Execute `./zig-out/bin/dim --help` to verify your compilation worked.
