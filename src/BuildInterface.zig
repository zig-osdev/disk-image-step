//!
//! This file implements the Zig build system interface for Dimmer.
//!
//! It is included by it's build.zig
//!
const std = @import("std");

const Interface = @This();

pub const kiB = 1024;
pub const MiB = 1024 * 1024;
pub const GiB = 1024 * 1024 * 1024;

builder: *std.Build,
dimmer_exe: *std.Build.Step.Compile,

pub fn init(builder: *std.Build, dep: *std.Build.Dependency) Interface {
    return .{
        .builder = builder,
        .dimmer_exe = dep.artifact("dimmer"),
    };
}

pub fn createDisk(dimmer: Interface, size: u64, content: Content) std.Build.LazyPath {
    const b = dimmer.builder;

    const write_files = b.addWriteFiles();

    const script_source, const variables = renderContent(write_files, b.allocator, content);

    const script_file = write_files.add("image.dis", script_source);

    const compile_script = b.addRunArtifact(dimmer.dimmer_exe);

    _ = compile_script.addPrefixedDepFileOutputArg("--deps-file=", "image.d");

    compile_script.addArg(b.fmt("--size={d}", .{size}));

    compile_script.addPrefixedFileArg("--script=", script_file);
    compile_script.addPrefixedDirectoryArg("--script-root=", .{ .cwd_relative = "." });

    const result_file = compile_script.addPrefixedOutputFileArg("--output=", "disk.img");

    {
        var iter = variables.iterator();
        while (iter.next()) |kvp| {
            const key = kvp.key_ptr.*;
            const path, const usage = kvp.value_ptr.*;

            switch (usage) {
                .file => compile_script.addPrefixedFileArg(
                    b.fmt("{s}=", .{key}),
                    path,
                ),
                .directory => compile_script.addPrefixedDirectoryArg(
                    b.fmt("{s}=", .{key}),
                    path,
                ),
            }
        }
    }

    return result_file;
}

fn renderContent(
    wfs: *std.Build.Step.WriteFile,
    allocator: std.mem.Allocator,
    content: Content,
) struct { []const u8, ContentWriter.VariableMap } {
    var code: std.Io.Writer.Allocating = .init(allocator);
    defer code.deinit();

    var variables: ContentWriter.VariableMap = .init(allocator);

    var cw: ContentWriter = .{
        .code = &code.writer,
        .wfs = wfs,
        .vars = &variables,
    };

    cw.render(content) catch @panic("out of memory");

    const source = std.mem.trim(
        u8,
        code.toOwnedSlice() catch @panic("out of memory"),
        " \r\n\t",
    );

    variables.sort(struct {
        map: *ContentWriter.VariableMap,

        pub fn lessThan(ctx: @This(), lhs: usize, rhs: usize) bool {
            return std.mem.lessThan(u8, ctx.map.keys()[lhs], ctx.map.keys()[rhs]);
        }
    }{
        .map = &variables,
    });

    return .{ source, variables };
}

