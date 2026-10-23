//! M28's generated corner (`docs/design/runtime-geometry.md` §8): geometry this sample makes
//! at run time, beside the compiled room, off the tour's path at `origin`.
//!
//! - **The patch**, a seeded heightfield made synchronously before the first tick. One set of
//!   triangles is both drawn and walked on, because collision is simulation and a patch that
//!   arrived when a thread finished would change what the character stands on (ADR-0061).
//! - **The water**, a 129² sheet rewritten every frame from the tick. By default each frame's
//!   sheet is generated on `Engine.tasks()` and updated through `Uploads.updateMesh`, so its
//!   validation, boxes and copy run on the pool too (Step 6's Resolution);
//!   `FOUNDRY_SANDBOX3D_WATER=inline` generates it and calls `Renderer.updateMesh` on the main
//!   thread each frame instead, the baseline.
//! - **The canvas**, a 1024² texture painted one 64² stamp at a time with `writeTexture`, where
//!   the player looks within reach; **C** clears it.
//! - **The landmark**, a large generated spire requested on a fixed tick. `background` (the
//!   default) generates it on `Engine.tasks()` and uploads it through `render3d.Uploads`;
//!   `inline` generates and uploads it in that frame, the baseline it is measured against.
//! - **The recoloured crate**, a compiled model whose slot 0 wears a `Content.createMaterial`
//!   binding the crate's compiled texture by content ID, followed across **R**'s reload.
//!
//! `FOUNDRY_SANDBOX3D_GENERATE=background|inline|off` chooses, as `FOUNDRY_SANDBOX3D_LOAD` does
//! the gallery's. Every timing here is measured and reported, and none reaches simulation.
const std = @import("std");
const app = @import("app");
const asset = @import("asset");
const core = @import("core");
const physics = @import("physics3d");
const render3d = @import("render3d");
const gallery_mod = @import("gallery.zig");

const Allocator = std.mem.Allocator;
const Mat4 = core.math.Mat4;
const Vec3 = core.math.Vec3;
const log = core.log.scoped(.sandbox3d);

/// The corner's centre: past the crate grid's last row (±9.6 m), so the tour never comes near.
pub const origin: Vec3 = .init(20, 0, 0);

/// How the landmark is made on its tick, and whether the corner is there at all.
pub const Mode = enum {
    off,
    @"inline",
    background,

    /// `FOUNDRY_SANDBOX3D_GENERATE`, `background` when unset. Anything else is said and treated
    /// as `off`: a measurement run of the wrong path is worse than none.
    pub fn parse(text: ?[]const u8) Mode {
        const value = std.mem.trim(u8, text orelse return .background, " ");
        if (std.meta.stringToEnum(Mode, value)) |mode| return mode;
        log.warn("FOUNDRY_SANDBOX3D_GENERATE='{s}' is not background, inline or off; no generated corner", .{value});
        return .off;
    }
};

// -- the patch ---------------------------------------------------------------------------

pub const patch_side = 65;
pub const patch_spacing: f32 = 0.2;
pub const patch_seed: u64 = 0x5eed_2028;
/// Where the patch walk starts and which way it goes, for the pinned headless proof.
pub const patch_start: Vec3 = .init(origin.x - 5, 1, origin.z - 1);
const patch_extent = @as(f32, patch_side - 1) * patch_spacing;

/// Two octaves of value noise, 2 m and 1 m cells, 0.3 m and 0.1 m tall: gentle enough to walk
/// (the steepest analytic slope is about 30°, under the character's 45°).
const octaves = [_]struct { cell: f32, amplitude: f32, salt: u64 }{
    .{ .cell = 2, .amplitude = 0.3, .salt = 0x9e37_79b9_7f4a_7c15 },
    .{ .cell = 1, .amplitude = 0.1, .salt = 0xbf58_476d_1ce4_e5b9 },
};

