//! A mesh's tree from outside (`collision-scale.md` §5, M38 Step 3).
//!
//! A tree is untrusted. A valid one answers exactly as the built one does, whatever its shape,
//! and each way of being wrong is refused under its own name.
const std = @import("std");
const core = @import("core");
const p = @import("root.zig");
const m = @import("mesh.zig");
const Pcg32 = core.rng.Pcg32;
const Vec3 = core.math.Vec3;
const Aabb = p.shape.Aabb;
const t = std.testing;
const gpa = t.allocator;

/// A bumpy ground of `nx` by `nz` squares, two triangles each.
const Ground = struct {
    positions: []Vec3,
    indices: []u32,

    fn init(nx: usize, nz: usize) !Ground {
        const positions = try gpa.alloc(Vec3, (nx + 1) * (nz + 1));
        errdefer gpa.free(positions);
        const indices = try gpa.alloc(u32, nx * nz * 6);
        var rng = Pcg32.init(38, 3);
        for (0..nz + 1) |j| for (0..nx + 1) |i| {
            positions[j * (nx + 1) + i] = .init(@floatFromInt(i), rng.float01() * 0.6, @floatFromInt(j));
        };
        var k: usize = 0;
        for (0..nz) |j| for (0..nx) |i| {
            const a: u32 = @intCast(j * (nx + 1) + i);
            const w: u32 = @intCast(nx + 1);
            for ([_]u32{ a, a + w, a + 1, a + 1, a + w, a + w + 1 }) |v| {
                indices[k] = v;
                k += 1;
            }
        };
        return .{ .positions = positions, .indices = indices };
    }

    fn deinit(self: Ground) void {
        gpa.free(self.positions);
        gpa.free(self.indices);
    }

    fn triangles(self: Ground) usize {
        return self.indices.len / 3;
    }

    fn boxOf(self: Ground, triangle: u32) Aabb {
        const ix = self.indices[@as(usize, triangle) * 3 ..][0..3];
        return Aabb.around(self.positions[ix[0]]).include(self.positions[ix[1]]).include(self.positions[ix[2]]);
    }
};

/// A tree as lopsided as one can be: every inner node's left child is a leaf, and the rest hangs
/// from its right. `leaves` leaves share the triangles, in a shuffled order. Its deepest node is
/// at depth `leaves - 1`.
const Chain = struct {
    nodes: []m.Node,
    order: []u32,

    fn init(ground: Ground, leaves: usize, loosen: f32) !Chain {
        const n = ground.triangles();
        std.debug.assert(leaves >= 1 and leaves <= n and leaves * m.leaf_capacity >= n);
        const order = try gpa.alloc(u32, n);
        errdefer gpa.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        var rng = Pcg32.init(77, 5);
        var i = n;
        while (i > 1) : (i -= 1) std.mem.swap(u32, &order[i - 1], &order[rng.below(@intCast(i))]);

        const nodes = try gpa.alloc(m.Node, leaves * 2 - 1);
        var first: u32 = 0;
        for (0..leaves) |leaf| {
            const count: u32 = @intCast(n / leaves + @intFromBool(leaf < n % leaves));
            var box = ground.boxOf(order[first]);
            for (order[first..][0..count]) |triangle| box = box.merge(ground.boxOf(triangle));
            const at = if (leaf + 1 == leaves) leaf * 2 else leaf * 2 + 1;
            nodes[at] = .{ .bounds = box, .first = first, .count = count };
            first += count;
        }
        // Each inner node's box, from the far end back: its leaf's and everything after it.
        var inner = leaves - 1;
        while (inner > 0) : (inner -= 1) {
            const at = (inner - 1) * 2;
            nodes[at] = .{
                .bounds = nodes[at + 1].bounds.merge(nodes[at + 2].bounds),
                .left = @intCast(at + 1),
                .right = @intCast(at + 2),
            };
        }
        for (nodes) |*node| node.bounds = node.bounds.expand(loosen);
        return .{ .nodes = nodes, .order = order };
    }

    fn deinit(self: Chain) void {
        gpa.free(self.nodes);
        gpa.free(self.order);
    }

    fn tree(self: Chain) m.Tree {
        return .{ .nodes = self.nodes, .order = self.order };
    }
};

