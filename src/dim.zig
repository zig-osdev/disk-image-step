//!
//! Disk Imager Command Line
//!
const std = @import("std");

const Tokenizer = @import("Tokenizer.zig");
const Parser = @import("Parser.zig");
const args = @import("args");

const max_script_size = 10 * DiskSize.MiB;

const Options = struct {
    output: ?[]const u8 = null,
    size: ?DiskSize = null,
    script: ?[]const u8 = null,
    @"import-env": bool = false,
};

const usage =
    \\dim OPTIONS [VARS]
    \\
    \\OPTIONS:
    \\ --output <path>
    \\   mandatory: where to store the output file
    \\[--size <size>]
    \\   optional: how big is the resulting disk image? allowed suffixes: k,K,M,G
    \\ --script <path>
    \\   mandatory: which script file to execute?
    \\[--import-env]
    \\   optional: if set, imports the current process environment into the variables
    \\VARS:
    \\{ KEY=VALUE }*
    \\  multiple ≥ 0: Sets variable KEY to VALUE
    \\
;

const VariableMap = std.StringArrayHashMapUnmanaged([]const u8);

pub fn main() !u8 {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();

    const gpa = gpa_impl.allocator();

    const opts = try args.parseForCurrentProcess(Options, gpa, .print);
    defer opts.deinit();

    const options = opts.options;

    const output_path = options.output orelse fatal("No output path specified");
    const script_path = options.script orelse fatal("No script specified");

    var var_map: VariableMap = .empty;
    defer var_map.deinit(gpa);

    var env_map = try std.process.getEnvMap(gpa);
    defer env_map.deinit();

    if (options.@"import-env") {
        var iter = env_map.iterator();
        while (iter.next()) |entry| {
            try var_map.putNoClobber(gpa, entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    var bad_args = false;
    for (opts.positionals) |pos| {
        if (std.mem.indexOfScalar(u8, pos, '=')) |idx| {
            const key = pos[0..idx];
            const val = pos[idx + 1 ..];
            try var_map.put(gpa, key, val);
        } else {
            std.debug.print("unexpected argument positional '{}'\n", .{
                std.zig.fmtEscapes(pos),
            });
            bad_args = true;
        }
    }
    if (bad_args)
        return 1;

    var current_dir = try std.fs.cwd().openDir(".", .{});
    defer current_dir.close();

    const script_source = try current_dir.readFileAlloc(gpa, script_path, max_script_size);
    defer gpa.free(script_source);

    var output_file = try current_dir.atomicFile(output_path, .{});
    defer output_file.deinit();

    var env = Environment{
        .allocator = gpa,
        .vars = &var_map,
        .include_base = current_dir,
        .parser = undefined,
    };

    var parser = try Parser.init(
        gpa,
        &env.io,
        .{
            .max_include_depth = 8,
        },
    );
    defer parser.deinit();

    env.parser = &parser;

    try parser.push_source(.{
        .path = script_path,
        .contents = script_source,
    });

    try env.execute_content(&parser);

    try output_file.finish();

    return 0;
}

fn fatal(msg: []const u8) noreturn {
    std.debug.print("Error: {s}\n", .{msg});
    std.debug.print("Usage: {s}", .{usage});
    std.process.exit(1);
}

const content_types: []const struct { []const u8, type } = &.{
    .{ "mbr-part", @import("components/part/MbrPartitionTable.zig") },
    .{ "gpt-part", @import("components/part/GptPartitionTable.zig") },
    .{ "fat", @import("components/fs/FatFileSystem.zig") },
    .{ "raw", @import("components/RawData.zig") },
    .{ "empty", @import("components/EmptyData.zig") },
    .{ "fill", @import("components/FillData.zig") },
};

pub const Context = struct {
    env: *Environment,

    pub const WriteError = error{};
    pub const Writer = std.io.Writer(*const Context, WriteError, write_some_data);

    pub fn get_remaining_size(ctx: Context) ?u64 {
        _ = ctx;

        // TODO: This
        return null;
    }

    pub fn open_file(ctx: Context, path: []const u8) !std.fs.File {
        const abs_path = try ctx.env.parser.get_include_path(ctx.env.allocator, path);
        defer ctx.env.allocator.free(abs_path);

        return ctx.env.include_base.openFile(abs_path, .{});
    }

    pub fn writer(ctx: *const Context) Writer {
        return .{ .context = ctx };
    }

    pub fn get_string(ctx: Context) ![]const u8 {
        return ctx.env.parser.next();
    }

    pub fn get_enum(ctx: Context, comptime E: type) !E {
        if (@typeInfo(E) != .@"enum")
            @compileError("get_enum requires an enum type!");
        return std.meta.stringToEnum(
            E,
            ctx.get_string(),
        ) orelse return error.InvalidEnumTag;
    }

    pub fn get_integer(ctx: Context, comptime I: type, base: u8) !I {
        if (@typeInfo(I) != .int)
            @compileError("get_integer requires an integer type!");
        return try std.fmt.parseInt(
            I,
            try ctx.get_string(),
            base,
        );
    }

    fn write_some_data(ctx: *const Context, buffer: []const u8) WriteError!usize {
        _ = ctx;
        // TODO: Implement this!
        return buffer.len;
    }
};

const Environment = struct {
    allocator: std.mem.Allocator,
    parser: *Parser,
    include_base: std.fs.Dir,
    vars: *const VariableMap,

    io: Parser.IO = .{
        .fetch_file_fn = fetch_file,
        .resolve_variable_fn = resolve_var,
    },

    fn execute_content(env: *Environment, parser: *Parser) !void {
        const content_type_str = try parser.next();

        inline for (content_types) |tn| {
            const name, const impl = tn;

            if (std.mem.eql(u8, name, content_type_str)) {
                return impl.execute(Context{ .env = env });
            }
        }
        return error.UnknownContentType;
    }

    fn fetch_file(io: *const Parser.IO, allocator: std.mem.Allocator, path: []const u8) error{ FileNotFound, IoError, OutOfMemory }![]const u8 {
        const env: *const Environment = @fieldParentPtr("io", io);
        return env.include_base.readFileAlloc(allocator, path, max_script_size) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound => return error.FileNotFound,
            else => return error.IoError,
        };
    }

    fn resolve_var(io: *const Parser.IO, name: []const u8) error{UnknownVariable}![]const u8 {
        const env: *const Environment = @fieldParentPtr("io", io);
        return env.vars.get(name) orelse return error.UnknownVariable;
    }
};

test {
    _ = Tokenizer;
    _ = Parser;
}

const DiskSize = enum(u64) {
    const KiB = 1024;
    const MiB = 1024 * 1024;
    const GiB = 1024 * 1024 * 1024;

    _,

    pub fn parse(str: []const u8) error{ InvalidSize, Overflow }!DiskSize {
        const suffix_scaling: ?u64 = if (std.mem.endsWith(u8, str, "K"))
            KiB
        else if (std.mem.endsWith(u8, str, "M"))
            MiB
        else if (std.mem.endsWith(u8, str, "G"))
            GiB
        else
            null;

        const cutoff: usize = if (suffix_scaling != null) 1 else 0;

        const numeric_text = std.mem.trim(u8, str[0 .. str.len - cutoff], " \t\r\n");

        const raw_number = std.fmt.parseInt(u64, numeric_text, 0) catch |err| switch (err) {
            error.Overflow => return error.Overflow,
            error.InvalidCharacter => return error.InvalidSize,
        };

        const byte_size = if (suffix_scaling) |scale|
            try std.math.mul(u64, raw_number, scale)
        else
            raw_number;

        return @enumFromInt(byte_size);
    }

    pub fn size_in_bytes(ds: DiskSize) u64 {
        return @intFromEnum(ds);
    }

    pub fn format(ds: DiskSize, fmt: []const u8, opt: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = opt;

        const size = ds.size_in_bytes();

        const div: u64, const unit: []const u8 = if (size > GiB)
            .{ GiB, " GiBi" }
        else if (size > MiB)
            .{ MiB, " MeBi" }
        else if (size > KiB)
            .{ KiB, " KiBi" }
        else
            .{ 1, " B" };

        if (size == 0) {
            try writer.writeAll("0 B");
            return;
        }

        const scaled_value = (1000 * size) / div;

        var buf: [std.math.log2_int_ceil(u64, std.math.maxInt(u64))]u8 = undefined;
        const divided = try std.fmt.bufPrint(&buf, "{d}", .{scaled_value});

        std.debug.assert(divided.len >= 3);

        const prefix, const suffix = .{
            divided[0 .. divided.len - 3],
            std.mem.trimRight(u8, divided[divided.len - 3 ..], "0"),
        };

        if (suffix.len > 0) {
            try writer.print("{s}.{s}{s}", .{ prefix, suffix, unit });
        } else {
            try writer.print("{s}{s}", .{ prefix, unit });
        }
    }
};

test DiskSize {
    const KiB = 1024;
    const MiB = 1024 * 1024;
    const GiB = 1024 * 1024 * 1024;

    const patterns: []const struct { u64, []const u8 } = &.{
        .{ 0, "0" },
        .{ 1000, "1000" },
        .{ 4096, "0x1000" },
        .{ 4096 * MiB, "0x1000 M" },
        .{ 1 * KiB, "1K" },
        .{ 1 * KiB, "1K" },
        .{ 1 * KiB, "1 K" },
        .{ 150 * KiB, "150K" },

        .{ 1 * MiB, "1M" },
        .{ 1 * MiB, "1M" },
        .{ 1 * MiB, "1 M" },
        .{ 150 * MiB, "150M" },

        .{ 1 * GiB, "1G" },
        .{ 1 * GiB, "1G" },
        .{ 1 * GiB, "1 G" },
        .{ 150 * GiB, "150G" },
    };

    for (patterns) |pat| {
        const size_in_bytes, const stringified = pat;
        const actual_size = try DiskSize.parse(stringified);

        try std.testing.expectEqual(size_in_bytes, actual_size.size_in_bytes());
    }
}
