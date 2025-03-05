//!
//! Disk Imager Command Line
//!
const std = @import("std");

const Tokenizer = @import("Tokenizer.zig");
const Parser = @import("Parser.zig");
const args = @import("args");

const Options = struct {
    output: ?[]const u8 = null,
    size: ?u32 = null,
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

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();

    const gpa = gpa_impl.allocator();

    const opts = try args.parseForCurrentProcess(Options, gpa, .print);
    defer opts.deinit();

    var var_map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer var_map.deinit(gpa);

    for (opts.positionals) |pos| {
        if (std.mem.indexOfScalar(u8, pos, '=')) |idx| {
            const key = pos[0..idx];
            const val = pos[idx + 1 ..];
            try var_map.put(gpa, key, val);
        }
    }

    const options = opts.options;

    if (options.output == null) {
        fatal("No output path specified");
    }

    if (options.script == null) {
        fatal("No script specified");
    }

    std.debug.print(
        "Output={?s} Script={?s} Size={?} import-env={}\n",
        .{ options.output, options.script, options.size, options.@"import-env" },
    );
}

fn fatal(msg: []const u8) noreturn {
    std.debug.print("Error: {s}\n", .{msg});
    std.debug.print("Usage: {s}", .{usage});
    std.process.exit(1);
}

test {
    _ = Tokenizer;
    _ = Parser;
}
