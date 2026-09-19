//! `fpack` — the content compiler. Authoring text in, one `.fpk` out.
//!
//! A plain command-line program, per ADR-0011: tools are Foundry applications built on
//! Foundry, and this one links the engine's own modules and reads files through `platform`
//! rather than reaching for `std.fs` beside it. When the public ABI exists (M7) that is the
//! surface it should move to; until then linking directly is the only surface there is, and
//! the point of the decision — no privileged path the mod API lacks — is kept by using the
//! same `data` every consumer will.
//!
//! ```
//! fpack --out zig-out/content/core.fpk --assets-out zig-out/content/core content/core
//! ```
//!
//! Two outputs, because a package has two kinds of thing in it. The `.fpk` is the compiled
//! records; `--assets-out` receives the assets that had an authoring format of their own and
//! had to be compiled too — a tile grid, today. It is kept separate from the package
//! directory so that what a person wrote and what a tool produced are never mixed, and it is
//! only needed by a package that contains something requiring compilation.
//!
//! **The package's name and version come from its own `mod.fdt`**, not from the command
//! line (ADR-0027). A package is identified by exactly one thing and the manifest is where
//! that thing is written down, so there is nowhere for a second answer to disagree from —
//! which is what `--name` and `--version` used to be.
//!
//! **The compiler is `author`'s, not this program's** (ADR-0042). `--dependency` names the
//! `.fpk` files this package is written against and `author` reads them exactly as a
//! workspace does, so what an author is checked against in an editor and what they are
//! checked against on the command line are the same packages read by the same code.
//!
//! Everything it compiles is untrusted input — a package directory may be a mod's — so a bad
//! file is a diagnostic and a non-zero exit, never a crash.

const std = @import("std");
const author = @import("author");
const data = @import("data");
const platform = @import("platform");

const usage =
    \\fpack — compile a Foundry content package
    \\
    \\usage: fpack --out <file.fpk> <package-dir>
    \\
    \\  --out <file.fpk>          where to write the compiled package (required)
    \\  --assets-out <dir>        where to write compiled assets (required if any)
    \\  --dependency <file.fpk>   a package this one is compiled against (repeatable)
    \\  --quiet                   report nothing on success
    \\
    \\The package's id and version are read from its mod.fdt (ADR-0027).
    \\Dependencies are named, never searched for: a package nobody names is not read, so
    \\its schemas are not registered and a record of its that this package uses is an
    \\unknown schema rather than a lucky find. They register in the order they were given,
    \\before this package's own declarations.
    \\  --help                    this text
    \\
;

const Args = struct {
    out: []const u8 = "",
    assets_out: []const u8 = "",
    quiet: bool = false,
    dir: []const u8 = "",
    /// The dependency files, in the order they were given: that order is the order their
    /// schemas are registered in, so the same command line reads the same on every machine.
    dependencies: std.ArrayListUnmanaged(author.DependencySource) = .empty,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;

    // Zig 0.16 hands the command line to the entry point rather than exposing it
    // ambiently, which is the same shape `app` keeps for the environment and for the same
    // reason: an input read from the air is a hidden input.
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
    defer args.dependencies.deinit(gpa);

    const os = try platform.os.Os.init(gpa, .{});
    defer os.deinit();

    var registry: data.Registry = .init(gpa, .default);
    defer registry.deinit(gpa);
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);

    // **The granted dependencies are read before anything is compiled.** A package checked
    // against half of what it was written against is worse than one that was not checked at
    // all, and a `.fpk` the host named and that cannot be read is a mistake to report on its
    // own rather than a reason to compile something else.
    var dependencies: author.DependencySet = .init(gpa);
    defer dependencies.deinit();
    if (args.dependencies.items.len > 0) {
        dependencies = author.DependencySet.load(gpa, os, args.dependencies.items, .{}, &diags) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.ContentInvalid, error.IoFailed, error.OverBudget => {
                try diags.render(&stderr.interface);
                return 1;
            },
        };
    }

    const result = author.compile(gpa, os, args.dir, .{
        .assets_out = if (args.assets_out.len == 0) null else args.assets_out,
        .dependencies = if (args.dependencies.items.len == 0) null else &dependencies,
    }, &registry, &diags, &bytes);

    // Diagnostics are rendered whatever happened: a package can compile and still have
    // something worth saying about it.
    try diags.render(&stderr.interface);

    // Both failures already said what went wrong, as a diagnostic, in the same shape a
    // content mistake gets. A second message here would be the tool talking over itself.
    const identity = result catch |err| switch (err) {
        error.ContentInvalid, error.IoFailed, error.OverBudget => return 1,
        error.OutOfMemory => return err,
    };
    defer gpa.free(identity.name);

    if (std.fs.path.dirname(args.out)) |parent| {
        os.createDirPath(parent) catch |err| {
            try stderr.interface.print("fpack: cannot create '{s}': {s}\n", .{ parent, @errorName(err) });
            return 1;
        };
    }
    os.writeFile(args.out, bytes.items) catch |err| {
        try stderr.interface.print("fpack: cannot write '{s}': {s}\n", .{ args.out, @errorName(err) });
        return 1;
    };

    if (!args.quiet) {
        try stderr.interface.print(
            "fpack: {s} version {d} -> {s} ({d} bytes)\n",
            .{ identity.name, identity.version, args.out, bytes.items.len },
        );
    }
    return 0;
}