const ContentWriter = struct {
    pub const VariableMap = std.StringArrayHashMap(struct { std.Build.LazyPath, ContentWriter.UsageHint });

    wfs: *std.Build.Step.WriteFile,
    code: *std.Io.Writer,
    vars: *VariableMap,

    fn render(cw: ContentWriter, content: Content) !void {
        // Always insert some padding before and after:
        try cw.code.writeAll(" ");
        errdefer cw.code.writeAll(" ") catch {};

        switch (content) {
            .empty => {
                try cw.code.writeAll("empty");
            },

            .fill => |data| {
                try cw.code.print("fill 0x{X:0>2}", .{data});
            },

            .paste_file => |data| {
                try cw.code.print("paste-file {f}", .{cw.fmtLazyPath(data, .file)});
            },

            .mbr_part_table => |data| {
                try cw.code.writeAll("mbr-part\n");

                if (data.bootloader) |loader| {
                    try cw.code.writeAll("  bootloader ");
                    try cw.render(loader.*);
                    try cw.code.writeAll("\n");
                }

                for (data.partitions) |mpart| {
                    if (mpart) |part| {
                        try cw.code.writeAll("  part\n");
                        switch (part.type) {
                            .named => |id| try cw.code.print("    type {s}\n", .{@tagName(id)}),
                            .custom => |id| try cw.code.print("    type 0x{X:0>2}\n", .{id}),
                        }
                        if (part.bootable) {
                            try cw.code.writeAll("    bootable\n");
                        }
                        if (part.offset) |offset| {
                            try cw.code.print("    offset {d}\n", .{offset});
                        }
                        if (part.size) |size| {
                            try cw.code.print("    size {d}\n", .{size});
                        }
                        try cw.code.writeAll("    contains");
                        try cw.render(part.data);
                        try cw.code.writeAll("\n");
                        try cw.code.writeAll("  endpart\n");
                    } else {
                        try cw.code.writeAll("  ignore\n");
                    }
                }
            },

            .gpt_part_table => |data| {
                try cw.code.writeAll("gpt-part\n");

                if (data.legacy_bootable) {
                    try cw.code.writeAll("  legacy-bootable\n");
                }

                for (data.partitions) |part| {
                    try cw.code.writeAll("  part\n");
                    try cw.code.writeAll("    type ");
                    switch (part.type) {
                        .name => |name| {
                            try cw.code.writeAll(@tagName(name));
                        },
                        .guid => |guid_text| {
                            try cw.code.writeAll(&guid_text);
                        },
                    }
                    try cw.code.writeByte('\n');

                    if (part.name) |name| {
                        try cw.code.print("    name \"{f}\"\n", .{std.zig.fmtString(name)});
                    }
                    if (part.offset) |offset| {
                        try cw.code.print("    offset {d}\n", .{offset});
                    }
                    if (part.size) |size| {
                        try cw.code.print("    size {d}\n", .{size});
                    }
                    try cw.code.writeAll("    contains");
                    try cw.render(part.data);
                    try cw.code.writeAll("\n");
                    try cw.code.writeAll("  endpart\n");
                }

                try cw.code.writeAll("endgpt");
            },

            .vfat => |data| {
                try cw.code.print("vfat {s}\n", .{
                    @tagName(data.format),
                });
                if (data.label) |label| {
                    try cw.code.print("  label {f}\n", .{
                        fmtPath(label),
                    });
                }

                try cw.renderFileSystemTree(data.tree);

                try cw.code.writeAll("endfat\n");
            },
        }
    }

    fn renderFileSystemTree(cw: ContentWriter, fs: FileSystem) !void {
        for (fs.items) |item| {
            switch (item) {
                .empty_dir => |dir| try cw.code.print("mkdir {f}\n", .{
                    fmtPath(dir),
                }),

                .copy_dir => |copy| try cw.code.print("copy-dir {f} {f}\n", .{
                    fmtPath(copy.destination),
                    cw.fmtLazyPath(copy.source, .directory),
                }),

                .copy_file => |copy| try cw.code.print("copy-file {f} {f}\n", .{
                    fmtPath(copy.destination),
                    cw.fmtLazyPath(copy.source, .file),
                }),

                .include_script => |script| try cw.code.print("!include {f}\n", .{
                    cw.fmtLazyPath(script, .file),
                }),
            }
        }
    }

    const PathFormatter = struct {
        path: []const u8,

        pub fn format(
            p: PathFormatter,
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            const path = p.path;
            const is_safe_word = for (path) |char| {
                switch (char) {
                    'A'...'Z',
                    'a'...'z',
                    '0'...'9',
                    '_',
                    '-',
                    '/',
                    '.',
                    ':',
                    => {},
                    else => break false,
                }
            } else true;

            if (is_safe_word) {
                try writer.writeAll(path);
            } else {
                try writer.writeAll("\"");

                for (path) |c| {
                    if (c == '\\') {
                        try writer.writeAll("/");
                    } else {
                        try writer.print("{f}", .{std.zig.fmtString(&[_]u8{c})});
                    }
                }

                try writer.writeAll("\"");
            }
        }
    };
    const LazyPathFormatter = std.fmt.Alt(
        struct { ContentWriter, std.Build.LazyPath, UsageHint },
        formatLazyPath,
    );
    const UsageHint = enum { file, directory };

    fn fmtLazyPath(
        cw: ContentWriter,
        path: std.Build.LazyPath,
        hint: UsageHint,
    ) LazyPathFormatter {
        return .{ .data = .{ cw, path, hint } };
    }

    fn fmtPath(path: []const u8) PathFormatter {
        return .{ .path = path };
    }

    fn formatLazyPath(
        data: struct { ContentWriter, std.Build.LazyPath, UsageHint },
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const cw, const path, const hint = data;

        switch (path) {
            .cwd_relative,
            .dependency,
            .src_path,
            => {

                // We can safely call getPath2 as we can fully resolve the path
                // already
                const rel_path = path.getPath2(cw.wfs.step.owner, &cw.wfs.step);

                const full_path = if (!std.fs.path.isAbsolute(rel_path))
                    std.fs.cwd().realpathAlloc(cw.wfs.step.owner.allocator, rel_path) catch @panic("oom")
                else
                    rel_path;

                if (!std.fs.path.isAbsolute(full_path)) {
                    const cwd = std.fs.cwd().realpathAlloc(cw.wfs.step.owner.allocator, ".") catch @panic("oom");
                    std.debug.print("non-absolute path detected for {t}: cwd=\"{f}\" path=\"{f}\"\n", .{
                        path,
                        std.zig.fmtString(cwd),
                        std.zig.fmtString(full_path),
                    });
                    @panic("non-absolute path detected!");
                }

                try writer.print("{f}", .{
                    fmtPath(full_path),
                });
            },

            .generated => {
                // this means we can't emit the variable just verbatim, but we
                // actually have a build-time dependency
                const var_id = cw.vars.count() + 1;
                const var_name = cw.wfs.step.owner.fmt("PATH{}", .{var_id});

                cw.vars.put(var_name, .{ path, hint }) catch return error.WriteFailed;

                try writer.print("${s}", .{var_name});
            },
        }
    }
};

