//!
//! The `fill <byte>` content will fill the remaining space with the given `<byte>` value.
//!

const std = @import("std");
const dim = @import("../dim.zig");

const FillData = @This();

fill_value: u8,

pub fn parse(ctx: dim.Context, stdio: std.Io) !dim.Content {
    const pf = try ctx.alloc_object(FillData);
    pf.* = .{
        .fill_value = try ctx.parse_integer(stdio, u8, 0),
    };
    return .create_handle(pf, .create(@This(), .{
        .render_fn = render,
    }));
}

fn render(self: *FillData, io: std.Io,  stream: *dim.BinaryStream) dim.Content.RenderError!void {
    var writer = stream.writer(io);
    writer.interface.splatByteAll(
        self.fill_value,
        stream.length,
    ) catch return error.Overflow; // TODO FIX we don't know actually why this failed.
                                   // std.Io.Writer only returns error.WriteFailed.
}
