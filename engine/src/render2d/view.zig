//! Views: the several spaces one frame is drawn in.
//!
//! A frame is not all one space. Statistics have to sit still while the camera moves, a
//! minimap looks at the world from somewhere else, and a mod's overlay is neither. So the
//! renderer holds a small table of views for the frame and a draw is recorded against
//! whichever one is current.
//!
//! **Deliberately not a two-valued `space` flag, and deliberately not a field on
//! `Sprite`.** A flag answers M2 and nothing after it: a parallax layer, a split screen, a
//! minimap and a mod's overlay are all *spaces*, and none of them is "screen". A field
//! would also have to be copied onto `TextOptions` and onto every draw struct that ever
//! exists, and would still carry two values. A table costs one indirection and answers all
//! of it — and a mod can add an entry the way a mod can add anything else (I6).

const std = @import("std");
const core = @import("core");
const rhi = @import("rhi");

const camera_mod = @import("camera.zig");

const Camera2D = camera_mod.Camera2D;
const Mat4 = core.math.Mat4;
const Rect = core.math.Rect;

/// Which way `+y` points in a space.
///
/// The world is Y-up and the screen is Y-down, and that disagreement is not an accident to
/// be papered over: a world where up is up matches the maths, and a screen where down is
/// down matches the mouse. What it costs is that **a quad has to know which space it is
/// being built in** — a texture's top row belongs at the smaller `y` in one and the larger
/// `y` in the other, and getting it wrong draws everything upside down.
pub const YAxis = enum { up, down };

pub const Error = error{
    /// A view id this frame does not have.
    InvalidView,
    /// More views than `max_views` in one frame.
    TooManyViews,
};

/// How many views one frame may hold.
///
/// A bound rather than a guess: `addView` is reachable from a mod, and a loop that added
/// one per entity would otherwise grow the table until the frame ran out of memory. Sixty
/// four is far past any real use — split screen for four players with a minimap and an
/// overlay each is twelve — and the failure is a clean error rather than a slow death.
pub const max_views: usize = 64;

/// Which space a draw is expressed in.
///
/// Non-exhaustive: `world` and `screen` always exist, and `addView` returns further ids.
/// `world` is 0 and `screen` is 1 so that the default view is the zero value and a
/// zero-initialised draw list means what it looks like it means.
pub const ViewId = enum(u16) {
    /// World units, through the frame's camera. The default.
    world = 0,
    /// Screen points, origin at the top-left, **+Y down** — the same units and direction
    /// as mouse input, so a HUD is placed where the pointer is measured.
    screen = 1,
    _,

    pub fn index(self: ViewId) usize {
        return @intFromEnum(self);
    }

    pub fn fromIndex(i: usize) ViewId {
        return @enumFromInt(@as(u16, @intCast(i)));
    }
};

/// What a caller says when adding a view.
pub const ViewDesc = union(enum) {
    /// World units through a 2D camera. Its `viewport` is the rectangle it draws into.
    camera: Camera2D,
    /// Screen points, origin at the top-left of the rectangle, +Y down.
    ///
    /// A `Rect` rather than a `Camera2D` with rotation zero, because a screen space that
    /// could be rotated and zoomed is a world space wearing a hat: the whole value of this
    /// one is that a point in it is a point on the display and stays there.
    screen: Rect,
};

/// A view, resolved. What the recorder binds.
pub const View = struct {
    /// The transform, ready for the shader's inline constants.
    view_projection: Mat4,
    /// Which way `+y` points here. Read by `writeQuad` and by text layout; see `YAxis`.
    y_axis: YAxis,
    /// The rectangle to draw into, in **pixels** — `Rect` is in points, and the GPU
    /// viewport is not. `FrameView.pixel_scale` is the one number that bridges them.
    viewport: rhi.Viewport,

    /// Resolves a description at the frame's pixel scale.
    pub fn resolve(desc: ViewDesc, pixel_scale: f32) camera_mod.CameraError!View {
        if (!std.math.isFinite(pixel_scale) or pixel_scale <= 0) return error.InvalidCamera;

        switch (desc) {
            .camera => |cam| {
                try cam.validate();
                return .{
                    .view_projection = try cam.viewProjection(),
                    .y_axis = .up,
                    .viewport = scaled(cam.viewport, pixel_scale),
                };
            },
            .screen => |area| {
                // The same conditions `Camera2D.validate` refuses, for the same reason:
                // this rectangle can come from a window size, a settings file or a mod.
                if (!(area.w > 0) or !(area.h > 0)) return error.InvalidCamera;
                if (!std.math.isFinite(area.x) or !std.math.isFinite(area.y)) {
                    return error.InvalidCamera;
                }
                if (!std.math.isFinite(area.w) or !std.math.isFinite(area.h)) {
                    return error.InvalidCamera;
                }
                return .{
                    .view_projection = screenProjection(area),
                    .y_axis = .down,
                    .viewport = scaled(area, pixel_scale),
                };
            },
        }
    }

    fn scaled(area: Rect, pixel_scale: f32) rhi.Viewport {
        return .{
            .x = area.x * pixel_scale,
            .y = area.y * pixel_scale,
            .width = area.w * pixel_scale,
            .height = area.h * pixel_scale,
        };
    }
};

