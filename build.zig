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

    // Added as each is implemented. The full graph from ADR-0007 is:
    //   L1  platform   -> core            (SDL3 lives ONLY here)
    //   L1  data       -> core
    //   L2  rhi        -> core, platform  (Metal/Vulkan/D3D live ONLY here)
    //   L2  asset      -> core, data, platform
    //   L3  render2d   -> core, rhi, asset
    //   L3  scene      -> core, data, asset
    //   L4  app        -> all of the above
    //   L5  abi        -> app             (M7)
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    // Unit tests are colocated in source (project convention). One test binary per
    // module, all hung off `zig build test`.
    const test_step = b.step("test", "Run all unit tests");

    // Compiling without running is what makes the cross-compilation obligation
    // checkable: ADR-0008 requires the non-rendering modules to build for Windows and
    // Linux every milestone, with no obligation to *run* them there until a backend
    // exists. `zig build check -Dtarget=...` is that check.
    const check_step = b.step("check", "Compile everything without running it");

    for (layering) |spec| {
        const unit_tests = b.addTest(.{ .root_module = modules.get(spec.name).? });
        check_step.dependOn(&unit_tests.step);

        const run = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run.step);
    }
}
