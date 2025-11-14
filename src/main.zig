const std = @import("std");
const builtin = @import("builtin");
const ourio = @import("ourio");
const zeit = @import("zeit");
const natord = @import("natord.zig");
const Icon = @import("icon.zig");
const build_options = @import("build_options");

const posix = std.posix;

const usage =
    \\Usage: 
    \\  lsr [options] [path...]
    \\
    \\  --help                           Print this message and exit
    \\  --version                        Print the version string
    \\
    \\DISPLAY OPTIONS
    \\  -1, --oneline                    Print entries one per line
    \\  -a, --all                        Show files that start with a dot (ASCII 0x2E)
    \\  -A, --almost-all                 Like --all, but skips implicit "." and ".." directories
    \\  -C, --columns                    Print the output in columns
    \\      --color=WHEN                 When to use colors (always, auto, never)
    \\      --group-directories-first    Print all directories before printing regular files
    \\      --hyperlinks=WHEN            When to use OSC 8 hyperlinks (always, auto, never)
    \\      --icons=WHEN                 When to display icons (always, auto, never)
    \\  -l, --long                       Display extended file metadata
    \\  -r, --reverse                    Reverse the sort order
    \\  -t, --time                       Sort the entries by modification time, most recent first
    \\      --tree[=DEPTH]               Display entries in a tree format (optional limit depth)
    \\
;

const queue_size = 256;

