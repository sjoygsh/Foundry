//! `fstage` — the release packager. Explicit inputs in, one staged release out.
//!
//! A plain command-line program, per ADR-0011, and a consumer of the engine's modules in
//! exactly the way `fpack` is: it reads packages through `data` and files through
//! `platform`, and it reaches nothing a game could not. It is packaging machinery, not a
//! second runtime — it never executes a script, opens a native library, or looks inside a
//! world (`distribution.md` §3).
//!
//! ```
//! fstage --out zig-out/dist/room --executable zig-out/bin/room --executable-name room \
//!        --product "Foundry Room" --version 0.9.0 --target-os macos \
//!        --package core --fpk .../core.fpk --source-root content/core \
//!        --package room --fpk .../room.fpk --source-root samples/room/content \
//!                      --generated-root .../room-assets
//! ```
//!
//! `--fpk`, `--source-root` and `--generated-root` attach to the `--package` before them, so
//! the command reads in the order the release is described rather than as four parallel
//! lists that can fall out of step.
//!
//! Everything it is handed is checked: a release description is written by a person and a
//! package may be a mod's, so a bad input is a refusal naming what was wrong and a non-zero
//! exit, never a crash and never a half-staged directory.

const std = @import("std");
const platform = @import("platform");

const stage = @import("stage.zig");

const Allocator = std.mem.Allocator;

const usage =
    \\fstage — stage a Foundry release from explicit inputs
    \\
    \\usage: fstage --out <dir> --executable <file> --product <name> --version <v>
    \\              --target-os <os> --package <stem> --fpk <file> --source-root <dir> ...
    \\
    \\  --out <dir>               where to stage the release; must be empty (required)
    \\  --executable <file>       the program to ship (required)
    \\  --executable-name <name>  what it is called in the release (default: its file name)
    \\  --product <name>          the product's name (required)
    \\  --version <string>        the product's version (required)
    \\  --build <string>          the product's build number (default: 1)
    \\  --revision <string>       the source revision, recorded as given (default: local)
    \\  --target-os <os>          the system the release runs on (required)
    \\  --max-files <n>           how many files a release may contain
    \\  --max-total-bytes <n>     how large a release may be
    \\  --package <stem>          add a package, staged as content/<stem> (repeatable)
    \\  --fpk <file>              its compiled package (required per --package)
    \\  --source-root <dir>       its authored directory (required per --package)
    \\  --generated-root <dir>    where its compiled assets are, if it has any
    \\  --extra <staged>=<file>   one more runtime file, at <staged> in the release
    \\  --quiet                   report nothing on success
    \\  --help                    this text
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;

    // Zig 0.16 hands the command line to the entry point rather than exposing it ambiently,
    // which is the shape `app` keeps for the environment and for the same reason: an input
    // read from the air is a hidden input.
    var it = try init.minimal.args.iterateAllocator(gpa);
    defer it.deinit();
    _ = it.skip();

    var argv: std.ArrayList([]const u8) = .empty;
    defer {
        for (argv.items) |a| gpa.free(a);
        argv.deinit(gpa);
    }
    while (it.next()) |arg| try argv.append(gpa, try gpa.dupe(u8, arg));

    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &stderr_buf);
    defer stderr.interface.flush() catch {};

    var args = parseArgs(gpa, argv.items, &stderr.interface) catch |err| switch (err) {
        error.HelpRequested => {
            try stderr.interface.writeAll(usage);
            return 0;
        },
        error.BadUsage => {
            try stderr.interface.writeAll(usage);
            return 2;
        },
        else => return err,
    };
    defer args.deinit(gpa);

    const os = try platform.os.Os.init(gpa, .{});
    defer os.deinit();

    var report: stage.Report = .{ .writer = &stderr.interface };
    const result = stage.run(gpa, os, args.options(), &report) catch |err| switch (err) {
        error.Refused => return 1,
        error.OutOfMemory => return err,
    };

    if (!args.quiet) {
        try stderr.interface.print("fstage: {s} {s} -> {s} ({d} files, {d} bytes)\n", .{
            args.product, args.version, args.out, result.files, result.bytes,
        });
    }
    return 0;
}

