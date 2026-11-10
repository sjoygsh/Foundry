//! A bounding-volume tree over the world's bodies (`collision-scale.md` §4, ADR-0077).
//!
//! **It finds candidates and never decides an answer.** A query walks the tree with its area and
//! is given the bodies whose boxes overlap it, sorted by body index. The world then tests each as
//! a scan in handle order would have, so no answer and no tie depends on the tree's shape.
//!
//! A leaf is a body, with a box at least as large as its bounds. An inner node holds the box
//! around its two children. A leaf is inserted beside the sibling that grows the tree's surface
//! least, the left child on a tie, and rotations on the way back up keep the two sides of every
//! node within one level of each other where they can.
//!
//! **Nothing here allocates but `reserve`.** A world reserves when it adds a body, so moving and
//! removing a body, and every query, allocate nothing.

const std = @import("std");
const core = @import("core");
const shape = @import("shape.zig");

const Aabb = shape.Aabb;
const Allocator = std.mem.Allocator;

/// No node: a root's parent, an empty tree's root, the end of the free list.
pub const none: u32 = std.math.maxInt(u32);
/// How far past its bounds a kinematic body's box reaches, metres, so that a small move leaves
/// it inside its box. An interface constant: a caller can observe it in `Report.refits`.
pub const margin: f32 = 0.1;
/// The query's stack. A walk that would pass it reports that it could not finish, and the world
/// scans instead, so a tree of any shape loses no body.
pub const stack_capacity: usize = 64;

const Node = struct {
    box: Aabb,
    /// The parent, or the next free node while this one is free.
    parent: u32 = none,
    left: u32 = none,
    right: u32 = none,
    /// 0 for a leaf, -1 while free.
    height: i32 = 0,
    /// A leaf's body index.
    body: u32 = none,

    fn isLeaf(self: Node) bool {
        return self.left == none;
    }
};

