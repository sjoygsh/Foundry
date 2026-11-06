//! Rigs from a compiled package (`docs/design/animation-logic.md` §4), over the real compiler,
//! store and registry. **No renderer is imported here,** and `rigs-test` is built without one:
//! that a simulation can reach a clip without `render3d` is what this file is for.

const std = @import("std");
const anim = @import("anim");
const asset = @import("asset");
const author = @import("author");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Mat4 = core.math.Mat4;
const Rigs = asset.Rigs;
const Transform = core.math.Transform;

const gpa = testing.allocator;

const manifest =
    \\foundry:mod demo:content { name "test" version 1 license "Apache-2.0" }
;

/// A model of two joints and two clips, in records and files, as a glTF import would leave it.
const model_text =
    \\foundry:skeleton demo:rig { source "rig.fskel" }
    \\foundry:animation demo:clip0 { source "clip0.fanim" }
    \\foundry:animation demo:clip1 { source "clip1.fanim" }
    \\foundry:model demo:hero {
    \\    slots [] parts [] skeleton demo:rig
    \\    clips [ { name "idle" clip demo:clip0 } { name "walk" clip demo:clip1 } ]
    \\}
;

const Stack = struct {
    os: *platform.os.Os,
    tmp: std.testing.TmpDir,
    src: []u8,
    out: []u8,
    schemas: data.Registry,
    diags: data.Diagnostics,
    store: data.Store,
    bytes: std.ArrayList(u8) = .empty,
    assets: asset.Registry,
    rigs: Rigs,

    fn init() !*Stack {
        const os = try platform.os.Os.init(gpa, .{ .app_name = "foundry-integration", .env = &.{} });
        errdefer os.deinit();
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_len = try tmp.dir.realPath(testing.io, &path_buf);
        const self = try gpa.create(Stack);
        self.* = .{
            .os = os,
            .tmp = tmp,
            .src = try platform.os.joinPath(gpa, &.{ path_buf[0..path_len], "src" }),
            .out = try platform.os.joinPath(gpa, &.{ path_buf[0..path_len], "out" }),
            .schemas = .init(gpa, .default),
            .diags = .init(gpa, .default),
            .store = .init(gpa, .default),
            .assets = undefined,
            .rigs = undefined,
        };
        self.assets = .init(gpa, os, &self.store, .{});
        self.rigs = .init(gpa, &self.assets);
        try self.write("mod.fdt", manifest);
        try self.write("model.fdt", model_text);
        try self.writeAssets(2, 0.5);
        return self;
    }

    fn deinit(self: *Stack) void {
        self.rigs.deinit();
        self.assets.deinit(gpa);
        self.store.deinit(gpa);
        self.schemas.deinit(gpa);
        self.diags.deinit(gpa);
        self.bytes.deinit(gpa);
        gpa.free(self.src);
        gpa.free(self.out);
        self.os.deinit();
        self.tmp.cleanup();
        gpa.destroy(self);
    }

    fn writeUnder(self: *Stack, root: []const u8, rel: []const u8, contents: []const u8) !void {
        const path = try platform.os.joinPath(gpa, &.{ root, rel });
        defer gpa.free(path);
        if (std.fs.path.dirname(path)) |parent| try self.os.createDirPath(parent);
        try self.os.writeFile(path, contents);
    }

    fn write(self: *Stack, rel: []const u8, contents: []const u8) !void {
        try self.writeUnder(self.src, rel, contents);
    }

    fn install(self: *Stack, rel: []const u8, contents: []const u8) !void {
        try self.writeUnder(self.src, rel, contents);
        try self.writeUnder(self.out, rel, contents);
    }

    /// The skeleton and both clips. `walk` runs the pelvis forward over `walk_seconds`.
    fn writeAssets(self: *Stack, joints: u32, walk_seconds: f32) !void {
        const parents = [_]u16{ 0xFFFF, 0, 1 };
        const rest: [3]Transform = @splat(.{});
        const binds: [3]Mat4 = @splat(Mat4.identity);
        const names = [_][]const u8{ "pelvis", "leg", "foot" };
        const rig = try asset.skeleton.write(gpa, .{ .parents = parents[0..joints], .rest = rest[0..joints], .inverse_bind = binds[0..joints], .names = names[0..joints] });
        defer gpa.free(rig);
        try self.install("rig.fskel", rig);

        const idle = try asset.animation.write(gpa, .{ .duration = 1, .joint_count = joints, .tracks = &.{} });
        defer gpa.free(idle);
        try self.install("clip0.fanim", idle);

        const times = [_]f32{ 0, walk_seconds };
        const values = [_]f32{ 0, 0, 0, 0, 0, -0.6 };
        const tracks = [_]asset.animation.Track{.{ .joint = 0, .path = .translation, .times = &times, .values = &values }};
        const walk = try asset.animation.write(gpa, .{ .duration = walk_seconds, .joint_count = joints, .tracks = &tracks });
        defer gpa.free(walk);
        try self.install("clip1.fanim", walk);
    }

    fn set(self: *Stack, text: []const u8) !void {
        try self.write("set.fdt", text);
    }

    /// Compiles and loads, as `app`'s package reload does.
    fn build(self: *Stack) !void {
        var next: std.ArrayList(u8) = .empty;
        errdefer next.deinit(gpa);
        const identity = try author.compile(gpa, self.os, self.src, .{ .assets_out = self.out }, &self.schemas, &self.diags, &next);
        defer gpa.free(identity.name);
        self.assets.clearMounts();
        self.store.deinit(gpa);
        self.bytes.deinit(gpa);
        self.bytes = next;
        self.store = .init(gpa, .default);
        const handle = try self.store.add(gpa, "demo:content", self.bytes.items, &self.schemas, &self.diags);
        try self.assets.mount(gpa, handle, self.out);
    }

    /// `build`, then what a game does when the content generation moves.
    fn reload(self: *Stack) !void {
        try self.build();
        _ = self.assets.reloadAll(gpa);
        try self.rigs.contentChanged();
    }

    fn expectRefused(self: *Stack, expected: asset.rigs.BuildError, text: []const u8) !void {
        try self.set(text);
        try self.build();
        try testing.expectError(expected, self.rigs.acquire(id("demo:set")));
    }
};