const Args = struct {
    out: []const u8 = "",
    executable: []const u8 = "",
    executable_name: []const u8 = "",
    product: []const u8 = "",
    version: []const u8 = "",
    build: []const u8 = "1",
    revision: []const u8 = "local",
    target_os: ?std.Target.Os.Tag = null,
    limits: stage.Limits = .default,
    packages: std.ArrayList(stage.PackageInput) = .empty,
    extras: std.ArrayList(stage.ExtraInput) = .empty,
    quiet: bool = false,

    fn deinit(self: *Args, gpa: Allocator) void {
        self.packages.deinit(gpa);
        self.extras.deinit(gpa);
        self.* = undefined;
    }

    fn options(self: *const Args) stage.Options {
        return .{
            .out = self.out,
            .executable = self.executable,
            .executable_name = self.executable_name,
            .packages = self.packages.items,
            .extras = self.extras.items,
            .metadata = .{
                .product = self.product,
                .version = self.version,
                .build = self.build,
                .revision = self.revision,
            },
            .limits = self.limits,
            .target_os = self.target_os.?,
        };
    }
};

const ArgError = error{ HelpRequested, BadUsage } || Allocator.Error || std.Io.Writer.Error;

fn parseArgs(gpa: Allocator, argv: []const []const u8, err: *std.Io.Writer) ArgError!Args {
    var args: Args = .{};
    errdefer args.deinit(gpa);

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return error.HelpRequested;
        if (std.mem.eql(u8, arg, "--quiet")) {
            args.quiet = true;
        } else if (std.mem.eql(u8, arg, "--out")) {
            args.out = try value(argv, &i, err);
        } else if (std.mem.eql(u8, arg, "--executable")) {
            args.executable = try value(argv, &i, err);
        } else if (std.mem.eql(u8, arg, "--executable-name")) {
            args.executable_name = try value(argv, &i, err);
        } else if (std.mem.eql(u8, arg, "--product")) {
            args.product = try value(argv, &i, err);
        } else if (std.mem.eql(u8, arg, "--version")) {
            args.version = try value(argv, &i, err);
        } else if (std.mem.eql(u8, arg, "--build")) {
            args.build = try value(argv, &i, err);
        } else if (std.mem.eql(u8, arg, "--revision")) {
            args.revision = try value(argv, &i, err);
        } else if (std.mem.eql(u8, arg, "--target-os")) {
            const name = try value(argv, &i, err);
            args.target_os = std.meta.stringToEnum(std.Target.Os.Tag, name) orelse {
                try err.print("fstage: '{s}' is not an operating system name\n", .{name});
                return error.BadUsage;
            };
        } else if (std.mem.eql(u8, arg, "--max-files")) {
            args.limits.max_files = try number(u32, argv, &i, err);
        } else if (std.mem.eql(u8, arg, "--max-total-bytes")) {
            args.limits.max_total_bytes = try number(u64, argv, &i, err);
        } else if (std.mem.eql(u8, arg, "--package")) {
            try args.packages.append(gpa, .{ .stem = try value(argv, &i, err), .fpk = "", .source_root = "" });
        } else if (std.mem.eql(u8, arg, "--fpk")) {
            (try current(&args, err)).fpk = try value(argv, &i, err);
        } else if (std.mem.eql(u8, arg, "--source-root")) {
            (try current(&args, err)).source_root = try value(argv, &i, err);
        } else if (std.mem.eql(u8, arg, "--generated-root")) {
            (try current(&args, err)).generated_root = try value(argv, &i, err);
        } else if (std.mem.eql(u8, arg, "--extra")) {
            const pair = try value(argv, &i, err);
            const at = std.mem.indexOfScalar(u8, pair, '=') orelse {
                try err.print("fstage: '--extra {s}' is not <staged-path>=<file>\n", .{pair});
                return error.BadUsage;
            };
            try args.extras.append(gpa, .{ .staged = pair[0..at], .source = pair[at + 1 ..] });
        } else {
            try err.print("fstage: unexpected argument '{s}'\n", .{arg});
            return error.BadUsage;
        }
    }

    try require(args.out, "--out", err);
    try require(args.executable, "--executable", err);
    try require(args.product, "--product", err);
    try require(args.version, "--version", err);
    if (args.target_os == null) {
        try err.writeAll("fstage: --target-os is required\n");
        return error.BadUsage;
    }
    if (args.packages.items.len == 0) {
        try err.writeAll("fstage: at least one --package is required\n");
        return error.BadUsage;
    }
    for (args.packages.items) |pkg| {
        if (pkg.fpk.len == 0 or pkg.source_root.len == 0) {
            try err.print("fstage: package '{s}' needs both --fpk and --source-root\n", .{pkg.stem});
            return error.BadUsage;
        }
    }

    // Defaulted rather than required: the artifact's own file name is right almost always,
    // and an application that wants a different one says so.
    if (args.executable_name.len == 0) args.executable_name = std.fs.path.basename(args.executable);
    return args;
}

