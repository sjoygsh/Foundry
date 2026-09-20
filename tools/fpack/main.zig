//! `fpack` — the content compiler. Authoring text in, one `.fpk` out.
//!
//! A plain command-line program, per ADR-0011: tools are Foundry applications built on
//! Foundry, and this one links the engine's own modules and reads files through `platform`
//! rather than reaching for `std.fs` beside it.
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
//! **This program is a host of the public authoring service, not a second compiler**
//! (ADR-0042, `editor.md` §9). It opens the package directory as an `author` workspace with
//! build authority and nothing else, asks for a build, and maps that build to `--out` and
//! `--assets-out` through a destination it configured itself. So the editor and the command
//! line do not merely *share* a compiler: they walk the same snapshot, the same dependency
//! reading and the same candidate, and there is no path through this program that an editor
//! could not take. The output bytes and the exit codes are exactly what they were.
//!
//! The one thing that is new on the command line is `--work`: a build needs a directory to
//! assemble its private candidate in, and that directory is a grant like every other. It
//! defaults to `--out`'s own parent, which is already a place this command writes.
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
    \\  --work <dir>              where build candidates are assembled
    \\                            (default: the directory --out is written to)
    \\  --quiet                   report nothing on success
    \\  --help                    this text
    \\
    \\The package's id and version are read from its mod.fdt (ADR-0027).
    \\
    \\Dependencies are named, never searched for: a package nobody names is not read, so
    \\its schemas are not registered and a record of its that this package uses is an
    \\unknown schema rather than a lucky find. They register in the order they were given,
    \\before this package's own declarations. A file named twice, or a copy of one, is
    \\read once; two different files that are the same package are refused.
    \\
    \\The work directory must not contain, or sit inside, the package directory or any
    \\dependency's. A candidate is created there and removed again whether the build
    \\succeeds or fails.
    \\
;

const Args = struct {
    out: []const u8 = "",
    assets_out: []const u8 = "",
    work: []const u8 = "",
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

    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);

    // The two directories this command writes to, made before anything is granted: a grant
    // names a directory that exists, and creating `--out`'s parent is what this program has
    // always done anyway.
    const out_dir = std.fs.path.dirname(args.out) orelse ".";
    os.createDirPath(out_dir) catch |err| switch (err) {
        error.AlreadyExists => {},
        else => {
            try stderr.interface.print("fpack: cannot create '{s}': {s}\n", .{ out_dir, @errorName(err) });
            return 1;
        },
    };
    const work = if (args.work.len == 0) out_dir else args.work;
    os.createDirPath(work) catch |err| switch (err) {
        error.AlreadyExists => {},
        else => {
            try stderr.interface.print("fpack: cannot create '{s}': {s}\n", .{ work, @errorName(err) });
            return 1;
        },
    };

    // One destination, which is the legacy pair. `compiled` and not `runtime`: what this
    // command has always written is the package plus the assets the **compiler** produced,
    // and copying a package's ordinary assets beside its `.fpk` would be a new output set
    // for a command line that has never had one.
    const destinations = [_]author.ExportTarget{.{
        .name = "--out",
        .kind = .compiled,
        .package_root = out_dir,
        .package_name = std.fs.path.basename(args.out),
        .assets_root = if (args.assets_out.len == 0) null else args.assets_out,
    }};

    var service: author.Service = .init(gpa, os, .{});
    defer service.deinit();

    const workspace = service.open(args.dir, .{
        .workspace = .{
            .dependencies = args.dependencies.items,
            .output_root = work,
            // Build authority and nothing else. This command does not edit a source file
            // and does not save one, and a grant it does not need is a grant it does not
            // get (`editor.md` §4).
            .grants = .{ .build = true },
            .limits = .{
                // **Unbounded, as it has always been.** A workspace caps what an editor
                // will hold in memory; someone compiling their own directory from the
                // command line has already chosen how big it is (`editor.md` §8's
                // compatibility rule).
                .walk = .unbounded,
            },
        },
        .exports = &destinations,
    }, &diags) catch |err| {
        try diags.render(&stderr.interface);
        return openFailure(&stderr.interface, err);
    };

    const entry = service.entry(workspace).?;
    const build = entry.workspace.build(entry.workspace.revision(), &diags) catch |err| {
        try diags.render(&stderr.interface);
        return buildFailure(&stderr.interface, err);
    };

    // Diagnostics are rendered whatever happened: a package can compile and still have
    // something worth saying about it.
    try diags.render(&stderr.interface);

    const info = try entry.workspace.buildInfo(build);
    const name = try gpa.dupe(u8, info.package_name);
    defer gpa.free(name);
    const version = info.package_version;
    const size = info.package_bytes.len;

    _ = service.exportBuild(workspace, build, 0) catch |err| {
        try entry.diags.render(&stderr.interface);
        try stderr.interface.print("fpack: cannot publish the build: {s}\n", .{@errorName(err)});
        return 1;
    };

    if (!args.quiet) {
        try stderr.interface.print(
            "fpack: {s} version {d} -> {s} ({d} bytes)\n",
            .{ name, version, args.out, size },
        );
    }
    return 0;
}

/// A workspace that could not be opened at all. Every one of these already has its
/// diagnostic; this only decides the exit code, and every content or file fault is 1.
fn openFailure(err_writer: *std.Io.Writer, err: anyerror) !u8 {
    switch (err) {
        error.OutOfMemory => return err,
        error.InvalidGrant => {
            try err_writer.writeAll("fpack: the work directory overlaps the package or a dependency; name another with --work\n");
            return 2;
        },
        else => return 1,
    }
}

fn buildFailure(err_writer: *std.Io.Writer, err: anyerror) !u8 {
    switch (err) {
        error.OutOfMemory => return err,
        error.OutputUnavailable, error.BuildNotGranted => {
            try err_writer.writeAll("fpack: the work directory is not usable; name another with --work\n");
            return 2;
        },
        else => return 1,
    }
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
        } else if (std.mem.eql(u8, arg, "--work")) {
            args.work = try value(argv, &i, err_writer);
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

    // The work directory is absent here too, and absent means `--out`'s own parent —
    // decided where the paths are known rather than baked into the parse.
    try testing.expectEqualStrings("", args.work);

    var full = try parseArgs(gpa, &.{ "content/core", "--out", "o", "--quiet", "--assets-out", "gen", "--work", "tmp" }, &writer);
    defer full.dependencies.deinit(gpa);
    try testing.expect(full.quiet);
    try testing.expectEqualStrings("gen", full.assets_out);
    try testing.expectEqualStrings("tmp", full.work);

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
    try testing.expectError(error.BadUsage, parseArgs(gpa, &.{ "--out", "o", "--work" }, &writer));
    try testing.expectError(error.BadUsage, parseArgs(gpa, &.{"content/core"}, &writer));
    try testing.expectError(error.BadUsage, parseArgs(gpa, &.{"--out"}, &writer));
    try testing.expectError(error.BadUsage, parseArgs(gpa, &.{ "--nope", "x" }, &writer));
    try testing.expectError(error.HelpRequested, parseArgs(gpa, &.{"--help"}, &writer));
}
