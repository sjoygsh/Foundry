//! Owned bind streams and conservative posed bounds (animation3d.md §8).
const std = @import("std");
const core = @import("core");
const asset = @import("asset");
const anim = @import("anim");
const frustum = @import("frustum.zig");
const Mat4 = core.math.Mat4;
const Vec3 = core.math.Vec3;
const Allocator = std.mem.Allocator;

pub const Bind = struct {
    positions: [][3]f32,
    normals: ?[][3]f32 = null,
    tangents: ?[][4]f32 = null,
    joints: [][4]u8,
    weights: [][4]f32,
    bounds: []asset.MeshAabb,

    pub fn init(gpa: Allocator, mesh: asset.Mesh) !Bind {
        const positions = try copyStream([3]f32, gpa, mesh, .position);
        errdefer gpa.free(positions);
        const joints = try copyStream([4]u8, gpa, mesh, .joints);
        errdefer gpa.free(joints);
        const weights = try copyStream([4]f32, gpa, mesh, .weights);
        errdefer gpa.free(weights);
        try anim.validateInfluences(joints, weights, mesh.joint_bounds.len);
        const bounds = try gpa.alloc(asset.MeshAabb, mesh.joint_bounds.len);
        errdefer gpa.free(bounds);
        for (bounds, mesh.joint_bounds) |*out, box| out.* = box;
        const normals = if (has(mesh, .normal)) try copyStream([3]f32, gpa, mesh, .normal) else null;
        errdefer if (normals) |values| gpa.free(values);
        const tangents = if (has(mesh, .tangent)) try copyStream([4]f32, gpa, mesh, .tangent) else null;
        return .{ .positions = positions, .joints = joints, .weights = weights, .bounds = bounds, .normals = normals, .tangents = tangents };
    }

    pub fn deinit(self: Bind, gpa: Allocator) void {
        gpa.free(self.positions);
        gpa.free(self.joints);
        gpa.free(self.weights);
        gpa.free(self.bounds);
        if (self.normals) |values| gpa.free(values);
        if (self.tangents) |values| gpa.free(values);
    }

    pub fn input(self: Bind) anim.skinning.Input {
        return .{ .positions = self.positions, .normals = self.normals, .tangents = self.tangents, .joints = self.joints, .weights = self.weights };
    }
};

fn has(mesh: asset.Mesh, semantic: asset.MeshSemantic) bool {
    for (mesh.streams) |stream| if (stream.semantic == semantic) return true;
    return false;
}

fn copyStream(comptime T: type, gpa: Allocator, mesh: asset.Mesh, semantic: asset.MeshSemantic) ![]T {
    for (mesh.streams) |stream| if (stream.semantic == semantic) {
        const out = try gpa.alloc(T, mesh.vertex_count);
        // Runtime stream bytes may be unaligned; copy into typed owned storage.
        @memcpy(std.mem.sliceAsBytes(out), stream.bytes);
        return out;
    };
    return error.MissingStream;
}

pub fn validate(matrices: []const Mat4, count: usize) error{ InvalidSkinCount, InvalidSkinMatrix }!void {
    if (matrices.len != count) return error.InvalidSkinCount;
    for (matrices) |matrix| {
        for (matrix.cols) |column| for (column) |value| if (!std.math.isFinite(value)) return error.InvalidSkinMatrix;
        if (matrix.cols[0][3] != 0 or matrix.cols[1][3] != 0 or matrix.cols[2][3] != 0 or matrix.cols[3][3] != 1) return error.InvalidSkinMatrix;
    }
}

pub fn posedBounds(boxes: []const asset.MeshAabb, matrices: []const Mat4, world: Mat4) frustum.Bounds {
    var lo = Vec3.init(std.math.inf(f32), std.math.inf(f32), std.math.inf(f32));
    var hi = lo.scale(-1);
    for (boxes, matrices) |box, matrix| for (0..8) |corner| {
        const p = matrix.mulPoint(.init(if (corner & 1 == 0) box.min.x else box.max.x, if (corner & 2 == 0) box.min.y else box.max.y, if (corner & 4 == 0) box.min.z else box.max.z));
        // Weights accepted at 1 ± tolerance need not be exactly normalized. The kernel
        // weights translation too; world placement is applied only after that scaling.
        for ([_]f32{ 1 - anim.skinning.weight_sum_tolerance, 1 + anim.skinning.weight_sum_tolerance }) |sum| {
            const q = world.mulPoint(p.scale(sum));
            if (!q.isFinite()) return .{ .center = .zero, .extent = .init(std.math.inf(f32), std.math.inf(f32), std.math.inf(f32)) };
            lo = .init(@min(lo.x, q.x), @min(lo.y, q.y), @min(lo.z, q.z));
            hi = .init(@max(hi.x, q.x), @max(hi.y, q.y), @max(hi.z, q.z));
        }
    };
    const padding = @max(1, @max(@max(@abs(lo.x), @abs(lo.y)), @max(@abs(lo.z), @max(@max(@abs(hi.x), @abs(hi.y)), @abs(hi.z))))) * 1e-5;
    return .{ .center = lo.scale(0.5).add(hi.scale(0.5)), .extent = hi.scale(0.5).sub(lo.scale(0.5)).add(.init(padding, padding, padding)) };
}

pub const Write = struct {
    input: anim.skinning.Input,
    matrices: []const Mat4,
    output: anim.skinning.Output,

    pub fn chunk(self: *const Write, range: core.jobs.Chunk) void {
        anim.skin(self.input, self.matrices, range.begin, range.end, self.output);
    }
};

pub const grain: u32 = 1024;
