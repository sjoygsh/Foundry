//! What navigation is doing, as a plain value (`agents.md` §10): what the overlay's panel prints.
//!
//! **The introspection lives here, and the overlay only prints it** (ADR-0025). A `Report` is
//! values and no pointers, so M48 can publish it with no redesign. `nav` reads no clock, so a game
//! that wants the times fills them in from its own profiler.

const features = @import("features.zig");
const crowd_mod = @import("crowd.zig");
const meshes_mod = @import("meshes.zig");
const poly = @import("poly.zig");

const state_count = @typeInfo(crowd_mod.AgentState).@"enum".fields.len;

pub const Report = struct {
    has_mesh: bool = false,
    polygons: u32 = 0,
    detail_triangles: u32 = 0,
    islands: u32 = 0,
    links: u32 = 0,
    links_unattached: u32 = 0,
    /// Regions left out of the mesh, which is worth a warning.
    skipped: u32 = 0,
    /// Square metres of each area, by index.
    area_m2: [features.max_areas]f32 = @splat(0),
    area_count: u32 = 0,

    generation: u32 = 0,
    rebuilds: u32 = 0,
    failed_builds: u32 = 0,
    building: bool = false,
    /// A game's own measure, or zero.
    build_ms: f32 = 0,

    agents: u32 = 0,
    /// By `AgentState`.
    agents_in: [state_count]u32 = @splat(0),
    searches_this_tick: u32 = 0,
    searches_most: u32 = 0,
    searches_total: u64 = 0,
    /// A game's own measure, or zero.
    step_p95_ms: f32 = 0,

    pub fn readMesh(self: *Report, mesh: *const poly.Mesh) void {
        self.has_mesh = true;
        self.polygons = @intCast(mesh.polygons.len);
        self.detail_triangles = @intCast(mesh.detail.triangles.len);
        self.islands = mesh.islands;
        self.links = @intCast(mesh.links.len);
        self.links_unattached = mesh.links_unattached;
        self.skipped = mesh.skipped;
        self.area_m2 = @splat(0);
        var highest: u32 = 0;
        const cs: f64 = mesh.cell_size;
        for (mesh.polygons) |*p| {
            const cells2: f64 = @floatFromInt(poly.polygonArea2(mesh, p));
            self.area_m2[p.area] += @floatCast(cells2 * cs * cs / 2);
            highest = @max(highest, p.area);
        }
        self.area_count = @max(highest + 1, @as(u32, @intCast(mesh.costs.len)));
    }

    pub fn readMeshes(self: *Report, meshes: *const meshes_mod.Meshes, generation: u32) void {
        self.generation = generation;
        self.rebuilds = meshes.rebuilds;
        self.failed_builds = meshes.failed_builds;
        self.building = meshes.pending != null;
    }

    pub fn readCrowd(self: *Report, crowd: *const crowd_mod.Crowd) void {
        self.agents = 0;
        self.agents_in = @splat(0);
        for (crowd.agents) |*a| {
            if (!a.used) continue;
            self.agents += 1;
            self.agents_in[@intFromEnum(a.state)] += 1;
        }
        self.searches_this_tick = crowd.searches_last_step;
        self.searches_most = crowd.searches_most;
        self.searches_total = crowd.searches_total;
    }
};
