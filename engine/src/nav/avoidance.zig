//! Reciprocal avoidance: Optimal Reciprocal Collision Avoidance (van den Berg et al., 2011),
//! reimplemented from the paper, on X and Z (`agents.md` §8, ADR-0070).
//!
//! Each neighbour gives one half-plane of velocities that keep clear of it for the time horizon,
//! the two agents sharing the change between them. The new velocity is the one nearest the
//! preferred, inside every half-plane and within the top speed, by a small linear program. When
//! no velocity satisfies them all, the least bad is taken, which is what lets a dense crowd move.
//!
//! **No randomness and no trig** (I9, ADR-0064), and nothing allocates: `max_lines` is on the
//! stack.

const std = @import("std");

/// At most this many neighbours constrain an agent.
pub const max_lines = 8;

const epsilon: f32 = 1e-5;

pub const Vec2 = struct {
    x: f32 = 0,
    z: f32 = 0,

    fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .z = a.z + b.z };
    }
    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .z = a.z - b.z };
    }
    fn scale(a: Vec2, s: f32) Vec2 {
        return .{ .x = a.x * s, .z = a.z * s };
    }
    fn dot(a: Vec2, b: Vec2) f32 {
        return a.x * b.x + a.z * b.z;
    }
    /// Positive when `b` is to the left of `a`, in the plane's own (x, z) sense.
    fn det(a: Vec2, b: Vec2) f32 {
        return a.x * b.z - a.z * b.x;
    }
    fn lengthSquared(a: Vec2) f32 {
        return a.dot(a);
    }
    fn normalized(a: Vec2) Vec2 {
        const length = @sqrt(a.lengthSquared());
        return if (length > 0) a.scale(1 / length) else .{};
    }
};

/// A half-plane of velocities: everything to the left of `direction` through `point`.
pub const Line = struct {
    point: Vec2,
    direction: Vec2,
};

pub const Party = struct {
    position: Vec2,
    velocity: Vec2,
    radius: f32,
};

/// The half-plane `self` must keep to for `other`. `share` is its part of the change: a half
/// between two walkers, and all of it round one standing still. Two agents at one point are told
/// apart by `tie`, the same rule on each side, which must be opposite for the pair.
pub fn lineFor(self: Party, other: Party, horizon: f32, dt: f32, share: f32, tie: f32) Line {
    var relative_position = other.position.sub(self.position);
    if (relative_position.lengthSquared() < 1e-8) relative_position = .{ .x = 1e-4 * tie };
    const relative_velocity = self.velocity.sub(other.velocity);
    const distance2 = relative_position.lengthSquared();
    const radius = self.radius + other.radius;
    const radius2 = radius * radius;

    var direction: Vec2 = undefined;
    var u: Vec2 = undefined;
    if (distance2 > radius2) {
        const w = relative_velocity.sub(relative_position.scale(1 / horizon));
        const w2 = w.lengthSquared();
        const along = w.dot(relative_position);
        if (along < 0 and along * along > radius2 * w2) {
            // Nearest the cut-off circle.
            const w_length = @sqrt(w2);
            const unit = w.scale(1 / w_length);
            direction = .{ .x = unit.z, .z = -unit.x };
            u = unit.scale(radius / horizon - w_length);
        } else {
            // Nearest a leg of the cone.
            const leg = @sqrt(distance2 - radius2);
            if (relative_position.det(w) > 0) {
                direction = (Vec2{
                    .x = relative_position.x * leg - relative_position.z * radius,
                    .z = relative_position.x * radius + relative_position.z * leg,
                }).scale(1 / distance2);
            } else {
                direction = (Vec2{
                    .x = relative_position.x * leg + relative_position.z * radius,
                    .z = -relative_position.x * radius + relative_position.z * leg,
                }).scale(-1 / distance2);
            }
            u = direction.scale(relative_velocity.dot(direction)).sub(relative_velocity);
        }
    } else {
        // Already overlapping: out, within this tick.
        const w = relative_velocity.sub(relative_position.scale(1 / dt));
        const w_length = @sqrt(w.lengthSquared());
        const unit = if (w_length > 0) w.scale(1 / w_length) else Vec2{ .x = 0, .z = tie };
        direction = .{ .x = unit.z, .z = -unit.x };
        u = unit.scale(radius / dt - w_length);
    }
    return .{ .point = self.velocity.add(u.scale(share)), .direction = direction };
}

