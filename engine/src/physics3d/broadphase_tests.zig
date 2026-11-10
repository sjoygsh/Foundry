//! The broadphase never decides an answer (`collision-scale.md` §4, M38 Step 2).
//!
//! Two worlds are given the same calls. One answers through the tree and the other by scanning
//! every body, as M23 did. Every answer must be equal, field for field, bit for bit.
const std = @import("std");
const core = @import("core");
const p = @import("root.zig");
const Pcg32 = core.rng.Pcg32;
const Quat = core.math.Quat;
const Vec3 = core.math.Vec3;
const t = std.testing;
const gpa = t.allocator;

const config: p.CharacterConfig = .{ .radius = 0.3, .height = 1.8, .max_slope = std.math.pi / 4.0, .step_height = 0.35, .snap_distance = 0.3, .max_move = 10 };
const extent: f32 = 40;

/// The same call made of both worlds.
const Twin = struct {
    tree: p.World = .empty,
    scan: p.World = .empty,
    hull: [2]p.HullHandle = undefined,
    mesh: [2]p.MeshHandle = undefined,
    bodies: std.ArrayList(p.BodyHandle) = .empty,
    characters: [4]p.CharacterHandle = undefined,

    fn worlds(self: *Twin) [2]*p.World {
        return .{ &self.tree, &self.scan };
    }

    fn deinit(self: *Twin) void {
        self.bodies.deinit(gpa);
        self.tree.deinit(gpa);
        self.scan.deinit(gpa);
    }

    fn init(self: *Twin) !void {
        self.scan.scan_reference = true;
        const corners = [_]Vec3{ .init(-0.5, 0, -0.5), .init(0.5, 0, -0.5), .init(0.5, 0, 0.5), .init(-0.5, 0, 0.5), .init(0, 0.8, 0) };
        // A floor of 32 triangles under everything.
        var positions: [25]Vec3 = undefined;
        var indices: [96]u32 = undefined;
        for (0..5) |j| for (0..5) |i| {
            positions[j * 5 + i] = .init((@as(f32, @floatFromInt(i)) - 2) * extent * 0.5, 0, (@as(f32, @floatFromInt(j)) - 2) * extent * 0.5);
        };
        var k: usize = 0;
        for (0..4) |j| for (0..4) |i| {
            const a: u32 = @intCast(j * 5 + i);
            for ([_]u32{ a, a + 5, a + 1, a + 1, a + 5, a + 6 }) |v| {
                indices[k] = v;
                k += 1;
            }
        };
        for (self.worlds(), 0..) |w, i| {
            self.hull[i] = try w.addHull(gpa, &corners);
            self.mesh[i] = try w.addMesh(gpa, &positions, &indices);
            _ = try w.addBody(gpa, .{ .shape = .{ .mesh = self.mesh[i] } });
        }
    }

    /// A body both worlds agree on: the handles are equal because the calls were.
    fn add(self: *Twin, rng: *Pcg32) !void {
        const pose = randomPose(rng);
        const kind: p.BodyKind = if (rng.below(4) == 0) .kinematic else .static;
        const which = rng.below(8);
        const scale: Vec3 = .init(0.5 + rng.float01() * 2, 0.5 + rng.float01() * 2, 0.5 + rng.float01() * 2);
        const layer: u32 = if (rng.below(8) == 0) 2 else 1;
        var handles: [2]p.BodyHandle = undefined;
        for (self.worlds(), 0..) |w, i| {
            const shape: p.Shape = switch (which) {
                0 => .{ .sphere = .{ .radius = 0.2 + scale.x * 0.3 } },
                1 => .{ .capsule = .{ .radius = 0.2, .half_height = scale.y * 0.4 } },
                2 => .{ .hull = self.hull[i] },
                else => .{ .box = .{ .half_extents = scale.scale(0.3) } },
            };
            handles[i] = try w.addBody(gpa, .{ .shape = shape, .pose = pose, .kind = kind, .scale = if (which == 2) scale else .one, .layer = layer });
        }
        try t.expectEqual(handles[0], handles[1]);
        try self.bodies.append(gpa, handles[0]);
    }

    fn change(self: *Twin, rng: *Pcg32) !void {
        if (self.bodies.items.len == 0) return self.add(rng);
        const at = rng.below(@intCast(self.bodies.items.len));
        const handle = self.bodies.items[at];
        const what = rng.below(10);
        const pose = randomPose(rng);
        const nudge: Vec3 = .init(rng.float01() * 0.1 - 0.05, 0, rng.float01() * 0.1 - 0.05);
        const scale: Vec3 = .init(0.5 + rng.float01() * 3, 0.5 + rng.float01() * 3, 0.5 + rng.float01() * 3);
        var crushed: [4]p.CharacterHandle = undefined;
        for (self.worlds(), 0..) |w, i| {
            const b = w.body(handle).?.*;
            switch (what) {
                0, 1 => _ = try w.setPose(gpa, handle, pose),
                // A small move, which a kinematic body's margin should absorb, and a large one.
                2, 3, 4 => if (b.kind == .kinematic) {
                    _ = try w.moveBody(gpa, handle, b.pose.translated(nudge), &crushed);
                } else {
                    _ = try w.setPose(gpa, handle, b.pose.translated(nudge));
                },
                5 => if (b.kind == .kinematic) {
                    _ = try w.moveBody(gpa, handle, pose, &crushed);
                },
                6 => if (b.shape == .hull) {
                    _ = try w.setScale(gpa, handle, scale);
                } else {
                    _ = try w.setShape(gpa, handle, .{ .box = .{ .half_extents = scale.scale(0.4) } });
                },
                7 => if (b.shape != .hull) {
                    _ = try w.setShape(gpa, handle, .{ .hull = self.hull[i] });
                    _ = try w.setScale(gpa, handle, scale);
                },
                8 => _ = w.setKind(handle, if (b.kind == .static) .kinematic else .static) catch unreachable,
                else => _ = w.removeBody(gpa, handle),
            }
        }
        if (what == 9) _ = self.bodies.swapRemove(at);
    }

    /// One query of each kind, asked of both worlds.
    fn ask(self: *Twin, rng: *Pcg32) !void {
        const origin = randomPoint(rng).add(.init(0, 2, 0));
        const direction = Vec3.init(rng.float01() - 0.5, -rng.float01(), rng.float01() - 0.5).normalize();
        const reach = 1 + rng.float01() * 20;
        const pose = randomPose(rng);
        const to: p.Pose = .{ .position = pose.position.add(direction.scale(reach * 0.3)), .rotation = randomPose(rng).rotation };
        const mask: u32 = if (rng.below(6) == 0) 2 else ~@as(u32, 0);
        const filter: p.Filter = .{ .mask = mask };
        const shapes = [_]p.Shape{
            .{ .sphere = .{ .radius = 0.4 } },
            .{ .capsule = .{ .radius = 0.3, .half_height = 0.6 } },
            .{ .box = .{ .half_extents = .init(0.6, 0.3, 0.4) } },
        };
        const shape = shapes[rng.below(3)];
        const big: p.Shape = .{ .box = .{ .half_extents = .init(3, 2, 3) } };

        const a = &self.tree;
        const b = &self.scan;
        try t.expectEqual(try b.raycast(origin, direction, reach, filter), try a.raycast(origin, direction, reach, filter));
        try t.expectEqual(try b.shapeCast(shape, pose, direction.scale(reach), filter), try a.shapeCast(shape, pose, direction.scale(reach), filter));
        try t.expectEqual(try b.shapeSweep(shape, pose, to, filter), try a.shapeSweep(shape, pose, to, filter));
        var oa: [12]p.Overlap = undefined;
        var ob: [12]p.Overlap = undefined;
        const fa = try a.overlap(big, pose, filter, &oa);
        try t.expectEqual(try b.overlap(big, pose, filter, &ob), fa);
        for (oa[0..fa.count], ob[0..fa.count]) |x, y| try t.expectEqual(y, x);
        var ca: [12]p.Contact = undefined;
        var cb: [12]p.Contact = undefined;
        const ga = try a.contacts(big, pose, filter, &ca);
        try t.expectEqual(try b.contacts(big, pose, filter, &cb), ga);
        for (ca[0..ga.count], cb[0..ga.count]) |x, y| try t.expectEqual(y, x);
    }

    fn walk(self: *Twin, round: usize) !void {
        var ha: [8]p.Hit = undefined;
        var hb: [8]p.Hit = undefined;
        for (self.characters, 0..) |c, i| {
            const turn = @as(f32, @floatFromInt(round)) * 0.05 + @as(f32, @floatFromInt(i));
            const by: Vec3 = .init(0.08 * @cos(turn), -0.02, 0.08 * @sin(turn));
            const ma = try self.tree.moveCharacter(gpa, c, by, &ha);
            const mb = try self.scan.moveCharacter(gpa, c, by, &hb);
            try t.expectEqual(mb, ma);
            for (ha[0..ma.?.hit_count], hb[0..ma.?.hit_count]) |x, y| try t.expectEqual(y, x);
        }
    }
};

