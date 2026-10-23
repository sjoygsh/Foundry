//! Live particles into quads: four vertices and six indices each, facing the view, in draw order
//! (`docs/design/particles.md` §3.3).
//!
//! **Output is world space.** A `local` emitter's particles are carried by its transform here,
//! so the mesh is drawn with an identity world and its bounds are the vertices' own.
//!
//! **The order is decided before the split.** A blended emitter is sorted back to front by view
//! depth, ties by spawn serial, which is a total order; an opaque or masked one keeps spawn
//! order. Then `core.Jobs` writes fixed chunks of that order, each into its own slice of the
//! output and its own bounds slot, combined in chunk order. So the bytes do not depend on how
//! many workers ran (ADR-0036).
//!
//! Angles go through `trig`, never `@sin`, for `trig.zig`'s reason: the vertices are pinned.

const std = @import("std");
const core = @import("core");
const emitter_mod = @import("emitter.zig");
const system_mod = @import("system.zig");
const trig = @import("trig.zig");

const Allocator = std.mem.Allocator;
const Jobs = core.Jobs;
const Mat4 = core.math.Mat4;
const Vec3 = core.math.Vec3;
const Emitter = emitter_mod.Emitter;
const System = system_mod.System;
const Aabb = system_mod.Aabb;

/// Quads per chunk: a named constant of the work, never a worker count (ADR-0036).
pub const grain: u32 = 256;
pub const max_chunks = (emitter_mod.max_capacity + grain - 1) / grain;

pub const vertices_per_quad = 4;
pub const indices_per_quad = 6;

/// The camera, in world space: where it is and its unit right, up and forward (into the screen,
/// its −Z, ADR-0048) axes.
pub const View = struct {
    eye: Vec3,
    right: Vec3,
    up: Vec3,
    forward: Vec3,

    /// From a camera's world transform, which maps its local axes to world ones.
    pub fn fromCamera(world: Mat4) View {
        return .{
            .eye = world.mulVec4(.fromPoint(.zero)).xyz(),
            .right = world.mulVec4(.fromDirection(.right)).xyz().normalize(),
            .up = world.mulVec4(.fromDirection(.up)).xyz().normalize(),
            .forward = world.mulVec4(.fromDirection(.forward)).xyz().normalize(),
        };
    }
};

/// The four streams and the indices of one mesh. Each slice holds at least `live × 4`
/// vertices or `live × 6` indices; the caller may point them into a staging reservation.
pub const Output = struct {
    positions: [][3]f32,
    uvs: [][2]f32,
    colors: [][4]f32,
    indices: []u16,
};

pub const Expanded = struct {
    quads: u32,
    /// Of every vertex written; null when nothing was.
    bounds: ?Aabb,
};

/// The sort's workspace, sized once for a store's capacity.
pub const Expander = struct {
    gpa: Allocator,
    /// The draw order, as store indices, and the radix sort's other half.
    order: []u32,
    order_scratch: []u32,
    keys: []u32,
    keys_scratch: []u32,

    pub fn init(gpa: Allocator, capacity: u32) Allocator.Error!Expander {
        std.debug.assert(capacity > 0 and capacity <= emitter_mod.max_capacity);
        var self: Expander = .{ .gpa = gpa, .order = &.{}, .order_scratch = &.{}, .keys = &.{}, .keys_scratch = &.{} };
        errdefer self.deinit();
        self.order = try gpa.alloc(u32, capacity);
        self.order_scratch = try gpa.alloc(u32, capacity);
        self.keys = try gpa.alloc(u32, capacity);
        self.keys_scratch = try gpa.alloc(u32, capacity);
        return self;
    }

    pub fn deinit(self: *Expander) void {
        for ([_][]u32{ self.order, self.order_scratch, self.keys, self.keys_scratch }) |slice| self.gpa.free(slice);
        self.* = undefined;
    }

    pub const Options = struct {
        /// Back to front, for a blended material. Otherwise spawn order.
        sorted: bool,
        /// The emitter's world transform: carries `local` particles, and orients `up` quads.
        transform: Mat4 = .identity,
    };

    /// Writes `system`'s live particles as quads, at the time of its last step. The system was
    /// stepped with `emitter`, and both are unchanged for the call.
    pub fn expand(self: *Expander, system: *const System, emitter: *const Emitter, view: View, options: Options, out: Output, jobs: Jobs) Expanded {
        const live = system.liveCount();
        std.debug.assert(live <= self.order.len);
        std.debug.assert(out.positions.len >= live * vertices_per_quad and out.uvs.len >= live * vertices_per_quad);
        std.debug.assert(out.colors.len >= live * vertices_per_quad and out.indices.len >= live * indices_per_quad);
        if (live == 0) return .{ .quads = 0, .bounds = null };

        const s = system.particles.slice();
        const order = self.order[0..live];
        for (order, 0..) |*o, i| o.* = @intCast(i);
        if (options.sorted) {
            const keys = self.keys[0..live];
            for (keys, s.items(.position)) |*key, p| key.* = farFirst(carry(emitter, options.transform, p).sub(view.eye).dot(view.forward));
            radixSort(keys, order, self.keys_scratch[0..live], self.order_scratch[0..live]);
        }

        var slots: [max_chunks]Aabb = undefined;
        const work: Work = .{
            .emitter = emitter,
            .positions = s.items(.position),
            .velocities = s.items(.velocity),
            .births = s.items(.birth),
            .lifetimes = s.items(.lifetime),
            .sizes = s.items(.size),
            .rotations = s.items(.rotation),
            .spins = s.items(.spin),
            .order = order,
            .view = view,
            .transform = options.transform,
            .now = @as(f64, @floatFromInt(system.last_tick.?)) * @as(f64, system.dt.?),
            .out = out,
            .slots = &slots,
        };
        jobs.forChunks(live, grain, &work, Work.chunk);

        var bounds = slots[0];
        for (slots[1..core.jobs.chunkCount(live, grain)]) |slot| bounds = merge(bounds, slot);
        return .{ .quads = live, .bounds = bounds };
    }
};

