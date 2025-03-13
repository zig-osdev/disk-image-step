//!
//! This file contains a common base implementation which should be valid for
//! all typical path based file systems.
//!
const std = @import("std");
const dim = @import("../../dim.zig");

pub const FsOperation = union(enum) {
    copy_file: struct {
        path: []const u8,
        source: dim.FileName,
    },

    copy_dir: struct {
        path: []const u8,
        source: dim.FileName,
    },

    make_dir: struct {
        path: []const u8,
    },

    create_file: struct {
        path: []const u8,
        size: u64,
        contents: dim.Content,
    },

    pub fn execute(op: FsOperation, executor: anytype) !void {
        _ = executor;
        switch (op) {
            .copy_file => |data| {
                _ = data;
            },
            .copy_dir => |data| {
                _ = data;
            },
            .make_dir => |data| {
                _ = data;
            },
            .create_file => |data| {
                _ = data;
            },
        }
    }
};

fn parse_path(ctx: dim.Context) ![]const u8 {
    const path = try ctx.parse_string();

    if (path.len == 0) {
        try ctx.report_nonfatal_error("Path cannot be empty!", .{});
        return path;
    }

    if (!std.mem.startsWith(u8, path, "/")) {
        try ctx.report_nonfatal_error("Path '{}' did not start with a \"/\"", .{
            std.zig.fmtEscapes(path),
        });
    }

    for (path) |c| {
        if (c < 0x20 or c == 0x7F or c == '\\') {
            try ctx.report_nonfatal_error("Path '{}' contains invalid character 0x{X:0>2}", .{
                std.zig.fmtEscapes(path),
                c,
            });
        }
    }

    _ = std.unicode.Utf8View.init(path) catch |err| {
        try ctx.report_nonfatal_error("Path '{}' is not a valid UTF-8 string: {s}", .{
            std.zig.fmtEscapes(path),
            @errorName(err),
        });
    };

    return path;
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