fn randomPoint(rng: *Pcg32) Vec3 {
    return .init((rng.float01() - 0.5) * extent, rng.float01() * 2, (rng.float01() - 0.5) * extent);
}

fn randomPose(rng: *Pcg32) p.Pose {
    const axis = Vec3.init(rng.float01() - 0.5, rng.float01() + 0.1, rng.float01() - 0.5).normalize();
    return .{ .position = randomPoint(rng), .rotation = Quat.fromAxisAngle(axis, rng.float01() * 6) };
}

test "broadphase: every query answers as a scan of every body does, through adds, moves, reshapes and removals" {
    var twin: Twin = .{};
    defer twin.deinit();
    try twin.init();
    var rng = Pcg32.init(0x38, 0x2);
    for (0..2048) |_| try twin.add(&rng);
    for (&twin.characters, 0..) |*c, i| {
        const feet: Vec3 = .init(@as(f32, @floatFromInt(i)) * 6 - 9, 3, 0);
        c.* = try twin.tree.addCharacter(gpa, config, feet, 0);
        try t.expectEqual(c.*, try twin.scan.addCharacter(gpa, config, feet, 0));
    }
    _ = twin.tree.takeCounters();
    _ = twin.scan.takeCounters();
    // 48 rounds ask 3,072 questions of each kind. The design's 200 took 86 s in a Debug build,
    // and every guard that 200 caught, 48 catches.
    for (0..48) |round| {
        for (0..24) |_| try twin.change(&rng);
        for (0..8) |_| try twin.add(&rng);
        for (0..64) |_| try twin.ask(&rng);
        try twin.walk(round);
        try t.expect(twin.tree.tree.consistent());
    }
    // The worlds hold the same bodies in the same places.
    var ia = twin.tree.bodyIterator();
    var ib = twin.scan.bodyIterator();
    while (ia.next()) |ea| {
        const eb = ib.next().?;
        try t.expectEqual(eb.id, ea.id);
        try t.expectEqual(eb.value.pose, ea.value.pose);
    }
    try t.expect(ib.next() == null);
    // And the tree did the same work on far fewer bodies.
    const ra = twin.tree.report();
    const rb = twin.scan.report();
    try t.expectEqual(rb.queries, ra.queries);
    try t.expect(ra.bodies_static + ra.bodies_kinematic > 2000);
    try t.expect(ra.bodies_tested * 20 < rb.bodies_tested);
    try t.expect(ra.tree_height <= 18);
    try t.expectEqual(ra.pairs_gjk, rb.pairs_gjk);
}

