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

    /// `collision3d.md` §10.2's course, as boxes and ramps on a 6 m floor with a west wall: four
    /// 0.15 m rises of 0.30 m to a 1 m platform 0.60 m up, a 25° ramp down from it, and a 55°
    /// ramp against the wall.
    pub fn course(self: *Scene) void {
        self.floor(.init(0, 0, 0), .init(6, 0, 6), false);
        self.box(.init(-0.2, 0, 0), .init(0, 2, 6));
        // Three step boxes and the platform: the fourth rise reaches it.
        for (0..3) |k| {
            const x0 = 1.3 + 0.3 * @as(f32, @floatFromInt(k));
            self.box(.init(x0, 0, 2), .init(x0 + 0.3, 0.15 * @as(f32, @floatFromInt(k + 1)), 3));
        }
        self.box(.init(2.2, 0, 2), .init(3.2, 0.6, 3));
        // 25° down from the platform's −Z edge: 0.6 m of rise over 1.287 m of run.
        const walkable = 0.6 / @sin(25.0 * std.math.pi / 180.0);
        self.ramp(.init(2.2, 0, 2 - walkable * @cos(25.0 * std.math.pi / 180.0)), 1, walkable, 25);
        self.ramp(.init(0, 0, 4.2), 1, 1.5, 55);
    }

    /// A level the size of the court: a 30 m by 20 m yard walled round, a low wall across it, a
    /// pit, a ledge and a ramp to it, and a few boxes.
    pub fn yard(self: *Scene) void {
        self.floor(.init(0, 0, 0), .init(30, 0, 9), false);
        self.floor(.init(0, 0, 11), .init(30, 0, 20), false);
        self.floor(.init(0, 0, 9), .init(12, 0, 11), false);
        self.floor(.init(14, 0, 9), .init(30, 0, 11), false);
        self.floor(.init(12, -2, 9), .init(14, -2, 11), false);
        self.box(.init(-0.5, 0, -0.5), .init(0, 3, 20.5));
        self.box(.init(30, 0, -0.5), .init(30.5, 3, 20.5));
        self.box(.init(0, 0, -0.5), .init(30, 3, 0));
        self.box(.init(0, 0, 20), .init(30, 3, 20.5));
        self.box(.init(4, 0, 14), .init(20, 0.8, 14.4));
        // A ledge 1.2 m up, and a 25° ramp rising to its −Z face.
        self.box(.init(22, 0, 8), .init(28, 1.2, 12));
        const length = 1.2 / @sin(25.0 * std.math.pi / 180.0);
        self.ramp(.init(22, 0, 8 - length * @cos(25.0 * std.math.pi / 180.0)), 2, length, 25);
        for (0..5) |k| {
            const x = 3 + 4.5 * @as(f32, @floatFromInt(k));
            self.box(.init(x, 0, 4), .init(x + 1, 1, 5));
        }
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
