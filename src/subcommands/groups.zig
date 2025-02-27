const std = @import("std");
const subcommands = @import("../subcommands.zig");
const shared = @import("../shared.zig");
const zsw = @import("zsw");

const log = std.log.scoped(.groups);

pub const name = "groups";

pub const usage =
    \\Usage: {0s} [user]
    \\   or: {0s} OPTION
    \\
    \\Display the current group names. 
    \\The optional [user] parameter will display the groups for the named user.
    \\
    \\     -h, --help  display this help and exit
    \\     --version   output version information and exit
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

pub fn execute(
    allocator: std.mem.Allocator,
    io: anytype,
    args: anytype,
    system: zsw.System,
    exe_path: []const u8,
) subcommands.Error!void {
    const z = shared.tracy.traceNamed(@src(), name);
    defer z.end();

    _ = exe_path;

    const opt_arg = try args.nextWithHelpOrVersion(true);

    const passwd_file = system.cwd().openFile("/etc/passwd", .{}) catch
        return shared.printError(@This(), io, "unable to read '/etc/passwd'");
    defer if (shared.free_on_close) passwd_file.close();

    return if (opt_arg) |arg|
        otherUser(allocator, io, arg, passwd_file, system)
    else
        currentUser(allocator, io, passwd_file, system);
}

fn currentUser(
    allocator: std.mem.Allocator,
    io: anytype,
    passwd_file: zsw.File,
    system: zsw.System,
) subcommands.Error!void {
    const z = shared.tracy.traceNamed(@src(), "current user");
    defer z.end();

    const euid = system.geteuid();

    log.debug("currentUser called, euid: {}", .{euid});

    var passwd_file_iter = shared.passwdFileIterator(allocator, passwd_file);
    defer passwd_file_iter.deinit();

    while (try passwd_file_iter.next(@This(), io)) |entry| {
        if (std.fmt.parseUnsigned(std.os.uid_t, entry.user_id, 10)) |user_id| {
            if (user_id == euid) {
                log.debug("found matching user id: {}", .{user_id});

                return if (std.fmt.parseUnsigned(std.os.uid_t, entry.primary_group_id, 10)) |primary_group_id|
                    printGroups(allocator, entry.user_name, primary_group_id, io, system)
                else |_|
                    shared.printError(@This(), io, "format of '/etc/passwd' is invalid");
            } else log.debug("found non-matching user id: {}", .{user_id});
        } else |_| return shared.printError(@This(), io, "format of '/etc/passwd' is invalid");
    }

    return shared.printError(@This(), io, "'/etc/passwd' does not contain the current effective uid");
}

fn otherUser(
    allocator: std.mem.Allocator,
    io: anytype,
    arg: shared.Arg,
    passwd_file: zsw.File,
    system: zsw.System,
) subcommands.Error!void {
    const z = shared.tracy.traceNamed(@src(), "other user");
    defer z.end();
    z.addText(arg.raw);

    log.debug("otherUser called, arg='{s}'", .{arg.raw});

    var passwd_file_iter = shared.passwdFileIterator(allocator, passwd_file);
    defer passwd_file_iter.deinit();

    while (try passwd_file_iter.next(@This(), io)) |entry| {
        if (!std.mem.eql(u8, entry.user_name, arg.raw)) {
            log.debug("found non-matching user: {s}", .{entry.user_name});
            continue;
        }

        log.debug("found matching user: {s}", .{entry.user_name});

        return if (std.fmt.parseUnsigned(std.os.uid_t, entry.primary_group_id, 10)) |primary_group_id|
            printGroups(allocator, entry.user_name, primary_group_id, io, system)
        else |_|
            shared.printError(@This(), io, "format of '/etc/passwd' is invalid");
    }

    return shared.printError(@This(), io, "'/etc/passwd' does not contain the current effective uid");
}

