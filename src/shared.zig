const std = @import("std");

// usage: mkfs.<tool> <image> <base> <length> <filesystem> <ops...>
//  <image> is a path to the image file
//  <base> is the byte base of the file system
//  <length> is the byte length of the file system
//  <filesystem> is the file system that should be used to format
//  <ops...> is a list of operations that should be performed on the file system:
//  - format            Formats the disk image.
//  - mount             Mounts the file system, must be before all following:
//  - mkdir:<dst>       Creates directory <dst> and all necessary parents.
//  - file:<src>:<dst>  Copy <src> to path <dst>. If <dst> exists, it will be overwritten.
//  - dir:<src>:<dst>   Copy <src> recursively into <dst>. If <dst> exists, they will be merged.
//
// <dst> paths are always rooted, even if they don't start with a /, and always use / as a path separator.
//

pub fn App(comptime Context: type) type {
    return struct {
        pub var allocator: std.mem.Allocator = undefined;
        pub var device: BlockDevice = undefined;

        pub fn main() !u8 {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            allocator = arena.allocator();

            const argv = try std.process.argsAlloc(allocator);

            if (argv.len <= 4)
                return mistake("invalid usage", .{});

            const image_file_path = argv[1];
            const byte_base = try std.fmt.parseInt(u64, argv[2], 0);
            const byte_len = try std.fmt.parseInt(u64, argv[3], 0);
            const file_system = argv[4];

            const command_list = argv[5..];

            if ((byte_base % BlockDevice.block_size) != 0) {
                std.log.warn("offset is not a multiple of {}", .{BlockDevice.block_size});
            }
            if ((byte_len % BlockDevice.block_size) != 0) {
                std.log.warn("length is not a multiple of {}", .{BlockDevice.block_size});
            }

            if (command_list.len == 0)
                return mistake("no commands.", .{});

            var image_file = try std.fs.cwd().openFile(image_file_path, .{
                .mode = .read_write,
            });
            defer image_file.close();

            const stat = try image_file.stat();

            if (byte_base + byte_len > stat.size)
                return mistake("invalid offsets.", .{});

            device = BlockDevice{
                .file = &image_file,
                .base = byte_base,
                .count = byte_len / BlockDevice.block_size,
            };

            var path_buffer = std.ArrayList(u8).init(allocator);
            defer path_buffer.deinit();

            try path_buffer.ensureTotalCapacity(8192);

            try Context.init(file_system);

            for (command_list) |command_sequence| {
                var cmd_iter = std.mem.split(u8, command_sequence, ":");

                const command_str = cmd_iter.next() orelse return mistake("bad command", .{});

                const command = std.meta.stringToEnum(Command, command_str) orelse return mistake("bad command: {s}", .{command_str});

                switch (command) {
                    .format => {
                        try Context.format();
                    },
                    .mount => {
                        try Context.mount();
                    },
                    .mkdir => {
                        const dir = try normalize(cmd_iter.next() orelse return mistake("mkdir:<dst> is missing it's <dst> path!", .{}));

                        // std.log.info("mkdir(\"{}\")", .{std.zig.fmtEscapes(dir)});

                        try recursiveMkDir(dir);
                    },
                    .file => {
                        const src = cmd_iter.next() orelse return mistake("file:<src>:<dst> is missing it's <src> path!", .{});
                        const dst = try normalize(cmd_iter.next() orelse return mistake("file:<src>:<dst> is missing it's <dst> path!", .{}));

                        // std.log.info("file(\"{}\", \"{}\")", .{ std.zig.fmtEscapes(src), std.zig.fmtEscapes(dst) });

                        var file = try std.fs.cwd().openFile(src, .{});
                        defer file.close();

                        try addFile(file, dst);
                    },
                    .dir => {
                        const src = cmd_iter.next() orelse return mistake("dir:<src>:<dst> is missing it's <src> path!", .{});
                        const dst = try normalize(cmd_iter.next() orelse return mistake("dir:<src>:<dst> is missing it's <dst> path!", .{}));

                        // std.log.info("dir(\"{}\", \"{}\")", .{ std.zig.fmtEscapes(src), std.zig.fmtEscapes(dst) });

                        var iter_dir = try std.fs.cwd().openDir(src, .{ .iterate = true });
                        defer iter_dir.close();

                        var walker = try iter_dir.walk(allocator);
                        defer walker.deinit();

                        while (try walker.next()) |entry| {
                            path_buffer.shrinkRetainingCapacity(0);
                            try path_buffer.appendSlice(dst);
                            try path_buffer.appendSlice("/");
                            try path_buffer.appendSlice(entry.path);

                            const fs_path = path_buffer.items;

                            // std.log.debug("- {s}", .{path_buffer.items});

                            switch (entry.kind) {
                                .file => {
                                    var file = try entry.dir.openFile(entry.basename, .{});
                                    defer file.close();

                                    try addFile(file, fs_path);
                                },

                                .directory => {
                                    try recursiveMkDir(fs_path);
                                },

                                else => {
                                    var realpath_buffer: [std.fs.max_path_bytes]u8 = undefined;
                                    std.log.warn("cannot copy file {!s}: {s} is not a supported file type!", .{
                                        entry.dir.realpath(entry.path, &realpath_buffer),
                                        @tagName(entry.kind),
                                    });
                                },
                            }
                        }
                    },
                }
            }

            return 0;
        }

        fn recursiveMkDir(path: []const u8) !void {
            var i: usize = 0;

            while (std.mem.indexOfScalarPos(u8, path, i, '/')) |index| {
                try Context.mkdir(path[0..index]);
                i = index + 1;
            }

            try Context.mkdir(path);
        }

        fn addFile(file: std.fs.File, fs_path: []const u8) !void {
            if (std.fs.path.dirnamePosix(fs_path)) |dir| {
                try recursiveMkDir(dir);
            }

            try Context.mkfile(fs_path, file);
        }

        fn normalize(src_path: []const u8) ![:0]const u8 {
            var list = std.ArrayList([]const u8).init(allocator);
            defer list.deinit();

            var parts = std.mem.tokenize(u8, src_path, "\\/");

            while (parts.next()) |part| {
                if (std.mem.eql(u8, part, ".")) {
                    // "cd same" is a no-op, we can remove it
                    continue;
                } else if (std.mem.eql(u8, part, "..")) {
                    // "cd up" is basically just removing the last pushed part
                    _ = list.popOrNull();
                } else {
                    // this is an actual "descend"
                    try list.append(part);
                }
            }

            return try std.mem.joinZ(allocator, "/", list.items);
        }
    };
}

const Command = enum {
    format,
    mount,
    mkdir,
    file,
    dir,
};

pub const Block = [BlockDevice.block_size]u8;

pub const BlockDevice = struct {
    pub const block_size = 512;

    file: *std.fs.File,
    base: u64, // byte base offset
    count: u64, // num blocks

    pub fn write(bd: *BlockDevice, num: u64, block: Block) !void {
        if (num >= bd.count) return error.InvalidBlock;
        try bd.file.seekTo(bd.base + block_size * num);
        try bd.file.writeAll(&block);
    }

    pub fn read(bd: *BlockDevice, num: u64) !Block {
        if (num >= bd.count) return error.InvalidBlock;
        var block: Block = undefined;
        try bd.file.seekTo(bd.base + block_size * num);
        try bd.file.reader().readNoEof(&block);
        return block;
    }
};

fn mistake(comptime fmt: []const u8, args: anytype) u8 {
    std.log.err(fmt, args);
    return 1;
}
