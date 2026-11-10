//! The closed forms against GJK (`collision-scale.md` §8, M38 Step 5).
//!
//! GJK stays compiled for every other pair, and here it is the reference: `narrow`'s general
//! routines answer the same question the closed forms do, to GJK's tolerance.
const std = @import("std");
const core = @import("core");
const p = @import("root.zig");
const Pcg32 = core.rng.Pcg32;
const Quat = core.math.Quat;
const Vec3 = core.math.Vec3;
const Convex = p.shape.Convex;
const narrow = p.narrow;
const t = std.testing;

/// The rigid frames `collision3d.md`'s mesh tests use: at the origin, a few metres off and
/// turned, and over a kilometre out.
const frames = [_]p.Pose{
    .identity,
    .{ .position = .init(5, -2, 7), .rotation = Quat.fromAxisAngle(.init(1, 2, 3), 0.7) },
    .{ .position = .init(900, -300, 1200), .rotation = Quat.fromAxisAngle(.init(-2, 0.5, 1), -1.9) },
};

/// What f32 cannot hold at a frame's distance from the origin: nothing measured there agrees
/// more closely than this, by any routine.
fn rounding(frame: p.Pose) f32 {
    return 8 * std.math.floatEps(f32) * frame.position.length();
}

fn spread(rng: *Pcg32, reach: f32) Vec3 {
    return .init((rng.float01() * 2 - 1) * reach, (rng.float01() * 2 - 1) * reach, (rng.float01() * 2 - 1) * reach);
}

/// A triangle with some area, in its body's space.
fn triangle(rng: *Pcg32) [3]Vec3 {
    while (true) {
        const tri = [3]Vec3{ spread(rng, 2), spread(rng, 2), spread(rng, 2) };
        if (Vec3.cross(tri[1].sub(tri[0]), tri[2].sub(tri[0])).length() > 0.2) return tri;
    }
}

fn turn(rng: *Pcg32) Quat {
    return Quat.fromAxisAngle(Vec3.init(rng.float01() - 0.5, rng.float01() + 0.1, rng.float01() - 0.5).normalize(), rng.float01() * 6);
}

/// How far `point` is from the triangle's plane and from its inside, by its own arithmetic.
fn onTriangle(point: Vec3, tri: [3]Vec3) f32 {
    return p.pairs.pointTriangle(point, tri).distance;
}

const Tally = struct {
    compared: u32 = 0,
    /// The cores met, where both routes are GJK's and there is nothing to compare.
    met: u32 = 0,
    witness_agreed: u32 = 0,
    worst_distance: f32 = 0,
};

fn compare(a: Convex, b: Convex, frame: p.Pose, tally: *Tally) !void {
    const closed = narrow.separation(a, b);
    const general = narrow.separationGeneral(a, b);
    try t.expectEqual(general.cores_intersect, closed.cores_intersect);
    if (closed.cores_intersect) {
        // The same route, so the same bits.
        try t.expectEqualDeep(general, closed);
        tally.met += 1;
        return;
    }
    const slack = rounding(frame);
    tally.compared += 1;
    tally.worst_distance = @max(tally.worst_distance, @abs(closed.distance - general.distance) - slack);
    try t.expectApproxEqAbs(general.distance, closed.distance, 2e-6 + slack);
    // The closed form's own witnesses are what it says: on each shape, the distance apart,
    // and the normal is the way between them.
    const local = b.core.triangle;
    const tri = [3]Vec3{ b.pose.apply(local[0]), b.pose.apply(local[1]), b.pose.apply(local[2]) };
    try t.expect(onTriangle(closed.point_b, tri) <= 2e-6 + slack);
    const between = closed.point_a.sub(closed.point_b);
    try t.expectApproxEqAbs(closed.distance, between.dot(closed.normal), 2e-6 + slack);
    try t.expectApproxEqAbs(@as(f32, 1), closed.normal.length(), 1e-5);
    // GJK finds the distance to its tolerance, and a witness only as well as that pins one
    // down. Where the nearest point is one point, the two agree.
    if (closed.point_b.sub(general.point_b).length() <= 1e-4 + slack and closed.normal.dot(general.normal) > 0.9999) tally.witness_agreed += 1;
}