pub const Options = struct {
    all: bool = false,
    @"almost-all": bool = false,
    color: When = .auto,
    shortview: enum { columns, oneline } = .oneline,
    @"group-directories-first": bool = true,
    hyperlinks: When = .auto,
    icons: When = .auto,
    long: bool = false,
    sort_by_mod_time: bool = false,
    reverse_sort: bool = false,
    tree: bool = false,
    tree_depth: ?usize = null,

    directories: std.ArrayListUnmanaged([:0]const u8) = .empty,
    file: ?[]const u8 = null,

    winsize: ?posix.winsize = null,
    colors: Colors = .none,

    const When = enum {
        never,
        auto,
        always,
    };

    pub const Colors = struct {
        reset: []const u8,
        dir: []const u8,
        executable: []const u8,
        symlink: []const u8,
        symlink_target: []const u8,
        symlink_missing: []const u8,

        pub const none: Colors = .{
            .reset = "",
            .dir = "",
            .executable = "",
            .symlink = "",
            .symlink_target = "",
            .symlink_missing = "",
        };

        pub const default: Colors = .{
            .reset = _reset,
            .dir = bold ++ blue,
            .executable = bold ++ green,
            .symlink = bold ++ purple,
            .symlink_target = bold ++ cyan,
            .symlink_missing = bold ++ red,
        };

        pub const _reset = "\x1b[m";
        pub const red = "\x1b[31m";
        pub const green = "\x1b[32m";
        pub const yellow = "\x1b[33m";
        pub const blue = "\x1b[34m";
        pub const purple = "\x1b[35m";
        pub const cyan = "\x1b[36m";
        pub const fg = "\x1b[37m";

        pub const bold = "\x1b[1m";
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

    fn useHyperlinks(self: Options) bool {
        switch (self.hyperlinks) {
            .never => return false,
            .always => return true,
            .auto => return self.isatty(),
        }
    }

    fn showDotfiles(self: Options) bool {
        return self.@"almost-all" or self.all;
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

    cmd.opts.winsize = getWinsize(std.fs.File.stdout().handle);

    cmd.opts.shortview = if (cmd.opts.isatty()) .columns else .oneline;

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    var stdout = &stdout_writer.interface;
    var stderr = &stderr_writer.interface;

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
                        'h' => {}, // human-readable: present for compatibility
                        'l' => cmd.opts.long = true,
                        'r' => cmd.opts.reverse_sort = true,
                        't' => cmd.opts.sort_by_mod_time = true,
                        else => {
                            try stderr.print("Invalid opt: '{c}'\n", .{b});
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
                        try stderr.print("Invalid boolean: '{s}'\n", .{val});
                        std.process.exit(1);
                    };
                } else if (eql(opt, "long")) {
                    cmd.opts.long = parseArgBool(val) orelse {
                        try stderr.print("Invalid boolean: '{s}'\n", .{val});
                        std.process.exit(1);
                    };
                } else if (eql(opt, "almost-all")) {
                    cmd.opts.@"almost-all" = parseArgBool(val) orelse {
                        try stderr.print("Invalid boolean: '{s}'\n", .{val});
                        std.process.exit(1);
                    };
                } else if (eql(opt, "group-directories-first")) {
                    cmd.opts.@"group-directories-first" = parseArgBool(val) orelse {
                        try stderr.print("Invalid boolean: '{s}'\n", .{val});
                        std.process.exit(1);
                    };
                } else if (eql(opt, "color")) {
                    cmd.opts.color = std.meta.stringToEnum(Options.When, val) orelse {
                        try stderr.print("Invalid color option: '{s}'\n", .{val});
                        std.process.exit(1);
                    };
                } else if (eql(opt, "human-readable")) {
                    // no-op: present for compatibility
                } else if (eql(opt, "hyperlinks")) {
                    cmd.opts.hyperlinks = std.meta.stringToEnum(Options.When, val) orelse {
                        try stderr.print("Invalid hyperlinks option: '{s}'\n", .{val});
                        std.process.exit(1);
                    };
                } else if (eql(opt, "icons")) {
                    cmd.opts.icons = std.meta.stringToEnum(Options.When, val) orelse {
                        try stderr.print("Invalid color option: '{s}'\n", .{val});
                        std.process.exit(1);
                    };
                } else if (eql(opt, "columns")) {
                    const c = parseArgBool(val) orelse {
                        try stderr.print("Invalid columns option: '{s}'\n", .{val});
                        std.process.exit(1);
                    };
                    cmd.opts.shortview = if (c) .columns else .oneline;
                } else if (eql(opt, "oneline")) {
                    const o = parseArgBool(val) orelse {
                        try stderr.print("Invalid oneline option: '{s}'\n", .{val});
                        std.process.exit(1);
                    };
                    cmd.opts.shortview = if (o) .oneline else .columns;
                } else if (eql(opt, "time")) {
                    cmd.opts.sort_by_mod_time = parseArgBool(val) orelse {
                        try stderr.print("Invalid boolean: '{s}'\n", .{val});
                        std.process.exit(1);
                    };
                } else if (eql(opt, "reverse")) {
                    cmd.opts.reverse_sort = parseArgBool(val) orelse {
                        try stderr.print("Invalid boolean: '{s}'\n", .{val});
                        std.process.exit(1);
                    };
                } else if (eql(opt, "tree")) {
                    if (val.len == 0) {
                        cmd.opts.tree = true;
                        cmd.opts.tree_depth = null; // unlimited depth
                    } else {
                        cmd.opts.tree = true;
                        cmd.opts.tree_depth = std.fmt.parseInt(usize, val, 10) catch {
                            try stderr.print("Invalid tree depth: '{s}'\n", .{val});
                            std.process.exit(1);
                        };
                    }
                } else if (eql(opt, "help")) {
                    try stdout.writeAll(usage);
                    try stdout.flush();
                    return;
                } else if (eql(opt, "version")) {
                    try stdout.print("lsr {s}\r\n", .{build_options.version});
                    try stdout.flush();
                    return;
                } else {
                    try stderr.print("Invalid opt: '{s}'\n", .{opt});
                    std.process.exit(1);
                }
            },
            .positional => {
                try cmd.opts.directories.append(allocator, arg);
            },
        }
    }

    if (cmd.opts.useColor()) {
        cmd.opts.colors = .default;
    }

    if (cmd.opts.directories.items.len == 0) {
        try cmd.opts.directories.append(allocator, ".");
    }

    const multiple_dirs = cmd.opts.directories.items.len > 1;

    for (cmd.opts.directories.items, 0..) |directory, dir_idx| {
        cmd.entries = &.{};
        cmd.entry_idx = 0;
        cmd.symlinks.clearRetainingCapacity();
        cmd.groups.clearRetainingCapacity();
        cmd.users.clearRetainingCapacity();
        cmd.tz = null;
        cmd.opts.file = null;
        cmd.current_directory = directory;

        var ring: ourio.Ring = try .init(allocator, queue_size);
        defer ring.deinit();

        _ = try ring.open(directory, .{ .DIRECTORY = true, .CLOEXEC = true }, 0, .{
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

        if (cmd.entries.len == 0) {
            if (multiple_dirs and dir_idx < cmd.opts.directories.items.len - 1) {
                try stdout.writeAll("\r\n");
            }
            continue;
        }

        std.sort.pdq(Entry, cmd.entries, cmd.opts, Entry.lessThan);

        if (cmd.opts.reverse_sort) {
            std.mem.reverse(Entry, cmd.entries);
        }

        if (multiple_dirs and !cmd.opts.tree) {
            if (dir_idx > 0) try stdout.writeAll("\r\n");
            try stdout.print("{s}:\r\n", .{directory});
        }

        if (cmd.opts.tree) {
            if (multiple_dirs and dir_idx > 0) try stdout.writeAll("\r\n");
            try printTree(cmd, stdout);
        } else if (cmd.opts.long) {
            try printLong(&cmd, stdout);
        } else switch (cmd.opts.shortview) {
            .columns => try printShortColumns(cmd, stdout),
            .oneline => try printShortOnePerLine(cmd, stdout),
        }
    }
    try stdout.flush();
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
            try printShortEntry(column.entries[row], cmd, writer);

            if (i < columns.items.len - 1) {
                const spaces = column.width - (icon_width + entry.name.len);
                var space_buf = [_][]const u8{" "};
                try writer.writeSplatAll(&space_buf, spaces);
            }
        }
        try writer.writeAll("\r\n");
    }
}

