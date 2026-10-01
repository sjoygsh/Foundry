//! glTF-only skeleton closure, remapping and clip translation (animation3d.md §7).
//! All returned storage is owned by the caller's bounded import arena. No anim dependency.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const document = @import("document.zig");
const accessor = @import("accessor.zig");
const Allocator = std.mem.Allocator;
const Mat4 = core.math.Mat4;
const Transform = core.math.Transform;
const none: u32 = std.math.maxInt(u32);
pub const Error = error{ContentInvalid} || Allocator.Error;
pub const Clip = struct { name: []const u8, source: asset.animation.Source };
pub const Rig = struct {
    skeleton: asset.skeleton.Source,
    clips: []const Clip,
    /// glTF skin joint ordinal -> closed skeleton index.
    remap: []const u8,
    mesh_skinned: []const bool,
    bind_matrices: []const Mat4,
};

pub const Context = struct {
    gpa: Allocator,
    arena: Allocator,
    doc: *const document.Document,
    buffers: []const []const u8,
    source: []const u8,
    diags: *data.Diagnostics,
    limits: document.Limits,

    pub fn prepare(self: Context, front: Mat4) Error!?Rig {
        // Leave the historical static importer untouched, including its output bytes.
        var needs_rig = self.doc.skins.len != 0 or self.doc.animations.len != 0;
        for (self.doc.nodes) |node| if (node.skin != null) {
            needs_rig = true;
        };
        if (!needs_rig) return null;
        const scene_index = self.doc.scene orelse @as(u32, 0);
        if (scene_index >= self.doc.scenes.len) return self.fail("scene", "has no valid default scene; export a scene", .{});
        const n = self.doc.nodes.len;
        const parents = try self.arena.alloc(u32, n);
        const worlds = try self.arena.alloc(Mat4, n);
        const visited = try self.arena.alloc(bool, n);
        @memset(parents, none);
        @memset(visited, false);
        const Entry = struct { node: u32, parent: u32, world: Mat4, depth: u32 };
        var stack: std.ArrayList(Entry) = .empty;
        const roots = self.doc.scenes[scene_index].nodes;
        var i = roots.len;
        while (i > 0) {
            i -= 1;
            try stack.append(self.arena, .{ .node = roots[i], .parent = none, .world = .identity, .depth = 1 });
        }
        var used_skin: ?u32 = null;
        const mesh_modes = try self.arena.alloc(u8, self.doc.meshes.len);
        @memset(mesh_modes, 0);
        while (stack.pop()) |e| {
            const path = try std.fmt.allocPrint(self.arena, "nodes[{d}]", .{e.node});
            if (e.node >= n) return self.fail(path, "is outside the node array; repair the hierarchy", .{});
            if (e.depth > self.limits.max_node_depth) return self.fail(path, "is deeper than the node-depth limit; flatten the hierarchy", .{});
            if (visited[e.node]) return self.fail(path, "is reached twice (a cycle or a second parent); export a tree", .{});
            visited[e.node] = true;
            parents[e.node] = e.parent;
            const node = self.doc.nodes[e.node];
            const local = try self.localMatrix(e.node);
            worlds[e.node] = Mat4.mul(e.world, local);
            if (node.skin) |s| {
                if (node.mesh == null or s >= self.doc.skins.len) return self.fail(path, "has no mesh or references a missing skin; repair the skin instance", .{});
                if (used_skin) |old| {
                    if (old != s) return self.fail(path, "uses more than one skin per model; export separate models", .{});
                }
                used_skin = s;
            }
            if (node.mesh) |m| {
                if (m >= mesh_modes.len) return self.fail(path, "references a missing mesh; repair the mesh instance", .{});
                mesh_modes[m] |= if (node.skin != null) @as(u8, 2) else @as(u8, 1);
                if (mesh_modes[m] == 3) return self.fail(path, "uses a mesh both rigidly and skinned; duplicate that mesh on export", .{});
            }
            i = node.children.len;
            while (i > 0) {
                i -= 1;
                try stack.append(self.arena, .{ .node = node.children[i], .parent = e.node, .world = worlds[e.node], .depth = e.depth + 1 });
            }
        }
        const s = used_skin orelse {
            if (self.doc.skins.len != 0) try self.warn("skins", "unused skins are not imported", .{});
            for (self.doc.animations, 0..) |a, ai| {
                for (a.channels, 0..) |_, ci| try self.warn(try std.fmt.allocPrint(self.arena, "animations[{d}].channels[{d}]", .{ ai, ci }), "targets no imported skeleton; channel dropped", .{});
            }
            return null;
        };
        const skin = self.doc.skins[s];
        const skin_path = try std.fmt.allocPrint(self.arena, "skins[{d}] ('{s}')", .{ s, skin.name orelse "" });
        if (skin.joints.len == 0 or skin.joints.len > 256) return self.fail(skin_path, "must have 1–256 joints; reduce the rig", .{});
        const original = try self.arena.alloc(bool, n);
        @memset(original, false);
        for (skin.joints) |j| {
            if (j >= n or !visited[j]) return self.fail(skin_path, "joint {d} is missing from the default scene; export the rig in that scene", .{j});
            if (original[j]) return self.fail(skin_path, "repeats joint {d}; remove the duplicate", .{j});
            original[j] = true;
        }
        // Closest common ancestor, not an invented connection across scene roots.
        var root = skin.joints[0];
        while (true) {
            var common = true;
            for (skin.joints) |j| if (!isAncestor(parents, root, j)) {
                common = false;
                break;
            };
            if (common) break;
            root = parents[root];
            if (root == none) return self.fail(skin_path, "joints do not form one tree; export one connected skeleton", .{});
        }
        if (skin.skeleton) |pivot| {
            if (pivot >= n or !visited[pivot] or !isAncestor(parents, pivot, root)) return self.fail(skin_path, "skeleton is not an ancestor of every joint; repair the skeleton root", .{});
        }
        const included = try self.arena.alloc(bool, n);
        @memset(included, false);
        for (skin.joints) |j| {
            var at = j;
            while (true) {
                included[at] = true;
                if (at == root) break;
                at = parents[at];
            }
        }
        const ordered = try self.arena.alloc(u32, 256);
        const mapping = try self.arena.alloc(u16, n);
        @memset(mapping, asset.skeleton.no_parent);
        var count: usize = 0;
        // Depth first, siblings in the file's children order, not skin joint order.
        var pending: std.ArrayList(u32) = .empty;
        try pending.append(self.arena, root);
        while (pending.pop()) |node| {
            if (count == 256) return self.fail(skin_path, "exceeds 256 joints after hierarchy closure; simplify the rig", .{});
            ordered[count] = node;
            mapping[node] = @intCast(count);
            count += 1;
            const children = self.doc.nodes[node].children;
            i = children.len;
            while (i > 0) {
                i -= 1;
                if (included[children[i]]) try pending.append(self.arena, children[i]);
            }
        }
        const out_parents = try self.arena.alloc(u16, count);
        const rest = try self.arena.alloc(Transform, count);
        const inverse_bind = try self.arena.alloc(Mat4, count);
        const names = try self.arena.alloc([]const u8, count);
        const bind_matrices = try self.arena.alloc(Mat4, count);
        for (ordered[0..count], 0..) |node, j| {
            out_parents[j] = if (node == root) asset.skeleton.no_parent else mapping[parents[node]];
            // Only skeleton locals need exact TRS; static flattened parts retain the old rule.
            rest[j] = Transform.fromMat4Exact(try self.localMatrix(node)) catch return self.fail(skin_path, "joint nodes[{d}] is not valid TRS; apply transforms on export", .{node});
            inverse_bind[j] = .identity;
            names[j] = self.doc.nodes[node].name orelse "";
        }
        const remap = try self.arena.alloc(u8, skin.joints.len);
        var binds: ?accessor.View = null;
        if (skin.inverseBindMatrices) |a| {
            const v = try self.open(skin_path, a);
            if (v.component != .f32 or v.shape != .mat4 or v.normalized or v.count < skin.joints.len) return self.fail(skin_path, "inverseBindMatrices must be FLOAT MAT4 with at least one per joint; repair the bind accessor", .{});
            binds = v;
        }
        for (skin.joints, 0..) |node, j| {
            remap[j] = @intCast(mapping[node]);
            if (binds) |v| {
                var m: Mat4 = undefined;
                for (0..4) |c| for (0..4) |r| {
                    m.cols[c][r] = try self.float(skin_path, v, @intCast(j), @intCast(c * 4 + r));
                };
                if (!affine(m) or m.inverse() == null) return self.fail(skin_path, "inverse bind for joint {d} is non-finite, non-affine or non-invertible; repair bind matrices", .{j});
                inverse_bind[remap[j]] = m;
            }
        }
        const root_matrix = Mat4.mul(front, if (parents[root] == none) Mat4.identity else worlds[parents[root]]);
        for (ordered[0..count], 0..) |node, j| bind_matrices[j] = Mat4.mul(Mat4.mul(front, worlds[node]), inverse_bind[j]);
        const skinned = try self.arena.alloc(bool, mesh_modes.len);
        for (skinned, mesh_modes) |*to, mode| to.* = mode == 2;
        const clips = try self.importClips(mapping, parents, root, count);
        const skeleton: asset.skeleton.Source = .{ .parents = out_parents, .rest = rest, .inverse_bind = inverse_bind, .root = root_matrix, .names = names };
        return .{ .skeleton = skeleton, .clips = clips, .remap = remap, .mesh_skinned = skinned, .bind_matrices = bind_matrices };
    }

    fn importClips(self: Context, mapping: []const u16, parents: []const u32, root: u32, joint_count: usize) Error![]const Clip {
        const clips = try self.arena.alloc(Clip, self.doc.animations.len);
        var import_keys: usize = 0;
        for (self.doc.animations, 0..) |a, ai| {
            const path = try std.fmt.allocPrint(self.arena, "animations[{d}] ('{s}')", .{ ai, a.name orelse "" });
            const name = a.name orelse return self.fail(path, "is unnamed; give each animation a unique name", .{});
            if (name.len == 0) return self.fail(path, "is unnamed; give each animation a unique name", .{});
            for (clips[0..ai]) |old| if (std.mem.eql(u8, old.name, name)) return self.fail(path, "has a duplicate name; rename the animation", .{});
            var tracks: std.ArrayList(asset.animation.Track) = .empty;
            var duration: f32 = 0;
            var total_keys: usize = 0;
            // Validate every sampler, even one whose channels are dropped.
            for (a.samplers, 0..) |sampler, si| {
                const sp = try std.fmt.allocPrint(self.arena, "{s}.samplers[{d}]", .{ path, si });
                if (std.mem.eql(u8, sampler.interpolation, "CUBICSPLINE")) return self.fail(sp, "uses CUBICSPLINE; bake to linear keys on export", .{});
                if (!std.mem.eql(u8, sampler.interpolation, "LINEAR") and !std.mem.eql(u8, sampler.interpolation, "STEP")) return self.fail(sp, "uses unsupported interpolation; export STEP or LINEAR", .{});
                const times = try self.open(sp, sampler.input);
                if (times.component != .f32 or times.shape != .scalar or times.normalized or times.count == 0 or times.count > 65_536) return self.fail(sp, "input must be a nonempty FLOAT SCALAR with at most 65536 keys; repair key times", .{});
                var previous: f32 = -1;
                for (0..times.count) |k| {
                    const t = try self.float(sp, times, @intCast(k), 0);
                    if (!std.math.isFinite(t) or t < 0 or t <= previous) return self.fail(sp, "key times are unsorted, negative or non-finite; export increasing finite times", .{});
                    previous = t;
                }
                duration = @max(duration, previous);
            }
            for (a.channels, 0..) |channel, ci| {
                const cp = try std.fmt.allocPrint(self.arena, "{s}.channels[{d}]", .{ path, ci });
                if (channel.sampler >= a.samplers.len) return self.fail(cp, "references a missing sampler; repair the channel", .{});
                const node = channel.target.node;
                if (node) |target| if (target >= mapping.len) return self.fail(cp, "references a missing target node; repair the channel", .{});
                if (std.mem.eql(u8, channel.target.path, "weights")) {
                    try self.warn(cp, "morph weights channel dropped; export skeletal animation instead", .{});
                    continue;
                }
                const target_path: asset.animation.Path = if (std.mem.eql(u8, channel.target.path, "translation")) .translation else if (std.mem.eql(u8, channel.target.path, "rotation")) .rotation else if (std.mem.eql(u8, channel.target.path, "scale")) .scale else return self.fail(cp, "has an unsupported target path; export TRS channels", .{});
                if (node == null or mapping[node.?] == asset.skeleton.no_parent) {
                    if (node != null and isAncestor(parents, node.?, root)) try self.warn(cp, "animates a non-joint above the root; treated as static, channel dropped", .{}) else try self.warn(cp, "targets a node outside the skeleton; channel dropped", .{});
                    continue;
                }
                const j = mapping[node.?];
                for (tracks.items) |old| if (old.joint == j and old.path == target_path) return self.fail(cp, "duplicates a joint/path track; merge the channels", .{});
                if (tracks.items.len == 768) return self.fail(cp, "exceeds 768 tracks; reduce the clip", .{});
                const sampler = a.samplers[channel.sampler];
                const input = try self.open(cp, sampler.input);
                const output = try self.open(cp, sampler.output);
                const shape: accessor.Shape = if (target_path == .rotation) .vec4 else .vec3;
                if (output.component != .f32 or output.shape != shape or output.normalized or output.count != input.count) return self.fail(cp, "output must be FLOAT TRS values with the input key count; repair the key accessor", .{});
                total_keys += input.count;
                if (total_keys > asset.animation.Limits.default.max_total_keys) return self.fail(cp, "exceeds the total-key limit; reduce the clip", .{});
                import_keys += input.count;
                if (import_keys > @min(self.limits.max_animation_keys, asset.animation.Limits.default.max_total_keys)) return self.fail(cp, "exceeds the import-wide key limit; split or reduce animations", .{});
                const times = try self.arena.alloc(f32, input.count);
                const values = try self.arena.alloc(f32, @as(usize, input.count) * target_path.width());
                for (times, 0..) |*t, k| t.* = try self.float(cp, input, @intCast(k), 0);
                for (0..input.count) |k| {
                    for (0..target_path.width()) |lane| {
                        const v = try self.float(cp, output, @intCast(k), @intCast(lane));
                        if (!std.math.isFinite(v)) return self.fail(cp, "contains non-finite key values; repair the key", .{});
                        values[k * target_path.width() + lane] = v;
                    }
                    if (target_path == .rotation) {
                        const v = values[k * 4 ..][0..4];
                        const q: core.math.Quat = .{ .x = v[0], .y = v[1], .z = v[2], .w = v[3] };
                        if (!q.isUnit()) return self.fail(cp, "has a non-unit rotation key; normalize rotations on export", .{});
                    }
                }
                try tracks.append(self.arena, .{ .joint = j, .path = target_path, .interpolation = if (std.mem.eql(u8, sampler.interpolation, "STEP")) .step else .linear, .times = times, .values = values });
            }
            if (duration <= 0 or !std.math.isFinite(duration)) return self.fail(path, "has no positive finite duration; export a clip longer than zero seconds", .{});
            clips[ai] = .{ .name = name, .source = .{ .duration = duration, .joint_count = @intCast(joint_count), .tracks = tracks.items } };
        }
        return clips;
    }

    pub fn open(self: Context, path: []const u8, index: u32) Error!accessor.View {
        return accessor.open(self.doc, self.buffers, index) catch |err| return self.fail(path, "accessor {d} is invalid ({s}); repair the accessor", .{ index, @errorName(err) });
    }
    pub fn float(self: Context, path: []const u8, v: accessor.View, element: u32, lane: u32) Error!f32 {
        return v.float(element, lane) catch |err| return self.fail(path, "accessor cannot be read ({s}); repair its component type", .{@errorName(err)});
    }
    fn localMatrix(self: Context, index: u32) Error!Mat4 {
        const node = self.doc.nodes[index];
        const path = try std.fmt.allocPrint(self.arena, "nodes[{d}] ('{s}')", .{ index, node.name orelse "" });
        if (node.matrix) |flat| {
            if (node.translation != null or node.rotation != null or node.scale != null) return self.fail(path, "writes matrix and TRS; export one representation", .{});
            var m: Mat4 = undefined;
            for (0..4) |c| for (0..4) |r| {
                m.cols[c][r] = flat[c * 4 + r];
            };
            if (!affine(m)) return self.fail(path, "has a non-finite or non-affine matrix; apply transforms on export", .{});
            return m;
        }
        const t = node.translation orelse .{ 0, 0, 0 };
        const r = node.rotation orelse .{ 0, 0, 0, 1 };
        const s = node.scale orelse .{ 1, 1, 1 };
        const trs: Transform = .{ .translation = .init(t[0], t[1], t[2]), .rotation = .{ .x = r[0], .y = r[1], .z = r[2], .w = r[3] }, .scale = .init(s[0], s[1], s[2]) };
        if (!trs.isValid()) return self.fail(path, "has invalid TRS; normalize rotations and use finite transforms", .{});
        return trs.toMat4();
    }
    pub fn fail(self: Context, path: []const u8, comptime fmt: []const u8, args: anytype) Error {
        const detail = std.fmt.allocPrint(self.arena, fmt, args) catch return error.OutOfMemory;
        self.diags.addFmt(self.gpa, .err, .whole(self.source), 1, "", "{s} {s}", .{ path, detail }) catch return error.OutOfMemory;
        return error.ContentInvalid;
    }
    pub fn warn(self: Context, path: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const detail = try std.fmt.allocPrint(self.arena, fmt, args);
        try self.diags.addFmt(self.gpa, .warning, .whole(self.source), 1, "", "{s} {s}", .{ path, detail });
    }
};
fn isAncestor(parents: []const u32, ancestor: u32, child: u32) bool {
    var at = child;
    while (at != none) {
        if (at == ancestor) return true;
        at = parents[at];
    }
    return false;
}
fn affine(m: Mat4) bool {
    for (m.cols) |c| for (c) |v| {
        if (!std.math.isFinite(v)) return false;
    };
    return m.cols[0][3] == 0 and m.cols[1][3] == 0 and m.cols[2][3] == 0 and m.cols[3][3] == 1;
}