test "closed forms: a point against a triangle is GJK's answer, over 100,000 configurations" {
    var rng = Pcg32.init(1, 85);
    var tally: Tally = .{};
    for (0..100_000) |i| {
        const frame = frames[i % frames.len];
        const body: p.Pose = .{ .position = frame.position, .rotation = frame.rotation.mul(turn(&rng)).normalize() };
        const b: Convex = .{ .core = .{ .triangle = triangle(&rng) }, .radius = 0, .pose = body };
        const a: Convex = .{ .core = .point, .radius = rng.float01() * 0.5, .pose = .at(frame.position.add(spread(&rng, 3))) };
        try compare(a, b, frame, &tally);
    }
    try t.expectEqual(@as(u32, 100_000), tally.compared);
    // A point's nearest point on a triangle is one point, so nearly every witness agrees. The
    // rest are GJK's: its tolerance is on the distance, which leaves a far witness loose.
    try t.expect(tally.witness_agreed * 1000 > tally.compared * 999);
    try t.expect(tally.worst_distance <= 2e-6);
}

test "closed forms: a segment against a triangle is GJK's answer, over 100,000 configurations" {
    var rng = Pcg32.init(2, 85);
    var tally: Tally = .{};
    for (0..100_000) |i| {
        const frame = frames[i % frames.len];
        const body: p.Pose = .{ .position = frame.position, .rotation = frame.rotation.mul(turn(&rng)).normalize() };
        const b: Convex = .{ .core = .{ .triangle = triangle(&rng) }, .radius = 0, .pose = body };
        // One in eight stands upright in the frame, as a character does.
        const rotation = if (i % 8 == 0) frame.rotation else turn(&rng);
        const a: Convex = .{ .core = .{ .segment = 0.1 + rng.float01() * 1.2 }, .radius = rng.float01() * 0.5, .pose = .{ .position = frame.position.add(spread(&rng, 3)), .rotation = rotation } };
        try compare(a, b, frame, &tally);
    }
    // A segment through a triangle's face is the cores meeting, which is GJK's on both routes.
    try t.expect(tally.compared > 99_000 and tally.met > 500);
    try t.expect(tally.witness_agreed * 1000 > tally.compared * 999);
    try t.expect(tally.worst_distance <= 2e-6);
}

test "closed forms: a ray's hit is a true crossing, and the general cast's wherever that finds one, over 100,000 rays" {
    var rng = Pcg32.init(3, 85);
    var both: u32 = 0;
    var neither: u32 = 0;
    var rim: u32 = 0;
    // Real crossings the general cast does not report, near the origin and a kilometre out.
    var lost = [2]u32{ 0, 0 };
    for (0..100_000) |i| {
        const frame = frames[i % frames.len];
        const body: p.Pose = .{ .position = frame.position, .rotation = frame.rotation.mul(turn(&rng)).normalize() };
        const local = triangle(&rng);
        const b: Convex = .{ .core = .{ .triangle = local }, .radius = 0, .pose = body };
        const tri = [3]Vec3{ body.apply(local[0]), body.apply(local[1]), body.apply(local[2]) };
        const origin = frame.position.add(spread(&rng, 3));
        // Most rays are aimed at the triangle, and the rest anywhere.
        const weights = [3]f32{ rng.float01(), rng.float01(), rng.float01() };
        const sum = weights[0] + weights[1] + weights[2] + 1e-3;
        const aim = if (i % 4 == 3) frame.position.add(spread(&rng, 3)) else tri[0].scale(weights[0] / sum).add(tri[1].scale(weights[1] / sum)).add(tri[2].scale((weights[2] + 1e-3) / sum));
        const along = aim.sub(origin).scale(0.5 + rng.float01() * 2);
        if (along.length() < 0.05) continue;
        const ray: Convex = .{ .core = .point, .radius = 0, .pose = .at(origin) };
        const closed = narrow.cast(ray, along, b, 0);
        const general = narrow.castGeneral(ray, along, b, 0);
        const slack = rounding(frame);
        // The ray as a segment, measured against the triangle another way: by the plane and
        // the face's regions, where the ray's own routine uses the three edges.
        const near = p.pairs.segmentTriangle(origin, origin.add(along), tri);
        if (closed) |c| {
            try t.expect(near.distance <= 3e-5 + 4 * slack);
            try t.expect(c.fraction >= 0 and c.fraction <= 1 and !c.started_inside);
            try t.expect(onTriangle(c.point, tri) <= 3e-5 + 4 * slack);
            if (c.fraction > 0) try t.expect(c.normal.dot(along) < 0);
            const g = general orelse {
                // The general cast gave up on a ray that does cross. A ray has no radius, so
                // near the face its normal comes from two points a rounding apart, and an
                // advance that lands a hair past the face reads as moving away.
                try t.expectEqual(@as(f32, 0), near.distance);
                lost[@intFromBool(i % frames.len == 2)] += 1;
                continue;
            };
            both += 1;
            // The general cast stops within its tolerance of the face, measured across it. The
            // closed form stops on it. Along a slanting ray that is further apart.
            const closing = -along.dot(b.surfaceNormal(along.neg(), tri[0]));
            try t.expect(@abs(c.fraction - g.fraction) * closing <= 3e-5 + 4 * slack);
            if (g.fraction > 0 and c.fraction > 0) try t.expect(c.normal.dot(g.normal) > 0.999);
        } else if (general != null) {
            // The general cast hits whatever the ray comes within its tolerance of: the rim of
            // the triangle, or a face the ray stops a hair short of. A crossing is neither.
            rim += 1;
            try t.expect(near.distance <= 3e-5 + 4 * slack);
        } else {
            neither += 1;
            // No crossing was missed by both. A kilometre out the triangle's corners in the
            // world and in its own space differ by a rounding, and so may which side of an
            // edge a ray passes.
            if (i % frames.len != 2) try t.expect(near.distance > 0);
        }
    }
    try t.expect(both > 40_000 and neither > 10_000);
    try t.expect(rim * 100 < both);
    // Near the origin the general cast loses a few in a thousand. A kilometre out it loses
    // about half, which is what this step's Resolution records.
    try t.expect(lost[0] * 100 < both);
    try t.expect(lost[1] > lost[0]);
}