fn isShortColumn(idx: usize, n_cols: usize, n_short_cols: usize) bool {
    return idx + n_short_cols >= n_cols;
}

fn printShortEntry(entry: Entry, cmd: Command, writer: anytype) !void {
    const opts = cmd.opts;
    const colors = opts.colors;
    if (opts.useIcons()) {
        const icon = Icon.get(entry);

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

    if (opts.useHyperlinks()) {
        const path = try std.fs.path.join(cmd.arena, &.{ cmd.current_directory, entry.name });
        try writer.print("\x1b]8;;file://{s}\x1b\\", .{path});
        try writer.writeAll(entry.name);
        try writer.writeAll("\x1b]8;;\x1b\\");
        try writer.writeAll(colors.reset);
    } else {
        try writer.writeAll(entry.name);
        try writer.writeAll(colors.reset);
    }
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
        try printShortEntry(entry, cmd, writer);
        try writer.writeAll("\r\n");
    }
}

fn drawTreePrefix(writer: anytype, prefix_list: []const bool, is_last: bool) !void {
    for (prefix_list) |is_last_at_level| {
        if (is_last_at_level) {
            try writer.writeAll("    ");
        } else {
            try writer.writeAll("│   ");
        }
    }

    if (is_last) {
        try writer.writeAll("└── ");
    } else {
        try writer.writeAll("├── ");
    }
}

fn printTree(cmd: Command, writer: anytype) !void {
    const dir_name = if (std.mem.eql(u8, cmd.current_directory, ".")) blk: {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = try std.process.getCwd(&buf);
        break :blk std.fs.path.basename(cwd);
    } else std.fs.path.basename(cmd.current_directory);

    try writer.print("{s}\n", .{dir_name});

    const max_depth = cmd.opts.tree_depth orelse std.math.maxInt(usize);
    var prefix_list: std.ArrayList(bool) = .{};

    for (cmd.entries, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        const is_last = i == cmd.entries.len - 1;

        try drawTreePrefix(writer, prefix_list.items, is_last);
        try printShortEntry(entry, cmd, writer);
        try writer.writeAll("\r\n");

        if (entry.kind == .directory and max_depth > 0) {
            const full_path = try std.fs.path.joinZ(cmd.arena, &.{ cmd.current_directory, entry.name });

            try prefix_list.append(cmd.arena, is_last);
            try recurseTree(cmd, writer, full_path, &prefix_list, 1, max_depth);

            _ = prefix_list.pop();
        }
    }
}