pub const Tree = struct {
    nodes: std.ArrayList(Node) = .empty,
    root: u32 = none,
    free: u32 = none,
    leaves: u32 = 0,

    pub fn deinit(self: *Tree, gpa: Allocator) void {
        self.nodes.deinit(gpa);
        self.* = .{};
    }

    /// Room for `bodies` leaves and the inner nodes above them.
    pub fn reserve(self: *Tree, gpa: Allocator, bodies: usize) Allocator.Error!void {
        try self.nodes.ensureTotalCapacity(gpa, bodies * 2);
    }

    /// A new leaf for `body`. The tree must have been reserved for it.
    pub fn insert(self: *Tree, body: u32, box: Aabb) u32 {
        const leaf = self.allocate();
        self.nodes.items[leaf] = .{ .box = box, .body = body };
        self.link(leaf);
        self.leaves += 1;
        return leaf;
    }

    pub fn remove(self: *Tree, leaf: u32) void {
        self.unlink(leaf);
        self.release(leaf);
        self.leaves -= 1;
    }

    /// Gives a leaf a new box and a new place. The node it frees is the node it takes.
    pub fn update(self: *Tree, leaf: u32, box: Aabb) void {
        self.unlink(leaf);
        self.nodes.items[leaf].box = box;
        self.link(leaf);
    }

    pub fn boxOf(self: *const Tree, leaf: u32) Aabb {
        return self.nodes.items[leaf].box;
    }

    /// Nodes in use: none for an empty tree, otherwise two a leaf less one.
    pub fn nodeCount(self: *const Tree) u32 {
        return if (self.leaves == 0) 0 else self.leaves * 2 - 1;
    }

    /// Levels below the root: 0 for an empty tree or a single leaf.
    pub fn height(self: *const Tree) u32 {
        return if (self.root == none) 0 else @intCast(self.nodes.items[self.root].height);
    }

    /// The bodies whose boxes overlap `area`, ascending, into `out`, which must hold every leaf.
    /// `visited` counts the nodes walked. Null when the walk would pass its stack.
    pub fn query(self: *const Tree, area: Aabb, out: []u32, visited: *u32) ?usize {
        if (self.root == none) return 0;
        const nodes = self.nodes.items;
        var stack: [stack_capacity]u32 = undefined;
        stack[0] = self.root;
        var pending: usize = 1;
        var count: usize = 0;
        while (pending > 0) {
            pending -= 1;
            const node = nodes[stack[pending]];
            visited.* +%= 1;
            if (!node.box.overlaps(area)) continue;
            if (node.isLeaf()) {
                out[count] = node.body;
                count += 1;
            } else {
                if (pending + 2 > stack_capacity) return null;
                stack[pending] = node.right;
                stack[pending + 1] = node.left;
                pending += 2;
            }
        }
        std.sort.heap(u32, out[0..count], {}, std.sort.asc(u32));
        return count;
    }

    // -- internals -------------------------------------------------------------------

    fn allocate(self: *Tree) u32 {
        if (self.free != none) {
            const index = self.free;
            self.free = self.nodes.items[index].parent;
            return index;
        }
        self.nodes.appendAssumeCapacity(undefined);
        return @intCast(self.nodes.items.len - 1);
    }

    fn release(self: *Tree, index: u32) void {
        self.nodes.items[index] = .{ .box = .around(.zero), .parent = self.free, .height = -1 };
        self.free = index;
    }

    /// Half a box's surface. Only compared, never reported.
    fn surface(box: Aabb) f32 {
        const d = box.max.sub(box.min);
        return d.x * d.y + d.y * d.z + d.z * d.x;
    }

    fn link(self: *Tree, leaf: u32) void {
        var nodes = self.nodes.items;
        nodes[leaf].parent = none;
        nodes[leaf].left = none;
        nodes[leaf].right = none;
        nodes[leaf].height = 0;
        if (self.root == none) {
            self.root = leaf;
            return;
        }
        const box = nodes[leaf].box;
        // Down to the sibling that costs least: making a new parent here, against pushing the
        // leaf into one child or the other.
        var index = self.root;
        while (!nodes[index].isLeaf()) {
            const combined = surface(nodes[index].box.merge(box));
            const here = 2 * combined;
            const inherited = 2 * (combined - surface(nodes[index].box));
            const left = self.descentCost(nodes[index].left, box) + inherited;
            const right = self.descentCost(nodes[index].right, box) + inherited;
            if (here < left and here < right) break;
            index = if (left <= right) nodes[index].left else nodes[index].right;
        }
        const sibling = index;
        const old_parent = nodes[sibling].parent;
        const parent = self.allocate();
        // A node taken past the end lengthens the list, within its reserved capacity.
        nodes = self.nodes.items;
        nodes[parent] = .{
            .box = box.merge(nodes[sibling].box),
            .parent = old_parent,
            .left = sibling,
            .right = leaf,
            .height = nodes[sibling].height + 1,
        };
        if (old_parent == none) {
            self.root = parent;
        } else if (nodes[old_parent].left == sibling) {
            nodes[old_parent].left = parent;
        } else {
            nodes[old_parent].right = parent;
        }
        nodes[sibling].parent = parent;
        nodes[leaf].parent = parent;
        self.repair(parent);
    }

    fn descentCost(self: *const Tree, child: u32, box: Aabb) f32 {
        const node = self.nodes.items[child];
        const merged = surface(node.box.merge(box));
        return if (node.isLeaf()) merged else merged - surface(node.box);
    }

    fn unlink(self: *Tree, leaf: u32) void {
        const nodes = self.nodes.items;
        if (leaf == self.root) {
            self.root = none;
            return;
        }
        const parent = nodes[leaf].parent;
        const grand = nodes[parent].parent;
        const sibling = if (nodes[parent].left == leaf) nodes[parent].right else nodes[parent].left;
        nodes[sibling].parent = grand;
        if (grand == none) {
            self.root = sibling;
        } else if (nodes[grand].left == parent) {
            nodes[grand].left = sibling;
        } else {
            nodes[grand].right = sibling;
        }
        self.release(parent);
        self.repair(grand);
    }

    /// From `start` to the root: balance, then the height and box each node's children give it.
    fn repair(self: *Tree, start: u32) void {
        const nodes = self.nodes.items;
        var index = start;
        while (index != none) {
            index = self.balance(index);
            const l = nodes[nodes[index].left];
            const r = nodes[nodes[index].right];
            nodes[index].height = 1 + @max(l.height, r.height);
            nodes[index].box = l.box.merge(r.box);
            index = nodes[index].parent;
        }
    }

    /// Rotates `a`'s taller child above it when its two sides differ by more than a level.
    /// Returns the node now where `a` was.
    fn balance(self: *Tree, a: u32) u32 {
        const nodes = self.nodes.items;
        if (nodes[a].isLeaf() or nodes[a].height < 2) return a;
        const b = nodes[a].left;
        const c = nodes[a].right;
        const lean = nodes[c].height - nodes[b].height;
        if (lean > 1) return self.rotate(a, c, b, .right);
        if (lean < -1) return self.rotate(a, b, c, .left);
        return a;
    }

    /// `up`, `a`'s child on `side`, takes `a`'s place and `a` becomes its left child. `up`'s
    /// taller child stays with it, and its other child takes `up`'s old place under `a`,
    /// beside `other`.
    fn rotate(self: *Tree, a: u32, up: u32, other: u32, side: enum { left, right }) u32 {
        const nodes = self.nodes.items;
        const f = nodes[up].left;
        const g = nodes[up].right;
        const above = nodes[a].parent;
        nodes[up].left = a;
        nodes[up].parent = above;
        nodes[a].parent = up;
        if (above == none) {
            self.root = up;
        } else if (nodes[above].left == a) {
            nodes[above].left = up;
        } else {
            nodes[above].right = up;
        }
        const keep = if (nodes[f].height > nodes[g].height) f else g;
        const give = if (keep == f) g else f;
        nodes[up].right = keep;
        switch (side) {
            .left => nodes[a].left = give,
            .right => nodes[a].right = give,
        }
        nodes[give].parent = a;
        nodes[a].box = nodes[other].box.merge(nodes[give].box);
        nodes[up].box = nodes[a].box.merge(nodes[keep].box);
        nodes[a].height = 1 + @max(nodes[other].height, nodes[give].height);
        nodes[up].height = 1 + @max(nodes[a].height, nodes[keep].height);
        return up;
    }

    /// Whether the tree is one: every link agrees with its parent's, every inner box holds its
    /// children's, every height is its children's plus one, and the leaves are `leaves`. For tests.
    pub fn consistent(self: *const Tree) bool {
        if (self.root == none) return self.leaves == 0;
        if (self.nodes.items[self.root].parent != none) return false;
        var found: u32 = 0;
        return self.check(self.root, &found) and found == self.leaves;
    }

    fn check(self: *const Tree, index: u32, found: *u32) bool {
        const node = self.nodes.items[index];
        if (node.isLeaf()) {
            found.* += 1;
            return node.right == none and node.height == 0 and node.body != none;
        }
        const l = self.nodes.items[node.left];
        const r = self.nodes.items[node.right];
        if (l.parent != index or r.parent != index) return false;
        if (node.height != 1 + @max(l.height, r.height)) return false;
        const both = l.box.merge(r.box);
        if (!both.min.eql(node.box.min) or !both.max.eql(node.box.max)) return false;
        return self.check(node.left, found) and self.check(node.right, found);
    }
};

