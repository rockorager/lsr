const std = @import("std");
const builtin = @import("builtin");
const ourio = @import("ourio");

const linux = std.os.linux;
const posix = std.posix;

const Options = struct {
    all: bool = false,
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn optKind(a: []const u8) enum { short, long, positional } {
    if (std.mem.startsWith(u8, a, "--")) return .long;
    if (std.mem.startsWith(u8, a, "-")) return .short;
    return .positional;
}

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

    var cmd: Command = .{ .arena = arena.allocator() };

    var args = std.process.args();
    while (args.next()) |arg| {
        switch (optKind(arg)) {
            .short => {
                const str = arg[1..];
                for (str) |b| {
                    switch (b) {
                        'a' => cmd.opts.all = true,
                        else => {
                            const w = std.io.getStdErr().writer();
                            try w.print("Invalid opt: '{c}'", .{b});
                            std.process.exit(1);
                        },
                    }
                }
            },
            .long => {
                const opt = arg[2..];
                if (eql(opt, "all"))
                    cmd.opts.all = true
                else {
                    const w = std.io.getStdErr().writer();
                    try w.print("Invalid opt: '{s}'", .{opt});
                    std.process.exit(1);
                }
            },
            .positional => {},
        }
    }

    var ring: ourio.Ring = try .init(arena.allocator(), 64);
    defer ring.deinit();

    _ = try ring.open(".", .{ .DIRECTORY = true, .CLOEXEC = true }, 0, .{
        .ptr = &cmd,
        .cb = onCompletion,
        .msg = @intFromEnum(Msg.cwd),
    });

    if (cmd.opts.all) {
        // We need to also open /etc/localtime and /etc/passwd
        _ = try ring.open("/etc/localtime", .{ .CLOEXEC = true }, 0, .{
            .ptr = &cmd,
            .cb = onCompletion,
            .msg = @intFromEnum(Msg.localtime),
        });
        _ = try ring.open("/etc/passwd", .{ .CLOEXEC = true }, 0, .{
            .ptr = &cmd,
            .cb = onCompletion,
            .msg = @intFromEnum(Msg.localtime),
        });
    }

    try ring.run(.until_done);

    const stdout = std.io.getStdOut();
    var bw = std.io.bufferedWriter(stdout.writer());
    for (cmd.entries) |entry| {
        try bw.writer().print("{s}\r\n", .{entry.name});
    }

    try bw.flush();
}

const Command = struct {
    arena: std.mem.Allocator,
    opts: Options = .{},
    entries: []Entry = &.{},
};

const Msg = enum(u16) {
    cwd,
    localtime,
    passwd,
    stat,
};

const Entry = struct {
    name: [:0]const u8,
    kind: std.fs.File.Kind,
    statx: ourio.Statx,

    fn lessThan(_: void, lhs: Entry, rhs: Entry) bool {
        return std.ascii.orderIgnoreCase(lhs.name, rhs.name).compare(.lt);
    }
};

fn onCompletion(io: *ourio.Ring, task: ourio.Task) anyerror!void {
    const cmd = task.userdataCast(Command);
    const msg = task.msgToEnum(Msg);
    const result = task.result.?;

    switch (msg) {
        .cwd => {
            const fd = try result.open;
            const dir: std.fs.Dir = .{ .fd = fd };

            var results: std.ArrayListUnmanaged(Entry) = .empty;

            var iter = dir.iterate();
            while (try iter.next()) |dirent| {
                const nameZ = try cmd.arena.dupeZ(u8, dirent.name);
                try results.append(cmd.arena, .{
                    .name = nameZ,
                    .kind = dirent.kind,
                    .statx = undefined,
                });
            }
            cmd.entries = results.items;
            // best effort close
            _ = try io.close(fd, .{});

            for (cmd.entries) |*entry| {
                _ = try io.stat(entry.name, &entry.statx, .{
                    .cb = onCompletion,
                    .ptr = cmd,
                    .msg = @intFromEnum(Msg.stat),
                });
            }
        },

        else => {},
    }
}
