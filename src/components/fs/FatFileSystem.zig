const std = @import("std");
const dim = @import("../../dim.zig");
const common = @import("common.zig");

const FAT = @This();

format_as: FatType,
label: ?[]const u8 = null,
ops: std.ArrayList(common.FsOperation),

pub fn parse(ctx: dim.Context) !dim.Content {
    const fat_type = try ctx.parse_enum(FatType);

    const pf = try ctx.alloc_object(FAT);
    pf.* = .{
        .format_as = fat_type,
        .ops = .init(ctx.get_arena()),
    };

    try common.parse_ops(
        ctx,
        "endfat",
        Appender{ .fat = pf },
    );

    return .create_handle(pf, .create(@This(), .{
        .render_fn = render,
    }));
}

const Appender = struct {
    fat: *FAT,

    pub fn append_common_op(self: @This(), op: common.FsOperation) !void {
        try self.fat.ops.append(op);
    }

    pub fn parse_custom_op(self: @This(), ctx: dim.Context, str_op: []const u8) !void {
        const Op = enum { label };
        const op = std.meta.stringToEnum(Op, str_op) orelse return ctx.report_fatal_error(
            "Unknown file system operation '{s}'",
            .{str_op},
        );
        switch (op) {
            .label => {
                self.fat.label = try ctx.parse_string();
            },
        }
    }
};

fn render(self: *FAT, stream: *dim.BinaryStream) dim.Content.RenderError!void {
    _ = self;
    _ = stream;
}

const FatType = enum {
    fat12,
    fat16,
    fat32,
    exfat,
};
