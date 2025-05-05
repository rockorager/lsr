const std = @import("std");
const builtin = @import("builtin");
const ourio = @import("ourio");
const zeit = @import("zeit");

const posix = std.posix;

const usage =
    \\Usage: 
    \\  els [options] [directory]
    \\
    \\  --help                           Print this message and exit
    \\
    \\DISPLAY OPTIONS
    \\  -1, --oneline                    Print entries one per line
    \\  -a, --all                        Show files that start with a dot (ASCII 0x2E)
    \\  -A, --almost-all                 Like --all, but skips implicit "." and ".." directories
    \\  -C, --columns                    Print the output in columns
    \\      --color=WHEN                 When to use colors (always, auto, never)
    \\      --group-directories-first    When to use colors (always, auto, never)
    \\      --icons=WHEN                 When to display icons (always, auto, never)
    \\  -l, --long                       Display extended file metadata
;

const Options = struct {
    all: bool = false,
    @"almost-all": bool = false,
    color: When = .auto,
    shortview: enum { columns, oneline } = .oneline,
    @"group-directories-first": bool = true,
    icons: When = .auto,
    long: bool = false,

    directory: [:0]const u8 = ".",

    winsize: ?posix.winsize = null,
    colors: Colors = .none,

    const When = enum {
        never,
        auto,
        always,
    };

    const Colors = struct {
        reset: []const u8,
        dir: []const u8,
        executable: []const u8,
        symlink: []const u8,
        symlink_target: []const u8,
        symlink_missing: []const u8,

        const none: Colors = .{
            .reset = "",
            .dir = "",
            .executable = "",
            .symlink = "",
            .symlink_target = "",
            .symlink_missing = "",
        };

        const default: Colors = .{
            .reset = _reset,
            .dir = bold ++ blue,
            .executable = bold ++ green,
            .symlink = bold ++ purple,
            .symlink_target = bold ++ cyan,
            .symlink_missing = bold ++ red,
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
            .never => return false,
            .always => return true,
            .auto => return self.isatty(),
        }
    }

    fn useIcons(self: Options) bool {
        switch (self.icons) {
            .never => return false,
            .always => return true,
            .auto => return self.isatty(),
        }
    }

    fn isatty(self: Options) bool {
        return self.winsize != null;
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

    cmd.opts.winsize = getWinsize(std.io.getStdOut().handle);

    cmd.opts.shortview = if (cmd.opts.isatty()) .columns else .oneline;

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();
    var bw = std.io.bufferedWriter(stdout);

    var args = std.process.args();
    // skip binary
    _ = args.next();
    while (args.next()) |arg| {
        switch (optKind(arg)) {
            .short => {
                const str = arg[1..];
                for (str) |b| {
                    switch (b) {
                        '1' => cmd.opts.shortview = .oneline,
                        'A' => cmd.opts.@"almost-all" = true,
                        'C' => cmd.opts.shortview = .columns,
                        'a' => cmd.opts.all = true,
                        'l' => cmd.opts.long = true,
                        else => {
                            try stderr.print("Invalid opt: '{c}'", .{b});
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
                    cmd.opts.all = parseArgBool(val) orelse {
                        try stderr.print("Invalid boolean: '{s}'", .{val});
                        std.process.exit(1);
                    };
                } else if (eql(opt, "long")) {
                    cmd.opts.long = parseArgBool(val) orelse {
                        try stderr.print("Invalid boolean: '{s}'", .{val});
                        std.process.exit(1);
                    };
                } else if (eql(opt, "almost-all")) {
                    cmd.opts.@"almost-all" = parseArgBool(val) orelse {
                        try stderr.print("Invalid boolean: '{s}'", .{val});
                        std.process.exit(1);
                    };
                } else if (eql(opt, "group-directories-first")) {
                    cmd.opts.@"group-directories-first" = parseArgBool(val) orelse {
                        try stderr.print("Invalid boolean: '{s}'", .{val});
                        std.process.exit(1);
                    };
                } else if (eql(opt, "color")) {
                    cmd.opts.color = std.meta.stringToEnum(Options.When, val) orelse {
                        try stderr.print("Invalid color option: '{s}'", .{val});
                        std.process.exit(1);
                    };
                } else if (eql(opt, "icons")) {
                    cmd.opts.icons = std.meta.stringToEnum(Options.When, val) orelse {
                        try stderr.print("Invalid color option: '{s}'", .{val});
                        std.process.exit(1);
                    };
                } else if (eql(opt, "columns")) {
                    const c = parseArgBool(val) orelse {
                        try stderr.print("Invalid columns option: '{s}'", .{val});
                        std.process.exit(1);
                    };
                    cmd.opts.shortview = if (c) .columns else .oneline;
                } else if (eql(opt, "oneline")) {
                    const o = parseArgBool(val) orelse {
                        try stderr.print("Invalid oneline option: '{s}'", .{val});
                        std.process.exit(1);
                    };
                    cmd.opts.shortview = if (o) .oneline else .columns;
                } else if (eql(opt, "help")) {
                    return stderr.writeAll(usage);
                } else {
                    try stderr.print("Invalid opt: '{s}'", .{opt});
                    std.process.exit(1);
                }
            },
            .positional => {
                cmd.opts.directory = arg;
            },
        }
    }

    if (cmd.opts.useColor()) {
        cmd.opts.colors = .default;
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

    try ring.run(.until_done);

    std.sort.insertion(Entry, cmd.entries, cmd.opts, Entry.lessThan);

    if (cmd.entries.len == 0) return;

    if (cmd.opts.long)
        try printLong(cmd, bw.writer())
    else switch (cmd.opts.shortview) {
        .columns => try printShortColumns(cmd, bw.writer()),
        .oneline => try printShortOnePerLine(cmd, bw.writer()),
    }
    try bw.flush();
}

fn printShortColumns(cmd: Command, writer: anytype) !void {
    const win_width = blk: {
        const ws = cmd.opts.winsize orelse break :blk 80;
        break :blk ws.col;
    };
    if (win_width == 0) return printShortOnePerLine(cmd, writer);

    const icon_width: u2 = if (cmd.opts.useIcons()) 2 else 0;

    var n_cols = @min(win_width, cmd.entries.len);

    const Column = struct {
        width: usize = 0,
        entries: []const Entry = &.{},
    };

    var columns: std.ArrayListUnmanaged(Column) = try .initCapacity(cmd.arena, n_cols);

    outer: while (n_cols > 0) {
        columns.clearRetainingCapacity();
        const n_rows = std.math.divCeil(usize, cmd.entries.len, n_cols) catch unreachable;
        const padding = (n_cols - 1) * 2;

        // The number of columns that are short by one entry
        const short_cols = n_cols * n_rows - cmd.entries.len;

        var idx: usize = 0;
        var line_width: usize = padding + icon_width * n_cols;

        if (line_width > win_width) {
            n_cols -= 1;
            continue :outer;
        }

        for (0..n_cols) |i| {
            const col_entries = if (isShortColumn(i, n_cols, short_cols)) n_rows - 1 else n_rows;
            const entries = cmd.entries[idx .. idx + col_entries];
            idx += col_entries;

            var max_width: usize = 0;
            for (entries) |entry| {
                max_width = @max(max_width, entry.name.len);
            }

            // line_width already includes all icons and padding
            line_width += max_width;

            const col_width = max_width + icon_width + 2;

            columns.appendAssumeCapacity(.{
                .entries = entries,
                .width = col_width,
            });

            if (line_width > win_width) {
                n_cols -= 1;
                continue :outer;
            }
        }

        break :outer;
    }

    if (n_cols <= 1) return printShortOnePerLine(cmd, writer);

    const n_rows = std.math.divCeil(usize, cmd.entries.len, columns.items.len) catch unreachable;
    for (0..n_rows) |row| {
        for (columns.items, 0..) |column, i| {
            if (row >= column.entries.len) continue;
            const entry = column.entries[row];
            try printShortEntry(column.entries[row], cmd.opts, writer);

            if (i < columns.items.len - 1) {
                const spaces = column.width - (icon_width + entry.name.len);
                try writer.writeByteNTimes(' ', spaces);
            }
        }
        try writer.writeAll("\r\n");
    }
}

fn isShortColumn(idx: usize, n_cols: usize, n_short_cols: usize) bool {
    return idx + n_short_cols >= n_cols;
}

fn printShortEntry(entry: Entry, opts: Options, writer: anytype) !void {
    const colors = opts.colors;
    if (opts.useIcons()) {
        const icon = Icon.get(entry, opts);

        if (opts.useColor()) {
            try writer.writeAll(icon.color);
            try writer.writeAll(icon.icon);
            try writer.writeAll(colors.reset);
        } else {
            try writer.writeAll(icon.icon);
        }

        try writer.writeByte(' ');
    }
    switch (entry.kind) {
        .directory => try writer.writeAll(colors.dir),
        .sym_link => try writer.writeAll(colors.symlink),
        else => {
            if (entry.isExecutable()) {
                try writer.writeAll(colors.executable);
            }
        },
    }
    try writer.writeAll(entry.name);
    try writer.writeAll(colors.reset);
}

fn printShortOneRow(cmd: Command, writer: anytype) !void {
    for (cmd.entries) |entry| {
        try printShortEntry(entry, cmd.opts, writer);
        try writer.writeAll("  ");
    }
    try writer.writeAll("\r\n");
}

fn printShortOnePerLine(cmd: Command, writer: anytype) !void {
    for (cmd.entries) |entry| {
        try printShortEntry(entry, cmd.opts, writer);
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

        if (cmd.opts.useIcons()) {
            const icon = Icon.get(entry, cmd.opts);

            if (cmd.opts.useColor()) {
                try writer.writeAll(icon.color);
                try writer.writeAll(icon.icon);
                try writer.writeAll(colors.reset);
            } else {
                try writer.writeAll(icon.icon);
            }

            try writer.writeByte(' ');
        }

        switch (entry.kind) {
            .directory => try writer.writeAll(colors.dir),
            .sym_link => try writer.writeAll(colors.symlink),
            else => {
                if (entry.isExecutable()) {
                    try writer.writeAll(colors.executable);
                }
            },
        }
        try writer.writeAll(entry.name);
        try writer.writeAll(colors.reset);

        if (entry.kind == .sym_link) {
            try writer.writeAll(" -> ");
            const color = if (entry.symlink_missing)
                colors.symlink_missing
            else
                colors.symlink_target;
            try writer.writeAll(color);
            try writer.writeAll(entry.link_name);
            try writer.writeAll(colors.reset);
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
    symlink_missing: bool = false,

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

    fn isExecutable(self: Entry) bool {
        return self.statx.mode & (posix.S.IXUSR | posix.S.IXGRP | posix.S.IXOTH) != 0;
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
                if (!cmd.opts.@"almost-all" and std.mem.startsWith(u8, dirent.name, ".")) continue;
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

        .stat => {
            if (result.statx) |_| {
                return;
            } else |_| {}

            const entry: *Entry = @fieldParentPtr("statx", task.req.statx.result);
            if (entry.symlink_missing) {
                // we already got here. Just zero out the statx;
                entry.statx = std.mem.zeroInit(ourio.Statx, entry.statx);
                return;
            }

            entry.symlink_missing = true;
            _ = try io.lstat(task.req.statx.path, task.req.statx.result, .{
                .cb = onCompletion,
                .ptr = cmd,
                .msg = @intFromEnum(Msg.stat),
            });
        },
    }
}

const Icon = struct {
    icon: []const u8,
    color: []const u8,

    // Entry types
    const directory: Icon = .{ .icon = "󰉋", .color = Options.Colors.blue };
    const drive: Icon = .{ .icon = "󰋊", .color = Options.Colors.blue };
    const file: Icon = .{ .icon = "󰈤", .color = Options.Colors.fg };
    const file_hidden: Icon = .{ .icon = "󰘓", .color = Options.Colors.fg };
    const pipe: Icon = .{ .icon = "󰟥", .color = Options.Colors.fg };
    const socket: Icon = .{ .icon = "󰐧", .color = Options.Colors.fg };
    const symlink: Icon = .{ .icon = "", .color = Options.Colors.fg };
    const symlink_dir: Icon = .{ .icon = "", .color = Options.Colors.blue };

    // Broad file types
    const executable: Icon = .{ .icon = "", .color = Options.Colors.green };
    const image: Icon = .{ .icon = "", .color = Options.Colors.yellow };
    const video: Icon = .{ .icon = "󰸬", .color = Options.Colors.yellow };

    // Filetypes
    const css: Icon = .{ .icon = "", .color = "\x1b[38:2:50:167:220m" };
    const go: Icon = .{ .icon = "󰟓", .color = Options.Colors.blue };
    const html: Icon = .{ .icon = "", .color = "\x1b[38:2:229:76:33m" };
    const javascript: Icon = .{ .icon = "", .color = "\x1b[38:2:233:212:77m" };
    const json: Icon = .{ .icon = "", .color = Options.Colors.blue };
    const lua: Icon = .{ .icon = "󰢱", .color = Options.Colors.blue };
    const markdown: Icon = .{ .icon = "", .color = "" };
    const python: Icon = .{ .icon = "", .color = Options.Colors.yellow };
    const typescript: Icon = .{ .icon = "", .color = Options.Colors.blue };
    const zig: Icon = .{ .icon = "", .color = "\x1b[38:2:247:164:29m" };

    const by_name: std.StaticStringMap(Icon) = .initComptime(.{});

    const by_extension: std.StaticStringMap(Icon) = .initComptime(.{
        .{ "css", Icon.css },
        .{ "gif", Icon.image },
        .{ "go", Icon.go },
        .{ "html", Icon.html },
        .{ "jpeg", Icon.image },
        .{ "jpg", Icon.image },
        .{ "js", Icon.javascript },
        .{ "json", Icon.json },
        .{ "lua", Icon.lua },
        .{ "md", Icon.markdown },
        .{ "mkv", Icon.video },
        .{ "mp4", Icon.video },
        .{ "png", Icon.image },
        .{ "py", Icon.python },
        .{ "ts", Icon.typescript },
        .{ "webp", Icon.image },
        .{ "zig", Icon.zig },
        .{ "zon", Icon.zig },
    });

    fn get(entry: Entry, opts: Options) Icon {
        // 1. By name
        // 2. By extension
        // 3. By type
        if (by_name.get(entry.name)) |icon| return icon;

        const ext = std.fs.path.extension(entry.name);
        if (ext.len > 0) {
            const ft = ext[1..];
            if (by_extension.get(ft)) |icon| return icon;
        }

        switch (entry.kind) {
            .block_device => return drive,
            .character_device => return drive,
            .directory => return directory,
            .file => {
                if (entry.isExecutable()) {
                    return executable;
                }
                return file;
            },
            .named_pipe => return pipe,
            .sym_link => {
                if (opts.long and posix.S.ISDIR(entry.statx.mode)) {
                    return symlink_dir;
                }
                return symlink;
            },
            .unix_domain_socket => return pipe,
            else => return file,
        }
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn parseArgBool(arg: []const u8) ?bool {
    if (arg.len == 0) return true;

    if (std.ascii.eqlIgnoreCase(arg, "true")) return true;
    if (std.ascii.eqlIgnoreCase(arg, "false")) return false;
    if (std.ascii.eqlIgnoreCase(arg, "1")) return true;
    if (std.ascii.eqlIgnoreCase(arg, "0")) return false;

    return null;
}

/// getWinsize gets the window size of the output. Returns null if output is not a terminal
fn getWinsize(fd: posix.fd_t) ?posix.winsize {
    var winsize: posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };

    const err = posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    switch (posix.errno(err)) {
        .SUCCESS => return winsize,
        else => return null,
    }
}

fn optKind(a: []const u8) enum { short, long, positional } {
    if (std.mem.startsWith(u8, a, "--")) return .long;
    if (std.mem.startsWith(u8, a, "-")) return .short;
    return .positional;
}