fn id(name: []const u8) ContentId {
    return .fromString(name);
}

const full_set =
    \\foundry:animation_set demo:set {
    \\    model demo:hero
    \\    start "walk"
    \\    motion_joint "pelvis"
    \\    clips [
    \\        { name "walk" motion true speed 2 events [ { at 0.5 event demo:foot } ] }
    \\    ]
    \\}
;

test "a set compiled from text builds a rig that plays, with no renderer" {
    const s = try Stack.init();
    defer s.deinit();
    try s.set(full_set);
    try s.build();
    const handle = try s.rigs.acquire(id("demo:set"));
    defer s.rigs.release(handle);
    var rig = s.rigs.get(handle).?.*;
    try rig.validate();
    try testing.expectEqual(@as(usize, 2), rig.clips.len);
    try testing.expectEqual(anim.clipName("walk"), rig.start);
    try testing.expectEqual(@as(u16, 0), rig.motion_joint);

    var walk = rig.find(anim.clipName("walk")).?;
    try testing.expectEqualStrings("walk", walk.label);
    try testing.expect(walk.motion and walk.loop);
    try testing.expectEqual(@as(f32, 2), walk.speed);
    try testing.expectEqual(@as(usize, 1), walk.events.len);
    try testing.expect(walk.events[0].id.eql(id("demo:foot")));

    try s.set("foundry:animation_set demo:set { model demo:hero clips [ { name \"walk\" loop false } ] }");
    try s.reload();
    try testing.expect(!s.rigs.get(handle).?.find(anim.clipName("walk")).?.loop);
    try s.set(full_set);
    try s.reload();
    rig = s.rigs.get(handle).?.*;
    walk = rig.find(anim.clipName("walk")).?;
    try testing.expect(walk.loop);

    // Listed by the model and not the set: looped, at speed 1, with nothing else.
    const idle = rig.find(anim.clipName("idle")).?;
    try testing.expect(idle.loop and !idle.motion);
    try testing.expectEqual(@as(usize, 0), idle.events.len);
    try testing.expectEqual(@as(f32, 1), idle.speed);

    // 0.6 m in half a second, at twice the rate.
    try testing.expectApproxEqAbs(@as(f32, 2.4), rig.motionSpeed(anim.clipName("walk")), 1e-5);

    var player: anim.Player = .{};
    var step: anim.Step = .{};
    var fired: u32 = 0;
    var travelled: f32 = 0;
    for (0..30) |_| {
        player.advance(rig, 1.0 / 60.0, &step);
        fired += step.event_count;
        travelled += step.motion.translation.z;
    }
    try testing.expectEqual(@as(u32, 2), fired);
    try testing.expectApproxEqAbs(@as(f32, -1.2), travelled, 2e-3);
}

