const std = @import("std");
const zzdoc = @import("zzdoc");

/// Must be kept in sync with git tags
const version: std.SemanticVersion = .{ .major = 1, .minor = 0, .patch = 0 };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // manpages
    {
        var man_step = zzdoc.addManpageStep(b, .{
            .root_doc_dir = b.path("docs/"),
        });

        const install_step = man_step.addInstallStep(.{});
        b.default_step.dependOn(&install_step.step);
    }

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const io_dep = b.dependency("ourio", .{ .optimize = optimize, .target = target });
    const io_mod = io_dep.module("ourio");
    exe_mod.addImport("ourio", io_mod);

    const zeit_dep = b.dependency("zeit", .{ .optimize = optimize, .target = target });
    const zeit_mod = zeit_dep.module("zeit");
    exe_mod.addImport("zeit", zeit_mod);

    const opts = b.addOptions();
    const version_string = genVersion(b) catch |err| {
        std.debug.print("{}", .{err});
        @compileError("couldn't get version");
    };
    opts.addOption([]const u8, "version", version_string);

    exe_mod.addOptions("build_options", opts);

    const exe = b.addExecutable(.{
        .name = "lsr",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

fn genVersion(b: *std.Build) ![]const u8 {
    if (!std.process.can_spawn) {
        std.debug.print("error: version info cannot be retrieved from git. Zig version must be provided using -Dversion-string\n", .{});
        std.process.exit(1);
    }
    const version_string = b.fmt("v{d}.{d}.{d}", .{ version.major, version.minor, version.patch });

    var code: u8 = undefined;
    const git_describe_untrimmed = b.runAllowFail(&[_][]const u8{
        "git",
        "-C",
        b.build_root.path orelse ".",
        "describe",
        "--match",
        "*.*.*",
        "--tags",
        "--abbrev=9",
    }, &code, .Ignore) catch {
        return version_string;
    };
    if (!std.mem.startsWith(u8, git_describe_untrimmed, version_string)) {
        std.debug.print("error: tagged version does not match internal version\n", .{});
        std.process.exit(1);
    }
    return std.mem.trim(u8, git_describe_untrimmed, " \n\r");
}
