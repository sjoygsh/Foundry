//! The 2D camera, and the projection that reaches clip space.

const std = @import("std");
const core = @import("core");
const rhi = @import("rhi");

const Mat4 = core.math.Mat4;
const Vec2 = core.math.Vec2;
const Vec3 = core.math.Vec3;
const Rect = core.math.Rect;

pub const CameraError = error{InvalidCamera};

/// Where the world is looked at from.
///
/// Coordinate spaces, which are never conflated (`docs/design/render2d.md` §4):
///
/// * **World** — the game's own units, **+Y up**.
/// * **Screen** — pixels, origin at the window's top-left, **+Y down**, which is what
///   `platform` reports for the mouse and the window.
/// * **Clip** — what the GPU consumes, defined by `rhi.clip_space`.
///
/// World Y-up and screen Y-down are not in tension; the projection is what bridges them,
/// and writing both down is why that stays true.
pub const Camera2D = struct {
    /// The world point at the centre of the viewport.
    center: Vec2 = .zero,
    /// **Pixels per world unit.** Larger is closer. This orientation, rather than its
    /// reciprocal, because it is the number a 2D game actually reasons about: a 16-unit
    /// sprite that should be 64 pixels across means a zoom of 4.
    zoom: f32 = 1,
    /// Radians, counter-clockwise, about `center`.
    rotation: f32 = 0,
    /// The pixel rectangle drawn into, in screen space. Usually the whole window.
    viewport: Rect,

    /// A camera can come from a settings file or a mod, so it is validated rather than
    /// asserted (CLAUDE.md §7).
    pub fn validate(self: Camera2D) CameraError!void {
        if (!std.math.isFinite(self.zoom) or self.zoom <= 0) return error.InvalidCamera;
        if (!std.math.isFinite(self.rotation)) return error.InvalidCamera;
        if (!std.math.isFinite(self.center.x) or !std.math.isFinite(self.center.y)) {
            return error.InvalidCamera;
        }
        if (!(self.viewport.w > 0) or !(self.viewport.h > 0)) return error.InvalidCamera;
    }

    /// World space to clip space, ready for the shader.
    pub fn viewProjection(self: Camera2D) CameraError!Mat4 {
        try self.validate();
        const half_w = self.viewport.w / 2;
        const half_h = self.viewport.h / 2;

        // Read right to left: put the camera's centre at the origin, undo its rotation,
        // scale world units into pixels, then map the viewport's pixel extent to clip.
        const view = Mat4.mul(
            Mat4.scaling(Vec3.init(self.zoom, self.zoom, 1)),
            Mat4.mul(
                Mat4.rotationZ(-self.rotation),
                Mat4.translation(Vec3.init(-self.center.x, -self.center.y, 0)),
            ),
        );
        return Mat4.mul(orthographic(-half_w, half_w, -half_h, half_h, 0, 1), view);
    }

    /// Screen pixels to world units. Exact, and the answer to "what did I click".
    pub fn screenToWorld(self: Camera2D, screen: Vec2) Vec2 {
        // Viewport-relative, centre origin, and flipped into Y-up.
        const px = screen.x - (self.viewport.x + self.viewport.w / 2);
        const py = -(screen.y - (self.viewport.y + self.viewport.h / 2));

        const inv_zoom = 1 / self.zoom;
        const c = @cos(self.rotation);
        const s = @sin(self.rotation);
        const x = px * inv_zoom;
        const y = py * inv_zoom;
        return .{
            .x = self.center.x + (x * c - y * s),
            .y = self.center.y + (x * s + y * c),
        };
    }

    /// World units to screen pixels. The exact inverse of `screenToWorld`.
    pub fn worldToScreen(self: Camera2D, world: Vec2) Vec2 {
        const dx = world.x - self.center.x;
        const dy = world.y - self.center.y;
        const c = @cos(-self.rotation);
        const s = @sin(-self.rotation);
        const x = (dx * c - dy * s) * self.zoom;
        const y = (dx * s + dy * c) * self.zoom;
        return .{
            .x = x + self.viewport.x + self.viewport.w / 2,
            .y = -y + self.viewport.y + self.viewport.h / 2,
        };
    }

    /// The world-space rectangle currently visible. The bounding box when rotated, which
    /// is what culling wants and is never smaller than the truth.
    pub fn visibleBounds(self: Camera2D) Rect {
        const corners = [4]Vec2{
            self.screenToWorld(.{ .x = self.viewport.x, .y = self.viewport.y }),
            self.screenToWorld(.{ .x = self.viewport.x + self.viewport.w, .y = self.viewport.y }),
            self.screenToWorld(.{ .x = self.viewport.x, .y = self.viewport.y + self.viewport.h }),
            self.screenToWorld(.{
                .x = self.viewport.x + self.viewport.w,
                .y = self.viewport.y + self.viewport.h,
            }),
        };
        var min = corners[0];
        var max = corners[0];
        for (corners[1..]) |p| {
            min.x = @min(min.x, p.x);
            min.y = @min(min.y, p.y);
            max.x = @max(max.x, p.x);
            max.y = @max(max.y, p.y);
        }
        return .{ .x = min.x, .y = min.y, .w = max.x - min.x, .h = max.y - min.y };
    }

    // -- movement ------------------------------------------------------------------
    //
    // Two operations, and deliberately only two. Both are *camera maths*: what they do
    // is decided by the projection, and getting either wrong under rotation is subtle.
    // Which key or button drives them is **input policy**, which belongs to the game —
    // and `render2d` could not implement it anyway, since it does not depend on
    // `platform` and the build graph would refuse the import (I7). The layering makes
    // the seam for us.
    //
    // Both take the whole change and validate it before committing, so a refused change
    // leaves the camera exactly as it was rather than half-applied.

    /// Moves the **camera** by a screen-space offset, in the same points as the mouse.
    ///
    /// The camera, not the content: `+x` scrolls the view right, so the world appears to
    /// slide left. A drag that makes the world follow the cursor passes the negated
    /// mouse motion, which is the caller's decision to make.
    ///
    /// Screen space is Y-down and world space is Y-up, and rotation and zoom both apply,
    /// so this is not `center.add(delta)`. It is derived from `screenToWorld` rather than
    /// re-derived, because two routes to the same transform is two things to keep in
    /// step.
    pub fn panByScreen(self: *Camera2D, delta: Vec2) CameraError!void {
        try self.validate();
        if (!std.math.isFinite(delta.x) or !std.math.isFinite(delta.y)) {
            return error.InvalidCamera;
        }

        // The affine part of `screenToWorld`: the difference of two screen points maps
        // to a world vector that does not depend on `center`.
        const world_delta = self.screenToWorld(delta).sub(self.screenToWorld(.zero));

        var next = self.*;
        next.center = self.center.add(world_delta);
        try next.validate();
        self.* = next;
    }

    /// Changes zoom while keeping the world point under `screen_anchor` under it.
    ///
    /// This is what a mouse wheel should do, and what "set `zoom` and hope" does not: a
    /// bare assignment zooms about the viewport's centre, so the thing being examined
    /// slides away from the cursor exactly when it is being looked at closely.
    ///
    /// Implemented by measuring the drift rather than solving for it. Ask what world
    /// point is under the anchor, change the zoom, ask again, and move the centre by the
    /// difference. Correct under rotation and an offset viewport for free, because
    /// `screenToWorld` already is.
    pub fn zoomAround(self: *Camera2D, screen_anchor: Vec2, new_zoom: f32) CameraError!void {
        try self.validate();
        if (!std.math.isFinite(screen_anchor.x) or !std.math.isFinite(screen_anchor.y)) {
            return error.InvalidCamera;
        }
        if (!std.math.isFinite(new_zoom) or new_zoom <= 0) return error.InvalidCamera;

        const before = self.screenToWorld(screen_anchor);

        var next = self.*;
        next.zoom = new_zoom;
        next.center = self.center.add(before.sub(next.screenToWorld(screen_anchor)));
        try next.validate();
        self.* = next;
    }
};