test "broadphase: a kinematic body moved inside its margin does not refit, and one moved past it does" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    const lift = try w.addBody(gpa, .{ .shape = .{ .box = .{ .half_extents = .init(1, 0.1, 1) } }, .kind = .kinematic });
    const wall = try w.addBody(gpa, .{ .shape = .{ .box = .{ .half_extents = .init(1, 1, 0.1) } }, .pose = .at(.init(5, 0, 0)) });
    var crushed: [1]p.CharacterHandle = undefined;
    _ = w.takeCounters();
    _ = try w.moveBody(gpa, lift, .at(.init(0, 0.05, 0)), &crushed);
    _ = try w.moveBody(gpa, lift, .at(.init(0, 0.09, 0)), &crushed);
    try t.expectEqual(@as(u32, 0), w.takeCounters().refits);
    _ = try w.moveBody(gpa, lift, .at(.init(0, 0.2, 0)), &crushed);
    try t.expectEqual(@as(u32, 1), w.takeCounters().refits);
    // It is found where it is, not where its box was.
    try t.expect((try w.raycast(.init(0, 5, 0), .init(0, -1, 0), 10, .{})).?.body.eql(lift));
    // A static body's box is its bounds: any move refits it, and none does not.
    _ = try w.setPose(gpa, wall, .at(.init(5, 0, 0)));
    try t.expectEqual(@as(u32, 0), w.takeCounters().refits);
    _ = try w.setPose(gpa, wall, .at(.init(5, 0.01, 0)));
    try t.expectEqual(@as(u32, 1), w.takeCounters().refits);
    // A body made static gives up its margin at once. One made kinematic keeps its exact box
    // until it moves out of it, since that box still holds it.
    _ = try w.setKind(lift, .static);
    try t.expectEqual(@as(u32, 1), w.takeCounters().refits);
    _ = try w.setKind(lift, .kinematic);
    try t.expectEqual(@as(u32, 0), w.takeCounters().refits);
}

test "broadphase: removing every body leaves an empty tree, and the world fills again" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    var handles: [64]p.BodyHandle = undefined;
    for (&handles, 0..) |*h, i| h.* = try w.addBody(gpa, .{ .shape = .{ .sphere = .{ .radius = 0.5 } }, .pose = .at(.init(@floatFromInt(i * 2), 0, 0)) });
    try t.expectEqual(@as(u32, 127), w.report().tree_nodes);
    for (handles) |h| try t.expect(w.removeBody(gpa, h));
    try t.expectEqual(@as(u32, 0), w.report().tree_nodes);
    try t.expect((try w.raycast(.init(4, 5, 0), .init(0, -1, 0), 10, .{})) == null);
    // Reused slots take new leaves.
    for (&handles, 0..) |*h, i| h.* = try w.addBody(gpa, .{ .shape = .{ .sphere = .{ .radius = 0.5 } }, .pose = .at(.init(@floatFromInt(i * 2), 0, 0)) });
    try t.expect((try w.raycast(.init(4, 5, 0), .init(0, -1, 0), 10, .{})).?.body.eql(handles[2]));
    try t.expect(w.tree.consistent());
}
