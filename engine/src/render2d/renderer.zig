//! The renderer: what a game holds, and what turns its draw calls into GPU work.

const std = @import("std");
const core = @import("core");
const rhi = @import("rhi");
const asset = @import("asset");

const atlas_mod = @import("atlas.zig");
const batch_mod = @import("batch.zig");
const camera_mod = @import("camera.zig");
const color_mod = @import("color.zig");
const sprite_mod = @import("sprite.zig");
const text_mod = @import("text.zig");
const tilemap_mod = @import("tilemap.zig");
const view_mod = @import("view.zig");
const texture_mod = @import("texture.zig");

const Allocator = std.mem.Allocator;
const AtlasHandle = atlas_mod.AtlasHandle;
const AtlasOptions = atlas_mod.AtlasOptions;
const BlendMode = color_mod.BlendMode;
const Camera2D = camera_mod.Camera2D;
const Color = color_mod.Color;
const Extent2D = texture_mod.Extent2D;
const Region = atlas_mod.Region;
const BitmapFont = text_mod.BitmapFont;
const Sprite = sprite_mod.Sprite;
const TextOptions = text_mod.TextOptions;
const TilemapLayer = tilemap_mod.TilemapLayer;
const ViewDesc = view_mod.ViewDesc;
const ViewId = view_mod.ViewId;
const TextureHandle = texture_mod.TextureHandle;
const Vertex = sprite_mod.Vertex;
const log = core.log.scoped(.render2d);

/// The shader the renderer draws with, compiled by the build and embedded (ADR-0019).
///
/// An engine-owned shader: the renderer cannot function without it, which makes it
/// machinery rather than content, so it does not wait for the content system.
const sprite_shader: []const u8 = switch (rhi.backend) {
    .metal => @embedFile("sprite_metallib"),
    .null => "null-backend-shader",
};

/// The blank patch is larger than the region taken out of it so that filtering at the
/// edge of a drawn rectangle samples white on both sides. Both samples had independently
/// picked the same two numbers, which is the strongest argument that they belong here.
const blank_size: u32 = 8;
const blank_inset: u32 = 2;

pub const Error = error{
    /// A texture handle that never existed, or that has been destroyed.
    InvalidTexture,
    /// An atlas handle that never existed, or that has been destroyed.
    InvalidAtlas,
    /// Larger than the device can hold.
    TextureTooLarge,
    /// Drawing outside a `begin`/`record` pair.
    NotRecording,
} || atlas_mod.Error || camera_mod.CameraError || tilemap_mod.Error || view_mod.Error ||
    rhi.ResourceError || rhi.MapError || rhi.CommandError || Allocator.Error;

pub const Config = struct {
    /// Quads per vertex buffer. A frame needing more simply uses more buffers, so this
    /// trades allocation granularity against draw-call count, and is not a limit.
    quads_per_buffer: u32 = 16 * 1024,
    /// Must match the value the device was created with. The retirement queue and the
    /// per-slot buffer pools are both sized by it.
    frames_in_flight: u32 = 2,
};

/// What the camera contributes to a frame.
pub const FrameView = struct {
    camera: Camera2D,
    /// Framebuffer pixels per logical point, from `platform.WindowInfo`.
    ///
    /// `Camera2D.viewport` is in **logical points** — the same space as mouse input, so
    /// `screenToWorld` takes a mouse position directly — and the GPU viewport is in
    /// pixels. This is the one number that bridges them, and it is asked for rather than
    /// assumed because `render2d` does not depend on `platform` and cannot look it up.
    pixel_scale: f32 = 1,
};

/// Per-frame counters. Outputs only: statistics never feed simulation (I9).
pub const Stats = struct {
    sprites: u32 = 0,
    /// Glyphs are sprites too, and are counted in `sprites` as well. Separately here
    /// because a frame that is mostly text and a frame that is mostly sprites want
    /// different things done about them.
    glyphs: u32 = 0,
    /// Tiles, likewise counted in `sprites` as well. This is the number that decides
    /// whether a tilemap ever needs a chunk cache, so it is measured from the first day
    /// there is a tilemap rather than from the day somebody suspects one
    /// (`tilemaps-and-collision.md` §10).
    tiles: u32 = 0,
    batches: u32 = 0,
    draw_calls: u32 = 0,
    vertices: u32 = 0,
    vertex_bytes: u32 = 0,
    buffers_used: u32 = 0,
    textures_resident: u32 = 0,
    /// How many views the frame used. Its floor on the batch count, so a frame with more
    /// batches than expected is worth checking against this first.
    views: u32 = 0,
};

/// One vertex buffer's worth of storage for one frame slot.
///
/// Two shapes, chosen by `unified_memory` at creation:
///
/// * **Unified** — one `upload` buffer, written by the CPU and read directly by the GPU
///   as vertices. No copy.
/// * **Discrete** — an `upload` staging buffer plus a `device_local` vertex buffer, with
///   one copy per frame. A GPU reading vertices across PCIe every frame is the slow path
///   that makes people conclude batching does not work.
///
/// Both paths are exercised: Metal on Apple Silicon reports unified, and the validation
/// backend deliberately reports **not** unified, so its ten rules check the barriers and
/// copies of the discrete path on every test run.
const SlotBuffer = struct {
    upload: rhi.BufferHandle,
    /// `.none` on unified memory, where the upload buffer *is* the vertex buffer.
    device: rhi.BufferHandle,
    /// Tracked so the per-frame barrier declares the truth (`rhi.md` §6).
    state: rhi.ResourceState,

    fn vertexSource(self: SlotBuffer) rhi.BufferHandle {
        return if (self.device.isNone()) self.upload else self.device;
    }
};

const Slot = struct {
    buffers: std.ArrayList(SlotBuffer) = .empty,
};

/// What the renderer keeps for each live atlas: a texture it owns, and where the free
/// space is. The packer holds no GPU state, which is what makes it testable on its own.
const AtlasState = struct {
    texture: TextureHandle,
    size: Extent2D,
    packer: atlas_mod.Packer,
};