test "a set that names only a model starts its first clip" {
    const s = try Stack.init();
    defer s.deinit();
    try s.set("foundry:animation_set demo:set { model demo:hero }");
    try s.build();
    const handle = try s.rigs.acquire(id("demo:set"));
    defer s.rigs.release(handle);
    const rig = s.rigs.get(handle).?;
    try testing.expectEqual(anim.clipName("idle"), rig.start);
    try testing.expectEqual(anim.no_parent, rig.motion_joint);
}

test "the same set is one rig, counted, and goes with its last release" {
    const s = try Stack.init();
    defer s.deinit();
    try s.set(full_set);
    try s.build();
    const a = try s.rigs.acquire(id("demo:set"));
    const b = try s.rigs.acquire(id("demo:set"));
    try testing.expect(a.eql(b));
    try testing.expect(s.rigs.lookup(id("demo:set")) == s.rigs.get(a));
    s.rigs.release(a);
    try testing.expect(s.rigs.get(b) != null);
    s.rigs.release(b);
    try testing.expect(s.rigs.get(b) == null);
    try testing.expect(s.rigs.lookup(id("demo:set")) == null);
    // Its assets went with it.
    _ = s.assets.evictUnused(gpa);
    try testing.expectEqual(@as(u32, 0), s.assets.count());

    // And the set can be acquired again.
    s.rigs.release(try s.rigs.acquire(id("demo:set")));
}

test "every refusal that needs another record is named, and leaves nothing behind" {
    const s = try Stack.init();
    defer s.deinit();
    try s.set(full_set);
    try s.build();
    try testing.expectError(error.MissingSet, s.rigs.acquire(id("demo:nothing")));
    try testing.expectError(error.NotASet, s.rigs.acquire(id("demo:hero")));

    try s.expectRefused(error.MissingModel, "foundry:animation_set demo:set { model demo:nobody }");
    try s.expectRefused(error.NotAModel, "foundry:animation_set demo:set { model demo:rig }");
    try s.expectRefused(error.UnknownClip, "foundry:animation_set demo:set { model demo:hero start \"run\" }");
    try s.expectRefused(error.UnknownClip, "foundry:animation_set demo:set { model demo:hero clips [ { name \"run\" } ] }");
    try s.expectRefused(error.UnknownJoint, "foundry:animation_set demo:set { model demo:hero motion_joint \"tail\" }");
    try s.expectRefused(error.MotionJointNotRoot, "foundry:animation_set demo:set { model demo:hero motion_joint \"leg\" }");

    try s.write("bare.fdt", "foundry:model demo:bare { slots [] parts [] }");
    try s.expectRefused(error.NotSkinned, "foundry:animation_set demo:set { model demo:bare }");
    try s.write("bare.fdt", "foundry:model demo:bare { slots [] parts [] skeleton demo:rig clips [] }");
    try s.expectRefused(error.NotSkinned, "foundry:animation_set demo:set { model demo:bare }");
    try s.write("bare.fdt", "");

    // No rig is left, and no asset is held by a refusal.
    try testing.expectEqual(@as(u32, 0), s.rigs.entries.count());
    _ = s.assets.evictUnused(gpa);
    try testing.expectEqual(@as(u32, 0), s.assets.count());
}

