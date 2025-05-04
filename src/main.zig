const std = @import("std");
const builtin = @import("builtin");
const ourio = @import("ourio");
const zeit = @import("zeit");

const posix = std.posix;

const Options = struct {
    all: bool = false,
    @"almost-all": bool = false,
    color: enum { none, auto, always } = .auto,
    @"group-directories-first": bool = true,
    long: bool = false,

    directory: [:0]const u8 = ".",

    isatty: bool = false,
    colors: Colors = .none,

    const Colors = struct {
        reset: []const u8,
        dir: []const u8,
        executable: []const u8,
        sym_link: []const u8,

        const none: Colors = .{
            .reset = "",
            .dir = "",
            .executable = "",
            .sym_link = "",
        };

        const default: Colors = .{
            .reset = _reset,
            .dir = bold ++ blue,
            .executable = bold ++ green,
            .sym_link = bold ++ purple,
        };

        const _reset = "\x1b[m";
        const red = "\x1b[31m";
        const green = "\x1b[32m";
        const yellow = "\x1b[33m";
        const blue = "\x1b[34m";
        const purple = "\x1b[35m";
        const cyan = "\x1b[36m";
        const fg = "\x1b[37m";

        const bold = "\x1b[1m";
    };
    fn useColor(self: Options) bool {
        switch (self.color) {
            .none => return false,
            .always => return true,
            .auto => return self.isatty,
        }
    }
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var sfb = std.heap.stackFallback(1 << 20, arena.allocator());
    const allocator = sfb.get();

    var cmd: Command = .{ .arena = allocator };

    var args = std.process.args();
    // skip binary
    _ = args.next();
    while (args.next()) |arg| {
        switch (optKind(arg)) {
            .short => {
                const str = arg[1..];
                for (str) |b| {
                    switch (b) {
                        'A' => cmd.opts.@"almost-all" = true,
                        'a' => cmd.opts.all = true,
                        'l' => cmd.opts.long = true,
                        else => {
                            const w = std.io.getStdErr().writer();
                            try w.print("Invalid opt: '{c}'", .{b});
                            std.process.exit(1);
                        },
                    }
                }
            },
            .long => {
                var split = std.mem.splitScalar(u8, arg[2..], '=');
                const opt = split.first();
                const val = split.rest();
                if (eql(opt, "all")) {
                    if (val.len == 0 or eql(val, "true"))
                        cmd.opts.all = true
                    else if (eql(val, "false"))
                        cmd.opts.all = false;
                } else if (eql(opt, "long")) {
                    if (val.len == 0 or eql(val, "true"))
                        cmd.opts.long = true
                    else if (eql(val, "false"))
                        cmd.opts.long = false;
                } else if (eql(opt, "almost-all")) {
                    if (val.len == 0 or eql(val, "true"))
                        cmd.opts.@"almost-all" = true
                    else if (eql(val, "false"))
                        cmd.opts.@"almost-all" = false;
                } else if (eql(opt, "group-directories-first")) {
                    if (val.len == 0 or eql(val, "true"))
                        cmd.opts.@"group-directories-first" = true
                    else if (eql(val, "false"))
                        cmd.opts.@"group-directories-first" = false;
                } else if (eql(opt, "color")) {
                    if (eql(val, "always"))
                        cmd.opts.color = .always
                    else if (eql(val, "auto"))
                        cmd.opts.color = .auto
                    else if (eql(val, "none"))
                        cmd.opts.color = .none;
                } else {
                    const w = std.io.getStdErr().writer();
                    try w.print("Invalid opt: '{s}'", .{opt});
                    std.process.exit(1);
                }
            },
            .positional => {
                cmd.opts.directory = arg;
            },
        }
    }

    var ring: ourio.Ring = try .init(allocator, 256);
    defer ring.deinit();

    _ = try ring.open(cmd.opts.directory, .{ .DIRECTORY = true, .CLOEXEC = true }, 0, .{
        .ptr = &cmd,
        .cb = onCompletion,
        .msg = @intFromEnum(Msg.cwd),
    });

    if (cmd.opts.long) {
        _ = try ring.open("/etc/localtime", .{ .CLOEXEC = true }, 0, .{
            .ptr = &cmd,
            .cb = onCompletion,
            .msg = @intFromEnum(Msg.localtime),
        });
        _ = try ring.open("/etc/passwd", .{ .CLOEXEC = true }, 0, .{
            .ptr = &cmd,
            .cb = onCompletion,
            .msg = @intFromEnum(Msg.passwd),
        });
        _ = try ring.open("/etc/group", .{ .CLOEXEC = true }, 0, .{
            .ptr = &cmd,
            .cb = onCompletion,
            .msg = @intFromEnum(Msg.group),
        });
    }

    if (cmd.opts.color == .auto) {
        cmd.opts.isatty = posix.isatty(std.io.getStdOut().handle);
    }

    if (cmd.opts.useColor()) {
        cmd.opts.colors = .default;
    }

    try ring.run(.until_done);

    std.sort.insertion(Entry, cmd.entries, cmd.opts, Entry.lessThan);

    const stdout = std.io.getStdOut();
    var bw = std.io.bufferedWriter(stdout.writer());
    if (cmd.opts.long) {
        try printLong(cmd, bw.writer());
    } else {
        try printShort(cmd, bw.writer());
    }
    try bw.flush();
}