// -- tests -----------------------------------------------------------------------------

const testing = std.testing;
const Vec3 = core.math.Vec3;

fn cube(x: f32, y: f32, z: f32) Aabb {
    return .{ .min = .init(x, y, z), .max = .init(x + 1, y + 1, z + 1) };
}

test "an empty tree answers nothing, and one leaf is its own root" {
    var tree: Tree = .{};
    defer tree.deinit(testing.allocator);
    var out: [4]u32 = undefined;
    var visited: u32 = 0;
    try testing.expectEqual(@as(?usize, 0), tree.query(cube(0, 0, 0), &out, &visited));
    try testing.expectEqual(@as(u32, 0), tree.nodeCount() + tree.height());
    try tree.reserve(testing.allocator, 1);
    const leaf = tree.insert(7, cube(0, 0, 0));
    try testing.expect(tree.consistent());
    try testing.expectEqual(@as(?usize, 1), tree.query(cube(0.5, 0.5, 0.5), &out, &visited));
    try testing.expectEqual(@as(u32, 7), out[0]);
    try testing.expectEqual(@as(?usize, 0), tree.query(cube(5, 5, 5), &out, &visited));
    tree.remove(leaf);
    try testing.expect(tree.consistent() and tree.root == none);
}

test "bodies come back ascending, whatever order they went in" {
    var tree: Tree = .{};
    defer tree.deinit(testing.allocator);
    try tree.reserve(testing.allocator, 64);
    // Inserted from the highest index down, all in one row.
    var i: u32 = 64;
    while (i > 0) {
        i -= 1;
        _ = tree.insert(i, cube(@floatFromInt(i * 2), 0, 0));
    }
    var out: [64]u32 = undefined;
    var visited: u32 = 0;
    const n = tree.query(.{ .min = .init(9.5, 0, 0), .max = .init(40.5, 1, 1) }, &out, &visited).?;
    try testing.expectEqual(@as(usize, 16), n);
    for (out[0..n], 0..) |body, k| try testing.expectEqual(@as(u32, @intCast(5 + k)), body);
    // Fewer nodes were walked than a scan would have visited bodies.
    try testing.expect(visited < 64);
}

