//! Copied triangles and a deterministic median-split BVH (collision3d.md §6).
//! No asset dependency. Query candidates are sorted by original index, so the tree's own order
//! never reaches an answer, and a tree from outside, once validated, answers as a built one does
//! (collision-scale.md §5, ADR-0077).
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
/// The deepest a node may sit under the root, which is at depth 0. `candidates` holds one pending
/// branch a level and the pair it has just pushed, so a path this deep fills its stack exactly.
pub const max_depth: u32 = stack_capacity - 1;
pub const AddError = error{ OutOfMemory, InvalidMesh };
/// The most surfaces one mesh's table holds (`collision-extras.md` §6): an index is 16 bits, and
/// `no_surface` is the one value left over.
pub const max_surfaces: usize = 65_535;
/// A triangle's surface index when it has none, and its body's surface applies.
pub const no_surface: u16 = 0xFFFF;

/// What a mesh's triangles are made of and which way they face (`collision-extras.md` §6).
/// An empty per-triangle slice means none of them: no surfaces, or every triangle two-sided.
/// Otherwise it has one entry per triangle.
pub const Attributes = struct {
    /// Content IDs `physics3d` reports and never interprets (I5). At most `max_surfaces`.
    surfaces: []const core.ContentId = &.{},
    /// Per triangle, an index into `surfaces`, or `no_surface`.
    triangle_surfaces: []const u16 = &.{},
    /// Per triangle, whether it collides from its front alone: the side its counter-clockwise
    /// winding faces, as glTF's front faces are.
    one_sided: []const bool = &.{},
    /// The mesh's tree, when it arrives with one (`collision-scale.md` §5). It is untrusted:
    /// `initWith` checks it as `validateTree` does, copies it, and builds nothing. A wrong tree
    /// refuses the mesh as `InvalidMesh`. It is never rebuilt.
    tree: ?Tree = null,

    pub fn valid(a: Attributes, triangles: usize) bool {
        if (a.surfaces.len > max_surfaces) return false;
        if (a.triangle_surfaces.len != 0 and a.triangle_surfaces.len != triangles) return false;
        if (a.one_sided.len != 0 and a.one_sided.len != triangles) return false;
        for (a.triangle_surfaces) |index| if (index != no_surface and index >= a.surfaces.len) return false;
        return true;
    }
};

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

/// A mesh's tree as a value: nodes in preorder, the root first, and the triangles in the order
/// the leaves hold them. A leaf's `first` and `count` name a run of `order`. An inner node has
/// `count` zero, its left child is the node after it, and `right` names the other.
pub const Tree = struct {
    nodes: []const Node,
    order: []const u32,

    /// The depth of the deepest node, the root being at 0. Only for a valid tree.
    pub fn height(tree: Tree) u32 {
        var stack: [stack_capacity]u32 = undefined;
        var pending: usize = 0;
        var depth: u32 = 0;
        var deepest: u32 = 0;
        for (tree.nodes) |node| {
            deepest = @max(deepest, depth);
            if (node.count == 0) {
                depth += 1;
                stack[pending] = depth;
                pending += 1;
            } else if (pending > 0) {
                pending -= 1;
                depth = stack[pending];
            }
        }
        return deepest;
    }
};

/// Why a tree was refused (`collision-scale.md` §5).
pub const TreeFault = enum {
    /// The triangles themselves fail `validate`. No node is named.
    mesh,
    /// No nodes, or more than two a triangle less one.
    node_count,
    /// `order` is not one entry a triangle.
    order_length,
    /// An inner node's right child is not after its left, or is past the last node.
    child,
    /// The nodes are not in preorder: a left child is not the next node, a right child is not
    /// where the walk arrives, or nodes are left over. A node named twice is one of these.
    preorder,
    /// A node deeper than `max_depth`.
    depth,
    /// A leaf of more than `leaf_capacity` triangles. A count of zero is an inner node.
    leaf_size,
    /// A leaf's run does not start where the one before it ended, runs past `order`, or the
    /// leaves together do not take all of it.
    run,
    /// `order` names a triangle the mesh does not have.
    triangle,
    /// `order` names a triangle twice.
    repeated,
    /// A leaf's box does not contain one of its triangles.
    leaf_bounds,
    /// A node's box is not inside its parent's. The node named is the child.
    parent_bounds,
};

