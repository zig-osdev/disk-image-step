const std = @import("std");

const Tokenizer = @This();

pub const TokenType = enum {
    /// `\S+`
    word,

    /// `\$\w+`
    variable,

    /// `!\w+`
    directive,

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
    InvalidSourceEncoding,
    BadEscapeSequence,
    BadStringLiteral,
};

pub fn get_text(tk: Tokenizer, token: Token) []const u8 {
    return tk.source[token.offset..][0..token.len];
}

pub fn next(tk: *Tokenizer) Error!?Token {
    const start = tk.index;
    const first = if (try tk.next_char()) |char|
        char
    else
        return null;

    if (std.ascii.isWhitespace(first)) {
        while (try tk.peek_char()) |c| {
            if (!std.ascii.isWhitespace(c))
                break;
            tk.take_char(c);
        }
        return .{
            .offset = @intCast(start),
            .len = @intCast(tk.index - start),
            .type = .whitespace,
        };
    }

    if (first == '#') {
        while (try tk.peek_char()) |c| {
            if (c == '\n')
                break;
            tk.take_char(c);
        }
        return .{
            .offset = @intCast(start),
            .len = @intCast(tk.index - start),
            .type = .comment,
        };
    }

    if (first == '"') {
        tk.index += 1;

        var string_ok = false;
        while (try tk.peek_char()) |c| {
            tk.take_char(c);
            if (c == '"') {
                string_ok = true;
                break;
            }
            if (c == '\\') {
                if ((try tk.next_char()) == null)
                    return error.BadEscapeSequence;
            }
        }
        if (!string_ok)
            return error.BadStringLiteral;

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
    } else if (first == '!') {
        tk.index += 1;
        ttype = .directive;
    }
    while (try tk.peek_char()) |c| {
        if (std.ascii.isWhitespace(c))
            break;
        tk.take_char(c);
    }
    return .{
        .offset = @intCast(start),
        .len = @intCast(tk.index - start),
        .type = ttype,
    };
}

fn peek_char(tk: Tokenizer) error{ SourceInputTooLarge, InvalidSourceEncoding }!?u8 {
    if (tk.index >= tk.source.len)
        return null;

    if (tk.index >= std.math.maxInt(u32))
        return error.SourceInputTooLarge;

    const char = tk.source[tk.index];
    if (char < 0x20 and !std.ascii.isWhitespace(char))
        return error.InvalidSourceEncoding;

    return char;
}

fn take_char(tk: *Tokenizer, c: u8) void {
    std.debug.assert(tk.source[tk.index] == c);
    tk.index += 1;
}

fn next_char(tk: *Tokenizer) error{ SourceInputTooLarge, InvalidSourceEncoding }!?u8 {
    const char = try tk.peek_char();
    if (char) |c|
        tk.take_char(c);
    return char;
}

fn run_fuzz_test(_: void, input: []const u8) !void {
    var tokenizer = init(input);

    while (true) {
        const tok = tokenizer.next() catch return;
        if (tok == null)
            break;
    }
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
        try std.testing.expectEqualStrings(expected.@"1", tokenizer.get_text(actual));
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
