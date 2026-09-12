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
//! const staged = foundry.release.stage(b, foundry.release.Tools.fromDependency(dep), .{
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
/// Where an application's icon lands inside the bundle. Fixed rather than derived from the
/// source file's name, so the plist and the staged path cannot drift apart.
pub const icon_staged_name = "AppIcon.icns";

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
    /// A nested Mach-O that must be signed before the outer application. Declare nested
    /// code deepest-first. Ordinary resources leave this false.
    macos_code: bool = false,
    /// The exact loader-relative spelling `otool -L` reports for this bundled dependency.
    /// Null means this extra is not admitted as a Mach-O dependency of the main executable.
    macos_load_path: ?[]const u8 = null,
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
    minimum_macos_version: []const u8 = "26.0",
    executable: *std.Build.Step.Compile,
    /// What the executable is called in the release. Defaults to the artifact's name.
    executable_name: ?[]const u8 = null,
    /// The application's macOS icon, staged as `Contents/Resources/AppIcon.icns` and named
    /// in the generated plist. **Supplied by the application, like its name and bundle ID.**
    /// Foundry's own mark is for Foundry's own artifacts; a game wearing the engine's icon
    /// would be telling a player something untrue (ADR-0034). Null ships no icon.
    icon: ?std.Build.LazyPath = null,
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