/// `node` is the node at fault, or null when the fault is not one node's.
pub const TreeValidation = struct { valid: bool, fault: ?TreeFault = null, node: ?u32 = null };

/// Whether `tree` is a tree of this mesh that `candidates` can walk and lose nothing by. One pass
/// over the nodes and one over the triangles, no sort. The memory is a bit a triangle, freed
/// before returning. A box larger than it needs to be is slow and not wrong, so containment is
/// the whole test of a box.
pub fn validateTree(gpa: Allocator, positions: []const Vec3, indices: []const u32, tree: Tree) error{OutOfMemory}!TreeValidation {
    if (!validate(positions, indices).valid) return .{ .valid = false, .fault = .mesh };
    return checkTree(gpa, positions, indices, tree);
}

fn refuse(fault: TreeFault, node: ?usize) TreeValidation {
    return .{ .valid = false, .fault = fault, .node = if (node) |n| @intCast(n) else null };
}

/// `validateTree` for triangles already known to pass `validate`.
fn checkTree(gpa: Allocator, positions: []const Vec3, indices: []const u32, tree: Tree) error{OutOfMemory}!TreeValidation {
    const triangles = indices.len / 3;
    const nodes = tree.nodes;
    if (nodes.len == 0 or nodes.len > triangles * 2 - 1) return refuse(.node_count, null);
    if (tree.order.len != triangles) return refuse(.order_length, null);
    const seen = try gpa.alloc(u8, (triangles + 7) / 8);
    defer gpa.free(seen);
    @memset(seen, 0);

    // A right child waiting for the walk to come back to it.
    const Pending = struct { node: u32, parent: u32, depth: u32 };
    var stack: [stack_capacity]Pending = undefined;
    var pending: usize = 0;
    var parent: ?u32 = null;
    var depth: u32 = 0;
    var taken: usize = 0;
    for (nodes, 0..) |node, i| {
        if (depth > max_depth) return refuse(.depth, i);
        if (parent) |above| {
            if (!contains(nodes[above].bounds, node.bounds)) return refuse(.parent_bounds, i);
        }
        if (node.count == 0) {
            if (node.left != i + 1) return refuse(.preorder, i);
            if (node.right <= node.left or node.right >= nodes.len) return refuse(.child, i);
            stack[pending] = .{ .node = node.right, .parent = @intCast(i), .depth = depth + 1 };
            pending += 1;
            parent = @intCast(i);
            depth += 1;
            continue;
        }
        if (node.count > leaf_capacity) return refuse(.leaf_size, i);
        if (node.first != taken or node.count > triangles - taken) return refuse(.run, i);
        for (tree.order[taken..][0..node.count]) |t| {
            if (t >= triangles) return refuse(.triangle, i);
            const bit = @as(u8, 1) << @intCast(t % 8);
            if (seen[t / 8] & bit != 0) return refuse(.repeated, i);
            seen[t / 8] |= bit;
            const first = @as(usize, t) * 3;
            for (indices[first..][0..3]) |index| {
                if (!contains(node.bounds, Aabb.around(positions[index]))) return refuse(.leaf_bounds, i);
            }
        }
        taken += node.count;
        if (pending == 0) {
            if (i + 1 != nodes.len) return refuse(.preorder, i + 1);
            break;
        }
        pending -= 1;
        const next = stack[pending];
        if (next.node != i + 1) return refuse(.preorder, next.node);
        parent = next.parent;
        depth = next.depth;
    } else {
        // The last node would be an inner one, which the child check never allows.
        unreachable;
    }
    // n distinct triangles in range are all of them, so this is also the permutation check.
    if (taken != triangles) return refuse(.run, nodes.len - 1);
    return .{ .valid = true };
}

/// Each comparison must hold, so a box with a NaN in it contains nothing.
fn contains(outer: Aabb, inner: Aabb) bool {
    return outer.min.x <= inner.min.x and outer.min.y <= inner.min.y and outer.min.z <= inner.min.z and
        outer.max.x >= inner.max.x and outer.max.y >= inner.max.y and outer.max.z >= inner.max.z;
}

