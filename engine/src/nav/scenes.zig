//! Hand-made test geometry: floors, boxes and ramps, as one source (`navigation.md` §11).
//! Tests only.

const std = @import("std");
const core = @import("core");
const input = @import("input.zig");

const Source = input.Source;
const Vec3 = core.math.Vec3;

pub const Scene = struct {
    positions: [1024]Vec3 = undefined,
    indices: [4096]u32 = undefined,
    position_count: usize = 0,
    index_count: usize = 0,
    one: [1]Source = undefined,

    /// The scene as a single source at the identity pose.
    pub fn sources(self: *Scene) []const Source {
        self.one[0] = .{ .positions = self.positions[0..self.position_count], .indices = self.indices[0..self.index_count] };
        return &self.one;
    }

    fn vertex(self: *Scene, p: Vec3) u32 {
        self.positions[self.position_count] = p;
        self.position_count += 1;
        return @intCast(self.position_count - 1);
    }

    fn triangle(self: *Scene, a: u32, b: u32, c: u32) void {
        self.indices[self.index_count..][0..3].* = .{ a, b, c };
        self.index_count += 3;
    }

    fn quad(self: *Scene, a: Vec3, b: Vec3, c: Vec3, d: Vec3) void {
        const i = self.vertex(a);
        _ = self.vertex(b);
        _ = self.vertex(c);
        _ = self.vertex(d);
        self.triangle(i, i + 1, i + 2);
        self.triangle(i, i + 2, i + 3);
    }

    /// A horizontal rectangle at `min.y`, facing up, or wound the other way.
    pub fn floor(self: *Scene, min: Vec3, max: Vec3, reversed: bool) void {
        const y = min.y;
        const a: Vec3 = .init(min.x, y, min.z);
        const b: Vec3 = .init(min.x, y, max.z);
        const c: Vec3 = .init(max.x, y, max.z);
        const d: Vec3 = .init(max.x, y, min.z);
        if (reversed) self.quad(a, d, c, b) else self.quad(a, b, c, d);
    }

    /// A closed box, faces outward.
    pub fn box(self: *Scene, min: Vec3, max: Vec3) void {
        const p = [8]Vec3{
            .init(min.x, min.y, min.z), .init(max.x, min.y, min.z), .init(max.x, max.y, min.z), .init(min.x, max.y, min.z),
            .init(min.x, min.y, max.z), .init(max.x, min.y, max.z), .init(max.x, max.y, max.z), .init(min.x, max.y, max.z),
        };
        self.quad(p[3], p[7], p[6], p[2]); // top
        self.quad(p[0], p[1], p[5], p[4]); // bottom
        self.quad(p[0], p[4], p[7], p[3]); // −X
        self.quad(p[1], p[2], p[6], p[5]); // +X
        self.quad(p[0], p[3], p[2], p[1]); // −Z
        self.quad(p[4], p[5], p[6], p[7]); // +Z
    }

    /// A surface `width` wide on X, `length` long along its slope, rising toward +Z from
    /// `base` at `degrees`.
    pub fn ramp(self: *Scene, base: Vec3, width: f32, length: f32, degrees: f32) void {
        const angle = degrees * std.math.pi / 180.0;
        const run = length * @cos(angle);
        const rise = length * @sin(angle);
        self.quad(base, base.add(.init(0, rise, run)), base.add(.init(width, rise, run)), base.add(.init(width, 0, 0)));
    }
};
