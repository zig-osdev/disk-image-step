//!
//! This file contains a common base implementation which should be valid for
//! all typical path based file systems.
//!
const std = @import("std");
const dim = @import("../../dim.zig");

pub const FsOperation = union(enum) {
    copy_file: struct {
        path: [:0]const u8,
        source: dim.FileName,
    },

    copy_dir: struct {
        path: [:0]const u8,
        source: dim.FileName,
    },

    make_dir: struct {
        path: [:0]const u8,
    },

    create_file: struct {
        path: [:0]const u8,
        size: u64,
        contents: dim.Content,
    },

    pub fn execute(op: FsOperation, executor: anytype) !void {
        const exec: Executor(@TypeOf(executor)) = .init(executor);

        try exec.execute(op);
    }
};

fn Executor(comptime T: type) type {
    return struct {
        const Exec = @This();

        inner: T,

        fn init(wrapped: T) Exec {
            return .{ .inner = wrapped };
        }

        fn execute(exec: Exec, op: FsOperation) dim.Content.RenderError!void {
            switch (op) {
                .make_dir => |data| {
                    try exec.recursive_mkdir(data.path);
                },

                .copy_file => |data| {
                    var handle = data.source.open() catch |err| switch (err) {
                        error.FileNotFound => return, // open() already reporeted the error
                        else => |e| return e,
                    };
                    defer handle.close();

                    var reader_buf: [1024]u8 = undefined;
                    var reader = handle.reader(&reader_buf);
                    try exec.add_file(data.path, &reader.interface);
                },
                .copy_dir => |data| {
                    var iter_dir = data.source.open_dir() catch |err| switch (err) {
                        error.FileNotFound => return, // open() already reporeted the error
                        else => |e| return e,
                    };
                    defer iter_dir.close();

                    var walker_memory: [16384]u8 = undefined;
                    var temp_allocator: std.heap.FixedBufferAllocator = .init(&walker_memory);

                    var path_memory: [8192]u8 = undefined;

                    var walker = try iter_dir.walk(temp_allocator.allocator());
                    defer walker.deinit();

                    while (walker.next() catch |err| return walk_err(err)) |entry| {
                        const path = std.fmt.bufPrintZ(&path_memory, "{s}/{s}", .{
                            data.path,
                            entry.path,
                        }) catch @panic("buffer too small!");

                        // std.log.debug("- {s}", .{path_buffer.items});

                        switch (entry.kind) {
                            .file => {
                                const fname: dim.FileName = .{
                                    .root_dir = entry.dir,
                                    .rel_path = entry.basename,
                                };

                                var file = try fname.open();
                                defer file.close();

                                var reader_buf: [1024]u8 = undefined;
                                var reader = file.reader(&reader_buf);

                                try exec.add_file(path, &reader.interface);
                            },

                            .directory => {
                                try exec.recursive_mkdir(path);
                            },

                            else => {
                                var realpath_buffer: [std.fs.max_path_bytes]u8 = undefined;
                                std.log.warn("cannot copy file {!s}: {s} is not a supported file type!", .{
                                    entry.dir.realpath(entry.path, &realpath_buffer),
                                    @tagName(entry.kind),
                                });
                            },
                        }
                    }
                },

                .create_file => |data| {
                    const buffer = try std.heap.page_allocator.alloc(u8, data.size);
                    defer std.heap.page_allocator.free(buffer);

                    var bs: dim.BinaryStream = .init_buffer(buffer);

                    try data.contents.render(&bs);

                    var reader = std.Io.Reader.fixed(buffer);
                    try exec.add_file(data.path, &reader);
                },
            }
        }

        fn add_file(exec: Exec, path: [:0]const u8, reader: *std.Io.Reader) !void {
            if (std.fs.path.dirnamePosix(path)) |dir| {
                try exec.recursive_mkdir(dir);
            }

            try exec.inner_mkfile(path, reader);
        }

        fn recursive_mkdir(exec: Exec, path: []const u8) !void {
            var i: usize = 0;

            while (std.mem.indexOfScalarPos(u8, path, i, '/')) |index| {
                try exec.inner_mkdir(path[0..index]);
                i = index + 1;
            }

            try exec.inner_mkdir(path);
        }

        fn inner_mkfile(exec: Exec, path: []const u8, reader: *std.Io.Reader) dim.Content.RenderError!void {
            try exec.inner.mkfile(path, reader);
        }

        fn inner_mkdir(exec: Exec, path: []const u8) dim.Content.RenderError!void {
            try exec.inner.mkdir(path);
        }

        fn walk_err(err: (std.fs.Dir.OpenError || std.mem.Allocator.Error)) dim.Content.RenderError {
            return switch (err) {
                error.InvalidUtf8,
                error.InvalidWtf8,
                error.BadPathName,
                error.NameTooLong => error.InvalidPath,

                error.OutOfMemory => error.OutOfMemory,
                error.FileNotFound => error.FileNotFound,

                error.DeviceBusy,
                error.AccessDenied,
                error.SystemResources,
                error.NoDevice,
                error.Unexpected,
                error.NetworkNotFound,
                error.SymLinkLoop,
                error.ProcessFdQuotaExceeded,
                error.SystemFdQuotaExceeded,
                error.NotDir,
                error.ProcessNotFound, 
                error.PermissionDenied, => error.IoError,
            };
        }
    };
}

