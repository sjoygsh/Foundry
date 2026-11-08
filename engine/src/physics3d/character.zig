//! Capsule characters (`collision3d.md` §7). Caller owns velocity, gravity and time.
//!
//! **Everything vertical is along the world's `up`** (`collision-extras.md` §3): walkable,
//! horizontal, a step's rise, a snap, a ceiling, and the axis the capsule stands along. +Y unless
//! the world was given another.
const std = @import("std");
const core = @import("core");
const world = @import("world.zig");
const shape = @import("shape.zig");
const narrow = @import("narrow.zig");
const BodyHandle = @import("body.zig").BodyHandle;
const Vec3 = core.math.Vec3;
const Allocator = std.mem.Allocator;
const World = world.World;
const Hit = world.Hit;

pub const max_slide_iterations: u32 = 4;
pub const max_depenetration_iterations: u32 = 4;
pub const Characters = opaque {};
pub const CharacterHandle = core.Handle(Characters);
pub const CharacterConfig = struct {
    radius: f32,
    height: f32,
    max_slope: f32,
    step_height: f32,
    snap_distance: f32,
    max_move: f32,
    layer: u32 = 1,
    mask: u32 = ~@as(u32, 0),

    pub fn valid(c: CharacterConfig) bool {
        return std.math.isFinite(c.radius) and c.radius > 0 and
            std.math.isFinite(c.height) and c.height >= 2 * c.radius and
            std.math.isFinite(c.max_slope) and c.max_slope > 0 and c.max_slope < std.math.pi / 2.0 and
            std.math.isFinite(c.step_height) and c.step_height >= 0 and c.step_height <= c.height - 2 * c.radius and
            std.math.isFinite(c.snap_distance) and c.snap_distance >= 0 and c.snap_distance <= c.height and
            std.math.isFinite(c.max_move) and c.max_move > 0;
    }
};
pub const Ground = struct {
    surface_normal: Vec3,
    body: BodyHandle,
    user: u64,
    triangle: u32,
};
pub const Character = struct {
    body: BodyHandle,
    config: CharacterConfig,
    ground: ?Ground = null,
};
pub const CharacterMove = struct {
    feet: Vec3,
    grounded: bool = false,
    ground: ?Ground = null,
    ceiling: bool = false,
    walls: u32 = 0,
    stepped: f32 = 0,
    snapped: bool = false,
    depenetrated: bool = false,
    stuck: bool = false,
    hit_count: u32 = 0,
    total_hits: u32 = 0,
};
pub const AddCharacterError = error{ OutOfMemory, InvalidCharacter, InvalidPose };
pub const MoveCharacterError = error{InvalidMove};

fn centre(w: *const World, c: CharacterConfig, feet: Vec3) Vec3 {
    return feet.add(w.up.scale(c.height * 0.5));
}
fn feetOf(w: *World, c: Character) Vec3 {
    return w.body(c.body).?.pose.position.sub(w.up.scale(c.config.height * 0.5));
}
/// The capsule's pose with its feet at `feet`, standing along the world's up.
fn poseAt(w: *const World, c: CharacterConfig, feet: Vec3) shape.Pose {
    return .{ .position = centre(w, c, feet), .rotation = w.up_rotation };
}
fn convex(w: *const World, c: Character, feet: Vec3) shape.Convex {
    return .{ .core = .{ .segment = c.config.height * 0.5 - c.config.radius }, .radius = c.config.radius, .pose = poseAt(w, c.config, feet) };
}
fn validFeet(w: *const World, c: CharacterConfig, feet: Vec3) bool {
    return shape.positionValid(feet) and shape.positionValid(centre(w, c, feet));
}

