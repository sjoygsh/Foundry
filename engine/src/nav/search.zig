//! Path search: A* over a mesh's polygons, with a link as one more edge (`agents.md` §5).
//!
//! **A `Query` allocates once,** at `init`, and `find` takes no allocator, so a search inside a
//! tick cannot allocate. Its bound is `max_nodes` polygons visited, and a search that reaches it
//! answers the best partial path.
//!
//! **Measured by edge midpoints,** so a path is a good one, not the shortest: a polygon graph has
//! no exact shortest path. `funnel.zig` straightens what this finds.
//!
//! **Determinism** (I9): the heap orders by cost and then by polygon index, polygons are expanded
//! edge by edge and then link by link, and nothing reads an address.

const std = @import("std");
const core = @import("core");

const features = @import("features.zig");
const link_mod = @import("link.zig");
const locate_mod = @import("locate.zig");
const poly = @import("poly.zig");

const Allocator = std.mem.Allocator;
const Located = locate_mod.Located;
const Mesh = poly.Mesh;
const Vec3 = core.math.Vec3;

pub const none_link = link_mod.none_link;
pub const max_query_nodes: u32 = 65_536;
pub const default_query_nodes: u32 = 4_096;

/// What one agent may walk. Applies to a whole search.
pub const Filter = struct {
    /// Multiplies an area's cost; zero excludes it. Anything else below one is refused, because
    /// it would break the heuristic. Indexed by area.
    area_scale: [features.max_areas]f32 = @splat(1),
    /// Bit `k` set excludes `LinkKind` `k`.
    excluded_links: u8 = 0,

    pub fn valid(self: *const Filter) bool {
        for (self.area_scale) |s| {
            if (!std.math.isFinite(s) or (s != 0 and s < 1)) return false;
        }
        return true;
    }

    pub fn excludes(self: *const Filter, kind: features.LinkKind) bool {
        return self.excluded_links & (@as(u8, 1) << @as(u3, @intCast(@intFromEnum(kind)))) != 0;
    }
};

/// One polygon of a path, and how it was entered.
pub const Step = struct {
    polygon: u32,
    /// The link crossed to reach it, or `none_link` if it was walked to.
    link: u32 = none_link,
    /// Whether that link was crossed from its `to` end.
    reversed: bool = false,
};

pub const Path = struct {
    /// Steps written, the first being the start's polygon. Zero for a search that was refused.
    count: u32 = 0,
    /// Whether it reaches the goal. If not, it ends as near the goal as could be reached.
    complete: bool = false,
    /// Where it ends: the goal, or the nearest point of its last polygon.
    end: Vec3 = .zero,
};

const none_node: u32 = std.math.maxInt(u32);

const Node = struct {
    polygon: u32,
    parent: u32,
    link: u32,
    reversed: bool,
    closed: bool,
    /// Where the path enters this polygon.
    point: Vec3,
    /// Cost so far, and that plus the distance left.
    g: f32,
    f: f32,
    /// Its place in the heap, while it is open.
    heap_at: u32,
};

pub const InitError = Allocator.Error || error{InvalidNodes};

