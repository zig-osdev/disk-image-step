const std = @import("std");
const dim = @import("../dim.zig");

pub fn execute(ctx: dim.Context) !void {
    const path = try ctx.get_string();

    var file = try ctx.open_file(path);
    defer file.close();

    if (ctx.get_remaining_size()) |available_size| {
        const stat = try file.stat();

        if (available_size < stat.size)
            return error.InsufficientSize; // TODO: Error reporting
    }

    var fifo: std.fifo.LinearFifo(u8, .{ .Static = 8192 }) = .init();

    try fifo.pump(file.reader(), ctx.writer());
}
