//! Agents: a value a game owns and ticks, beside its collision world (`agents.md` §6, ADR-0070).
//!
//! **An agent wishes, and the game moves it.** `step` computes each agent's displacement for the
//! tick; the game applies it however it likes and reports the result with `place`. A game with no
//! bodies skips `place`, because `step` has already kept the agent on the surface. So this module
//! needs no collision world, and `nav` stays on `core` alone.
//!
//! **A corridor, not a search a tick.** An agent keeps the polygons from where it is toward its
//! goal, recomputes the corners along them each tick, and searches again only when its target
//! leaves them. Searches are budgeted per tick, oldest request first and then by slot, so a
//! rebuilt mesh spreads its cost over a few ticks.
//!
//! **Allocates at `init` and never again.** `step` takes no allocator.
//!
//! **Determinism** (I9): ticks are counted, not read from a clock; agents are stepped by slot; a
//! freed slot is reused lowest first; nothing reads an address. `hash` covers everything a tick
//! computes, as a pin and a replay read it.

const std = @import("std");
const core = @import("core");

const avoidance = @import("avoidance.zig");
const crossing = @import("crossing.zig");
const features = @import("features.zig");
const funnel = @import("funnel.zig");
const locate = @import("locate.zig");
const poly = @import("poly.zig");
const search = @import("search.zig");
const surface = @import("surface.zig");

const Allocator = std.mem.Allocator;
const Filter = search.Filter;
const Located = locate.Located;
const Mesh = poly.Mesh;
const Step = search.Step;
const Vec3 = core.math.Vec3;
const none_link = search.none_link;
const Vec2 = avoidance.Vec2;

/// Turns every preferred velocity the same small way when neighbours are near, so that two agents
/// exactly head-on drift to their own sides (§8). Its sine and cosine, for about half a degree.
const keep_side_sine: f32 = 0.01;
const keep_side_cosine: f32 = 0.99995;

pub const Agents = opaque {};
pub const AgentHandle = core.Handle(Agents);

pub const max_agents: u32 = 256;
/// The most polygons an agent's corridor holds. A longer path is walked in parts.
pub const max_corridor = 256;
/// Corners computed a tick: the next is steered at, and the one after says whether it is the last.
const corner_count = 4;

pub const Options = struct {
    max_agents: u32 = 64,
    /// Searches a step may run.
    max_searches_per_step: u32 = 8,
    /// Each search's node limit.
    max_nodes: u32 = search.default_query_nodes,
    /// Ticks of barely moving before an agent says it is blocked.
    blocked_ticks: u32 = 60,
    /// How far ahead avoidance looks, seconds.
    horizon: f32 = 1.5,
};

pub const AgentParams = struct {
    radius: f32,
    height: f32,
    /// Metres a second.
    speed: f32,
    /// Metres a second, per second.
    acceleration: f32,
    /// How near the goal is arrived, and how near a link's end begins it.
    arrival_radius: f32 = 0.25,
    /// Ticks between searches while the target moves.
    replan_ticks: u32 = 15,
    /// How far from a target's point a polygon may be, half-sizes in metres.
    target_extent: Vec3 = .init(0.5, 2, 0.5),
    filter: Filter = .{},

    pub fn valid(p: *const AgentParams) bool {
        return within(p.radius, 0.001, 5) and within(p.height, 0.01, 10) and
            within(p.speed, 0.001, 50) and within(p.acceleration, 0.001, 1000) and
            within(p.arrival_radius, 0.01, 10) and p.replan_ticks >= 1 and p.replan_ticks <= 36_000 and
            within(p.target_extent.x, 0, 100) and within(p.target_extent.y, 0, 100) and within(p.target_extent.z, 0, 100) and
            p.filter.valid();
    }
};

fn within(value: f32, lo: f32, hi: f32) bool {
    return std.math.isFinite(value) and value >= lo and value <= hi;
}

pub const AgentState = enum {
    /// No target.
    idle,
    walking,
    /// Crossing a link, and out of avoidance.
    on_link,
    /// At the goal, or as near as could be reached.
    arrived,
    /// Trying, and barely moving. A game's policy decides what that means.
    blocked,
    /// Its feet are on no polygon, and it asks for no move until `place` finds a floor.
    off_mesh,
};