fn printShort(cmd: Command, writer: anytype) !void {
    const colors = cmd.opts.colors;
    for (cmd.entries) |entry| {
        const mode = entry.modeStr();
        switch (entry.kind) {
            .directory => try writer.writeAll(colors.dir),
            .sym_link => try writer.writeAll(colors.sym_link),
            else => {
                if (isExecutable(mode)) {
                    try writer.writeAll(colors.executable);
                }
            },
        }
        try writer.writeAll(entry.name);
        try writer.writeAll(colors.reset);
        try writer.writeAll("\r\n");
    }
}

fn printLong(cmd: Command, writer: anytype) !void {
    const tz = cmd.tz.?;
    const now = zeit.instant(.{}) catch unreachable;
    const one_year_ago = try now.subtract(.{ .days = 365 });
    const colors = cmd.opts.colors;

    const longest_group, const longest_user, const longest_size, const longest_suffix = blk: {
        var n_group: usize = 0;
        var n_user: usize = 0;
        var n_size: usize = 0;
        var n_suff: usize = 0;
        for (cmd.entries) |entry| {
            const group = cmd.getGroup(entry.statx.gid).?;
            const user = cmd.getGroup(entry.statx.uid).?;
            var buf: [16]u8 = undefined;
            const size = try entry.humanReadableSize(&buf);
            n_group = @max(n_group, group.name.len);
            n_user = @max(n_user, user.name.len);
            n_size = @max(n_size, size.len);
            n_suff = @max(n_suff, entry.humanReadableSuffix().len);
        }
        break :blk .{ n_group, n_user, n_size, n_suff };
    };

    for (cmd.entries) |entry| {
        const user = cmd.getUser(entry.statx.uid).?;
        const group = cmd.getGroup(entry.statx.gid).?;
        const ts = @as(i128, entry.statx.mtime.sec) * std.time.ns_per_s;
        const inst: zeit.Instant = .{ .timestamp = ts, .timezone = &tz };
        const time = inst.time();

        const mode = entry.modeStr();

        try writer.writeAll(&mode);
        try writer.writeByte(' ');
        try writer.writeAll(user.name);
        try writer.writeByteNTimes(' ', longest_user - user.name.len);
        try writer.writeByte(' ');
        try writer.writeAll(group.name);
        try writer.writeByteNTimes(' ', longest_group - group.name.len);
        try writer.writeByte(' ');

        var size_buf: [16]u8 = undefined;
        const size = try entry.humanReadableSize(&size_buf);
        const suffix = entry.humanReadableSuffix();

        try writer.writeByteNTimes(' ', longest_size - size.len);
        try writer.writeAll(size);
        try writer.writeByte(' ');
        try writer.writeAll(suffix);
        try writer.writeByteNTimes(' ', longest_suffix - suffix.len);
        try writer.writeByte(' ');

        try writer.print("{d: >2} {s} ", .{
            time.day,
            time.month.shortName(),
        });

        if (ts > one_year_ago.timestamp) {
            try writer.print("{d: >2}:{d:0>2} ", .{ time.hour, time.minute });
        } else {
            try writer.print("{d: >5} ", .{@as(u32, @intCast(time.year))});
        }

        switch (entry.kind) {
            .directory => try writer.writeAll(colors.dir),
            .sym_link => try writer.writeAll(colors.sym_link),
            else => {
                if (isExecutable(mode)) {
                    try writer.writeAll(colors.executable);
                }
            },
        }
        try writer.writeAll(entry.name);
        try writer.writeAll(colors.reset);

        if (entry.kind == .sym_link) {
            try writer.writeAll(" -> ");
            try writer.writeAll(entry.link_name);
        }

        try writer.writeAll("\r\n");
    }
}

const Command = struct {
    arena: std.mem.Allocator,
    opts: Options = .{},
    entries: []Entry = &.{},

    tz: ?zeit.TimeZone = null,
    groups: std.ArrayListUnmanaged(Group) = .empty,
    users: std.ArrayListUnmanaged(User) = .empty,

    fn getUser(self: Command, uid: posix.uid_t) ?User {
        for (self.users.items) |user| {
            if (user.uid == uid) return user;
        }
        return null;
    }

    fn getGroup(self: Command, gid: posix.gid_t) ?Group {
        for (self.groups.items) |group| {
            if (group.gid == gid) return group;
        }
        return null;
    }
};

