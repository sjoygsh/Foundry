//! Copied triangles and a deterministic median-split BVH (collision3d.md §6).
//! No asset dependency. Tree order is private; query candidates are sorted by original index.
const std = @import("std");
const core = @import("core");
const shape = @import("shape.zig");
const Vec3 = core.math.Vec3;
const Aabb = shape.Aabb;
const Allocator = std.mem.Allocator;

pub const max_triangles: usize = 1_048_576;
pub const max_positions: usize = 3_145_728;
pub const min_triangle_area: f32 = 1e-12;
pub const leaf_capacity: usize = 4;
// Median splitting of at most 2^20 triangles needs at most 21 pending branches.
pub const stack_capacity: usize = 32;
pub const AddError = error{ OutOfMemory, InvalidMesh };

/// Validation reports the first bad indexed triangle, or null for a count/unused-position
/// failure. Validation is performed before allocation, also by World.addMesh.
pub const Validation = struct { valid: bool, triangle: ?u32 = null };
pub fn validate(positions: []const Vec3, indices: []const u32) Validation {
    if (indices.len == 0 or indices.len % 3 != 0 or indices.len / 3 > max_triangles or
        positions.len == 0 or positions.len > max_positions) return .{ .valid = false };
    for (indices, 0..) |index, i| {
        if (index >= positions.len or !shape.positionValid(positions[index]))
            return .{ .valid = false, .triangle = @intCast(i / 3) };
    }
    for (positions) |p| if (!shape.positionValid(p)) return .{ .valid = false };
    return .{ .valid = true };
}

pub const Node = struct {
    bounds: Aabb,
    left: u32 = 0,
    right: u32 = 0,
    first: u32 = 0,
    count: u32 = 0, // nonzero only in a leaf
};

pub const Mesh = struct {
    positions: []Vec3,
    indices: []u32,
    order: []u32,
    nodes: []Node,
    node_count: u32 = 0,
    users: u32 = 0,

    pub fn init(gpa: Allocator, positions: []const Vec3, indices: []const u32) AddError!Mesh {
        if (!validate(positions, indices).valid) return error.InvalidMesh;
        const p = try gpa.dupe(Vec3, positions);
        errdefer gpa.free(p);
        const ix = try gpa.dupe(u32, indices);
        errdefer gpa.free(ix);
        const order = try gpa.alloc(u32, indices.len / 3);
        errdefer gpa.free(order);
        const nodes = try gpa.alloc(Node, order.len * 2);
        errdefer gpa.free(nodes);
        for (order, 0..) |*t, i| t.* = @intCast(i);
        var mesh: Mesh = .{ .positions = p, .indices = ix, .order = order, .nodes = nodes };
        _ = mesh.build(0, @intCast(order.len));
        return mesh;
    }

    pub fn deinit(self: *Mesh, gpa: Allocator) void {
        gpa.free(self.positions);
        gpa.free(self.indices);
        gpa.free(self.order);
        gpa.free(self.nodes);
    }

    pub fn triangle(self: *const Mesh, index: u32) [3]Vec3 {
        const first = @as(usize, index) * 3;
        return .{ self.positions[self.indices[first]], self.positions[self.indices[first + 1]], self.positions[self.indices[first + 2]] };
    }

    pub fn usable(self: *const Mesh, index: u32) bool {
        const pts = self.triangle(index);
        // Cross product magnitude = twice area. Keep degenerates in the copied input/tree,
        // but never feed a zero normal to the narrowphase.
        return Vec3.cross(pts[1].sub(pts[0]), pts[2].sub(pts[0])).lengthSquared() >=
            4 * min_triangle_area * min_triangle_area;
    }

    fn bounds(self: *const Mesh, index: u32) Aabb {
        const pts = self.triangle(index);
        return Aabb.around(pts[0]).include(pts[1]).include(pts[2]);
    }

    fn centroid(self: *const Mesh, index: u32) Vec3 {
        const pts = self.triangle(index);
        return pts[0].add(pts[1]).add(pts[2]).scale(1.0 / 3.0);
    }

    fn build(self: *Mesh, first: u32, count: u32) u32 {
        const node = self.node_count;
        self.node_count += 1;
        const items = self.order[first..][0..count];
        var box = self.bounds(items[0]);
        var centres = Aabb.around(self.centroid(items[0]));
        for (items[1..]) |t| {
            box = box.merge(self.bounds(t));
            centres = centres.include(self.centroid(t));
        }
        self.nodes[node] = .{ .bounds = box, .first = first, .count = count };
        if (count <= leaf_capacity) return node;
        const size = centres.max.sub(centres.min);
        const axis: u2 = if (size.x >= size.y and size.x >= size.z) 0 else if (size.y >= size.z) 1 else 2;
        const Context = struct {
            mesh: *const Mesh,
            axis: u2,
            fn less(ctx: @This(), a: u32, b: u32) bool {
                const ca = ctx.mesh.centroid(a);
                const cb = ctx.mesh.centroid(b);
                const va = switch (ctx.axis) {
                    0 => ca.x,
                    1 => ca.y,
                    else => ca.z,
                };
                const vb = switch (ctx.axis) {
                    0 => cb.x,
                    1 => cb.y,
                    else => cb.z,
                };
                return va < vb or (va == vb and a < b);
            }
        };
        std.sort.heap(u32, items, Context{ .mesh = self, .axis = axis }, Context.less);
        const left = self.build(first, count / 2);
        const right = self.build(first + count / 2, count - count / 2);
        self.nodes[node].count = 0;
        self.nodes[node].left = left;
        self.nodes[node].right = right;
        return node;
    }

    /// Fixed-stack walk, then index sort. `out` was reserved for this mesh's full count at
    /// add time; even a query covering the entire mesh performs no allocation.
    pub fn candidates(self: *const Mesh, pose: shape.Pose, area: Aabb, out: []u32) []const u32 {
        const transform: shape.Convex = .{ .core = .point, .radius = 0, .pose = pose };
        var stack: [stack_capacity]u32 = undefined;
        stack[0] = 0;
        var pending: usize = 1;
        var count: usize = 0;
        while (pending > 0) {
            pending -= 1;
            const node = self.nodes[stack[pending]];
            // Expand for rigid-transform f32 rounding at the coordinate bound. A false
            // positive only costs a narrowphase; a false negative would lose collision.
            if (!transform.poseBounds(node.bounds).expand(0.002).overlaps(area)) continue;
            if (node.count != 0) {
                for (self.order[node.first..][0..node.count]) |t| {
                    if (!self.usable(t)) continue;
                    out[count] = t;
                    count += 1;
                }
            } else {
                stack[pending] = node.right;
                stack[pending + 1] = node.left;
                pending += 2;
            }
        }
        std.sort.heap(u32, out[0..count], {}, std.sort.asc(u32));
        return out[0..count];
    }
};
