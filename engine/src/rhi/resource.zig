//! GPU resources: buffers, textures, samplers, and the two things about them that Metal
//! would let us ignore — **memory intent** and **resource state**.
//!
//! Design: `docs/design/rhi.md` §3, §5, §6.

const std = @import("std");
const core = @import("core");
const format = @import("format.zig");

// -- identity ------------------------------------------------------------------------
//
// Phantom tags. Every RHI object is a generational handle (I1): no raw GPU pointer crosses
// out of `rhi`, nothing above stores a backend object, and a destroyed resource's handle
// resolves to nothing rather than to whatever took its slot.

pub const Buffer = opaque {};
pub const Texture = opaque {};
pub const Sampler = opaque {};
pub const ShaderModule = opaque {};

pub const BufferHandle = core.Handle(Buffer);
pub const TextureHandle = core.Handle(Texture);
pub const SamplerHandle = core.Handle(Sampler);
pub const ShaderModuleHandle = core.Handle(ShaderModule);

pub const Extent2D = struct {
    width: u32 = 0,
    height: u32 = 0,

    pub fn eql(a: Extent2D, b: Extent2D) bool {
        return a.width == b.width and a.height == b.height;
    }
    pub fn isEmpty(e: Extent2D) bool {
        return e.width == 0 or e.height == 0;
    }

    /// The extent of mip level `level`, halving and never reaching zero.
    ///
    /// The clamp at 1 is the part worth stating: a 16x1 texture's level 4 is 1x1, not
    /// 1x0, and every graphics API agrees on that. Written once here rather than at each
    /// place that needs to bound a copy.
    pub fn mipLevel(e: Extent2D, level: u32) Extent2D {
        const shift: u5 = @intCast(@min(level, 31));
        return .{
            .width = @max(1, e.width >> shift),
            .height = @max(1, e.height >> shift),
        };
    }
};

/// The top-left corner of a rectangle in **texture space**, in texels.
///
/// Y increases downward, which is the same direction `Viewport` uses and the same
/// direction every image format on disk stores its rows in. That this disagrees with
/// `clip_space.y_axis` is not a contradiction: they are different spaces, and the
/// projection matrix is what bridges them (`command.zig`).
pub const Origin2D = struct {
    x: u32 = 0,
    y: u32 = 0,

    pub fn isZero(o: Origin2D) bool {
        return o.x == 0 and o.y == 0;
    }
};

// -- memory --------------------------------------------------------------------------

/// What a resource is *for*, rather than where it lives.
///
/// The rule that makes this more than a hint: **a `device_local` resource is never
/// CPU-mappable through the RHI.** Getting data into one means writing an `upload` buffer
/// and recording an explicit copy.
///
/// On Apple Silicon the memory really is unified and the Metal backend could skip the
/// staging copy entirely. It deliberately does not offer callers that option. An engine
/// tuned only on unified memory develops the habit of writing straight into vertex buffers
/// every frame, and then runs at a fraction of its speed on a discrete GPU where that write
/// crosses PCIe. The cost of the discipline is one copy on a machine that did not need it;
/// the cost of skipping it is discovered on hardware we do not own.
pub const MemoryIntent = enum {
    /// GPU reads and writes it constantly. Never mappable.
    device_local,
    /// CPU writes, GPU reads once. The source of a staging copy.
    upload,
    /// GPU writes, CPU reads. Screenshots and query results.
    readback,

    /// Whether `mapBuffer` is permitted. The whole point of the enum.
    pub fn isMappable(self: MemoryIntent) bool {
        return self != .device_local;
    }
};

/// What a resource is currently being used for.
///
/// Metal tracks this automatically; Vulkan and D3D12 require every transition to be stated
/// and go catastrophically wrong when one is missed. The RHI declares them, the Metal
/// backend discards them, and the validation backend checks them — which is what keeps the
/// interface honest while only one real backend exists.
pub const ResourceState = enum {
    /// Contents are not worth preserving. Transitioning *from* this is free everywhere and
    /// is the correct way to begin a frame with a target about to be cleared.
    /// Transitioning *to* it is not a thing.
    undefined,
    render_target,
    depth_stencil,
    shader_read,
    copy_src,
    copy_dst,
    present,
};

// -- buffers -------------------------------------------------------------------------

/// How a buffer may be used. Declared up front because Vulkan and D3D12 both need it at
/// creation time, and because it is what the validation backend checks a binding against.
pub const BufferUsage = packed struct(u8) {
    vertex: bool = false,
    index: bool = false,
    uniform: bool = false,
    storage: bool = false,
    copy_src: bool = false,
    copy_dst: bool = false,
    _reserved: u2 = 0,

    pub fn any(self: BufferUsage) bool {
        return @as(u8, @bitCast(self)) != 0;
    }
};

pub const BufferDesc = struct {
    /// Shown in GPU debuggers and frame captures. Free in release builds, invaluable in
    /// Xcode's frame capture, which is one of the reasons Metal is the first backend.
    label: []const u8 = "",
    size: u64,
    usage: BufferUsage,
    memory: MemoryIntent = .device_local,
};

// -- textures ------------------------------------------------------------------------

pub const TextureUsage = packed struct(u8) {
    sampled: bool = false,
    render_target: bool = false,
    depth_stencil: bool = false,
    copy_src: bool = false,
    copy_dst: bool = false,
    _reserved: u3 = 0,

    pub fn any(self: TextureUsage) bool {
        return @as(u8, @bitCast(self)) != 0;
    }
};