test "closed forms: a cast never passes through, and stops where the general cast does" {
    var rng = Pcg32.init(4, 85);
    var hits: u32 = 0;
    var worst: f32 = 0;
    for (0..20_000) |i| {
        const frame = frames[i % 2];
        const body: p.Pose = .{ .position = frame.position, .rotation = frame.rotation.mul(turn(&rng)).normalize() };
        const b: Convex = .{ .core = .{ .triangle = triangle(&rng) }, .radius = 0, .pose = body };
        const start = frame.position.add(spread(&rng, 3));
        const a: Convex = if (i % 2 == 0)
            .{ .core = .point, .radius = 0.05 + rng.float01() * 0.4, .pose = .at(start) }
        else
            .{ .core = .{ .segment = 0.2 + rng.float01() }, .radius = 0.05 + rng.float01() * 0.4, .pose = .{ .position = start, .rotation = if (i % 4 == 1) frame.rotation else turn(&rng) } };
        const along = frame.position.add(spread(&rng, 1.5)).sub(start).scale(1.5);
        const closed = narrow.cast(a, along, b, p.contact_skin) orelse {
            // Whatever it did not hit, the shape at its journey's end is not inside.
            try t.expect(narrow.separationGeneral(a.translated(along), b).distance > -1e-5);
            continue;
        };
        if (closed.started_inside) continue;
        // At its stopping place it is at least the skin, less the tolerance, from the triangle,
        // by GJK's measure and not its own.
        const stopped = narrow.separationGeneral(a.translated(along.scale(closed.fraction)), b);
        const slack = rounding(frame);
        // One that began nearer than the skin has not moved, and is no nearer than it began.
        if (closed.fraction == 0) {
            try t.expect(stopped.distance >= 0);
            continue;
        }
        try t.expect(stopped.distance >= p.contact_skin - narrow.cast_tolerance - 2e-6 - slack);
        hits += 1;
        if (narrow.castGeneral(a, along, b, p.contact_skin)) |general| {
            worst = @max(worst, @abs(general.fraction - closed.fraction) * along.length());
        }
    }
    try t.expect(hits > 3_000);
    // The two stop within the cast's tolerance of each other along the way, a slant aside.
    try t.expect(worst < 1e-3);
}