pub fn add(w: *World, gpa: Allocator, config: CharacterConfig, feet: Vec3, user: u64) AddCharacterError!CharacterHandle {
    if (!config.valid()) return error.InvalidCharacter;
    if (!validFeet(w, config, feet)) return error.InvalidPose;
    const body = w.addBody(gpa, .{
        .shape = .{ .capsule = .{ .radius = config.radius, .half_height = config.height * 0.5 - config.radius } },
        .pose = poseAt(w, config, feet),
        .kind = .kinematic,
        .layer = config.layer,
        .mask = config.mask,
        .user = user,
    }) catch |err| return switch (err) {
        error.InvalidShape => error.InvalidCharacter,
        error.InvalidPose => error.InvalidPose,
        error.OutOfMemory => error.OutOfMemory,
    };
    errdefer _ = w.removeBody(gpa, body);
    return w.characters.add(gpa, .{ .body = body, .config = config });
}
pub fn remove(w: *World, gpa: Allocator, handle: CharacterHandle) bool {
    const c = w.characters.get(handle) orelse return false;
    _ = w.removeBody(gpa, c.body);
    return w.characters.remove(handle);
}
pub fn setFeet(w: *World, gpa: Allocator, handle: CharacterHandle, feet: Vec3) error{InvalidPose}!bool {
    _ = gpa; // No broadphase yet; kept for the same reason as World.setPose.
    const c = w.characters.get(handle) orelse return false;
    if (w.body(c.body) == null) return false;
    if (!validFeet(w, c.config, feet)) return error.InvalidPose;
    w.bodies.get(c.body).?.pose = poseAt(w, c.config, feet);
    c.ground = null;
    return true;
}

/// Whether a hit's face may be stood on, against `up`.
pub fn walkable(c: CharacterConfig, up: Vec3, hit: Hit) bool {
    return hit.surface_normal.dot(up) >= @cos(c.max_slope);
}
fn cast(w: *World, c: Character, feet: Vec3, by: Vec3) ?Hit {
    return w.characterCast(convex(w, c, feet), by, c.body, @cos(c.config.max_slope));
}
fn ground(w: *World, c: Character, feet: Vec3) ?Ground {
    const h = groundCast(w, c, feet, w.up.scale(-2 * narrow.contact_skin)) orelse return null;
    if (!walkable(c.config, w.up, h)) return null;
    return .{ .surface_normal = h.surface_normal, .body = h.body, .user = h.user, .triangle = h.triangle };
}
fn groundCast(w: *World, c: Character, feet: Vec3, by: Vec3) ?Hit {
    return w.characterProbe(convex(w, c, feet), by, c.body, @cos(c.config.max_slope));
}
fn record(r: *CharacterMove, out: []Hit, h: Hit) void {
    if (r.hit_count < out.len) {
        out[r.hit_count] = h;
        r.hit_count += 1;
    }
    r.total_hits += 1;
}
/// `v` with its part along `up` taken out.
fn horizontal(v: Vec3, up: Vec3) Vec3 {
    return v.sub(up.scale(v.dot(up)));
}
fn project(v: Vec3, n: Vec3) Vec3 {
    return v.sub(n.scale(@min(0, v.dot(n))));
}