test "4,096 inserts in sorted order stay balanced" {
    var tree: Tree = .{};
    defer tree.deinit(testing.allocator);
    try tree.reserve(testing.allocator, 4096);
    for (0..4096) |i| _ = tree.insert(@intCast(i), cube(@floatFromInt(i * 2), 0, 0));
    try testing.expect(tree.consistent());
    try testing.expectEqual(@as(u32, 8191), tree.nodeCount());
    // 1.45·log2(4096) + 2.
    try testing.expect(tree.height() <= 19);
}

test "moving and removing leaves keeps the tree whole and reuses its nodes" {
    var tree: Tree = .{};
    defer tree.deinit(testing.allocator);
    try tree.reserve(testing.allocator, 256);
    var rng = core.rng.Pcg32.init(38, 2);
    var leaves: [256]u32 = undefined;
    var boxes: [256]Aabb = undefined;
    for (&leaves, &boxes, 0..) |*leaf, *box, i| {
        box.* = cube(rng.float01() * 40, rng.float01() * 4, rng.float01() * 40);
        leaf.* = tree.insert(@intCast(i), box.*);
    }
    const capacity = tree.nodes.capacity;
    for (0..2000) |_| {
        const i = rng.below(256);
        boxes[i] = cube(rng.float01() * 40, rng.float01() * 4, rng.float01() * 40);
        tree.update(leaves[i], boxes[i]);
    }
    try testing.expect(tree.consistent());
    try testing.expectEqual(capacity, tree.nodes.capacity);
    try testing.expect(tree.nodes.items.len <= 511);
    try testing.expect(tree.height() <= 14);
    // Every query finds exactly the boxes a pass over all of them finds.
    var out: [256]u32 = undefined;
    for (0..200) |_| {
        const area = cube(rng.float01() * 40, rng.float01() * 4, rng.float01() * 40).expand(rng.float01() * 3);
        var visited: u32 = 0;
        const n = tree.query(area, &out, &visited).?;
        var k: usize = 0;
        for (boxes, 0..) |box, i| {
            if (!box.overlaps(area)) continue;
            try testing.expectEqual(@as(u32, @intCast(i)), out[k]);
            k += 1;
        }
        try testing.expectEqual(n, k);
    }
    for (leaves[0..255]) |leaf| tree.remove(leaf);
    try testing.expect(tree.consistent() and tree.height() == 0 and tree.nodeCount() == 1);
    tree.remove(leaves[255]);
    try testing.expect(tree.root == none and tree.leaves == 0);
}

test "a walk that would pass its stack says so" {
    // A chain made by hand, deeper than any balanced tree: each inner node's left is a leaf and
    // its right the next inner node, every box the same.
    var tree: Tree = .{};
    defer tree.deinit(testing.allocator);
    const depth = stack_capacity + 8;
    try tree.reserve(testing.allocator, depth + 1);
    const box = cube(0, 0, 0);
    for (0..depth) |i| {
        const inner: u32 = @intCast(i * 2);
        tree.nodes.appendAssumeCapacity(.{ .box = box, .left = inner + 1, .right = inner + 2, .height = @intCast(depth - i) });
        tree.nodes.appendAssumeCapacity(.{ .box = box, .body = @intCast(i) });
    }
    tree.nodes.appendAssumeCapacity(.{ .box = box, .body = @intCast(depth) });
    tree.root = 0;
    tree.leaves = @intCast(depth + 1);
    var out: [stack_capacity + 9]u32 = undefined;
    var visited: u32 = 0;
    // Right is pushed under left, so a chain to the right never deepens the stack.
    try testing.expectEqual(@as(?usize, depth + 1), tree.query(box, &out, &visited));
    // The same chain to the left does.
    for (0..depth) |i| std.mem.swap(u32, &tree.nodes.items[i * 2].left, &tree.nodes.items[i * 2].right);
    try testing.expectEqual(@as(?usize, null), tree.query(box, &out, &visited));
}