pub const Renderer = struct {
    gpa: Allocator,
    device: *rhi.Device,
    config: Config,
    unified: bool,

    shader: rhi.ShaderModuleHandle,
    group_layout: rhi.BindGroupLayoutHandle,
    pipeline_layout: rhi.PipelineLayoutHandle,
    /// One per blend mode. The permutation count is exactly this because the CPU
    /// premultiplies, so the modes differ only in blend factors.
    pipelines: [BlendMode.count]rhi.RenderPipelineHandle,
    indices: rhi.BufferHandle,

    textures: texture_mod.Pool,
    atlases: core.HandlePool(atlas_mod.Atlas, AtlasState),
    batcher: batch_mod.Batcher,
    /// This frame's spaces. Rebuilt by `begin`, so it never outlives the camera it was
    /// derived from.
    views: std.ArrayList(view_mod.View),
    current_view: ViewId,
    /// The scissor in force for subsequent draws, in screen points, or `null` for none.
    /// Renderer state rather than a parameter on every draw, for the same reason the view
    /// is: it changes per panel, not per sprite.
    current_clip: ?core.math.Rect,
    /// A white patch the renderer owns, so that no game has to build one to draw a filled
    /// rectangle. See `blankRegion`.
    blank: Region,
    slots: []Slot,

    view: FrameView,
    recording: bool,
    frame: ?rhi.FrameContext,
    stats: Stats,
    last_stats: Stats,

    const Self = @This();

    pub fn init(gpa: Allocator, device: *rhi.Device, config: Config) Error!Self {
        std.debug.assert(config.quads_per_buffer > 0);
        std.debug.assert(config.frames_in_flight > 0);

        const caps = device.capabilities();

        const shader = try device.createShaderModule(.{
            .label = "render2d sprite",
            .bytes = sprite_shader,
        });
        errdefer device.destroyShaderModule(shader);

        // Group 0 is the material: a texture and its sampler. Ascending `binding` is what
        // §9's walk uses, which is what puts them at texture(0) and sampler(0).
        const group_layout = try device.createBindGroupLayout(.{
            .label = "render2d material",
            .entries = &.{
                .{ .binding = 0, .type = .sampled_texture, .visibility = .{ .fragment = true } },
                .{ .binding = 1, .type = .sampler, .visibility = .{ .fragment = true } },
            },
        });
        errdefer device.destroyBindGroupLayout(group_layout);

        const pipeline_layout = try device.createPipelineLayout(.{
            .label = "render2d",
            .bind_group_layouts = &.{group_layout},
            // The view-projection, and nothing else. It changes every frame and is 64
            // bytes, so it is command stream data rather than a resource that would need
            // its own ring buffering.
            .inline_constant_bytes = @sizeOf(core.math.Mat4),
        });
        errdefer device.destroyPipelineLayout(pipeline_layout);

        var pipelines: [BlendMode.count]rhi.RenderPipelineHandle = undefined;
        var built: usize = 0;
        errdefer for (pipelines[0..built]) |p| device.destroyRenderPipeline(p);
        inline for (comptime std.enums.values(BlendMode), 0..) |mode, i| {
            pipelines[i] = try device.createRenderPipeline(.{
                .label = "render2d sprite " ++ @tagName(mode),
                .layout = pipeline_layout,
                .vertex_shader = shader,
                .fragment_shader = shader,
                .vertex_buffers = &.{.{
                    .stride = @sizeOf(Vertex),
                    .attributes = &.{
                        .{ .location = 0, .offset = @offsetOf(Vertex, "position"), .format = .float32x2 },
                        .{ .location = 1, .offset = @offsetOf(Vertex, "uv"), .format = .float32x2 },
                        .{ .location = 2, .offset = @offsetOf(Vertex, "color"), .format = .unorm8x4 },
                    },
                }},
                .color_targets = &.{.{
                    .format = caps.surface_format,
                    .blend = switch (mode) {
                        .alpha => rhi.pipeline.BlendState.premultiplied_alpha,
                        .additive => rhi.pipeline.BlendState.additive,
                        .none => null,
                    },
                }},
            });
            built += 1;
        }

        const indices = try buildIndexBuffer(device, config.quads_per_buffer);
        errdefer device.destroyBuffer(indices);

        const slots = try gpa.alloc(Slot, config.frames_in_flight);
        errdefer gpa.free(slots);
        for (slots) |*slot| slot.* = .{};

        log.info("render2d up: {d} quads per buffer, {s} memory", .{
            config.quads_per_buffer,
            if (caps.unified_memory) "unified" else "discrete",
        });

        var self: Self = .{
            .gpa = gpa,
            .device = device,
            .config = config,
            .unified = caps.unified_memory,
            .shader = shader,
            .group_layout = group_layout,
            .pipeline_layout = pipeline_layout,
            .pipelines = pipelines,
            .indices = indices,
            .textures = .init(config.frames_in_flight),
            .atlases = .empty,
            .batcher = .init(config.quads_per_buffer),
            .views = .empty,
            .current_view = .world,
            .current_clip = null,
            // Filled in below. `.none` rather than `undefined` because `destroyTexture`
            // compares against it, and it is called from inside the creation that sets it.
            .blank = .{ .texture = .none, .uv = .{}, .size_px = .{} },
            .slots = slots,
            .view = .{ .camera = .{ .viewport = .init(0, 0, 1, 1) } },
            .recording = false,
            .frame = null,
            .stats = .{},
            .last_stats = .{},
        };
        errdefer self.textures.deinit(gpa, device);

        self.blank = try self.createBlank();
        return self;
    }

    /// Releases everything.
    ///
    /// Idles the device first, because a renderer is destroyed *before* the device it
    /// borrows — that is the order every consumer creates them in, reversed — and
    /// releasing a resource a frame in flight still references is undefined behaviour.
    /// This is what `rhi`'s `waitIdle` exists for; M2 added it because this teardown is
    /// the ordinary case, not a corner.
    pub fn deinit(self: *Self) void {
        self.device.waitIdle();

        for (self.slots) |*slot| {
            for (slot.buffers.items) |buffer| {
                self.device.destroyBuffer(buffer.upload);
                if (!buffer.device.isNone()) self.device.destroyBuffer(buffer.device);
            }
            slot.buffers.deinit(self.gpa);
        }
        self.gpa.free(self.slots);

        self.batcher.deinit(self.gpa);
        self.views.deinit(self.gpa);
        {
            var it = self.atlases.iterator();
            while (it.next()) |entry| entry.value.packer.deinit(self.gpa);
            self.atlases.deinit(self.gpa);
        }
        self.textures.deinit(self.gpa, self.device);

        self.device.destroyBuffer(self.indices);
        for (self.pipelines) |p| self.device.destroyRenderPipeline(p);
        self.device.destroyPipelineLayout(self.pipeline_layout);
        self.device.destroyBindGroupLayout(self.group_layout);
        self.device.destroyShaderModule(self.shader);
        self.* = undefined;
    }

    // -- resources -------------------------------------------------------------------

    /// Upload a decoded image and get back a handle a game can hold.
    pub fn createTexture(
        self: *Self,
        image: asset.Image,
        options: texture_mod.TextureOptions,
    ) Error!TextureHandle {
        const caps = self.device.capabilities();
        // The image came from a file, so the size is checked rather than asserted.
        if (image.width > caps.max_texture_dimension or image.height > caps.max_texture_dimension) {
            log.warn("texture '{s}' is {d}x{d}, larger than the device's {d}", .{
                options.label, image.width, image.height, caps.max_texture_dimension,
            });
            return error.TextureTooLarge;
        }

        const handle = try self.createEmptyTexture(
            .{ .width = image.width, .height = image.height },
            options,
        );
        errdefer self.destroyTexture(handle);

        const state = self.textures.get(handle).?;
        try self.uploadRegion(state.gpu, image, .{});
        return handle;
    }

    /// Requests destruction. The handle stops resolving immediately; the GPU objects are
    /// released once no in-flight frame can reference them (`texture.Pool`).
    pub fn destroyTexture(self: *Self, handle: TextureHandle) void {
        // The blank texture is the renderer's, not the caller's. Refused rather than
        // asserted: the caller is a game today and a mod from M7, and destroying it would
        // break every other consumer's panels rather than only the one that asked.
        if (handle.eql(self.blank.texture)) {
            log.warn("refusing to destroy the renderer's own blank texture", .{});
            return;
        }
        const frame_index = if (self.frame) |f| f.index else 0;
        _ = self.textures.destroy(self.gpa, handle, frame_index);
    }

    /// A region of solid white the renderer owns, for drawing filled rectangles: panels,
    /// outlines, bars, and everything the UI's draw list calls a `rect`.
    ///
    /// Engine-owned rather than content, the same category as ADR-0019's built-in shaders.
    /// A game may still draw a filled rectangle from its own sheet and nothing stops it;
    /// this exists so that no game *has* to — `samples/sandbox` and `samples/room` had each
    /// written the identical eight-pixel image, upload and inset by hand.
    ///
    /// It is the middle of a larger patch rather than the whole of a one-pixel texture, so
    /// that a filtered sample straying off the rectangle's edge lands on more white instead
    /// of on the clamp boundary.
    pub fn blankRegion(self: *const Self) Region {
        return self.blank;
    }

    pub fn textureSize(self: *Self, handle: TextureHandle) ?Extent2D {
        const state = self.textures.get(handle) orelse return null;
        return .{ .width = state.width, .height = state.height };
    }

    /// The whole texture, addressed as a `Region`.
    ///
    /// So that a game can pass a standalone texture wherever a packed one is expected —
    /// a font, for instance — and moving that image into an atlas later changes the
    /// creation call and nothing else.
    pub fn textureRegion(self: *Self, handle: TextureHandle) ?Region {
        const size = self.textureSize(handle) orelse return null;
        return .whole(handle, size);
    }

    // -- atlases ---------------------------------------------------------------------

    /// An empty atlas of `size` pixels, cleared to transparent.
    ///
    /// The atlas owns a texture of its own, destroyed with it. Nothing is drawn from an
    /// empty atlas, so the clear is not decoration: an uninitialised texture samples as
    /// noise, and the padding between packed images is sampled all the time.
    pub fn createAtlas(self: *Self, size: Extent2D, options: AtlasOptions) Error!AtlasHandle {
        const caps = self.device.capabilities();
        // An atlas size is a number a game or a mod chose, so it is checked and refused.
        if (size.isEmpty() or
            size.width > caps.max_texture_dimension or
            size.height > caps.max_texture_dimension)
        {
            log.warn("atlas '{s}' is {d}x{d}, which the device cannot hold (max {d})", .{
                options.label, size.width, size.height, caps.max_texture_dimension,
            });
            return error.TextureTooLarge;
        }

        const handle = try self.createEmptyTexture(size, .{
            .filter = options.filter,
            .wrap = options.wrap,
            .label = options.label,
        });
        errdefer self.destroyTexture(handle);
        try self.clearTexture(self.textures.get(handle).?.gpu, size);

        return self.atlases.add(self.gpa, .{
            .texture = handle,
            .size = size,
            .packer = .init(size, options.padding),
        });
    }

    /// Packs `image` into `atlas` and returns where it landed.
    ///
    /// `error.AtlasFull` is a **normal** answer — the caller makes another atlas — and is
    /// deliberately distinct from `error.RegionTooLarge`, which no atlas of this size will
    /// ever accept.
    ///
    /// Call this outside a frame. It records and submits a copy of its own, and destroys
    /// the staging buffer immediately afterwards, which is safe exactly because nothing is
    /// in flight — the same reasoning `createTexture` relies on. Doing it mid-frame is a
    /// rule 9 violation, which the validation backend names.
    pub fn atlasAdd(self: *Self, handle: AtlasHandle, image: asset.Image) Error!Region {
        const state = self.atlases.get(handle) orelse return error.InvalidAtlas;
        const gpu = self.textures.get(state.texture) orelse return error.InvalidTexture;
        const gpu_handle = gpu.gpu;

        const placement = try state.packer.add(self.gpa, image.width, image.height);
        try self.uploadRegion(gpu_handle, image, .{ .x = placement.x, .y = placement.y });

        const whole: Region = .whole(state.texture, state.size);
        return whole.sub(placement.x, placement.y, image.width, image.height);
    }

    /// The atlas as one region, which is how a font packed whole into one is addressed.
    pub fn atlasRegion(self: *Self, handle: AtlasHandle) ?Region {
        const state = self.atlases.get(handle) orelse return null;
        return .whole(state.texture, state.size);
    }

    pub fn atlasTexture(self: *Self, handle: AtlasHandle) ?TextureHandle {
        const state = self.atlases.get(handle) orelse return null;
        return state.texture;
    }

    /// The fraction of the atlas the packed images occupy. A diagnostic: it is the number
    /// that tells you an atlas is the wrong size.
    pub fn atlasFill(self: *Self, handle: AtlasHandle) ?f32 {
        const state = self.atlases.get(handle) orelse return null;
        return state.packer.fill();
    }

    /// Destroys the atlas and the texture it owns. Regions handed out from it stop
    /// resolving with it, because they name that texture (I1).
    pub fn destroyAtlas(self: *Self, handle: AtlasHandle) void {
        const state = self.atlases.get(handle) orelse return;
        self.destroyTexture(state.texture);
        state.packer.deinit(self.gpa);
        _ = self.atlases.remove(handle);
    }

    /// The texture, sampler and bind group, with no pixels written yet.
    ///
    /// Shared by `createTexture` and `createAtlas` so that a texture is built one way.
    fn createEmptyTexture(
        self: *Self,
        size: Extent2D,
        options: texture_mod.TextureOptions,
    ) Error!TextureHandle {
        const gpu = try self.device.createTexture(.{
            .label = options.label,
            .size = .{ .width = size.width, .height = size.height },
            // sRGB, matching the surface, so sampling returns linear light and the write
            // encodes back. `asset.Image` documents its bytes as sRGB for this reason.
            .format = .rgba8_unorm_srgb,
            .usage = .{ .sampled = true, .copy_dst = true },
        });
        errdefer self.device.destroyTexture(gpu);

        const sampler = try self.device.createSampler(.{
            .label = options.label,
            .min_filter = switch (options.filter) {
                .nearest => .nearest,
                .linear => .linear,
            },
            .mag_filter = switch (options.filter) {
                .nearest => .nearest,
                .linear => .linear,
            },
            .address_u = switch (options.wrap) {
                .clamp => .clamp_to_edge,
                .repeat => .repeat,
            },
            .address_v = switch (options.wrap) {
                .clamp => .clamp_to_edge,
                .repeat => .repeat,
            },
        });
        errdefer self.device.destroySampler(sampler);

        const group = try self.device.createBindGroup(.{
            .label = options.label,
            .layout = self.group_layout,
            .entries = &.{
                .{ .binding = 0, .resource = .{ .sampled_texture = gpu } },
                .{ .binding = 1, .resource = .{ .sampler = sampler } },
            },
        });
        errdefer self.device.destroyBindGroup(group);

        return self.textures.add(self.gpa, .{
            .gpu = gpu,
            .group = group,
            .sampler = sampler,
            .width = size.width,
            .height = size.height,
        });
    }

    /// Writes `image` into `gpu` at `origin`.
    ///
    /// A whole-texture upload is this with the default origin, and packing into an atlas
    /// is this with a computed one — one path, so an atlas cannot drift from a texture in
    /// how its pixels get there.
    fn uploadRegion(
        self: *Self,
        gpu: rhi.TextureHandle,
        image: asset.Image,
        origin: rhi.Origin2D,
    ) Error!void {
        const staging = try self.device.createBuffer(.{
            .label = "render2d texture staging",
            .size = image.byteSize(),
            .usage = .{ .copy_src = true },
            .memory = .upload,
        });
        // Destroyed at the end of this function, which is safe specifically because it is
        // not inside a frame: nothing is in flight, so the deferred-destroy guarantee the
        // RHI documents but does not implement is not being leaned on.
        defer self.device.destroyBuffer(staging);

        {
            const bytes = try self.device.mapBuffer(staging);
            defer self.device.unmapBuffer(staging);
            @memcpy(bytes[0..image.byteSize()], image.pixels);
        }

        var cmd = try self.device.beginCommandBuffer();
        // From `undefined` every time, including for an atlas that already has pixels in
        // it: the region being written has no contents worth preserving, and the texels
        // outside it are untouched by a copy. Declaring `shader_read` here instead would
        // be a lie the moment two uploads ran back to back.
        try cmd.textureBarrier(&.{.{ .texture = gpu, .from = .undefined, .to = .copy_dst }});
        try cmd.copyBufferToTexture(.{
            .src = staging,
            .dst = gpu,
            .dst_origin = origin,
            .size = .{ .width = image.width, .height = image.height },
        });
        try cmd.textureBarrier(&.{.{ .texture = gpu, .from = .copy_dst, .to = .shader_read }});
        try cmd.submit();
    }

    /// Fills a whole texture with transparent black.
    ///
    /// Through a zeroed staging buffer rather than a render pass, which would need
    /// `render_target` usage and a pipeline for something that happens once per atlas.
    /// The buffer is the atlas's full size — four megabytes for 1024 squared — and is
    /// released immediately.
    fn clearTexture(self: *Self, gpu: rhi.TextureHandle, size: Extent2D) Error!void {
        const bytes_needed = @as(u64, size.width) * size.height * asset.Image.channels;
        const staging = try self.device.createBuffer(.{
            .label = "render2d atlas clear",
            .size = bytes_needed,
            .usage = .{ .copy_src = true },
            .memory = .upload,
        });
        defer self.device.destroyBuffer(staging);

        {
            const bytes = try self.device.mapBuffer(staging);
            defer self.device.unmapBuffer(staging);
            @memset(bytes[0..@intCast(bytes_needed)], 0);
        }

        var cmd = try self.device.beginCommandBuffer();
        try cmd.textureBarrier(&.{.{ .texture = gpu, .from = .undefined, .to = .copy_dst }});
        try cmd.copyBufferToTexture(.{
            .src = staging,
            .dst = gpu,
            .size = .{ .width = size.width, .height = size.height },
        });
        try cmd.textureBarrier(&.{.{ .texture = gpu, .from = .copy_dst, .to = .shader_read }});
        try cmd.submit();
    }

    // -- the frame -------------------------------------------------------------------

    /// Starts a frame's draw list. Called by the game, before any `drawSprite`.
    ///
    /// Fills views 0 and 1 — `world` from the camera, `screen` from the same rectangle in
    /// points — and selects `world`. A game that never mentions views therefore behaves
    /// exactly as it did before there were any.
    pub fn begin(self: *Self, view: FrameView) Error!void {
        try view.camera.validate();
        self.view = view;

        self.views.clearRetainingCapacity();
        try self.views.append(self.gpa, try view_mod.View.resolve(
            .{ .camera = view.camera },
            view.pixel_scale,
        ));
        // The screen view spans the camera's own viewport, so a screen point is a point in
        // the same space the mouse is reported in — which is what makes a HUD placeable
        // without any conversion at all.
        try self.views.append(self.gpa, try view_mod.View.resolve(
            .{ .screen = view.camera.viewport },
            view.pixel_scale,
        ));
        self.current_view = .world;
        self.current_clip = null;

        self.batcher.reset();
        self.stats = .{};
        self.recording = true;
    }

    /// Adds a space for this frame and returns its id.
    ///
    /// The id is valid until the next `begin`, which is the only lifetime that makes sense
    /// for something derived from this frame's camera and window size. Views are ordered
    /// by id, so a view added later draws over one added earlier (`batch.zig`).
    pub fn addView(self: *Self, desc: ViewDesc) Error!ViewId {
        if (!self.recording) return error.NotRecording;
        if (self.views.items.len >= view_mod.max_views) return error.TooManyViews;

        const resolved = try view_mod.View.resolve(desc, self.view.pixel_scale);
        const id: ViewId = .fromIndex(self.views.items.len);
        try self.views.append(self.gpa, resolved);
        return id;
    }

    /// Selects the space subsequent draws are recorded in.
    ///
    /// Renderer state rather than a parameter on every draw: this changes per screenful,
    /// not per sprite, and a HUD is one call followed by a hundred draws. It resets to
    /// `world` with `begin`, which is the only place it could go stale.
    pub fn setView(self: *Self, id: ViewId) Error!void {
        if (!self.recording) return error.NotRecording;
        if (id.index() >= self.views.items.len) return error.InvalidView;
        self.current_view = id;
    }

    pub fn currentView(self: *const Self) ViewId {
        return self.current_view;
    }

    /// Clips subsequent draws to `rect`, or to nothing at all with `null`.
    ///
    /// **In screen points**, the same space `ViewId.screen` uses and the same space the
    /// mouse is reported in, converted to framebuffer pixels by the recorder — which is the
    /// only place that knows the pixel scale. Every other public rectangle in `render2d` is
    /// in points, and one API in pixels would put a scale factor at the call site.
    ///
    /// A scissor is a property of the render target rather than of a space, so a clip set
    /// while drawing in the world view still names a rectangle of the window. It is
    /// intersected with the view's viewport when recorded, so it can never reach outside
    /// what the frame is allowed to touch.
    ///
    /// A batch cannot span a clip change, so this costs one draw call per change — the
    /// number a person tuning a frame is already reading, which is why `Stats` gains
    /// nothing for it.
    pub fn setClip(self: *Self, rect: ?core.math.Rect) Error!void {
        if (!self.recording) return error.NotRecording;
        self.current_clip = if (rect) |r| sanitizeClip(r) else null;
    }

    pub fn currentClip(self: *const Self) ?core.math.Rect {
        return self.current_clip;
    }

    /// A clip may come from a content-driven layout and, from M7, from a mod, so a
    /// non-finite component is **rejected rather than asserted on** (CLAUDE.md §7). It
    /// collapses to an empty rectangle, which draws nothing — a failure that is visible
    /// immediately rather than one that leaks a panel over the rest of the screen.
    fn sanitizeClip(r: core.math.Rect) core.math.Rect {
        if (!std.math.isFinite(r.x) or !std.math.isFinite(r.y) or
            !std.math.isFinite(r.w) or !std.math.isFinite(r.h))
        {
            log.warn("clip rectangle is not finite; clipping everything away instead", .{});
            return .{};
        }
        return .init(r.x, r.y, @max(0, r.w), @max(0, r.h));
    }

    /// Which way `+y` points in a view. `.up` for anything the frame does not have, which
    /// cannot happen — `setView` refuses an unknown id — but is answered rather than
    /// asserted because the alternative is an out-of-bounds read.
    fn viewAxis(self: *const Self, id: ViewId) view_mod.YAxis {
        if (id.index() >= self.views.items.len) return .up;
        return self.views.items[id.index()].y_axis;
    }

    /// The rectangle of a view's space that it displays. Empty for anything the frame does
    /// not have, which culls everything rather than reading past the table — same
    /// reasoning as `viewAxis`, and `setView` already makes it unreachable.
    fn viewVisible(self: *const Self, id: ViewId) core.math.Rect {
        if (id.index() >= self.views.items.len) return .{};
        return self.views.items[id.index()].visible;
    }

    /// Appends one sprite to this frame's draw list. No GPU work happens here.
    pub fn drawSprite(self: *Self, sprite: Sprite) Error!void {
        if (!self.recording) return error.NotRecording;
        // Validated at submission rather than at draw time, so a stale handle is a clean
        // error at the call site that caused it — the payoff of I1.
        if (self.textures.get(sprite.texture) == null) return error.InvalidTexture;
        try self.batcher.add(self.gpa, sprite, self.current_view, self.current_clip);
    }

    /// Appends one string's glyphs to this frame's draw list.
    ///
    /// A glyph is a sprite, so this is a loop over `drawSprite`'s work and nothing more —
    /// same batcher, same sort key, same draw call. Text and sprites in one layer from one
    /// atlas cost one draw call, which is not a special case here but a consequence of
    /// there being no separate text path to make one.
    ///
    /// The bytes are untrusted and are never asserted on: invalid UTF-8 and codepoints the
    /// font lacks draw the substitution glyph (`text.Layout`).
    pub fn drawText(
        self: *Self,
        font: BitmapFont,
        string: []const u8,
        options: TextOptions,
    ) Error!void {
        if (!self.recording) return error.NotRecording;
        // Checked once, not once per glyph: every glyph comes from the same texture, and a
        // thousand-character line should not pay for a thousand lookups.
        if (self.textures.get(font.glyphs.texture) == null) return error.InvalidTexture;

        const y_axis = self.viewAxis(self.current_view);
        var layout: text_mod.Layout = .initIn(font, string, options, y_axis);
        while (layout.next()) |placed| {
            const region = placed.region orelse continue;
            try self.batcher.add(self.gpa, .{
                .texture = region.texture,
                .position = placed.position,
                .size = placed.size,
                .uv = region.uv,
                // Top-left, because that is where `TextOptions.position` is measured
                // from — which is `origin.y = 1` in a Y-up space and `0` in a Y-down one,
                // since `origin` is normalised against the space's own direction.
                .origin = .init(0, switch (y_axis) {
                    .up => 1,
                    .down => 0,
                }),
                .tint = options.tint,
                .layer = options.layer,
                .blend = options.blend,
            }, self.current_view, self.current_clip);
            self.stats.glyphs += 1;
        }
    }

    /// Appends one layer of a tilemap to this frame's draw list, culled to the current view.
    ///
    /// A tile is a sprite, so this is `drawText`'s shape again: a loop over a pure iterator,
    /// the same batcher, the same sort key. A layer is one texture at one sort layer and is
    /// therefore **one batch**, whatever its size — and because the iterator is culled first,
    /// what it costs is the screenful rather than the map (`tilemap.zig`).
    ///
    /// **The space is the current view, not a parameter**, exactly as it is for every other
    /// draw. `setView` is how the renderer has always been told which space to record in, and
    /// a per-call view argument on one entry point out of three is the kind of inconsistency
    /// that a frozen ABI makes permanent (CLAUDE.md §7).
    ///
    /// The layer is untrusted — every field of it can come from a content file — so a layer
    /// that could not be drawn anywhere is refused, while a tile id the sheet does not have
    /// simply draws nothing.
    pub fn drawTilemap(self: *Self, layer: TilemapLayer) Error!void {
        if (!self.recording) return error.NotRecording;
        // Once, not once per tile: every tile in a layer is from the same texture, and a
        // ten-thousand-cell map should not pay for ten thousand lookups.
        if (self.textures.get(layer.tiles.texture) == null) return error.InvalidTexture;

        const id = self.current_view;
        var tiles: tilemap_mod.Tiles = try .init(layer, self.viewVisible(id));
        while (tiles.next()) |tile| {
            try self.batcher.add(self.gpa, tile, id, self.current_clip);
            self.stats.tiles += 1;
        }
    }

    /// Sorts, writes vertices, and records any copies the memory model needs.
    ///
    /// Called by `app`, not by the game: it takes a command buffer, and a game that could
    /// reach one would be reaching the RHI (CLAUDE.md §4.2).
    pub fn prepare(self: *Self, cmd: *rhi.CommandBuffer, frame: rhi.FrameContext) Error!void {
        self.frame = frame;
        self.textures.collect(self.device, frame.index);

        try self.batcher.plan(self.gpa);

        const slot = &self.slots[frame.slot];
        const needed = self.batcher.bufferCount();
        while (slot.buffers.items.len < needed) {
            try slot.buffers.append(self.gpa, try self.createSlotBuffer(frame.slot));
        }

        const quads_per_buffer = self.config.quads_per_buffer;
        var written_quads: u32 = 0;

        for (0..needed) |i| {
            const first = @as(u32, @intCast(i)) * quads_per_buffer;
            const count = @min(quads_per_buffer, self.batcher.count() - first);
            const buffer = slot.buffers.items[i];

            {
                // Mapped per frame rather than persistently, deliberately: the validation
                // backend's rule 3 fires on `mapBuffer` when the slot is still in flight,
                // so a persistent mapping would switch off the exact check the per-slot
                // scheme exists to earn.
                const bytes = try self.device.mapBuffer(buffer.upload);
                defer self.device.unmapBuffer(buffer.upload);

                const aligned: []align(@alignOf(Vertex)) u8 = @alignCast(bytes);
                const vertices = std.mem.bytesAsSlice(Vertex, aligned);
                for (0..count) |q| {
                    const item = self.batcher.items.items[self.batcher.order.items[first + q]];
                    const at = q * sprite_mod.vertices_per_quad;
                    // Which way is up is the *space's* property, not the sprite's, and
                    // this is where the two meet.
                    sprite_mod.writeQuad(
                        item.sprite,
                        self.viewAxis(item.view),
                        vertices[at..][0..sprite_mod.vertices_per_quad],
                    );
                }
            }

            written_quads += count;
        }

        if (!self.unified and needed > 0) {
            try self.recordUploads(cmd, slot, needed);
        }

        self.stats.sprites = self.batcher.count();
        self.stats.batches = @intCast(self.batcher.batches.items.len);
        self.stats.buffers_used = needed;
        self.stats.vertices = written_quads * sprite_mod.vertices_per_quad;
        self.stats.vertex_bytes = self.stats.vertices * @sizeOf(Vertex);
        self.stats.textures_resident = self.textures.count();
        self.stats.views = @intCast(self.views.items.len);
    }

    /// Emits the draw calls. Called by `app`, into the pass it opened.
    pub fn record(self: *Self, pass: *rhi.RenderPass) Error!void {
        defer {
            self.recording = false;
            self.last_stats = self.stats;
        }
        if (self.batcher.batches.items.len == 0) return;

        const frame = self.frame orelse return error.NotRecording;
        const slot = &self.slots[frame.slot];

        var bound_pipeline: ?BlendMode = null;
        var bound_texture: ?TextureHandle = null;
        var bound_buffer: ?u32 = null;
        var bound_view: ?ViewId = null;
        var bound_clip: ?core.math.Rect = null;
        // A `?Rect` cannot say "nothing bound yet" on its own, since `null` already means
        // "no clip". The first batch of every frame therefore sets the scissor explicitly
        // rather than inheriting whatever the pass began with.
        var clip_bound = false;

        for (self.batcher.batches.items) |item| {
            const state = self.textures.get(item.texture) orelse continue;
            // Batches are grouped by view (`batch.zig`), so this changes a handful of
            // times a frame at most. A view whose id the frame no longer has cannot occur
            // — `setView` refused it — but the lookup is bounded rather than trusted.
            const view = if (item.view.index() < self.views.items.len)
                self.views.items[item.view.index()]
            else
                continue;

            const view_changed = bound_view == null or bound_view.? != item.view;
            if (view_changed) {
                pass.setViewport(view.viewport);
                bound_view = item.view;
            }

            // After the viewport, and re-sent when the view changes even if the rectangle
            // did not: the scissor is clamped to the viewport, so the same clip means a
            // different pixel rectangle in a different space.
            if (!clip_bound or view_changed or !batch_mod.clipEql(bound_clip, item.clip)) {
                pass.setScissor(self.scissorFor(view.viewport, item.clip));
                bound_clip = item.clip;
                clip_bound = true;
            }

            if (bound_pipeline == null or bound_pipeline.? != item.blend) {
                pass.setPipeline(self.pipelines[@intFromEnum(item.blend)]);
                bound_pipeline = item.blend;
                // Binding a pipeline invalidates inline constants when the layout differs
                // (`rhi.md` §9), so they are always re-set here rather than only when the
                // transform changed.
                pass.setInlineConstants(std.mem.asBytes(&view.view_projection));
            } else if (view_changed) {
                // Same pipeline, different space: the constants still have to change.
                pass.setInlineConstants(std.mem.asBytes(&view.view_projection));
            }
            if (bound_texture == null or !bound_texture.?.eql(item.texture)) {
                pass.setBindGroup(0, state.group);
                bound_texture = item.texture;
            }
            if (bound_buffer == null or bound_buffer.? != item.buffer) {
                pass.setVertexBuffer(0, slot.buffers.items[item.buffer].vertexSource(), 0);
                pass.setIndexBuffer(self.indices, .uint32, 0);
                bound_buffer = item.buffer;
            }

            pass.drawIndexed(.{
                .index_count = item.quad_count * sprite_mod.indices_per_quad,
                .first_index = item.first_quad * sprite_mod.indices_per_quad,
            });
            self.stats.draw_calls += 1;
        }
    }

    /// The most recently completed frame's counters.
    pub fn frameStats(self: *const Self) Stats {
        return self.last_stats;
    }

    // -- internals -------------------------------------------------------------------

    /// A clip in screen points, resolved to framebuffer pixels and clamped to the viewport
    /// it will be applied inside. `null` is the viewport itself, which is what "no clip"
    /// means once a scissor has to be set to something.
    ///
    /// Clamping is not tidiness: a scissor reaching outside the render target is a
    /// validation error on Metal, and a clip rectangle is exactly the kind of number a
    /// content-driven layout gets slightly wrong.
    fn scissorFor(
        self: *const Self,
        viewport: rhi.command.Viewport,
        clip: ?core.math.Rect,
    ) rhi.command.ScissorRect {
        const left = viewport.x;
        const top = viewport.y;
        const right = viewport.x + viewport.width;
        const bottom = viewport.y + viewport.height;

        var x0 = left;
        var y0 = top;
        var x1 = right;
        var y1 = bottom;
        if (clip) |c| {
            const scale = self.view.pixel_scale;
            // Outward-rounded, so a rectangle on a half-pixel boundary keeps the pixel it
            // partly covers rather than clipping a column off its own edge.
            x0 = @max(left, @floor(c.x * scale));
            y0 = @max(top, @floor(c.y * scale));
            x1 = @min(right, @ceil((c.x + c.w) * scale));
            y1 = @min(bottom, @ceil((c.y + c.h) * scale));
        }

        return .{
            .x = toPixels(x0),
            .y = toPixels(y0),
            .width = toPixels(@max(0, x1 - x0)),
            .height = toPixels(@max(0, y1 - y0)),
        };
    }

    fn toPixels(v: f32) u32 {
        return @intFromFloat(@max(0, v));
    }

    /// The white patch behind `blankRegion`, built in memory rather than loaded: it is not
    /// content, and making it an asset would give the engine a content dependency for four
    /// pixels of white.
    fn createBlank(self: *Self) Error!Region {
        var image = try asset.Image.alloc(self.gpa, blank_size, blank_size);
        defer image.deinit(self.gpa);
        @memset(image.pixels, 0xFF);

        const handle = try self.createTexture(image, .{ .label = "render2d blank" });
        return self.textureRegion(handle).?.sub(
            blank_inset,
            blank_inset,
            blank_size - blank_inset * 2,
            blank_size - blank_inset * 2,
        );
    }

    fn createSlotBuffer(self: *Self, slot_index: u32) Error!SlotBuffer {
        const size = @as(u64, self.config.quads_per_buffer) *
            sprite_mod.vertices_per_quad * @sizeOf(Vertex);

        if (self.unified) {
            return .{
                .upload = try self.device.createBuffer(.{
                    .label = "render2d vertices",
                    .size = size,
                    .usage = .{ .vertex = true },
                    .memory = .upload,
                }),
                .device = .none,
                .state = .shader_read,
            };
        }

        const staging = try self.device.createBuffer(.{
            .label = "render2d vertex staging",
            .size = size,
            .usage = .{ .copy_src = true },
            .memory = .upload,
        });
        errdefer self.device.destroyBuffer(staging);

        const device_buffer = try self.device.createBuffer(.{
            .label = "render2d vertices",
            .size = size,
            .usage = .{ .vertex = true, .copy_dst = true },
            .memory = .device_local,
        });

        _ = slot_index;
        return .{ .upload = staging, .device = device_buffer, .state = .undefined };
    }

    /// The discrete-memory path: one barrier batch, the copies, one barrier batch back.
    ///
    /// Batched at the boundaries rather than issued per copy, which is the shape `rhi.md`
    /// §6 asks for — per-resource barriers between every command are what make Vulkan slow.
    fn recordUploads(self: *Self, cmd: *rhi.CommandBuffer, slot: *Slot, used: u32) Error!void {
        var to_copy: [8]rhi.command.BufferBarrier = undefined;
        var to_read: [8]rhi.command.BufferBarrier = undefined;

        var i: u32 = 0;
        while (i < used) {
            const chunk = @min(@as(u32, to_copy.len), used - i);
            for (0..chunk) |j| {
                const buffer = &slot.buffers.items[i + j];
                to_copy[j] = .{ .buffer = buffer.device, .from = buffer.state, .to = .copy_dst };
                to_read[j] = .{ .buffer = buffer.device, .from = .copy_dst, .to = .shader_read };
            }

            try cmd.bufferBarrier(to_copy[0..chunk]);
            for (0..chunk) |j| {
                const index = i + j;
                const first = @as(u32, @intCast(index)) * self.config.quads_per_buffer;
                const count = @min(self.config.quads_per_buffer, self.batcher.count() - first);
                const buffer = &slot.buffers.items[index];
                try cmd.copyBufferToBuffer(.{
                    .src = buffer.upload,
                    .dst = buffer.device,
                    // Only what was written, not the whole buffer.
                    .size = @as(u64, count) * sprite_mod.vertices_per_quad * @sizeOf(Vertex),
                });
                buffer.state = .shader_read;
            }
            try cmd.bufferBarrier(to_read[0..chunk]);

            i += chunk;
        }
    }

    fn buildIndexBuffer(device: *rhi.Device, quads: u32) Error!rhi.BufferHandle {
        const count = quads * sprite_mod.indices_per_quad;
        const size = @as(u64, count) * @sizeOf(u32);

        const staging = try device.createBuffer(.{
            .label = "render2d index staging",
            .size = size,
            .usage = .{ .copy_src = true },
            .memory = .upload,
        });
        defer device.destroyBuffer(staging);

        const indices = try device.createBuffer(.{
            .label = "render2d indices",
            .size = size,
            // `u32` rather than `u16`: `u16` would cap a draw at 16,384 quads and save two
            // bytes a vertex, and a cap that produces a rare size-dependent bug is a bad
            // trade for a buffer written once and never touched again.
            .usage = .{ .index = true, .copy_dst = true },
            .memory = .device_local,
        });
        errdefer device.destroyBuffer(indices);

        {
            const bytes = try device.mapBuffer(staging);
            defer device.unmapBuffer(staging);
            // Mapped GPU memory carries no Zig alignment guarantee, so this is checked
            // rather than assumed: `@alignCast` panics in a safe build if a backend ever
            // hands back something a `u32` cannot be written to.
            const aligned: []align(@alignOf(u32)) u8 = @alignCast(bytes[0..@intCast(size)]);
            sprite_mod.writeIndices(std.mem.bytesAsSlice(u32, aligned));
        }

        var cmd = try device.beginCommandBuffer();
        try cmd.bufferBarrier(&.{.{ .buffer = indices, .from = .undefined, .to = .copy_dst }});
        try cmd.copyBufferToBuffer(.{ .src = staging, .dst = indices, .size = size });
        // `shader_read` is the state for "the GPU reads this now"; the RHI does not
        // distinguish index fetch from shader read, because none of the three APIs needs
        // it to (`rhi.md` §6).
        try cmd.bufferBarrier(&.{.{ .buffer = indices, .from = .copy_dst, .to = .shader_read }});
        try cmd.submit();

        return indices;
    }
};