fn parse_path(ctx: dim.Context) ![:0]const u8 {
    const path = try ctx.parse_string();

    if (path.len == 0) {
        try ctx.report_nonfatal_error("Path cannot be empty!", .{});
        return "";
    }

    if (!std.mem.startsWith(u8, path, "/")) {
        try ctx.report_nonfatal_error("Path '{f}' did not start with a \"/\"", .{
            std.zig.fmtString(path),
        });
    }

    for (path) |c| {
        if (c < 0x20 or c == 0x7F or c == '\\') {
            try ctx.report_nonfatal_error("Path '{f}' contains invalid character 0x{X:0>2}", .{
                std.zig.fmtString(path),
                c,
            });
        }
    }

    _ = std.unicode.Utf8View.init(path) catch |err| {
        try ctx.report_nonfatal_error("Path '{f}' is not a valid UTF-8 string: {s}", .{
            std.zig.fmtString(path),
            @errorName(err),
        });
    };

    return try normalize(ctx.get_arena(), path);
}

pub fn parse_ops(ctx: dim.Context, end_seq: []const u8, handler: anytype) !void {
    while (true) {
        const opsel = try ctx.parse_string();
        if (std.mem.eql(u8, opsel, end_seq))
            return;

        if (std.mem.eql(u8, opsel, "mkdir")) {
            const path = try parse_path(ctx);
            try handler.append_common_op(FsOperation{
                .make_dir = .{ .path = path },
            });
        } else if (std.mem.eql(u8, opsel, "copy-dir")) {
            const path = try parse_path(ctx);
            const src = try ctx.parse_file_name();

            try handler.append_common_op(FsOperation{
                .copy_dir = .{ .path = path, .source = src },
            });
        } else if (std.mem.eql(u8, opsel, "copy-file")) {
            const path = try parse_path(ctx);
            const src = try ctx.parse_file_name();

            try handler.append_common_op(FsOperation{
                .copy_file = .{ .path = path, .source = src },
            });
        } else if (std.mem.eql(u8, opsel, "create-file")) {
            const path = try parse_path(ctx);
            const size = try ctx.parse_mem_size();
            const contents = try ctx.parse_content();

            try handler.append_common_op(FsOperation{
                .create_file = .{ .path = path, .size = size, .contents = contents },
            });
        } else {
            try handler.parse_custom_op(ctx, opsel);
        }
    }
}

fn normalize(allocator: std.mem.Allocator, src_path: []const u8) ![:0]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);

    var parts = std.mem.tokenizeAny(u8, src_path, "\\/");

    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) {
            // "cd same" is a no-op, we can remove it
            continue;
        } else if (std.mem.eql(u8, part, "..")) {
            // "cd up" is basically just removing the last pushed part
            _ = list.pop();
        } else {
            // this is an actual "descend"
            try list.append(allocator, part);
        }
    }

    return try std.mem.joinZ(allocator, "/", list.items);
}