pub const Query = struct {
    gpa: Allocator,
    nodes: []Node,
    /// Open addressing from a polygon to its node, a power of two at least twice `nodes`.
    slots: []u32,
    heap: []u32,

    pub fn init(gpa: Allocator, max_nodes: u32) InitError!Query {
        if (max_nodes == 0 or max_nodes > max_query_nodes) return error.InvalidNodes;
        const nodes = try gpa.alloc(Node, max_nodes);
        errdefer gpa.free(nodes);
        const slots = try gpa.alloc(u32, std.math.ceilPowerOfTwoAssert(u32, 2 * max_nodes));
        errdefer gpa.free(slots);
        const heap = try gpa.alloc(u32, max_nodes);
        return .{ .gpa = gpa, .nodes = nodes, .slots = slots, .heap = heap };
    }

    pub fn deinit(self: *Query) void {
        self.gpa.free(self.nodes);
        self.gpa.free(self.slots);
        self.gpa.free(self.heap);
        self.* = undefined;
    }

    /// A path from `start` to `goal`, written to `out`. A start or goal off this mesh, or a filter
    /// that is not valid, answers nothing. A path longer than `out` is cut off after `out.len`
    /// steps, and is not complete.
    pub fn find(self: *Query, mesh: *const Mesh, filter: *const Filter, start: Located, goal: Located, out: []Step) Path {
        if (out.len == 0 or !filter.valid()) return .{};
        const polygons: u32 = @intCast(mesh.polygons.len);
        if (start.polygon >= polygons or goal.polygon >= polygons) return .{};
        if (!start.point.isFinite() or !goal.point.isFinite()) return .{};

        @memset(self.slots, none_node);
        var search: Search = .{ .query = self, .mesh = mesh, .filter = filter, .goal = goal };
        const first = search.add(start.polygon).?;
        const h = start.point.sub(goal.point).length();
        self.nodes[first] = .{ .polygon = start.polygon, .parent = none_node, .link = none_link, .reversed = false, .closed = false, .point = start.point, .g = 0, .f = h, .heap_at = 0 };
        search.push(first);
        var best = first;
        var best_h = h;

        var reached: ?u32 = null;
        while (search.pop()) |at| {
            if (self.nodes[at].polygon == goal.polygon) {
                reached = at;
                break;
            }
            self.nodes[at].closed = true;
            search.expand(at, &best, &best_h);
        }

        const last = reached orelse best;
        var length: u32 = 0;
        var walk = last;
        while (walk != none_node) : (walk = self.nodes[walk].parent) length += 1;
        // Skip what `out` cannot hold, so that it keeps the start of the path.
        const written: u32 = @min(length, @as(u32, @intCast(out.len)));
        walk = last;
        var drop = length - written;
        while (drop > 0) : (drop -= 1) walk = self.nodes[walk].parent;
        var i = written;
        var end_node = walk;
        while (i > 0) {
            i -= 1;
            const n = &self.nodes[walk];
            out[i] = .{ .polygon = n.polygon, .link = n.link, .reversed = n.reversed };
            walk = n.parent;
        }
        end_node = if (written == length) last else end_node;
        const complete = reached != null and written == length;
        const end = if (complete) goal.point else locate_mod.nearestOn(mesh, self.nodes[end_node].polygon, goal.point);
        return .{ .count = written, .complete = complete, .end = end };
    }
};

