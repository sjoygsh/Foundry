//! Foundry `render3d` — layer L3. GPU residency and the first 3D drawing boundary.
//!
//! Games submit meshes, rigid cameras and world transforms here; backend objects remain
//! below the RHI. CPU mesh bytes remain in `asset` (ADR-0053).
//!
//! Design: `docs/design/render3d.md` §6 and ADR-0054.

pub const camera = @import("camera.zig");
pub const renderer = @import("renderer.zig");

pub const Camera = camera.Camera;
pub const Config = renderer.Config;
pub const Error = renderer.Error;
pub const Extent2D = renderer.Extent2D;
pub const FrameView = renderer.FrameView;
pub const MeshDraw = renderer.MeshDraw;
pub const MeshHandle = renderer.MeshHandle;
pub const Renderer = renderer.Renderer;
pub const Stats = renderer.Stats;

test {
    _ = camera;
    _ = renderer;
}