/// The package the last `--package` opened. A file belongs to a package, so naming one
/// before any package exists is a mistake worth catching rather than a file in limbo.
fn current(args: *Args, err: *std.Io.Writer) ArgError!*stage.PackageInput {
    if (args.packages.items.len == 0) {
        try err.writeAll("fstage: a package option came before any --package\n");
        return error.BadUsage;
    }
    return &args.packages.items[args.packages.items.len - 1];
}

fn require(given: []const u8, name: []const u8, err: *std.Io.Writer) ArgError!void {
    if (given.len > 0) return;
    try err.print("fstage: {s} is required\n", .{name});
    return error.BadUsage;
}

fn value(argv: []const []const u8, i: *usize, err: *std.Io.Writer) ArgError![]const u8 {
    if (i.* + 1 >= argv.len) {
        try err.print("fstage: '{s}' needs a value\n", .{argv[i.*]});
        return error.BadUsage;
    }
    i.* += 1;
    return argv[i.*];
}

fn number(comptime T: type, argv: []const []const u8, i: *usize, err: *std.Io.Writer) ArgError!T {
    const text = try value(argv, i, err);
    return std.fmt.parseInt(T, text, 10) catch {
        try err.print("fstage: '{s}' is not a number\n", .{text});
        return error.BadUsage;
    };
}

test {
    _ = stage;
}

const testing = std.testing;

test "a release is described in the order it is written, and a package owns the files after it" {
    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    var args = try parseArgs(testing.allocator, &.{
        "--out",            "out",
        "--executable",     "build/bin/room",
        "--product",        "Foundry Room",
        "--version",        "0.9.0",
        "--target-os",      "macos",
        "--package",        "core",
        "--fpk",            "build/core.fpk",
        "--source-root",    "content/core",
        "--package",        "room",
        "--fpk",            "build/room.fpk",
        "--source-root",    "samples/room/content",
        "--generated-root", "build/room-assets",
        "--extra",          "content/room/libx.dylib=build/libx.dylib",
    }, &writer);
    defer args.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), args.packages.items.len);
    try testing.expectEqualStrings("core", args.packages.items[0].stem);
    try testing.expectEqualStrings("build/core.fpk", args.packages.items[0].fpk);
    try testing.expect(args.packages.items[0].generated_root == null);
    try testing.expectEqualStrings("build/room-assets", args.packages.items[1].generated_root.?);
    try testing.expectEqual(std.Target.Os.Tag.macos, args.target_os.?);

    // The executable's own name, because an application that wants a different one says so.
    try testing.expectEqualStrings("room", args.executable_name);

    try testing.expectEqualStrings("content/room/libx.dylib", args.extras.items[0].staged);
    try testing.expectEqualStrings("build/libx.dylib", args.extras.items[0].source);

    // Recorded as given, and `local` when nobody said. The build runs no `git`.
    try testing.expectEqualStrings("local", args.revision);
    try testing.expectEqualStrings("1", args.build);
}

test "an incomplete release description is a usage error rather than a default" {
    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    const complete = [_][]const u8{
        "--out",     "out",   "--executable",  "bin/room", "--product", "Room",
        "--version", "1",     "--target-os",   "macos",    "--package", "room",
        "--fpk",     "r.fpk", "--source-root", "src",
    };
    var ok = try parseArgs(testing.allocator, &complete, &writer);
    ok.deinit(testing.allocator);

    // Each required option, removed one at a time. A release described incompletely must
    // not stage something plausible.
    try testing.expectError(error.BadUsage, parseArgs(testing.allocator, complete[2..], &writer));
    try testing.expectError(error.BadUsage, parseArgs(testing.allocator, &.{ "--out", "o" }, &writer));
    try testing.expectError(error.BadUsage, parseArgs(testing.allocator, complete[0..8], &writer));

    // A package with no compiled half, and a file with no package.
    try testing.expectError(error.BadUsage, parseArgs(testing.allocator, complete[0..10], &writer));
    try testing.expectError(error.BadUsage, parseArgs(testing.allocator, &.{ "--fpk", "r.fpk" }, &writer));

    try testing.expectError(error.BadUsage, parseArgs(testing.allocator, &.{ "--target-os", "plan9x" }, &writer));
    try testing.expectError(error.BadUsage, parseArgs(testing.allocator, &.{ "--extra", "nopair" }, &writer));
    try testing.expectError(error.BadUsage, parseArgs(testing.allocator, &.{ "--max-files", "lots" }, &writer));
    try testing.expectError(error.BadUsage, parseArgs(testing.allocator, &.{"--nope"}, &writer));
    try testing.expectError(error.HelpRequested, parseArgs(testing.allocator, &.{"--help"}, &writer));
}