pub const AgentView = struct {
    state: AgentState,
    position: Vec3,
    velocity: Vec3,
    /// `none_polygon` while off the mesh.
    polygon: u32,
    /// Whether the current path reaches the target.
    complete: bool,
    /// The link being crossed, and how far, 0 to 1.
    link: u32,
    link_t: f32,
};

const Crossing = struct {
    link: u32,
    kind: features.LinkKind,
    leave: Vec3,
    land: Vec3,
    arc: f32,
    t: f32 = 0,
    rate: f32,
};

pub const Agent = struct {
    used: bool = false,
    generation: u32 = 0,
    params: AgentParams = undefined,
    state: AgentState = .idle,
    position: Vec3 = .zero,
    last_position: Vec3 = .zero,
    velocity: Vec3 = .zero,
    /// Where it would go this tick with no one else there, and where avoidance sends it.
    preferred: Vec2 = .{},
    chosen: Vec2 = .{},
    steering: bool = false,
    wish: Vec3 = .zero,
    polygon: u32 = poly.none_polygon,
    has_target: bool = false,
    target: Vec3 = .zero,
    target_dirty: bool = false,
    /// Where the corridor ends, and whether that is the target.
    goal: Located = .{ .polygon = poly.none_polygon, .point = .zero },
    complete: bool = false,
    /// A search has been asked for, at this tick.
    pending: bool = false,
    requested: u64 = 0,
    /// A search is wanted once `replan_ticks` have passed since the last.
    wanted: bool = false,
    since_search: u32 = 0,
    blocked_for: u32 = 0,
    crossing: ?Crossing = null,
    head: u32 = 0,
    count: u32 = 0,
    steps: [max_corridor]Step = undefined,

    pub fn corridor(self: *const Agent) []const Step {
        return self.steps[self.head..self.count];
    }
};

pub const AddError = error{ Full, InvalidAgent, InvalidPose };

pub const Wish = struct {
    /// What the agent asks to move by this tick. Metres.
    displacement: Vec3,
    /// Whether it is crossing a link, on a curve a controller would refuse: a game with a body
    /// sets its feet for these ticks.
    on_link: bool,
};