const testing = std.testing;

/// A device, a renderer and one texture: the smallest thing that can draw.
///
/// Under `-Drhi=null` this runs against the validation backend with violation logging on,
/// so any of its ten rules broken anywhere in the renderer fails the test through the log
/// — including the barrier and copy discipline of the discrete-memory path, which is the
/// path the null backend takes because it deliberately reports memory as *not* unified.
const Fixture = struct {
    device: *rhi.Device,
    renderer: Renderer,
    texture: TextureHandle,
    other: TextureHandle,

    fn init(quads_per_buffer: u32) !Fixture {
        const device = try rhi.Device.init(testing.allocator, .{});
        errdefer device.deinit();

        var renderer = try Renderer.init(testing.allocator, device, .{
            .quads_per_buffer = quads_per_buffer,
        });
        errdefer renderer.deinit();

        var image = try asset.Image.alloc(testing.allocator, 2, 2);
        defer image.deinit(testing.allocator);
        @memset(image.pixels, 0xFF);

        const texture = try renderer.createTexture(image, .{ .label = "fixture a" });
        const other = try renderer.createTexture(image, .{ .label = "fixture b" });

        return .{ .device = device, .renderer = renderer, .texture = texture, .other = other };
    }

    fn deinit(self: *Fixture) void {
        self.renderer.deinit();
        self.device.deinit();
    }

    /// One complete frame, driven the way `app` drives it.
    fn frame(self: *Fixture) !void {
        const ctx = try self.device.beginFrame();
        const cmd = try self.device.beginCommandBuffer();
        try self.renderer.prepare(cmd, ctx);

        const pass = try cmd.beginRenderPass(.{
            .label = "test",
            .color = &.{.{
                .texture = ctx.surface_texture,
                .load = .{ .clear = .{ .color = .{ 0, 0, 0, 1 } } },
                .store = .store,
                .initial_state = .undefined,
                .final_state = .present,
            }},
        });
        try self.renderer.record(pass);
        pass.end();
        try cmd.submit();
        try self.device.endFrame();
    }

    fn sprite(self: *Fixture, which: TextureHandle, layer: i16, blend: BlendMode) Sprite {
        _ = self;
        return .{
            .texture = which,
            .position = .init(0, 0),
            .size = .init(10, 10),
            .layer = layer,
            .blend = blend,
        };
    }

    fn view(self: *Fixture) FrameView {
        _ = self;
        return .{ .camera = .{ .viewport = .init(0, 0, 1280, 720) } };
    }
};