/// Screen points to clip space: `area`'s top-left maps to the top-left of the viewport.
///
/// The Y flip is expressed by passing `bottom` **below** `top` — which is what those
/// parameters are for — rather than by a sign somewhere. `camera.orthographic` already
/// knows which way the clip space points (`rhi.clip_space`), so this file does not have to.
pub fn screenProjection(area: Rect) Mat4 {
    return camera_mod.orthographic(
        area.x,
        area.x + area.w,
        area.y + area.h, // bottom, which in screen space is the larger y
        area.y, // top
        0,
        1,
    );
}

const testing = std.testing;

fn clipOf(m: Mat4, x: f32, y: f32) core.math.Vec2 {
    const v = m.mulVec4(.{ .x = x, .y = y, .z = 0, .w = 1 });
    return .{ .x = v.x, .y = v.y };
}

test "screen space puts the origin at the top-left and grows downward" {
    const m = screenProjection(.init(0, 0, 800, 600));

    // (0, 0) is the top-left of the viewport: clip x = -1, and clip y = +1 because clip
    // space is Y-up while screen space is Y-down. That flip is the whole point.
    const top_left = clipOf(m, 0, 0);
    try testing.expectApproxEqAbs(@as(f32, -1), top_left.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), top_left.y, 1e-5);

    const bottom_right = clipOf(m, 800, 600);
    try testing.expectApproxEqAbs(@as(f32, 1), bottom_right.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, -1), bottom_right.y, 1e-5);

    const centre = clipOf(m, 400, 300);
    try testing.expectApproxEqAbs(@as(f32, 0), centre.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), centre.y, 1e-5);
}

test "screen space is measured in the same units as mouse input" {
    // The property that makes a HUD placeable: a point given to `screen` lands where the
    // pointer at that position lands, so `input.mouse.position` can be drawn at directly.
    const area: Rect = .init(0, 0, 1280, 720);
    const m = screenProjection(area);

    // A quarter across and a quarter down, in points.
    const p = clipOf(m, 320, 180);
    try testing.expectApproxEqAbs(@as(f32, -0.5), p.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), p.y, 1e-5);
}

test "an offset area shifts the origin without changing the scale" {
    const m = screenProjection(.init(100, 50, 400, 200));

    const origin = clipOf(m, 100, 50);
    try testing.expectApproxEqAbs(@as(f32, -1), origin.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), origin.y, 1e-5);

    const far = clipOf(m, 500, 250);
    try testing.expectApproxEqAbs(@as(f32, 1), far.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, -1), far.y, 1e-5);
}

test "the GPU viewport is in pixels and the area is in points" {
    // The one number that bridges them is `pixel_scale`, and getting it wrong on a Retina
    // display draws the HUD into a quarter of the window.
    const view = try View.resolve(.{ .screen = .init(0, 0, 1280, 720) }, 2);
    try testing.expectApproxEqAbs(@as(f32, 2560), view.viewport.width, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1440), view.viewport.height, 1e-5);

    const one_to_one = try View.resolve(.{ .screen = .init(0, 0, 1280, 720) }, 1);
    try testing.expectApproxEqAbs(@as(f32, 1280), one_to_one.viewport.width, 1e-5);
}

test "a camera view is the camera's own projection and viewport" {
    const cam: Camera2D = .{ .viewport = .init(0, 0, 800, 600), .zoom = 2 };
    const view = try View.resolve(.{ .camera = cam }, 1);

    const expected = try cam.viewProjection();
    try testing.expectEqualSlices([4]f32, &expected.cols, &view.view_projection.cols);
    try testing.expectApproxEqAbs(@as(f32, 800), view.viewport.width, 1e-5);
}

test "a view that cannot be drawn is refused rather than asserted" {
    // Every one of these can arrive from a window size, a settings file or a mod.
    try testing.expectError(error.InvalidCamera, View.resolve(.{ .screen = .init(0, 0, 0, 600) }, 1));
    try testing.expectError(error.InvalidCamera, View.resolve(.{ .screen = .init(0, 0, 800, -1) }, 1));
    try testing.expectError(
        error.InvalidCamera,
        View.resolve(.{ .screen = .init(std.math.nan(f32), 0, 800, 600) }, 1),
    );
    try testing.expectError(error.InvalidCamera, View.resolve(.{
        .camera = .{ .viewport = .init(0, 0, 800, 600), .zoom = 0 },
    }, 1));
    // And a pixel scale of zero, which would collapse the viewport to nothing.
    try testing.expectError(error.InvalidCamera, View.resolve(.{ .screen = .init(0, 0, 8, 6) }, 0));
}

test "world is view zero and screen is view one" {
    // Not decoration: `world` being the zero value is what makes the default view the one
    // a caller who has never heard of views expects.
    try testing.expectEqual(@as(usize, 0), ViewId.world.index());
    try testing.expectEqual(@as(usize, 1), ViewId.screen.index());
    try testing.expectEqual(ViewId.screen, ViewId.fromIndex(1));
    // Ids past the named ones are ordinary values of the same type.
    try testing.expectEqual(@as(usize, 7), ViewId.fromIndex(7).index());
}

test "a camera space is Y-up and a screen space is Y-down" {
    // Not a detail: it is what tells `writeQuad` which corner of a quad the texture's top
    // row belongs to, and getting it wrong draws every sprite and every glyph inverted.
    const cam = try View.resolve(.{ .camera = .{ .viewport = .init(0, 0, 8, 6) } }, 1);
    try testing.expectEqual(YAxis.up, cam.y_axis);

    const screen = try View.resolve(.{ .screen = .init(0, 0, 8, 6) }, 1);
    try testing.expectEqual(YAxis.down, screen.y_axis);
}
