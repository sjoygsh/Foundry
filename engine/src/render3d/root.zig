//! Foundry `render3d` — layer L3. GPU residency and the first 3D drawing boundary.
//!
//! Games submit meshes, rigid cameras and world transforms here; backend objects remain
//! below the RHI. CPU mesh bytes remain in `asset` (ADR-0053).
//!
//! Design: `docs/design/render3d.md` §6 and ADR-0054.

pub const camera = @import("camera.zig");
pub const content = @import("content.zig");
pub const frustum = @import("frustum.zig");
pub const instances = @import("instances.zig");
pub const loader = @import("loader.zig");
pub const lighting = @import("lighting.zig");
pub const renderer = @import("renderer.zig");

pub const Camera = camera.Camera;
pub const AlphaMode = renderer.AlphaMode;
pub const Config = renderer.Config;
pub const Content = content.Content;
pub const ContentLimits = content.Limits;
pub const Error = renderer.Error;
pub const Extent2D = renderer.Extent2D;
pub const Filter = renderer.Filter;
pub const FrameView = renderer.FrameView;
pub const InstanceHandle = instances.InstanceHandle;
pub const Instances = instances.Instances;
pub const InstanceLightHandle = instances.LightHandle;
pub const InstancesLimits = instances.Limits;
pub const Light = lighting.Light;
pub const max_lights = lighting.max_lights;
pub const MaterialDesc = renderer.MaterialDesc;
pub const MaterialHandle = renderer.MaterialHandle;
pub const MaterialFields = renderer.MaterialFields;
pub const MeshDraw = renderer.MeshDraw;
pub const MeshHandle = renderer.MeshHandle;
pub const ModelDraw = content.ModelDraw;
pub const ModelHandle = content.ModelHandle;
pub const meshLoader = loader.meshLoader;
pub const meshOf = loader.meshOf;
pub const Renderer = renderer.Renderer;
pub const ShaderStage = renderer.ShaderStage;
pub const ShadingModel = renderer.ShadingModel;
pub const ShadingVariants = renderer.ShadingVariants;
pub const SlotOverride = content.SlotOverride;
pub const Stats = renderer.Stats;
pub const StreamSet = renderer.StreamSet;
pub const TextureHandle = renderer.TextureHandle;
pub const TextureOptions = renderer.TextureOptions;
pub const textureLoader = loader.textureLoader;
pub const textureOf = loader.textureOf;
pub const Wrap = renderer.Wrap;
pub const unlit_id = renderer.unlit_id;
pub const lit_id = renderer.lit_id;
pub const ShadingFeatures = renderer.ShadingFeatures;

test {
    _ = camera;
    _ = content;
    _ = frustum;
    _ = instances;
    _ = loader;
    _ = lighting;
    _ = renderer;
}