test "a set in a package no compiler checked is still refused" {
    // A mod's package is untrusted, whatever made it.
    const s = try Stack.init();
    defer s.deinit();
    try s.set("foundry:animation_set demo:set { model demo:hero }");
    try s.build();

    var package = try data.Package.init(gpa, "raw:content", 1, .default);
    defer package.deinit(gpa);
    var doc = try data.parser.parse(gpa, "raw.fdt",
        \\foundry:animation_set demo:set { model demo:hero clips [ { name "walk" } { name "walk" } ] }
    , .{ .namespace = "demo" }, &s.diags);
    defer doc.deinit(gpa);
    try package.addDocument(gpa, &doc, &s.schemas, &s.diags);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try data.fpk.write(gpa, &package, &s.schemas, &bytes);
    _ = try s.store.add(gpa, "raw:content", bytes.items, &s.schemas, &s.diags);
    try testing.expectError(error.DuplicateClip, s.rigs.acquire(id("demo:set")));
}

test "a clip made for another skeleton, and a file that won't load, are refused by name" {
    const s = try Stack.init();
    defer s.deinit();
    try s.set(full_set);
    try s.write("mismatch.fdt",
        \\foundry:skeleton demo:big { source "big.fskel" }
        \\foundry:model demo:odd { slots [] parts [] skeleton demo:big clips [ { name "idle" clip demo:clip0 } ] }
        \\foundry:animation_set demo:odd.set { model demo:odd }
        \\foundry:animation demo:broken { source "broken.fanim" }
        \\foundry:model demo:bad { slots [] parts [] skeleton demo:rig clips [ { name "idle" clip demo:broken } ] }
        \\foundry:animation_set demo:bad.set { model demo:bad }
    );
    const parents = [_]u16{ 0xFFFF, 0, 1, 2 };
    const rest: [4]Transform = @splat(.{});
    const binds: [4]Mat4 = @splat(Mat4.identity);
    const names = [_][]const u8{ "a", "b", "c", "d" };
    const big = try asset.skeleton.write(gpa, .{ .parents = &parents, .rest = &rest, .inverse_bind = &binds, .names = &names });
    defer gpa.free(big);
    try s.install("big.fskel", big);
    try s.install("broken.fanim", "not a clip");
    try s.build();
    try testing.expectError(error.JointCountMismatch, s.rigs.acquire(id("demo:odd.set")));
    try testing.expectError(error.AssetUnavailable, s.rigs.acquire(id("demo:bad.set")));
    try testing.expectEqual(@as(u32, 0), s.rigs.entries.count());
}

test "a bad set is refused at compile, naming the record" {
    const s = try Stack.init();
    defer s.deinit();
    try s.set("foundry:animation_set demo:set { model demo:hero clips [ { name \"a\" speed 0 } ] }");
    try testing.expectError(error.ContentInvalid, s.build());
    var found = false;
    for (s.diags.items.items) |diagnostic| {
        if (std.mem.indexOf(u8, diagnostic.message, "animation set 'demo:set'") != null) found = true;
    }
    try testing.expect(found);
}

test "a reload keeps handles, and follows the set and the clips" {
    const s = try Stack.init();
    defer s.deinit();
    try s.set(full_set);
    try s.build();
    const handle = try s.rigs.acquire(id("demo:set"));
    defer s.rigs.release(handle);

    try s.set(
        \\foundry:animation_set demo:set {
        \\    model demo:hero
        \\    motion_joint "pelvis"
        \\    clips [ { name "walk" motion true speed 4 } ]
        \\}
    );
    try s.writeAssets(2, 2);
    try s.reload();
    const rig = s.rigs.get(handle).?;
    const walk = rig.find(anim.clipName("walk")).?;
    try testing.expectEqual(@as(f32, 4), walk.speed);
    try testing.expectEqual(@as(usize, 0), walk.events.len);
    try testing.expectEqual(@as(f32, 2), walk.clip.duration);
    try testing.expectEqual(anim.clipName("idle"), rig.start);
}