/// A tree `buildTree` made, owned by whoever asked.
pub const Built = struct {
    nodes: []Node,
    order: []u32,

    pub fn tree(self: Built) Tree {
        return .{ .nodes = self.nodes, .order = self.order };
    }

    pub fn deinit(self: *Built, gpa: Allocator) void {
        gpa.free(self.nodes);
        gpa.free(self.order);
        self.* = undefined;
    }
};

/// The tree `Mesh.init` builds for these triangles, node for node. It is what `author` bakes
/// into a file, so a baked mesh and a built one walk the same tree.
pub fn buildTree(gpa: Allocator, positions: []const Vec3, indices: []const u32) AddError!Built {
    if (!validate(positions, indices).valid) return error.InvalidMesh;
    return buildChecked(gpa, positions, indices);
}

fn buildChecked(gpa: Allocator, positions: []const Vec3, indices: []const u32) error{OutOfMemory}!Built {
    const order = try gpa.alloc(u32, indices.len / 3);
    errdefer gpa.free(order);
    for (order, 0..) |*t, i| t.* = @intCast(i);
    // A leaf holds at least one triangle, so there are never more than 2n - 1 nodes.
    var nodes = try gpa.alloc(Node, order.len * 2);
    errdefer gpa.free(nodes);
    var builder: Builder = .{ .positions = positions, .indices = indices, .order = order, .nodes = nodes };
    _ = builder.build(0, @intCast(order.len));
    if (gpa.resize(nodes, builder.node_count)) {
        nodes = nodes[0..builder.node_count];
    } else {
        const exact = try gpa.dupe(Node, nodes[0..builder.node_count]);
        gpa.free(nodes);
        nodes = exact;
    }
    return .{ .nodes = nodes, .order = order };
}

fn triangleOf(positions: []const Vec3, indices: []const u32, index: u32) [3]Vec3 {
    const first = @as(usize, index) * 3;
    return .{ positions[indices[first]], positions[indices[first + 1]], positions[indices[first + 2]] };
}

