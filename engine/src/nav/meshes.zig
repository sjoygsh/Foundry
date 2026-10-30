//! A running game's meshes (`agents.md` §9, ADR-0070): the rebuilds of one recipe, at most one in
//! flight, and the generations they arrived as.
//!
//! **A running obstacle is a source.** A game keeps its level's sources and adds a `boxSource` per
//! obstacle at its pose as it is now. There is no incremental update: the ordinary build runs on
//! the background pool, and a gate at `closed` cuts a doorway because it is a box there.
//!
//! **Arrival is not adoption** (ADR-0061's decision 4). `pump` numbers an arrived mesh and goes no
//! further. A game puts that number in the next tick's recorded input, and only the tick calls
//! `Crowd.setMesh`. So when a build finished, which is a wall-clock fact, reaches simulation only
//! as an input, and a replay handed the same input reads the same mesh from here.
//!
//! **A generation's bytes are a pure function of what was asked for,** so a run and its replay
//! share one `Meshes`.

const std = @import("std");
const core = @import("core");

const config_mod = @import("config.zig");
const features_mod = @import("features.zig");
const input = @import("input.zig");
const poly = @import("poly.zig");
const task = @import("task.zig");

const Allocator = std.mem.Allocator;
const Mesh = poly.Mesh;
const Pose = input.Pose;
const Source = input.Source;
const Vec3 = core.math.Vec3;

/// A box's corners, for as long as its `Source` is read.
pub const BoxGeometry = struct {
    positions: [8]Vec3,
};

/// Twelve triangles, wound outward.
const box_indices = [36]u32{
    3, 7, 6, 3, 6, 2, // top
    0, 1, 5, 0, 5, 4, // bottom
    0, 4, 7, 0, 7, 3, // −X
    1, 2, 6, 1, 6, 5, // +X
    0, 3, 2, 0, 2, 1, // −Z
    4, 5, 6, 4, 6, 7, // +Z
};

/// A closed box centred on `pose`, as a source. `out` must outlive the `Source`, and a build copies
/// it at `start`.
pub fn boxSource(half_extents: Vec3, pose: Pose, out: *BoxGeometry) Source {
    const h = half_extents;
    out.positions = .{
        .init(-h.x, -h.y, -h.z), .init(h.x, -h.y, -h.z), .init(h.x, h.y, -h.z), .init(-h.x, h.y, -h.z),
        .init(-h.x, -h.y, h.z),  .init(h.x, -h.y, h.z),  .init(h.x, h.y, h.z),  .init(-h.x, h.y, h.z),
    };
    return .{ .positions = &out.positions, .indices = &box_indices, .pose = pose };
}

pub const Options = struct {
    /// Generations kept; 0 keeps them all. Past it the oldest goes, except the first and the one
    /// in use. A game that replays keeps all it may adopt, and one that does not keeps a few.
    keep: u32 = 0,
};

pub const Arrival = union(enum) {
    /// A new generation, to be put in the next tick's input.
    generation: u32,
    failed: poly.BuildError,
};

pub const Meshes = struct {
    gpa: Allocator,
    options: Options,
    /// Heap entries, so a mesh does not move while a crowd borrows it. Index + 1 is the
    /// generation; null once dropped.
    entries: std.ArrayList(?*Mesh) = .empty,
    pending: ?task.Build = null,
    dirty: bool = false,
    in_use: u32 = 0,
    /// Builds that arrived, and those that failed.
    rebuilds: u32 = 0,
    failed_builds: u32 = 0,

    pub fn init(gpa: Allocator, options: Options) Meshes {
        return .{ .gpa = gpa, .options = options };
    }

    /// Waits for a build in flight through `tasks`, then frees everything.
    pub fn deinit(self: *Meshes, tasks: core.Tasks) void {
        tasks.wait();
        if (self.pending) |*b| b.deinit();
        for (self.entries.items) |entry| {
            if (entry) |m| self.free(m);
        }
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    fn free(self: *Meshes, m: *Mesh) void {
        m.deinit(self.gpa);
        self.gpa.destroy(m);
    }

    /// Something a mesh is built from has changed.
    pub fn markDirty(self: *Meshes) void {
        self.dirty = true;
    }

    /// Whether a build should start now: something changed, and none is running. While one runs,
    /// changes wait for it, so a crate dragged across a room makes a few rebuilds and not one a
    /// tick. The next build reads the poses as they are by then.
    pub fn wantsBuild(self: *const Meshes) bool {
        return self.dirty and self.pending == null;
    }

    /// Starts a build. A full executor leaves it dirty, to try again.
    pub fn start(self: *Meshes, tasks: core.Tasks, config: config_mod.Config, sources: []const Source, features: features_mod.Features) task.StartError!void {
        std.debug.assert(self.pending == null);
        self.pending = try task.Build.startWith(tasks, self.gpa, config, sources, features);
        self.dirty = false;
    }

    /// Takes a finished build, if there is one. On the main thread, between frames.
    pub fn pump(self: *Meshes) ?Arrival {
        const pending = &(self.pending orelse return null);
        const answer = pending.take() orelse return null;
        pending.deinit();
        self.pending = null;
        const fresh = answer catch |err| {
            self.failed_builds += 1;
            return .{ .failed = err };
        };
        const generation = self.add(fresh) catch |err| {
            self.failed_builds += 1;
            return .{ .failed = err };
        };
        self.rebuilds += 1;
        return .{ .generation = generation };
    }

    /// Keeps `mesh`, which is now this list's, as the next generation.
    pub fn add(self: *Meshes, mesh: Mesh) Allocator.Error!u32 {
        var owned = mesh;
        errdefer owned.deinit(self.gpa);
        const entry = try self.gpa.create(Mesh);
        errdefer self.gpa.destroy(entry);
        try self.entries.append(self.gpa, entry);
        entry.* = owned;
        self.evict();
        return @intCast(self.entries.items.len);
    }

    fn evict(self: *Meshes) void {
        if (self.options.keep == 0) return;
        var live: u32 = 0;
        for (self.entries.items) |e| live += @intFromBool(e != null);
        const newest = self.entries.items.len;
        for (self.entries.items, 1..) |*entry, generation| {
            if (live <= self.options.keep) return;
            const m = entry.* orelse continue;
            if (generation == 1 or generation == self.in_use or generation == newest) continue;
            self.free(m);
            entry.* = null;
            live -= 1;
        }
    }

    /// The mesh of `generation`, or null if there is none or it was dropped.
    pub fn get(self: *const Meshes, generation: u32) ?*const Mesh {
        if (generation == 0 or generation > self.entries.items.len) return null;
        return self.entries.items[generation - 1];
    }

    /// Says a crowd now reads `generation`, so that it is not dropped.
    pub fn use(self: *Meshes, generation: u32) void {
        self.in_use = generation;
    }
};
