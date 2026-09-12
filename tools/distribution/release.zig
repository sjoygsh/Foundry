//! Describing a release, for Foundry's own samples and for a game in its own repository.
//!
//! **Build-time only.** Nothing here is compiled into anything: it names `std.Build` and no
//! engine module, and it is `@import`ed by a `build.zig` rather than linked. `fstage` beside
//! it is the program that does the work; this is the part that knows how to ask.
//!
//! A game consuming Foundry as a dependency reaches this the way it reaches any other
//! build-time declaration:
//!
//! ```zig
//! const foundry = @import("foundry");                       // Foundry's own build.zig
//! const dep = b.dependency("foundry", .{ .target = t, .optimize = .ReleaseSafe,
//!                                        .platform = .sdl3, .rhi = .metal });
//! const staged = foundry.release.stage(b, .fromDependency(dep), .{
//!     .product_name = "Lanterns",
//!     .bundle_id = "com.example.lanterns",
//!     .product_version = "1.0.0",
//!     .executable = game,
//!     .packages = &.{ .{ .stem = "core", .dir = "content/core" },
//!                     .{ .stem = "lanterns", .dir = "content/lanterns" } },
//! });
//! ```
//!
//! So the samples are not a special case: `build.zig` calls exactly this, with exactly these
//! inputs, and a game outside this repository gets no less and no more (ADR-0017).
//!
//! Design: `docs/design/distribution.md` §3, §4 and §8.

const std = @import("std");

/// One package in a release: where its sources are, and what it is called under `content/`.
pub const Package = struct {
    /// Relative to the consuming build's root.
    dir: []const u8,
    /// A location, never identity (ADR-0021) — the compiled package states its own id.
    stem: []const u8,
    /// The notice this package's license requires, when it is not the application's own.
    /// A manifest's `license` is an identifier and discharges nothing by itself
    /// (`distribution.md` §9).
    notice: ?std.Build.LazyPath = null,
};

/// A runtime file no package can name: a native library, or an asset for a loader the
/// engine does not define (`distribution.md` §8).
pub const ExtraFile = struct {
    /// Where it goes, relative to the release root.
    staged: []const u8,
    source: std.Build.LazyPath,
};

/// Explicit bounds on a release, checked before anything is copied.
pub const Limits = struct {
    max_files: u32 = 4096,
    max_total_bytes: u64 = 2 << 30,
};

/// One application's release description (`distribution.md` §4).
///
/// The product's identity lives here and nowhere else: Step 7 generates the bundle's plist
/// from these fields rather than from a second copy of them, and the engine's ABI version
/// is not among them because it is not a product version.
pub const Description = struct {
    product_name: []const u8,
    /// Reverse-DNS, for the macOS bundle. Recorded now so that it has exactly one home.
    bundle_id: []const u8,
    product_version: []const u8,
    build_number: []const u8 = "1",
    /// The oldest macOS the artifact claims to run on. Step 7 is what enforces it.
    minimum_macos_version: []const u8 = "13.0",
    executable: *std.Build.Step.Compile,
    /// What the executable is called in the release. Defaults to the artifact's name.
    executable_name: ?[]const u8 = null,
    /// The application's own license identifier, and the file holding its text. A staged
    /// package declaring this identifier is covered by that file; one declaring anything
    /// else supplies its own notice.
    license_id: []const u8,
    license_file: std.Build.LazyPath,
    /// Its `NOTICE`, when it has one.
    notice_file: ?std.Build.LazyPath = null,
    /// The directory of recorded third-party licenses the attribution is generated from,
    /// relative to the consuming build's root. A game records Foundry here, the way Foundry
    /// records SDL and Lua.
    licenses_dir: []const u8,
    packages: []const Package,
    extra_files: []const ExtraFile = &.{},
    limits: Limits = .{},
    /// The source revision, recorded as given. Null is recorded as `local`: the build runs
    /// no `git` — it has no external tool dependencies (ADR-0014) — so a revision is
    /// something an operator states, never something the build infers.
    revision: ?[]const u8 = null,
};

/// The two programs a release is staged with.
///
/// `fpack` is run on the **host**, because it is a program and a cross-built one cannot be
/// executed here (`distribution.md` §8). `stage` checks that before running anything.
pub const Tools = struct {
    fpack: *std.Build.Step.Compile,
    fstage: *std.Build.Step.Compile,

    pub fn fromDependency(dep: *std.Build.Dependency) Tools {
        return .{ .fpack = dep.artifact("fpack"), .fstage = dep.artifact("fstage") };
    }
};

/// A compiled package: the `.fpk`, and the directory holding whatever assets had an
/// authoring format of their own.
pub const Compiled = struct {
    fpk: std.Build.LazyPath,
    /// Separate from the package directory, because what a person wrote and what a tool
    /// produced never share a tree (`tilemaps-and-collision.md` §9).
    generated: std.Build.LazyPath,
};