pub const Content = union(enum) {
    empty,
    fill: u8,
    paste_file: std.Build.LazyPath,
    mbr_part_table: MbrPartTable,
    gpt_part_table: GptPartTable,
    vfat: FatFs,
};

pub const MbrPartTable = struct {
    bootloader: ?*const Content = null,
    partitions: [4]?*const Partition,

    pub const PartType = enum(u8) {
        empty,
        fat12,
        ntfs,
        @"fat32-chs",
        @"fat32-lba",
        @"fat16-lba",
        @"linux-swa",
        @"linux-fs",
        @"linux-lvm",
    };

    pub const Partition = struct {
        type: union(enum) {
            named: PartType,
            custom: u8,

            pub fn predefined(value: PartType) @This() {
                return .{ .named = value };
            }
            pub fn id(value: u8) @This() {
                return .{ .custom = value };
            }
        },
        bootable: bool = false,
        size: ?u64 = null,
        offset: ?u64 = null,
        data: Content,
    };
};

pub const GptPartTable = struct {
    legacy_bootable: bool = false,
    partitions: []const Partition,

    pub const Partition = struct {
        type: union(enum) {
            name: enum {
                unused,
                @"efi-system",
                @"legacy-mbr",
                @"bios-boot",
                @"microsoft-basic-data",
                @"microsoft-reserved",
                @"windows-recovery",
                plan9,
                @"linux-swap",
                @"linux-fs",
                @"linux-reserved",
                @"linux-lvm",
            },
            guid: [36]u8,
        },
        name: ?[]const u8 = null,
        size: ?u64 = null,
        offset: ?u64 = null,
        data: Content,
    };
};

pub const FatFs = struct {
    format: enum {
        fat12,
        fat16,
        fat32,
    } = .fat32,

    label: ?[]const u8 = null,

    // TODO: fats <fatcount>
    // TODO: root-size <count>
    // TODO: sector-align <align>
    // TODO: cluster-size <size>

    tree: FileSystem,
};

pub const FileSystemBuilder = struct {
    b: *std.Build,
    list: std.ArrayListUnmanaged(FileSystem.Item),

    pub fn init(b: *std.Build) FileSystemBuilder {
        return FileSystemBuilder{
            .b = b,
            .list = .{},
        };
    }

    pub fn finalize(fsb: *FileSystemBuilder) FileSystem {
        return .{
            .items = fsb.list.toOwnedSlice(fsb.b.allocator) catch @panic("out of memory"),
        };
    }

    pub fn includeScript(fsb: *FileSystemBuilder, source: std.Build.LazyPath) void {
        fsb.list.append(fsb.b.allocator, .{
            .include_script = source.dupe(fsb.b),
        }) catch @panic("out of memory");
    }

    pub fn copyFile(fsb: *FileSystemBuilder, source: std.Build.LazyPath, destination: []const u8) void {
        fsb.list.append(fsb.b.allocator, .{
            .copy_file = .{
                .source = source.dupe(fsb.b),
                .destination = fsb.b.dupe(destination),
            },
        }) catch @panic("out of memory");
    }

    pub fn copyDirectory(fsb: *FileSystemBuilder, source: std.Build.LazyPath, destination: []const u8) void {
        fsb.list.append(fsb.b.allocator, .{
            .copy_dir = .{
                .source = source.dupe(fsb.b),
                .destination = fsb.b.dupe(destination),
            },
        }) catch @panic("out of memory");
    }

    pub fn mkdir(fsb: *FileSystemBuilder, destination: []const u8) void {
        fsb.list.append(fsb.b.allocator, .{
            .empty_dir = fsb.b.dupe(destination),
        }) catch @panic("out of memory");
    }
};

pub const FileSystem = struct {
    pub const Copy = struct {
        source: std.Build.LazyPath,
        destination: []const u8,
    };

    pub const Item = union(enum) {
        empty_dir: []const u8,
        copy_dir: Copy,
        copy_file: Copy,
        include_script: std.Build.LazyPath,
    };

    // format: Format,
    // label: []const u8,
    items: []const Item,

    // private:
    // executable: ?std.Build.LazyPath = null,
};
