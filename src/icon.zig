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
// Format: "\x1b[38;2;R;G;Bm"
const c: Icon = .{ .icon = "", .color = "\x1b[38;2;168;185;204m" }; // #A8B9CC
const clj: Icon = .{ .icon = "", .color = "\x1b[38;2;88;129;216m" }; // #5881D8
const cpp: Icon = .{ .icon = "", .color = "\x1b[38;2;0;89;156m" }; // #00599C
const cs: Icon = .{ .icon = "󰌛", .color = "\x1b[38;2;35;145;32m" }; // #239120
const css: Icon = .{ .icon = "", .color = "\x1b[38;2;21;114;182m" }; // #1572B6
const dart: Icon = .{ .icon = "", .color = "\x1b[38;2;1;117;194m" }; // #0175C2
const elisp: Icon = .{ .icon = "", .color = "\x1b[38:2:127:90:182m" }; // #7f5ab6
const erl: Icon = .{ .icon = "", .color = "\x1b[38;2;169;5;51m" }; // #A90533
const ex: Icon = .{ .icon = "", .color = "\x1b[38;2;110;74;126m" }; // #6E4A7E
const fennel: Icon = .{ .icon = "", .color = "" }; // logo color would be light-on-light in light background
const git: Icon = .{ .icon = "󰊢", .color = Options.Colors.fg };
const go: Icon = .{ .icon = "󰟓", .color = "\x1b[38;2;0;173;216m" }; // #00ADD8
const hs: Icon = .{ .icon = "", .color = "\x1b[38;2;93;79;133m" }; // #5D4F85
const html: Icon = .{ .icon = "", .color = "\x1b[38;2;227;79;38m" }; // #E34F26
const java: Icon = .{ .icon = "", .color = "\x1b[38;2;0;115;150m" }; // #007396
const javascript: Icon = .{ .icon = "", .color = "\x1b[38;2;0;187;0m" }; // #00BB00
const json: Icon = .{ .icon = "", .color = Options.Colors.blue };
const kt: Icon = .{ .icon = "", .color = "\x1b[38;2;127;82;255m" }; // #7F52FF
const lua: Icon = .{ .icon = "󰢱", .color = "\x1b[38;2;44;45;114m" }; // #2C2D72
const makefile: Icon = .{ .icon = "", .color = "\x1b[38;2;227;121;51m" }; // existing makefile
const markdown: Icon = .{ .icon = "", .color = Options.Colors.fg };
const nix: Icon = .{ .icon = "󱄅", .color = "\x1b[38;2;127;185;228m" };
const php: Icon = .{ .icon = "", .color = "\x1b[38;2;119;123;180m" }; // #777BB4
const pl: Icon = .{ .icon = "", .color = "\x1b[38;2;57;69;126m" }; // #39457E
const python: Icon = .{ .icon = "", .color = "\x1b[38;2;55;118;171m" }; // #3776AB
const rb: Icon = .{ .icon = "", .color = "\x1b[38;2;204;52;45m" }; // #CC342D
const rlang: Icon = .{ .icon = "", .color = "\x1b[38;2;39;109;195m" }; // #276DC3
const root: Icon = .{ .icon = "󰦣", .color = "\x1b[38;2;23;214;240m" }; // #17D6F0
const rust: Icon = .{ .icon = "", .color = "\x1b[38;2;187;28;37m" }; // rs -> #BB1C25
const scala: Icon = .{ .icon = "", .color = "\x1b[38;2;220;50;47m" }; // #DC322F
const sh: Icon = .{ .icon = "", .color = "\x1b[38;2;137;224;81m" }; // #89E051
const sql: Icon = .{ .icon = "", .color = "\x1b[38;2;204;41;39m" }; // #CC2927
const swift: Icon = .{ .icon = "", .color = "\x1b[38;2;240;81;56m" }; // #F05138
const toml: Icon = .{ .icon = "", .color = "\x1b[38;2;156;66;33m" }; // existing toml color
const typescript: Icon = .{ .icon = "", .color = "\x1b[38;2;49;120;198m" }; // #3178C6
const yaml: Icon = .{ .icon = "", .color = "\x1b[38;2;204;25;31m" }; // #CC191F
const zig: Icon = .{ .icon = "", .color = "\x1b[38;2;187;187;70m" }; // zig -> #BBBB46