fn printGroups(
    allocator: std.mem.Allocator,
    user_name: []const u8,
    primary_group_id: std.os.uid_t,
    io: anytype,
    system: zsw.System,
) !void {
    const z = shared.tracy.traceNamed(@src(), "print groups");
    defer z.end();
    z.addText(user_name);

    log.debug("printGroups called, user_name='{s}', primary_group_id={}", .{ user_name, primary_group_id });

    var group_file = system.cwd().openFile("/etc/group", .{}) catch
        return shared.printError(@This(), io, "unable to read '/etc/group'");

    defer if (shared.free_on_close) group_file.close();

    var group_file_iter = shared.groupFileIterator(allocator, group_file);
    defer group_file_iter.deinit();

    var first = true;

    while (try group_file_iter.next(@This(), io)) |entry| {
        if (std.fmt.parseUnsigned(std.os.uid_t, entry.group_id, 10)) |group_id| {
            if (group_id == primary_group_id) {
                if (!first) {
                    io.stdout.writeByte(' ') catch |err| return shared.unableToWriteTo("stdout", io, err);
                }
                io.stdout.writeAll(entry.group_name) catch |err| return shared.unableToWriteTo("stdout", io, err);
                first = false;
                continue;
            }
        } else |_| return shared.printError(@This(), io, "format of '/etc/group' is invalid");

        var member_iter = entry.iterateMembers();
        while (member_iter.next()) |member| {
            if (std.mem.eql(u8, member, user_name)) {
                if (!first) {
                    io.stdout.writeByte(' ') catch |err| return shared.unableToWriteTo("stdout", io, err);
                }
                io.stdout.writeAll(entry.group_name) catch |err| return shared.unableToWriteTo("stdout", io, err);
                first = false;
                break;
            }
        }
    }

    io.stdout.writeByte('\n') catch |err| return shared.unableToWriteTo("stdout", io, err);
}

test "groups root" {
    var test_system = try TestSystem.create();
    defer test_system.destroy();

    var stdout = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout.deinit();

    try subcommands.testExecute(
        @This(),
        &.{"root"},
        .{
            .system = test_system.backend.system(),
            .stdout = stdout.writer(),
        },
    );

    try std.testing.expectEqualStrings("root proc scanner users\n", stdout.items);
}

test "groups no args - current user: user" {
    var test_system = try TestSystem.create();
    defer test_system.destroy();

    var stdout = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout.deinit();

    try subcommands.testExecute(
        @This(),
        &.{},
        .{
            .system = test_system.backend.system(),
            .stdout = stdout.writer(),
        },
    );

    try std.testing.expectEqualStrings("sys wheel users rfkill user\n", stdout.items);
}

test "groups help" {
    try subcommands.testHelp(@This(), true);
}

test "groups version" {
    try subcommands.testVersion(@This());
}

const TestSystem = struct {
    backend: *BackendType,

    const BackendType = zsw.Backend(.{
        .fallback_to_host = true,
        .file_system = true,
        .linux_user_group = true,
    });

    pub fn create() !TestSystem {
        var file_system = blk: {
            const file_system = try zsw.FileSystemDescription.create(std.testing.allocator);
            errdefer file_system.destroy();

            const etc = try file_system.root.addDirectory("etc");

            try etc.addFile(
                "passwd",
                \\root:x:0:0::/root:/bin/bash
                \\bin:x:1:1::/:/usr/bin/nologin
                \\daemon:x:2:2::/:/usr/bin/nologin
                \\mail:x:8:12::/var/spool/mail:/usr/bin/nologin
                \\ftp:x:14:11::/srv/ftp:/usr/bin/nologin
                \\http:x:33:33::/srv/http:/usr/bin/nologin
                \\nobody:x:65534:65534:Nobody:/:/usr/bin/nologin
                \\user:x:1000:1000:User:/home/user:/bin/bash
                \\
                ,
            );

            try etc.addFile(
                "group",
                \\root:x:0:root
                \\sys:x:3:bin,user
                \\mem:x:8:
                \\ftp:x:11:
                \\mail:x:12:
                \\log:x:19:
                \\smmsp:x:25:
                \\proc:x:26:root
                \\games:x:50:
                \\lock:x:54:
                \\network:x:90:
                \\floppy:x:94:
                \\scanner:x:96:root
                \\power:x:98:
                \\adm:x:999:daemon
                \\wheel:x:998:user
                \\utmp:x:997:
                \\audio:x:996:
                \\disk:x:995:
                \\input:x:994:
                \\kmem:x:993:
                \\kvm:x:992:
                \\lp:x:991:
                \\optical:x:990:
                \\render:x:989:
                \\sgx:x:988:
                \\storage:x:987:
                \\tty:x:5:
                \\uucp:x:986:
                \\video:x:985:
                \\users:x:984:user,root
                \\rfkill:x:982:user
                \\bin:x:1:daemon
                \\daemon:x:2:bin
                \\http:x:33:
                \\nobody:x:65534:
                \\user:x:1000:
                \\
                ,
            );

            break :blk file_system;
        };
        defer file_system.destroy();

        var linux_user_group: zsw.LinuxUserGroupDescription = .{
            .initial_euid = 1000,
        };

        var backend = try BackendType.create(std.testing.allocator, .{
            .file_system = file_system,
            .linux_user_group = linux_user_group,
        });
        errdefer backend.destroy();

        return TestSystem{
            .backend = backend,
        };
    }

    pub fn destroy(self: *TestSystem) void {
        self.backend.destroy();
    }
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