const Msg = enum(u16) {
    cwd,
    localtime,
    passwd,
    group,
    stat,

    read_localtime,
    read_passwd,
    read_group,
};

const User = struct {
    uid: posix.uid_t,
    name: []const u8,

    fn lessThan(_: void, lhs: User, rhs: User) bool {
        return lhs.uid < rhs.uid;
    }
};

const Group = struct {
    gid: posix.gid_t,
    name: []const u8,

    fn lessThan(_: void, lhs: Group, rhs: Group) bool {
        return lhs.gid < rhs.gid;
    }
};

const Entry = struct {
    name: [:0]const u8,
    kind: std.fs.File.Kind,
    statx: ourio.Statx,
    link_name: [:0]const u8 = "",

    fn lessThan(opts: Options, lhs: Entry, rhs: Entry) bool {
        if (opts.@"group-directories-first" and
            lhs.kind != rhs.kind and
            (lhs.kind == .directory or rhs.kind == .directory))
        {
            return lhs.kind == .directory;
        }

        return std.ascii.orderIgnoreCase(lhs.name, rhs.name).compare(.lt);
    }

    fn modeStr(self: Entry) [10]u8 {
        var mode = [_]u8{'-'} ** 10;
        switch (self.kind) {
            .directory => mode[0] = 'd',
            .sym_link => mode[0] = 'l',
            else => {},
        }

        if (self.statx.mode & posix.S.IRUSR != 0) mode[1] = 'r';
        if (self.statx.mode & posix.S.IWUSR != 0) mode[2] = 'w';
        if (self.statx.mode & posix.S.IXUSR != 0) mode[3] = 'x';

        if (self.statx.mode & posix.S.IRGRP != 0) mode[4] = 'r';
        if (self.statx.mode & posix.S.IWGRP != 0) mode[5] = 'w';
        if (self.statx.mode & posix.S.IXGRP != 0) mode[6] = 'x';

        if (self.statx.mode & posix.S.IROTH != 0) mode[7] = 'r';
        if (self.statx.mode & posix.S.IWOTH != 0) mode[8] = 'w';
        if (self.statx.mode & posix.S.IXOTH != 0) mode[9] = 'x';
        return mode;
    }

    fn humanReadableSuffix(self: Entry) []const u8 {
        if (self.kind == .directory) return "-";

        const buckets = [_]u64{
            1 << 40, // TB
            1 << 30, // GB
            1 << 20, // MB
            1 << 10, // KB
        };

        const suffixes = [_][]const u8{ "TB", "GB", "MB", "KB" };

        for (buckets, suffixes) |bucket, suffix| {
            if (self.statx.size >= bucket) {
                return suffix;
            }
        }
        return "B";
    }

    fn humanReadableSize(self: Entry, out: []u8) ![]u8 {
        if (self.kind == .directory) return &.{};

        const buckets = [_]u64{
            1 << 40, // TB
            1 << 30, // GB
            1 << 20, // MB
            1 << 10, // KB
        };

        for (buckets) |bucket| {
            if (self.statx.size >= bucket) {
                const size_f: f64 = @floatFromInt(self.statx.size);
                const bucket_f: f64 = @floatFromInt(bucket);
                const val = size_f / bucket_f;
                return std.fmt.bufPrint(out, "{d:0.1}", .{val});
            }
        }
        return std.fmt.bufPrint(out, "{d}", .{self.statx.size});
    }
};

