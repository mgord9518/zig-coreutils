const std = @import("std");
const subcommands = @import("../subcommands.zig");
const shared = @import("../shared.zig");
const zsw = @import("zsw");

pub const log = std.log.scoped(.base32);

pub const name = "base32";

pub const usage =
    \\Usage: {0s} [OPTION]... [FILE]
    \\
    \\Base32 encode or decode FILE, or standard input, to standard output.
    \\
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\Mandatory arguments to long options are mandatory for short options too.
    \\  -d, --decode          decode data
    \\  -i, --ignore-garbage  when decoding, ignore non-alphabet characters
    \\  -w, --wrap=COLS       wrap encoded lines after COLS character (default 76).
    \\                          Use 0 to disable line wrapping
    \\     --help             display this help and exit
    \\     --version          output version information and exit
    \\
;

// io
// .{
//     .stderr: std.io.Writer,
//     .stdin: std.io.Reader,
//     .stdout: std.io.Writer,
// },

// args
// struct {
//     fn next(self: *Self) ?shared.Arg,
//
//     // intended to only be called for the first argument
//     fn nextWithHelpOrVersion(self: *Self, comptime include_shorthand: bool) !?shared.Arg,
//
//     fn nextRaw(self: *Self) ?[]const u8,
// }

pub inline fn execute(
    allocator: std.mem.Allocator,
    io: anytype,
    args: anytype,
    system: zsw.System,
    exe_path: []const u8,
) subcommands.Error!void {
    const z = shared.tracy.traceNamed(@src(), name);
    defer z.end();
    return shared.basexx(@This(), allocator, io, args, system, exe_path);
}

// test "base32 no args" {
//     try subcommands.testExecute(
//         @This(),
//         &.{},
//         .{},
//     );
// }

test "base32 help" {
    try subcommands.testHelp(@This(), true);
}

test "base32 version" {
    try subcommands.testVersion(@This());
}

comptime {
    refAllDeclsRecursive(@This());
}

/// This is a copy of `std.testing.refAllDeclsRecursive` but as it is in the file it can access private decls
/// Also it only reference structs, enums, unions, opaques, types and functions
fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;
    inline for (comptime std.meta.declarations(T)) |decl| {
        if (decl.is_pub) {
            if (@TypeOf(@field(T, decl.name)) == type) {
                switch (@typeInfo(@field(T, decl.name))) {
                    .Struct, .Enum, .Union, .Opaque => {
                        refAllDeclsRecursive(@field(T, decl.name));
                        _ = @field(T, decl.name);
                    },
                    .Type, .Fn => {
                        _ = @field(T, decl.name);
                    },
                    else => {},
                }
            }
        }
    }
}
