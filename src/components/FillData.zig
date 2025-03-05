//!
//! The `fill <byte>` content will fill the remaining space with the given `<byte>` value.
//!

const std = @import("std");
const dim = @import("../dim.zig");

pub fn execute(ctx: dim.Context) !void {
    const fill_value: u8 = try ctx.get_integer(u8, 0);

    if (ctx.get_remaining_size()) |size| {
        try ctx.writer().writeByteNTimes(fill_value, size);
    }
}
