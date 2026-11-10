//! A vector of three f64s, for the few routines that take f32 points and must not lose their
//! last bits between: the hull builder and the closed forms. The difference of two f32s is
//! exact in f64, so these routines round once, at the end.
const core = @import("core");
const Vec3 = core.math.Vec3;

pub const D3 = struct {
    x: f64,
    y: f64,
    z: f64,

    pub fn of(p: Vec3) D3 {
        return .{ .x = p.x, .y = p.y, .z = p.z };
    }
    /// Rounded to f32.
    pub fn vec(a: D3) Vec3 {
        return .init(@floatCast(a.x), @floatCast(a.y), @floatCast(a.z));
    }
    pub fn add(a: D3, b: D3) D3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }
    pub fn sub(a: D3, b: D3) D3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }
    pub fn dot(a: D3, b: D3) f64 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
    pub fn cross(a: D3, b: D3) D3 {
        return .{ .x = a.y * b.z - a.z * b.y, .y = a.z * b.x - a.x * b.z, .z = a.x * b.y - a.y * b.x };
    }
    pub fn scale(a: D3, s: f64) D3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }
};