test "a later package's override of the set wins, with no asset restated" {
    const s = try Stack.init();
    defer s.deinit();
    try s.set(full_set);
    try s.build();

    var next: std.ArrayList(u8) = .empty;
    defer next.deinit(gpa);
    const dir = try platform.os.joinPath(gpa, &.{ s.src, "..", "quick" });
    defer gpa.free(dir);
    try s.writeUnder(dir, "mod.fdt", "foundry:mod quick:content { name \"quick\" version 1 license \"Apache-2.0\" }");
    try s.writeUnder(dir, "set.fdt",
        \\foundry:animation_set demo:set {
        \\    model demo:hero
        \\    start "walk"
        \\    motion_joint "pelvis"
        \\    clips [ { name "walk" motion true speed 8 events [ { at 0.25 event demo:foot } ] } ]
        \\}
    );
    const identity = try author.compile(gpa, s.os, dir, .{}, &s.schemas, &s.diags, &next);
    defer gpa.free(identity.name);
    _ = try s.store.add(gpa, "quick:content", next.items, &s.schemas, &s.diags);

    const handle = try s.rigs.acquire(id("demo:set"));
    defer s.rigs.release(handle);
    const walk = s.rigs.get(handle).?.find(anim.clipName("walk")).?;
    try testing.expectEqual(@as(f32, 8), walk.speed);
    try testing.expectEqual(@as(f32, 0.25), walk.events[0].at);
}

test "a reload that breaks a rig answers null, and a later one mends it under the same handle" {
    const s = try Stack.init();
    defer s.deinit();
    try s.set(full_set);
    try s.build();
    const handle = try s.rigs.acquire(id("demo:set"));
    defer s.rigs.release(handle);

    try s.set("foundry:animation_set demo:set { model demo:hero start \"gone\" }");
    try s.reload();
    try testing.expect(s.rigs.get(handle) == null);
    try testing.expect(s.rigs.lookup(id("demo:set")) == null);

    // A second acquire of a broken set says why, and holds nothing.
    try testing.expectError(error.UnknownClip, s.rigs.acquire(id("demo:set")));

    try s.set(full_set);
    try s.reload();
    try testing.expectEqual(anim.clipName("walk"), s.rigs.get(handle).?.start);
}

test "out of memory at any allocation leaks nothing, and a retry succeeds" {
    const s = try Stack.init();
    defer s.deinit();
    try s.set(full_set);
    try s.build();
    var fail: usize = 0;
    while (true) : (fail += 1) {
        var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = fail });
        var rigs = Rigs.init(failing.allocator(), &s.assets);
        defer rigs.deinit();
        const handle = rigs.acquire(id("demo:set")) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        rigs.release(handle);
        break;
    }
    try testing.expect(fail > 3);
}

// ---------------------------------------------------------------------------------------------
// Version 2 and machines (`docs/design/animation-states.md` §9, §10, M35 Step 4)

const v2_set =
    \\foundry:animation_set demo:set {
    \\    model demo:hero
    \\    start "walk"
    \\    motion_joint "pelvis"
    \\    clips [ { name "walk" motion true } ]
    \\    masks [ { name "legs" joints [ { joint "leg" weight 0.5 } { joint "foot" } ] } ]
    \\    sync [ { clip "walk" group "feet" } ]
    \\    additive [ { clip "idle" reference "walk" } ]
    \\    rises [ { clip "walk" rise 0.3 } ]
    \\}
;

const machine_text =
    \\foundry:animation_machine demo:machine {
    \\    params [ { name "speed" } { name "near" } ]
    \\    layers [
    \\        { name "body" entry "walk"
    \\          states [ { name "walk" clip "walk" speed_param "speed" } ] }
    \\        { name "breath" mode "additive" mask "legs" weight_param "near" weight_fade 0.5 entry "idle"
    \\          states [ { name "idle" clip "idle" } ] }
    \\    ]
    \\}
