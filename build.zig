const std = @import("std");

/// The module layering from ADR-0007, expressed as data.
///
/// This table *is* the enforcement mechanism for Invariant I7. A module can only
/// `@import` what is listed in its `deps`, because that is all the build graph grants
/// it — so a layering violation is a compile error naming the offending import, not a
/// code review finding. Zig additionally refuses to import a file outside a module's
/// own directory, which closes the obvious workaround.
///
/// One nuance, verified rather than assumed: the error fires at the point of *use*.
/// Zig analyses top-level declarations lazily, so an undeclared import that nothing
/// references is never resolved and compiles clean. That is harmless — a dead import
/// grants no access — but it means the guarantee is "you cannot use what you were not
/// given", not "you cannot type it".
///
/// Dependencies point downward only. Modules are declared in dependency order.
/// If a new subsystem does not fit here, that is a signal to re-examine the subsystem
/// or the layering explicitly — not to add a sideways dependency.
const Module = struct {
    name: []const u8,
    deps: []const []const u8 = &.{},
};

const layering = [_]Module{
    // L0 — std only.
    .{ .name = "core" },

    // L1 — SDL3 lives ONLY here (ADR-0002).
    .{ .name = "platform", .deps = &.{"core"} },

    // L1 — schemas, content, packages (docs/design/content-schemas.md). Note what it
    // does *not* get, and that this is the interesting part: `platform`. `data` cannot
    // open a file. The parser is handed bytes and resolves `@import` through a
    // caller-supplied callback, which makes the whole content pipeline a pure function —
    // hermetically testable, deterministic (I9), and safe on untrusted input without
    // wondering what it might read. That fell out of ADR-0007 rather than being designed.
    .{ .name = "data", .deps = &.{"core"} },

    // L1 — collision, not dynamics (ADR-0022, docs/design/tilemaps-and-collision.md).
    // `core` alone, and the shortness of that list is the design: no entities, because
    // `scene` is above it; no content, because a grid's arrays are borrowed from whoever
    // loaded them; no `platform`, so there is no clock to read (I9 rule 4) and nothing to
    // open. A collision module that needed any of the three would be announcing that it had
    // grown into a physics engine.
    .{ .name = "physics2d", .deps = &.{"core"} },

    // L2 — Metal/Vulkan/D3D live ONLY here (ADR-0003).
    .{ .name = "rhi", .deps = &.{ "core", "platform" } },

    // L2 — assets. The module with both a filesystem and the content model, which makes
    // it the seam between them: `data` cannot open a file and `render2d` should not, so
    // opening files on content's behalf is this module's job (docs/design/assets.md).
    .{ .name = "asset", .deps = &.{ "core", "data", "platform" } },

    // L3 — the game-facing 2D renderer (docs/design/render2d.md). Note what it does
    // *not* get: `platform`. The renderer neither opens files nor reads input; `asset`
    // hands it decoded images and the game hands it draw calls.
    .{ .name = "render2d", .deps = &.{ "core", "rhi", "asset" } },

    // L3 — entities, components, systems and world state (docs/design/entity-storage.md).
    // ADR-0007 allows `asset` as well; it is not taken, because nothing here acquires one
    // — a `sprite` component holds a texture's content id and the rendering system above
    // resolves it. A dependency a module does not use is a claim the build cannot check.
    //
    // What it does *not* get is the interesting part again: no `platform`, so a simulation
    // can read neither a clock nor an input device, and no filesystem to save a world
    // through. Both fall out of the layering, and both are what I9 would have asked for
    // anyway.
    .{ .name = "scene", .deps = &.{ "core", "data" } },

    // L4 — the engine loop and subsystem lifecycle. Gains dependencies as the layers
    // between it and `platform` arrive; it is allowed to see all of them (ADR-0007).
    // `data` and `asset` joined at M3 step 9: the engine loads package zero and mounts it
    // (I3). Not `render2d` — the game owns its renderer and registers the texture loader
    // from there, so the engine needs no opinion about what a texture is.
    .{ .name = "app", .deps = &.{ "core", "data", "platform", "rhi", "asset" } },

    // Added as each is implemented. The rest of the graph from ADR-0007 is:
    //   L5  abi        -> app             (M7)
};

