//! Environments by content ID: a compiled package to the renderer's cube and harmonics
//! (`docs/design/environment.md` §7.4, ADR-0083).
//!
//! `render3d.Content` reads `foundry:environment` records, decodes their faces through its own
//! loader, and prefilters them, on the calling thread when acquired and on the registry's
//! background pool when requested. These tests run over the real compiler, store, registry and
//! renderer, as `model_content.zig`'s do.

const std = @import("std");
const core = @import("core");
const platform = @import("platform");
const asset = @import("asset");
const render3d = @import("render3d");
const model_content = @import("model_content.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Stack = model_content.Stack;
const id = model_content.id;
const rgbaPng = @import("ui_theme.zig").rgbaPng;
const environment = asset.environment;

const records =
    \\foundry:texture demo:textures.face { source "textures/face.png" }
    \\foundry:texture demo:textures.wide { source "textures/wide.png" }
    \\foundry:texture demo:textures.data { source "textures/face.png" color_space "linear" }
    \\foundry:material demo:materials.plain {}
    \\foundry:environment demo:environments.sky {
    \\    kind "gradient"
    \\    zenith { r 0.2 g 0.4 b 1 l 900 }
    \\    horizon { r 0.8 g 0.85 b 1 l 1200 }
    \\    ground { r 0.3 g 0.25 b 0.2 l 300 }
    \\    size 16
    \\}
    \\foundry:environment demo:environments.box {
    \\    kind "faces"
    \\    faces [ demo:textures.face demo:textures.face demo:textures.face demo:textures.face demo:textures.face demo:textures.face ]
    \\    luminance 50
    \\    size 16
    \\}
    \\foundry:environment demo:environments.wide {
    \\    kind "faces"
    \\    faces [ demo:textures.wide demo:textures.wide demo:textures.wide demo:textures.wide demo:textures.wide demo:textures.wide ]
    \\    size 16
    \\}
    \\foundry:environment demo:environments.linear {
    \\    kind "faces"
    \\    faces [ demo:textures.data demo:textures.data demo:textures.data demo:textures.data demo:textures.data demo:textures.data ]
    \\    size 16
    \\}
    \\foundry:environment demo:environments.material {
    \\    kind "faces"
    \\    faces [ demo:textures.face demo:materials.plain demo:textures.face demo:textures.face demo:textures.face demo:textures.face ]
    \\    size 16
    \\}
;

fn widePng(gpa: Allocator) ![]u8 {
    var pixels: [32 * 16 * 4]u8 = @splat(200);
    return rgbaPng(gpa, 32, 16, &pixels);
}

fn environmentStack() !*Stack {
    const stack = try Stack.init(1);
    errdefer stack.deinit();
    const face = try model_content.checkerPng(stack.gpa, 32);
    defer stack.gpa.free(face);
    try stack.install("textures/face.png", face);
    const wide = try widePng(stack.gpa);
    defer stack.gpa.free(wide);
    try stack.install("textures/wide.png", wide);
    try stack.write("content.fdt", records);
    try stack.build();
    return stack;
}

/// What `prefilter` makes of the record as the store holds it, its faces decoded from `out`.
fn expected(stack: *Stack, which: []const u8) !environment.Prefiltered {
    const env = try environment.decode(stack.store.lookup(id(which)).?.fields);
    if (env.source == .gradient) return environment.prefilter(stack.gpa, env, &.{});
    const path = try platform.os.joinPath(stack.gpa, &.{ stack.out, "textures/face.png" });
    defer stack.gpa.free(path);
    const png = try stack.os.readFile(stack.gpa, path, 1 << 20);
    defer stack.gpa.free(png);
    var image = try asset.png.decode(stack.gpa, png, .{});
    defer image.deinit(stack.gpa);
    const faces: [6]environment.Face = @splat(.{ .image = image, .color_space = .srgb });
    return environment.prefilter(stack.gpa, env, &faces);
}

fn written(stack: *Stack, handle: render3d.EnvironmentHandle) environment.Harmonics {
    return stack.renderer.environments.getConst(handle).?.harmonics;
}

/// A frame that names `handle`, with nothing drawn: what the null backend checks is the bind.
fn frameWith(stack: *Stack, handle: render3d.EnvironmentHandle) !void {
    try stack.renderer.begin(.{
        .camera = .{ .vertical_fov = std.math.pi / 2.0, .near = 0.1, .far = 10 },
        .target_size = .{ .width = model_content.target_size, .height = model_content.target_size },
        .environment = handle,
    });
    try stack.finish(null);
}

test "an acquired environment is ready on return, its harmonics the prefilter's, and the same ID is the same handle" {
    const stack = try environmentStack();
    defer stack.deinit();
    for ([_][]const u8{ "demo:environments.sky", "demo:environments.box" }) |which| {
        const handle = try stack.content.acquireEnvironment(id(which));
        try testing.expectEqual(render3d.EnvironmentState.ready, (try stack.content.environmentState(handle)).?);
        try testing.expectEqual(@as(?bool, true), stack.renderer.environmentWritten(handle));
        var want = try expected(stack, which);
        defer want.deinit(stack.gpa);
        try testing.expectEqual(want.harmonics, written(stack, handle));
        try testing.expectEqual(want.levels, stack.renderer.environments.getConst(handle).?.levels);
        const again = try stack.content.acquireEnvironment(id(which));
        try testing.expect(again.eql(handle));
        stack.content.releaseEnvironment(again);
        try frameWith(stack, handle);
        stack.content.releaseEnvironment(handle);
        try testing.expectEqual(@as(?bool, null), stack.renderer.environmentWritten(handle));
    }
    try testing.expectEqual(@as(usize, 0), stack.violations());
}

test "an environment that cannot be made is refused by name and holds nothing" {
    const stack = try environmentStack();
    defer stack.deinit();
    try testing.expectError(error.EnvironmentNotFound, stack.content.acquireEnvironment(id("demo:environments.absent")));
    try testing.expectError(error.NotAnEnvironment, stack.content.acquireEnvironment(id("demo:materials.plain")));
    try testing.expectError(error.NotAnEnvironment, stack.content.requestEnvironment(id("demo:textures.face")));
    // A face not square, a face in linear light, a face that is a material: each said and refused.
    for ([_][]const u8{ "demo:environments.wide", "demo:environments.linear", "demo:environments.material" }) |which|
        try testing.expectError(error.InvalidEnvironmentRecord, stack.content.acquireEnvironment(id(which)));
    try testing.expectEqual(@as(u32, 0), stack.content.environments.count());
    try testing.expectEqual(@as(u32, 0), stack.renderer.environments.count());
    try testing.expectEqual(@as(?render3d.EnvironmentState, null), try stack.content.environmentState(.none));

    // Requested, the same refusals arrive as `failed`, and it lights nothing.
    const wide = try stack.content.requestEnvironment(id("demo:environments.wide"));
    defer stack.content.releaseEnvironment(wide);
    var state = (try stack.content.environmentState(wide)).?;
    for (0..8) |_| {
        if (state != .pending) break;
        _ = stack.assets.pump(stack.gpa, .{});
        state = (try stack.content.environmentState(wide)).?;
    }
    try testing.expectEqual(render3d.EnvironmentState.failed, state);
    try testing.expectEqual(@as(?bool, false), stack.renderer.environmentWritten(wide));
    try frameWith(stack, wide);
    try testing.expectEqual(@as(usize, 0), stack.violations());
}

const Order = enum { immediate, reversed, pool };

/// Everything `manual` holds run and pumped, so the registry has nothing in flight and its
/// executor may be swapped back.
fn drain(stack: *Stack, manual: *core.tasks.Manual) void {
    while (true) {
        while (manual.pending() > 0) manual.runLast();
        _ = stack.assets.pump(stack.gpa, .{});
        if (!stack.assets.busy() and manual.pending() == 0) return;
    }
}

fn tasksFor(order: Order, manual: *core.tasks.Manual, pool: *platform.Background) core.Tasks {
    return switch (order) {
        .immediate => core.tasks.immediate,
        .reversed => manual.tasks(),
        .pool => pool.tasks(),
    };
}

/// Runs what the registry and the prefilter wait for, one round at a time, as frames would.
fn settle(stack: *Stack, handle: render3d.EnvironmentHandle, order: Order, manual: *core.tasks.Manual, pool: *platform.Background) !render3d.EnvironmentState {
    for (0..16) |_| {
        switch (order) {
            .immediate => {},
            .reversed => while (manual.pending() > 0) manual.runLast(),
            .pool => pool.tasks().wait(),
        }
        _ = stack.assets.pump(stack.gpa, .{});
        const state = (try stack.content.environmentState(handle)).?;
        if (state != .pending) return state;
    }
    return error.TestUnexpectedResult;
}

test "a requested environment lights nothing until it settles, then what an acquired one does, in any completion order" {
    const stack = try environmentStack();
    defer stack.deinit();
    const pool = try stack.os.startBackground(stack.gpa, .{ .count = 2 });
    defer pool.deinit();
    var manual = try core.tasks.Manual.init(stack.gpa, 16);
    defer manual.deinit();

    for ([_][]const u8{ "demo:environments.sky", "demo:environments.box" }) |which| {
        var want = try expected(stack, which);
        defer want.deinit(stack.gpa);
        for ([_]Order{ .immediate, .reversed, .pool }) |order| {
            stack.assets.useTasks(tasksFor(order, &manual, pool));
            defer stack.assets.useTasks(core.tasks.immediate);
            const handle = try stack.content.requestEnvironment(id(which));
            if (order != .immediate) {
                try testing.expectEqual(render3d.EnvironmentState.pending, (try stack.content.environmentState(handle)).?);
                // A pending environment is not an error to name: it lights nothing.
                try testing.expectEqual(@as(?bool, false), stack.renderer.environmentWritten(handle));
                try frameWith(stack, handle);
            }
            try testing.expectEqual(render3d.EnvironmentState.ready, try settle(stack, handle, order, &manual, pool));
            try testing.expectEqual(want.harmonics, written(stack, handle));
            try frameWith(stack, handle);
            stack.content.releaseEnvironment(handle);
            _ = stack.assets.unloadWith(stack.gpa, render3d.loader.faceLoader());
        }
    }
    try testing.expectEqual(@as(usize, 0), stack.violations());
}

test "acquiring an environment still pending completes it on the calling thread" {
    const stack = try environmentStack();
    defer stack.deinit();
    var manual = try core.tasks.Manual.init(stack.gpa, 16);
    defer manual.deinit();
    stack.assets.useTasks(manual.tasks());
    defer stack.assets.useTasks(core.tasks.immediate);
    const requested = try stack.content.requestEnvironment(id("demo:environments.box"));
    defer stack.content.releaseEnvironment(requested);
    try testing.expectEqual(render3d.EnvironmentState.pending, (try stack.content.environmentState(requested)).?);
    const acquired = try stack.content.acquireEnvironment(id("demo:environments.box"));
    defer stack.content.releaseEnvironment(acquired);
    try testing.expect(acquired.eql(requested));
    try testing.expectEqual(render3d.EnvironmentState.ready, (try stack.content.environmentState(acquired)).?);
    drain(stack, &manual);
}

test "a reloaded face or record is prefiltered again behind the same handle, and a record gone keeps what it had" {
    const stack = try environmentStack();
    defer stack.deinit();
    const box = try stack.content.acquireEnvironment(id("demo:environments.box"));
    defer stack.content.releaseEnvironment(box);
    const sky = try stack.content.acquireEnvironment(id("demo:environments.sky"));
    defer stack.content.releaseEnvironment(sky);
    const before = written(stack, box);

    // A face's PNG edited on disk: the face reloads, and the next settle prefilters again.
    const other = try model_content.checkerPng(stack.gpa, 16);
    defer stack.gpa.free(other);
    var flipped = try asset.png.decode(stack.gpa, other, .{});
    defer flipped.deinit(stack.gpa);
    for (flipped.pixels, 0..) |*byte, i| {
        if (i % 4 != 3) byte.* = 255 - byte.*;
    }
    const edited = try rgbaPng(stack.gpa, 16, 16, flipped.pixels);
    defer stack.gpa.free(edited);
    try stack.writeUnder(stack.out, "textures/face.png", edited);
    _ = stack.assets.reloadChanged(stack.gpa);
    _ = stack.assets.pump(stack.gpa, .{});
    try testing.expectEqual(render3d.EnvironmentState.ready, (try stack.content.environmentState(box)).?);
    const reloaded = written(stack, box);
    try testing.expect(!std.mem.eql(u8, std.mem.asBytes(&before), std.mem.asBytes(&reloaded)));
    var want = try expected(stack, "demo:environments.box");
    try testing.expectEqual(want.harmonics, reloaded);
    want.deinit(stack.gpa);

    // The record's luminance edited: a package reload, the same handle, twice the light.
    const brighter = try std.mem.replaceOwned(u8, stack.gpa, records, "luminance 50", "luminance 100");
    defer stack.gpa.free(brighter);
    try stack.write("content.fdt", brighter);
    try stack.reload();
    try testing.expectEqual(@as(?bool, true), stack.renderer.environmentWritten(box));
    const doubled = written(stack, box);
    try testing.expectApproxEqRel(reloaded[0][0] * 2, doubled[0][0], 1e-3);

    // The sky's record gone: it keeps lighting with what it had.
    const sky_before = written(stack, sky);
    const without = try std.mem.replaceOwned(u8, stack.gpa, brighter, "foundry:environment demo:environments.sky", "foundry:environment demo:environments.renamed");
    defer stack.gpa.free(without);
    try stack.write("content.fdt", without);
    try stack.reload();
    try testing.expectEqual(render3d.EnvironmentState.ready, (try stack.content.environmentState(sky)).?);
    try testing.expectEqual(sky_before, written(stack, sky));
    try frameWith(stack, sky);
    try testing.expectEqual(@as(usize, 0), stack.violations());
}

test "an environment released while its prefilter runs is freed once the prefilter finishes" {
    const stack = try environmentStack();
    defer stack.deinit();
    var manual = try core.tasks.Manual.init(stack.gpa, 16);
    defer manual.deinit();
    stack.assets.useTasks(manual.tasks());
    defer stack.assets.useTasks(core.tasks.immediate);
    const sky = try stack.content.requestEnvironment(id("demo:environments.sky"));
    // The gradient has no faces, so its first settle starts the prefilter on the executor.
    try testing.expectEqual(render3d.EnvironmentState.pending, (try stack.content.environmentState(sky)).?);
    try testing.expectEqual(@as(u32, 1), manual.pending());
    stack.content.releaseEnvironment(sky);
    try testing.expectEqual(@as(usize, 1), stack.content.abandoned.items.len);
    manual.runLast();
    // Any later settle sweeps it; the testing allocator sees nothing leak either way.
    const box = try stack.content.requestEnvironment(id("demo:environments.box"));
    defer stack.content.releaseEnvironment(box);
    _ = try stack.content.environmentState(box);
    try testing.expectEqual(@as(usize, 0), stack.content.abandoned.items.len);
    drain(stack, &manual);
}