fn expectValid(ground: Ground, tree: m.Tree) !void {
    const result = try m.validateTree(gpa, ground.positions, ground.indices, tree);
    try t.expectEqual(m.TreeValidation{ .valid = true }, result);
}

/// The tree is refused for this reason at this node, and a mesh given it is refused too.
fn expectRefused(ground: Ground, tree: m.Tree, fault: m.TreeFault, node: ?u32) !void {
    const result = try m.validateTree(gpa, ground.positions, ground.indices, tree);
    try t.expectEqual(m.TreeValidation{ .valid = false, .fault = fault, .node = node }, result);
    var w: p.World = .empty;
    defer w.deinit(gpa);
    try t.expectError(error.InvalidMesh, w.addMeshWith(gpa, ground.positions, ground.indices, .{ .tree = tree }));
    try t.expectEqual(@as(u32, 0), w.meshCount());
}

test "tree: the built tree is valid, is what a mesh builds, and is accepted back" {
    const ground = try Ground.init(12, 9);
    defer ground.deinit();
    var built = try m.buildTree(gpa, ground.positions, ground.indices);
    defer built.deinit(gpa);
    try expectValid(ground, built.tree());

    var mesh = try m.Mesh.init(gpa, ground.positions, ground.indices);
    defer mesh.deinit(gpa);
    try t.expect(!mesh.baked);
    try t.expectEqualSlices(u32, mesh.order, built.order);
    try t.expectEqual(mesh.nodes.len, built.nodes.len);
    for (mesh.nodes, built.nodes) |a, b| try t.expectEqualDeep(a, b);

    var given = try m.Mesh.initWith(gpa, ground.positions, ground.indices, .{ .tree = built.tree() });
    defer given.deinit(gpa);
    try t.expect(given.baked);
    try t.expectEqualSlices(u32, mesh.order, given.order);
    for (mesh.nodes, given.nodes) |a, b| try t.expectEqualDeep(a, b);
    // A copy: the mesh does not borrow what it was handed.
    try t.expect(given.nodes.ptr != built.nodes.ptr and given.order.ptr != built.order.ptr);
    try t.expectEqual(mesh.tree().height(), given.tree().height());

    try t.expectError(error.InvalidMesh, m.buildTree(gpa, ground.positions, ground.indices[0 .. ground.indices.len - 1]));
}