test "a frame with no sprites still completes, and draws nothing" {
    var fx = try Fixture.init(1024);
    defer fx.deinit();

    try fx.renderer.begin(fx.view());
    try fx.frame();

    const stats = fx.renderer.frameStats();
    try testing.expectEqual(@as(u32, 0), stats.sprites);
    try testing.expectEqual(@as(u32, 0), stats.draw_calls);
    try testing.expectEqual(@as(u32, 0), stats.buffers_used);
}

test "sprites sharing a texture and blend mode become a single draw call" {
    var fx = try Fixture.init(1024);
    defer fx.deinit();

    try fx.renderer.begin(fx.view());
    for (0..500) |_| try fx.renderer.drawSprite(fx.sprite(fx.texture, 0, .alpha));
    try fx.frame();

    const stats = fx.renderer.frameStats();
    try testing.expectEqual(@as(u32, 500), stats.sprites);
    try testing.expectEqual(@as(u32, 1), stats.batches);
    try testing.expectEqual(@as(u32, 1), stats.draw_calls);
    try testing.expectEqual(@as(u32, 2000), stats.vertices);
    // Two from the fixture and the renderer's own blank patch, which every renderer has.
    try testing.expectEqual(@as(u32, 3), stats.textures_resident);
}

test "a second texture and a second blend mode each cost a draw call" {
    var fx = try Fixture.init(1024);
    defer fx.deinit();

    try fx.renderer.begin(fx.view());
    try fx.renderer.drawSprite(fx.sprite(fx.texture, 0, .alpha));
    try fx.renderer.drawSprite(fx.sprite(fx.other, 0, .alpha));
    try fx.renderer.drawSprite(fx.sprite(fx.other, 0, .additive));
    try fx.frame();

    try testing.expectEqual(@as(u32, 3), fx.renderer.frameStats().draw_calls);
}