/// A depth as a key that sorts farther first when sorted ascending: IEEE order made unsigned,
/// then reversed. −0 and +0 compare equal, so −0 is folded into +0 first.
fn farFirst(depth: f32) u32 {
    const d: f32 = if (depth == 0) 0 else depth;
    const bits: u32 = @bitCast(d);
    const ascending = if (bits >> 31 != 0) ~bits else bits | 0x8000_0000;
    return ~ascending;
}

/// A stable least-significant-digit radix sort of `order` by `keys`, a byte a pass. Stable, and
/// `order` arrives in store order, which is spawn order, so equal depths stay in spawn-serial
/// order: the total order "farther first, then earlier spawned" (§3.3). Four passes leave the
/// result back in `keys` and `order`.
fn radixSort(keys: []u32, order: []u32, keys_scratch: []u32, order_scratch: []u32) void {
    var from_keys = keys;
    var from_order = order;
    var to_keys = keys_scratch;
    var to_order = order_scratch;
    var shift: u5 = 0;
    for (0..4) |_| {
        var counts: [256]u32 = @splat(0);
        for (from_keys) |key| counts[(key >> shift) & 0xff] += 1;
        var at: u32 = 0;
        for (&counts) |*count| {
            const n = count.*;
            count.* = at;
            at += n;
        }
        for (from_keys, from_order) |key, index| {
            const bucket = &counts[(key >> shift) & 0xff];
            to_keys[bucket.*] = key;
            to_order[bucket.*] = index;
            bucket.* += 1;
        }
        std.mem.swap([]u32, &from_keys, &to_keys);
        std.mem.swap([]u32, &from_order, &to_order);
        shift +%= 8;
    }
}