/// The programs a release is staged and inspected with.
///
/// `fpack` is run on the **host**, because it is a program and a cross-built one cannot be
/// executed here (`distribution.md` §8). `stage` checks that before running anything.
pub const Tools = struct {
    fpack: *std.Build.Step.Compile,
    fstage: std.Build.LazyPath,
    fmacos_verify: std.Build.LazyPath,

    pub fn fromDependency(dep: *std.Build.Dependency) Tools {
        return .{
            .fpack = dep.artifact("fpack"),
            // Build-only tools are exported as paths rather than installed into the
            // developer prefix. A dependency can still run them, while `zig build` does
            // not acquire programs nobody asked it to install.
            .fstage = dep.namedLazyPath("fstage"),
            .fmacos_verify = dep.namedLazyPath("fmacos-verify"),
        };
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
    return stageWithLayout(b, tools, description, false);
}

fn stageWithLayout(
    b: *std.Build,
    tools: Tools,
    description: Description,
    macos_bundle: bool,
) std.Build.LazyPath {
    const target = description.executable.rootModuleTarget();

    const run = addRunTool(b, tools.fstage, "fstage");
    // Quiet, like the content compiler beside it: a build step that says something on
    // success is a build step Zig reports as having gone wrong. What was staged is in the
    // inventory, which is a better place for it than a line in a log.
    run.addArg("--quiet");
    run.addArg("--out");
    const out = run.addOutputDirectoryArg(if (macos_bundle)
        b.fmt("{s}.app", .{description.product_name})
    else
        description.product_name);

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
    if (macos_bundle) {
        run.addArgs(&.{ "--macos-bundle", "--bundle-id", description.bundle_id });
        run.addArgs(&.{ "--minimum-macos-version", description.minimum_macos_version });
        if (description.icon) |icon| {
            // Staged like any other declared file, then named in the plist. The stager
            // refuses the pair if the name and the file ever disagree.
            run.addArg("--extra");
            run.addPrefixedFileArg(icon_staged_name ++ "=", icon);
            run.addArgs(&.{ "--icon-file", icon_staged_name });
        }
    }

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

/// The two signing profiles are intentionally different operations. A local build uses an
/// ad-hoc identity and no timestamp; a public build uses an operator-supplied Developer ID
/// identity, hardened runtime and Apple's timestamp service (`distribution.md` §11).
pub const MacosSigningProfile = union(enum) {
    local,
    developer_id: []const u8,
};

/// Outputs of the macOS packaging gates. Symbols remain beside the player artifact rather
/// than inside it, and `ready` is the gate an install/copy step must depend on.
pub const MacosArtifacts = struct {
    app: std.Build.LazyPath,
    symbols: std.Build.LazyPath,
    zip: std.Build.LazyPath,
    ready: *std.Build.Step,
};

/// Builds, inspects, signs and zips one macOS application.
///
/// The unsigned payload is still produced by `fstage`; it receives a layout flag rather than
/// growing a second content-packaging implementation. Apple tools are deliberately visible
/// build steps, and their text answers pass through `fmacos-verify` so a leaked host path or
/// mismatched dSYM is a hard failure rather than advisory output.
pub fn macosApplication(
    b: *std.Build,
    tools: Tools,
    description: Description,
    profile: MacosSigningProfile,
) MacosArtifacts {
    const executable_name = description.executable_name orelse description.executable.name;
    const app = stageWithLayout(b, tools, description, true);
    const executable = app.path(b, b.fmt("Contents/MacOS/{s}", .{executable_name}));
    const plist = app.path(b, "Contents/Info.plist");

    const plist_lint = b.addSystemCommand(&.{ "/usr/bin/plutil", "-lint" });
    plist_lint.addFileArg(plist);

    const dependencies = b.addSystemCommand(&.{ "/usr/bin/otool", "-L" });
    dependencies.addFileArg(executable);
    const dependency_text = dependencies.captureStdOut(.{ .basename = "otool-dependencies.txt" });

    const make_symbols = b.addSystemCommand(&.{"/usr/bin/dsymutil"});
    make_symbols.addFileArg(executable);
    make_symbols.addArg("-o");
    const symbols = make_symbols.addOutputDirectoryArg(b.fmt("{s}.app.dSYM", .{description.product_name}));

    const binary_uuid = b.addSystemCommand(&.{ "/usr/bin/dwarfdump", "--uuid" });
    binary_uuid.addFileArg(executable);
    const binary_uuid_text = binary_uuid.captureStdOut(.{ .basename = "binary-uuid.txt" });

    const symbols_uuid = b.addSystemCommand(&.{ "/usr/bin/dwarfdump", "--uuid" });
    symbols_uuid.addDirectoryArg(symbols);
    const symbols_uuid_text = symbols_uuid.captureStdOut(.{ .basename = "symbols-uuid.txt" });

    const inspect = addRunTool(b, tools.fmacos_verify, "fmacos-verify");
    inspect.addArg("--dependencies");
    inspect.addFileArg(dependency_text);
    inspect.addArg("--binary-uuid");
    inspect.addFileArg(binary_uuid_text);
    inspect.addArg("--symbols-uuid");
    inspect.addFileArg(symbols_uuid_text);
    for (description.extra_files) |extra| {
        if (extra.macos_load_path) |load_path| inspect.addArgs(&.{ "--bundled", load_path });
    }
    inspect.step.dependOn(&plist_lint.step);

    // Nested code is signed deepest-first in the order the application declares it, then
    // the outer bundle seals its final resources. The samples have no nested code; the
    // declaration exists because a reusable game helper may explicitly stage one.
    var previous: *std.Build.Step = &inspect.step;
    for (description.extra_files) |extra| {
        if (!extra.macos_code) continue;
        const nested = app.path(b, b.fmt("Contents/Resources/{s}", .{extra.staged}));
        const sign_nested = codesign(b, profile, nested, false);
        sign_nested.step.dependOn(previous);
        previous = &sign_nested.step;
    }

    const sign_app = codesign(b, profile, app, true);
    sign_app.step.dependOn(previous);

    const verify_signature = b.addSystemCommand(&.{
        "/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2",
    });
    verify_signature.addDirectoryArg(app);
    verify_signature.step.dependOn(&sign_app.step);
    _ = verify_signature.captureStdErr(.{ .basename = "codesign-verify.txt" });

    const describe_signature = b.addSystemCommand(&.{ "/usr/bin/codesign", "--display", "--verbose=4" });
    describe_signature.addDirectoryArg(app);
    describe_signature.step.dependOn(&verify_signature.step);
    _ = describe_signature.captureStdErr(.{ .basename = "codesign-details.txt" });

    const zip = b.addSystemCommand(&.{ "/usr/bin/ditto", "-c", "-k", "--keepParent" });
    zip.addDirectoryArg(app);
    const suffix = switch (profile) {
        .local => "local",
        .developer_id => "notarization-submission",
    };
    const archive = zip.addOutputFileArg(b.fmt("{s}-{s}.zip", .{ description.product_name, suffix }));
    zip.step.dependOn(&describe_signature.step);

    return .{ .app = app, .symbols = symbols, .zip = archive, .ready = &zip.step };
}

/// Runs a build-only executable exported by a Foundry dependency as a `LazyPath`.
fn addRunTool(b: *std.Build, executable: std.Build.LazyPath, name: []const u8) *std.Build.Step.Run {
    const run = std.Build.Step.Run.create(b, b.fmt("run {s}", .{name}));
    run.addFileArg(executable);
    return run;
}

fn codesign(
    b: *std.Build,
    profile: MacosSigningProfile,
    artifact: std.Build.LazyPath,
    directory: bool,
) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ "/usr/bin/codesign", "--force" });
    switch (profile) {
        .local => run.addArgs(&.{ "--sign", "-", "--timestamp=none" }),
        .developer_id => |identity| run.addArgs(&.{ "--options", "runtime", "--timestamp", "--sign", identity }),
    }
    if (directory) run.addDirectoryArg(artifact) else run.addFileArg(artifact);
    return run;
}

