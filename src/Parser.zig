const std = @import("std");

const Tokenizer = @import("Tokenizer.zig");

const Token = Tokenizer.Token;
const TokenType = Tokenizer.TokenType;

const Parser = @This();

pub const Error = Tokenizer.Error || error{
    FileNotFound,
    InvalidPath,
    UnknownVariable,
    IoError,
    BadDirective,
    MaxIncludeDepthReached,
    ExpectedIncludePath,
    UnknownDirective,
    OutOfMemory,
    InvalidEscapeSequence,
};

pub const IO = struct {
    fetch_file_fn: *const fn (io: *const IO, std.mem.Allocator, path: []const u8) error{ FileNotFound, IoError, OutOfMemory, InvalidPath }![]const u8,
    resolve_variable_fn: *const fn (io: *const IO, name: []const u8) error{UnknownVariable}![]const u8,

    pub fn fetch_file(io: *const IO, allocator: std.mem.Allocator, path: []const u8) error{ FileNotFound, IoError, OutOfMemory, InvalidPath }![]const u8 {
        return io.fetch_file_fn(io, allocator, path);
    }

    pub fn resolve_variable(io: *const IO, name: []const u8) error{UnknownVariable}![]const u8 {
        return io.resolve_variable_fn(io, name);
    }
};

const File = struct {
    path: []const u8,
    tokenizer: Tokenizer,
};

allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
io: *const IO,

file_stack: []File,
max_include_depth: usize,

pub const InitOptions = struct {
    max_include_depth: usize,
};
pub fn init(allocator: std.mem.Allocator, io: *const IO, options: InitOptions) error{OutOfMemory}!Parser {
    var slice = try allocator.alloc(File, options.max_include_depth);
    slice.len = 0;
    return .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .allocator = allocator,
        .io = io,
        .max_include_depth = options.max_include_depth,
        .file_stack = slice,
    };
}

pub fn deinit(parser: *Parser) void {
    parser.file_stack.len = parser.max_include_depth;
    parser.allocator.free(parser.file_stack);
    parser.arena.deinit();
    parser.* = undefined;
}

pub fn push_source(parser: *Parser, options: struct {
    path: []const u8,
    contents: []const u8,
}) !void {
    std.debug.assert(parser.file_stack.len <= parser.max_include_depth);
    if (parser.file_stack.len == parser.max_include_depth)
        return error.MaxIncludeDepthReached;

    const index = parser.file_stack.len;
    parser.file_stack.len += 1;

    parser.file_stack[index] = .{
        .path = options.path,
        .tokenizer = .init(options.contents),
    };
}

pub fn push_file(parser: *Parser, include_path: []const u8) !void {
    const abs_include_path = try parser.get_include_path(parser.arena.allocator(), include_path);

    const file_contents = try parser.io.fetch_file(parser.arena.allocator(), abs_include_path);

    const index = parser.file_stack.len;
    parser.file_stack.len += 1;

    parser.file_stack[index] = .{
        .path = abs_include_path,
        .tokenizer = .init(file_contents),
    };
}

pub fn get_include_path(parser: Parser, allocator: std.mem.Allocator, rel_include_path: []const u8) ![]const u8 {
    std.debug.assert(parser.file_stack.len <= parser.max_include_depth);
    if (parser.file_stack.len == parser.max_include_depth)
        return error.MaxIncludeDepthReached;

    const top_path = if (parser.file_stack.len > 0)
        parser.file_stack[parser.file_stack.len - 1].path
    else
        "";

    const abs_include_path = try std.fs.path.resolvePosix(
        allocator,
        &.{
            std.fs.path.dirnamePosix(top_path) orelse ".",
            rel_include_path,
        },
    );
    errdefer allocator.free(abs_include_path);

    return abs_include_path;
}

pub fn next(parser: *Parser) (Error || error{UnexpectedEndOfFile})![]const u8 {
    return if (try parser.next_or_eof()) |word|
        word
    else
        error.UnexpectedEndOfFile;
}