;

test "a version 2 set builds masks, groups, additive clips and rises into its rig" {
    const s = try Stack.init();
    defer s.deinit();
    // A third joint, so a mask has a subtree to take.
    try s.writeAssets(3, 0.5);
    try s.set(v2_set);
    try s.build();
    const handle = try s.rigs.acquire(id("demo:set"));
    defer s.rigs.release(handle);
    const rig = s.rigs.get(handle).?;
    try rig.validate();

    const legs = rig.mask(anim.clipName("legs")).?;
    try testing.expectEqualStrings("legs", legs.label);
    try testing.expectEqualSlices(f32, &.{ 0, 0.5, 1 }, legs.weights);

    const walk = rig.find(anim.clipName("walk")).?;
    try testing.expectEqual(anim.clipName("feet"), walk.sync);
    try testing.expectEqual(@as(f32, 0.3), walk.rise);
    try testing.expectEqual(@as(u32, 2), rig.lapsFor(anim.clipName("walk"), 0.6));

    const idle = rig.find(anim.clipName("idle")).?;
    try testing.expect(idle.additive);
    // Its reference is the walk's first frame, sampled once: the pelvis at its first key.
    try testing.expectEqual(@as(usize, 3), idle.reference.len);
    try testing.expectEqual(@as(f32, 0), idle.reference[0].translation.z);
    try testing.expect(!walk.additive and walk.reference.len == 0);
}

test "a version 1 set still builds the rig it did" {
    const s = try Stack.init();
    defer s.deinit();
    // A third joint, so a mask has a subtree to take.
    try s.writeAssets(3, 0.5);
    try s.set(full_set);
    try s.build();
    const handle = try s.rigs.acquire(id("demo:set"));
    defer s.rigs.release(handle);
    const rig = s.rigs.get(handle).?;
    try testing.expectEqual(@as(usize, 0), rig.masks.len);
    for (rig.clips) |clip| {
        try testing.expectEqual(@as(u64, 0), clip.sync);
        try testing.expectEqual(@as(f32, 0), clip.rise);
        try testing.expect(!clip.additive and clip.reference.len == 0);
    }
}

test "every version 2 refusal that needs the model is named, and leaves nothing behind" {
    const s = try Stack.init();
    defer s.deinit();
    // A third joint, so a mask has a subtree to take.
    try s.writeAssets(3, 0.5);
    const head = "foundry:animation_set demo:set { model demo:hero start \"walk\" ";
    try s.expectRefused(error.UnknownClip, head ++ "sync [ { clip \"run\" group \"g\" } ] }");
    try s.expectRefused(error.UnknownClip, head ++ "additive [ { clip \"run\" } ] }");
    try s.expectRefused(error.UnknownClip, head ++ "rises [ { clip \"run\" rise 1 } ] }");
    try s.expectRefused(error.UnknownReference, head ++ "additive [ { clip \"idle\" reference \"run\" } ] }");
    try s.expectRefused(error.UnknownJoint, head ++ "masks [ { name \"m\" joints [ { joint \"tail\" } ] } ] }");
    // The model's first clip is the start when none is named, and the base plays no difference.
    try s.expectRefused(error.AdditiveStart, "foundry:animation_set demo:set { model demo:hero additive [ { clip \"idle\" } ] }");
    try testing.expectEqual(@as(u32, 0), s.rigs.entries.count());
    _ = s.assets.evictUnused(gpa);
    try testing.expectEqual(@as(u32, 0), s.assets.count());
}