/// Submits an explicitly Developer-ID-signed archive, staples the accepted ticket, applies
/// the distribution verification gates, and creates the final player zip.
///
/// This helper performs network and Keychain operations only when the caller attaches its
/// `ready` step to an explicitly requested build step. The profile names credentials already
/// stored by `notarytool`; no password or API key crosses the build description.
pub fn notarizeMacos(
    b: *std.Build,
    description: Description,
    signed: MacosArtifacts,
    keychain_profile: []const u8,
) MacosArtifacts {
    const submit = b.addSystemCommand(&.{ "xcrun", "notarytool", "submit" });
    submit.addFileArg(signed.zip);
    submit.addArgs(&.{ "--keychain-profile", keychain_profile, "--wait" });
    submit.step.dependOn(signed.ready);

    const staple = b.addSystemCommand(&.{ "xcrun", "stapler", "staple" });
    staple.addDirectoryArg(signed.app);
    staple.step.dependOn(&submit.step);

    const validate_ticket = b.addSystemCommand(&.{ "xcrun", "stapler", "validate" });
    validate_ticket.addDirectoryArg(signed.app);
    validate_ticket.step.dependOn(&staple.step);

    const verify_signature = b.addSystemCommand(&.{
        "/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2",
    });
    verify_signature.addDirectoryArg(signed.app);
    verify_signature.step.dependOn(&staple.step);
    _ = verify_signature.captureStdErr(.{ .basename = "notarized-codesign-verify.txt" });

    const assess = b.addSystemCommand(&.{
        "/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=4",
    });
    assess.addDirectoryArg(signed.app);
    assess.step.dependOn(&validate_ticket.step);
    assess.step.dependOn(&verify_signature.step);
    _ = assess.captureStdErr(.{ .basename = "gatekeeper-assessment.txt" });

    // The submission zip predates the ticket. Nothing mutates the app after this final zip.
    const final_zip = b.addSystemCommand(&.{ "/usr/bin/ditto", "-c", "-k", "--keepParent" });
    final_zip.addDirectoryArg(signed.app);
    const archive = final_zip.addOutputFileArg(b.fmt("{s}.zip", .{description.product_name}));
    final_zip.step.dependOn(&assess.step);

    return .{ .app = signed.app, .symbols = signed.symbols, .zip = archive, .ready = &final_zip.step };
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