/// A lattice value in [-1, 1], from the seed alone: no global RNG, no clock (I9).
fn lattice(seed: u64, x: i64, z: i64) f32 {
    var h = seed ^ (@as(u64, @bitCast(x)) *% 0x9e37_79b9_7f4a_7c15) ^ (@as(u64, @bitCast(z)) *% 0xc2b2_ae3d_27d4_eb4f);
    h = (h ^ (h >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    h = (h ^ (h >> 27)) *% 0x94d0_49bb_1331_11eb;
    h ^= h >> 31;
    return @as(f32, @floatFromInt(h >> 40)) / @as(f32, 1 << 23) - 1;
}

const Height = struct { y: f32, dx: f32, dz: f32 };

/// The patch's height at a local `(x, z)`, and its exact derivatives, so the normals are
/// analytic rather than differenced.
pub fn patchHeight(seed: u64, x: f32, z: f32) Height {
    var out: Height = .{ .y = 0, .dx = 0, .dz = 0 };
    for (octaves) |o| {
        const fx = x / o.cell;
        const fz = z / o.cell;
        const ix = @floor(fx);
        const iz = @floor(fz);
        const tx = fx - ix;
        const tz = fz - iz;
        // Smoothstep weights and their derivatives.
        const sx = tx * tx * (3 - 2 * tx);
        const sz = tz * tz * (3 - 2 * tz);
        const dsx = 6 * tx * (1 - tx);
        const dsz = 6 * tz * (1 - tz);
        const cx: i64 = @intFromFloat(ix);
        const cz: i64 = @intFromFloat(iz);
        const s = seed ^ o.salt;
        const a = lattice(s, cx, cz);
        const b = lattice(s, cx + 1, cz);
        const c = lattice(s, cx, cz + 1);
        const d = lattice(s, cx + 1, cz + 1);
        const value = a + (b - a) * sx + (c - a) * sz + (a - b - c + d) * sx * sz;
        out.y += o.amplitude * value;
        out.dx += o.amplitude * ((b - a) + (a - b - c + d) * sz) * dsx / o.cell;
        out.dz += o.amplitude * ((c - a) + (a - b - c + d) * sx) * dsz / o.cell;
    }
    return out;
}

/// The patch's triangles in world space: what is drawn and what is walked on, the same bytes.
pub const Patch = struct {
    positions: []Vec3,
    normals: []Vec3,
    indices: []u32,

    pub fn generate(gpa: Allocator, seed: u64) Allocator.Error!Patch {
        const count = patch_side * patch_side;
        const positions = try gpa.alloc(Vec3, count);
        errdefer gpa.free(positions);
        const normals = try gpa.alloc(Vec3, count);
        errdefer gpa.free(normals);
        const indices = try gpa.alloc(u32, (patch_side - 1) * (patch_side - 1) * 6);
        for (0..patch_side) |row| for (0..patch_side) |col| {
            const x = @as(f32, @floatFromInt(col)) * patch_spacing - patch_extent / 2;
            const z = @as(f32, @floatFromInt(row)) * patch_spacing - patch_extent / 2;
            const h = patchHeight(seed, x, z);
            positions[row * patch_side + col] = .init(origin.x + x, origin.y + h.y, origin.z + z);
            normals[row * patch_side + col] = Vec3.init(-h.dx, 1, -h.dz).normalize();
        };
        gridIndices(indices, patch_side);
        return .{ .positions = positions, .normals = normals, .indices = indices };
    }

    pub fn deinit(self: *Patch, gpa: Allocator) void {
        gpa.free(self.positions);
        gpa.free(self.normals);
        gpa.free(self.indices);
        self.* = undefined;
    }

    pub fn mesh(self: Patch, gpa: Allocator) !asset.OwnedMesh {
        var builder: asset.MeshBuilder = .init(gpa, .{});
        defer builder.deinit();
        try builder.positions(self.positions);
        try builder.normals(self.normals);
        try builder.indices32(self.indices);
        return builder.finish();
    }
};

/// Two counter-clockwise triangles per cell, seen from +Y, rows along +Z.
fn gridIndices(out: []u32, side: u32) void {
    var i: usize = 0;
    for (0..side - 1) |row| for (0..side - 1) |col| {
        const a: u32 = @intCast(row * side + col);
        const b = a + 1;
        const c = a + side;
        const d = c + 1;
        out[i..][0..6].* = .{ a, c, b, b, c, d };
        i += 6;
    };
}

// -- the water ---------------------------------------------------------------------------

pub const water_side = 129;
const water_width: f32 = 12;
const water_depth: f32 = 6;
const water_level: f32 = -0.25;
/// Where the sheet starts: beside the patch, towards +Z.
const water_corner: Vec3 = .init(origin.x - water_width / 2, water_level, origin.z + patch_extent / 2 + 0.5);

const Wave = struct { kx: f32, kz: f32, amplitude: f32, speed: f32 };
const waves = [_]Wave{
    .{ .kx = 1.3, .kz = 0.4, .amplitude = 0.06, .speed = 1.7 },
    .{ .kx = -0.5, .kz = 1.9, .amplitude = 0.04, .speed = 2.3 },
    .{ .kx = 2.7, .kz = 2.1, .amplitude = 0.015, .speed = 3.1 },
};

/// The sheet the CPU rewrites, and the views `updateMesh` reads, kept so a frame allocates
/// nothing.
pub const Water = struct {
    positions: []Vec3,
    normals: []Vec3,
    indices: []u32,
    /// Each wave's phase splits into a column part and a row part, so a fill takes one sine and
    /// cosine per column and per row rather than per vertex (`sin(a + b)`'s identity).
    column: [waves.len][water_side][2]f32 = undefined,
    row: [waves.len][water_side][2]f32 = undefined,
    streams: [2]asset.MeshStream = undefined,
    submeshes: [1]asset.Submesh = undefined,

    pub fn init(gpa: Allocator) Allocator.Error!Water {
        const count = water_side * water_side;
        const positions = try gpa.alloc(Vec3, count);
        errdefer gpa.free(positions);
        const normals = try gpa.alloc(Vec3, count);
        errdefer gpa.free(normals);
        const indices = try gpa.alloc(u32, (water_side - 1) * (water_side - 1) * 6);
        gridIndices(indices, water_side);
        return .{ .positions = positions, .normals = normals, .indices = indices };
    }

    pub fn deinit(self: *Water, gpa: Allocator) void {
        gpa.free(self.positions);
        gpa.free(self.normals);
        gpa.free(self.indices);
        self.* = undefined;
    }

    /// The sheet at `seconds` of simulation time: a sum of sines, with analytic normals.
    pub fn fill(self: *Water, seconds: f32) void {
        for (waves, 0..) |w, k| for (0..water_side) |i| {
            const along = @as(f32, @floatFromInt(i)) / (water_side - 1);
            const a = w.kx * along * water_width;
            const b = w.kz * along * water_depth - w.speed * seconds;
            self.column[k][i] = .{ @sin(a), @cos(a) };
            self.row[k][i] = .{ @sin(b), @cos(b) };
        };
        for (0..water_side) |row| for (0..water_side) |col| {
            const x = @as(f32, @floatFromInt(col)) / (water_side - 1) * water_width;
            const z = @as(f32, @floatFromInt(row)) / (water_side - 1) * water_depth;
            var y: f32 = 0;
            var dx: f32 = 0;
            var dz: f32 = 0;
            inline for (waves, 0..) |w, k| {
                const sa, const ca = self.column[k][col];
                const sb, const cb = self.row[k][row];
                const sine = sa * cb + ca * sb;
                const cosine = ca * cb - sa * sb;
                y += w.amplitude * sine;
                dx += w.amplitude * w.kx * cosine;
                dz += w.amplitude * w.kz * cosine;
            }
            self.positions[row * water_side + col] = water_corner.add(.init(x, y, z));
            self.normals[row * water_side + col] = Vec3.init(-dx, 1, -dz).normalize();
        };
    }

    /// The current sheet as a mesh borrowing these arrays.
    pub fn mesh(self: *Water) !asset.Mesh {
        self.streams = .{
            .{ .semantic = .position, .format = .float32x3, .bytes = std.mem.sliceAsBytes(self.positions) },
            .{ .semantic = .normal, .format = .float32x3, .bytes = std.mem.sliceAsBytes(self.normals) },
        };
        self.submeshes = .{.{ .first_index = 0, .index_count = @intCast(self.indices.len) }};
        return .{
            .vertex_count = @intCast(self.positions.len),
            .streams = &self.streams,
            .index_format = .uint32,
            .indices = std.mem.sliceAsBytes(self.indices),
            .submeshes = &self.submeshes,
            .bounds = try asset.Mesh.computeBounds(self.positions),
        };
    }
};

/// How the water is rewritten. `pooled`, the default: generated and validated off the main
/// thread, arriving a frame or two later, which is presentation (ADR-0061). `inline`: all of it
/// on the main thread, before the frame's window opens.
pub const WaterMode = enum {
    pooled,
    @"inline",

    pub fn parse(text: ?[]const u8) WaterMode {
        const value = std.mem.trim(u8, text orelse return .pooled, " ");
        if (std.meta.stringToEnum(WaterMode, value)) |mode| return mode;
        log.warn("FOUNDRY_SANDBOX3D_WATER='{s}' is not pooled or inline; pooled", .{value});
        return .pooled;
    }
};

/// One frame's sheet, generated on the pool into its own scratch, then built into a mesh
/// `Uploads` takes. One is in flight at a time, so the scratch is reused.
const WaterJob = struct {
    gpa: Allocator,
    water: Water,
    seconds: f32 = 0,
    done: core.tasks.Done = .{},
    result: ?asset.OwnedMesh = null,

    fn run(context: *anyopaque) void {
        const self: *WaterJob = @ptrCast(@alignCast(context));
        self.water.fill(self.seconds);
        // Copied into memory `Uploads` frees on the pool after its finish.
        var builder: asset.MeshBuilder = .init(self.gpa, .{});
        defer builder.deinit();
        builder.positions(self.water.positions) catch return;
        builder.normals(self.water.normals) catch return;
        builder.indices32(self.water.indices) catch return;
        self.result = builder.finish() catch null;
    }
};

// -- the canvas --------------------------------------------------------------------------

pub const canvas_size = 1024;
pub const brush_size = 64;
const canvas_width: f32 = 3;
/// How far away a look still paints.
const reach: f32 = 5;
/// The canvas's centre, on the patch's west edge, facing +X towards the patch.
const canvas_centre: Vec3 = .init(origin.x - patch_extent / 2 - 0.2, 1.6, origin.z - 2);

/// A brush stamp's rectangle on the canvas, clipped to it, and where in the stamp it starts.
pub const Stamp = struct { region: render3d.TextureRegion, from_x: u32, from_y: u32 };

/// The stamp centred on texel `(cx, cy)`, clipped; null when none of it is on the canvas.
pub fn stampAt(cx: i64, cy: i64) ?Stamp {
    const half: i64 = brush_size / 2;
    const x0 = @max(0, cx - half);
    const y0 = @max(0, cy - half);
    const x1 = @min(canvas_size, cx + half);
    const y1 = @min(canvas_size, cy + half);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{
        .region = .{ .x = @intCast(x0), .y = @intCast(y0), .width = @intCast(x1 - x0), .height = @intCast(y1 - y0) },
        .from_x = @intCast(x0 - (cx - half)),
        .from_y = @intCast(y0 - (cy - half)),
    };
}

/// Where a look from `eye` along `forward` meets the canvas within reach, in texels.
pub fn canvasHit(eye: Vec3, forward: Vec3) ?[2]i64 {
    // The canvas's plane is x = canvas_centre.x, seen from +X.
    if (forward.x >= -1e-4) return null;
    const t = (canvas_centre.x - eye.x) / forward.x;
    if (t <= 0 or t > reach) return null;
    const p = eye.add(forward.scale(t));
    const u = (canvas_centre.z + canvas_width / 2 - p.z) / canvas_width;
    const v = (canvas_centre.y + canvas_width / 2 - p.y) / canvas_width;
    if (u < 0 or u >= 1 or v < 0 or v >= 1) return null;
    return .{ @intFromFloat(u * canvas_size), @intFromFloat(v * canvas_size) };
}

/// The canvas's texels on the CPU, which a stamp blends into before its region is written.
const Canvas = struct {
    pixels: []u8,
    scratch: [brush_size * brush_size * 4]u8 = undefined,
    texture: render3d.TextureHandle = .none,
    material: render3d.MaterialHandle = .none,
    mesh: render3d.MeshHandle = .none,
    stamps: u64 = 0,

    fn clearPixels(self: *Canvas) void {
        @memset(self.pixels, 235);
    }

    /// Blends a soft round stamp of `colour` into the canvas and writes its region.
    fn stamp(self: *Canvas, renderer: *render3d.Renderer, at: [2]i64, colour: [3]u8) !void {
        const s = stampAt(at[0], at[1]) orelse return;
        const r = s.region;
        for (0..r.height) |row| for (0..r.width) |col| {
            const bx: f32 = @floatFromInt(s.from_x + col);
            const by: f32 = @floatFromInt(s.from_y + row);
            const half: f32 = brush_size / 2;
            const d = @sqrt((bx - half + 0.5) * (bx - half + 0.5) + (by - half + 0.5) * (by - half + 0.5)) / half;
            const alpha = std.math.clamp(1.2 - d * 1.2, 0, 1);
            const texel = self.pixels[((r.y + row) * canvas_size + r.x + col) * 4 ..][0..4];
            for (texel[0..3], colour) |*channel, paint| {
                const mixed = @as(f32, @floatFromInt(channel.*)) * (1 - alpha) + @as(f32, @floatFromInt(paint)) * alpha;
                channel.* = @intFromFloat(@round(mixed));
            }
            texel[3] = 255;
            @memcpy(self.scratch[(row * r.width + col) * 4 ..][0..4], texel);
        };
        try renderer.writeTexture(self.texture, r, self.scratch[0 .. r.width * r.height * 4]);
        self.stamps += 1;
    }

    fn clear(self: *Canvas, renderer: *render3d.Renderer) !void {
        self.clearPixels();
        try renderer.writeTexture(self.texture, .{ .width = canvas_size, .height = canvas_size }, self.pixels);
    }
};

/// A colour per stamp, cycling, so a painted line reads as one.
fn brushColour(n: u64) [3]u8 {
    const colours = [_][3]u8{ .{ 200, 40, 40 }, .{ 40, 120, 210 }, .{ 240, 190, 40 }, .{ 50, 160, 80 } };
    return colours[(n / 30) % colours.len];
}

/// `FOUNDRY_SANDBOX3D_PAINT=auto`'s path: a figure of eight across the canvas, one stamp a tick,
/// so a run nobody watches still writes a region every tick for §1's measurement.
pub fn autoStroke(tick: u64) [2]i64 {
    const t = @as(f32, @floatFromInt(tick)) / 60;
    const x = 0.5 + 0.38 * @sin(t * 0.9);
    const y = 0.5 + 0.3 * @sin(t * 1.8);
    return .{ @intFromFloat(x * canvas_size), @intFromFloat(y * canvas_size) };
}

// -- the landmark ------------------------------------------------------------------------

/// Requested two seconds after the gallery's, so a run measures one or the other cleanly.
pub const landmark_tick: u64 = 240;
/// Pinned in Step 6's Resolution: large enough that the inline baseline's frame exceeds
/// 16.67 ms on the Mac, as §1's exit criterion 2 asks.
pub const spire_rings = 1024;
pub const spire_segments = 1024;
const spire_height: f32 = 9;
const spire_base: Vec3 = .init(origin.x + 4, -0.2, origin.z - 3.5);

/// A spire of revolved, displaced rings, made from its parameters alone. Pure, so it runs on
/// any thread and the same parameters give the same bytes inline or in the background.
pub fn spireMesh(gpa: Allocator, rings: u32, segments: u32) !asset.OwnedMesh {
    const columns = segments + 1;
    const count = @as(usize, rings + 1) * columns;
    const positions = try gpa.alloc(Vec3, count);
    defer gpa.free(positions);
    const normals = try gpa.alloc(Vec3, count);
    defer gpa.free(normals);
    const indices = try gpa.alloc(u32, @as(usize, rings) * segments * 6);
    defer gpa.free(indices);

    for (0..rings + 1) |ring| {
        const v = @as(f32, @floatFromInt(ring)) / @as(f32, @floatFromInt(rings));
        const radius_here = spireRadius(v);
        for (0..columns) |segment| {
            const u = @as(f32, @floatFromInt(segment)) / @as(f32, @floatFromInt(segments));
            const angle = u * std.math.tau;
            // Fluting and banding, so the surface has detail worth the vertices.
            const r = radius_here * (1 + 0.06 * @sin(angle * 12) + 0.03 * @sin(v * 90 + angle * 3));
            positions[ring * columns + segment] = spire_base.add(.init(r * @cos(angle), v * spire_height, r * @sin(angle)));
        }
    }
    // Normals from the grid's neighbours: the seam column repeats the first, so it wraps.
    for (0..rings + 1) |ring| for (0..columns) |segment| {
        const left = positions[ring * columns + (segment + segments - 1) % segments];
        const right = positions[ring * columns + (segment + 1) % segments];
        const down = positions[(if (ring == 0) ring else ring - 1) * columns + segment];
        const up = positions[(if (ring == rings) ring else ring + 1) * columns + segment];
        const n = up.sub(down).cross(right.sub(left));
        normals[ring * columns + segment] = if (n.lengthSquared() > 1e-20) n.normalize() else .init(0, 1, 0);
    };
    var i: usize = 0;
    for (0..rings) |ring| for (0..segments) |segment| {
        const a: u32 = @intCast(ring * columns + segment);
        const b = a + 1;
        const c = a + columns;
        const d = c + 1;
        indices[i..][0..6].* = .{ a, c, b, b, c, d };
        i += 6;
    };

    var builder: asset.MeshBuilder = .init(gpa, .{});
    defer builder.deinit();
    try builder.positions(positions);
    try builder.normals(normals);
    try builder.indices32(indices);
    return builder.finish();
}

/// The spire's radius at height fraction `v`: a broad foot, a waist and a point.
fn spireRadius(v: f32) f32 {
    return 1.4 * (1 - v) * (1 - v) + 0.25 * (1 - v) + 0.15 * @sin(v * std.math.pi * 3) * (1 - v);
}

/// A digest of a mesh's bytes, which tests pin and runs compare.
pub fn meshDigest(mesh: asset.Mesh) u64 {
    var h = std.hash.Wyhash.init(0);
    for (mesh.streams) |stream| {
        h.update(std.mem.asBytes(&stream.semantic));
        h.update(stream.bytes);
    }
    h.update(mesh.indices);
    return h.final();
}

/// The generation the pool runs: what it was asked for, and what it made.
const Job = struct {
    gpa: Allocator,
    done: core.tasks.Done = .{},
    result: ?asset.OwnedMesh = null,
    failed: bool = false,

    fn run(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        self.result = spireMesh(self.gpa, spire_rings, spire_segments) catch {
            self.failed = true;
            return;
        };
    }
};

const Landmark = struct {
    stage: enum { idle, generating, uploading, ready, failed } = .idle,
    job: ?*Job = null,
    upload: render3d.UploadHandle = .none,
    mesh: render3d.MeshHandle = .none,
    started_ns: u64 = 0,
    window: gallery_mod.Window = .{ .label = "landmark", .pump_span = uploads_span },
};

/// The profiler span the corner's `Uploads.pump` runs in.
pub const uploads_span = "uploads.pump";

// -- the corner --------------------------------------------------------------------------

/// What the corner times on the main thread: each write's own cost, never what simulation sees.
const Timings = struct {
    const capacity = 4096;
    values: [capacity]i64 = undefined,
    len: usize = 0,

    fn add(self: *Timings, ns: i64) void {
        if (self.len == capacity) return;
        self.values[self.len] = ns;
        self.len += 1;
    }

    fn summary(self: *const Timings) core.profile.Summary {
        var scratch: [capacity]i64 = undefined;
        return core.profile.summarise(self.values[0..self.len], &scratch);
    }
};

pub const Corner = struct {
    gpa: Allocator,
    mode: Mode,
    auto_paint: bool,
    uploads: render3d.Uploads,

    patch_mesh: render3d.MeshHandle = .none,
    patch_body: physics.BodyHandle = .none,
    patch_collision: physics.MeshHandle = .none,
    patch_material: render3d.MaterialHandle = .none,
    water: Water,
    water_mode: WaterMode,
    water_job: ?*WaterJob = null,
    water_running: bool = false,
    water_upload: render3d.UploadHandle = .none,
    /// The main thread's share of the pending update: its request, and the next generation's start.
    water_request_ns: i64 = 0,
    water_mesh: render3d.MeshHandle = .none,
    water_material: render3d.MaterialHandle = .none,
    canvas: Canvas,
    landmark: Landmark = .{},
    landmark_material: render3d.MaterialHandle = .none,
    crate: render3d.ModelHandle = .none,
    recolour: render3d.MaterialHandle = .none,
    /// What the recolour bound at the last reload, so the next one can say what changed.
    recolour_bound: render3d.TextureHandle = .none,

    water_times: Timings = .{},
    /// The water's generation alone, the CPU half of `water_times`.
    water_fill_times: Timings = .{},
    /// `updateMesh` alone: validation, staging and the copy's submission.
    water_update_times: Timings = .{},
    canvas_times: Timings = .{},

    /// Everything but the landmark, made now, before the first tick. The patch's triangles go
    /// to `walk` as well as the renderer.
    pub fn init(self: *Corner, engine: *app.Engine, mode: Mode, renderer: *render3d.Renderer, content: *render3d.Content, walk: *physics.World) !void {
        const gpa = engine.gpa;
        var water = try Water.init(gpa);
        const pixels = gpa.alloc(u8, canvas_size * canvas_size * 4) catch |err| {
            water.deinit(gpa);
            return err;
        };
        self.* = .{
            .gpa = gpa,
            .mode = mode,
            .auto_paint = if (engine.os.envVar("FOUNDRY_SANDBOX3D_PAINT")) |v| std.mem.eql(u8, v, "auto") else false,
            // The pool frees what it uploaded, so its bytes come from the allocator that is
            // safe on the pool.
            .uploads = render3d.Uploads.init(engine.taskAllocator(), renderer, engine.tasks(), .{}),
            .water = water,
            .water_mode = WaterMode.parse(engine.os.envVar("FOUNDRY_SANDBOX3D_WATER")),
            .canvas = .{ .pixels = pixels },
        };
        // From here `deinit` frees whatever has been made, the water and canvas included.
        errdefer self.deinit(renderer, content, walk);

        var patch = try Patch.generate(gpa, patch_seed);
        defer patch.deinit(gpa);
        var patch_bytes = try patch.mesh(gpa);
        defer patch_bytes.deinit(gpa);
        self.patch_mesh = try renderer.createMesh(patch_bytes.mesh, "sandbox3d patch");
        self.patch_collision = try walk.addMesh(gpa, patch.positions, patch.indices);
        self.patch_body = try walk.addBody(gpa, .{ .shape = .{ .mesh = self.patch_collision } });
        self.patch_material = try content.acquireMaterial(.fromString("sandbox3d:materials.patch"));

        self.water.fill(0);
        self.water_mesh = try renderer.createMesh(try self.water.mesh(), "sandbox3d water");
        if (self.water_mode == .pooled) {
            const job = try gpa.create(WaterJob);
            job.* = .{ .gpa = engine.taskAllocator(), .water = Water.init(gpa) catch |err| {
                gpa.destroy(job);
                return err;
            } };
            self.water_job = job;
        }
        self.water_material = try content.acquireMaterial(.fromString("sandbox3d:materials.water"));

        self.canvas.clearPixels();
        self.canvas.texture = try renderer.createTexture(.{ .width = canvas_size, .height = canvas_size, .pixels = self.canvas.pixels }, .{ .filter = .linear, .label = "sandbox3d canvas" });
        self.canvas.material = try content.createMaterial(.{ .shading = render3d.lit_id, .roughness = 0.9, .base_color_texture = .{ .runtime = self.canvas.texture } });
        self.canvas.mesh = try canvasQuad(gpa, renderer);

        self.landmark_material = try content.acquireMaterial(.fromString("sandbox3d:materials.landmark"));
        self.crate = try content.acquireModel(.fromString("sandbox3d:models.crate"));
        self.recolour = try content.createMaterial(.{
            .shading = render3d.lit_id,
            .roughness = 0.6,
            .base_color = .{ 0.4, 1.0, 0.45, 1 },
            .base_color_texture = .{ .content = .fromString("sandbox3d:models.crate.texture0") },
        });
        self.recolour_bound = renderer.materials.getConst(self.recolour).?.desc.base_color_texture;
        log.info("generated corner: patch {d} triangles at x {d}, water {d}² rewritten every frame ({t}), canvas {d}², landmark {t} on tick {d}", .{
            patch.indices.len / 3, origin.x, water_side, self.water_mode, canvas_size, mode, landmark_tick,
        });
    }

    /// Waits for anything still on the pool, then frees everything; before `content`, the
    /// renderer and `walk` go.
    pub fn deinit(self: *Corner, renderer: *render3d.Renderer, content: *render3d.Content, walk: *physics.World) void {
        // Nothing of ours may still be running on the pool when what it reads is freed.
        self.uploads.tasks.wait();
        if (self.landmark.job) |job| {
            if (job.result) |*mesh| mesh.deinit(job.gpa);
            self.gpa.destroy(job);
        }
        if (self.water_job) |job| {
            if (job.result) |*mesh| mesh.deinit(job.gpa);
            job.water.deinit(self.gpa);
            self.gpa.destroy(job);
        }
        self.uploads.deinit();
        if (!self.landmark.mesh.isNone()) renderer.destroyMesh(self.landmark.mesh);
        if (!self.recolour.isNone()) content.releaseMaterial(self.recolour);
        if (!self.crate.isNone()) content.releaseModel(self.crate);
        if (!self.landmark_material.isNone()) content.releaseMaterial(self.landmark_material);
        if (!self.canvas.material.isNone()) content.releaseMaterial(self.canvas.material);
        if (!self.canvas.mesh.isNone()) renderer.destroyMesh(self.canvas.mesh);
        if (!self.canvas.texture.isNone()) renderer.destroyTexture(self.canvas.texture);
        if (!self.water_material.isNone()) content.releaseMaterial(self.water_material);
        if (!self.water_mesh.isNone()) renderer.destroyMesh(self.water_mesh);
        if (!self.patch_material.isNone()) content.releaseMaterial(self.patch_material);
        if (!self.patch_body.isNone()) _ = walk.removeBody(self.gpa, self.patch_body);
        if (!self.patch_collision.isNone()) _ = walk.removeMesh(self.gpa, self.patch_collision) catch unreachable; // Its body went above.
        if (!self.patch_mesh.isNone()) renderer.destroyMesh(self.patch_mesh);
        self.water.deinit(self.gpa);
        self.gpa.free(self.canvas.pixels);
    }

    /// Once a frame, at its start and before simulation: finishes what the pool has filled,
    /// and hands a finished generation to `Uploads` (ADR-0061, decision 4).
    pub fn pump(self: *Corner, engine: *app.Engine, seconds: f32) void {
        const scope = engine.beginScope(uploads_span);
        defer scope.end();
        const pump_started = engine.os.monotonicNanos(); // Measurement only.
        if (self.landmark.stage == .generating) if (self.landmark.job) |job| if (job.done.isSet()) {
            self.landmark.job = null;
            defer self.gpa.destroy(job);
            if (job.result) |mesh| {
                if (self.uploads.createMesh(mesh, "sandbox3d landmark")) |handle| {
                    self.landmark.upload = handle;
                    self.landmark.stage = .uploading;
                } else |err| {
                    log.warn("landmark: refused by Uploads ({t}); it is not drawn", .{err});
                    var owned = mesh;
                    owned.deinit(job.gpa);
                    self.landmark.stage = .failed;
                }
            } else {
                log.warn("landmark: its generation ran out of memory; it is not drawn", .{});
                self.landmark.stage = .failed;
            }
        };
        // M27's pump budget: one large finish always runs under it.
        var budget: core.tasks.Budget = .{ .bytes = 8 << 20, .nodes = 16 };
        _ = self.uploads.pump(&budget);
        const pump_ns: i64 = @intCast(engine.os.monotonicNanos() - pump_started);
        self.pumpWater(engine, seconds, pump_ns);
        if (self.landmark.stage == .uploading) if (self.uploads.state(self.landmark.upload)) |state| switch (state) {
            .pending => {},
            .done => {
                self.landmark.mesh = self.uploads.result(self.landmark.upload).?.mesh;
                self.uploads.release(self.landmark.upload);
                self.landmark.upload = .none;
                self.ready(engine);
            },
            .failed, .cancelled => {
                log.warn("landmark: its upload did not finish ({t}); it is not drawn", .{state});
                self.uploads.release(self.landmark.upload);
                self.landmark.upload = .none;
                self.landmark.stage = .failed;
            },
        };
    }

    /// The pooled water: the last update collected, the finished generation requested, and the
    /// next one started. Its main-thread cost per update is its request, the next start, and
    /// the pump its finish ran in, which may have finished other work too: an upper bound.
    fn pumpWater(self: *Corner, engine: *app.Engine, seconds: f32, pump_ns: i64) void {
        const job = self.water_job orelse return;
        if (!self.water_upload.isNone()) if (self.uploads.state(self.water_upload)) |state| switch (state) {
            .pending => return,
            .done => {
                self.water_times.add(self.water_request_ns + pump_ns);
                self.uploads.release(self.water_upload);
                self.water_upload = .none;
            },
            .failed, .cancelled => {
                log.warn("water: an update did not finish ({t})", .{state});
                self.uploads.release(self.water_upload);
                self.water_upload = .none;
            },
        };
        const started = engine.os.monotonicNanos(); // Measurement only.
        if (self.water_running) {
            if (!job.done.isSet()) return;
            self.water_running = false;
            if (job.result) |mesh| {
                job.result = null;
                self.water_upload = self.uploads.updateMesh(self.water_mesh, mesh, "sandbox3d water") catch |err| blk: {
                    log.warn("water: an update was refused ({t})", .{err});
                    var owned = mesh;
                    owned.deinit(job.gpa);
                    break :blk .none;
                };
            } else log.warn("water: a generation ran out of memory", .{});
        }
        job.done = .{};
        job.seconds = seconds;
        self.uploads.tasks.start(.{ .context = job, .call = WaterJob.run }, &job.done) catch return;
        self.water_running = true;
        self.water_request_ns = @intCast(engine.os.monotonicNanos() - started);
    }

    /// One fixed tick: the landmark's request on its tick, and at most one canvas stamp.
    pub fn step(self: *Corner, engine: *app.Engine, renderer: *render3d.Renderer, tick: u64, look: ?[2]Vec3) void {
        if (tick == landmark_tick) self.request(engine, renderer);
        const at: ?[2]i64 = if (self.auto_paint) autoStroke(tick) else if (look) |l| canvasHit(l[0], l[1]) else null;
        if (at) |texel| {
            const started = engine.os.monotonicNanos(); // Measurement only.
            self.canvas.stamp(renderer, texel, brushColour(self.canvas.stamps)) catch |err| {
                log.warn("canvas: a stamp was refused ({t})", .{err});
                return;
            };
            self.canvas_times.add(@intCast(engine.os.monotonicNanos() - started));
        }
    }

    fn request(self: *Corner, engine: *app.Engine, renderer: *render3d.Renderer) void {
        if (self.landmark.stage != .idle) return;
        self.landmark.started_ns = engine.os.monotonicNanos();
        switch (self.mode) {
            .off => return,
            .@"inline" => {
                self.landmark.window.start(engine.frame_index, .sync);
                var mesh = spireMesh(self.gpa, spire_rings, spire_segments) catch |err| {
                    log.warn("landmark: not generated ({t})", .{err});
                    self.landmark.stage = .failed;
                    return;
                };
                defer mesh.deinit(self.gpa);
                self.landmark.mesh = renderer.createMesh(mesh.mesh, "sandbox3d landmark") catch |err| {
                    log.warn("landmark: not uploaded ({t})", .{err});
                    self.landmark.stage = .failed;
                    return;
                };
                self.ready(engine);
            },
            .background => {
                self.landmark.window.start(engine.frame_index, .background);
                const job = self.gpa.create(Job) catch {
                    self.landmark.stage = .failed;
                    return;
                };
                job.* = .{ .gpa = engine.taskAllocator() };
                self.uploads.tasks.start(.{ .context = job, .call = Job.run }, &job.done) catch |err| {
                    log.warn("landmark: the pool would not take its generation ({t})", .{err});
                    self.gpa.destroy(job);
                    self.landmark.stage = .failed;
                    return;
                };
                self.landmark.job = job;
                self.landmark.stage = .generating;
                log.info("landmark: requested on frame {d}", .{engine.frame_index});
            },
        }
    }

    fn ready(self: *Corner, engine: *app.Engine) void {
        const took: i64 = @intCast(engine.os.monotonicNanos() - self.landmark.started_ns);
        self.landmark.window.markReady(engine.frame_index, took);
        self.landmark.stage = .ready;
        log.info("landmark: ready {s} in {d:.3}ms on frame {d}", .{
            if (self.mode == .@"inline") "inline" else "in the background", ms(took), engine.frame_index,
        });
    }

    /// `inline`'s water, before the frame's window opens: rewritten from simulation time.
    pub fn updateWater(self: *Corner, engine: *app.Engine, renderer: *render3d.Renderer, seconds: f32) void {
        if (self.water_mode != .@"inline") return;
        const started = engine.os.monotonicNanos(); // Measurement only.
        self.water.fill(seconds);
        self.water_fill_times.add(@intCast(engine.os.monotonicNanos() - started));
        const mesh = self.water.mesh() catch |err| {
            log.warn("water: not rewritten ({t})", .{err});
            return;
        };
        const updating = engine.os.monotonicNanos(); // Measurement only.
        renderer.updateMesh(self.water_mesh, mesh, "sandbox3d water") catch |err| {
            log.warn("water: the update was refused ({t})", .{err});
            return;
        };
        const now = engine.os.monotonicNanos();
        self.water_update_times.add(@intCast(now - updating));
        self.water_times.add(@intCast(now - started));
    }

    pub fn clearCanvas(self: *Corner, renderer: *render3d.Renderer) void {
        self.canvas.clear(renderer) catch |err| log.warn("canvas: not cleared ({t})", .{err});
        log.info("c: the canvas is cleared", .{});
    }

    /// After a content change: what the recolour binds now, against what it bound before.
    pub fn noteReload(self: *Corner, renderer: *render3d.Renderer) void {
        const desc = (renderer.materials.getConst(self.recolour) orelse return).desc;
        log.info("recolour: material {d}.{d} {s}, binding texture {d}.{d} (was {d}.{d})", .{
            self.recolour.index,                                        self.recolour.generation,
            if (renderer.isMaterial(self.recolour)) "kept" else "LOST", desc.base_color_texture.index,
            desc.base_color_texture.generation,                         self.recolour_bound.index,
            self.recolour_bound.generation,
        });
        self.recolour_bound = desc.base_color_texture;
    }

    pub fn draw(self: *Corner, renderer: *render3d.Renderer, content: *render3d.Content) !void {
        try renderer.drawMesh(.{ .mesh = self.patch_mesh, .material = self.patch_material, .world = .identity });
        try renderer.drawMesh(.{ .mesh = self.water_mesh, .material = self.water_material, .world = .identity });
        try renderer.drawMesh(.{ .mesh = self.canvas.mesh, .material = self.canvas.material, .world = .identity });
        if (!self.landmark.mesh.isNone()) try renderer.drawMesh(.{ .mesh = self.landmark.mesh, .material = self.landmark_material, .world = .identity });
        const feet = patchHeight(patch_seed, 3, 3).y;
        try content.drawModel(.{
            .model = self.crate,
            .world = Mat4.translation(.init(origin.x + 3, feet + 0.45, origin.z + 3)),
            .overrides = &.{.{ .slot = 0, .material = self.recolour }},
        });
    }

    /// Where a person is put by **T**: the patch walk's start, facing along it.
    pub fn teleportTarget() Vec3 {
        return patch_start;
    }

    /// Said once at the end of a run, in the gallery's style, for an evidence run to read.
    pub fn report(self: *Corner) void {
        const water = self.water_times.summary();
        const water_fill = self.water_fill_times.summary();
        const water_update = self.water_update_times.summary();
        switch (self.water_mode) {
            .pooled => log.info("water: {d} updates of {d}² vertices ({t}), main thread median {d:.3}ms p95 {d:.3}ms max {d:.3}ms; budget p95 1.0ms", .{
                water.count, water_side, self.water_mode, ms(water.median_ns), ms(water.p95_ns), ms(water.max_ns),
            }),
            .@"inline" => log.info("water: {d} updates of {d}² vertices ({t}), main thread median {d:.3}ms p95 {d:.3}ms max {d:.3}ms (generation p95 {d:.3}ms, updateMesh p95 {d:.3}ms); budget p95 1.0ms", .{
                water.count, water_side, self.water_mode, ms(water.median_ns), ms(water.p95_ns), ms(water.max_ns), ms(water_fill.p95_ns), ms(water_update.p95_ns),
            }),
        }
        const canvas = self.canvas_times.summary();
        log.info("canvas: {d} stamps of {d}², main thread median {d:.3}ms p95 {d:.3}ms max {d:.3}ms; budget p95 0.5ms", .{
            canvas.count, brush_size, ms(canvas.median_ns), ms(canvas.p95_ns), ms(canvas.max_ns),
        });
        self.landmark.window.report();
    }
};

/// The canvas's quad, facing +X, with UVs top-left at the corner a person sees top-left.
fn canvasQuad(gpa: Allocator, renderer: *render3d.Renderer) !render3d.MeshHandle {
    const half = canvas_width / 2;
    const c = canvas_centre;
    const positions = [_]Vec3{
        .init(c.x, c.y - half, c.z + half), .init(c.x, c.y - half, c.z - half),
        .init(c.x, c.y + half, c.z - half), .init(c.x, c.y + half, c.z + half),
    };
    const normals = [_]Vec3{.init(1, 0, 0)} ** 4;
    const uvs = [_][2]f32{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };
    var builder: asset.MeshBuilder = .init(gpa, .{});
    defer builder.deinit();
    try builder.positions(&positions);
    try builder.normals(&normals);
    try builder.uv0(&uvs);
    try builder.indices16(&.{ 0, 1, 2, 0, 2, 3 });
    var mesh = try builder.finish();
    defer mesh.deinit(gpa);
    return renderer.createMesh(mesh.mesh, "sandbox3d canvas");
}

fn ms(ns: i64) f64 {
    return @as(f64, @floatFromInt(ns)) / core.time.ns_per_ms;
}

// -- tests -------------------------------------------------------------------------------

// Pinned from the first run on the Mac; see Step 6's Resolution.
const PATCH_DIGEST = 11729102987930533220;
const PATCH_END_X = 22.390009;
const PATCH_END_Y = 0.074692;
const PATCH_END_Z = 1.227917;
const SPIRE_DIGEST = 17175394173672716032;
const WATER_DIGEST = 8743190568358611974;

const testing = std.testing;
const walk_mod = @import("walk.zig");

test "the generate switch is background unless it names inline or off, and anything else is off" {
    try testing.expectEqual(Mode.background, Mode.parse(null));
    try testing.expectEqual(Mode.background, Mode.parse(" background "));
    try testing.expectEqual(Mode.@"inline", Mode.parse("inline"));
    try testing.expectEqual(Mode.off, Mode.parse("off"));
    for ([_][]const u8{ "", "sync", "INLINE" }) |bad| try testing.expectEqual(Mode.off, Mode.parse(bad));
}

test "the patch is the same bytes from its seed, walkable everywhere, and a walk across it ends where it is pinned" {
    var patch = try Patch.generate(testing.allocator, patch_seed);
    defer patch.deinit(testing.allocator);
    var mesh = try patch.mesh(testing.allocator);
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, PATCH_DIGEST), meshDigest(mesh.mesh));
    // Every normal is within the character's 45° of up, so nothing on it is a wall.
    for (patch.normals) |n| try testing.expect(n.y >= @cos(std.math.pi / 4.0));
    var again = try Patch.generate(testing.allocator, patch_seed);
    defer again.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(patch.positions), std.mem.sliceAsBytes(again.positions));

    // The sample's own walk, on the patch's triangles alone, stepped as a tick steps it.
    var walk = walk_mod.Walk.init(testing.allocator);
    // Its world only: this walk holds no collision asset for `Walk.deinit` to release.
    defer walk.world.deinit(testing.allocator);
    const collision = try walk.world.addMesh(testing.allocator, patch.positions, patch.indices);
    const body = try walk.world.addBody(testing.allocator, .{ .shape = .{ .mesh = collision } });
    defer {
        _ = walk.world.removeBody(testing.allocator, body);
        _ = walk.world.removeMesh(testing.allocator, collision) catch unreachable;
    }
    const dt: f32 = 1.0 / 60.0;
    walk.settings = .{
        .orbit = false,
        .spawn = patch_start,
        .spawn_yaw = 0,
        .character = .{ .radius = 0.3, .height = 1.8, .max_slope = 0.785398, .step_height = 0.35, .snap_distance = 0.3, .max_move = 1 },
        .eye_height = 1.65,
        .walk_speed = 3,
        .gravity = 9.81,
        .turn_rate = 1.5,
        .look_rate = 0.004,
        .course = .none,
    };
    walk.character = try walk.world.addCharacter(testing.allocator, walk.settings.?.character, patch_start, 0);
    for (0..180) |tick| try walk.step(.{ .direction = if (tick < 30) .zero else .init(1, 0, 0.3) }, dt);
    const feet = walk.result.feet;
    try testing.expect(walk.result.grounded);
    // On the patch's surface, under its far edge, and where it was pinned.
    try testing.expect(feet.x > origin.x and feet.x < origin.x + patch_extent / 2);
    try testing.expectApproxEqAbs(@as(f32, PATCH_END_X), feet.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, PATCH_END_Y), feet.y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, PATCH_END_Z), feet.z, 1e-4);
}

