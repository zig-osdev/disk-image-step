const std = @import("std");
const dim = @import("../dim.zig");

const PasteFile = @This();

file_handle: dim.FileName,

pub fn parse(ctx: dim.Context) !dim.Content {
    const pf = try ctx.alloc_object(PasteFile);
    pf.* = .{
        .file_handle = try ctx.parse_file_name(),
    };
    return .create_handle(pf, .create(@This(), .{
        .guess_size_fn = guess_size,
        .render_fn = render,
    }));
}

fn guess_size(self: *PasteFile) dim.Content.GuessError!dim.SizeGuess {
    const size = try self.file_handle.get_size();

    return .{ .exact = size };
}

fn render(self: *PasteFile, stream: *dim.BinaryStream) dim.Content.RenderError!void {
    try self.file_handle.copy_to(stream);
}
