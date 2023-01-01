const std = @import("std");
const subcommands = @import("../subcommands.zig");
const shared = @import("../shared.zig");
const zsw = @import("zsw");

pub fn basexx(
    comptime subcommand: type,
    allocator: std.mem.Allocator,
    io: anytype,
    args: anytype,
    system: zsw.System,
    exe_path: []const u8,
) subcommands.Error!void {
    const options = try parseArguments(subcommand, allocator, io, args, exe_path);
    return performBase(subcommand, allocator, io, system, options);
}

fn parseArguments(
    comptime subcommand: type,
    allocator: std.mem.Allocator,
    io: anytype,
    args: anytype,
    exe_path: []const u8,
) !BaseOptions {
    const is_base32 = subcommand == @import("../subcommands/base32.zig");

    const log = subcommand.log;

    const z = shared.tracy.traceNamed(@src(), "parse arguments");
    defer z.end();

    var opt_arg: ?shared.Arg = try args.nextWithHelpOrVersion(true);

    var options: BaseOptions = .{
        .algorithm = if (is_base32) .base32 else .base64,
    };

    const State = union(enum) {
        normal,
        wrap_columns,
        multiple_files,
        wrap_columns_failed: WrapColumnsFailed,
        invalid_argument: Argument,

        const WrapColumnsFailed = struct {
            value: []const u8,
            err: []const u8,
        };

        const Argument = union(enum) {
            slice: []const u8,
            character: u8,
        };
    };

    var state: State = .normal;

    while (opt_arg) |*arg| : (opt_arg = args.next()) {
        switch (arg.arg_type) {
            .longhand => |longhand| {
                if (state != .normal) break;

                if (std.mem.eql(u8, longhand, "decode")) {
                    options.method = .decode;
                    log.debug("got do decode longhand", .{});
                } else if (std.mem.eql(u8, longhand, "ignore-garbage")) {
                    options.ignore_garbage = true;
                    log.debug("got ignore garbage longhand", .{});
                } else if (std.mem.eql(u8, longhand, "wrap")) {
                    state = .wrap_columns;
                    log.debug("got wrap columns longhand", .{});
                } else {
                    state = .{ .invalid_argument = .{ .slice = longhand } };
                    break;
                }
            },
            .shorthand => |*shorthand| {
                while (shorthand.next()) |char| {
                    if (state != .normal) break;

                    switch (char) {
                        'd' => {
                            options.method = .decode;
                            log.debug("got decode shorthand", .{});
                        },
                        'i' => {
                            options.ignore_garbage = true;
                            log.debug("got ignore garbage shorthand", .{});
                        },
                        'w' => {
                            state = .wrap_columns;
                            log.debug("got wrap columns shorthand", .{});
                        },
                        else => {
                            state = .{ .invalid_argument = .{ .character = char } };
                            break;
                        },
                    }
                }
            },
            .longhand_with_value => |longhand_with_value| {
                if (state != .normal) break;

                if (std.mem.eql(u8, longhand_with_value.longhand, "wrap")) {
                    log.debug("got wrap longhand, columns string: '{s}'", .{longhand_with_value.value});

                    options.wrap_columns = std.fmt.parseUnsigned(
                        usize,
                        longhand_with_value.value,
                        10,
                    ) catch |err| {
                        state = .{
                            .wrap_columns_failed = .{
                                .value = longhand_with_value.value,
                                .err = @errorName(err),
                            },
                        };
                        break;
                    };
                } else {
                    state = .{ .invalid_argument = .{ .slice = longhand_with_value.longhand } };
                    break;
                }
            },
            .positional => {
                switch (state) {
                    .normal => {
                        if (options.file_arg != null) {
                            state = .multiple_files;
                            break;
                        }
                        options.file_arg = arg.raw;
                    },
                    .wrap_columns => {
                        log.debug("got wrap columns value: '{s}'", .{arg.raw});
                        options.wrap_columns = std.fmt.parseUnsigned(
                            usize,
                            arg.raw,
                            10,
                        ) catch |err| {
                            state = .{
                                .wrap_columns_failed = .{
                                    .value = arg.raw,
                                    .err = @errorName(err),
                                },
                            };
                            break;
                        };
                        state = .normal;
                        continue;
                    },
                    else => break,
                }
            },
        }
    }

    return switch (state) {
        .normal => options,
        .wrap_columns => shared.printInvalidUsage(subcommand, io, exe_path, "expected number of columns for wrap columns argument"),
        .multiple_files => shared.printInvalidUsage(subcommand, io, exe_path, "multiple files given"),
        .wrap_columns_failed => |failed| shared.printErrorAlloc(
            subcommand,
            allocator,
            io,
            "failed to parse '{s}' as an unsigned integer: {s}",
            .{ failed.value, failed.err },
        ),
        .invalid_argument => |invalid_arg| switch (invalid_arg) {
            .slice => |slice| shared.printInvalidUsageAlloc(subcommand, allocator, io, exe_path, "unrecognized option '{s}'", .{slice}),
            .character => |character| shared.printInvalidUsageAlloc(subcommand, allocator, io, exe_path, "unrecognized option -- '{c}'", .{character}),
        },
    };
}

fn performBase(
    comptime subcommand: type,
    allocator: std.mem.Allocator,
    io: anytype,
    system: zsw.System,
    options: BaseOptions,
) !void {
    const log = subcommand.log;

    const z = shared.tracy.traceNamed(@src(), "perform base");
    defer z.end();
    z.addText(@tagName(options.algorithm));

    log.debug("performBase called, options={}", .{options});

    const file: zsw.File = if (options.file_arg) |file|
        system.cwd().openFile(file, .{}) catch |err|
            return shared.printErrorAlloc(
            subcommand,
            allocator,
            io,
            "failed to open '{s}': {s}",
            .{ file, @errorName(err) },
        )
    else
        system.getStdIn();
    defer file.close();

    // TODO: Actually implement base32/64 encoding and decoding.
    @panic("UNIMPLEMENTED");
}

const BaseOptions = struct {
    algorithm: Algorithm,

    method: Method = .encode,

    /// when decoding, ignore non-alphabet characters
    ignore_garbage: bool = false,

    /// number of columns to wrap encoded lines after
    /// 0 to disables line wrapping
    wrap_columns: usize = 76,

    file_arg: ?[]const u8 = null,

    pub const Method = enum {
        encode,
        decode,
    };

    // TODO: Support other alphabets
    pub const Algorithm = enum {
        /// RFC 4648
        base32,

        /// RFC 4648
        base64,
    };
};

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