fn recurseTree(cmd: Command, writer: anytype, dir_path: [:0]const u8, prefix_list: *std.ArrayList(bool), depth: usize, max_depth: usize) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        return;
    };
    defer dir.close();

    var entries: std.ArrayList(Entry) = .{};
    var iter = dir.iterate();

    while (try iter.next()) |dirent| {
        if (!cmd.opts.showDotfiles() and std.mem.startsWith(u8, dirent.name, ".")) continue;

        const nameZ = try cmd.arena.dupeZ(u8, dirent.name);
        try entries.append(cmd.arena, .{
            .name = nameZ,
            .kind = dirent.kind,
            .statx = undefined,
        });
    }

    std.sort.pdq(Entry, entries.items, cmd.opts, Entry.lessThan);

    if (cmd.opts.reverse_sort) {
        std.mem.reverse(Entry, entries.items);
    }

    for (entries.items, 0..) |entry, i| {
        const is_last = i == entries.items.len - 1;

        try drawTreePrefix(writer, prefix_list.items, is_last);
        try printTreeEntry(entry, cmd, writer, dir_path);
        try writer.writeAll("\r\n");

        if (entry.kind == .directory and depth < max_depth) {
            const full_path = try std.fs.path.joinZ(cmd.arena, &.{ dir_path, entry.name });

            try prefix_list.append(cmd.arena, is_last);
            try recurseTree(cmd, writer, full_path, prefix_list, depth + 1, max_depth);

            _ = prefix_list.pop();
        }
    }
}

fn printTreeEntry(entry: Entry, cmd: Command, writer: anytype, dir_path: [:0]const u8) !void {
    const opts = cmd.opts;
    const colors = opts.colors;

    if (opts.useIcons()) {
        const icon = Icon.get(entry);

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
            const full_path = try std.fs.path.join(cmd.arena, &.{ dir_path, entry.name });
            const stat_result = std.fs.cwd().statFile(full_path) catch null;
            if (stat_result) |stat| {
                if (stat.mode & (std.posix.S.IXUSR | std.posix.S.IXGRP | std.posix.S.IXOTH) != 0) {
                    try writer.writeAll(colors.executable);
                }
            }
        },
    }

    if (opts.useHyperlinks()) {
        const path = try std.fs.path.join(cmd.arena, &.{ dir_path, entry.name });
        try writer.print("\x1b]8;;file://{s}\x1b\\", .{path});
        try writer.writeAll(entry.name);
        try writer.writeAll("\x1b]8;;\x1b\\");
        try writer.writeAll(colors.reset);
    } else {
        try writer.writeAll(entry.name);
        try writer.writeAll(colors.reset);
    }
}

fn printLong(cmd: *Command, writer: anytype) !void {
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
            const group = try cmd.getGroup(entry.statx.gid);
            const user = try cmd.getUser(entry.statx.uid);

            var buf: [16]u8 = undefined;
            const size = try entry.humanReadableSize(&buf);
            const group_len: usize = if (group) |g| g.name.len else switch (entry.statx.gid) {
                0...9 => 1,
                10...99 => 2,
                100...999 => 3,
                1000...9999 => 4,
                10000...99999 => 5,
                else => 6,
            };

            const user_len: usize = if (user) |u| u.name.len else switch (entry.statx.uid) {
                0...9 => 1,
                10...99 => 2,
                100...999 => 3,
                1000...9999 => 4,
                10000...99999 => 5,
                else => 6,
            };

            n_group = @max(n_group, group_len);
            n_user = @max(n_user, user_len);
            n_size = @max(n_size, size.len);
            n_suff = @max(n_suff, entry.humanReadableSuffix().len);
        }
        break :blk .{ n_group, n_user, n_size, n_suff };
    };

    for (cmd.entries) |entry| {
        const user: User = try cmd.getUser(entry.statx.uid) orelse
            .{
                .uid = entry.statx.uid,
                .name = try std.fmt.allocPrint(cmd.arena, "{d}", .{entry.statx.uid}),
            };
        const group: Group = try cmd.getGroup(entry.statx.gid) orelse
            .{
                .gid = entry.statx.gid,
                .name = try std.fmt.allocPrint(cmd.arena, "{d}", .{entry.statx.gid}),
            };
        const ts = @as(i128, entry.statx.mtime.sec) * std.time.ns_per_s;
        const inst: zeit.Instant = .{ .timestamp = ts, .timezone = &tz };
        const time = inst.time();

        const mode = entry.modeStr();

        try writer.writeAll(&mode);
        try writer.writeByte(' ');
        try writer.writeAll(user.name);
        var space_buf1 = [_][]const u8{" "};
        try writer.writeSplatAll(&space_buf1, longest_user - user.name.len);
        try writer.writeByte(' ');
        try writer.writeAll(group.name);
        var space_buf2 = [_][]const u8{" "};
        try writer.writeSplatAll(&space_buf2, longest_group - group.name.len);
        try writer.writeByte(' ');

        var size_buf: [16]u8 = undefined;
        const size = try entry.humanReadableSize(&size_buf);
        const suffix = entry.humanReadableSuffix();

        var space_buf3 = [_][]const u8{" "};
        try writer.writeSplatAll(&space_buf3, longest_size - size.len);
        try writer.writeAll(size);
        try writer.writeByte(' ');
        try writer.writeAll(suffix);
        var space_buf4 = [_][]const u8{" "};
        try writer.writeSplatAll(&space_buf4, longest_suffix - suffix.len);
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
            const icon = Icon.get(entry);

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

        if (cmd.opts.useHyperlinks()) {
            const path = try std.fs.path.join(cmd.arena, &.{ cmd.current_directory, entry.name });
            try writer.print("\x1b]8;;file://{s}\x1b\\", .{path});
            try writer.writeAll(entry.name);
            try writer.writeAll("\x1b]8;;\x1b\\");
        } else {
            try writer.writeAll(entry.name);
        }
        try writer.writeAll(colors.reset);

        switch (entry.kind) {
            .sym_link => {
                try writer.writeAll(" -> ");

                const symlink: Symlink = cmd.symlinks.get(entry.name) orelse .{
                    .name = "[missing]",
                    .exists = false,
                };

                const color = if (symlink.exists) colors.symlink_target else colors.symlink_missing;

                try writer.writeAll(color);
                if (cmd.opts.useHyperlinks() and symlink.exists) {
                    try writer.print("\x1b]8;;file://{s}\x1b\\", .{symlink.name});
                    try writer.writeAll(symlink.name);
                    try writer.writeAll("\x1b]8;;\x1b\\");
                } else {
                    try writer.writeAll(symlink.name);
                }
                try writer.writeAll(colors.reset);
            },

            else => {},
        }

        try writer.writeAll("\r\n");
    }
}

