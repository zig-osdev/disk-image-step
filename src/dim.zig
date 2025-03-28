//!
//! Disk Imager Command Line
//!
const std = @import("std");
const builtin = @import("builtin");

const Tokenizer = @import("Tokenizer.zig");
const Parser = @import("Parser.zig");
const args = @import("args");

pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug)
        .debug
    else
        .info,
    .log_scope_levels = &.{
        .{ .scope = .fatfs, .level = .info },
    },
};

comptime {
    // Ensure zfat is linked to prevent compiler errors!
    _ = @import("zfat");
}

const max_script_size = 10 * DiskSize.MiB;

const Options = struct {
    output: ?[]const u8 = null,
    size: DiskSize = DiskSize.empty,
    script: ?[]const u8 = null,
    @"import-env": bool = false,
    @"deps-file": ?[]const u8 = null,
};

const usage =
    \\dim OPTIONS [VARS]
    \\
    \\OPTIONS:
    \\ --output <path>
    \\   mandatory: where to store the output file
    \\ --size <size>
    \\   mandatory: how big is the resulting disk image? allowed suffixes: k,K,M,G
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

var global_deps_file: ?std.fs.File = null;

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

    const size_limit: u64 = options.size.size_in_bytes();
    if (size_limit == 0) {
        return fatal("--size must be given!");
    }

    var current_dir = try std.fs.cwd().openDir(".", .{});
    defer current_dir.close();

    const script_source = try current_dir.readFileAlloc(gpa, script_path, max_script_size);
    defer gpa.free(script_source);

    if (options.@"deps-file") |deps_file_path| {
        global_deps_file = try std.fs.cwd().createFile(deps_file_path, .{});

        try global_deps_file.?.writer().print(
            \\{s}: {s}
        , .{
            output_path,
            script_path,
        });
    }
    defer if (global_deps_file) |deps_file|
        deps_file.close();

    var mem_arena: std.heap.ArenaAllocator = .init(gpa);
    defer mem_arena.deinit();

    var env = Environment{
        .allocator = gpa,
        .arena = mem_arena.allocator(),
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

    const root_content: Content = env.parse_content() catch |err| switch (err) {
        error.FatalConfigError => return 1,

        else => |e| return e,
    };

    if (env.error_flag) {
        return 1;
    }

    {
        var output_file = try current_dir.createFile(output_path, .{ .read = true });
        defer output_file.close();

        try output_file.setEndPos(size_limit);

        var stream: BinaryStream = .init_file(output_file, size_limit);

        try root_content.render(&stream);
    }

    if (global_deps_file) |deps_file| {
        try deps_file.writeAll("\n");
    }

    return 0;
}

pub fn declare_file_dependency(path: []const u8) !void {
    const deps_file = global_deps_file orelse return;

    const stat = try std.fs.cwd().statFile(path);
    if (stat.kind != .directory) {
        try deps_file.writeAll(" \\\n    ");
        try deps_file.writeAll(path);
    }
}

fn fatal(msg: []const u8) noreturn {
    std.debug.print("Error: {s}\n", .{msg});
    std.debug.print("Usage: {s}", .{usage});
    std.process.exit(1);
}

const content_types: []const struct { []const u8, type } = &.{
    .{ "mbr-part", @import("components/part/MbrPartitionTable.zig") },
    // .{ "gpt-part", @import("components/part/GptPartitionTable.zig") },
    .{ "vfat", @import("components/fs/FatFileSystem.zig") },
    .{ "paste-file", @import("components/PasteFile.zig") },
    .{ "empty", @import("components/EmptyData.zig") },
    .{ "fill", @import("components/FillData.zig") },
};