fn onCompletion(io: *ourio.Ring, task: ourio.Task) anyerror!void {
    const cmd = task.userdataCast(Command);
    const msg = task.msgToEnum(Msg);
    const result = task.result.?;

    switch (msg) {
        .cwd => {
            const fd = try result.open;
            // we are async, no need to defer!
            _ = try io.close(fd, .{});
            const dir: std.fs.Dir = .{ .fd = fd };

            var results: std.ArrayListUnmanaged(Entry) = .empty;

            // Preallocate some memory
            try results.ensureUnusedCapacity(cmd.arena, 64);

            // zig skips "." and "..", so we manually add them if needed
            if (cmd.opts.all) {
                results.appendAssumeCapacity(.{
                    .name = ".",
                    .kind = .directory,
                    .statx = undefined,
                });
                results.appendAssumeCapacity(.{
                    .name = "..",
                    .kind = .directory,
                    .statx = undefined,
                });
            }

            var iter = dir.iterate();
            while (try iter.next()) |dirent| {
                if (!cmd.opts.all and std.mem.startsWith(u8, dirent.name, ".")) continue;
                const nameZ = try cmd.arena.dupeZ(u8, dirent.name);
                try results.append(cmd.arena, .{
                    .name = nameZ,
                    .kind = dirent.kind,
                    .statx = undefined,
                });
            }
            cmd.entries = results.items;

            for (cmd.entries) |*entry| {
                const path = try std.fs.path.joinZ(
                    cmd.arena,
                    &.{ cmd.opts.directory, entry.name },
                );

                if (entry.kind == .sym_link) {
                    var buf: [std.fs.max_path_bytes]u8 = undefined;

                    // NOTE: Sadly, we can't do readlink via io_uring
                    const link = try posix.readlink(path, &buf);
                    entry.link_name = try cmd.arena.dupeZ(u8, link);
                }
                _ = try io.stat(path, &entry.statx, .{
                    .cb = onCompletion,
                    .ptr = cmd,
                    .msg = @intFromEnum(Msg.stat),
                });
            }
        },

        .localtime => {
            const fd = try result.open;

            // Largest TZ file on my system is Asia/Hebron at 4791 bytes. We allocate an amount
            // sufficiently more than that to make sure we do this in a single pass
            const buffer = try cmd.arena.alloc(u8, 8192);
            _ = try io.read(fd, buffer, .{
                .cb = onCompletion,
                .ptr = cmd,
                .msg = @intFromEnum(Msg.read_localtime),
            });
        },

        .read_localtime => {
            const n = try result.read;
            _ = try io.close(task.req.read.fd, .{});
            const bytes = task.req.read.buffer[0..n];
            var fbs = std.io.fixedBufferStream(bytes);
            const tz = try zeit.timezone.TZInfo.parse(cmd.arena, fbs.reader());
            cmd.tz = .{ .tzinfo = tz };
        },

        .passwd => {
            const fd = try result.open;

            // TODO: stat this or do multiple reads. We'll never know a good bound unless we go
            // really big
            const buffer = try cmd.arena.alloc(u8, 8192 * 2);
            _ = try io.read(fd, buffer, .{
                .cb = onCompletion,
                .ptr = cmd,
                .msg = @intFromEnum(Msg.read_passwd),
            });
        },

        .read_passwd => {
            const n = try result.read;
            _ = try io.close(task.req.read.fd, .{});
            const bytes = task.req.read.buffer[0..n];

            var lines = std.mem.splitScalar(u8, bytes, '\n');

            var line_count: usize = 0;
            while (lines.next()) |_| {
                line_count += 1;
            }
            try cmd.users.ensureUnusedCapacity(cmd.arena, line_count);
            lines.reset();
            // <name>:<throwaway>:<uid><...garbage>
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                var iter = std.mem.splitScalar(u8, line, ':');
                const name = iter.first();
                _ = iter.next();
                const uid = iter.next().?;

                const user: User = .{
                    .name = name,
                    .uid = try std.fmt.parseInt(u32, uid, 10),
                };

                cmd.users.appendAssumeCapacity(user);
            }
            std.mem.sort(User, cmd.users.items, {}, User.lessThan);
        },

        .group => {
            const fd = try result.open;

            const buffer = try cmd.arena.alloc(u8, 8192);
            _ = try io.read(fd, buffer, .{
                .cb = onCompletion,
                .ptr = cmd,
                .msg = @intFromEnum(Msg.read_group),
            });
        },

        .read_group => {
            const n = try result.read;
            _ = try io.close(task.req.read.fd, .{});
            const bytes = task.req.read.buffer[0..n];

            var lines = std.mem.splitScalar(u8, bytes, '\n');

            var line_count: usize = 0;
            while (lines.next()) |_| {
                line_count += 1;
            }
            try cmd.groups.ensureUnusedCapacity(cmd.arena, line_count);
            lines.reset();
            // <name>:<throwaway>:<uid><...garbage>
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                var iter = std.mem.splitScalar(u8, line, ':');
                const name = iter.first();
                _ = iter.next();
                const gid = iter.next().?;

                const group: Group = .{
                    .name = name,
                    .gid = try std.fmt.parseInt(u32, gid, 10),
                };

                cmd.groups.appendAssumeCapacity(group);
            }
            std.mem.sort(Group, cmd.groups.items, {}, Group.lessThan);
        },

        else => {},
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn optKind(a: []const u8) enum { short, long, positional } {
    if (std.mem.startsWith(u8, a, "--")) return .long;
    if (std.mem.startsWith(u8, a, "-")) return .short;
    return .positional;
}

fn isExecutable(mode: [10]u8) bool {
    return mode[3] == 'x' or mode[6] == 'x' or mode[9] == 'x';
}