const ArgError = error{ HelpRequested, BadUsage } || std.Io.Writer.Error || std.mem.Allocator.Error;

fn parseArgs(gpa: std.mem.Allocator, argv: []const []const u8, err_writer: *std.Io.Writer) ArgError!Args {
    var args: Args = .{};
    errdefer args.dependencies.deinit(gpa);

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return error.HelpRequested;
        if (std.mem.eql(u8, arg, "--quiet")) {
            args.quiet = true;
        } else if (std.mem.eql(u8, arg, "--out")) {
            args.out = try value(argv, &i, err_writer);
        } else if (std.mem.eql(u8, arg, "--assets-out")) {
            args.assets_out = try value(argv, &i, err_writer);
        } else if (std.mem.eql(u8, arg, "--dependency")) {
            // Repeatable, and each one is a file rather than a directory: a dependency is a
            // compiled package, so there is nothing to search for inside it.
            try args.dependencies.append(gpa, .{ .path = try value(argv, &i, err_writer) });
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try err_writer.print("fpack: unknown option '{s}'\n", .{arg});
            return error.BadUsage;
        } else if (args.dir.len == 0) {
            args.dir = arg;
        } else {
            try err_writer.print("fpack: more than one package directory given ('{s}')\n", .{arg});
            return error.BadUsage;
        }
    }

    if (args.dir.len == 0) return error.BadUsage;
    if (args.out.len == 0) {
        try err_writer.writeAll("fpack: --out is required\n");
        return error.BadUsage;
    }
    return args;
}

fn value(argv: []const []const u8, i: *usize, err_writer: *std.Io.Writer) ArgError![]const u8 {
    if (i.* + 1 >= argv.len) {
        try err_writer.print("fpack: '{s}' needs a value\n", .{argv[i.*]});
        return error.BadUsage;
    }
    i.* += 1;
    return argv[i.*];
}

test {
    _ = author;
}

const testing = std.testing;

test "arguments are read, and a missing one is a usage error rather than a default" {
    const gpa = testing.allocator;
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    var args = try parseArgs(gpa, &.{ "--out", "core.fpk", "content/core" }, &writer);
    defer args.dependencies.deinit(gpa);
    try testing.expectEqualStrings("core.fpk", args.out);
    try testing.expectEqualStrings("content/core", args.dir);
    try testing.expect(!args.quiet);

    // Absent rather than defaulted: a package with nothing to compile needs no output
    // directory, and inventing one would create a directory nobody asked for.
    try testing.expectEqualStrings("", args.assets_out);
    try testing.expectEqual(0, args.dependencies.items.len);

    var full = try parseArgs(gpa, &.{ "content/core", "--out", "o", "--quiet", "--assets-out", "gen" }, &writer);
    defer full.dependencies.deinit(gpa);
    try testing.expect(full.quiet);
    try testing.expectEqualStrings("gen", full.assets_out);

    // Dependencies keep the order they were given, because that order decides the order
    // their schemas register in and a content compile may not depend on how a directory
    // happened to be laid out (I9).
    var deps = try parseArgs(gpa, &.{ "d", "--out", "o", "--dependency", "a.fpk", "--dependency", "b.fpk" }, &writer);
    defer deps.dependencies.deinit(gpa);
    try testing.expectEqual(2, deps.dependencies.items.len);
    try testing.expectEqualStrings("a.fpk", deps.dependencies.items[0].path);
    try testing.expectEqualStrings("b.fpk", deps.dependencies.items[1].path);

    // `--name` and `--version` are gone: a package states its own identity (ADR-0027), and
    // an option that used to be accepted must fail loudly rather than be ignored, or a
    // stale build script would silently compile the wrong thing.
    try testing.expectError(error.BadUsage, parseArgs(gpa, &.{ "--name", "a:b", "--out", "o", "d" }, &writer));
    try testing.expectError(error.BadUsage, parseArgs(gpa, &.{ "--version", "7", "--out", "o", "d" }, &writer));

    try testing.expectError(error.BadUsage, parseArgs(gpa, &.{ "--out", "o", "--assets-out" }, &writer));
    try testing.expectError(error.BadUsage, parseArgs(gpa, &.{ "--out", "o", "--dependency" }, &writer));
    try testing.expectError(error.BadUsage, parseArgs(gpa, &.{"content/core"}, &writer));
    try testing.expectError(error.BadUsage, parseArgs(gpa, &.{"--out"}, &writer));
    try testing.expectError(error.BadUsage, parseArgs(gpa, &.{ "--nope", "x" }, &writer));
    try testing.expectError(error.HelpRequested, parseArgs(gpa, &.{"--help"}, &writer));
}
