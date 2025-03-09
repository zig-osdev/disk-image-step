//!
//! The `fill <byte>` content will fill the remaining space with the given `<byte>` value.
//!

const std = @import("std");
const dim = @import("../dim.zig");

const FillData = @This();

fill_value: u8,

pub fn parse(ctx: dim.Context) !dim.Content {
    const pf = try ctx.alloc_object(FillData);
    pf.* = .{
        .fill_value = try ctx.parse_integer(u8, 0),
    };
    return .create_handle(pf, .create(@This(), .{
        .guess_size_fn = guess_size,
        .render_fn = render,
    }));
}

fn guess_size(_: *FillData) dim.Content.GuessError!dim.SizeGuess {
    return .{ .at_least = 0 };
}

fn render(self: *FillData, stream: *dim.BinaryStream) dim.Content.RenderError!void {
    try stream.writer().writeByteNTimes(
        self.fill_value,
        stream.capacity,
    );
}