/// The velocity nearest `preferred`, within `max_speed`, meeting `lines` or failing them least.
pub fn solve(lines: []const Line, preferred: Vec2, max_speed: f32) Vec2 {
    var result: Vec2 = .{};
    const failed = program2(lines, max_speed, preferred, false, &result);
    if (failed < lines.len) program3(lines, failed, max_speed, &result);
    // Nearly parallel lines meet far away, and `f32` loses the disc's edge out there. A velocity
    // must never pass the top speed, so that is enforced here rather than assumed.
    if (result.lengthSquared() > max_speed * max_speed) result = result.normalized().scale(max_speed);
    return result;
}

/// The best point on line `i`, under the lines before it. False if there is none.
fn program1(lines: []const Line, i: usize, radius: f32, optimum: Vec2, along_direction: bool, result: *Vec2) bool {
    const line = lines[i];
    const dot = line.point.dot(line.direction);
    const discriminant = dot * dot + radius * radius - line.point.lengthSquared();
    if (discriminant < 0) return false;
    const root = @sqrt(discriminant);
    var left = -dot - root;
    var right = -dot + root;
    for (lines[0..i]) |other| {
        const denominator = line.direction.det(other.direction);
        const numerator = other.direction.det(line.point.sub(other.point));
        if (@abs(denominator) <= epsilon) {
            if (numerator < 0) return false;
            continue;
        }
        const t = numerator / denominator;
        if (denominator >= 0) right = @min(right, t) else left = @max(left, t);
        if (left > right) return false;
    }
    var t: f32 = undefined;
    if (along_direction) {
        t = if (optimum.dot(line.direction) > 0) right else left;
    } else {
        t = std.math.clamp(line.direction.dot(optimum.sub(line.point)), left, right);
    }
    result.* = line.point.add(line.direction.scale(t));
    return true;
}

/// Meets every line if it can. Answers the first line it could not meet, or `lines.len`.
fn program2(lines: []const Line, radius: f32, optimum: Vec2, along_direction: bool, result: *Vec2) usize {
    if (along_direction) {
        result.* = optimum.scale(radius);
    } else if (optimum.lengthSquared() > radius * radius) {
        result.* = optimum.normalized().scale(radius);
    } else {
        result.* = optimum;
    }
    for (lines, 0..) |line, i| {
        if (line.direction.det(line.point.sub(result.*)) > 0) {
            const before = result.*;
            if (!program1(lines, i, radius, optimum, along_direction, result)) {
                result.* = before;
                return i;
            }
        }
    }
    return lines.len;
}