test "the landmark is the same bytes inline and from a pool task, and its digest is pinned" {
    var direct = try spireMesh(testing.allocator, spire_rings, spire_segments);
    defer direct.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, (spire_rings + 1) * (spire_segments + 1)), direct.mesh.vertex_count);
    try testing.expectEqual(@as(u64, SPIRE_DIGEST), meshDigest(direct.mesh));

    var manual = try core.tasks.Manual.init(testing.allocator, 1);
    defer manual.deinit();
    var job: Job = .{ .gpa = testing.allocator };
    try manual.tasks().start(.{ .context = &job, .call = Job.run }, &job.done);
    try testing.expect(!job.done.isSet());
    manual.runAll();
    try testing.expect(job.done.isSet() and !job.failed);
    defer job.result.?.deinit(testing.allocator);
    try testing.expectEqual(meshDigest(direct.mesh), meshDigest(job.result.?.mesh));
}

test "a brush stamp is clipped to the canvas, and a look paints only what it meets within reach" {
    const middle = stampAt(512, 512).?;
    try testing.expectEqual(render3d.TextureRegion{ .x = 480, .y = 480, .width = 64, .height = 64 }, middle.region);
    const corner = stampAt(10, 1020).?;
    try testing.expectEqual(render3d.TextureRegion{ .x = 0, .y = 988, .width = 42, .height = 36 }, corner.region);
    try testing.expectEqual(@as(u32, 22), corner.from_x);
    try testing.expectEqual(@as(u32, 0), corner.from_y);
    try testing.expect(stampAt(-40, 500) == null);
    try testing.expect(stampAt(500, 1060) == null);

    const front = canvas_centre.add(.init(2, 0, 0));
    // The centre, to within the texel a float's rounding moves it.
    const hit = canvasHit(front, .init(-1, 0, 0)).?;
    try testing.expect(@abs(hit[0] - 512) <= 1 and @abs(hit[1] - 512) <= 1);
    try testing.expect(canvasHit(canvas_centre.add(.init(reach + 0.5, 0, 0)), .init(-1, 0, 0)) == null);
    try testing.expect(canvasHit(front, .init(1, 0, 0)) == null);
    try testing.expect(canvasHit(front.add(.init(0, 0, canvas_width)), .init(-1, 0, 0)) == null);
    // From behind, looking at its back, nothing is painted through it.
    try testing.expect(canvasHit(canvas_centre.add(.init(-2, 0, 0)), .init(1, 0, 0)) == null);
    // An eye on its plane, looking along it, is no hit, and no division by zero.
    try testing.expect(canvasHit(canvas_centre, .init(0, 0, -1)) == null);
    // The stroke a run nobody watches paints stays on the canvas.
    for (0..600) |tick| try testing.expect(stampAt(autoStroke(tick)[0], autoStroke(tick)[1]) != null);
}

test "the water is a function of simulation time, inside its bounds, with unit normals" {
    var water = try Water.init(testing.allocator);
    defer water.deinit(testing.allocator);
    water.fill(1.5);
    const first = try testing.allocator.dupe(Vec3, water.positions);
    defer testing.allocator.free(first);
    water.fill(3.0);
    water.fill(1.5);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(first), std.mem.sliceAsBytes(water.positions));
    var amplitude: f32 = 0;
    for (waves) |w| amplitude += w.amplitude;
    for (water.positions, water.normals) |p, n| {
        try testing.expect(@abs(p.y - water_level) <= amplitude + 1e-5);
        try testing.expectApproxEqAbs(@as(f32, 1), n.length(), 1e-5);
    }
    const mesh = try water.mesh();
    try mesh.validate();
    // Pinned, so the waves cannot change direction or shape unnoticed.
    try testing.expectEqual(@as(u64, WATER_DIGEST), meshDigest(mesh));
}