const by_name: std.StaticStringMap(Icon) = .initComptime(.{
    .{ ".bash_aliases", Icon.sh },
    .{ ".bash_history", Icon.sh },
    .{ ".bash_profile", Icon.sh },
    .{ ".bash_logout", Icon.sh },
    .{ ".bashrc", Icon.sh },
    .{ ".gitconfig", Icon.git },
    .{ ".gitignore", Icon.git },
    .{ ".rootlogon.C", Icon.root },
    .{ ".rootrc", Icon.root },
    .{ ".zshrc", Icon.sh },
    .{ "DESCRIPTION", Icon.rlang },
    .{ "GNUMakefile", Icon.makefile },
    .{ "Gemfile", Icon.rb },
    .{ "Gemfile.lock", Icon.rb },
    .{ "Makefile", Icon.makefile },
    .{ "Package.swift", Icon.swift },
    .{ "Cargo.lock", Icon.rust },
    .{ "Cargo.toml", Icon.rust },
    .{ "build.gradle", Icon.java },
    .{ "build.gradle.kts", Icon.kt },
    .{ "build.sbt", Icon.scala },
    .{ "cabal", Icon.hs },
    .{ "composer.json", Icon.php },
    .{ "composer.lock", Icon.php },
    .{ "cpanfile", Icon.pl },
    .{ "csproj", Icon.cs },
    .{ "cabal", Icon.hs },
    .{ "composer.json", Icon.php },
    .{ "composer.lock", Icon.php },
    .{ "flake.lock", Icon.nix },
    .{ "go.mod", Icon.go },
    .{ "go.sum", Icon.go },
    .{ "mix.exs", Icon.ex },
    .{ "package-lock.json", Icon.javascript },
    .{ "package.json", Icon.javascript },
    .{ "pom.xml", Icon.java },
    .{ "project.clj", Icon.clj },
    .{ "pubspec.yaml", Icon.dart },
    .{ "rebar.config", Icon.erl },
    .{ "requirements.txt", Icon.python },
    .{ "stack.yaml", Icon.hs },
    .{ "tsconfig.json", Icon.typescript },
});

const by_extension: std.StaticStringMap(Icon) = .initComptime(.{
    .{ "bash", Icon.sh },
    .{ "c", Icon.c },
    .{ "cc", Icon.cpp },
    .{ "cjs", Icon.javascript },
    .{ "clj", Icon.clj },
    .{ "cljs", Icon.clj },
    .{ "cpp", Icon.cpp },
    .{ "cxx", Icon.cpp },
    .{ "cs", Icon.cs },
    .{ "css", Icon.css },
    .{ "dart", Icon.dart },
    .{ "drv", Icon.nix },
    .{ "el", Icon.elisp },
    .{ "ex", Icon.ex },
    .{ "exs", Icon.ex },
    .{ "erl", Icon.erl },
    .{ "fnl", Icon.fennel },
    .{ "gif", Icon.image },
    .{ "git", Icon.git },
    .{ "go", Icon.go },
    .{ "h", Icon.c },
    .{ "hh", Icon.cpp },
    .{ "hpp", Icon.cpp },
    .{ "hs", Icon.hs },
    .{ "hxx", Icon.cpp },
    .{ "html", Icon.html },
    .{ "htm", Icon.html },
    .{ "java", Icon.java },
    .{ "jpeg", Icon.image },
    .{ "jpg", Icon.image },
    .{ "js", Icon.javascript },
    .{ "jsx", Icon.javascript },
    .{ "json", Icon.json },
    .{ "kt", Icon.kt },
    .{ "kts", Icon.kt },
    .{ "lua", Icon.lua },
    .{ "md", Icon.markdown },
    .{ "mjs", Icon.javascript },
    .{ "mkv", Icon.video },
    .{ "mp4", Icon.video },
    .{ "nar", Icon.nix },
    .{ "nix", Icon.nix },
    .{ "php", Icon.php },
    .{ "pl", Icon.pl },
    .{ "png", Icon.image },
    .{ "py", Icon.python },
    .{ "r", Icon.rlang },
    .{ "rb", Icon.rb },
    .{ "rs", Icon.rust },
    .{ "root", Icon.root },
    .{ "scala", Icon.scala },
    .{ "sh", Icon.sh },
    .{ "sql", Icon.sql },
    .{ "swift", Icon.swift },
    .{ "toml", Icon.toml },
    .{ "ts", Icon.typescript },
    .{ "tsx", Icon.typescript },
    .{ "webp", Icon.image },
    .{ "yaml", Icon.yaml },
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
