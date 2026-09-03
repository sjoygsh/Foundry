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

    // L2 — Metal/Vulkan/D3D live ONLY here (ADR-0003).
    .{ .name = "rhi", .deps = &.{ "core", "platform" } },

    // L4 — the engine loop and subsystem lifecycle. Gains dependencies as the layers
    // between it and `platform` arrive; it is allowed to see all of them (ADR-0007).
    .{ .name = "app", .deps = &.{ "core", "platform", "rhi" } },

    // Added as each is implemented. The rest of the graph from ADR-0007 is:
    //   L1  data       -> core
    //   L2  asset      -> core, data, platform
    //   L3  render2d   -> core, rhi, asset
    //   L3  scene      -> core, data, asset
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
    sandbox_mod.addImport("core", modules.get("core").?);
    sandbox_mod.addImport("platform", platform_module);
    sandbox_mod.addImport("rhi", modules.get("rhi").?);

    const sandbox = b.addExecutable(.{ .name = "sandbox", .root_module = sandbox_mod });
    b.installArtifact(sandbox);

    const run_sandbox = b.addRunArtifact(sandbox);
    run_sandbox.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_sandbox.addArgs(args);
    b.step("run", "Build and run samples/sandbox").dependOn(&run_sandbox.step);

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

    for (layering) |spec| {
        const unit_tests = b.addTest(.{ .root_module = modules.get(spec.name).? });
        check_step.dependOn(&unit_tests.step);

        const run = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run.step);
    }
}