pub const Context = struct {
    env: *Environment,

    pub fn get_arena(ctx: Context) std.mem.Allocator {
        return ctx.env.arena;
    }

    pub fn alloc_object(ctx: Context, comptime T: type) error{OutOfMemory}!*T {
        return try ctx.env.arena.create(T);
    }

    pub fn report_nonfatal_error(ctx: Context, comptime msg: []const u8, params: anytype) error{OutOfMemory}!void {
        try ctx.env.report_error(msg, params);
    }

    pub fn report_fatal_error(ctx: Context, comptime msg: []const u8, params: anytype) error{ FatalConfigError, OutOfMemory } {
        try ctx.env.report_error(msg, params);
        return error.FatalConfigError;
    }

    pub fn parse_string(ctx: Context) Environment.ParseError![]const u8 {
        const str = try ctx.env.parser.next();
        // std.debug.print("token: '{}'\n", .{std.zig.fmtEscapes(str)});
        return str;
    }

    pub fn parse_file_name(ctx: Context) Environment.ParseError!FileName {
        const rel_path = try ctx.parse_string();

        const abs_path = try ctx.env.parser.get_include_path(ctx.env.arena, rel_path);

        return .{
            .root_dir = ctx.env.include_base,
            .rel_path = abs_path,
        };
    }

    pub fn parse_enum(ctx: Context, comptime E: type) Environment.ParseError!E {
        if (@typeInfo(E) != .@"enum")
            @compileError("get_enum requires an enum type!");
        const tag_name = try ctx.parse_string();
        const converted = std.meta.stringToEnum(
            E,
            tag_name,
        );
        if (converted) |ok|
            return ok;
        std.debug.print("detected invalid enum tag for {s}: \"{}\"\n", .{ @typeName(E), std.zig.fmtEscapes(tag_name) });
        std.debug.print("valid options are:\n", .{});

        for (std.enums.values(E)) |val| {
            std.debug.print("- '{s}'\n", .{@tagName(val)});
        }

        return error.InvalidEnumTag;
    }

    pub fn parse_integer(ctx: Context, comptime I: type, base: u8) Environment.ParseError!I {
        if (@typeInfo(I) != .int)
            @compileError("get_integer requires an integer type!");
        return std.fmt.parseInt(
            I,
            try ctx.parse_string(),
            base,
        ) catch return error.InvalidNumber;
    }

    pub fn parse_mem_size(ctx: Context) Environment.ParseError!u64 {
        const str = try ctx.parse_string();

        const ds: DiskSize = try .parse(str);

        return ds.size_in_bytes();
    }

    pub fn parse_content(ctx: Context) Environment.ParseError!Content {
        const content_type_str = try ctx.env.parser.next();

        inline for (content_types) |tn| {
            const name, const impl = tn;

            if (std.mem.eql(u8, name, content_type_str)) {
                const content: Content = try impl.parse(ctx);

                return content;
            }
        }

        return ctx.report_fatal_error("unknown content type: '{}'", .{
            std.zig.fmtEscapes(content_type_str),
        });
    }
};

pub fn FieldUpdater(comptime Obj: type, comptime optional_fields: []const std.meta.FieldEnum(Obj)) type {
    return struct {
        const FUP = @This();
        const FieldName = std.meta.FieldEnum(Obj);

        ctx: Context,
        target: *Obj,

        updated_fields: std.EnumSet(FieldName) = .initEmpty(),

        pub fn init(ctx: Context, target: *Obj) FUP {
            return .{
                .ctx = ctx,
                .target = target,
            };
        }

        pub fn set(fup: *FUP, comptime field: FieldName, value: @FieldType(Obj, @tagName(field))) !void {
            if (fup.updated_fields.contains(field)) {
                try fup.ctx.report_nonfatal_error("duplicate assignment of {s}.{s}", .{
                    @typeName(Obj),
                    @tagName(field),
                });
            }

            @field(fup.target, @tagName(field)) = value;
            fup.updated_fields.insert(field);
        }

        pub fn validate(fup: FUP) !void {
            var missing_fields = fup.updated_fields;
            for (optional_fields) |fld| {
                missing_fields.insert(fld);
            }
            missing_fields = missing_fields.complement();
            var iter = missing_fields.iterator();
            while (iter.next()) |fld| {
                try fup.ctx.report_nonfatal_error("missing assignment of {s}.{s}", .{
                    @typeName(Obj),
                    @tagName(fld),
                });
            }
        }
    };
}