test "more sprites than one buffer holds spill into the next one" {
    var fx = try Fixture.init(2);
    defer fx.deinit();

    try fx.renderer.begin(fx.view());
    for (0..5) |_| try fx.renderer.drawSprite(fx.sprite(fx.texture, 0, .alpha));
    try fx.frame();

    const stats = fx.renderer.frameStats();
    // Five quads at two per buffer is three buffers, and a batch cannot span two.
    try testing.expectEqual(@as(u32, 3), stats.buffers_used);
    try testing.expectEqual(@as(u32, 3), stats.draw_calls);
    try testing.expectEqual(@as(u32, 5), stats.sprites);
}

test "frames cycle through slots without writing memory a frame may still read" {
    var fx = try Fixture.init(64);
    defer fx.deinit();

    // Six frames is three times round a two-slot ring. If the renderer wrote a slot the
    // GPU had not finished with, the validation backend's rule 3 would fire on the map
    // and fail this test through the log.
    for (0..6) |i| {
        try fx.renderer.begin(fx.view());
        for (0..(i + 1) * 10) |_| try fx.renderer.drawSprite(fx.sprite(fx.texture, 0, .alpha));
        try fx.frame();
    }

    try testing.expectEqual(@as(u32, 60), fx.renderer.frameStats().sprites);
}