const Builder = struct {
    positions: []const Vec3,
    indices: []const u32,
    order: []u32,
    nodes: []Node,
    node_count: u32 = 0,

    fn bounds(self: *const Builder, index: u32) Aabb {
        const pts = triangleOf(self.positions, self.indices, index);
        return Aabb.around(pts[0]).include(pts[1]).include(pts[2]);
    }

    fn centroid(self: *const Builder, index: u32) Vec3 {
        const pts = triangleOf(self.positions, self.indices, index);
        return pts[0].add(pts[1]).add(pts[2]).scale(1.0 / 3.0);
    }

    fn build(self: *Builder, first: u32, count: u32) u32 {
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
            mesh: *const Builder,
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
};

pub const Mesh = struct {
    positions: []Vec3,
    indices: []u32,
    order: []u32,
    nodes: []Node,
    /// Whether the tree arrived with the mesh, and was not built here.
    baked: bool = false,
    /// Copied `Attributes`, each empty when the mesh was given none.
    surfaces: []core.ContentId = &.{},
    triangle_surfaces: []u16 = &.{},
    one_sided: []bool = &.{},
    users: u32 = 0,

    pub fn init(gpa: Allocator, positions: []const Vec3, indices: []const u32) AddError!Mesh {
        return initWith(gpa, positions, indices, .{});
    }

    /// `init`, with surfaces, one-sided triangles and perhaps a tree. Refused as `InvalidMesh`
    /// when `attributes` is not `valid` for the mesh's triangle count, or its tree fails
    /// `validateTree`, which says why.
    pub fn initWith(gpa: Allocator, positions: []const Vec3, indices: []const u32, attributes: Attributes) AddError!Mesh {
        if (!validate(positions, indices).valid) return error.InvalidMesh;
        if (!attributes.valid(indices.len / 3)) return error.InvalidMesh;
        const surfaces = try gpa.dupe(core.ContentId, attributes.surfaces);
        errdefer gpa.free(surfaces);
        const triangle_surfaces = try gpa.dupe(u16, attributes.triangle_surfaces);
        errdefer gpa.free(triangle_surfaces);
        const one_sided = try gpa.dupe(bool, attributes.one_sided);
        errdefer gpa.free(one_sided);
        const p = try gpa.dupe(Vec3, positions);
        errdefer gpa.free(p);
        const ix = try gpa.dupe(u32, indices);
        errdefer gpa.free(ix);
        var built: Built = undefined;
        if (attributes.tree) |given| {
            if (!(try checkTree(gpa, positions, indices, given)).valid) return error.InvalidMesh;
            const order = try gpa.dupe(u32, given.order);
            errdefer gpa.free(order);
            built = .{ .nodes = try gpa.dupe(Node, given.nodes), .order = order };
        } else {
            built = try buildChecked(gpa, positions, indices);
        }
        return .{
            .positions = p,
            .indices = ix,
            .order = built.order,
            .nodes = built.nodes,
            .baked = attributes.tree != null,
            .surfaces = surfaces,
            .triangle_surfaces = triangle_surfaces,
            .one_sided = one_sided,
        };
    }

    /// The tree this mesh walks, borrowed.
    pub fn tree(self: *const Mesh) Tree {
        return .{ .nodes = self.nodes, .order = self.order };
    }

    pub fn deinit(self: *Mesh, gpa: Allocator) void {
        gpa.free(self.positions);
        gpa.free(self.indices);
        gpa.free(self.order);
        gpa.free(self.nodes);
        gpa.free(self.surfaces);
        gpa.free(self.triangle_surfaces);
        gpa.free(self.one_sided);
    }

    /// A triangle's own surface, or none, when its body's applies.
    pub fn surfaceOf(self: *const Mesh, index: u32) core.ContentId {
        if (self.triangle_surfaces.len == 0) return .none;
        const at = self.triangle_surfaces[index];
        return if (at == no_surface) .none else self.surfaces[at];
    }

    pub fn oneSided(self: *const Mesh, index: u32) bool {
        return self.one_sided.len != 0 and self.one_sided[index];
    }

    pub fn triangle(self: *const Mesh, index: u32) [3]Vec3 {
        return triangleOf(self.positions, self.indices, index);
    }

    pub fn usable(self: *const Mesh, index: u32) bool {
        const pts = self.triangle(index);
        // Cross product magnitude = twice area. Keep degenerates in the copied input/tree,
        // but never feed a zero normal to the narrowphase.
        return Vec3.cross(pts[1].sub(pts[0]), pts[2].sub(pts[0])).lengthSquared() >=
            4 * min_triangle_area * min_triangle_area;
    }

    /// Fixed-stack walk, then index sort. `out` was reserved for this mesh's full count at
    /// add time; even a query covering the entire mesh performs no allocation.
    pub fn candidates(self: *const Mesh, pose: shape.Pose, scale: Vec3, area: Aabb, out: []u32) []const u32 {
        // The query box is moved into the mesh's own space once, rather than every node's box
        // into the world: a node that overlaps the area in the world has a point the inverse
        // pose carries into both its local box and the area's local bounds, so nothing is lost.
        const inverse: shape.Pose = .{
            .position = pose.inverseDirection(pose.position.scale(-1)),
            .rotation = pose.rotation.conjugate(),
        };
        const local: shape.Convex = .{ .core = .point, .radius = 0, .pose = inverse };
        // Expand for rigid-transform f32 rounding at the coordinate bound. A false positive
        // only costs a narrowphase; a false negative would lose collision.
        const posed = local.poseBounds(area);
        // Then out of the body's scale, which is positive on every axis, so the box stays a box.
        const local_area = (Aabb{ .min = posed.min.div(scale), .max = posed.max.div(scale) }).expand(0.002);
        var stack: [stack_capacity]u32 = undefined;
        stack[0] = 0;
        var pending: usize = 1;
        var count: usize = 0;
        while (pending > 0) {
            pending -= 1;
            const node = self.nodes[stack[pending]];
            if (!node.bounds.overlaps(local_area)) continue;
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
