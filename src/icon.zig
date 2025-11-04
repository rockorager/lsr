const std = @import("std");
const posix = std.posix;

const main = @import("main.zig");
const Entry = main.Entry;
const Options = main.Options;

const Icon = @This();

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
const c: Icon = .{ .icon = "󰙱", .color = "\x1b[38:2:81:154:186m" };
const cpp: Icon = .{ .icon = "󰙲", .color = "\x1b[38:2:81:154:186m" };
const css: Icon = .{ .icon = "", .color = "\x1b[38:2:50:167:220m" };
const elisp: Icon = .{ .icon = "", .color = "\x1b[38:2:127:90:182m" };
const fennel: Icon = .{ .icon = "", .color = "" }; // logo color would be light-on-light in light background
const go: Icon = .{ .icon = "󰟓", .color = Options.Colors.blue };
const html: Icon = .{ .icon = "", .color = "\x1b[38:2:229:76:33m" };
const javascript: Icon = .{ .icon = "", .color = "\x1b[38:2:233:212:77m" };
const json: Icon = .{ .icon = "", .color = Options.Colors.blue };
const lua: Icon = .{ .icon = "󰢱", .color = Options.Colors.blue };
const makefile: Icon = .{ .icon = "", .color = "\x1b[38:2:227:121:51m" };
const markdown: Icon = .{ .icon = "", .color = "" };
const nix: Icon = .{ .icon = "󱄅", .color = "\x1b[38:2:127:185:228m" };
const python: Icon = .{ .icon = "", .color = Options.Colors.yellow };
const rust: Icon = .{ .icon = "", .color = "" };
const toml: Icon = .{ .icon = "", .color = "\x1b[38:2:156:66:33m" };
const typescript: Icon = .{ .icon = "", .color = Options.Colors.blue };
const zig: Icon = .{ .icon = "", .color = "\x1b[38:2:247:164:29m" };

const by_name: std.StaticStringMap(Icon) = .initComptime(.{
    .{ "flake.lock", Icon.nix },
    .{ "go.mod", Icon.go },
    .{ "go.sum", Icon.go },
    .{ "Makefile", Icon.makefile },
    .{ "GNUMakefile", Icon.makefile },
});

const by_extension: std.StaticStringMap(Icon) = .initComptime(.{
    .{ "c", Icon.c },
    .{ "h", Icon.c },
    .{ "cc", Icon.cpp },
    .{ "cpp", Icon.cpp },
    .{ "cxx", Icon.cpp },
    .{ "hh", Icon.cpp },
    .{ "hpp", Icon.cpp },
    .{ "hxx", Icon.cpp },
    .{ "cjs", Icon.javascript },
    .{ "css", Icon.css },
    .{ "drv", Icon.nix },
    .{ "el", Icon.elisp },
    .{ "fnl", Icon.fennel },
    .{ "gif", Icon.image },
    .{ "go", Icon.go },
    .{ "html", Icon.html },
    .{ "jpeg", Icon.image },
    .{ "jpg", Icon.image },
    .{ "js", Icon.javascript },
    .{ "jsx", Icon.javascript },
    .{ "json", Icon.json },
    .{ "lua", Icon.lua },
    .{ "md", Icon.markdown },
    .{ "mjs", Icon.javascript },
    .{ "mkv", Icon.video },
    .{ "mp4", Icon.video },
    .{ "nar", Icon.nix },
    .{ "nix", Icon.nix },
    .{ "png", Icon.image },
    .{ "py", Icon.python },
    .{ "rs", Icon.rust },
    .{ "toml", Icon.toml },
    .{ "ts", Icon.typescript },
    .{ "tsx", Icon.typescript },
    .{ "webp", Icon.image },
    .{ "zig", Icon.zig },
    .{ "zon", Icon.zig },
});

pub fn get(entry: Entry) Icon {
    // 1. By name
    // 2. By type
    // 3. By extension
    if (by_name.get(entry.name)) |icon| return icon;

    switch (entry.kind) {
        .block_device => return drive,
        .character_device => return drive,
        .directory => return directory,
        .file => {
            const ext = std.fs.path.extension(entry.name);
            if (ext.len > 0) {
                const ft = ext[1..];
                if (by_extension.get(ft)) |icon| return icon;
            }

            if (entry.isExecutable()) {
                return executable;
            }
            return file;
        },
        .named_pipe => return pipe,
        .sym_link => {
            if (posix.S.ISDIR(entry.statx.mode)) {
                return symlink_dir;
            }
            return symlink;
        },
        .unix_domain_socket => return pipe,
        else => return file,
    }
}