test "tree: a lopsided valid tree gives the built tree's answers" {
    const ground = try Ground.init(8, 7); // 112 triangles
    defer ground.deinit();
    // 32 leaves put the deepest at depth 31, the most the walk's stack holds. The boxes are
    // looser than they need be, which is slow and not wrong.
    const chain = try Chain.init(ground, 32, 0.25);
    defer chain.deinit();
    try expectValid(ground, chain.tree());
    try t.expectEqual(m.max_depth, chain.tree().height());

    var worlds: [2]p.World = .{ .empty, .empty };
    defer for (&worlds) |*w| w.deinit(gpa);
    const pose: p.Pose = .{ .position = .init(-4, 0.5, -3.5), .rotation = core.math.Quat.fromAxisAngle(.init(0.2, 1, 0.1), 0.6) };
    for (&worlds, [_]?m.Tree{ null, chain.tree() }) |*w, tree| {
        const mesh = try w.addMeshWith(gpa, ground.positions, ground.indices, .{ .tree = tree });
        _ = try w.addBody(gpa, .{ .shape = .{ .mesh = mesh }, .pose = pose, .scale = .init(1.5, 1, 0.75) });
    }
    try t.expectEqual(@as(u32, 0), worlds[0].report().meshes_baked);
    try t.expectEqual(@as(u32, 1), worlds[1].report().meshes_baked);

    // The whole mesh at once: every usable triangle, in index order, from both.
    var out: [2][112]u32 = undefined;
    const everything: Aabb = .{ .min = .init(-100, -100, -100), .max = .init(100, 100, 100) };
    var all: [2][]const u32 = undefined;
    for (&worlds, 0..) |*w, i| {
        var meshes = w.meshes.iterator();
        all[i] = meshes.next().?.value.candidates(pose, .init(1.5, 1, 0.75), everything, &out[i]);
    }
    try t.expectEqual(@as(usize, 112), all[0].len);
    try t.expectEqualSlices(u32, all[0], all[1]);

    const shapes = [_]p.Shape{
        .{ .sphere = .{ .radius = 0.4 } },
        .{ .capsule = .{ .radius = 0.3, .half_height = 0.6 } },
        .{ .box = .{ .half_extents = .init(0.5, 0.3, 0.7) } },
    };
    var rng = Pcg32.init(5, 38);
    var hits: usize = 0;
    for (0..400) |_| {
        const from: Vec3 = .init(rng.float01() * 16 - 8, 1 + rng.float01() * 3, rng.float01() * 10 - 5);
        const direction = Vec3.init(rng.float01() - 0.5, -rng.float01() - 0.05, rng.float01() - 0.5).normalize();
        const shape = shapes[rng.below(3)];
        const at: p.Pose = .at(.init(rng.float01() * 16 - 8, 0.4 + rng.float01(), rng.float01() * 10 - 5));
        var rays: [2]?p.RayHit = undefined;
        var casts: [2]?p.Hit = undefined;
        var contacts: [2][24]p.Contact = undefined;
        var found: [2]p.Found = undefined;
        for (&worlds, 0..) |*w, i| {
            rays[i] = try w.raycast(from, direction, 12, .{});
            casts[i] = try w.shapeCast(shape, .at(from), direction.scale(8), .{});
            found[i] = try w.contacts(shape, at, .{}, &contacts[i]);
        }
        try t.expectEqualDeep(rays[0], rays[1]);
        try t.expectEqualDeep(casts[0], casts[1]);
        try t.expectEqualDeep(found[0], found[1]);
        try t.expectEqualSlices(u8, std.mem.sliceAsBytes(contacts[0][0..found[0].count]), std.mem.sliceAsBytes(contacts[1][0..found[1].count]));
        hits += @as(usize, @intFromBool(rays[0] != null)) + @intFromBool(casts[0] != null) + found[0].count;
    }
    // The comparison is of answers, not of two worlds that both found nothing.
    try t.expect(hits > 400);
}

test "tree: one node deeper than the walk's stack holds is refused" {
    const ground = try Ground.init(8, 7);
    defer ground.deinit();
    const chain = try Chain.init(ground, 33, 0);
    defer chain.deinit();
    // The first node at depth 32 is the last inner node's left child.
    try expectRefused(ground, chain.tree(), .depth, 63);
}

test "tree: a wrong count of nodes or of triangles is refused" {
    const ground = try Ground.init(4, 4); // 32 triangles
    defer ground.deinit();
    var built = try m.buildTree(gpa, ground.positions, ground.indices);
    defer built.deinit(gpa);
    try expectRefused(ground, .{ .nodes = &.{}, .order = built.order }, .node_count, null);
    const many = try gpa.alloc(m.Node, 64);
    defer gpa.free(many);
    @memset(many, built.nodes[0]);
    try expectRefused(ground, .{ .nodes = many, .order = built.order }, .node_count, null);
    try expectRefused(ground, .{ .nodes = built.nodes, .order = built.order[0..31] }, .order_length, null);
    try expectRefused(ground, .{ .nodes = built.nodes, .order = &.{} }, .order_length, null);

    // And triangles that are not a mesh at all name no node.
    const result = try m.validateTree(gpa, ground.positions, ground.indices[0..95], built.tree());
    try t.expectEqual(m.TreeValidation{ .valid = false, .fault = .mesh }, result);
}