const Environment = struct {
    const ParseError = Parser.Error || error{
        OutOfMemory,
        UnexpectedEndOfFile,
        InvalidNumber,
        UnknownContentType,
        FatalConfigError,
        InvalidEnumTag,
        Overflow,
        InvalidSize,
    };

    arena: std.mem.Allocator,
    allocator: std.mem.Allocator,
    parser: *Parser,
    include_base: std.fs.Dir,
    vars: *const VariableMap,
    error_flag: bool = false,

    io: Parser.IO = .{
        .fetch_file_fn = fetch_file,
        .resolve_variable_fn = resolve_var,
    },

    fn parse_content(env: *Environment) ParseError!Content {
        var ctx = Context{ .env = env };

        return try ctx.parse_content();
    }

    fn report_error(env: *Environment, comptime fmt: []const u8, params: anytype) error{OutOfMemory}!void {
        env.error_flag = true;
        std.log.err("PARSE ERROR: " ++ fmt, params);
    }

    fn fetch_file(io: *const Parser.IO, allocator: std.mem.Allocator, path: []const u8) error{ FileNotFound, IoError, OutOfMemory, InvalidPath }![]const u8 {
        const env: *const Environment = @fieldParentPtr("io", io);

        const contents = env.include_base.readFileAlloc(allocator, path, max_script_size) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound => {
                const ctx = Context{ .env = @constCast(env) };
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                try ctx.report_nonfatal_error("failed to open file: \"{}/{}\"", .{
                    std.zig.fmtEscapes(env.include_base.realpath(".", &buffer) catch return error.FileNotFound),
                    std.zig.fmtEscapes(path),
                });
                return error.FileNotFound;
            },
            else => return error.IoError,
        };
        errdefer allocator.free(contents);

        const name: FileName = .{ .root_dir = env.include_base, .rel_path = path };
        try name.declare_dependency();

        return contents;
    }

    fn resolve_var(io: *const Parser.IO, name: []const u8) error{UnknownVariable}![]const u8 {
        const env: *const Environment = @fieldParentPtr("io", io);
        return env.vars.get(name) orelse return error.UnknownVariable;
    }
};

/// A "Content" is something that will fill a given space of a disk image.
/// It can be raw data, a pattern, a file system, a partition table, ...
///
///
pub const Content = struct {
    pub const RenderError = FileName.OpenError || FileHandle.ReadError || BinaryStream.WriteError || error{
        ConfigurationError,
        OutOfBounds,
        OutOfMemory,
    };
    pub const GuessError = FileName.GetSizeError;

    obj: *anyopaque,
    vtable: *const VTable,

    pub const empty: Content = @import("components/EmptyData.zig").parse(undefined) catch unreachable;

    pub fn create_handle(obj: *anyopaque, vtable: *const VTable) Content {
        return .{ .obj = obj, .vtable = vtable };
    }

    /// Emits the content into a binary stream.
    pub fn render(content: Content, stream: *BinaryStream) RenderError!void {
        try content.vtable.render_fn(content.obj, stream);
    }

    pub const VTable = struct {
        render_fn: *const fn (*anyopaque, *BinaryStream) RenderError!void,

        pub fn create(
            comptime Container: type,
            comptime funcs: struct {
                render_fn: *const fn (*Container, *BinaryStream) RenderError!void,
            },
        ) *const VTable {
            const Wrap = struct {
                fn render(self: *anyopaque, stream: *BinaryStream) RenderError!void {
                    return funcs.render_fn(
                        @ptrCast(@alignCast(self)),
                        stream,
                    );
                }
            };
            return comptime &.{
                .render_fn = Wrap.render,
            };
        }
    };
};

