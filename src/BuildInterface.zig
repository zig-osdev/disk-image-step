//!
//! This file implements the Zig build system interface for Dimmer.
//!
//! It is included by it's build.zig
//!
const std = @import("std");

const Interface = @This();

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

    const result_file = compile_script.addPrefixedOutputFileArg("--output=", "disk.img");

    {
        var iter = variables.iterator();
        while (iter.next()) |kvp| {
            const key = kvp.key_ptr.*;
            const value = kvp.value_ptr.*;

            compile_script.addPrefixedFileArg(
                b.fmt("{s}=", .{key}),
                value,
            );
        }
    }

    return result_file;
}

fn renderContent(wfs: *std.Build.Step.WriteFile, allocator: std.mem.Allocator, content: Content) struct { []const u8, std.StringHashMap(std.Build.LazyPath) } {
    var code: std.ArrayList(u8) = .init(allocator);
    defer code.deinit();

    var variables: std.StringHashMap(std.Build.LazyPath) = .init(allocator);

    renderContentInner(
        wfs,
        code.writer(),
        &variables,
        content,
    ) catch @panic("out of memory");

    const source = std.mem.trim(
        u8,
        code.toOwnedSlice() catch @panic("out of memory"),
        " \r\n\t",
    );

    return .{ source, variables };
}

fn renderContentInner(
    wfs: *std.Build.Step.WriteFile,
    code: std.ArrayList(u8).Writer,
    vars: *std.StringHashMap(std.Build.LazyPath),
    content: Content,
) !void {
    // Always insert some padding before and after:
    try code.writeAll(" ");
    errdefer code.writeAll(" ") catch {};

    switch (content) {
        .empty => {
            try code.writeAll("empty");
        },

        .fill => |data| {
            try code.print("fill 0x{X:0>2}", .{data});
        },

        .paste_file => |data| {
            try code.writeAll("paste-file ");
            try renderLazyPath(wfs, code, vars, data);
        },

        .mbr_part_table => |data| {
            _ = data;
            @panic("not supported yet!");
        },
        .vfat => |data| {
            _ = data;
            @panic("not supported yet!");
        },
    }
}

fn renderLazyPath(
    wfs: *std.Build.Step.WriteFile,
    code: std.ArrayList(u8).Writer,
    vars: *std.StringHashMap(std.Build.LazyPath),
    path: std.Build.LazyPath,
) !void {
    switch (path) {
        .cwd_relative,
        .dependency,
        .src_path,
        => {
            // We can safely call getPath2 as we can fully resolve the path
            // already
            const full_path = path.getPath2(wfs.step.owner, &wfs.step);

            std.debug.assert(std.fs.path.isAbsolute(full_path));

            try code.writeAll(full_path);
        },

        .generated => {
            // this means we can't emit the variable just verbatim, but we
            // actually have a build-time dependency
            const var_id = vars.count() + 1;
            const var_name = wfs.step.owner.fmt("PATH{}", .{var_id});

            try vars.put(var_name, path);

            try code.print("${s}", .{var_name});
        },
    }
}

pub const Content = union(enum) {
    empty,
    fill: u8,
    paste_file: std.Build.LazyPath,
    mbr_part_table: MbrPartTable,
    vfat: FatFs,
};

pub const MbrPartTable = struct {
    //
};

pub const FatFs = struct {
    //
};
