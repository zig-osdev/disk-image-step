const std = @import("std");

const Tokenizer = @This();

pub const TokenType = enum {
    /// `\S+`
    word,

    /// `\$\w+`
    variable,

    /// `\s+`
    whitespace,

    /// `/#[^\n]*\n/`
    comment,

    /// `/"([^"]|\\")*"/`
    string,
};

pub const Token = struct {
    offset: u32,
    len: u32,
    type: TokenType,
};

source: []const u8,
index: usize = 0,

pub fn init(source: []const u8) Tokenizer {
    return .{ .source = source };
}

pub const Error = error{
    SourceInputTooLarge,
};

pub fn next(tk: *Tokenizer) Error!?Token {
    if (tk.index >= tk.source.len)
        return null;
    if (tk.index >= std.math.maxInt(u32)) {
        return error.SourceInputTooLarge;
    }

    const start = tk.index;
    const first = tk.source[start];

    if (std.ascii.isWhitespace(first)) {
        while (tk.index < tk.source.len and std.ascii.isWhitespace(tk.source[tk.index])) {
            tk.index += 1;
        }
        return .{
            .offset = @intCast(start),
            .len = @intCast(tk.index - start),
            .type = .whitespace,
        };
    }
    if (first == '#') {
        while (tk.index < tk.source.len and tk.source[tk.index] != '\n') {
            tk.index += 1;
        }
        return .{
            .offset = @intCast(start),
            .len = @intCast(tk.index - start),
            .type = .comment,
        };
    }

    if (first == '"') {
        tk.index += 1;

        while (tk.index < tk.source.len) {
            const chr = tk.source[tk.index];
            tk.index += 1;

            if (chr == '"')
                break;

            if (chr == '\\')
                tk.index += 1;
        }

        return .{
            .offset = @intCast(start),
            .len = @intCast(tk.index - start),
            .type = .string,
        };
    }

    var ttype: TokenType = .word;
    if (first == '$') {
        tk.index += 1;
        ttype = .variable;
    }
    while (tk.index < tk.source.len and !std.ascii.isWhitespace(tk.source[tk.index])) {
        tk.index += 1;
    }
    return .{
        .offset = @intCast(start),
        .len = @intCast(tk.index - start),
        .type = ttype,
    };
}

fn run_fuzz_test(_: void, input: []const u8) !void {
    var tokenizer = init(input);

    while (try tokenizer.next()) |_| {}
}

test "fuzz Tokenizer" {
    try std.testing.fuzz({}, run_fuzz_test, .{});
}

test Tokenizer {
    const seq: []const struct { TokenType, []const u8 } = &.{
        .{ .word, "hello" },
        .{ .whitespace, " " },
        .{ .word, "world" },
        .{ .whitespace, "\n  " },
        .{ .variable, "$foobar" },
        .{ .whitespace, " " },
        .{ .comment, "# hello, this is a comment" },
        .{ .whitespace, "\n" },
        .{ .string, "\"stringy content\"" },
    };

    var tokenizer = init(
        \\hello world
        \\  $foobar # hello, this is a comment
        \\"stringy content"
    );

    var offset: u32 = 0;
    for (seq) |expected| {
        const actual = (try tokenizer.next()) orelse return error.Unexpected;
        errdefer std.debug.print("unexpected token: .{} \"{}\"\n", .{
            std.zig.fmtId(@tagName(actual.type)),
            std.zig.fmtEscapes(tokenizer.source[actual.offset..][0..actual.len]),
        });
        try std.testing.expectEqual(offset, actual.offset);
        try std.testing.expectEqual(expected.@"0", actual.type);
        try std.testing.expectEqual(expected.@"1".len, actual.len);
        offset += actual.len;
    }
    try std.testing.expectEqual(null, try tokenizer.next());
}

test "empty file" {
    var tokenizer = init("");
    try std.testing.expectEqual(null, try tokenizer.next());
}
