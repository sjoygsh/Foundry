//! MikkTSpace tangents, a Zig port of Morten S. Mikkelsen's `mikktspace.c` (ADR-0086,
//! `docs/design/environment.md` §5.1).
//!
//! **This is an altered version of the original software, and is marked as such** (zlib
//! licence, clause 2; `THIRD_PARTY_LICENSES/mikktspace.md`). The original is copyright (C)
//! 2011 by Morten S. Mikkelsen, from commit 3e895b49d05ea07e4c2133156cfa94369e19e409 of
//! https://github.com/mmikk/MikkTSpace.
//!
//! A normal map is right only under the basis it was baked against, and Blender, Substance,
//! xNormal and glTF 2.0 all mean MikkTSpace. So this keeps the reference's structure and its
//! `f32` arithmetic, step for step, and a corpus test compares every tangent's bits with the
//! reference's (`testdata/tangents/`, written by `scripts/m41/make_tangent_corpus.py`).
//!
//! **What the port leaves out, none of which changes a result for a triangle list:**
//! - Quads. Every Foundry mesh is a triangle list, so a face is always three corners and no
//!   two triangles share an original face. The reference's quad paths (the shorter-diagonal
//!   split, `QUAD_ONE_DEGEN_TRI`, the forced quad orientation, and `AvgTSpace`, which only
//!   a corner shared by a quad's two triangles reaches) never run on such input.
//! - The angular threshold. Only `genTangSpaceDefault`'s 180° is offered, whose cosine the
//!   reference computes as exactly -1 in `f32`.
//! - The slow fallbacks taken when `malloc` fails. Here an allocation failure is
//!   `error.OutOfMemory`, never a different algorithm.
//! - `setTSpace`'s bitangent and magnitudes. Only `setTSpaceBasic`'s tangent and sign leave.
//!
//! **Input is refused, not repaired:** a non-finite value, an index out of range, or an index
//! count that is not a whole number of triangles is a named error. The reference's own
//! behaviour on non-finite input depends on the C compiler, so it is not a contract to match.
//!
//! Pure and thread-free: it allocates only through the allocator it is given.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// One corner's tangent: xyz, and the bitangent's sign in w (+1 or -1), as glTF stores it.
pub const Tangent = [4]f32;

pub const Input = struct {
    positions: []align(1) const [3]f32,
    normals: []align(1) const [3]f32,
    uvs: []align(1) const [2]f32,
    /// A triangle list. Every index must name a vertex.
    indices: []const u32,
};

pub const Error = Allocator.Error || error{
    /// The normals or UVs do not have the positions' count.
    StreamLengthMismatch,
    /// The index count is zero or not a multiple of three.
    InvalidIndexCount,
    IndexOutOfRange,
    /// More triangles than a corner's packed index can name (2^29).
    TooManyTriangles,
    NonFinitePosition,
    NonFiniteNormal,
    NonFiniteTexcoord,
};

/// The tangent of every corner, `out[i]` for `input.indices[i]`. Corners of one vertex may
/// differ, at a UV seam or a mirror; the caller splits that vertex if it needs one tangent
/// per vertex. The caller frees the result with `gpa`.
pub fn generate(gpa: Allocator, input: Input) Error![]Tangent {
    const count = input.positions.len;
    if (input.normals.len != count or input.uvs.len != count) return error.StreamLengthMismatch;
    if (input.indices.len == 0 or input.indices.len % 3 != 0) return error.InvalidIndexCount;
    if (input.indices.len / 3 > max_triangles) return error.TooManyTriangles;
    for (input.indices) |index| if (index >= count) return error.IndexOutOfRange;
    for (input.positions) |p| if (!finite3(p)) return error.NonFinitePosition;
    for (input.normals) |n| if (!finite3(n)) return error.NonFiniteNormal;
    for (input.uvs) |t| if (!std.math.isFinite(t[0]) or !std.math.isFinite(t[1])) return error.NonFiniteTexcoord;

    var context: Context = .{ .input = input };
    return context.run(gpa);
}

/// A corner is named `face << 2 | corner`, so a face number fits in 29 bits.
const max_triangles = 1 << 29;

fn finite3(v: [3]f32) bool {
    return std.math.isFinite(v[0]) and std.math.isFinite(v[1]) and std.math.isFinite(v[2]);
}

// -- vectors, exactly as the reference evaluates them ---------------------------------

const Vec = struct {
    x: f32,
    y: f32,
    z: f32,

    const zero: Vec = .{ .x = 0, .y = 0, .z = 0 };
};

fn veq(a: Vec, b: Vec) bool {
    return a.x == b.x and a.y == b.y and a.z == b.z;
}

fn vadd(a: Vec, b: Vec) Vec {
    return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
}

fn vsub(a: Vec, b: Vec) Vec {
    return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
}

fn vscale(s: f32, v: Vec) Vec {
    return .{ .x = s * v.x, .y = s * v.y, .z = s * v.z };
}

fn lengthSquared(v: Vec) f32 {
    return v.x * v.x + v.y * v.y + v.z * v.z;
}

fn length(v: Vec) f32 {
    return @sqrt(lengthSquared(v));
}

fn normalize(v: Vec) Vec {
    return vscale(1 / length(v), v);
}