pub fn next_or_eof(parser: *Parser) Error!?[]const u8 {
    fetch_loop: while (parser.file_stack.len > 0) {
        const top = &parser.file_stack[parser.file_stack.len - 1];

        const token = (try fetch_token(&top.tokenizer)) orelse {
            // we exhausted tokens in the current file, pop the stack and continue
            // on lower file
            parser.file_stack.len -= 1;
            continue :fetch_loop;
        };

        switch (token.type) {
            .whitespace, .comment => unreachable,

            .word, .variable, .string => return try parser.resolve_value(
                token.type,
                top.tokenizer.get_text(token),
            ),

            .directive => {
                const directive = top.tokenizer.get_text(token);

                if (std.mem.eql(u8, directive, "!include")) {
                    if (try fetch_token(&top.tokenizer)) |path_token| {
                        const rel_include_path = switch (path_token.type) {
                            .word, .variable, .string => try parser.resolve_value(
                                path_token.type,
                                top.tokenizer.get_text(path_token),
                            ),
                            .comment, .directive, .whitespace => return error.BadDirective,
                        };

                        try parser.push_file(rel_include_path);
                    } else {
                        return error.ExpectedIncludePath;
                    }
                } else {
                    return error.UnknownDirective;
                }
            },
        }
    }

    return null;
}

fn fetch_token(tok: *Tokenizer) Tokenizer.Error!?Token {
    while (true) {
        const token = if (try tok.next()) |t|
            t
        else
            return null;

        switch (token.type) {
            // Skipped:
            .whitespace, .comment => {},

            else => return token,
        }
    }
}

fn resolve_value(parser: *Parser, token_type: TokenType, text: []const u8) ![]const u8 {
    return switch (token_type) {
        .word => text,

        .variable => try parser.io.resolve_variable(
            text[1..],
        ),

        .string => {
            const content_slice = text[1 .. text.len - 1];

            const has_includes = for (content_slice) |c| {
                if (c == '\\')
                    break true;
            } else false;

            if (!has_includes)
                return content_slice;

            var unescaped: std.ArrayList(u8) = .init(parser.arena.allocator());
            defer unescaped.deinit();

            try unescaped.ensureTotalCapacityPrecise(content_slice.len);

            {
                var i: usize = 0;
                while (i < content_slice.len) {
                    const c = content_slice[i];
                    i += 1;

                    if (c != '\\') {
                        try unescaped.append(c);
                        continue;
                    }

                    if (i == content_slice.len)
                        return error.InvalidEscapeSequence;

                    const esc_code = content_slice[i];
                    i += 1;

                    errdefer std.log.err("invalid escape sequence: \\{s}", .{[_]u8{esc_code}});

                    switch (esc_code) {
                        'r' => try unescaped.append('\r'),
                        'n' => try unescaped.append('\n'),
                        't' => try unescaped.append('\t'),
                        '\\' => try unescaped.append('\\'),
                        '\"' => try unescaped.append('\"'),
                        '\'' => try unescaped.append('\''),
                        'e' => try unescaped.append('\x1B'),

                        else => return error.InvalidEscapeSequence,
                    }
                }
            }

            return try unescaped.toOwnedSlice();
        },

        .comment, .directive, .whitespace => unreachable,
    };
}

test Parser {
    const io: IO = .{
        .fetch_file_fn = undefined,
        .resolve_variable_fn = undefined,
    };

    var parser: Parser = try .init(std.testing.allocator, &io, .{
        .max_include_depth = 8,
    });
    defer parser.deinit();

    try parser.push_source(.{
        .path = "test.script",
        .contents =
        \\mbr-part
        \\  bootloader PATH1
        \\  part # partition 1
        \\      type fat32-lba
        \\      size 500M
        \\      bootable
        \\      contents
        \\          fat32 ...
        ,
    });

    const sequence: []const []const u8 = &.{
        "mbr-part",
        "bootloader",
        "PATH1",
        "part",
        "type",
        "fat32-lba",
        "size",
        "500M",
        "bootable",
        "contents",
        "fat32",
        "...",
    };

    for (sequence) |item| {
        try std.testing.expectEqualStrings(item, (try parser.next_or_eof()).?);
    }

    try std.testing.expectEqual(null, parser.next_or_eof());
}

test "parser with variables" {
    const MyIO = struct {
        fn resolve_variable(io: *const IO, name: []const u8) error{UnknownVariable}![]const u8 {
            _ = io;
            if (std.mem.eql(u8, name, "DISK"))
                return "./zig-out/disk.img";
            if (std.mem.eql(u8, name, "KERNEL"))
                return "./zig-out/bin/kernel.elf";
            return error.UnknownVariable;
        }
    };
    const io: IO = .{
        .fetch_file_fn = undefined,
        .resolve_variable_fn = MyIO.resolve_variable,
    };

    var parser: Parser = try .init(std.testing.allocator, &io, .{
        .max_include_depth = 8,
    });
    defer parser.deinit();

    try parser.push_source(.{
        .path = "test.script",
        .contents =
        \\select-disk $DISK
        \\copy-file $KERNEL /BOOT/vzlinuz
        \\
        ,
    });

    const sequence: []const []const u8 = &.{
        "select-disk",
        "./zig-out/disk.img",
        "copy-file",
        "./zig-out/bin/kernel.elf",
        "/BOOT/vzlinuz",
    };

    for (sequence) |item| {
        try std.testing.expectEqualStrings(item, (try parser.next_or_eof()).?);
    }

    try std.testing.expectEqual(null, parser.next_or_eof());
}