pub const FileName = struct {
    root_dir: std.fs.Dir,
    rel_path: []const u8,

    pub const OpenError = error{ FileNotFound, InvalidPath, IoError };

    pub fn open(name: FileName) OpenError!FileHandle {
        const file = name.root_dir.openFile(name.rel_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                std.log.err("failed to open \"{}/{}\": not found", .{
                    std.zig.fmtEscapes(name.root_dir.realpath(".", &buffer) catch |e| @errorName(e)),
                    std.zig.fmtEscapes(name.rel_path),
                });
                return error.FileNotFound;
            },

            error.NameTooLong,
            error.InvalidWtf8,
            error.BadPathName,
            error.InvalidUtf8,
            => return error.InvalidPath,

            error.NoSpaceLeft,
            error.FileTooBig,
            error.DeviceBusy,
            error.AccessDenied,
            error.SystemResources,
            error.WouldBlock,
            error.NoDevice,
            error.Unexpected,
            error.SharingViolation,
            error.PathAlreadyExists,
            error.PipeBusy,
            error.NetworkNotFound,
            error.AntivirusInterference,
            error.SymLinkLoop,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.IsDir,
            error.NotDir,
            error.FileLocksNotSupported,
            error.FileBusy,
            => return error.IoError,
        };

        try name.declare_dependency();

        return .{ .file = file };
    }

    pub fn open_dir(name: FileName) OpenError!std.fs.Dir {
        const dir = name.root_dir.openDir(name.rel_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => {
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                std.log.err("failed to open \"{}/{}\": not found", .{
                    std.zig.fmtEscapes(name.root_dir.realpath(".", &buffer) catch |e| @errorName(e)),
                    std.zig.fmtEscapes(name.rel_path),
                });
                return error.FileNotFound;
            },

            error.NameTooLong,
            error.InvalidWtf8,
            error.BadPathName,
            error.InvalidUtf8,
            => return error.InvalidPath,

            error.DeviceBusy,
            error.AccessDenied,
            error.SystemResources,
            error.NoDevice,
            error.Unexpected,
            error.NetworkNotFound,
            error.SymLinkLoop,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.NotDir,
            => return error.IoError,
        };

        try name.declare_dependency();

        return dir;
    }

    pub fn declare_dependency(name: FileName) OpenError!void {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;

        const realpath = name.root_dir.realpath(
            name.rel_path,
            &buffer,
        ) catch @panic("failed to determine real path for dependency file!");
        declare_file_dependency(realpath) catch @panic("Failed to write to deps file!");
    }

    pub const GetSizeError = error{ FileNotFound, InvalidPath, IoError };
    pub fn get_size(name: FileName) GetSizeError!u64 {
        const stat = name.root_dir.statFile(name.rel_path) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,

            error.NameTooLong,
            error.InvalidWtf8,
            error.BadPathName,
            error.InvalidUtf8,
            => return error.InvalidPath,

            error.NoSpaceLeft,
            error.FileTooBig,
            error.DeviceBusy,
            error.AccessDenied,
            error.SystemResources,
            error.WouldBlock,
            error.NoDevice,
            error.Unexpected,
            error.SharingViolation,
            error.PathAlreadyExists,
            error.PipeBusy,

            error.NetworkNotFound,
            error.AntivirusInterference,
            error.SymLinkLoop,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.IsDir,
            error.NotDir,
            error.FileLocksNotSupported,
            error.FileBusy,
            => return error.IoError,
        };
        return stat.size;
    }

    pub fn copy_to(file: FileName, stream: *BinaryStream) (OpenError || FileHandle.ReadError || BinaryStream.WriteError)!void {
        var handle = try file.open();
        defer handle.close();

        var fifo: std.fifo.LinearFifo(u8, .{ .Static = 8192 }) = .init();

        try fifo.pump(
            handle.reader(),
            stream.writer(),
        );
    }
};

pub const FileHandle = struct {
    pub const ReadError = error{ReadFileFailed};

    pub const Reader = std.io.Reader(std.fs.File, ReadError, read_some);

    file: std.fs.File,

    pub fn close(fd: *FileHandle) void {
        fd.file.close();
        fd.* = undefined;
    }

    pub fn reader(fd: FileHandle) Reader {
        return .{ .context = fd.file };
    }

    fn read_some(file: std.fs.File, data: []u8) ReadError!usize {
        return file.read(data) catch |err| switch (err) {
            error.InputOutput,
            error.AccessDenied,
            error.BrokenPipe,
            error.SystemResources,
            error.OperationAborted,
            error.LockViolation,
            error.WouldBlock,
            error.ConnectionResetByPeer,
            error.ProcessNotFound,
            error.Unexpected,
            error.IsDir,
            error.ConnectionTimedOut,
            error.NotOpenForReading,
            error.SocketNotConnected,
            error.Canceled,
            => return error.ReadFileFailed,
        };
    }
};