fn vdot(a: Vec, b: Vec) f32 {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

/// `fabsf(x) > FLT_MIN`.
fn notZero(x: f32) bool {
    return @abs(x) > std.math.floatMin(f32);
}

fn vNotZero(v: Vec) bool {
    return notZero(v.x) or notZero(v.y) or notZero(v.z);
}

// -- the reference's records ---------------------------------------------------------

const mark_degenerate: u32 = 1;
const group_with_any: u32 = 4;
const orient_preserving: u32 = 8;

const no_group = std.math.maxInt(u32);

const TriInfo = struct {
    neighbors: [3]i32 = .{ -1, -1, -1 },
    /// Indices into the group list, `no_group` for none: the reference's `AssignedGroup`
    /// pointers, compared only for identity.
    groups: [3]u32 = .{ no_group, no_group, no_group },
    os: Vec = .zero,
    ot: Vec = .zero,
    mag_s: f32 = 0,
    mag_t: f32 = 0,
    org_face: i32 = 0,
    flag: u32 = 0,
    tspaces_offs: i32 = 0,
    vert_num: [3]u8 = .{ 0, 1, 2 },
};

const Group = struct {
    face_count: i32,
    /// Where its faces start in the shared buffer.
    faces_at: usize,
    vertex_representative: i32,
    orient_preserving: bool,
};

const TSpace = struct {
    os: Vec = .{ .x = 1, .y = 0, .z = 0 },
    mag_s: f32 = 1,
    ot: Vec = .{ .x = 0, .y = 1, .z = 0 },
    mag_t: f32 = 1,
    counter: i32 = 0,
    orient: bool = false,
};

const Edge = struct {
    /// i0, i1, f: the reference's union, indexed by sort channel.
    v: [3]i32,
};

const internal_rnd_sort_seed: u32 = 39871946;
const cells: i32 = 2048;
/// `cos((180 * (float)M_PI) / 180.0f)` rounded to `float`, as `genTangSpaceDefault` makes it.
const thres_cos: f32 = -1.0;

fn makeIndex(face: i32, vert: i32) i32 {
    return (face << 2) | (vert & 0x3);
}

/// Rotates the seed as the reference does. Its `uSeed >> (32 - t)` shifts by 32 when `t` is
/// zero, which every target Foundry builds for performs modulo 32: a rotation. The pivots it
/// picks do not change a result here: every key sorted is distinct by the time the sorts
/// finish (an edge by its two vertices and its face), so any pivot gives the same order. It is
/// kept so the port stays the reference's.
fn nextSeed(seed: u32) u32 {
    const t: u5 = @truncate(seed & 31);
    return seed +% std.math.rotl(u32, seed, t) +% 3;
}

const Context = struct {
    input: Input,

    fn vertexOf(self: *const Context, index: i32) u32 {
        const face: usize = @intCast(index >> 2);
        const corner: usize = @intCast(index & 0x3);
        return self.input.indices[face * 3 + corner];
    }

    fn position(self: *const Context, index: i32) Vec {
        const p = self.input.positions[self.vertexOf(index)];
        return .{ .x = p[0], .y = p[1], .z = p[2] };
    }

    fn normal(self: *const Context, index: i32) Vec {
        const n = self.input.normals[self.vertexOf(index)];
        return .{ .x = n[0], .y = n[1], .z = n[2] };
    }

    fn texCoord(self: *const Context, index: i32) Vec {
        const t = self.input.uvs[self.vertexOf(index)];
        return .{ .x = t[0], .y = t[1], .z = 1 };
    }

    /// `genTangSpace`, for triangles.
    fn run(self: *const Context, gpa: Allocator) Error![]Tangent {
        const total_tris: i32 = @intCast(self.input.indices.len / 3);
        const tspace_count: usize = @intCast(total_tris * 3);

        const tri_list = try gpa.alloc(i32, tspace_count);
        defer gpa.free(tri_list);
        const tri_infos = try gpa.alloc(TriInfo, @intCast(total_tris));
        defer gpa.free(tri_infos);

        // GenerateInitialVerticesIndexList: every face is a triangle.
        for (tri_infos, 0..) |*info, t| {
            const f: i32 = @intCast(t);
            info.* = .{ .org_face = f, .tspaces_offs = f * 3 };
            for (0..3) |i| tri_list[t * 3 + i] = makeIndex(f, @intCast(i));
        }

        try self.generateSharedVerticesIndexList(gpa, tri_list, total_tris);

        // Mark every degenerate triangle.
        var degenerate: i32 = 0;
        for (tri_infos, 0..) |*info, t| {
            const p0 = self.position(tri_list[t * 3 + 0]);
            const p1 = self.position(tri_list[t * 3 + 1]);
            const p2 = self.position(tri_list[t * 3 + 2]);
            if (veq(p0, p1) or veq(p0, p2) or veq(p1, p2)) {
                info.flag |= mark_degenerate;
                degenerate += 1;
            }
        }
        const good_tris = total_tris - degenerate;

        degenPrologue(tri_infos, tri_list, good_tris, total_tris);

        try self.initTriInfo(gpa, tri_infos, tri_list, good_tris);

        const max_groups: usize = @intCast(good_tris * 3);
        const groups = try gpa.alloc(Group, max_groups);
        defer gpa.free(groups);
        const group_faces = try gpa.alloc(i32, max_groups);
        defer gpa.free(group_faces);
        const active_groups = build4RuleGroups(tri_infos, groups, group_faces, tri_list, good_tris);

        const tspaces = try gpa.alloc(TSpace, tspace_count);
        defer gpa.free(tspaces);
        @memset(tspaces, .{});

        try self.generateTSpaces(gpa, tspaces, tri_infos, groups[0..active_groups], group_faces, tri_list);

        degenEpilogue(tspaces, tri_infos, tri_list, good_tris, total_tris);

        const out = try gpa.alloc(Tangent, tspace_count);
        for (out, tspaces) |*tangent, space| {
            tangent.* = .{ space.os.x, space.os.y, space.os.z, if (space.orient) 1.0 else -1.0 };
        }
        return out;
    }

    // -- welding ----------------------------------------------------------------------

    /// The reference marks this `noinline` so the cell of one value never depends on how a
    /// compiler reordered the arithmetic around it. Zig does not contract or reorder floating
    /// point, so a plain function gives the same cell for the same value.
    fn findGridCell(min: f32, max: f32, value: f32) i32 {
        const index_f: f32 = @as(f32, @floatFromInt(cells)) * ((value - min) / (max - min));
        // C's `(int)` of a NaN (every value equal on the axis) gives 0 or INT_MIN on Foundry's
        // targets, and both clamp to cell 0; `+inf` cannot arise from finite input.
        if (!(index_f >= 0)) return 0;
        if (index_f >= @as(f32, @floatFromInt(cells))) return cells - 1;
        return @intFromFloat(index_f);
    }

    fn channelOf(v: Vec, channel: u2) f32 {
        return switch (channel) {
            0 => v.x,
            1 => v.y,
            else => v.z,
        };
    }

    fn generateSharedVerticesIndexList(self: *const Context, gpa: Allocator, tri_list: []i32, tris: i32) Error!void {
        const corners: usize = @intCast(tris * 3);
        var v_min = self.position(0);
        var v_max = v_min;
        for (1..corners) |i| {
            const p = self.position(tri_list[i]);
            if (v_min.x > p.x) v_min.x = p.x else if (v_max.x < p.x) v_max.x = p.x;
            if (v_min.y > p.y) v_min.y = p.y else if (v_max.y < p.y) v_max.y = p.y;
            if (v_min.z > p.z) v_min.z = p.z else if (v_max.z < p.z) v_max.z = p.z;
        }

        const dim = vsub(v_max, v_min);
        var channel: u2 = 0;
        var f_min = v_min.x;
        var f_max = v_max.x;
        if (dim.y > dim.x and dim.y > dim.z) {
            channel = 1;
            f_min = v_min.y;
            f_max = v_max.y;
        } else if (dim.z > dim.x) {
            channel = 2;
            f_min = v_min.z;
            f_max = v_max.z;
        }

        const hash_table = try gpa.alloc(i32, corners);
        defer gpa.free(hash_table);
        const cell_count: usize = @intCast(cells);
        const hash_count = try gpa.alloc(i32, cell_count);
        defer gpa.free(hash_count);
        const hash_offsets = try gpa.alloc(i32, cell_count);
        defer gpa.free(hash_offsets);
        const hash_count2 = try gpa.alloc(i32, cell_count);
        defer gpa.free(hash_count2);
        @memset(hash_count, 0);
        @memset(hash_count2, 0);

        for (0..corners) |i| {
            const value = channelOf(self.position(tri_list[i]), channel);
            hash_count[@intCast(findGridCell(f_min, f_max, value))] += 1;
        }

        hash_offsets[0] = 0;
        for (1..cell_count) |k| hash_offsets[k] = hash_offsets[k - 1] + hash_count[k - 1];

        for (0..corners) |i| {
            const value = channelOf(self.position(tri_list[i]), channel);
            const cell: usize = @intCast(findGridCell(f_min, f_max, value));
            std.debug.assert(hash_count2[cell] < hash_count[cell]);
            const at: usize = @intCast(hash_offsets[cell] + hash_count2[cell]);
            hash_table[at] = @intCast(i);
            hash_count2[cell] += 1;
        }

        var max_count = hash_count[0];
        for (hash_count[1..]) |n| max_count = @max(max_count, n);
        const tmp = try gpa.alloc(TmpVert, @intCast(max_count));
        defer gpa.free(tmp);

        for (0..cell_count) |k| {
            const start: usize = @intCast(hash_offsets[k]);
            const entries: usize = @intCast(hash_count[k]);
            if (entries < 2) continue;
            const table = hash_table[start..][0..entries];
            for (table, 0..) |i, e| {
                const p = self.position(tri_list[@intCast(i)]);
                tmp[e] = .{ .vert = .{ p.x, p.y, p.z }, .index = i };
            }
            self.mergeVertsFast(tri_list, tmp, 0, @intCast(entries - 1));
        }
    }

    const TmpVert = struct {
        vert: [3]f32,
        index: i32,
    };

    fn mergeVertsFast(self: *const Context, tri_list: []i32, tmp: []TmpVert, l_in: i32, r_in: i32) void {
        const lo: usize = @intCast(l_in);
        const hi: usize = @intCast(r_in);
        var fv_min = tmp[lo].vert;
        var fv_max = fv_min;
        for (lo + 1..hi + 1) |l| {
            for (0..3) |c| {
                if (fv_min[c] > tmp[l].vert[c]) fv_min[c] = tmp[l].vert[c];
                if (fv_max[c] < tmp[l].vert[c]) fv_max[c] = tmp[l].vert[c];
            }
        }

        const dx = fv_max[0] - fv_min[0];
        const dy = fv_max[1] - fv_min[1];
        const dz = fv_max[2] - fv_min[2];

        var channel: usize = 0;
        if (dy > dx and dy > dz) channel = 1 else if (dz > dx) channel = 2;

        const sep = 0.5 * (fv_max[channel] + fv_min[channel]);

        if (!std.math.isFinite(sep)) return;

        if (sep >= fv_max[channel] or sep <= fv_min[channel]) {
            // Complete the weld: each entry takes the first earlier entry equal to it.
            for (lo..hi + 1) |l| {
                const i: usize = @intCast(tmp[l].index);
                const index = tri_list[i];
                const p = self.position(index);
                const n = self.normal(index);
                const t = self.texCoord(index);

                var not_found = true;
                var l2 = lo;
                var i2rec: usize = 0;
                while (l2 < l and not_found) {
                    const other: usize = @intCast(tmp[l2].index);
                    const index2 = tri_list[other];
                    i2rec = other;
                    if (veq(p, self.position(index2)) and veq(n, self.normal(index2)) and veq(t, self.texCoord(index2))) {
                        not_found = false;
                    } else {
                        l2 += 1;
                    }
                }
                if (!not_found) tri_list[i] = tri_list[i2rec];
            }
            return;
        }

        var il: i32 = l_in;
        var ir: i32 = r_in;
        std.debug.assert(r_in - l_in > 0);
        while (il < ir) {
            var ready_left = false;
            var ready_right = false;
            while (!ready_left and il < ir) {
                ready_left = !(tmp[@intCast(il)].vert[channel] < sep);
                if (!ready_left) il += 1;
            }
            while (!ready_right and il < ir) {
                ready_right = tmp[@intCast(ir)].vert[channel] < sep;
                if (!ready_right) ir -= 1;
            }
            if (ready_left and ready_right) {
                std.mem.swap(TmpVert, &tmp[@intCast(il)], &tmp[@intCast(ir)]);
                il += 1;
                ir -= 1;
            }
        }

        if (il == ir) {
            if (tmp[@intCast(ir)].vert[channel] < sep) il += 1 else ir -= 1;
        }

        if (l_in < ir) self.mergeVertsFast(tri_list, tmp, l_in, ir);
        if (il < r_in) self.mergeVertsFast(tri_list, tmp, il, r_in);
    }

    // -- triangle attributes and neighbours ------------------------------------------

    fn initTriInfo(self: *const Context, gpa: Allocator, infos: []TriInfo, tri_list: []const i32, tris: i32) Error!void {
        const count: usize = @intCast(tris);
        for (infos[0..count]) |*info| {
            info.neighbors = .{ -1, -1, -1 };
            info.groups = .{ no_group, no_group, no_group };
            info.os = .zero;
            info.ot = .zero;
            info.mag_s = 0;
            info.mag_t = 0;
            // Assumed bad.
            info.flag |= group_with_any;
        }

        for (infos[0..count], 0..) |*info, f| {
            const v1 = self.position(tri_list[f * 3 + 0]);
            const v2 = self.position(tri_list[f * 3 + 1]);
            const v3 = self.position(tri_list[f * 3 + 2]);
            const t1 = self.texCoord(tri_list[f * 3 + 0]);
            const t2 = self.texCoord(tri_list[f * 3 + 1]);
            const t3 = self.texCoord(tri_list[f * 3 + 2]);

            const t21x = t2.x - t1.x;
            const t21y = t2.y - t1.y;
            const t31x = t3.x - t1.x;
            const t31y = t3.y - t1.y;
            const d1 = vsub(v2, v1);
            const d2 = vsub(v3, v1);

            const signed_area_x2 = t21x * t31y - t21y * t31x;
            const os = vsub(vscale(t31y, d1), vscale(t21y, d2)); // eq 18
            const ot = vadd(vscale(-t31x, d1), vscale(t21x, d2)); // eq 19

            if (signed_area_x2 > 0) info.flag |= orient_preserving;

            if (notZero(signed_area_x2)) {
                const abs_area = @abs(signed_area_x2);
                const len_os = length(os);
                const len_ot = length(ot);
                const s: f32 = if (info.flag & orient_preserving == 0) -1.0 else 1.0;
                if (notZero(len_os)) info.os = vscale(s / len_os, os);
                if (notZero(len_ot)) info.ot = vscale(s / len_ot, ot);

                info.mag_s = len_os / abs_area;
                info.mag_t = len_ot / abs_area;

                if (notZero(info.mag_s) and notZero(info.mag_t)) info.flag &= ~group_with_any;
            }
        }

        // The reference's quad orientation pass finds no quad in a triangle list.

        const edges = try gpa.alloc(Edge, count * 3);
        defer gpa.free(edges);
        buildNeighborsFast(infos, edges, tri_list, tris);
    }

    // -- tangent spaces ---------------------------------------------------------------

    fn project(n: Vec, v: Vec) Vec {
        var out = vsub(v, vscale(vdot(n, v), n));
        if (vNotZero(out)) out = normalize(out);
        return out;
    }

    fn generateTSpaces(
        self: *const Context,
        gpa: Allocator,
        tspaces: []TSpace,
        infos: []const TriInfo,
        groups: []const Group,
        group_faces: []const i32,
        tri_list: []const i32,
    ) Error!void {
        var max_faces: i32 = 0;
        for (groups) |group| max_faces = @max(max_faces, group.face_count);
        if (max_faces == 0) return;

        const max: usize = @intCast(max_faces);
        const sub_tspaces = try gpa.alloc(TSpace, max);
        defer gpa.free(sub_tspaces);
        // Each unique subgroup's members, sorted, at `sub_at[s]` in `sub_members`.
        const sub_at = try gpa.alloc(usize, max);
        defer gpa.free(sub_at);
        const sub_len = try gpa.alloc(usize, max);
        defer gpa.free(sub_len);
        var sub_members: std.ArrayList(i32) = .empty;
        defer sub_members.deinit(gpa);
        const tmp_members = try gpa.alloc(i32, max);
        defer gpa.free(tmp_members);

        for (groups, 0..) |group, g| {
            var unique: usize = 0;
            sub_members.clearRetainingCapacity();
            const faces = group_faces[group.faces_at..][0..@intCast(group.face_count)];

            for (faces) |face| {
                const f: usize = @intCast(face);
                var index: usize = 3;
                for (0..3) |k| if (infos[f].groups[k] == g) {
                    index = k;
                    break;
                };
                std.debug.assert(index < 3);

                const vert_index = tri_list[f * 3 + index];
                std.debug.assert(vert_index == group.vertex_representative);

                const n = self.normal(vert_index);
                const os = project(n, infos[f].os);
                const ot = project(n, infos[f].ot);

                const of1 = infos[f].org_face;

                var members: usize = 0;
                for (faces) |other| {
                    const t: usize = @intCast(other);
                    const of2 = infos[t].org_face;
                    const os2 = project(n, infos[t].os);
                    const ot2 = project(n, infos[t].ot);

                    const any = (infos[f].flag | infos[t].flag) & group_with_any != 0;
                    const same_org_face = of1 == of2;
                    const cos_s = vdot(os, os2);
                    const cos_t = vdot(ot, ot2);

                    if (any or same_org_face or (cos_s > thres_cos and cos_t > thres_cos)) {
                        tmp_members[members] = other;
                        members += 1;
                    }
                }

                if (members > 1) quickSort(tmp_members, 0, @intCast(members - 1), internal_rnd_sort_seed);
                const group_members = tmp_members[0..members];

                var found = false;
                var l: usize = 0;
                while (l < unique and !found) {
                    found = std.mem.eql(i32, group_members, sub_members.items[sub_at[l]..][0..sub_len[l]]);
                    if (!found) l += 1;
                }

                if (!found) {
                    sub_at[unique] = sub_members.items.len;
                    sub_len[unique] = members;
                    try sub_members.appendSlice(gpa, group_members);
                    sub_tspaces[unique] = self.evalTSpace(group_members, tri_list, infos, group.vertex_representative);
                    unique += 1;
                }

                // A triangle's corner is reached once, so the reference's average of two
                // spaces at one corner, which only a quad's two triangles produce, never runs.
                const out = &tspaces[@intCast(infos[f].tspaces_offs + infos[f].vert_num[index])];
                std.debug.assert(out.counter == 0);
                out.* = sub_tspaces[l];
                out.counter = 1;
                out.orient = group.orient_preserving;
            }
        }
    }

    fn evalTSpace(self: *const Context, faces: []const i32, tri_list: []const i32, infos: []const TriInfo, vertex_representative: i32) TSpace {
        var res: TSpace = .{ .os = .zero, .ot = .zero, .mag_s = 0, .mag_t = 0 };
        var angle_sum: f32 = 0;

        for (faces) |face| {
            const f: usize = @intCast(face);
            if (infos[f].flag & group_with_any != 0) continue;

            var i: usize = 3;
            for (0..3) |k| if (tri_list[3 * f + k] == vertex_representative) {
                i = k;
                break;
            };
            std.debug.assert(i < 3);

            const index = tri_list[3 * f + i];
            const n = self.normal(index);
            const os = project(n, infos[f].os);
            const ot = project(n, infos[f].ot);

            const next = tri_list[3 * f + (if (i < 2) i + 1 else 0)];
            const here = tri_list[3 * f + i];
            const prev = tri_list[3 * f + (if (i > 0) i - 1 else 2)];

            const p0 = self.position(prev);
            const p1 = self.position(here);
            const p2 = self.position(next);
            const v1 = project(n, vsub(p0, p1));
            const v2 = project(n, vsub(p2, p1));

            var cos_angle = vdot(v1, v2);
            cos_angle = if (cos_angle > 1) 1 else if (cos_angle < -1) -1 else cos_angle;
            // `(float) acos(fCos)`: the reference takes the arc cosine in double.
            const angle: f32 = @floatCast(std.math.acos(@as(f64, cos_angle)));
            const mag_s = infos[f].mag_s;
            const mag_t = infos[f].mag_t;

            res.os = vadd(res.os, vscale(angle, os));
            res.ot = vadd(res.ot, vscale(angle, ot));
            res.mag_s += angle * mag_s;
            res.mag_t += angle * mag_t;
            angle_sum += angle;
        }

        if (vNotZero(res.os)) res.os = normalize(res.os);
        if (vNotZero(res.ot)) res.ot = normalize(res.ot);
        if (angle_sum > 0) {
            res.mag_s /= angle_sum;
            res.mag_t /= angle_sum;
        }
        return res;
    }
};

// -- groups ---------------------------------------------------------------------------

fn build4RuleGroups(infos: []TriInfo, groups: []Group, group_faces: []i32, tri_list: []const i32, tris: i32) usize {
    var active: usize = 0;
    var offset: usize = 0;
    for (0..@intCast(tris)) |f| {
        for (0..3) |i| {
            if (infos[f].flag & group_with_any != 0 or infos[f].groups[i] != no_group) continue;

            const vert_index = tri_list[f * 3 + i];
            std.debug.assert(active < groups.len);
            const g: u32 = @intCast(active);
            infos[f].groups[i] = g;
            groups[g] = .{
                .face_count = 0,
                .faces_at = offset,
                .vertex_representative = vert_index,
                .orient_preserving = infos[f].flag & orient_preserving != 0,
            };
            active += 1;

            addTriToGroup(groups, group_faces, g, @intCast(f));
            const neigh_l = infos[f].neighbors[i];
            const neigh_r = infos[f].neighbors[if (i > 0) i - 1 else 2];
            if (neigh_l >= 0) _ = assignRecur(tri_list, infos, neigh_l, groups, group_faces, g);
            if (neigh_r >= 0) _ = assignRecur(tri_list, infos, neigh_r, groups, group_faces, g);

            offset += @intCast(groups[g].face_count);
            std.debug.assert(offset <= groups.len);
        }
    }
    return active;
}

fn addTriToGroup(groups: []Group, group_faces: []i32, g: u32, tri: i32) void {
    const group = &groups[g];
    group_faces[group.faces_at + @as(usize, @intCast(group.face_count))] = tri;
    group.face_count += 1;
}

fn assignRecur(tri_list: []const i32, infos: []TriInfo, my_tri: i32, groups: []Group, group_faces: []i32, g: u32) bool {
    const t: usize = @intCast(my_tri);
    const info = &infos[t];
    const rep = groups[g].vertex_representative;
    const verts = tri_list[3 * t ..][0..3];
    const i: usize = if (verts[0] == rep) 0 else if (verts[1] == rep) 1 else if (verts[2] == rep) 2 else unreachable;

    if (info.groups[i] == g) return true;
    if (info.groups[i] != no_group) return false;
    if (info.flag & group_with_any != 0) {
        // The first group to reach a group-with-anything triangle sets its orientation:
        // the reference's one order dependency.
        if (info.groups[0] == no_group and info.groups[1] == no_group and info.groups[2] == no_group) {
            info.flag &= ~orient_preserving;
            if (groups[g].orient_preserving) info.flag |= orient_preserving;
        }
    }
    if ((info.flag & orient_preserving != 0) != groups[g].orient_preserving) return false;

    addTriToGroup(groups, group_faces, g, my_tri);
    info.groups[i] = g;

    const neigh_l = info.neighbors[i];
    const neigh_r = info.neighbors[if (i > 0) i - 1 else 2];
    if (neigh_l >= 0) _ = assignRecur(tri_list, infos, neigh_l, groups, group_faces, g);
    if (neigh_r >= 0) _ = assignRecur(tri_list, infos, neigh_r, groups, group_faces, g);
    return true;
}

// -- sorting, with the reference's pivots ---------------------------------------------

fn quickSort(buffer: []i32, left: i32, right: i32, seed_in: u32) void {
    const seed = nextSeed(seed_in);

    var il = left;
    var ir = right;
    const n: u32 = @intCast(ir - il + 1);
    const index: i32 = @intCast(seed % n);
    const mid = buffer[@intCast(index + il)];

    while (true) {
        while (buffer[@intCast(il)] < mid) il += 1;
        while (buffer[@intCast(ir)] > mid) ir -= 1;
        if (il <= ir) {
            std.mem.swap(i32, &buffer[@intCast(il)], &buffer[@intCast(ir)]);
            il += 1;
            ir -= 1;
        }
        if (!(il <= ir)) break;
    }

    if (left < ir) quickSort(buffer, left, ir, seed);
    if (il < right) quickSort(buffer, il, right, seed);
}

fn quickSortEdges(buffer: []Edge, left: i32, right: i32, channel: usize, seed_in: u32) void {
    const elems = right - left + 1;
    if (elems < 2) return;
    if (elems == 2) {
        if (buffer[@intCast(left)].v[channel] > buffer[@intCast(right)].v[channel]) {
            std.mem.swap(Edge, &buffer[@intCast(left)], &buffer[@intCast(right)]);
        }
        return;
    }

    const seed = nextSeed(seed_in);

    var il = left;
    var ir = right;
    const n: u32 = @intCast(ir - il + 1);
    const index: i32 = @intCast(seed % n);
    const mid = buffer[@intCast(index + il)].v[channel];

    while (true) {
        while (buffer[@intCast(il)].v[channel] < mid) il += 1;
        while (buffer[@intCast(ir)].v[channel] > mid) ir -= 1;
        if (il <= ir) {
            std.mem.swap(Edge, &buffer[@intCast(il)], &buffer[@intCast(ir)]);
            il += 1;
            ir -= 1;
        }
        if (!(il <= ir)) break;
    }

    if (left < ir) quickSortEdges(buffer, left, ir, channel, seed);
    if (il < right) quickSortEdges(buffer, il, right, channel, seed);
}

/// The edge of `indices` that joins `a` and `b`, in the triangle's own winding.
fn getEdge(indices: []const i32, a: i32, b: i32) struct { first: i32, second: i32, edge: usize } {
    if (indices[0] == a or indices[0] == b) {
        if (indices[1] == a or indices[1] == b) return .{ .first = indices[0], .second = indices[1], .edge = 0 };
        return .{ .first = indices[2], .second = indices[0], .edge = 2 };
    }
    return .{ .first = indices[1], .second = indices[2], .edge = 1 };
}

fn buildNeighborsFast(infos: []TriInfo, edges: []Edge, tri_list: []const i32, tris: i32) void {
    const seed = internal_rnd_sort_seed;
    const count: usize = @intCast(tris);
    // Every triangle degenerate: no edges to pair.
    if (count == 0) return;
    for (0..count) |f| {
        for (0..3) |i| {
            const a = tri_list[f * 3 + i];
            const b = tri_list[f * 3 + (if (i < 2) i + 1 else 0)];
            edges[f * 3 + i] = .{ .v = .{ if (a < b) a else b, if (!(a < b)) a else b, @intCast(f) } };
        }
    }

    const entries: i32 = tris * 3;
    quickSortEdges(edges, 0, entries - 1, 0, seed);

    var start: usize = 0;
    for (1..@intCast(entries)) |i| {
        if (edges[start].v[0] != edges[i].v[0]) {
            const l: i32 = @intCast(start);
            const r: i32 = @intCast(i - 1);
            start = i;
            quickSortEdges(edges, l, r, 1, seed);
        }
    }

    // The reference's sub-sort by face keeps it compliant with its slow path when more
    // than two triangles share an edge.
    start = 0;
    for (1..@intCast(entries)) |i| {
        if (edges[start].v[0] != edges[i].v[0] or edges[start].v[1] != edges[i].v[1]) {
            const l: i32 = @intCast(start);
            const r: i32 = @intCast(i - 1);
            start = i;
            quickSortEdges(edges, l, r, 2, seed);
        }
    }

    for (0..@intCast(entries)) |i| {
        const lo = edges[i].v[0];
        const hi = edges[i].v[1];
        const f: usize = @intCast(edges[i].v[2]);
        const a = getEdge(tri_list[f * 3 ..][0..3], lo, hi);
        if (infos[f].neighbors[a.edge] != -1) continue;

        var j = i + 1;
        var not_found = true;
        var edge_b: usize = 0;
        while (j < @as(usize, @intCast(entries)) and lo == edges[j].v[0] and hi == edges[j].v[1] and not_found) {
            const t: usize = @intCast(edges[j].v[2]);
            // Flipped: B's edge runs the other way round.
            const b = getEdge(tri_list[t * 3 ..][0..3], edges[j].v[0], edges[j].v[1]);
            edge_b = b.edge;
            const unassigned_b = infos[t].neighbors[b.edge] == -1;
            if (a.first == b.second and a.second == b.first and unassigned_b) not_found = false else j += 1;
        }

        if (!not_found) {
            const t = edges[j].v[2];
            infos[f].neighbors[a.edge] = t;
            infos[@intCast(t)].neighbors[edge_b] = @intCast(f);
        }
    }
}

// -- degenerate triangles -------------------------------------------------------------

/// Moves every degenerate triangle behind the good ones, keeping the good ones' order.
fn degenPrologue(infos: []TriInfo, tri_list: []i32, good_tris: i32, total_tris: i32) void {
    var next_good: i32 = 1;
    var t: i32 = 0;
    var still_finding = true;
    while (t < good_tris and still_finding) {
        const is_good = infos[@intCast(t)].flag & mark_degenerate == 0;
        if (is_good) {
            if (next_good < t + 2) next_good = t + 2;
        } else {
            var just_a_degenerate = true;
            while (just_a_degenerate and next_good < total_tris) {
                if (infos[@intCast(next_good)].flag & mark_degenerate == 0) just_a_degenerate = false else next_good += 1;
            }
            const t0: usize = @intCast(t);
            const t1: usize = @intCast(next_good);
            next_good += 1;
            if (!just_a_degenerate) {
                for (0..3) |i| std.mem.swap(i32, &tri_list[t0 * 3 + i], &tri_list[t1 * 3 + i]);
                std.mem.swap(TriInfo, &infos[t0], &infos[t1]);
            } else {
                still_finding = false;
            }
        }
        if (still_finding) t += 1;
    }
}

/// A degenerate triangle's corner copies the space of the first good corner sharing its
/// welded vertex.
fn degenEpilogue(tspaces: []TSpace, infos: []const TriInfo, tri_list: []const i32, good_tris: i32, total_tris: i32) void {
    const good_corners: usize = @intCast(good_tris * 3);
    var t: usize = @intCast(good_tris);
    while (t < @as(usize, @intCast(total_tris))) : (t += 1) {
        for (0..3) |i| {
            const index1 = tri_list[t * 3 + i];
            const j = std.mem.indexOfScalar(i32, tri_list[0..good_corners], index1) orelse continue;
            const src_tri = j / 3;
            const src_vert = j % 3;
            const src: usize = @intCast(infos[src_tri].tspaces_offs + infos[src_tri].vert_num[src_vert]);
            const dst: usize = @intCast(infos[t].tspaces_offs + infos[t].vert_num[i]);
            tspaces[dst] = tspaces[src];
        }
    }
}

// -- tests ----------------------------------------------------------------------------

/// One tangent per vertex, from `generate`'s per-corner tangents (`environment.md`'s Step 2
/// Resolution). `Builder.generateTangents` and glTF import share it, so both split alike.
pub const Split = struct {
    /// One per vertex after the split: each original vertex's first corner's tangent, or
    /// +x with a sign of +1 for a vertex no index names, then each added vertex's.
    tangents: []Tangent,
    /// The original each added vertex copies, in the order they were added.
    sources: []u32,

    pub fn deinit(self: Split, gpa: Allocator) void {
        gpa.free(self.tangents);
        gpa.free(self.sources);
    }
};

/// Rewrites `indices` in place: a vertex keeps its index and its first corner's tangent, and
/// each further tangent its corners need becomes one vertex appended at the end, in
/// first-need order. More than `max_vertices` in all is `TooManyVertices`; on a refusal
/// `indices` may be partly rewritten, so a caller that must stay unchanged passes a copy.
pub fn split(gpa: Allocator, vertex_count: u32, indices: []u32, corners: []const Tangent, max_vertices: u32) (Allocator.Error || error{TooManyVertices})!Split {
    std.debug.assert(indices.len == corners.len);
    const first = try gpa.alloc(?Tangent, vertex_count);
    defer gpa.free(first);
    @memset(first, null);
    const Key = struct { vertex: u32, bits: [4]u32 };
    var added: std.AutoHashMapUnmanaged(Key, u32) = .empty;
    defer added.deinit(gpa);
    var sources: std.ArrayList(u32) = .empty;
    defer sources.deinit(gpa);
    var extra: std.ArrayList(Tangent) = .empty;
    defer extra.deinit(gpa);
    for (indices, corners) |*index, tangent| {
        const vertex = index.*;
        if (first[vertex]) |kept| {
            if (@as(u128, @bitCast(kept)) == @as(u128, @bitCast(tangent))) continue;
            const entry = try added.getOrPut(gpa, .{ .vertex = vertex, .bits = @bitCast(tangent) });
            if (!entry.found_existing) {
                if (vertex_count + sources.items.len >= max_vertices) return error.TooManyVertices;
                entry.value_ptr.* = @intCast(vertex_count + sources.items.len);
                try sources.append(gpa, vertex);
                try extra.append(gpa, tangent);
            }
            index.* = entry.value_ptr.*;
        } else {
            first[vertex] = tangent;
        }
    }
    const tangents = try gpa.alloc(Tangent, vertex_count + extra.items.len);
    errdefer gpa.free(tangents);
    for (first, tangents[0..vertex_count]) |kept, *out| out.* = kept orelse .{ 1, 0, 0, 1 };
    @memcpy(tangents[vertex_count..], extra.items);
    return .{ .tangents = tangents, .sources = try sources.toOwnedSlice(gpa) };
}

const testing = std.testing;

const quad_positions = [_][3]f32{ .{ -1, 0, 1 }, .{ 1, 0, 1 }, .{ 1, 0, -1 }, .{ -1, 0, -1 } };
const quad_normals = [_][3]f32{.{ 0, 1, 0 }} ** 4;
const quad_uvs = [_][2]f32{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };
const quad_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };

