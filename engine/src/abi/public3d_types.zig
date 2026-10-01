//! Plain C values for M25 public3d.md §5–§9. Explicit padding, no engine layouts.
const types = @import("types.zig");
pub const Instance = types.Opaque("3D instance");
pub const Light = types.Opaque("3D light");
pub const Body3D = types.Opaque("3D body");
pub const Character = types.Opaque("3D character");
pub const Vec3 = extern struct {
    x: f32,
    y: f32,
    z: f32,
};
pub const Quat = extern struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,
};
pub const Mat4 = extern struct {
    elements: [16]f32,
};
pub const Transform = extern struct {
    translation: Vec3,
    rotation: Quat,
    scale: Vec3,
};
pub const Pose3D = extern struct {
    position: Vec3,
    rotation: Quat,
};
pub const Camera3D = extern struct {
    position: Vec3,
    rotation: Quat,
    fov_y: f32,
    near: f32,
    far: f32,
    width: u32,
    height: u32,
};
pub const Light3D = extern struct {
    kind: i32,
    color: Vec3,
    intensity: f32,
    range: f32,
    inner_cone: f32,
    outer_cone: f32,
    position: Vec3,
    rotation: Quat,
    casts_shadow: types.Bool,
    reserved: [3]u8,
};
pub const Shape3D = extern struct {
    kind: i32,
    radius: f32,
    half_height: f32,
    half_extents: Vec3,
};
pub const Filter3D = extern struct {
    mask: u32,
    reserved: u32,
    ignore: Body3D,
};
pub const Body3DDesc = extern struct {
    shape: Shape3D,
    pose: Pose3D,
    kind: i32,
    layer: u32,
    mask: u32,
    user: u64,
};
pub const RayHit3D = extern struct {
    distance: f32,
    point: Vec3,
    normal: Vec3,
    surface_normal: Vec3,
    body: Body3D,
    user: u64,
    triangle: u32,
    started_inside: types.Bool,
    reserved: [3]u8,
};
pub const Hit3D = extern struct {
    fraction: f32,
    point: Vec3,
    normal: Vec3,
    surface_normal: Vec3,
    body: Body3D,
    user: u64,
    triangle: u32,
    started_inside: types.Bool,
    reserved: [3]u8,
};
pub const Overlap3D = extern struct {
    body: Body3D,
    user: u64,
    triangle: u32,
    reserved: u32,
};
pub const CharacterConfig = extern struct {
    radius: f32,
    height: f32,
    max_slope: f32,
    step_height: f32,
    snap_distance: f32,
    max_move: f32,
    layer: u32,
    mask: u32,
};
pub const CharacterMove = extern struct {
    feet: Vec3,
    ground_normal: Vec3,
    ground_body: Body3D,
    ground_user: u64,
    ground_triangle: u32,
    walls: u32,
    stepped: f32,
    grounded: types.Bool,
    ceiling: types.Bool,
    snapped: types.Bool,
    depenetrated: types.Bool,
    stuck: types.Bool,
    reserved: [7]u8,
};