/// Which platform backend to build against.
///
/// A compile-time choice rather than a runtime one: nobody swaps platform backends
/// mid-run, and a vtable would cost an indirect call on every input poll and clock
/// read for no benefit. A backend is an engine port, and ports are compile-time
/// decisions — deliberately unlike component types and asset loaders, which I6 requires
/// be runtime-registered so that mods can add them.
const PlatformBackend = enum {
    /// Headless. No window, no real input, a synthetic clock. The default, because it
    /// needs no display server and no dependency, so `zig build test` works anywhere.
    null,
    /// SDL3. The backend that actually opens a window (ADR-0002).
    sdl3,
};

/// Which graphics backend to build against.
///
/// `metal` joins this list at M1 (ADR-0003). Vulkan and D3D12 are deliberately
/// unscheduled: they start when there is a reason — shipping Windows or Linux, or
/// validating the RHI against a second API — not when the roadmap reaches them.
const RhiBackend = enum {
    /// Draws nothing and validates everything. Not scaffolding: it is the agreed
    /// mitigation for designing an abstraction against a single graphics API.
    null,
    /// Metal, through the Objective-C shim (ADR-0012). macOS only, and the only backend
    /// that puts pixels on a screen.
    metal,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const platform_backend = b.option(
        PlatformBackend,
        "platform",
        "Platform backend to build against (default: null, headless)",
    ) orelse .sdl3;

    // Passed as a string rather than as the enum: `addOption` would emit its own
    // definition of the enum type, which would not be the same type as the one
    // `platform` declares. The name is converted back at comptime there, so an
    // unrecognised value is still a compile error naming the offender.
    const rhi_backend = b.option(
        RhiBackend,
        "rhi",
        "Graphics backend to build against (default: null, which validates and draws nothing)",
    ) orelse .null;

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "platform_backend", @tagName(platform_backend));
    build_options.addOption([]const u8, "rhi_backend", @tagName(rhi_backend));
    const build_options_module = build_options.createModule();

    var modules: std.StringHashMapUnmanaged(*std.Build.Module) = .empty;

    for (layering) |spec| {
        const mod = b.addModule(spec.name, .{
            .root_source_file = b.path(b.fmt("engine/src/{s}/root.zig", .{spec.name})),
            .target = target,
            .optimize = optimize,
        });

        for (spec.deps) |dep_name| {
            const dep = modules.get(dep_name) orelse std.debug.panic(
                "module '{s}' depends on '{s}', which is not declared earlier in `layering`",
                .{ spec.name, dep_name },
            );
            mod.addImport(dep_name, dep);
        }

        modules.put(b.allocator, spec.name, mod) catch @panic("OOM");
    }

    // Build configuration reaches exactly the module that needs it. This is not a
    // layering exception: `build_options` carries no engine code, and granting it
    // broadly would let build-time configuration leak into modules whose behaviour is
    // supposed to be decided by their inputs alone.
    const platform_module = modules.get("platform").?;
    platform_module.addImport("build_options", build_options_module);

    const rhi_module = modules.get("rhi").?;
    rhi_module.addImport("build_options", build_options_module);

    // **The only place Metal enters the build graph**, mirroring how SDL enters it below:
    // the Objective-C shim, its header's include path, and the three frameworks are attached
    // to `rhi` and to nothing else, so no module above L2 can name a Metal type even by
    // accident (I7, ADR-0003).
    //
    // ARC is not optional here. It is the reason the bridge is Objective-C rather than
    // `objc_msgSend` calls from Zig (ADR-0012): object lifetime stays in the language that
    // handles it correctly.
    if (rhi_backend == .metal) {
        if (target.result.os.tag != .macos) {
            std.debug.panic(
                "-Drhi=metal is macOS only; target is '{s}'. Use -Drhi=null to cross-compile.",
                .{@tagName(target.result.os.tag)},
            );
        }
        const metal_dir = "engine/src/rhi/backends/metal";
        rhi_module.addIncludePath(b.path(metal_dir));
        rhi_module.addCSourceFile(.{
            .file = b.path(metal_dir ++ "/metal_shim.m"),
            .flags = &.{ "-fobjc-arc", "-Wall", "-Wextra" },
        });
        rhi_module.link_libc = true;
        rhi_module.linkSystemLibrary("objc", .{});
        rhi_module.linkFramework("Metal", .{});
        rhi_module.linkFramework("QuartzCore", .{});
        rhi_module.linkFramework("Foundation", .{});
    }

    // **The only place SDL enters the build graph.** I7 is enforced here as much as by
    // the layering table above: no other module is linked against it, so no other
    // module can name an SDL type even by accident (ADR-0002).
    //
    // `lazyDependency` rather than `dependency` because the manifest marks it lazy, so
    // a null-backend build must not require it. It returns an optional; null means the
    // package still needs fetching and the build will re-run itself.
    if (platform_backend == .sdl3) {
        if (b.lazyDependency("sdl", .{ .target = target, .optimize = optimize })) |sdl| {
            platform_module.linkLibrary(sdl.artifact("SDL3"));
        }
    }

    // The renderer's own shader, compiled by the build and embedded in the module
    // (ADR-0019). This is an *engine-owned* shader — one whose absence means the renderer
    // cannot draw — so it is machinery rather than content, and it does not wait for the
    // content system. Mod-authored and content-owned shaders remain assets per ADR-0015.
    //
    // Metal only, for the same reason as the sandbox's: `xcrun` is a macOS toolchain and a
    // null build must not require Xcode to exist.
    if (rhi_backend == .metal) {
        modules.get("render2d").?.addAnonymousImport("sprite_metallib", .{
            .root_source_file = metalLibrary(b, "sprite", &.{"engine/src/render2d/shaders/sprite.metal"}),
        });
    }

    // Samples are consumers of the engine, exactly as a game in its own repository
    // would be (ADR-0017): they depend on `app` and reach nothing that `app` does not
    // hand them. `samples/` holds the smallest thing that exercises a capability — when
    // one starts wanting features rather than demonstrating them, it has outgrown this
    // repository.
    const sandbox_mod = b.createModule(.{
        .root_source_file = b.path("samples/sandbox/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    sandbox_mod.addImport("app", modules.get("app").?);
    sandbox_mod.addImport("asset", modules.get("asset").?);
    sandbox_mod.addImport("core", modules.get("core").?);
    // A game reads its own content, which means naming `data`'s types. It gets the module
    // the same way it gets every other one: as a consumer of the engine, not as a member
    // of the layering.
    sandbox_mod.addImport("data", modules.get("data").?);
    sandbox_mod.addImport("platform", platform_module);
    // Collision is the game's to run, not the engine's: `app` owns the frame, and when to
    // move a body and what to do about what it hit is gameplay. So the sample names
    // `physics2d` for itself, exactly as it names `scene`.
    sandbox_mod.addImport("physics2d", modules.get("physics2d").?);
    sandbox_mod.addImport("render2d", modules.get("render2d").?);
    sandbox_mod.addImport("rhi", modules.get("rhi").?);
    // A game owns its world and defines its own component types, so it names `scene`
    // directly rather than reaching it through `app` — which does not have it. `app` drives
    // the frame; what the frame simulates is the game's.
    sandbox_mod.addImport("scene", modules.get("scene").?);

    // The shader the sandbox draws with, compiled by the build and embedded in the
    // executable. Only under Metal: `xcrun` is a macOS toolchain, and a null build must not
    // require Xcode to be installed at all.
    //
    // Embedding is deliberately the *simple* answer, not the final one. Loading a shader by
    // content ID needs the asset system, which is M3, and inventing half of one here to
    // avoid an `@embedFile` would prejudge the package-zero question that milestone owes an
    // answer to. What M1 is obliged to prove is that `createShaderModule` has a producer.
    if (rhi_backend == .metal) {
        sandbox_mod.addAnonymousImport("quad_metallib", .{
            .root_source_file = metalLibrary(b, "quad", &.{"samples/sandbox/shaders/quad.metal"}),
        });
    }

    const sandbox = b.addExecutable(.{ .name = "sandbox", .root_module = sandbox_mod });
    b.installArtifact(sandbox);

    // `tools/fpack` — the content compiler (ADR-0011). A consumer of the engine's modules
    // like a sample is, not a privileged member of the layering: it gets `data` because it
    // compiles content, `platform` because `data` cannot open a file, and `asset` because
    // that is where the asset kinds a path can derive are declared. It does not get `rhi`
    // or `render2d`, and a content compiler that needed a GPU would be a design mistake
    // announcing itself.
    const fpack_mod = b.createModule(.{
        .root_source_file = b.path("tools/fpack/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    fpack_mod.addImport("asset", modules.get("asset").?);
    fpack_mod.addImport("core", modules.get("core").?);
    fpack_mod.addImport("data", modules.get("data").?);
    fpack_mod.addImport("platform", platform_module);
    // And `scene`, for the same reason it gets `asset`: that is where the record types for
    // entity templates and scenes are declared, and content using one must not have to
    // declare an engine-owned schema itself.
    fpack_mod.addImport("scene", modules.get("scene").?);

    const fpack = b.addExecutable(.{ .name = "fpack", .root_module = fpack_mod });
    b.installArtifact(fpack);

    // Content packages, compiled by `fpack` and installed beside the executable.
    //
    // **The base game is package zero and there is no privileged path** (I3): the engine's
    // own content is compiled by the same tool, in the same format, and loaded by the same
    // call a mod's would be. `content/core` is the engine's; the sample keeps its own,
    // because a game has its own package and `samples/sandbox` is the reference for what a
    // game looks like (ADR-0017).
    //
    // The order here is the load order, which is what the engine is handed. Discovering
    // one — mod manifests, dependency resolution — is M7; `data` consumes a load order and
    // does not compute one.
    const ContentPackage = struct {
        /// The package's content id, which is its identity.
        id: []const u8,
        /// Where its sources are in this repository.
        dir: []const u8,
        /// What it is called under `<prefix>/content`. A location, never identity
        /// (ADR-0021) — the compiled package states its own id and the store checks it.
        stem: []const u8,
    };
    const content_packages = [_]ContentPackage{
        .{ .id = "foundry:core", .dir = "content/core", .stem = "core" },
        .{ .id = "sandbox:content", .dir = "samples/sandbox/content", .stem = "sandbox" },
    };

    // **Only when the build target can run here.** `fpack` is built for the target like
    // everything else, so a cross build produces a compiler this machine cannot execute.
    // `zig build check` — the portability obligation from ADR-0008 — does not install and
    // so does not reach this; cross-*installing* is not a workflow Foundry has yet. When it
    // is one, the answer is a host-targeted `fpack`, not a weaker check here.
    if (target.query.isNative()) {
        for (content_packages) |pkg| {
            const compile_content = b.addRunArtifact(fpack);
            compile_content.addArgs(&.{ "--quiet", "--name", pkg.id, "--out" });
            const compiled = compile_content.addOutputFileArg(b.fmt("{s}.fpk", .{pkg.stem}));
            // Assets with an authoring format of their own — a tile grid — are compiled too,
            // and land here rather than in the package directory: what a person wrote and
            // what a tool produced never share a tree (`tilemaps-and-collision.md` §9).
            compile_content.addArg("--assets-out");
            const generated = compile_content.addOutputDirectoryArg(b.fmt("{s}-assets", .{pkg.stem}));
            compile_content.addDirectoryArg(b.path(pkg.dir));
            // And every file under it as an input, which is what actually makes the build
            // re-run `fpack` when a package changes. A directory argument creates the
            // dependency and passes the path; it does **not** put the directory's contents
            // in the Run step's cache key, so without this an edited `.fdt` leaves a stale
            // `.fpk` installed and the game loads yesterday's content.
            addDirectoryInputs(b, compile_content, pkg.dir);

            b.getInstallStep().dependOn(&b.addInstallFileWithDir(
                compiled,
                .prefix,
                b.fmt("content/{s}.fpk", .{pkg.stem}),
            ).step);

            // The sources go beside it, because an asset record names where its bytes are
            // and the registry reads them at load (`assets.md` §4). It is also what step
            // 10's hot reload will watch.
            b.getInstallStep().dependOn(&b.addInstallDirectory(.{
                .source_dir = b.path(pkg.dir),
                .install_dir = .prefix,
                .install_subdir = b.fmt("content/{s}", .{pkg.stem}),
            }).step);

            // And the compiled assets over the top of them, into the one tree the registry
            // mounts. They are disjoint from the sources — a `.grid` stays a source and the
            // `.fgrid` beside it is what an asset record names — so the two installs never
            // write the same file.
            b.getInstallStep().dependOn(&b.addInstallDirectory(.{
                .source_dir = generated,
                .install_dir = .prefix,
                .install_subdir = b.fmt("content/{s}", .{pkg.stem}),
            }).step);
        }
    }

    const run_sandbox = b.addRunArtifact(sandbox);
    run_sandbox.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_sandbox.addArgs(args);
    b.step("run", "Build and run samples/sandbox").dependOn(&run_sandbox.step);

    const run_fpack = b.addRunArtifact(fpack);
    run_fpack.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_fpack.addArgs(args);
    b.step("fpack", "Build and run tools/fpack (pass arguments after --)").dependOn(&run_fpack.step);

    // Unit tests are colocated in source (project convention). One test binary per
    // module, all hung off `zig build test`.
    const test_step = b.step("test", "Run all unit tests");

    // Compiling without running is what makes the cross-compilation obligation
    // checkable: ADR-0008 requires the non-rendering modules to build for Windows and
    // Linux every milestone, with no obligation to *run* them there until a backend
    // exists. `zig build check -Dtarget=...` is that check.
    const check_step = b.step("check", "Compile everything without running it");

    // Samples are part of the per-milestone portability obligation too: a sample that
    // stopped cross-compiling would be a milestone rule broken (ROADMAP), and finding
    // that out at release time is the expensive way.
    check_step.dependOn(&sandbox.step);
    check_step.dependOn(&fpack.step);

    for (layering) |spec| {
        const unit_tests = b.addTest(.{ .root_module = modules.get(spec.name).? });
        check_step.dependOn(&unit_tests.step);

        const run = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run.step);
    }

    // Tools are tested like modules are. `fpack`'s tests reach a real filesystem, which is
    // the point of them: everything below it is already hermetic, and what is left to prove
    // is exactly the part that touches a disk.
    const fpack_tests = b.addTest(.{ .root_module = fpack_mod });
    check_step.dependOn(&fpack_tests.step);
    test_step.dependOn(&b.addRunArtifact(fpack_tests).step);

    // Integration tests (CLAUDE.md §4.5): what no single module can test alone, because
    // testing it means standing above two of them. `render2d` registering a texture loader
    // into `asset` is the first: the modules deliberately cannot see each other — `asset`
    // is below and `render2d` has no `data` — so the seam between them is only reachable
    // from a consumer that has both, which is what `app` and a game are.
    const integration_mod = b.createModule(.{
        .root_source_file = b.path("engine/tests/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    for ([_][]const u8{ "core", "data", "platform", "physics2d", "rhi", "asset", "render2d", "scene" }) |name| {
        integration_mod.addImport(name, modules.get(name).?);
    }

    const integration_tests = b.addTest(.{ .root_module = integration_mod });
    check_step.dependOn(&integration_tests.step);
    test_step.dependOn(&b.addRunArtifact(integration_tests).step);
}

/// Adds every file under `dir` as an input to `run`, so that editing one re-runs it.
///
/// Walked at configure time, which happens on every build, so a file *added* since the last
/// build is picked up as well as a file changed. A directory that cannot be read is left
/// with no inputs rather than failing the configure: the step itself will report the
/// problem, with the path, in the one place that knows why it was reading it.
fn addDirectoryInputs(b: *std.Build, run: *std.Build.Step.Run, dir: []const u8) void {
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

/// Compiles MSL into a `.metallib`, per ADR-0015: `xcrun metal` turns each source into an
/// `.air`, then `xcrun metallib` links them together.
///
/// **Always through `xcrun`, never a hardcoded path** (ADR-0014). The Metal toolchain is an
/// on-demand component living on a versioned mount that moves between Xcode updates, so a
/// path recorded today is wrong after the next one.
///
/// This is also the concrete answer to ADR-0014's claim that Foundry needs no separate build
/// tool: a shader compiler is an ordinary build step with declared inputs and outputs, so
/// Zig caches it and rebuilds it exactly when a source changes. No Make, no Ninja, no script.
///
/// Returns the linked library as a `LazyPath`, which the consumer decides what to do with.
/// Today the sandbox embeds it; from M3 shaders are assets loaded through the content system
/// (ADR-0015), and this step becomes what `tools/fpack` invokes rather than what a sample does.
fn metalLibrary(b: *std.Build, name: []const u8, sources: []const []const u8) std.Build.LazyPath {
    const link = b.addSystemCommand(&.{ "xcrun", "metallib" });

    for (sources) |source| {
        const compile = b.addSystemCommand(&.{ "xcrun", "metal", "-c" });
        compile.addFileArg(b.path(source));
        // Line tables and embedded source, so an Xcode frame capture shows the shader that
        // actually ran rather than disassembly. Confirming frame capture works is part of
        // M1, and it is much less useful without these (ADR-0012).
        compile.addArgs(&.{ "-gline-tables-only", "-frecord-sources" });
        compile.addArg("-o");
        link.addFileArg(compile.addOutputFileArg(b.fmt("{s}.air", .{std.fs.path.stem(source)})));
    }

    link.addArg("-o");
    return link.addOutputFileArg(b.fmt("{s}.metallib", .{name}));
}
