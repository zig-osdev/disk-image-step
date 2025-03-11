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
        .render_fn = render,
    }));
}

fn render(self: *PasteFile, stream: *dim.BinaryStream) dim.Content.RenderError!void {
    try self.file_handle.copy_to(stream);
}