const Search = struct {
    query: *Query,
    mesh: *const Mesh,
    filter: *const Filter,
    goal: Located,
    used: u32 = 0,
    heap_len: u32 = 0,

    fn slotOf(self: *const Search, polygon: u32) usize {
        const mask = self.query.slots.len - 1;
        var at: usize = @as(usize, polygon) *% 2654435761 & mask;
        while (true) : (at = (at + 1) & mask) {
            const n = self.query.slots[at];
            if (n == none_node or self.query.nodes[n].polygon == polygon) return at;
        }
    }

    /// A fresh node for `polygon`, or null when the query has no more.
    fn add(self: *Search, polygon: u32) ?u32 {
        if (self.used == self.query.nodes.len) return null;
        const n = self.used;
        self.used += 1;
        self.query.slots[self.slotOf(polygon)] = n;
        self.query.nodes[n].polygon = polygon;
        return n;
    }

    /// What polygon `p`'s floor charges per metre under this filter, or null if it is excluded.
    fn rate(self: *const Search, p: u32) ?f32 {
        const scale = self.filter.area_scale[self.mesh.polygons[p].area];
        return if (scale == 0) null else scale * self.mesh.costOf(p);
    }

    fn expand(self: *Search, at: u32, best: *u32, best_h: *f32) void {
        const here = self.query.nodes[at];
        const p = self.mesh.polygons[here.polygon];
        // A start in an excluded area may still walk out of it.
        const rate_here = self.rate(here.polygon) orelse 1;
        for (p.neighbours[0..p.count], 0..) |q, e| {
            if (q == poly.none_polygon or q == here.polygon) continue;
            const a = self.mesh.position(p.vertices[e]);
            const b = self.mesh.position(p.vertices[(e + 1) % p.count]);
            const mid = a.add(b).scale(0.5);
            self.visit(at, q, mid, here.point.sub(mid).length() * rate_here, none_link, false, best, best_h);
        }
        for (self.mesh.linksFrom(here.polygon)) |li| {
            const l = &self.mesh.links[li];
            if (self.filter.excludes(l.kind)) continue;
            const reversed = l.from_polygon != here.polygon;
            const q = if (reversed) l.from_polygon else l.to_polygon;
            if (q == here.polygon) continue;
            const leave = if (reversed) l.to else l.from;
            const land = if (reversed) l.from else l.to;
            const step = here.point.sub(leave).length() * rate_here + leave.sub(land).length() + l.cost;
            self.visit(at, q, land, step, li, reversed, best, best_h);
        }
    }

    fn visit(self: *Search, from: u32, q: u32, point: Vec3, step: f32, link: u32, reversed: bool, best: *u32, best_h: *f32) void {
        const rate_q = self.rate(q) orelse return;
        const nodes = self.query.nodes;
        var g = nodes[from].g + step;
        const to_goal = point.sub(self.goal.point).length();
        var h = to_goal;
        if (q == self.goal.polygon) {
            g += to_goal * rate_q;
            h = 0;
        }
        const slot = self.query.slots[self.slotOf(q)];
        var n = slot;
        const known = slot != none_node;
        if (known) {
            if (nodes[n].closed or g >= nodes[n].g) return;
        } else {
            n = self.add(q) orelse return;
        }
        nodes[n] = .{ .polygon = q, .parent = from, .link = link, .reversed = reversed, .closed = false, .point = point, .g = g, .f = g + h, .heap_at = if (known) nodes[n].heap_at else 0 };
        if (known) self.siftUp(nodes[n].heap_at) else self.push(n);
        if (to_goal < best_h.* or (to_goal == best_h.* and q < nodes[best.*].polygon)) {
            best.* = n;
            best_h.* = to_goal;
        }
    }

    fn before(self: *const Search, a: u32, b: u32) bool {
        const na = &self.query.nodes[a];
        const nb = &self.query.nodes[b];
        if (na.f != nb.f) return na.f < nb.f;
        return na.polygon < nb.polygon;
    }

    fn place(self: *Search, at: u32, n: u32) void {
        self.query.heap[at] = n;
        self.query.nodes[n].heap_at = at;
    }

    fn push(self: *Search, n: u32) void {
        self.place(self.heap_len, n);
        self.heap_len += 1;
        self.siftUp(self.heap_len - 1);
    }

    fn siftUp(self: *Search, start: u32) void {
        var at = start;
        const n = self.query.heap[at];
        while (at > 0) {
            const parent = (at - 1) / 2;
            const up = self.query.heap[parent];
            if (!self.before(n, up)) break;
            self.place(at, up);
            at = parent;
        }
        self.place(at, n);
    }

    fn pop(self: *Search) ?u32 {
        if (self.heap_len == 0) return null;
        const top = self.query.heap[0];
        self.heap_len -= 1;
        if (self.heap_len == 0) return top;
        const n = self.query.heap[self.heap_len];
        var at: u32 = 0;
        while (true) {
            var child = 2 * at + 1;
            if (child >= self.heap_len) break;
            if (child + 1 < self.heap_len and self.before(self.query.heap[child + 1], self.query.heap[child])) child += 1;
            if (!self.before(self.query.heap[child], n)) break;
            self.place(at, self.query.heap[child]);
            at = child;
        }
        self.place(at, n);
        return top;
    }
};
