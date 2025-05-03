const std = @import("std");
const builtin = @import("builtin");
const io = @import("ourio");

const linux = std.os.linux;

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

    var ring: io.Ring = try .init(arena.allocator(), 64);
    defer ring.deinit();

    // TODO: implement openat in ourio
    var cwd = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer cwd.close();

    var results: std.ArrayListUnmanaged(*Entry) = .empty;

    var iter = cwd.iterate();
    while (try iter.next()) |dirent| {
        const nameZ = try arena.allocator().dupeZ(u8, dirent.name);
        const entry = try arena.allocator().create(Entry);
        entry.* = .{ .name = nameZ, .kind = dirent.kind, .statx = undefined };
        try results.append(arena.allocator(), entry);
        _ = try ring.stat(nameZ, &entry.statx, .{ .cb = onCompletion });
    }

    try ring.run(.until_done);

    var output: std.ArrayListUnmanaged(u8) = .empty;
    var writer = output.writer(arena.allocator());
    for (results.items) |entry| {
        try writer.print("{s}\r\n", .{entry.name});
    }

    try std.io.getStdOut().writeAll(output.items);
}

const Entry = struct {
    name: [:0]const u8,
    kind: std.fs.File.Kind,
    statx: io.Statx,

    fn lessThan(_: void, lhs: *Entry, rhs: *Entry) bool {
        return std.ascii.orderIgnoreCase(lhs.name, rhs.name).compare(.lt);
    }
};

fn onCompletion(_: *io.Ring, task: io.Task) anyerror!void {
    const result = task.result.?;

    _ = result.statx catch |err| {
        std.log.err("stat error: {}", .{err});
        return;
    };
}