test "a flat quad's tangent follows +u, and its sign says +v runs along -cross(n, t)" {
    const out = try generate(testing.allocator, .{
        .positions = &quad_positions,
        .normals = &quad_normals,
        .uvs = &quad_uvs,
        .indices = &quad_indices,
    });
    defer testing.allocator.free(out);
    // +v runs along +z, and cross(+y, +x) is -z.
    for (out) |t| try testing.expectEqual(Tangent{ 1, 0, 0, -1 }, t);
}

test "mirrored UVs flip the sign" {
    const mirrored = [_][2]f32{ .{ 1, 1 }, .{ 0, 1 }, .{ 0, 0 }, .{ 1, 0 } };
    const out = try generate(testing.allocator, .{
        .positions = &quad_positions,
        .normals = &quad_normals,
        .uvs = &mirrored,
        .indices = &quad_indices,
    });
    defer testing.allocator.free(out);
    for (out) |t| try testing.expectEqual(Tangent{ -1, 0, 0, 1 }, t);
}

test "malformed input is refused by name" {
    const base: Input = .{ .positions = &quad_positions, .normals = &quad_normals, .uvs = &quad_uvs, .indices = &quad_indices };
    var input = base;
    input.normals = quad_normals[0..3];
    try testing.expectError(error.StreamLengthMismatch, generate(testing.allocator, input));
    input = base;
    input.indices = quad_indices[0..4];
    try testing.expectError(error.InvalidIndexCount, generate(testing.allocator, input));
    input.indices = &.{};
    try testing.expectError(error.InvalidIndexCount, generate(testing.allocator, input));
    input = base;
    input.indices = &.{ 0, 1, 4 };
    try testing.expectError(error.IndexOutOfRange, generate(testing.allocator, input));

    var positions = quad_positions;
    positions[2][1] = std.math.inf(f32);
    input = base;
    input.positions = &positions;
    try testing.expectError(error.NonFinitePosition, generate(testing.allocator, input));
    var normals = quad_normals;
    normals[1][0] = std.math.nan(f32);
    input = base;
    input.normals = &normals;
    try testing.expectError(error.NonFiniteNormal, generate(testing.allocator, input));
    var uvs = quad_uvs;
    uvs[3][1] = std.math.nan(f32);
    input = base;
    input.uvs = &uvs;
    try testing.expectError(error.NonFiniteTexcoord, generate(testing.allocator, input));
}