test "a machine compiled from text builds against a rig and runs, with no renderer" {
    const s = try Stack.init();
    defer s.deinit();
    // A third joint, so a mask has a subtree to take.
    try s.writeAssets(3, 0.5);
    try s.set(v2_set);
    try s.write("machine.fdt", machine_text);
    try s.build();
    const handle = try s.rigs.acquireMachine(id("demo:set"), id("demo:machine"));
    defer s.rigs.releaseMachine(handle);
    const machine = s.rigs.getMachine(handle).?;
    try testing.expect(machine == s.rigs.lookupMachine(id("demo:set"), id("demo:machine")).?);
    const rig = s.rigs.lookup(id("demo:set")).?;
    try machine.validate(rig.*);
    try testing.expectEqual(@as(usize, 2), machine.layers.len);

    var stack: anim.Stack = .{};
    var step: anim.Step = .{};
    // 0.6 m in half a second is 1.2 m/s, so at 2.4 m/s the walk runs at twice its rate.
    try anim.machine.set(&stack, machine.*, anim.clipName("speed"), 2.4);
    try anim.machine.set(&stack, machine.*, anim.clipName("near"), 1);
    for (0..30) |_| anim.machine.advance(&stack, rig.*, machine.*, 1.0 / 60.0, &step);
    try testing.expectEqual(anim.clipName("walk"), stack.layers[0].state);
    const base = &stack.layers[0].player;
    try testing.expectApproxEqAbs(@as(f32, 2), base.channels[base.newest].speed, 1e-5);
    try testing.expectEqual(@as(f32, 1), stack.layers[1].weight);
    try testing.expect(stack.layers[1].player.playing(anim.clipName("idle")));
}

test "every machine refusal that needs the rig is named, and leaves nothing behind" {
    const s = try Stack.init();
    defer s.deinit();
    // A third joint, so a mask has a subtree to take.
    try s.writeAssets(3, 0.5);
    try s.set(v2_set);
    try s.write("machine.fdt", machine_text);
    try s.build();
    try testing.expectError(error.MissingMachine, s.rigs.acquireMachine(id("demo:set"), id("demo:nothing")));
    try testing.expectError(error.NotAMachine, s.rigs.acquireMachine(id("demo:set"), id("demo:set")));
    try testing.expectError(error.MissingSet, s.rigs.acquireMachine(id("demo:nothing"), id("demo:machine")));

    const cases = [_]struct { anyerror, []const u8 }{
        .{ error.UnknownClip, "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"run\" } ] } ] }" },
        .{ error.UnknownMask, "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"walk\" } ] } { name \"u\" mask \"arms\" mode \"additive\" entry \"s\" states [ { name \"s\" clip \"idle\" } ] } ] }" },
        .{ error.AdditiveMismatch, "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"idle\" } ] } ] }" },
        .{ error.MotionOffBase, "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"walk\" } ] } { name \"u\" entry \"s\" states [ { name \"s\" clip \"walk\" } ] } ] }" },
        .{ error.NoMotionSpeed, "params [ { name \"p\" } ] layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"walk\" } ] } { name \"u\" mode \"additive\" entry \"s\" states [ { name \"s\" clip \"idle\" speed_param \"p\" } ] } ] }" },
    };
    for (cases) |case| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        try text.appendSlice(gpa, "foundry:animation_machine demo:machine { ");
        try text.appendSlice(gpa, case[1]);
        try s.write("machine.fdt", text.items);
        try s.build();
        try testing.expectError(case[0], s.rigs.acquireMachine(id("demo:set"), id("demo:machine")));
    }

    // The set itself does not build: nothing to check a machine against.
    try s.write("machine.fdt", machine_text);
    try s.set("foundry:animation_set demo:set { model demo:hero start \"gone\" }");
    try s.build();
    try testing.expectError(error.UnknownClip, s.rigs.acquireMachine(id("demo:set"), id("demo:machine")));

    try testing.expectEqual(@as(u32, 0), s.rigs.machines.count());
    try testing.expectEqual(@as(u32, 0), s.rigs.entries.count());
}