pub const Crowd = struct {
    gpa: Allocator,
    options: Options,
    agents: []Agent,
    query: search.Query,
    mesh: ?*const Mesh = null,
    tick: u64 = 0,
    /// Searches run by the last `step`, the most in any one, and in all.
    searches_last_step: u32 = 0,
    searches_most: u32 = 0,
    searches_total: u64 = 0,

    pub const InitError = search.InitError || error{InvalidOptions};

    pub fn init(gpa: Allocator, options: Options) InitError!Crowd {
        if (options.max_agents == 0 or options.max_agents > max_agents or options.max_searches_per_step == 0) return error.InvalidOptions;
        if (!within(options.horizon, 0.1, 60)) return error.InvalidOptions;
        const agents = try gpa.alloc(Agent, options.max_agents);
        errdefer gpa.free(agents);
        @memset(agents, .{});
        return .{ .gpa = gpa, .options = options, .agents = agents, .query = try .init(gpa, options.max_nodes) };
    }

    pub fn deinit(self: *Crowd) void {
        self.query.deinit();
        self.gpa.free(self.agents);
        self.* = undefined;
    }

    /// Borrows `mesh`, which stays alive and unchanged until the next `setMesh`. Every agent
    /// re-seats on it and asks for a new path, since a rebuild renumbers polygons. One crossing a
    /// link finishes first, because its ends are points and not polygons.
    pub fn setMesh(self: *Crowd, mesh: *const Mesh) void {
        self.mesh = mesh;
        for (self.agents) |*a| {
            if (!a.used) continue;
            a.count = 0;
            a.head = 0;
            a.pending = false;
            a.wanted = false;
            if (a.crossing != null) continue;
            a.target_dirty = a.has_target;
            self.seat(a, a.position);
        }
    }

    fn slot(self: *const Crowd, handle: AgentHandle) ?*Agent {
        if (handle.isNone() or handle.index >= self.agents.len) return null;
        const a = &self.agents[handle.index];
        return if (a.used and a.generation == handle.generation) a else null;
    }

    pub fn add(self: *Crowd, params: AgentParams, feet: Vec3) AddError!AgentHandle {
        if (!params.valid()) return error.InvalidAgent;
        if (!feet.isFinite()) return error.InvalidPose;
        for (self.agents, 0..) |*a, i| {
            if (a.used) continue;
            var generation = a.generation +% 1;
            if (generation == 0) generation = 1;
            // Field by field: the corridor's buffer is not worth writing.
            a.used = true;
            a.generation = generation;
            a.params = params;
            a.state = .idle;
            a.position = feet;
            a.last_position = feet;
            a.velocity = .zero;
            a.wish = .zero;
            a.polygon = poly.none_polygon;
            a.has_target = false;
            a.target_dirty = false;
            a.complete = false;
            a.pending = false;
            a.wanted = false;
            a.since_search = 0;
            a.blocked_for = 0;
            a.crossing = null;
            a.head = 0;
            a.count = 0;
            self.seat(a, feet);
            return .{ .index = @intCast(i), .generation = generation };
        }
        return error.Full;
    }

    pub fn remove(self: *Crowd, handle: AgentHandle) bool {
        const a = self.slot(handle) orelse return false;
        a.used = false;
        return true;
    }

    /// Where the agent should go. Finds its polygon at the next `step`. False for a stale handle
    /// or a point that is not finite.
    pub fn setTarget(self: *Crowd, handle: AgentHandle, point: Vec3) bool {
        const a = self.slot(handle) orelse return false;
        if (!point.isFinite()) return false;
        a.target = point;
        a.has_target = true;
        a.target_dirty = true;
        // A new target is a new attempt: `blocked` said the last one was stuck.
        if (!point.eql(a.goal.point)) {
            a.blocked_for = 0;
            if (a.state == .blocked) a.state = .walking;
        }
        return true;
    }

    pub fn clearTarget(self: *Crowd, handle: AgentHandle) bool {
        const a = self.slot(handle) orelse return false;
        a.has_target = false;
        a.target_dirty = false;
        a.pending = false;
        a.wanted = false;
        a.count = 0;
        a.head = 0;
        a.velocity = .zero;
        if (a.state != .on_link and a.state != .off_mesh) a.state = .idle;
        return true;
    }

    pub fn wish(self: *const Crowd, handle: AgentHandle) ?Wish {
        const a = self.slot(handle) orelse return null;
        return .{ .displacement = a.wish, .on_link = a.crossing != null };
    }

    pub fn agent(self: *const Crowd, handle: AgentHandle) ?AgentView {
        const a = self.slot(handle) orelse return null;
        return .{
            .state = a.state,
            .position = a.position,
            .velocity = a.velocity,
            .polygon = a.polygon,
            .complete = a.complete,
            .link = if (a.crossing) |c| c.link else none_link,
            .link_t = if (a.crossing) |c| c.t else 0,
        };
    }

    /// Where the body ended up. Ignored during a crossing, whose curve the game was told to
    /// follow, and for a point that is not finite.
    pub fn place(self: *Crowd, handle: AgentHandle, feet: Vec3) void {
        const a = self.slot(handle) orelse return;
        if (a.crossing != null or !feet.isFinite()) return;
        self.seat(a, feet);
    }

    /// Puts `a` on the polygon under `feet`: its own, then along its corridor, then anywhere near.
    fn seat(self: *Crowd, a: *Agent, feet: Vec3) void {
        const mesh = self.mesh orelse {
            a.position = feet;
            a.state = .off_mesh;
            return;
        };
        const extent: Vec3 = .init(a.params.radius, a.params.height * 0.5, a.params.radius);
        var at: ?Located = null;
        if (a.polygon < mesh.polygons.len) {
            at = onPolygon(mesh, a.polygon, feet, extent.y);
            for (a.steps[0..a.count]) |s| {
                if (at != null) break;
                at = onPolygon(mesh, s.polygon, feet, extent.y);
            }
        }
        if (at == null) at = mesh.locate(feet, extent);
        const found = at orelse {
            a.position = feet;
            a.polygon = poly.none_polygon;
            a.state = .off_mesh;
            a.velocity = .zero;
            return;
        };
        a.position = found.point;
        a.polygon = found.polygon;
        if (a.state == .off_mesh) a.state = if (a.has_target) .walking else .idle;
        if (!advance(a, found.polygon) and a.has_target) self.requestSearch(a);
    }

    fn onPolygon(mesh: *const Mesh, pi: u32, feet: Vec3, reach: f32) ?Located {
        if (!surface.contains(mesh, pi, feet)) return null;
        const y = locate.heightOn(mesh, pi, feet.x, feet.z) orelse return null;
        if (@abs(y - feet.y) > reach) return null;
        return .{ .polygon = pi, .point = .init(feet.x, y, feet.z) };
    }

    /// Moves the corridor's head to `polygon`, or back to it: a body that lags its wish can be
    /// placed in a polygon the agent has just left, and that is still the same corridor. False if
    /// the corridor does not hold it.
    fn advance(a: *Agent, polygon: u32) bool {
        for (a.head..a.count) |i| {
            if (a.steps[i].polygon == polygon) {
                a.head = @intCast(i);
                return true;
            }
        }
        var i = a.head;
        while (i > 0) {
            i -= 1;
            if (a.steps[i].polygon == polygon) {
                a.head = @intCast(i);
                return true;
            }
        }
        return false;
    }

    fn requestSearch(self: *const Crowd, a: *Agent) void {
        if (a.pending) return;
        a.pending = true;
        a.requested = self.tick;
    }

    /// One fixed tick: finds targets, runs what searches the budget allows, then moves every
    /// agent. A `dt` that is not a positive number moves nothing.
    pub fn step(self: *Crowd, dt: f32) void {
        if (!std.math.isFinite(dt) or dt <= 0) return;
        self.tick += 1;
        self.searches_last_step = 0;
        const mesh = self.mesh orelse return;
        for (self.agents) |*a| {
            if (a.used) self.retarget(mesh, a);
        }
        self.runSearches(mesh);
        for (self.agents) |*a| {
            if (!a.used) continue;
            a.wish = .zero;
            a.steering = false;
            if (a.crossing != null) {
                self.cross(a, dt);
                continue;
            }
            switch (a.state) {
                .walking, .blocked => self.prefer(mesh, a, dt),
                .idle, .arrived, .off_mesh, .on_link => {},
            }
        }
        // From where everyone is, and from last tick's velocities, then applied together: so no
        // agent's answer depends on which slot it is in.
        for (self.agents, 0..) |*a, i| {
            if (a.used and a.steering) self.avoid(a, i, dt);
        }
        for (self.agents) |*a| {
            if (a.used and a.steering) self.drive(mesh, a, dt);
        }
    }

    /// `a.chosen`: its preferred velocity, kept clear of its eight nearest neighbours.
    fn avoid(self: *const Crowd, a: *Agent, self_index: usize, dt: f32) void {
        const me: avoidance.Party = .{ .position = flat(a.position), .velocity = flat(a.velocity), .radius = a.params.radius };
        const reach = a.params.speed * self.options.horizon + a.params.radius;
        var nearest: [avoidance.max_lines]u32 = undefined;
        var distances: [avoidance.max_lines]f32 = undefined;
        var count: usize = 0;
        for (self.agents, 0..) |*b, i| {
            if (!b.used or i == self_index) continue;
            // Another floor is no neighbour.
            if (@abs(b.position.y - a.position.y) > @max(a.params.height, b.params.height)) continue;
            const limit = reach + b.params.radius;
            const offset = flat(b.position).sub(me.position);
            const d = offset.x * offset.x + offset.z * offset.z;
            if (d > limit * limit) continue;
            // Kept sorted by distance, then by slot, and the far end falls off.
            var at = count;
            while (at > 0 and d < distances[at - 1]) at -= 1;
            if (at == avoidance.max_lines) continue;
            if (count < avoidance.max_lines) count += 1;
            var move = count - 1;
            while (move > at) : (move -= 1) {
                nearest[move] = nearest[move - 1];
                distances[move] = distances[move - 1];
            }
            nearest[at] = @intCast(i);
            distances[at] = d;
        }
        if (count == 0) {
            a.chosen = a.preferred;
            return;
        }
        var lines: [avoidance.max_lines]avoidance.Line = undefined;
        for (nearest[0..count], lines[0..count]) |i, *line| {
            const b = &self.agents[i];
            const moving = b.steering;
            const other: avoidance.Party = .{ .position = flat(b.position), .velocity = if (moving) flat(b.velocity) else .{}, .radius = b.params.radius };
            const tie: f32 = if (self_index < i) -1 else 1;
            line.* = avoidance.lineFor(me, other, self.options.horizon, dt, if (moving) 0.5 else 1, tie);
        }
        const p = a.preferred;
        const turned: Vec2 = .{ .x = p.x * keep_side_cosine - p.z * keep_side_sine, .z = p.x * keep_side_sine + p.z * keep_side_cosine };
        a.chosen = avoidance.solve(lines[0..count], turned, a.params.speed);
    }

    /// Finds the target's polygon, if it moved. The corridor's end and its neighbours first:
    /// a target that walks a little needs no scan and no search.
    fn retarget(self: *Crowd, mesh: *const Mesh, a: *Agent) void {
        if (a.since_search < std.math.maxInt(u32)) a.since_search += 1;
        if (a.target_dirty) {
            a.target_dirty = false;
            if (a.state == .arrived or a.state == .idle) a.state = .walking;
            const reach = a.params.target_extent.y;
            if (a.count > a.head and a.complete) {
                const last = a.steps[a.count - 1].polygon;
                if (onPolygon(mesh, last, a.target, reach)) |found| {
                    a.goal = found;
                } else if (a.count == max_corridor or !extendTo(mesh, a, last)) {
                    self.relocate(mesh, a);
                }
            } else self.relocate(mesh, a);
        }
        if (a.wanted and a.since_search >= a.params.replan_ticks) {
            a.wanted = false;
            self.requestSearch(a);
        }
    }

    fn extendTo(mesh: *const Mesh, a: *Agent, last: u32) bool {
        const p = &mesh.polygons[last];
        for (p.neighbours[0..p.count]) |q| {
            if (q == poly.none_polygon) continue;
            if (onPolygon(mesh, q, a.target, a.params.target_extent.y)) |found| {
                a.steps[a.count] = .{ .polygon = q };
                a.count += 1;
                a.goal = found;
                return true;
            }
        }
        return false;
    }

    /// The target has left the corridor: a scan, and a search as soon as `replan_ticks` allows.
    fn relocate(self: *const Crowd, mesh: *const Mesh, a: *Agent) void {
        const found = mesh.locate(a.target, a.params.target_extent) orelse return;
        a.goal = found;
        if (a.count == a.head) {
            self.requestSearch(a);
        } else a.wanted = true;
    }

    fn runSearches(self: *Crowd, mesh: *const Mesh) void {
        var budget = self.options.max_searches_per_step;
        while (budget > 0) : (budget -= 1) {
            var oldest: ?*Agent = null;
            for (self.agents) |*a| {
                if (!a.used or !a.pending or a.crossing != null) continue;
                if (a.polygon == poly.none_polygon or a.goal.polygon >= mesh.polygons.len) continue;
                if (oldest == null or a.requested < oldest.?.requested) oldest = a;
            }
            const a = oldest orelse return;
            a.pending = false;
            a.since_search = 0;
            const path = self.query.find(mesh, &a.params.filter, .{ .polygon = a.polygon, .point = a.position }, a.goal, &a.steps);
            self.searches_last_step += 1;
            self.searches_most = @max(self.searches_most, self.searches_last_step);
            self.searches_total += 1;
            if (path.count == 0) continue;
            a.head = 0;
            a.count = path.count;
            a.complete = path.complete;
            a.goal = .{ .polygon = a.steps[path.count - 1].polygon, .point = path.end };
            if (a.state == .arrived) a.state = .walking;
        }
    }

    /// What `a` would do alone: its state, and `a.preferred`.
    fn prefer(self: *Crowd, mesh: *const Mesh, a: *Agent, dt: f32) void {
        const moved = flatLength(a.position.sub(a.last_position));
        a.last_position = a.position;
        if (moved < 0.1 * a.params.speed * dt) {
            a.blocked_for += 1;
            if (a.blocked_for >= self.options.blocked_ticks) a.state = .blocked;
        } else {
            a.blocked_for = 0;
            a.state = .walking;
        }
        if (a.count == a.head) return;
        var buffer: [corner_count]funnel.Corner = undefined;
        const corners = funnel.corners(mesh, a.corridor(), a.position, a.goal.point, &buffer);
        if (corners.len == 0) {
            self.requestSearch(a);
            return;
        }
        const next = corners[0];
        const d = flatLength(next.point.sub(a.position));
        const is_link = next.link != none_link;
        const last = !is_link and corners.len == 1;
        if (d <= a.params.arrival_radius) {
            if (is_link) {
                beginCrossing(mesh, a, next);
                self.cross(a, dt);
                return;
            }
            if (last) {
                a.state = .arrived;
                a.velocity = .zero;
                a.blocked_for = 0;
                return;
            }
        }
        var speed = a.params.speed;
        if (last) speed = @min(speed, @sqrt(2 * a.params.acceleration * d));
        const scale = if (d > 0) speed / d else 0;
        a.preferred = .{ .x = (next.point.x - a.position.x) * scale, .z = (next.point.z - a.position.z) * scale };
        a.steering = true;
    }

    /// Moves `a` by what avoidance chose, as far as its acceleration and the mesh allow.
    fn drive(self: *Crowd, mesh: *const Mesh, a: *Agent, dt: f32) void {
        const wanted: Vec3 = .init(a.chosen.x, 0, a.chosen.z);
        const change = wanted.sub(a.velocity);
        const room = a.params.acceleration * dt;
        const size = change.length();
        a.velocity = if (size > room) a.velocity.add(change.scale(room / size)) else wanted;
        const to = a.position.add(a.velocity.scale(dt));
        const moved_to = surface.move(mesh, a.polygon, a.position, to);
        a.wish = moved_to.point.sub(a.position);
        a.position = moved_to.point;
        a.polygon = moved_to.polygon;
        if (!advance(a, moved_to.polygon)) {
            if (a.head > 0) {
                a.head -= 1;
                a.steps[a.head] = .{ .polygon = moved_to.polygon };
            } else self.requestSearch(a);
        }
    }

    fn beginCrossing(mesh: *const Mesh, a: *Agent, corner: funnel.Corner) void {
        const l = &mesh.links[corner.link];
        const land = if (corner.reversed) l.from else l.to;
        const seconds = crossing.duration(l.kind, a.position, land, a.params.speed);
        a.crossing = .{
            .link = corner.link,
            .kind = l.kind,
            .leave = a.position,
            .land = land,
            .arc = l.arc,
            .rate = if (seconds > 0) 1 / seconds else std.math.inf(f32),
        };
        a.state = .on_link;
        a.velocity = .zero;
    }

    fn cross(self: *Crowd, a: *Agent, dt: f32) void {
        const c = &a.crossing.?;
        c.t = @min(1, c.t + c.rate * dt);
        const now = crossing.at(c.kind, c.leave, c.land, c.arc, a.params.speed, c.t);
        a.wish = now.sub(a.position);
        a.position = now;
        a.last_position = now;
        if (c.t < 1) return;
        const link = c.link;
        a.crossing = null;
        a.state = if (a.has_target) .walking else .idle;
        // The corridor went with the mesh if it was rebuilt meanwhile: `setMesh` emptied it.
        var along = false;
        for (a.head..a.count) |i| {
            if (a.steps[i].link == link) {
                a.head = @intCast(i);
                along = true;
                break;
            }
        }
        if (!along) {
            a.count = 0;
            a.head = 0;
            a.target_dirty = a.has_target;
        }
        a.polygon = if (along) a.steps[a.head].polygon else poly.none_polygon;
        self.seat(a, now);
    }

    /// Everything a tick computes, as bits.
    pub fn hash(self: *const Crowd) u64 {
        var h = std.hash.Wyhash.init(0);
        for (self.agents) |*a| {
            if (!a.used) continue;
            h.update(&.{@intFromEnum(a.state)});
            for ([_]f32{ a.position.x, a.position.y, a.position.z, a.velocity.x, a.velocity.y, a.velocity.z, a.wish.x, a.wish.y, a.wish.z }) |f| {
                h.update(std.mem.asBytes(&@as(u32, @bitCast(f))));
            }
            for ([_]u32{ a.polygon, a.head, a.count, a.blocked_for, a.since_search }) |w| h.update(std.mem.asBytes(&w));
            if (a.crossing) |c| h.update(std.mem.asBytes(&@as(u32, @bitCast(c.t))));
        }
        return h.final();
    }
};

fn flat(v: Vec3) Vec2 {
    return .{ .x = v.x, .z = v.z };
}

fn flatLength(v: Vec3) f32 {
    return @sqrt(v.x * v.x + v.z * v.z);
}
