//! Capsule characters (`collision3d.md` §7). Caller owns velocity, gravity and time.
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

fn centre(c: CharacterConfig, feet: Vec3) Vec3 {
    return feet.add(.init(0, c.height * 0.5, 0));
}
fn feetOf(w: *World, c: Character) Vec3 {
    return w.body(c.body).?.pose.position.sub(.init(0, c.config.height * 0.5, 0));
}
fn convex(c: Character, feet: Vec3) shape.Convex {
    return .{ .core = .{ .segment = c.config.height * 0.5 - c.config.radius }, .radius = c.config.radius, .pose = .at(centre(c.config, feet)) };
}
fn validFeet(c: CharacterConfig, feet: Vec3) bool {
    return shape.positionValid(feet) and shape.positionValid(centre(c, feet));
}

pub fn add(w: *World, gpa: Allocator, config: CharacterConfig, feet: Vec3, user: u64) AddCharacterError!CharacterHandle {
    if (!config.valid()) return error.InvalidCharacter;
    if (!validFeet(config, feet)) return error.InvalidPose;
    const body = w.addBody(gpa, .{
        .shape = .{ .capsule = .{ .radius = config.radius, .half_height = config.height * 0.5 - config.radius } },
        .pose = .at(centre(config, feet)),
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
    if (!validFeet(c.config, feet)) return error.InvalidPose;
    w.bodies.get(c.body).?.pose = .at(centre(c.config, feet));
    c.ground = null;
    return true;
}

pub fn walkable(c: CharacterConfig, hit: Hit) bool {
    return hit.surface_normal.y >= @cos(c.max_slope);
}
fn cast(w: *World, c: Character, feet: Vec3, by: Vec3) ?Hit {
    return w.characterCast(convex(c, feet), by, c.body, @cos(c.config.max_slope));
}
fn ground(w: *World, c: Character, feet: Vec3) ?Ground {
    const h = groundCast(w, c, feet, .init(0, -2 * narrow.contact_skin, 0)) orelse return null;
    if (!walkable(c.config, h)) return null;
    return .{ .surface_normal = h.surface_normal, .body = h.body, .user = h.user, .triangle = h.triangle };
}
fn groundCast(w: *World, c: Character, feet: Vec3, by: Vec3) ?Hit {
    return w.characterProbe(convex(c, feet), by, c.body, @cos(c.config.max_slope));
}
fn record(r: *CharacterMove, out: []Hit, h: Hit) void {
    if (r.hit_count < out.len) {
        out[r.hit_count] = h;
        r.hit_count += 1;
    }
    r.total_hits += 1;
}
fn horizontal(v: Vec3) Vec3 {
    return .init(v.x, 0, v.z);
}
fn project(v: Vec3, n: Vec3) Vec3 {
    return v.sub(n.scale(@min(0, v.dot(n))));
}

pub fn move(w: *World, gpa: Allocator, handle: CharacterHandle, displacement: Vec3, hits: []Hit) MoveCharacterError!?CharacterMove {
    _ = gpa; // All steady-state controller work is allocation-free.
    const stored = w.characters.get(handle) orelse return null;
    if (w.body(stored.body) == null) return null;
    const c = stored.*;
    // f64 avoids overflow turning a finite, huge displacement or limit into infinity.
    const dx: f64 = displacement.x;
    const dy: f64 = displacement.y;
    const dz: f64 = displacement.z;
    const limit: f64 = c.config.max_move;
    if (!displacement.isFinite() or dx * dx + dy * dy + dz * dz > limit * limit) return error.InvalidMove;
    const original = feetOf(w, c);
    if (!validFeet(c.config, original.add(displacement))) return error.InvalidMove;
    var r: CharacterMove = .{ .feet = original };
    var iteration: u32 = 0;
    // A scan that finds nothing is the answer; only running out of iterations needs another.
    var clear = false;
    while (iteration < max_depenetration_iterations) : (iteration += 1) {
        const contact = w.characterContact(convex(c, r.feet), c.body) orelse {
            clear = true;
            break;
        };
        r.feet = r.feet.add(contact.normal.scale(contact.depth + narrow.contact_skin));
        if (!validFeet(c.config, r.feet)) return error.InvalidMove;
        r.depenetrated = true;
    }
    // The ground under the final feet, kept when the snap check already asked for it.
    var probed: ??Ground = null;
    if (!clear and w.characterContact(convex(c, r.feet), c.body) != null) {
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
            if (h.surface_normal.y < 0 and remaining.y > 0) {
                r.ceiling = true;
                remaining.y = 0;
            }
            if (walkable(c.config, h)) {
                remaining = project(remaining, h.normal);
            } else {
                r.walls += 1;
                const flat = horizontal(h.normal).normalize();
                const lateral = project(horizontal(remaining), flat);
                const vertical = if (remaining.y < 0) project(Vec3.init(0, remaining.y, 0), h.normal) else Vec3.init(0, remaining.y, 0);
                const requested_y = remaining.y;
                remaining = lateral.add(vertical);
                remaining.y = @min(remaining.y, @max(0, requested_y));
            }
        }
        // A jumping move neither steps nor snaps. Speculative step casts record hits only
        // when accepted; discarded candidates cannot affect observable movement reports.
        if (c.ground != null and displacement.y <= 0 and r.walls > 0 and c.config.step_height > 0 and horizontal(displacement).lengthSquared() > 0) {
            const rise = Vec3.init(0, c.config.step_height, 0);
            const up = cast(w, c, start, rise);
            var candidate_feet = start.add(rise.scale(if (up) |h| h.fraction else 1));
            const forward = horizontal(displacement);
            const across = cast(w, c, candidate_feet, forward);
            candidate_feet = candidate_feet.add(forward.scale(if (across) |h| h.fraction else 1));
            const down = Vec3.init(0, -(candidate_feet.y - start.y + c.config.snap_distance), 0);
            if (groundCast(w, c, candidate_feet, down)) |landing| {
                candidate_feet = candidate_feet.add(down.scale(landing.fraction));
                const gain = candidate_feet.y - start.y;
                if (walkable(c.config, landing) and landing.point.y - start.y <= c.config.step_height + narrow.cast_tolerance and
                    gain > 0 and gain <= c.config.step_height + narrow.cast_tolerance and
                    horizontal(candidate_feet.sub(start)).dot(forward) > horizontal(r.feet.sub(start)).dot(forward))
                {
                    r.feet = candidate_feet;
                    r.stepped = gain;
                    if (up) |h| record(&r, hits, h);
                    if (across) |h| record(&r, hits, h);
                    record(&r, hits, landing);
                }
            }
        }
        if (c.ground != null and displacement.y <= 0 and c.config.snap_distance > 0) {
            probed = ground(w, c, r.feet);
            if (probed.? == null) {
                const down = Vec3.init(0, -c.config.snap_distance, 0);
                if (groundCast(w, c, r.feet, down)) |h| {
                    if (walkable(c.config, h)) {
                        r.feet = r.feet.add(down.scale(h.fraction));
                        r.snapped = true;
                        record(&r, hits, h);
                        probed = null; // The feet moved.
                    }
                }
            }
        }
    }
    if (!validFeet(c.config, r.feet)) return error.InvalidMove;
    r.ground = if (r.stuck) null else probed orelse ground(w, c, r.feet);
    r.grounded = r.ground != null;
    w.bodies.get(c.body).?.pose = .at(centre(c.config, r.feet));
    stored.ground = r.ground;
    return r;
}