test "closed forms: no ray slips through a mesh's seams or corners" {
    // A closed shape: a bumpy ball of triangles. A ray from inside it to far outside must
    // cross a triangle, and rays aimed at corners and along seams are the ones that could fail.
    const rings = 9;
    const around = 12;
    var corners: [(rings + 1) * around]Vec3 = undefined;
    var rng = Pcg32.init(8, 38);
    for (0..rings + 1) |i| for (0..around) |j| {
        const polar = @as(f32, @floatFromInt(i)) * std.math.pi / rings;
        const angle = @as(f32, @floatFromInt(j)) * std.math.tau / around;
        const r: f32 = 0.8 + rng.float01() * 0.4;
        // Every corner of the first and last ring is the same pole.
        corners[i * around + j] = if (i == 0) .init(0, 1, 0) else if (i == rings) .init(0, -1, 0) else .init(r * @sin(polar) * @cos(angle), r * @cos(polar), r * @sin(polar) * @sin(angle));
    };
    var triangles: [rings * around * 2][3]Vec3 = undefined;
    var count: usize = 0;
    for (0..rings) |i| for (0..around) |j| {
        const a = corners[i * around + j];
        const b = corners[i * around + (j + 1) % around];
        const c = corners[(i + 1) * around + j];
        const d = corners[(i + 1) * around + (j + 1) % around];
        // Each pole's fan has a triangle of no area in every square, which is left out.
        if (i != 0) {
            triangles[count] = .{ a, b, c };
            count += 1;
        }
        if (i != rings - 1) {
            triangles[count] = .{ b, d, c };
            count += 1;
        }
    };
    var several: usize = 0;
    for (0..12_000) |round| {
        // The ball at the origin, turned a few metres off, and a kilometre out and larger.
        const frame = frames[round % frames.len];
        const scale: f32 = if (round % frames.len == 2) 40 else 1;
        const origin_local = spread(&rng, 0.2 * scale);
        // A third of the rays go exactly at a corner, a third at a point of a seam.
        const one = triangles[rng.below(@intCast(count))];
        const target_local: Vec3 = switch ((round / 3) % 3) {
            0 => one[rng.below(3)].scale(scale),
            1 => one[0].lerp(one[1], rng.float01()).scale(scale),
            else => spread(&rng, 0.5 * scale),
        };
        const way = target_local.sub(origin_local);
        if (way.length() < 0.1 * scale) continue;
        const ray: Convex = .{ .core = .point, .radius = 0, .pose = .at(frame.apply(origin_local)) };
        const along = frame.applyDirection(way.scale(3 * scale / way.length()));
        var hits: usize = 0;
        for (triangles[0..count]) |tri| {
            const b: Convex = .{ .core = .{ .triangle = .{ tri[0].scale(scale), tri[1].scale(scale), tri[2].scale(scale) } }, .radius = 0, .pose = frame };
            hits += @intFromBool(narrow.cast(ray, along, b, 0) != null);
        }
        try t.expect(hits >= 1);
        several += @intFromBool(hits >= 2);
    }
    // Rays at corners and seams did land on more than one triangle.
    try t.expect(several > 1_000);
}

test "closed forms: a ray's hit is on the triangle itself, at the triangle's own height" {
    // A level floor. Slanting rays land on it at exactly its height, as GJK's witness did: the
    // point is the triangle's corners weighed, and not the ray's origin plus a rounded length.
    const floor: Convex = .{ .core = .{ .triangle = .{ .init(-10, 0, -10), .init(0, 0, 10), .init(10, 0, -10) } }, .radius = 0, .pose = .identity };
    var rng = Pcg32.init(12, 85);
    for (0..2_000) |_| {
        const origin: Vec3 = .init(rng.float01() * 4 - 2, 0.3 + rng.float01() * 3, rng.float01() * 4 - 2);
        const along: Vec3 = .init(rng.float01() * 2 - 1, -3.7, rng.float01() * 2 - 1);
        const hit = narrow.cast(.{ .core = .point, .radius = 0, .pose = .at(origin) }, along, floor, 0).?;
        try t.expectEqual(@as(f32, 0), hit.point.y);
        try t.expect(hit.normal.eql(.init(0, 1, 0)));
        try t.expect(hit.point.sub(origin.add(along.scale(hit.fraction))).length() < 1e-5);
    }
    // From below it is the other side's normal.
    const under = narrow.cast(.{ .core = .point, .radius = 0, .pose = .at(.init(0, -2, 0)) }, .init(0.3, 4, 0.1), floor, 0).?;
    try t.expect(under.normal.eql(.init(0, -1, 0)));
    try t.expectEqual(@as(f32, 0.5), under.fraction);

    // A ray that starts on the floor, or a hair under it by rounding, has already arrived: it
    // hits at once, as it always did, where a crossing alone would find the floor behind it.
    for ([_]f32{ 0, 5e-6, -5e-6 }) |height| {
        const down = narrow.cast(.{ .core = .point, .radius = 0, .pose = .at(.init(1, height, 1)) }, .init(0, -2, 0), floor, 0).?;
        try t.expectEqual(@as(f32, 0), down.fraction);
        try t.expect(!down.started_inside);
    }
}