test "tree: a child out of range, a node named twice and nodes left over are refused" {
    const ground = try Ground.init(4, 4);
    defer ground.deinit();
    var built = try m.buildTree(gpa, ground.positions, ground.indices);
    defer built.deinit(gpa);
    const nodes = built.nodes;
    const root = nodes[0];
    try t.expect(root.count == 0 and nodes[1].count == 0);

    nodes[0].right = @intCast(nodes.len);
    try expectRefused(ground, built.tree(), .child, 0);
    nodes[0].right = root.left;
    try expectRefused(ground, built.tree(), .child, 0);
    nodes[0].right = 0;
    try expectRefused(ground, built.tree(), .child, 0);
    nodes[0] = root;

    // The left child is not the next node.
    nodes[0].left = 2;
    try expectRefused(ground, built.tree(), .preorder, 0);
    nodes[0] = root;

    // The root and its left child name the same right child, so the walk would visit it twice.
    // The walk reaches it once, for the inner node, and is refused when the root is still owed it.
    nodes[0].right = nodes[1].right;
    try expectRefused(ground, built.tree(), .preorder, nodes[1].right);
    nodes[0] = root;

    // A right child one too far skips a node, which the walk then meets with nothing owed.
    const inner = nodes[1];
    nodes[1].right += 1;
    const skipped = try m.validateTree(gpa, ground.positions, ground.indices, built.tree());
    try t.expectEqual(@as(?m.TreeFault, .preorder), skipped.fault);
    nodes[1] = inner;
    try expectValid(ground, built.tree());

    // Two leaves and no parent: the second is never reached.
    const pair = try Ground.init(1, 1);
    defer pair.deinit();
    const box = pair.boxOf(0).merge(pair.boxOf(1));
    const loose = [_]m.Node{ .{ .bounds = box, .first = 0, .count = 2 }, .{ .bounds = box, .first = 0, .count = 2 } };
    try expectRefused(pair, .{ .nodes = &loose, .order = &.{ 0, 1 } }, .preorder, 1);
    try expectValid(pair, .{ .nodes = loose[0..1], .order = &.{ 1, 0 } });
}

test "tree: a leaf of five, a leaf of none and a run out of place are refused" {
    const ground = try Ground.init(8, 7);
    defer ground.deinit();
    const chain = try Chain.init(ground, 30, 0);
    defer chain.deinit();
    try expectValid(ground, chain.tree());
    const nodes = chain.nodes;
    // Node 1 is the first leaf and node 3 the second.
    const first = nodes[1];
    const second = nodes[3];
    try t.expect(first.count == 4 and second.count == 4);

    nodes[1].count = 5;
    try expectRefused(ground, chain.tree(), .leaf_size, 1);
    // A count of zero is how an inner node is told from a leaf, so this is an inner node whose
    // left child is not the next one.
    nodes[1].count = 0;
    try expectRefused(ground, chain.tree(), .preorder, 1);
    nodes[1] = first;

    // The first two leaves trade runs: each still holds four triangles its box contains.
    nodes[1].first = second.first;
    nodes[3].first = first.first;
    try expectRefused(ground, chain.tree(), .run, 1);
    nodes[1] = first;
    nodes[3] = second;

    // A leaf that takes one fewer leaves the next run starting late.
    nodes[1].count = 3;
    try expectRefused(ground, chain.tree(), .run, 3);
    nodes[1] = first;

    // The last leaf takes one fewer, and a triangle is in no leaf.
    const last = nodes.len - 1;
    nodes[last].count -= 1;
    try expectRefused(ground, chain.tree(), .run, @intCast(last));
    // Or one more than there are.
    nodes[last].count += 2;
    try expectRefused(ground, chain.tree(), .run, @intCast(last));
    nodes[last].count -= 1;
    try expectValid(ground, chain.tree());
}