test "parser with variables and include files" {
    const MyIO = struct {
        fn resolve_variable(io: *const IO, name: []const u8) error{UnknownVariable}![]const u8 {
            _ = io;
            if (std.mem.eql(u8, name, "DISK"))
                return "./zig-out/disk.img";
            if (std.mem.eql(u8, name, "KERNEL"))
                return "./zig-out/bin/kernel.elf";
            return error.UnknownVariable;
        }
        fn fetch_file(io: *const IO, allocator: std.mem.Allocator, path: []const u8) error{ FileNotFound, IoError, OutOfMemory }![]const u8 {
            _ = io;
            if (std.mem.eql(u8, path, "path/parent/kernel.script"))
                return try allocator.dupe(u8, "copy-file $KERNEL /BOOT/vzlinuz");
            return error.FileNotFound;
        }
    };
    const io: IO = .{
        .fetch_file_fn = MyIO.fetch_file,
        .resolve_variable_fn = MyIO.resolve_variable,
    };

    var parser: Parser = try .init(std.testing.allocator, &io, .{
        .max_include_depth = 8,
    });
    defer parser.deinit();

    try parser.push_source(.{
        .path = "path/to/test.script",
        .contents =
        \\select-disk $DISK
        \\!include "../parent/kernel.script"
        \\end-of sequence
        ,
    });

    const sequence: []const []const u8 = &.{
        "select-disk",
        "./zig-out/disk.img",
        "copy-file",
        "./zig-out/bin/kernel.elf",
        "/BOOT/vzlinuz",
        "end-of",
        "sequence",
    };

    for (sequence) |item| {
        try std.testing.expectEqualStrings(item, (try parser.next_or_eof()).?);
    }

    try std.testing.expectEqual(null, parser.next_or_eof());
}

test "parse nothing" {
    const io: IO = .{
        .fetch_file_fn = undefined,
        .resolve_variable_fn = undefined,
    };

    var parser: Parser = try .init(std.testing.allocator, &io, .{
        .max_include_depth = 8,
    });
    defer parser.deinit();

    try std.testing.expectEqual(null, parser.next_or_eof());
}

fn fuzz_parser(_: void, input: []const u8) !void {
    const FuzzIO = struct {
        fn fetch_file(io: *const IO, allocator: std.mem.Allocator, path: []const u8) error{ FileNotFound, IoError, OutOfMemory }![]const u8 {
            _ = io;
            _ = allocator;
            _ = path;
            return error.FileNotFound;
        }
        fn resolve_variable(io: *const IO, name: []const u8) error{UnknownVariable}![]const u8 {
            _ = io;
            return name;
        }
    };

    const io: IO = .{
        .fetch_file_fn = FuzzIO.fetch_file,
        .resolve_variable_fn = FuzzIO.resolve_variable,
    };

    var parser: Parser = try .init(std.testing.allocator, &io, .{
        .max_include_depth = 8,
    });
    defer parser.deinit();

    try parser.push_source(.{
        .path = "fuzz.script",
        .contents = input,
    });

    while (true) {
        const res = parser.next_or_eof() catch |err| switch (err) {
            error.UnknownDirective,
            error.UnknownVariable,
            error.BadDirective,
            error.FileNotFound,
            error.ExpectedIncludePath,
            error.InvalidPath,
            => continue,

            error.MaxIncludeDepthReached,
            error.IoError,
            error.SourceInputTooLarge,
            => @panic("reached impossible case for fuzz testing"),

            error.OutOfMemory => |e| return e,

            // Fine, must just terminate the parse loop:
            error.InvalidSourceEncoding,
            error.BadStringLiteral,
            error.BadEscapeSequence,
            => return,
        };
        if (res == null)
            break;
    }
}

test "fuzz parser" {
    try std.testing.fuzz({}, fuzz_parser, .{});
}