/// Runs the content compiler over one package.
///
/// Shared by the development install and by staging, so the two cannot compile content
/// differently — and available to a game outside this repository, which needs the same step
/// and should not have to reimplement it.
pub fn compilePackage(
    b: *std.Build,
    fpack: *std.Build.Step.Compile,
    package: Package,
) Compiled {
    const run = b.addRunArtifact(fpack);
    run.addArgs(&.{ "--quiet", "--out" });
    const fpk = run.addOutputFileArg(b.fmt("{s}.fpk", .{package.stem}));
    run.addArg("--assets-out");
    const generated = run.addOutputDirectoryArg(b.fmt("{s}-assets", .{package.stem}));
    run.addDirectoryArg(b.path(package.dir));
    addDirectoryInputs(b, run, package.dir);
    return .{ .fpk = fpk, .generated = generated };
}

/// Stages a release, and returns the directory it was staged into.
///
/// The directory is **build-owned**: Zig hands the step a fresh one every time it runs, so
/// "start staging fresh" is a property of where the output goes rather than of something
/// this deletes (`distribution.md` §8).
pub fn stage(b: *std.Build, tools: Tools, description: Description) std.Build.LazyPath {
    const target = description.executable.rootModuleTarget();

    const run = b.addRunArtifact(tools.fstage);
    // Quiet, like the content compiler beside it: a build step that says something on
    // success is a build step Zig reports as having gone wrong. What was staged is in the
    // inventory, which is a better place for it than a line in a log.
    run.addArg("--quiet");
    run.addArg("--out");
    const out = run.addOutputDirectoryArg(description.product_name);

    run.addArg("--executable");
    run.addFileArg(description.executable.getEmittedBin());
    run.addArgs(&.{ "--executable-name", description.executable_name orelse description.executable.name });
    run.addArgs(&.{ "--product", description.product_name });
    run.addArgs(&.{ "--version", description.product_version });
    run.addArgs(&.{ "--build", description.build_number });
    run.addArgs(&.{ "--revision", description.revision orelse "local" });
    run.addArgs(&.{ "--target-os", @tagName(target.os.tag) });
    run.addArgs(&.{ "--max-files", b.fmt("{d}", .{description.limits.max_files}) });
    run.addArgs(&.{ "--max-total-bytes", b.fmt("{d}", .{description.limits.max_total_bytes}) });

    run.addArgs(&.{ "--license-id", description.license_id });
    run.addArg("--license");
    run.addFileArg(description.license_file);
    if (description.notice_file) |notice| {
        run.addArg("--notice");
        run.addFileArg(notice);
    }
    run.addArg("--licenses");
    run.addDirectoryArg(b.path(description.licenses_dir));
    // The recorded entries are read file by file, so each one has to be an input in its own
    // right: editing a license and restaging must not produce yesterday's attribution.
    addDirectoryInputs(b, run, description.licenses_dir);

    for (description.packages) |package| {
        const compiled = compilePackage(b, tools.fpack, package);
        run.addArgs(&.{ "--package", package.stem });
        run.addArg("--fpk");
        run.addFileArg(compiled.fpk);
        run.addArg("--source-root");
        run.addDirectoryArg(b.path(package.dir));
        run.addArg("--generated-root");
        run.addDirectoryArg(compiled.generated);
        if (package.notice) |notice| {
            run.addArg("--package-notice");
            run.addFileArg(notice);
        }
        // A directory argument creates the dependency and passes the path; it does not put
        // the directory's contents in the step's cache key. Without this, editing a `.wav`
        // would leave the previous release staged and nobody would be told.
        addDirectoryInputs(b, run, package.dir);
    }

    for (description.extra_files) |extra| {
        run.addArg("--extra");
        run.addPrefixedFileArg(b.fmt("{s}=", .{extra.staged}), extra.source);
    }

    return out;
}

/// Adds every file under `dir` as an input to `run`, so that editing one re-runs it.
///
/// Walked at configure time, which happens on every build, so a file *added* since the last
/// build is picked up as well as a file changed. A directory that cannot be read is left
/// with no inputs rather than failing the configure: the step itself will report the
/// problem, with the path, in the one place that knows why it was reading it.
pub fn addDirectoryInputs(b: *std.Build, run: *std.Build.Step.Run, dir: []const u8) void {
    const io = b.graph.io;
    var handle = b.build_root.handle.openDir(io, dir, .{ .iterate = true }) catch return;
    defer handle.close(io);

    var walker = handle.walk(b.allocator) catch return;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        run.addFileInput(b.path(b.pathJoin(&.{ dir, entry.path })));
    }
}