test "tree: a triangle named twice or not in the mesh is refused" {
    const ground = try Ground.init(8, 7);
    defer ground.deinit();
    // Boxes loose enough that any triangle is inside any leaf's, so only the order is wrong.
    const chain = try Chain.init(ground, 30, 50);
    defer chain.deinit();
    try expectValid(ground, chain.tree());
    const order = chain.order;

    const kept = order[1];
    order[1] = order[0];
    try expectRefused(ground, chain.tree(), .repeated, 1);
    // The same triangle in two leaves, the second of which is where it is found.
    order[1] = kept;
    const far = order[9];
    order[9] = order[0];
    try expectRefused(ground, chain.tree(), .repeated, 5);
    order[9] = far;

    order[0] = 112;
    try expectRefused(ground, chain.tree(), .triangle, 1);
    order[0] = 0xFFFF_FFFF;
    try expectRefused(ground, chain.tree(), .triangle, 1);
}

test "tree: a box that misses what is under it is refused" {
    const ground = try Ground.init(8, 7);
    defer ground.deinit();
    const chain = try Chain.init(ground, 30, 0);
    defer chain.deinit();
    const nodes = chain.nodes;

    // A leaf's box drawn in by a hair on one side misses a triangle, and is still in its parent's.
    for ([_]usize{ 1, 7, nodes.len - 1 }) |leaf| {
        const whole = nodes[leaf];
        nodes[leaf].bounds.max.x = std.math.nextAfter(f32, whole.bounds.max.x, -1000);
        try expectRefused(ground, chain.tree(), .leaf_bounds, @intCast(leaf));
        nodes[leaf] = whole;
        nodes[leaf].bounds.min.y = std.math.nextAfter(f32, whole.bounds.min.y, 1000);
        try expectRefused(ground, chain.tree(), .leaf_bounds, @intCast(leaf));
        nodes[leaf] = whole;
    }

    // An inner node's box drawn in misses a child. The child is the node named: the left one
    // when both stick out.
    const inner = nodes[4];
    nodes[4].bounds.min.z = std.math.nextAfter(f32, nodes[6].bounds.min.z, 1000);
    const missed = try m.validateTree(gpa, ground.positions, ground.indices, chain.tree());
    try t.expectEqual(@as(?m.TreeFault, .parent_bounds), missed.fault);
    try t.expect(missed.node.? == 5 or missed.node.? == 6);
    nodes[4] = inner;

    // A right child's box alone, grown past its parent's: found when the walk comes back to it.
    const right = nodes[6];
    nodes[6].bounds = right.bounds.expand(100);
    try expectRefused(ground, chain.tree(), .parent_bounds, 6);
    nodes[6] = right;

    // A box with a NaN in it contains nothing, and one that is infinite contains everything.
    const leaf = nodes[1];
    nodes[1].bounds.max.y = std.math.nan(f32);
    try expectRefused(ground, chain.tree(), .parent_bounds, 1);
    nodes[1] = leaf;
    nodes[0].bounds.min.x = std.math.nan(f32);
    try expectRefused(ground, chain.tree(), .parent_bounds, 1);
    const infinite: Aabb = .{ .min = Vec3.init(1, 1, 1).scale(-std.math.inf(f32)), .max = Vec3.init(1, 1, 1).scale(std.math.inf(f32)) };
    nodes[0].bounds = infinite;
    try expectValid(ground, chain.tree());
}

test "tree: a mesh given a tree frees what it took when memory runs out" {
    const ground = try Ground.init(4, 4);
    defer ground.deinit();
    var built = try m.buildTree(gpa, ground.positions, ground.indices);
    defer built.deinit(gpa);
    const Try = struct {
        fn given(allocator: std.mem.Allocator, g: Ground, tree: ?m.Tree) !void {
            var mesh = try m.Mesh.initWith(allocator, g.positions, g.indices, .{ .tree = tree });
            mesh.deinit(allocator);
        }
        fn build(allocator: std.mem.Allocator, g: Ground) !void {
            var tree = try m.buildTree(allocator, g.positions, g.indices);
            tree.deinit(allocator);
        }
    };
    try t.checkAllAllocationFailures(gpa, Try.given, .{ ground, @as(?m.Tree, built.tree()) });
    try t.checkAllAllocationFailures(gpa, Try.given, .{ ground, @as(?m.Tree, null) });
    try t.checkAllAllocationFailures(gpa, Try.build, .{ground});
}