test "every allocation failure is refused cleanly" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            const out = try generate(gpa, .{ .positions = &quad_positions, .normals = &quad_normals, .uvs = &quad_uvs, .indices = &quad_indices });
            gpa.free(out);
        }
    }.run, .{});
}

/// One corpus case: `<name>.mesh` (written by the corpus script) and `<name>.tangents`
/// (written by the reference from it).
const corpus = [_][]const u8{
    "quad",
    "grid",
    "cube",
    "sphere",
    "mirror",
    "collapsed_uv",
    "soup",
    "unwelded",
    "torus",
    "degenerate",
    "all_degenerate",
    "butterfly",
    "parallel",
};

fn corpusBytes(comptime name: []const u8, comptime ext: []const u8) []const u8 {
    return @embedFile("testdata/tangents/" ++ name ++ ext);
}

test "ADR-0086: every corpus tangent is bit-equal to the reference's" {
    inline for (corpus) |name| {
        const mesh = corpusBytes(name, ".mesh");
        const expected = corpusBytes(name, ".tangents");

        const vertex_count = std.mem.readInt(u32, mesh[0..4], .little);
        const index_count = std.mem.readInt(u32, mesh[4..8], .little);
        var at: usize = 8;
        const positions = std.mem.bytesAsSlice([3]f32, mesh[at..][0 .. vertex_count * 12]);
        at += vertex_count * 12;
        const normals = std.mem.bytesAsSlice([3]f32, mesh[at..][0 .. vertex_count * 12]);
        at += vertex_count * 12;
        const uvs = std.mem.bytesAsSlice([2]f32, mesh[at..][0 .. vertex_count * 8]);
        at += vertex_count * 8;
        const indices = try testing.allocator.alloc(u32, index_count);
        defer testing.allocator.free(indices);
        for (indices, 0..) |*index, i| index.* = std.mem.readInt(u32, mesh[at + i * 4 ..][0..4], .little);
        at += index_count * 4;
        try testing.expectEqual(mesh.len, at);
        try testing.expectEqual(@as(usize, index_count) * 16, expected.len);

        const out = try generate(testing.allocator, .{ .positions = positions, .normals = normals, .uvs = uvs, .indices = indices });
        defer testing.allocator.free(out);
        for (out, 0..) |tangent, corner| {
            for (0..4) |c| {
                const want = std.mem.readInt(u32, expected[corner * 16 + c * 4 ..][0..4], .little);
                const got: u32 = @bitCast(tangent[c]);
                if (want != got) {
                    std.debug.print("{s}: corner {d} component {d}: 0x{x:0>8}, the reference's 0x{x:0>8}\n", .{ name, corner, c, got, want });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}