test "a destroyed texture is refused at the draw call that uses it" {
    var fx = try Fixture.init(64);
    defer fx.deinit();

    var image = try asset.Image.alloc(testing.allocator, 1, 1);
    defer image.deinit(testing.allocator);
    @memset(image.pixels, 0x80);
    const doomed = try fx.renderer.createTexture(image, .{ .label = "doomed" });

    try fx.renderer.begin(fx.view());
    try fx.renderer.drawSprite(fx.sprite(doomed, 0, .alpha));
    fx.renderer.destroyTexture(doomed);

    // The generation bump makes this a clean error at the call site rather than a draw
    // that samples freed GPU memory. That is the whole point of I1.
    try testing.expectError(error.InvalidTexture, fx.renderer.drawSprite(fx.sprite(doomed, 0, .alpha)));

    // The sprite submitted *before* the destroy is skipped rather than drawn from freed
    // memory: a batch whose texture no longer resolves is dropped.
    try fx.frame();
    try testing.expectEqual(@as(u32, 0), fx.renderer.frameStats().draw_calls);

    // And the GPU objects survive until no in-flight frame can reference them, which is
    // why the frames above did not trip rule 9.
    for (0..3) |_| {
        try fx.renderer.begin(fx.view());
        try fx.frame();
    }
}

test "drawing outside a begin is a caller error, not a crash" {
    var fx = try Fixture.init(64);
    defer fx.deinit();
    try testing.expectError(error.NotRecording, fx.renderer.drawSprite(fx.sprite(fx.texture, 0, .alpha)));
}

test "an unusable camera is refused before anything is recorded" {
    var fx = try Fixture.init(64);
    defer fx.deinit();
    try testing.expectError(error.InvalidCamera, fx.renderer.begin(.{
        .camera = .{ .viewport = .init(0, 0, 800, 600), .zoom = 0 },
    }));
}

test "an oversized image is refused rather than truncated" {
    var fx = try Fixture.init(64);
    defer fx.deinit();

    const caps = fx.device.capabilities();
    // Only allocate a plausible buffer; the check is on the declared dimensions.
    var image: asset.Image = .{
        .width = caps.max_texture_dimension + 1,
        .height = 1,
        .pixels = &.{},
    };
    try testing.expectError(error.TextureTooLarge, fx.renderer.createTexture(image, .{}));
    image.width = 1;
}

test "an atlas packs several images into one texture, and one draw call" {
    // The whole point of an atlas, stated as the thing that is actually observable: the
    // batcher breaks on a texture change, and after packing there is no texture change.
    var fx = try Fixture.init(64);
    defer fx.deinit();

    const handle = try fx.renderer.createAtlas(.{ .width = 64, .height = 64 }, .{});

    var image = try asset.Image.alloc(testing.allocator, 8, 8);
    defer image.deinit(testing.allocator);
    @memset(image.pixels, 0xFF);

    var regions: [4]Region = undefined;
    for (&regions) |*r| r.* = try fx.renderer.atlasAdd(handle, image);

    // Four regions, one texture.
    for (regions[1..]) |r| try testing.expectEqual(regions[0].texture, r.texture);

    try fx.renderer.begin(fx.view());
    for (regions) |r| {
        try fx.renderer.drawSprite(.{
            .texture = r.texture,
            .uv = r.uv,
            .position = .init(0, 0),
            .size = .init(8, 8),
        });
    }
    try fx.frame();

    const stats = fx.renderer.frameStats();
    try testing.expectEqual(@as(u32, 4), stats.sprites);
    try testing.expectEqual(@as(u32, 1), stats.draw_calls);
}

test "an atlas reports how full it is, and refuses more than it can hold" {
    var fx = try Fixture.init(64);
    defer fx.deinit();

    // No padding, so the arithmetic is the packer's and not the padding's.
    const handle = try fx.renderer.createAtlas(.{ .width = 32, .height = 32 }, .{ .padding = 0 });
    try testing.expectEqual(@as(f32, 0), fx.renderer.atlasFill(handle).?);

    var image = try asset.Image.alloc(testing.allocator, 16, 16);
    defer image.deinit(testing.allocator);
    @memset(image.pixels, 0xFF);

    for (0..4) |_| _ = try fx.renderer.atlasAdd(handle, image);
    try testing.expectApproxEqAbs(@as(f32, 1), fx.renderer.atlasFill(handle).?, 1e-6);

    // Full is a normal answer, and different from "no atlas this size will ever take it".
    try testing.expectError(error.AtlasFull, fx.renderer.atlasAdd(handle, image));

    var huge = try asset.Image.alloc(testing.allocator, 64, 8);
    defer huge.deinit(testing.allocator);
    try testing.expectError(error.RegionTooLarge, fx.renderer.atlasAdd(handle, huge));
}

test "destroying an atlas invalidates the regions cut from it" {
    // I1's payoff again: a region holds a texture handle, so a sprite still holding one
    // after the atlas went away is a clean error at the draw that uses it.
    var fx = try Fixture.init(64);
    defer fx.deinit();

    const handle = try fx.renderer.createAtlas(.{ .width = 32, .height = 32 }, .{});

    var image = try asset.Image.alloc(testing.allocator, 8, 8);
    defer image.deinit(testing.allocator);
    @memset(image.pixels, 0xFF);
    const region = try fx.renderer.atlasAdd(handle, image);

    fx.renderer.destroyAtlas(handle);
    try testing.expect(fx.renderer.atlasFill(handle) == null);
    try testing.expect(fx.renderer.atlasRegion(handle) == null);
    // Destroying it twice is a no-op, the same as for a texture.
    fx.renderer.destroyAtlas(handle);

    try fx.renderer.begin(fx.view());
    try testing.expectError(error.InvalidTexture, fx.renderer.drawSprite(.{
        .texture = region.texture,
        .uv = region.uv,
        .position = .init(0, 0),
        .size = .init(8, 8),
    }));
}

test "an atlas larger than the device can hold is refused" {
    var fx = try Fixture.init(64);
    defer fx.deinit();

    const caps = fx.device.capabilities();
    try testing.expectError(error.TextureTooLarge, fx.renderer.createAtlas(
        .{ .width = caps.max_texture_dimension + 1, .height = 16 },
        .{},
    ));
    // And an empty one, which would otherwise create a zero-sized texture.
    try testing.expectError(error.TextureTooLarge, fx.renderer.createAtlas(.{}, .{}));
}

test "a stale atlas handle is refused rather than resolving to another atlas" {
    var fx = try Fixture.init(64);
    defer fx.deinit();

    const first = try fx.renderer.createAtlas(.{ .width = 32, .height = 32 }, .{});
    fx.renderer.destroyAtlas(first);
    _ = try fx.renderer.createAtlas(.{ .width = 32, .height = 32 }, .{});

    var image = try asset.Image.alloc(testing.allocator, 4, 4);
    defer image.deinit(testing.allocator);
    try testing.expectError(error.InvalidAtlas, fx.renderer.atlasAdd(first, image));
}

test "text and sprites from one atlas are one draw call" {
    // §10's claim, checked rather than asserted in prose. If text ever grows a pipeline of
    // its own this is the test that fails.
    var fx = try Fixture.init(256);
    defer fx.deinit();

    const handle = try fx.renderer.createAtlas(.{ .width = 256, .height = 256 }, .{});

    var sheet = try asset.Image.alloc(testing.allocator, 32, 32);
    defer sheet.deinit(testing.allocator);
    @memset(sheet.pixels, 0xFF);
    const art = try fx.renderer.atlasAdd(handle, sheet);

    var glyphs = try asset.Image.alloc(testing.allocator, 128, 48);
    defer glyphs.deinit(testing.allocator);
    @memset(glyphs.pixels, 0xFF);
    const font: BitmapFont = .{
        .glyphs = try fx.renderer.atlasAdd(handle, glyphs),
        .cell = .{ .width = 8, .height = 8 },
        .columns = 16,
        .glyph_count = 96,
    };

    try fx.renderer.begin(fx.view());
    try fx.renderer.drawSprite(.{
        .texture = art.texture,
        .uv = art.uv,
        .position = .init(0, 0),
        .size = .init(32, 32),
    });
    try fx.renderer.drawText(font, "hello", .{ .position = .init(0, 0) });
    try fx.frame();

    const stats = fx.renderer.frameStats();
    try testing.expectEqual(@as(u32, 5), stats.glyphs);
    // Six things drawn — one sprite and five glyphs — from one texture, so one batch.
    try testing.expectEqual(@as(u32, 6), stats.sprites);
    try testing.expectEqual(@as(u32, 1), stats.draw_calls);
}