const Command = struct {
    arena: std.mem.Allocator,
    opts: Options = .{},
    entries: []Entry = &.{},
    entry_idx: usize = 0,
    symlinks: std.StringHashMapUnmanaged(Symlink) = .empty,
    current_directory: [:0]const u8 = ".",

    tz: ?zeit.TimeZone = null,
    groups: std.ArrayListUnmanaged(Group) = .empty,
    users: std.ArrayListUnmanaged(User) = .empty,

    fn getUser(self: *Command, uid: posix.uid_t) !?User {
        for (self.users.items) |user| {
            if (user.uid == uid) return user;
        }
        if (std.c.getpwuid(uid)) |user| {
            if (user.name) |name| {
                const new_user = User{
                    .uid = uid,
                    .name = std.mem.span(name),
                };
                try self.users.append(self.arena, new_user);
                return new_user;
            }
        }
        return null;
    }

    fn getGroup(self: *Command, gid: posix.gid_t) !?Group {
        for (self.groups.items) |group| {
            if (group.gid == gid) return group;
        }
        if (std.c.getgrgid(gid)) |group| {
            if (group.name) |name| {
                const new_group = Group{
                    .gid = gid,
                    .name = std.mem.span(name),
                };
                try self.groups.append(self.arena, new_group);
                return new_group;
            }
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
    uid: if (builtin.os.tag == .macos) i33 else posix.uid_t,
    name: []const u8,

    fn lessThan(_: void, lhs: User, rhs: User) bool {
        return lhs.uid < rhs.uid;
    }
};

const Group = struct {
    gid: if (builtin.os.tag == .macos) i33 else posix.gid_t,
    name: []const u8,

    fn lessThan(_: void, lhs: Group, rhs: Group) bool {
        return lhs.gid < rhs.gid;
    }
};

const MinimalEntry = struct {
    name: [:0]const u8,
    kind: std.fs.File.Kind,

    fn lessThan(opts: Options, lhs: MinimalEntry, rhs: MinimalEntry) bool {
        if (opts.@"group-directories-first" and
            lhs.kind != rhs.kind and
            (lhs.kind == .directory or rhs.kind == .directory))
        {
            return lhs.kind == .directory;
        }

        return std.ascii.lessThanIgnoreCase(lhs.name, rhs.name);
    }
};

const Symlink = struct {
    name: [:0]const u8,
    exists: bool = true,
};

pub const Entry = struct {
    name: [:0]const u8,
    kind: std.fs.File.Kind,
    statx: ourio.Statx,

    fn lessThan(opts: Options, lhs: Entry, rhs: Entry) bool {
        if (opts.@"group-directories-first" and
            lhs.kind != rhs.kind and
            (lhs.kind == .directory or rhs.kind == .directory))
        {
            return lhs.kind == .directory;
        }

        if (opts.sort_by_mod_time) {
            if (lhs.statx.mtime.sec == rhs.statx.mtime.sec) {
                return lhs.statx.mtime.nsec > rhs.statx.mtime.nsec;
            }
            return lhs.statx.mtime.sec > rhs.statx.mtime.sec;
        }

        return natord.orderIgnoreCase(lhs.name, rhs.name) == .lt;
    }

    fn modeStr(self: Entry) [10]u8 {
        var mode = [_]u8{'-'} ** 10;
        switch (self.kind) {
            .block_device => mode[0] = 'b',
            .character_device => mode[0] = 'c',
            .directory => mode[0] = 'd',
            .named_pipe => mode[0] = 'p',
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

    pub fn isExecutable(self: Entry) bool {
        return self.statx.mode & (posix.S.IXUSR | posix.S.IXGRP | posix.S.IXOTH) != 0;
    }
};

fn onCompletion(io: *ourio.Ring, task: ourio.Task) anyerror!void {
    const cmd = task.userdataCast(Command);
    const msg = task.msgToEnum(Msg);
    const result = task.result.?;

    switch (msg) {
        .cwd => {
            const fd = result.open catch |err| {
                switch (err) {
                    error.NotDir => {
                        // Guard against infinite recursion
                        if (cmd.opts.file != null) return err;

                        // if the user specified a file (or something that couldn't be opened as a
                        // directory), then we open it's parent and apply a filter
                        const dirname = std.fs.path.dirname(cmd.current_directory) orelse ".";
                        cmd.opts.file = std.fs.path.basename(cmd.current_directory);
                        cmd.current_directory = try cmd.arena.dupeZ(u8, dirname);
                        _ = try io.open(
                            cmd.current_directory,
                            .{ .DIRECTORY = true, .CLOEXEC = true },
                            0,
                            .{
                                .ptr = cmd,
                                .cb = onCompletion,
                                .msg = @intFromEnum(Msg.cwd),
                            },
                        );
                        return;
                    },
                    else => return err,
                }
            };
            // we are async, no need to defer!
            _ = try io.close(fd, .{});
            const dir: std.fs.Dir = .{ .fd = fd };

            if (cmd.opts.useHyperlinks()) {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const cwd = try std.os.getFdPath(fd, &buf);
                cmd.current_directory = try cmd.arena.dupeZ(u8, cwd);
            }

            var temp_results: std.ArrayListUnmanaged(MinimalEntry) = .empty;

            // Preallocate some memory
            try temp_results.ensureUnusedCapacity(cmd.arena, queue_size);

            // zig skips "." and "..", so we manually add them if needed
            if (cmd.opts.all) {
                temp_results.appendAssumeCapacity(.{
                    .name = ".",
                    .kind = .directory,
                });
                temp_results.appendAssumeCapacity(.{
                    .name = "..",
                    .kind = .directory,
                });
            }

            var iter = dir.iterate();
            while (try iter.next()) |dirent| {
                if (!cmd.opts.showDotfiles() and std.mem.startsWith(u8, dirent.name, ".")) continue;
                if (cmd.opts.file) |file| {
                    if (eql(file, dirent.name)) {
                        const nameZ = try cmd.arena.dupeZ(u8, dirent.name);
                        try temp_results.append(cmd.arena, .{
                            .name = nameZ,
                            .kind = dirent.kind,
                        });
                    }
                    continue;
                }
                const nameZ = try cmd.arena.dupeZ(u8, dirent.name);
                try temp_results.append(cmd.arena, .{
                    .name = nameZ,
                    .kind = dirent.kind,
                });
            }

            // sort the entries on the minimal struct. This has better memory locality since it is
            // much smaller than bringing in the ourio.Statx struct
            std.sort.pdq(MinimalEntry, temp_results.items, cmd.opts, MinimalEntry.lessThan);

            var results: std.ArrayListUnmanaged(Entry) = .empty;
            try results.ensureUnusedCapacity(cmd.arena, temp_results.items.len);
            for (temp_results.items) |tmp| {
                results.appendAssumeCapacity(.{
                    .name = tmp.name,
                    .kind = tmp.kind,
                    .statx = undefined,
                });
            }
            cmd.entries = results.items;

            for (cmd.entries, 0..) |*entry, i| {
                if (i >= queue_size) {
                    cmd.entry_idx = i;
                    break;
                }
                const path = try std.fs.path.joinZ(
                    cmd.arena,
                    &.{ cmd.current_directory, entry.name },
                );

                if (entry.kind == .sym_link) {
                    var buf: [std.fs.max_path_bytes]u8 = undefined;

                    // NOTE: Sadly, we can't do readlink via io_uring
                    const link = try posix.readlink(path, &buf);
                    const symlink: Symlink = .{ .name = try cmd.arena.dupeZ(u8, link) };
                    try cmd.symlinks.put(cmd.arena, entry.name, symlink);
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
            _ = try io.read(fd, buffer, .file, .{
                .cb = onCompletion,
                .ptr = cmd,
                .msg = @intFromEnum(Msg.read_localtime),
            });
        },

        .read_localtime => {
            const n = try result.read;
            _ = try io.close(task.req.read.fd, .{});
            const bytes = task.req.read.buffer[0..n];
            var reader = std.Io.Reader.fixed(bytes);
            const tz = try zeit.timezone.TZInfo.parse(cmd.arena, &reader);
            cmd.tz = .{ .tzinfo = tz };
        },

        .passwd => {
            const fd = try result.open;

            // TODO: stat this or do multiple reads. We'll never know a good bound unless we go
            // really big
            const buffer = try cmd.arena.alloc(u8, 8192 * 2);
            _ = try io.read(fd, buffer, .file, .{
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
                if (std.mem.startsWith(u8, line, "#")) continue;

                var iter = std.mem.splitScalar(u8, line, ':');
                const name = iter.first();
                _ = iter.next();
                const uid = iter.next().?;

                const user: User = .{
                    .name = name,
                    .uid = try std.fmt.parseInt(
                        if (builtin.os.tag == .macos) i33 else u32,
                        uid,
                        10,
                    ),
                };

                cmd.users.appendAssumeCapacity(user);
            }
            std.sort.pdq(User, cmd.users.items, {}, User.lessThan);
        },

        .group => {
            const fd = try result.open;

            const buffer = try cmd.arena.alloc(u8, 8192);
            _ = try io.read(fd, buffer, .file, .{
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
                if (std.mem.startsWith(u8, line, "#")) continue;

                var iter = std.mem.splitScalar(u8, line, ':');
                const name = iter.first();
                _ = iter.next();
                const gid = iter.next().?;

                const group: Group = .{
                    .name = name,
                    .gid = try std.fmt.parseInt(
                        if (builtin.os.tag == .macos) i33 else u32,
                        gid,
                        10,
                    ),
                };

                cmd.groups.appendAssumeCapacity(group);
            }
            std.sort.pdq(Group, cmd.groups.items, {}, Group.lessThan);
        },

        .stat => {
            _ = result.statx catch |err| {
                const entry: *Entry = @fieldParentPtr("statx", task.req.statx.result);
                const symlink = cmd.symlinks.getPtr(entry.name) orelse return err;

                if (!symlink.exists) {
                    // We already lstated this and found an error. Just zero out statx and move
                    // along
                    entry.statx = std.mem.zeroInit(ourio.Statx, entry.statx);
                    return;
                }

                symlink.exists = false;

                _ = try io.lstat(task.req.statx.path, task.req.statx.result, .{
                    .cb = onCompletion,
                    .ptr = cmd,
                    .msg = @intFromEnum(Msg.stat),
                });
                return;
            };

            if (cmd.entry_idx >= cmd.entries.len) return;

            const entry = &cmd.entries[cmd.entry_idx];
            cmd.entry_idx += 1;
            const path = try std.fs.path.joinZ(
                cmd.arena,
                &.{ cmd.current_directory, entry.name },
            );

            if (entry.kind == .sym_link) {
                var buf: [std.fs.max_path_bytes]u8 = undefined;

                // NOTE: Sadly, we can't do readlink via io_uring
                const link = try posix.readlink(path, &buf);
                const symlink: Symlink = .{ .name = try cmd.arena.dupeZ(u8, link) };
                try cmd.symlinks.put(cmd.arena, entry.name, symlink);
            }
            _ = try io.stat(path, &entry.statx, .{
                .cb = onCompletion,
                .ptr = cmd,
                .msg = @intFromEnum(Msg.stat),
            });
        },
    }
}

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

test "ref" {
    _ = natord;
}