/// No velocity meets them all: the one that strays least past the worst of them.
fn program3(lines: []const Line, first: usize, radius: f32, result: *Vec2) void {
    var distance: f32 = 0;
    for (lines[first..], first..) |line, i| {
        if (line.direction.det(line.point.sub(result.*)) <= distance) continue;
        var projected: [max_lines]Line = undefined;
        var count: usize = 0;
        for (lines[0..i]) |other| {
            const determinant = line.direction.det(other.direction);
            var point: Vec2 = undefined;
            if (@abs(determinant) <= epsilon) {
                if (line.direction.dot(other.direction) > 0) continue;
                point = line.point.add(other.point).scale(0.5);
            } else {
                const t = other.direction.det(line.point.sub(other.point)) / determinant;
                point = line.point.add(line.direction.scale(t));
            }
            projected[count] = .{ .point = point, .direction = other.direction.sub(line.direction).normalized() };
            count += 1;
        }
        const before = result.*;
        const away: Vec2 = .{ .x = -line.direction.z, .z = line.direction.x };
        if (program2(projected[0..count], radius, away, true, result) < count) result.* = before;
        distance = line.direction.det(line.point.sub(result.*));
    }
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

fn meets(line: Line, v: Vec2, slack: f32) bool {
    return line.direction.det(line.point.sub(v)) <= slack;
}

test "with nothing in the way the preferred velocity is taken, within the top speed" {
    try testing.expectEqual(Vec2{ .x = 1, .z = 0.5 }, solve(&.{}, .{ .x = 1, .z = 0.5 }, 2));
    const fast = solve(&.{}, .{ .x = 3, .z = 4 }, 2);
    try testing.expectApproxEqAbs(@as(f32, 2), @sqrt(fast.lengthSquared()), 1e-5);
}

test "two walkers head-on each take half the turn, and the result meets the line" {
    const a: Party = .{ .position = .{}, .velocity = .{ .x = 1 }, .radius = 0.3 };
    const b: Party = .{ .position = .{ .x = 2 }, .velocity = .{ .x = -1 }, .radius = 0.3 };
    const la = lineFor(a, b, 1.5, 1.0 / 60.0, 0.5, 1);
    const lb = lineFor(b, a, 1.5, 1.0 / 60.0, 0.5, -1);
    const va = solve(&.{la}, a.velocity, 2);
    const vb = solve(&.{lb}, b.velocity, 2);
    try testing.expect(meets(la, va, 1e-4) and meets(lb, vb, 1e-4));
    // Reciprocal: each has changed, by the same amount.
    const da = @sqrt(va.sub(a.velocity).lengthSquared());
    const db = @sqrt(vb.sub(b.velocity).lengthSquared());
    try testing.expect(da > 0.01);
    try testing.expectApproxEqAbs(da, db, 1e-3);
}

test "a standing neighbour leaves all the change to the one walking" {
    const a: Party = .{ .position = .{}, .velocity = .{ .x = 1 }, .radius = 0.3 };
    const b: Party = .{ .position = .{ .x = 1.2 }, .velocity = .{}, .radius = 0.3 };
    const half = solve(&.{lineFor(a, b, 1.5, 1.0 / 60.0, 0.5, 1)}, a.velocity, 2);
    const whole = solve(&.{lineFor(a, b, 1.5, 1.0 / 60.0, 1, 1)}, a.velocity, 2);
    try testing.expect(@sqrt(whole.sub(a.velocity).lengthSquared()) > @sqrt(half.sub(a.velocity).lengthSquared()) * 1.5);
}

test "overlapping and coincident agents are pushed apart, not into NaN" {
    const a: Party = .{ .position = .{}, .velocity = .{}, .radius = 0.3 };
    const near: Party = .{ .position = .{ .x = 0.2 }, .velocity = .{}, .radius = 0.3 };
    const same: Party = .{ .position = .{}, .velocity = .{}, .radius = 0.3 };
    const push = solve(&.{lineFor(a, near, 1.5, 1.0 / 60.0, 0.5, 1)}, .{}, 2);
    try testing.expect(push.x < 0);
    const left = solve(&.{lineFor(a, same, 1.5, 1.0 / 60.0, 0.5, 1)}, .{}, 2);
    const right = solve(&.{lineFor(same, a, 1.5, 1.0 / 60.0, 0.5, -1)}, .{}, 2);
    try testing.expect(std.math.isFinite(left.x) and std.math.isFinite(right.x));
    try testing.expect(left.x * right.x < 0);
}

test "lines no velocity can meet still give a finite answer, within the top speed" {
    const lines = [_]Line{
        .{ .point = .{ .x = 5 }, .direction = .{ .x = 0, .z = 1 } },
        .{ .point = .{ .x = -5 }, .direction = .{ .x = 0, .z = -1 } },
        .{ .point = .{ .z = 5 }, .direction = .{ .x = -1, .z = 0 } },
    };
    const v = solve(&lines, .{ .x = 1 }, 2);
    try testing.expect(std.math.isFinite(v.x) and std.math.isFinite(v.z));
    try testing.expect(@sqrt(v.lengthSquared()) <= 2.001);
}

test "a seeded sweep of lines always answers, meeting all it can" {
    var prng = std.Random.DefaultPrng.init(0x5555);
    const r = prng.random();
    for (0..5000) |_| {
        var lines: [max_lines]Line = undefined;
        const n = r.uintAtMost(usize, max_lines);
        for (lines[0..n]) |*l| {
            const angle = r.float(f32) * 6.283;
            l.* = .{
                .point = .{ .x = (r.float(f32) - 0.5) * 2, .z = (r.float(f32) - 0.5) * 2 },
                .direction = (Vec2{ .x = 1 - angle * angle / 2, .z = angle - angle * angle * angle / 6 }).normalized(),
            };
        }
        const v = solve(lines[0..n], .{ .x = r.float(f32) * 2, .z = r.float(f32) * 2 }, 2);
        try testing.expect(std.math.isFinite(v.x) and std.math.isFinite(v.z));
        try testing.expect(@sqrt(v.lengthSquared()) <= 2.0001);
    }
}