test "a font on its own texture works the same way, and costs the batch break" {
    // The other half of the claim: moving a font into an atlas is a change to how it is
    // created and to nothing else. Here it is standalone, and the only difference is the
    // second draw call — which is exactly what the atlas exists to remove.
    var fx = try Fixture.init(256);
    defer fx.deinit();

    var glyphs = try asset.Image.alloc(testing.allocator, 128, 48);
    defer glyphs.deinit(testing.allocator);
    @memset(glyphs.pixels, 0xFF);
    const texture = try fx.renderer.createTexture(glyphs, .{ .label = "font" });

    const font: BitmapFont = .{
        .glyphs = fx.renderer.textureRegion(texture).?,
        .cell = .{ .width = 8, .height = 8 },
        .columns = 16,
        .glyph_count = 96,
    };

    try fx.renderer.begin(fx.view());
    try fx.renderer.drawSprite(fx.sprite(fx.texture, 0, .alpha));
    try fx.renderer.drawText(font, "hi", .{ .position = .init(0, 0) });
    try fx.frame();

    const stats = fx.renderer.frameStats();
    try testing.expectEqual(@as(u32, 2), stats.glyphs);
    try testing.expectEqual(@as(u32, 2), stats.draw_calls);
}

test "text from a destroyed font is refused at the call that draws it" {
    var fx = try Fixture.init(64);
    defer fx.deinit();

    var glyphs = try asset.Image.alloc(testing.allocator, 128, 48);
    defer glyphs.deinit(testing.allocator);
    @memset(glyphs.pixels, 0xFF);
    const texture = try fx.renderer.createTexture(glyphs, .{});
    const font: BitmapFont = .{
        .glyphs = fx.renderer.textureRegion(texture).?,
        .cell = .{ .width = 8, .height = 8 },
        .columns = 16,
        .glyph_count = 96,
    };
    fx.renderer.destroyTexture(texture);

    try fx.renderer.begin(fx.view());
    try testing.expectError(error.InvalidTexture, fx.renderer.drawText(font, "x", .{
        .position = .init(0, 0),
    }));
}

test "drawing text outside a begin is a caller error, not a crash" {
    var fx = try Fixture.init(64);
    defer fx.deinit();

    const font: BitmapFont = .{
        .glyphs = .whole(fx.texture, .{ .width = 128, .height = 48 }),
        .cell = .{ .width = 8, .height = 8 },
        .columns = 16,
        .glyph_count = 96,
    };
    try testing.expectError(error.NotRecording, fx.renderer.drawText(font, "x", .{
        .position = .init(0, 0),
    }));
}

test "text a font cannot render still costs the frame nothing surprising" {
    // A font with no substitute draws nothing for a missing codepoint. The glyph count
    // reports what was actually drawn, which is the number worth having.
    var fx = try Fixture.init(64);
    defer fx.deinit();

    var glyphs = try asset.Image.alloc(testing.allocator, 128, 48);
    defer glyphs.deinit(testing.allocator);
    @memset(glyphs.pixels, 0xFF);
    const texture = try fx.renderer.createTexture(glyphs, .{});

    const font: BitmapFont = .{
        .glyphs = fx.renderer.textureRegion(texture).?,
        .cell = .{ .width = 8, .height = 8 },
        .columns = 16,
        .glyph_count = 96,
        .substitute = null,
    };

    try fx.renderer.begin(fx.view());
    try fx.renderer.drawText(font, "a\u{2603}b", .{ .position = .init(0, 0) });
    try fx.frame();

    try testing.expectEqual(@as(u32, 2), fx.renderer.frameStats().glyphs);
}

test "a frame has a world view and a screen view without being asked" {
    var fx = try Fixture.init(64);
    defer fx.deinit();

    try fx.renderer.begin(fx.view());
    // The default is world, so a game that has never heard of views is in the one it
    // expects.
    try testing.expectEqual(ViewId.world, fx.renderer.currentView());
    try fx.renderer.drawSprite(fx.sprite(fx.texture, 0, .alpha));

    try fx.renderer.setView(.screen);
    try fx.renderer.drawSprite(fx.sprite(fx.texture, 0, .alpha));
    try fx.frame();

    const stats = fx.renderer.frameStats();
    try testing.expectEqual(@as(u32, 2), stats.views);
    // Same texture, same blend, same layer: the only difference is the space, and that is
    // a different transform on the GPU.
    try testing.expectEqual(@as(u32, 2), stats.draw_calls);
}

test "the screen view does not move when the camera does" {
    // The property a HUD is for. Checked on the transform rather than on pixels, because
    // the transform is what the recorder binds.
    var fx = try Fixture.init(64);
    defer fx.deinit();

    try fx.renderer.begin(fx.view());
    const before = fx.renderer.views.items[ViewId.screen.index()].view_projection;
    const world_before = fx.renderer.views.items[ViewId.world.index()].view_projection;

    var moved = fx.view();
    moved.camera.center = .init(500, -250);
    moved.camera.zoom = 3;
    try fx.renderer.begin(moved);

    const after = fx.renderer.views.items[ViewId.screen.index()].view_projection;
    try testing.expectEqualSlices([4]f32, &before.cols, &after.cols);
    // And the world view did change, so the test is not passing because nothing moved.
    const world_after = fx.renderer.views.items[ViewId.world.index()].view_projection;
    try testing.expect(!std.mem.eql(u8, std.mem.asBytes(&world_before), std.mem.asBytes(&world_after)));
}

test "a view added this frame draws over the ones before it" {
    var fx = try Fixture.init(64);
    defer fx.deinit();

    try fx.renderer.begin(fx.view());
    const minimap = try fx.renderer.addView(.{ .camera = .{
        .viewport = .init(1000, 20, 260, 200),
        .zoom = 0.1,
    } });
    try testing.expectEqual(@as(usize, 2), minimap.index());

    // Submitted last-first, to show that the ordering is by view id and not by when the
    // draw happened.
    try fx.renderer.setView(minimap);
    try fx.renderer.drawSprite(fx.sprite(fx.texture, 0, .alpha));
    try fx.renderer.setView(.world);
    try fx.renderer.drawSprite(fx.sprite(fx.texture, 0, .alpha));
    try fx.frame();

    const stats = fx.renderer.frameStats();
    try testing.expectEqual(@as(u32, 3), stats.views);
    try testing.expectEqual(@as(u32, 2), stats.draw_calls);
    try testing.expectEqual(ViewId.world, fx.renderer.batcher.batches.items[0].view);
    try testing.expectEqual(minimap, fx.renderer.batcher.batches.items[1].view);
}

test "a view id the frame does not have is refused" {
    var fx = try Fixture.init(64);
    defer fx.deinit();

    try fx.renderer.begin(fx.view());
    try testing.expectError(error.InvalidView, fx.renderer.setView(.fromIndex(9)));
    // And the current view is unchanged, so a refused selection cannot silently redirect
    // the next hundred draws.
    try testing.expectEqual(ViewId.world, fx.renderer.currentView());
}

test "a view that cannot be drawn is refused, and the table is bounded" {
    var fx = try Fixture.init(64);
    defer fx.deinit();

    try fx.renderer.begin(fx.view());
    try testing.expectError(error.InvalidCamera, fx.renderer.addView(.{ .screen = .init(0, 0, 0, 10) }));

    // `addView` is reachable from a mod, so the table has a bound and the failure is an
    // error rather than growth until something else breaks.
    while (fx.renderer.views.items.len < view_mod.max_views) {
        _ = try fx.renderer.addView(.{ .screen = .init(0, 0, 8, 8) });
    }
    try testing.expectError(error.TooManyViews, fx.renderer.addView(.{ .screen = .init(0, 0, 8, 8) }));
}

test "views are a frame's business, not the renderer's" {
    var fx = try Fixture.init(64);
    defer fx.deinit();

    // Outside a frame there is no camera to derive one from, so both are refused rather
    // than answered from a stale table.
    try testing.expectError(error.NotRecording, fx.renderer.addView(.{ .screen = .init(0, 0, 8, 8) }));
    try testing.expectError(error.NotRecording, fx.renderer.setView(.screen));

    // And a view added in one frame does not survive into the next.
    try fx.renderer.begin(fx.view());
    const extra = try fx.renderer.addView(.{ .screen = .init(0, 0, 8, 8) });
    try fx.frame();

    try fx.renderer.begin(fx.view());
    try testing.expectError(error.InvalidView, fx.renderer.setView(extra));
}

test "text goes wherever the current view is" {
    // `drawText` takes no view of its own: that is the point of the current view being
    // renderer state rather than a field on every draw struct.
    var fx = try Fixture.init(64);
    defer fx.deinit();

    var glyphs = try asset.Image.alloc(testing.allocator, 128, 48);
    defer glyphs.deinit(testing.allocator);
    @memset(glyphs.pixels, 0xFF);
    const texture = try fx.renderer.createTexture(glyphs, .{});
    const font: BitmapFont = .{
        .glyphs = fx.renderer.textureRegion(texture).?,
        .cell = .{ .width = 8, .height = 8 },
        .columns = 16,
        .glyph_count = 96,
    };

    try fx.renderer.begin(fx.view());
    try fx.renderer.setView(.screen);
    try fx.renderer.drawText(font, "hud", .{ .position = .init(8, 8) });
    try fx.frame();

    try testing.expectEqual(@as(u32, 3), fx.renderer.frameStats().glyphs);
    try testing.expectEqual(ViewId.screen, fx.renderer.batcher.batches.items[0].view);
}