/// Orthographic projection into the clip space `rhi.clip_space` describes.
///
/// This lives here rather than in `core.math` on purpose. `core` is L0 and has consumers
/// that are not renderers; a projection matrix baking in one clip space would be a
/// landmine for every one of them, and `core/math.zig` opens by promising it does not know
/// which way is up.
///
/// It reads the convention instead of hardcoding it, which costs one comptime branch and
/// means a backend that could not conform would be a value change rather than a hunt.
pub fn orthographic(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Mat4 {
    var m = Mat4.identity;

    m.cols[0][0] = 2 / (right - left);
    m.cols[3][0] = -(right + left) / (right - left);

    const y_sign: f32 = switch (rhi.clip_space.y_axis) {
        .up => 1,
        .down => -1,
    };
    m.cols[1][1] = y_sign * 2 / (top - bottom);
    m.cols[3][1] = y_sign * -(top + bottom) / (top - bottom);

    switch (rhi.clip_space.depth_range) {
        .zero_to_one => {
            m.cols[2][2] = 1 / (far - near);
            m.cols[3][2] = -near / (far - near);
        },
        .minus_one_to_one => {
            m.cols[2][2] = 2 / (far - near);
            m.cols[3][2] = -(far + near) / (far - near);
        },
    }

    return m;
}

const testing = std.testing;
const tolerance = 1e-4;

fn project(m: Mat4, x: f32, y: f32) Vec2 {
    const v = m.mulVec4(.{ .x = x, .y = y, .z = 0, .w = 1 });
    return .{ .x = v.x, .y = v.y };
}

test "the projection maps the viewport's world extent onto clip space" {
    const cam: Camera2D = .{ .viewport = .init(0, 0, 800, 600) };
    const vp = try cam.viewProjection();

    // At zoom 1 the visible world is 800x600 units centred on the origin.
    try testing.expectApproxEqAbs(@as(f32, 0), project(vp, 0, 0).x, tolerance);
    try testing.expectApproxEqAbs(@as(f32, 0), project(vp, 0, 0).y, tolerance);
    try testing.expectApproxEqAbs(@as(f32, 1), project(vp, 400, 0).x, tolerance);
    try testing.expectApproxEqAbs(@as(f32, -1), project(vp, -400, 0).x, tolerance);

    // +Y in the world reaches +Y in clip space, which is the whole point of writing the
    // convention down. If this ever inverts, the world renders upside down and nothing
    // else fails.
    try testing.expect(project(vp, 0, 300).y > 0);
    try testing.expectApproxEqAbs(@as(f32, 1), project(vp, 0, 300).y, tolerance);
}

test "zoom is pixels per world unit" {
    const cam: Camera2D = .{ .viewport = .init(0, 0, 800, 600), .zoom = 4 };
    const vp = try cam.viewProjection();
    // At zoom 4, 100 world units is 400 pixels, which is the full half-width.
    try testing.expectApproxEqAbs(@as(f32, 1), project(vp, 100, 0).x, tolerance);
}

test "screen and world round-trip exactly, including under rotation and pan" {
    const cases = [_]Camera2D{
        .{ .viewport = .init(0, 0, 800, 600) },
        .{ .viewport = .init(0, 0, 800, 600), .zoom = 3.5 },
        .{ .viewport = .init(0, 0, 1280, 720), .center = .init(-40, 90), .zoom = 0.25 },
        .{ .viewport = .init(0, 0, 1280, 720), .center = .init(12, -7), .zoom = 2, .rotation = 0.9 },
        // A viewport that is not at the window's origin: the offset must be honoured.
        .{ .viewport = .init(100, 50, 400, 300), .center = .init(5, 5), .zoom = 1.5 },
    };

    for (cases) |cam| {
        for ([_]Vec2{
            .init(0, 0),
            .init(640, 360),
            .init(1279, 719),
            .init(-20, 40),
        }) |screen| {
            const round_trip = cam.worldToScreen(cam.screenToWorld(screen));
            try testing.expectApproxEqAbs(screen.x, round_trip.x, 1e-2);
            try testing.expectApproxEqAbs(screen.y, round_trip.y, 1e-2);
        }
    }
}

test "screen space is Y-down and world space is Y-up" {
    const cam: Camera2D = .{ .viewport = .init(0, 0, 800, 600) };
    // The top-left pixel is up and to the left in the world.
    const top_left = cam.screenToWorld(.init(0, 0));
    try testing.expect(top_left.x < 0);
    try testing.expect(top_left.y > 0);

    // Moving down the screen moves down in the world.
    const lower = cam.screenToWorld(.init(400, 500));
    try testing.expect(lower.y < 0);
}

test "the projection agrees with worldToScreen" {
    // Two independent routes to the same place: the matrix the GPU uses, and the closed
    // form the game uses for picking. They must not drift apart.
    const cam: Camera2D = .{
        .viewport = .init(0, 0, 800, 600),
        .center = .init(10, -5),
        .zoom = 2,
        .rotation = 0.4,
    };
    const vp = try cam.viewProjection();

    for ([_]Vec2{ .init(0, 0), .init(50, 30), .init(-120, 75) }) |world| {
        const clip = project(vp, world.x, world.y);
        // Clip back to pixels, undoing the Y flip the projection applied.
        const from_matrix = Vec2{
            .x = (clip.x + 1) / 2 * cam.viewport.w + cam.viewport.x,
            .y = (1 - clip.y) / 2 * cam.viewport.h + cam.viewport.y,
        };
        const from_closed_form = cam.worldToScreen(world);
        try testing.expectApproxEqAbs(from_matrix.x, from_closed_form.x, 1e-2);
        try testing.expectApproxEqAbs(from_matrix.y, from_closed_form.y, 1e-2);
    }
}

test "an unusable camera is refused, not asserted" {
    // Every one of these can arrive from a settings file or a mod.
    const bad = [_]Camera2D{
        .{ .viewport = .init(0, 0, 800, 600), .zoom = 0 },
        .{ .viewport = .init(0, 0, 800, 600), .zoom = -2 },
        .{ .viewport = .init(0, 0, 800, 600), .zoom = std.math.nan(f32) },
        .{ .viewport = .init(0, 0, 800, 600), .zoom = std.math.inf(f32) },
        .{ .viewport = .init(0, 0, 0, 600) },
        .{ .viewport = .init(0, 0, 800, 0) },
        .{ .viewport = .init(0, 0, 800, 600), .rotation = std.math.nan(f32) },
        .{ .viewport = .init(0, 0, 800, 600), .center = .init(std.math.inf(f32), 0) },
    };
    for (bad) |cam| {
        try testing.expectError(error.InvalidCamera, cam.validate());
        try testing.expectError(error.InvalidCamera, cam.viewProjection());
    }
}

test "visible bounds cover the viewport and grow when rotated" {
    const straight: Camera2D = .{ .viewport = .init(0, 0, 800, 600), .zoom = 1 };
    const bounds = straight.visibleBounds();
    try testing.expectApproxEqAbs(@as(f32, 800), bounds.w, 1e-2);
    try testing.expectApproxEqAbs(@as(f32, 600), bounds.h, 1e-2);

    var turned = straight;
    turned.rotation = std.math.pi / 4.0;
    const turned_bounds = turned.visibleBounds();
    try testing.expect(turned_bounds.w > bounds.w);
    try testing.expect(turned_bounds.h > bounds.h);
}

test "panning by a screen delta moves the camera in screen terms, not world terms" {
    var cam: Camera2D = .{ .viewport = .init(0, 0, 800, 600), .zoom = 2 };

    // 100 points right is 50 world units right, because zoom is pixels per world unit.
    try cam.panByScreen(.init(100, 0));
    try testing.expectApproxEqAbs(@as(f32, 50), cam.center.x, tolerance);
    try testing.expectApproxEqAbs(@as(f32, 0), cam.center.y, tolerance);

    // Screen Y is down and world Y is up, so panning down the screen lowers the camera.
    try cam.panByScreen(.init(0, 100));
    try testing.expectApproxEqAbs(@as(f32, -50), cam.center.y, tolerance);
}

test "panning is exact in screen space, whatever the camera is doing" {
    // The property that matters at the call site: panning the camera by `delta` slides
    // the world the other way, so whatever was under a pixel is now under that pixel
    // *minus* `delta`. It has to hold under rotation, off-origin viewports and extreme
    // zoom, which is where a hand-rolled `center.add(delta)` stops being right.
    const cases = [_]Camera2D{
        .{ .viewport = .init(0, 0, 800, 600) },
        .{ .viewport = .init(0, 0, 800, 600), .zoom = 0.05 },
        .{ .viewport = .init(120, 40, 500, 500), .center = .init(-9, 3), .zoom = 7 },
        .{ .viewport = .init(0, 0, 1280, 720), .center = .init(60, -20), .zoom = 1.7, .rotation = 1.1 },
        .{ .viewport = .init(0, 0, 1280, 720), .rotation = -2.4, .zoom = 0.3 },
    };
    const deltas = [_]Vec2{ .init(37, 0), .init(0, -18), .init(-120, 64), .init(0.5, 0.5) };

    for (cases) |start| {
        for (deltas) |delta| {
            const probe: Vec2 = .init(310, 205);
            const before = start.screenToWorld(probe);

            var cam = start;
            try cam.panByScreen(delta);

            const after = cam.screenToWorld(.{ .x = probe.x - delta.x, .y = probe.y - delta.y });
            try testing.expectApproxEqAbs(before.x, after.x, 1e-2);
            try testing.expectApproxEqAbs(before.y, after.y, 1e-2);
        }
    }
}

test "zooming about a point keeps that point under the cursor" {
    // The whole reason `zoomAround` exists. If this fails, zooming in on something makes
    // it slide off the screen.
    const cases = [_]Camera2D{
        .{ .viewport = .init(0, 0, 800, 600) },
        .{ .viewport = .init(0, 0, 1280, 720), .center = .init(-140, 260), .zoom = 3 },
        .{ .viewport = .init(64, 32, 900, 400), .center = .init(11, -4), .zoom = 0.4, .rotation = 0.7 },
    };
    const anchors = [_]Vec2{ .init(0, 0), .init(200, 150), .init(799, 599) };
    const zooms = [_]f32{ 0.01, 0.5, 1, 2.5, 64 };

    for (cases) |start| {
        for (anchors) |anchor| {
            const pinned = start.screenToWorld(anchor);
            for (zooms) |z| {
                var cam = start;
                try cam.zoomAround(anchor, z);
                try testing.expectApproxEqAbs(z, cam.zoom, tolerance);

                const still_there = cam.screenToWorld(anchor);
                // Scaled tolerance: at zoom 0.01 one pixel *is* a hundred world units,
                // so an absolute world tolerance would be meaningless. The test is
                // "within a pixel of where it was", which is what the user sees.
                const slack = @max(1e-2, 1 / z);
                try testing.expectApproxEqAbs(pinned.x, still_there.x, slack);
                try testing.expectApproxEqAbs(pinned.y, still_there.y, slack);
            }
        }
    }
}

test "zooming about the viewport centre leaves the centre alone" {
    var cam: Camera2D = .{ .viewport = .init(0, 0, 800, 600), .center = .init(25, -8) };
    try cam.zoomAround(.init(400, 300), 5);
    try testing.expectApproxEqAbs(@as(f32, 25), cam.center.x, tolerance);
    try testing.expectApproxEqAbs(@as(f32, -8), cam.center.y, tolerance);
}

test "a refused move leaves the camera exactly as it was" {
    // Every one of these can arrive from a mod, a settings file or a device that reported
    // nonsense. None of them may leave a half-applied camera behind.
    const start: Camera2D = .{ .viewport = .init(0, 0, 800, 600), .center = .init(3, 4), .zoom = 2 };
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);

    for ([_]Vec2{ .init(nan, 0), .init(0, nan), .init(inf, 0) }) |bad| {
        var cam = start;
        try testing.expectError(error.InvalidCamera, cam.panByScreen(bad));
        try testing.expectEqual(start, cam);
    }

    for ([_]f32{ 0, -1, nan, inf }) |bad| {
        var cam = start;
        try testing.expectError(error.InvalidCamera, cam.zoomAround(.init(10, 10), bad));
        try testing.expectEqual(start, cam);
    }

    {
        var cam = start;
        try testing.expectError(error.InvalidCamera, cam.zoomAround(.init(nan, 0), 2));
        try testing.expectEqual(start, cam);
    }

    // And a camera that was already unusable is refused rather than repaired.
    var broken: Camera2D = .{ .viewport = .init(0, 0, 0, 600) };
    try testing.expectError(error.InvalidCamera, broken.panByScreen(.init(1, 1)));
    try testing.expectError(error.InvalidCamera, broken.zoomAround(.init(1, 1), 2));
}