test "a bad machine is refused at compile, naming the record" {
    const s = try Stack.init();
    defer s.deinit();
    // A third joint, so a mask has a subtree to take.
    try s.writeAssets(3, 0.5);
    try s.set(v2_set);
    try s.write("machine.fdt", "foundry:animation_machine demo:machine { layers [ { name \"b\" entry \"t\" states [ { name \"s\" clip \"walk\" } ] } ] }");
    try testing.expectError(error.ContentInvalid, s.build());
    var found = false;
    for (s.diags.items.items) |diagnostic| {
        if (std.mem.indexOf(u8, diagnostic.message, "animation machine 'demo:machine'") != null) found = true;
    }
    try testing.expect(found);
}

test "the same pair is one machine, counted, and it holds its rig" {
    const s = try Stack.init();
    defer s.deinit();
    // A third joint, so a mask has a subtree to take.
    try s.writeAssets(3, 0.5);
    try s.set(v2_set);
    try s.write("machine.fdt", machine_text);
    try s.build();
    const a = try s.rigs.acquireMachine(id("demo:set"), id("demo:machine"));
    const b = try s.rigs.acquireMachine(id("demo:set"), id("demo:machine"));
    try testing.expectEqual(a, b);
    try testing.expectEqual(@as(u32, 1), s.rigs.machines.count());
    // The rig a game acquired itself goes with its own release; the machine still holds one.
    const rig = try s.rigs.acquire(id("demo:set"));
    s.rigs.release(rig);
    try testing.expect(s.rigs.lookup(id("demo:set")) != null);
    s.rigs.releaseMachine(a);
    try testing.expect(s.rigs.getMachine(b) != null);
    s.rigs.releaseMachine(b);
    try testing.expectEqual(@as(u32, 0), s.rigs.machines.count());
    try testing.expectEqual(@as(u32, 0), s.rigs.entries.count());
}

test "a reload keeps a machine's handle, follows its record, and a broken one mends" {
    const s = try Stack.init();
    defer s.deinit();
    // A third joint, so a mask has a subtree to take.
    try s.writeAssets(3, 0.5);
    try s.set(v2_set);
    try s.write("machine.fdt", machine_text);
    try s.build();
    const handle = try s.rigs.acquireMachine(id("demo:set"), id("demo:machine"));
    defer s.rigs.releaseMachine(handle);

    try s.write("machine.fdt",
        \\foundry:animation_machine demo:machine {
        \\    params [ { name "speed" } ]
        \\    layers [ { name "body" entry "walk" states [ { name "walk" clip "walk" speed 2 } ] } ]
        \\}
    );
    try s.reload();
    const machine = s.rigs.getMachine(handle).?;
    try testing.expectEqual(@as(usize, 1), machine.layers.len);
    try testing.expectEqual(@as(f32, 2), machine.layers[0].states[0].speed);

    // A machine its rig no longer supports answers null, as does one whose rig is gone.
    try s.write("machine.fdt", "foundry:animation_machine demo:machine { layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"run\" } ] } ] }");
    try s.reload();
    try testing.expect(s.rigs.getMachine(handle) == null);
    try s.write("machine.fdt", machine_text);
    try s.set("foundry:animation_set demo:set { model demo:hero start \"gone\" }");
    try s.reload();
    try testing.expect(s.rigs.getMachine(handle) == null);

    try s.set(v2_set);
    try s.reload();
    try testing.expectEqual(@as(usize, 2), s.rigs.getMachine(handle).?.layers.len);
}

test "out of memory building a version 2 rig or a machine leaks nothing, and a retry succeeds" {
    const s = try Stack.init();
    defer s.deinit();
    // A third joint, so a mask has a subtree to take.
    try s.writeAssets(3, 0.5);
    try s.set(v2_set);
    try s.write("machine.fdt", machine_text);
    try s.build();
    var fail: usize = 0;
    while (true) : (fail += 1) {
        var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = fail });
        var rigs = Rigs.init(failing.allocator(), &s.assets);
        defer rigs.deinit();
        const handle = rigs.acquireMachine(id("demo:set"), id("demo:machine")) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        rigs.releaseMachine(handle);
        break;
    }
    try testing.expect(fail > 6);
}