test "a tilemap layer costs one batch and only the tiles the camera can see" {
    var fx = try Fixture.init(16 * 1024);
    defer fx.deinit();

    // A thousand cells on a side is a million tiles. The camera is at the origin and so is
    // the map's corner, so it sees the 40 by 23 cells of the map's bottom-left quadrant that
    // fit in 640 by 360 points — and not the other 999,080.
    const map = try testing.allocator.alloc(u16, 1000 * 1000);
    defer testing.allocator.free(map);
    @memset(map, 0);

    try fx.renderer.begin(fx.view());
    try fx.renderer.drawTilemap(.{
        .tiles = fx.renderer.textureRegion(fx.texture).?,
        .tile_size = .{ .width = 1, .height = 1 },
        .columns = 2,
        .map = map,
        .width = 1000,
        .height = 1000,
        .cell = .init(16, 16),
    });
    try fx.frame();

    const stats = fx.renderer.frameStats();
    try testing.expectEqual(@as(u32, 40 * 23), stats.tiles);
    // Counted as sprites too, because that is what they are.
    try testing.expectEqual(stats.tiles, stats.sprites);
    // One texture, one layer, one view: one batch and one draw call, whatever the map size.
    try testing.expectEqual(@as(u32, 1), stats.batches);
    try testing.expectEqual(@as(u32, 1), stats.draw_calls);
}

test "a tilemap is recorded in the current view, like every other draw" {
    var fx = try Fixture.init(1024);
    defer fx.deinit();

    const map = [_]u16{ 0, 1, 2, 3 };
    const layer: TilemapLayer = .{
        .tiles = fx.renderer.textureRegion(fx.texture).?,
        .tile_size = .{ .width = 1, .height = 1 },
        .columns = 2,
        .map = &map,
        .width = 2,
        .height = 2,
        .cell = .init(16, 16),
    };

    try fx.renderer.begin(fx.view());
    // The world camera is centred on the origin, so all four cells of a map at the origin
    // are visible; the screen view is 1280x720 with its origin at the top-left, and the
    // same map placed at the same coordinates is inside it as well.
    try fx.renderer.drawTilemap(layer);
    try fx.renderer.setView(.screen);
    try fx.renderer.drawTilemap(layer);
    try fx.frame();

    const stats = fx.renderer.frameStats();
    try testing.expectEqual(@as(u32, 8), stats.tiles);
    // Two views cannot share a batch, which is the sort key doing its job.
    try testing.expectEqual(@as(u32, 2), stats.batches);
}

test "a tilemap is refused the way every other untrusted draw is" {
    var fx = try Fixture.init(1024);
    defer fx.deinit();

    const map = [_]u16{ 0, 1, 2, 3 };
    var layer: TilemapLayer = .{
        .tiles = fx.renderer.textureRegion(fx.texture).?,
        .tile_size = .{ .width = 1, .height = 1 },
        .columns = 2,
        .map = &map,
        .width = 2,
        .height = 2,
        .cell = .init(16, 16),
    };

    // Outside a frame.
    try testing.expectError(error.NotRecording, fx.renderer.drawTilemap(layer));

    try fx.renderer.begin(fx.view());
    // A texture this renderer never made, or has destroyed — the same check `drawSprite`
    // makes, and made once rather than once per tile.
    layer.tiles.texture = .none;
    try testing.expectError(error.InvalidTexture, fx.renderer.drawTilemap(layer));

    layer.tiles = fx.renderer.textureRegion(fx.texture).?;
    layer.width = 3; // claims six cells, carries four
    try testing.expectError(error.InvalidTilemap, fx.renderer.drawTilemap(layer));

    try fx.frame();
    try testing.expectEqual(@as(u32, 0), fx.renderer.frameStats().tiles);
}

test "the renderer owns a blank region, so no game has to build one" {
    var fx = try Fixture.init(1024);
    defer fx.deinit();

    const blank = fx.renderer.blankRegion();
    try testing.expect(!blank.texture.isNone());
    // The middle of a larger patch, so filtering at a drawn rectangle's edge samples white
    // on both sides: four pixels out of eight.
    try testing.expectEqual(@as(u32, 4), blank.size_px.width);
    try testing.expectEqual(@as(u32, 4), blank.size_px.height);

    // And it draws like any other region.
    try fx.renderer.begin(fx.view());
    try fx.renderer.drawSprite(.{
        .texture = blank.texture,
        .uv = blank.uv,
        .position = .init(0, 0),
        .size = .init(100, 20),
    });
    try fx.frame();
    try testing.expectEqual(@as(u32, 1), fx.renderer.frameStats().draw_calls);
}

test "a game cannot destroy the renderer's blank texture" {
    var fx = try Fixture.init(1024);
    defer fx.deinit();

    const blank = fx.renderer.blankRegion();
    fx.renderer.destroyTexture(blank.texture);

    // Still resolvable, and still drawable: the request was refused, not deferred.
    try testing.expect(fx.renderer.textureRegion(blank.texture) != null);
}

test "a clip change costs a draw call and clearing it costs another" {
    var fx = try Fixture.init(1024);
    defer fx.deinit();

    try fx.renderer.begin(fx.view());
    try fx.renderer.drawSprite(fx.sprite(fx.texture, 0, .alpha));
    try fx.renderer.setClip(.init(10, 10, 100, 100));
    try fx.renderer.drawSprite(fx.sprite(fx.texture, 0, .alpha));
    try fx.renderer.drawSprite(fx.sprite(fx.texture, 0, .alpha));
    try fx.renderer.setClip(null);
    try fx.renderer.drawSprite(fx.sprite(fx.texture, 0, .alpha));
    try fx.frame();

    const stats = fx.renderer.frameStats();
    try testing.expectEqual(@as(u32, 4), stats.sprites);
    // One texture, one blend, one view: the scissor is the only thing that changed, and it
    // shows up as batches rather than as a counter of its own.
    try testing.expectEqual(@as(u32, 3), stats.batches);
    try testing.expectEqual(@as(u32, 3), stats.draw_calls);
}

test "the clip resets with the frame, so it cannot leak into the next one" {
    var fx = try Fixture.init(1024);
    defer fx.deinit();

    try fx.renderer.begin(fx.view());
    try fx.renderer.setClip(.init(0, 0, 10, 10));
    try testing.expect(fx.renderer.currentClip() != null);
    try fx.frame();

    try fx.renderer.begin(fx.view());
    try testing.expectEqual(@as(?core.math.Rect, null), fx.renderer.currentClip());
    try fx.frame();
}

test "a clip cannot be set outside a frame" {
    var fx = try Fixture.init(1024);
    defer fx.deinit();
    try testing.expectError(error.NotRecording, fx.renderer.setClip(.init(0, 0, 1, 1)));
}

test "a clip that is not a finite rectangle clips everything away" {
    // Untrusted input: a layout driven by content, and from M7 by a mod, can produce one.
    // It collapses to an empty rectangle rather than being asserted on, so the failure is
    // visible immediately instead of leaking a panel across the screen.
    var fx = try Fixture.init(1024);
    defer fx.deinit();

    try fx.renderer.begin(fx.view());
    try fx.renderer.setClip(.init(std.math.nan(f32), 0, 100, 100));
    try testing.expect(fx.renderer.currentClip().?.isEmpty());
    try fx.renderer.drawSprite(fx.sprite(fx.texture, 0, .alpha));
    try fx.frame();

    // The sprite is still submitted and still drawn — clipping is the pass's business, not
    // the batcher's — but the scissor it is drawn under is empty.
    try testing.expectEqual(@as(u32, 1), fx.renderer.frameStats().draw_calls);
}

test "a clip is clamped to the viewport it is recorded in" {
    var fx = try Fixture.init(1024);
    defer fx.deinit();
    const viewport: rhi.command.Viewport = .{ .x = 0, .y = 0, .width = 1280, .height = 720 };

    // Hanging off the right and the bottom: clamped, never larger than the target.
    const over = fx.renderer.scissorFor(viewport, .init(1200, 700, 400, 400));
    try testing.expectEqual(@as(u32, 1200), over.x);
    try testing.expectEqual(@as(u32, 80), over.width);
    try testing.expectEqual(@as(u32, 20), over.height);

    // Entirely outside: empty rather than inverted.
    const away = fx.renderer.scissorFor(viewport, .init(4000, 4000, 10, 10));
    try testing.expectEqual(@as(u32, 0), away.width);
    try testing.expectEqual(@as(u32, 0), away.height);

    // No clip is the viewport itself, which is what a scissor has to be set to when the
    // answer is "none".
    const none = fx.renderer.scissorFor(viewport, null);
    try testing.expectEqual(@as(u32, 1280), none.width);
    try testing.expectEqual(@as(u32, 720), none.height);
}

test "a clip is in screen points and is scaled to pixels when recorded" {
    var fx = try Fixture.init(1024);
    defer fx.deinit();
    // A retina window: the viewport is in pixels, the clip is in the points the mouse is
    // reported in, and the pixel scale is the only thing that bridges them.
    fx.renderer.view = .{ .camera = .{ .viewport = .init(0, 0, 640, 480) }, .pixel_scale = 2 };
    const viewport: rhi.command.Viewport = .{ .x = 0, .y = 0, .width = 1280, .height = 960 };

    const scissor = fx.renderer.scissorFor(viewport, .init(10, 20, 100, 50));
    try testing.expectEqual(@as(u32, 20), scissor.x);
    try testing.expectEqual(@as(u32, 40), scissor.y);
    try testing.expectEqual(@as(u32, 200), scissor.width);
    try testing.expectEqual(@as(u32, 100), scissor.height);
}