pub const TextureDesc = struct {
    label: []const u8 = "",
    size: Extent2D,
    format: format.TextureFormat,
    usage: TextureUsage,
    mip_levels: u32 = 1,
    /// Textures are device-local in every case Foundry has: uploads go through a staging
    /// buffer and a copy. Present as a field rather than hardcoded because a readback
    /// target is a legitimate future use.
    memory: MemoryIntent = .device_local,
    /// The state the texture is in immediately after creation. Almost always `undefined`:
    /// a freshly created texture has no contents worth preserving.
    initial_state: ResourceState = .undefined,
};

// -- samplers ------------------------------------------------------------------------

pub const FilterMode = enum { nearest, linear };

pub const AddressMode = enum { clamp_to_edge, repeat, mirror_repeat };

pub const SamplerDesc = struct {
    label: []const u8 = "",
    /// `nearest` by default, because Foundry is 2D first and a pixel-art sprite filtered
    /// linearly is a bug report. 3D and scaled 2D ask for `linear` explicitly.
    min_filter: FilterMode = .nearest,
    mag_filter: FilterMode = .nearest,
    mip_filter: FilterMode = .nearest,
    address_u: AddressMode = .clamp_to_edge,
    address_v: AddressMode = .clamp_to_edge,
};

// -- shaders -------------------------------------------------------------------------

/// Backend-specific compiled shader bytes: a `.metallib`, SPIR-V, or DXIL.
///
/// `rhi` does not know what a content ID is, does not read files and does not compile
/// anything. Selecting the right variant for the running backend is `render2d`'s job
/// (ADR-0015), which depends on both `rhi` and `asset` and is where the two should meet.
pub const ShaderModuleDesc = struct {
    label: []const u8 = "",
    /// Compiled bytes for the *selected* backend. Copied by the backend if it needs to
    /// retain them; the caller may free the slice once this returns.
    bytes: []const u8,
};

/// Source text for runtime compilation, used by shader hot reload (ADR-0015).
///
/// A backend may report this unsupported: the Metal backend compiles MSL at runtime, and a
/// future SPIR-V backend could not without shipping a compiler. It is on the interface now
/// because it is the same mechanism mod-authored shaders will need at M7, and discovering
/// then that the interface cannot express it would be expensive.
pub const ShaderSourceDesc = struct {
    label: []const u8 = "",
    source: []const u8,
};

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

test "device_local memory is never mappable" {
    // The single rule that keeps unified memory from becoming a habit.
    try testing.expect(!MemoryIntent.device_local.isMappable());
    try testing.expect(MemoryIntent.upload.isMappable());
    try testing.expect(MemoryIntent.readback.isMappable());
}

test "a zeroed handle is none, for every resource kind" {
    try testing.expect(std.mem.zeroes(BufferHandle).isNone());
    try testing.expect(std.mem.zeroes(TextureHandle).isNone());
    try testing.expect(std.mem.zeroes(SamplerHandle).isNone());
    try testing.expect(std.mem.zeroes(ShaderModuleHandle).isNone());
}

test "resource handles of different kinds are different types" {
    // A texture handle must not be passable where a buffer handle is wanted (I1).
    try testing.expect(BufferHandle != TextureHandle);
    try testing.expect(TextureHandle != SamplerHandle);
}

test "usage flags pack into one byte and round-trip" {
    try testing.expectEqual(@as(usize, 1), @sizeOf(BufferUsage));
    try testing.expectEqual(@as(usize, 1), @sizeOf(TextureUsage));

    const u: BufferUsage = .{ .vertex = true, .copy_dst = true };
    try testing.expect(u.any());
    try testing.expect(u.vertex and u.copy_dst);
    try testing.expect(!u.index);
    try testing.expect(!(BufferUsage{}).any());
}

test "undefined is the default resource state" {
    // A freshly created texture has no contents worth preserving, and saying so is what
    // makes the first transition free on every backend.
    const desc: TextureDesc = .{
        .size = .{ .width = 4, .height = 4 },
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true },
    };
    try testing.expectEqual(ResourceState.undefined, desc.initial_state);
    try testing.expectEqual(MemoryIntent.device_local, desc.memory);
}

test "samplers default to nearest, because Foundry is 2D first" {
    const s: SamplerDesc = .{};
    try testing.expectEqual(FilterMode.nearest, s.min_filter);
    try testing.expectEqual(FilterMode.nearest, s.mag_filter);
    try testing.expectEqual(AddressMode.clamp_to_edge, s.address_u);
}

test "extent comparison" {
    try testing.expect((Extent2D{ .width = 1, .height = 2 }).eql(.{ .width = 1, .height = 2 }));
    try testing.expect(!(Extent2D{ .width = 1, .height = 2 }).eql(.{ .width = 2, .height = 1 }));
    try testing.expect((Extent2D{ .width = 0, .height = 5 }).isEmpty());
}

test "a mip level halves without ever reaching zero" {
    const base: Extent2D = .{ .width = 16, .height = 4 };
    try testing.expect(base.mipLevel(0).eql(.{ .width = 16, .height = 4 }));
    try testing.expect(base.mipLevel(2).eql(.{ .width = 4, .height = 1 }));
    // Level 4 is where the two axes stop agreeing: 1x1, not 1x0. Every graphics API
    // clamps here and a copy bounded by a zero extent would reject legal writes.
    try testing.expect(base.mipLevel(4).eql(.{ .width = 1, .height = 1 }));
    // A nonsense level still produces something bounded rather than a shift overflow.
    try testing.expect(base.mipLevel(999).eql(.{ .width = 1, .height = 1 }));
}

test "an origin defaults to the corner" {
    try testing.expect((Origin2D{}).isZero());
    try testing.expect(!(Origin2D{ .y = 1 }).isZero());
}