const Work = struct {
    emitter: *const Emitter,
    positions: []const [3]f32,
    velocities: []const [3]f32,
    births: []const f64,
    lifetimes: []const f32,
    sizes: []const f32,
    rotations: []const f32,
    spins: []const f32,
    order: []const u32,
    view: View,
    transform: Mat4,
    now: f64,
    out: Output,
    slots: *[max_chunks]Aabb,

    fn chunk(self: *const Work, piece: core.jobs.Chunk) void {
        var lo: [3]f32 = @splat(std.math.inf(f32));
        var hi: [3]f32 = @splat(-std.math.inf(f32));
        for (piece.begin..piece.end) |q| {
            const quad = self.writeQuad(@intCast(q));
            for (quad) |corner| for (0..3) |axis| {
                lo[axis] = @min(lo[axis], corner[axis]);
                hi[axis] = @max(hi[axis], corner[axis]);
            };
        }
        self.slots[piece.index] = .{ .min = lo, .max = hi };
    }

    /// Quad `q` of the draw order, at vertices `4q..4q+3` and indices `6q..6q+5`.
    fn writeQuad(self: *const Work, q: u32) [4][3]f32 {
        const emitter = self.emitter;
        const index = self.order[q];
        const age_seconds = self.now - self.births[index];
        const age: f32 = @floatCast(age_seconds);
        const t = std.math.clamp(age / self.lifetimes[index], 0, 1);
        const size = self.sizes[index] * emitter.sizeAt(t);
        const centre = carry(emitter, self.transform, self.positions[index]);

        const half = self.halfAxes(index, age, size);
        const corners = [4]Vec3{
            centre.sub(half[0]).sub(half[1]),
            centre.add(half[0]).sub(half[1]),
            centre.add(half[0]).add(half[1]),
            centre.sub(half[0]).add(half[1]),
        };

        const frame = sheetFrame(emitter.sheet, t, age);
        const columns: f32 = @floatFromInt(emitter.sheet.columns);
        const rows: f32 = @floatFromInt(emitter.sheet.rows);
        const left = @as(f32, @floatFromInt(frame % emitter.sheet.columns)) / columns;
        const top = @as(f32, @floatFromInt(frame / emitter.sheet.columns)) / rows;
        const right = left + 1 / columns;
        const bottom = top + 1 / rows;
        // The sheet's top row is v = 0, so the quad's lower corners take the frame's lower edge.
        const uvs = [4][2]f32{ .{ left, bottom }, .{ right, bottom }, .{ right, top }, .{ left, top } };

        const c = emitter.colorAt(t);
        const color = [4]f32{ c[0] * c[3], c[1] * c[3], c[2] * c[3], c[3] * (1 - emitter.additive) };

        const v = q * vertices_per_quad;
        var written: [4][3]f32 = undefined;
        for (corners, uvs, 0..) |corner, uv, k| {
            written[k] = .{ corner.x, corner.y, corner.z };
            self.out.positions[v + k] = written[k];
            self.out.uvs[v + k] = uv;
            self.out.colors[v + k] = color;
        }
        const base: u16 = @intCast(v);
        const i = q * indices_per_quad;
        self.out.indices[i..][0..indices_per_quad].* = .{ base, base + 1, base + 2, base, base + 2, base + 3 };
        return written;
    }

    /// The quad's two half-axes, in world space.
    fn halfAxes(self: *const Work, index: u32, age: f32, size: f32) [2]Vec3 {
        const half = size / 2;
        const emitter = self.emitter;
        const angle = self.rotations[index] + self.spins[index] * age;
        switch (emitter.facing) {
            .camera => return rotated(self.view.right, self.view.up, angle, half),
            .up => {
                const x = self.transform.mulVec4(.fromDirection(.right)).xyz().normalize();
                const z = self.transform.mulVec4(.fromDirection(.init(0, 0, 1))).xyz().normalize();
                return rotated(x, z, angle, half);
            },
            .velocity => {
                const velocity = carryDirection(emitter, self.transform, self.velocities[index]);
                const forward = self.view.forward;
                const across = velocity.sub(forward.scale(velocity.dot(forward)));
                const length = across.length();
                // Moving straight along the view, or not at all: nothing to stretch along.
                if (length <= 1e-6) return rotated(self.view.right, self.view.up, 0, half);
                const long = across.scale(1 / length);
                const wide = forward.cross(long).normalize();
                return .{ long.scale(half + emitter.stretch * velocity.length() / 2), wide.scale(half) };
            },
        }
    }
};

/// `a` and `b` turned by `angle` in their own plane, each scaled to `half`.
fn rotated(a: Vec3, b: Vec3, angle: f32, half: f32) [2]Vec3 {
    // `sinCosTurns(0)` is exactly (0, 1), so an unturned quad skips it and writes the same bytes.
    if (angle == 0) return .{ a.scale(half), b.scale(half) };
    const sc = trig.sinCosTurns(@as(f64, angle) / (2 * std.math.pi));
    const s: f32 = @floatCast(sc[0]);
    const c: f32 = @floatCast(sc[1]);
    return .{ a.scale(c).add(b.scale(s)).scale(half), b.scale(c).sub(a.scale(s)).scale(half) };
}

/// The frame of a flipbook at normalized age `t`: once over the life when `fps` is 0, looping
/// at `fps` otherwise.
pub fn sheetFrame(sheet: emitter_mod.Sheet, t: f32, age: f32) u32 {
    const frames: f32 = @floatFromInt(sheet.frames);
    if (sheet.fps == 0) return @min(sheet.frames - 1, @as(u32, @intFromFloat(@floor(t * frames))));
    const played: u64 = @intFromFloat(@floor(@max(0, age) * sheet.fps));
    return @intCast(played % sheet.frames);
}

fn carry(emitter: *const Emitter, transform: Mat4, p: [3]f32) Vec3 {
    const v = Vec3.init(p[0], p[1], p[2]);
    return if (emitter.space == .local) transform.mulVec4(.fromPoint(v)).xyz() else v;
}

fn carryDirection(emitter: *const Emitter, transform: Mat4, d: [3]f32) Vec3 {
    const v = Vec3.init(d[0], d[1], d[2]);
    return if (emitter.space == .local) transform.mulVec4(.fromDirection(v)).xyz() else v;
}

fn merge(x: Aabb, y: Aabb) Aabb {
    var out = x;
    for (0..3) |axis| {
        out.min[axis] = @min(x.min[axis], y.min[axis]);
        out.max[axis] = @max(x.max[axis], y.max[axis]);
    }
    return out;
}