pub const BinaryStream = struct {
    pub const WriteError = error{ Overflow, IoError };
    pub const ReadError = error{ Overflow, IoError };
    pub const Writer = std.io.Writer(*BinaryStream, WriteError, write_some);

    backing: Backing,

    virtual_offset: u64 = 0,

    /// Max number of bytes that can be written
    length: u64,

    /// Constructs a BinaryStream from a slice.
    pub fn init_buffer(data: []u8) BinaryStream {
        return .{
            .backing = .{ .buffer = data.ptr },
            .length = data.len,
        };
    }

    /// Constructs a BinaryStream from a file.
    pub fn init_file(file: std.fs.File, max_len: u64) BinaryStream {
        return .{
            .backing = .{
                .file = .{
                    .file = file,
                    .base = 0,
                },
            },
            .length = max_len,
        };
    }

    /// Returns a view into the stream.
    pub fn slice(bs: BinaryStream, offset: u64, length: ?u64) error{OutOfBounds}!BinaryStream {
        if (offset > bs.length)
            return error.OutOfBounds;
        const true_length = length orelse bs.length - offset;
        if (true_length > bs.length)
            return error.OutOfBounds;

        return .{
            .length = true_length,
            .backing = switch (bs.backing) {
                .buffer => |old| .{ .buffer = old + offset },
                .file => |old| .{
                    .file = .{
                        .file = old.file,
                        .base = old.base + offset,
                    },
                },
            },
        };
    }

    pub fn read(bs: *BinaryStream, offset: u64, data: []u8) ReadError!void {
        const end_pos = offset + data.len;
        if (end_pos > bs.length)
            return error.Overflow;

        switch (bs.backing) {
            .buffer => |ptr| @memcpy(data, ptr[@intCast(offset)..][0..data.len]),
            .file => |state| {
                state.file.seekTo(state.base + offset) catch return error.IoError;
                state.file.reader().readNoEof(data) catch |err| switch (err) {
                    error.InputOutput,
                    error.AccessDenied,
                    error.BrokenPipe,
                    error.SystemResources,
                    error.OperationAborted,
                    error.LockViolation,
                    error.WouldBlock,
                    error.ConnectionResetByPeer,
                    error.ProcessNotFound,
                    error.Unexpected,
                    error.IsDir,
                    error.ConnectionTimedOut,
                    error.NotOpenForReading,
                    error.SocketNotConnected,
                    error.Canceled,
                    error.EndOfStream,
                    => return error.IoError,
                };
            },
        }
    }

    pub fn write(bs: *BinaryStream, offset: u64, data: []const u8) WriteError!void {
        const end_pos = offset + data.len;
        if (end_pos > bs.length)
            return error.Overflow;

        switch (bs.backing) {
            .buffer => |ptr| @memcpy(ptr[@intCast(offset)..][0..data.len], data),
            .file => |state| {
                state.file.seekTo(state.base + offset) catch return error.IoError;
                state.file.writeAll(data) catch |err| switch (err) {
                    error.DiskQuota, error.NoSpaceLeft, error.FileTooBig => return error.Overflow,

                    error.InputOutput,
                    error.DeviceBusy,
                    error.InvalidArgument,
                    error.AccessDenied,
                    error.BrokenPipe,
                    error.SystemResources,
                    error.OperationAborted,
                    error.NotOpenForWriting,
                    error.LockViolation,
                    error.WouldBlock,
                    error.ConnectionResetByPeer,
                    error.ProcessNotFound,
                    error.NoDevice,
                    error.Unexpected,
                    => return error.IoError,
                };
            },
        }
    }

    pub fn seek_to(bs: *BinaryStream, offset: u64) error{OutOfBounds}!void {
        if (offset > bs.length)
            return error.OutOfBounds;
        bs.virtual_offset = offset;
    }

    pub fn writer(bs: *BinaryStream) Writer {
        return .{ .context = bs };
    }

    fn write_some(stream: *BinaryStream, data: []const u8) WriteError!usize {
        const remaining_len = stream.length - stream.virtual_offset;

        const written_len: usize = @intCast(@min(remaining_len, data.len));

        try stream.write(stream.virtual_offset, data[0..written_len]);
        stream.virtual_offset += written_len;

        return written_len;
    }

    pub const Backing = union(enum) {
        file: struct {
            file: std.fs.File,
            base: u64,
        },
        buffer: [*]u8,
    };
};

test {
    _ = Tokenizer;
    _ = Parser;
}

pub const DiskSize = enum(u64) {
    const KiB = 1024;
    const MiB = 1024 * 1024;
    const GiB = 1024 * 1024 * 1024;

    pub const empty: DiskSize = @enumFromInt(0);

    _,

    pub fn parse(str: []const u8) error{ InvalidSize, Overflow }!DiskSize {
        const suffix_scaling: ?u64 = if (std.mem.endsWith(u8, str, "K") or std.mem.endsWith(u8, str, "k"))
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
