//!
//! The `empty` content will just not touch anything in the output
//! and serves as a placeholder.
//!

const std = @import("std");
const dim = @import("../dim.zig");

const EmptyData = @This();

pub fn parse(ctx: dim.Context) !dim.Content {
    _ = ctx;
    return .create_handle(undefined, .create(@This(), .{
        .render_fn = render,
    }));
}

fn render(self: *EmptyData, io: std.Io, stream: *dim.BinaryStream) dim.Content.RenderError!void {
    _ = self;
    _ = stream;
    _ = io;
}