pub fn move(w: *World, gpa: Allocator, handle: CharacterHandle, displacement: Vec3, hits: []Hit) MoveCharacterError!?CharacterMove {
    _ = gpa; // All steady-state controller work is allocation-free.
    const stored = w.characters.get(handle) orelse return null;
    if (w.body(stored.body) == null) return null;
    const c = stored.*;
    const up = w.up;
    // f64 avoids overflow turning a finite, huge displacement or limit into infinity.
    const dx: f64 = displacement.x;
    const dy: f64 = displacement.y;
    const dz: f64 = displacement.z;
    const limit: f64 = c.config.max_move;
    if (!displacement.isFinite() or dx * dx + dy * dy + dz * dz > limit * limit) return error.InvalidMove;
    const original = feetOf(w, c);
    if (!validFeet(w, c.config, original.add(displacement))) return error.InvalidMove;
    var r: CharacterMove = .{ .feet = original };
    var iteration: u32 = 0;
    // A scan that finds nothing is the answer; only running out of iterations needs another.
    var clear = false;
    while (iteration < max_depenetration_iterations) : (iteration += 1) {
        const contact = w.characterContact(convex(w, c, r.feet), c.body) orelse {
            clear = true;
            break;
        };
        r.feet = r.feet.add(contact.normal.scale(contact.depth + narrow.contact_skin));
        if (!validFeet(w, c.config, r.feet)) return error.InvalidMove;
        r.depenetrated = true;
    }
    // The ground under the final feet, kept when the snap check already asked for it.
    var probed: ??Ground = null;
    if (!clear and w.characterContact(convex(w, c, r.feet), c.body) != null) {
        r.stuck = true;
    } else {
        const start = r.feet;
        var remaining = displacement;
        iteration = 0;
        while (iteration < max_slide_iterations and remaining.lengthSquared() > 1e-12) : (iteration += 1) {
            const h = cast(w, c, r.feet, remaining) orelse {
                r.feet = r.feet.add(remaining);
                break;
            };
            record(&r, hits, h);
            r.feet = r.feet.add(remaining.scale(h.fraction)); // Cast already includes skin.
            remaining = remaining.scale(1 - h.fraction);
            if (h.surface_normal.dot(up) < 0 and remaining.dot(up) > 0) {
                r.ceiling = true;
                remaining = horizontal(remaining, up);
            }
            // A contact whose own normal is walkable supports the feet, even where the face
            // it touches is a wall: the top edge of a drop, met from above. Its tiny horizontal
            // part is not a wall's direction, and treating it as one stops a walk off the edge.
            if (walkable(c.config, up, h) or h.normal.dot(up) >= @cos(c.config.max_slope)) {
                remaining = project(remaining, h.normal);
            } else {
                r.walls += 1;
                const flat = horizontal(h.normal, up).normalize();
                const lateral = project(horizontal(remaining, up), flat);
                const requested_y = remaining.dot(up);
                const vertical = if (requested_y < 0) project(up.scale(requested_y), h.normal) else up.scale(requested_y);
                remaining = lateral.add(vertical);
                // Along up it may fall less than asked, never more, and never rise past what was asked.
                const now_y = remaining.dot(up);
                remaining = remaining.add(up.scale(@min(now_y, @max(0, requested_y)) - now_y));
            }
        }
        // A jumping move neither steps nor snaps. Speculative step casts record hits only
        // when accepted; discarded candidates cannot affect observable movement reports.
        if (c.ground != null and displacement.dot(up) <= 0 and r.walls > 0 and c.config.step_height > 0 and horizontal(displacement, up).lengthSquared() > 0) {
            const rise = up.scale(c.config.step_height);
            const lifted = cast(w, c, start, rise);
            var candidate_feet = start.add(rise.scale(if (lifted) |h| h.fraction else 1));
            const forward = horizontal(displacement, up);
            const across = cast(w, c, candidate_feet, forward);
            candidate_feet = candidate_feet.add(forward.scale(if (across) |h| h.fraction else 1));
            const down = up.scale(-(candidate_feet.sub(start).dot(up) + c.config.snap_distance));
            if (groundCast(w, c, candidate_feet, down)) |landing| {
                candidate_feet = candidate_feet.add(down.scale(landing.fraction));
                const gain = candidate_feet.sub(start).dot(up);
                if (walkable(c.config, up, landing) and landing.point.sub(start).dot(up) <= c.config.step_height + narrow.cast_tolerance and
                    gain > 0 and gain <= c.config.step_height + narrow.cast_tolerance and
                    horizontal(candidate_feet.sub(start), up).dot(forward) > horizontal(r.feet.sub(start), up).dot(forward))
                {
                    r.feet = candidate_feet;
                    r.stepped = gain;
                    if (lifted) |h| record(&r, hits, h);
                    if (across) |h| record(&r, hits, h);
                    record(&r, hits, landing);
                }
            }
        }
        if (c.ground != null and displacement.dot(up) <= 0 and c.config.snap_distance > 0) {
            probed = ground(w, c, r.feet);
            if (probed.? == null) {
                const down = up.scale(-c.config.snap_distance);
                if (groundCast(w, c, r.feet, down)) |h| {
                    if (walkable(c.config, up, h)) {
                        r.feet = r.feet.add(down.scale(h.fraction));
                        r.snapped = true;
                        record(&r, hits, h);
                        probed = null; // The feet moved.
                    }
                }
            }
        }
    }
    if (!validFeet(w, c.config, r.feet)) return error.InvalidMove;
    r.ground = if (r.stuck) null else probed orelse ground(w, c, r.feet);
    r.grounded = r.ground != null;
    w.bodies.get(c.body).?.pose = poseAt(w, c.config, r.feet);
    stored.ground = r.ground;
    return r;
}
