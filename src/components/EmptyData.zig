//!
//! The `empty` content will just not touch anything in the output
//! and serves as a placeholder.
//!

const std = @import("std");
const dim = @import("../dim.zig");

const EmptyData = @This();

pub fn parse(ctx: dim.Context) !dim.Content {
    const pf = try ctx.alloc_object(EmptyData);
    pf.* = .{};
    return .create_handle(pf, .create(@This(), .{
        .guess_size_fn = guess_size,
        .render_fn = render,
    }));
}

fn guess_size(_: *EmptyData) dim.Content.GuessError!dim.SizeGuess {
    return .{ .at_least = 0 };
}

fn render(self: *EmptyData, stream: *dim.BinaryStream) dim.Content.RenderError!void {
    _ = self;
    _ = stream;
}