test "closed forms: over a face the contact normal is the face's own, and cores that meet are GJK's" {
    var rng = Pcg32.init(13, 85);
    for (0..2_000) |i| {
        const frame = frames[i % frames.len];
        const body: p.Pose = .{ .position = frame.position, .rotation = frame.rotation.mul(turn(&rng)).normalize() };
        const local = [3]Vec3{ .init(-3, 0, -3), .init(0, 0, 3), .init(3, 0, -3) };
        const b: Convex = .{ .core = .{ .triangle = local }, .radius = 0, .pose = body };
        // A sphere and a capsule a little over the middle of the face.
        const over = body.apply(.init(rng.float01() - 0.5, 0.2 + rng.float01(), rng.float01() - 0.5));
        const a: Convex = if (i % 2 == 0) .{ .core = .point, .radius = 0.1, .pose = .at(over) } else .{ .core = .{ .segment = 0.1 }, .radius = 0.05, .pose = .{ .position = over, .rotation = body.rotation } };
        const s = narrow.separation(a, b);
        // The same bits the hit's surface normal has, so the two can be compared without a tolerance.
        try t.expect(s.normal.eql(b.surfaceNormal(body.applyDirection(.init(0, 1, 0)), over)));
    }
    // A point within GJK's own idea of touching is a meeting of cores on both routes, and is
    // answered by the route that answers depth.
    const level: Convex = .{ .core = .{ .triangle = .{ .init(-3, 0, -3), .init(0, 0, 3), .init(3, 0, -3) } }, .radius = 0, .pose = .identity };
    for ([_]f32{ 0, 2e-7, 9e-7 }) |height| {
        const ball: Convex = .{ .core = .point, .radius = 0.25, .pose = .at(.init(0.1, height, 0.2)) };
        const closed = narrow.separation(ball, level);
        try t.expect(closed.cores_intersect);
        try t.expectEqualDeep(narrow.separationGeneral(ball, level), closed);
    }
    try t.expect(!narrow.separation(.{ .core = .point, .radius = 0.25, .pose = .at(.init(0.1, 2e-6, 0.2)) }, level).cores_intersect);
}

test "closed forms: a slide into the seam of a riser and its tread is the riser's, however the step is turned" {
    // A 30 cm step. The capsule's lower end is 5 mm over the tread, so the nearest point of the
    // mesh is on the edge the riser and the tread share, and both triangles are met at once.
    var worlds: usize = 0;
    var rng = Pcg32.init(14, 85);
    for (0..200) |_| {
        var w: p.World = .empty;
        defer w.deinit(t.allocator);
        const yaw = Quat.fromAxisAngle(.init(0, 1, 0), rng.float01() * 6);
        const pose: p.Pose = .{ .position = .init(rng.float01() * 40 - 20, 0, rng.float01() * 40 - 20), .rotation = yaw };
        const mesh = try w.addMesh(t.allocator, &.{ .init(1, 0, -2), .init(1, 0.3, -2), .init(1, 0.3, 2), .init(1, 0, 2), .init(4, 0.3, -2), .init(4, 0.3, 2) }, &.{ 0, 1, 2, 0, 2, 3, 1, 4, 5, 1, 5, 2 });
        _ = try w.addBody(t.allocator, .{ .shape = .{ .mesh = mesh }, .pose = pose });
        const actor = try w.addBody(t.allocator, .{ .shape = .{ .sphere = .{ .radius = 0.01 } }, .pose = .at(.init(0, 50, 0)), .kind = .kinematic });
        const z = rng.float01() * 2 - 1;
        const capsule: Convex = .{ .core = .{ .segment = 0.6 }, .radius = 0.3, .pose = .{ .position = pose.apply(.init(0.4, 0.905, z)), .rotation = yaw } };
        const hit = w.characterCast(capsule, pose.applyDirection(.init(0.6, 0, 0)), actor, @cos(std.math.pi / 4.0)).?;
        // The riser is triangles 0 and 1, and the tread 2 and 3.
        try t.expect(hit.triangle < 2);
        try t.expect(hit.surface_normal.dot(pose.applyDirection(.init(-1, 0, 0))) > 0.999);
        worlds += 1;
    }
    try t.expectEqual(@as(usize, 200), worlds);
}
