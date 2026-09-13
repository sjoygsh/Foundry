//! GPU textures, as the renderer hands them out.

const std = @import("std");
const core = @import("core");
const rhi = @import("rhi");

const Allocator = std.mem.Allocator;

/// Phantom tag for `TextureHandle`. Never instantiated; it exists so that a renderer
/// texture cannot be confused with any other handle (I1).
pub const Texture = opaque {};

/// A texture, as a game refers to it.
///
/// **Deliberately not an `rhi.TextureHandle`.** A game holding one of those would be
/// holding an RHI type, which CLAUDE.md §4.2 forbids, and would also be holding something
/// whose lifetime rules it has no way to see.
pub const TextureHandle = core.Handle(Texture);

/// A size in pixels.
///
/// **`render2d`'s own, deliberately not `rhi.Extent2D`.** This type appears in the
/// game-facing API — `textureSize`, `createAtlas`, `Region`, `BitmapFont.cell` — and
/// CLAUDE.md §4.2 says games never touch the RHI. A game that had to name `rhi.Extent2D`
/// to ask how big its texture is would be touching it.
pub const Extent2D = struct {
    width: u32 = 0,
    height: u32 = 0,

    pub fn eql(a: Extent2D, b: Extent2D) bool {
        return a.width == b.width and a.height == b.height;
    }
    pub fn isEmpty(e: Extent2D) bool {
        return e.width == 0 or e.height == 0;
    }
};

pub const Filter = enum { nearest, linear };
pub const Wrap = enum { clamp, repeat };

pub const TextureOptions = struct {
    /// **Nearest by default.** Linear silently blurs upscaled pixel art and nothing in
    /// the API tells you why; nearest is visibly wrong for photographic content, which
    /// sends you looking for the setting. Defaults should fail loudly.
    filter: Filter = .nearest,
    wrap: Wrap = .clamp,
    label: []const u8 = "texture",
};

/// What the renderer keeps for each live texture.
pub const State = struct {
    gpu: rhi.TextureHandle,
    /// Bind group 0: this texture and its sampler. Built once at creation, because a
    /// bind group per texture is what makes a batch switch cost one `setBindGroup`.
    group: rhi.BindGroupHandle,
    sampler: rhi.SamplerHandle,
    width: u32,
    height: u32,
    /// The state the renderer's submitted work leaves the texture in, so that the next
    /// upload's barrier declares the truth (`rhi.md` §6). `undefined` until the first write.
    ///
    /// Tracked rather than assumed because `undefined` is not a neutral answer: it says the
    /// contents are not worth preserving, and a backend is entitled to discard them. That
    /// is right for a new texture and wrong for an atlas with images already in it.
    state: rhi.ResourceState = .undefined,
};

/// Owns every GPU texture the renderer has handed out.
///
/// **Destruction is two lifetimes, and each has one owner.** The renderer's handle dies
/// the moment `destroy` is called, so a stale handle is a lookup that fails at the call
/// site rather than a draw from freed memory — the payoff of I1. The GPU objects belong to
/// the device, which keeps them until every recording that could have used them has
/// finished (`rhi.md` §3, ADR-0035). The renderer keeps no retirement of its own: a second
/// timeline counting frames above the one counting submissions could only disagree with it,
/// and an upload made outside any frame is exactly where it would.
pub const Pool = struct {
    live: core.HandlePool(Texture, State) = .empty,

    pub const empty: Pool = .{};

    /// Destroys everything still live.
    pub fn deinit(self: *Pool, gpa: Allocator, device: *rhi.Device) void {
        var it = self.live.iterator();
        while (it.next()) |entry| releaseState(device, entry.value.*);
        self.live.deinit(gpa);
        self.* = undefined;
    }

    pub fn add(self: *Pool, gpa: Allocator, state: State) Allocator.Error!TextureHandle {
        return self.live.add(gpa, state);
    }

    pub fn get(self: *Pool, handle: TextureHandle) ?*State {
        return self.live.get(handle);
    }

    pub fn count(self: *const Pool) u32 {
        return self.live.count();
    }

    /// The handle stops resolving now; the device decides when the GPU objects go.
    /// Returns false if the handle was already stale, which is not an error — a double
    /// unload is a normal thing for game code to do.
    ///
    /// Cannot fail and allocates nothing: the device reserved each object's retirement
    /// when it was created.
    pub fn destroy(self: *Pool, device: *rhi.Device, handle: TextureHandle) bool {
        const state = self.live.get(handle) orelse return false;
        const copy = state.*;
        _ = self.live.remove(handle);
        releaseState(device, copy);
        return true;
    }

    fn releaseState(device: *rhi.Device, state: State) void {
        device.destroyBindGroup(state.group);
        device.destroySampler(state.sampler);
        device.destroyTexture(state.gpu);
    }
};

const testing = std.testing;

/// A texture, its sampler and a group naming both: the three objects a `State` holds.
fn createState(device: *rhi.Device, layout: rhi.BindGroupLayoutHandle) !State {
    const gpu = try device.createTexture(.{
        .label = "pool test",
        .size = .{ .width = 4, .height = 4 },
        .format = .rgba8_unorm_srgb,
        .usage = .{ .sampled = true, .copy_dst = true },
    });
    const sampler = try device.createSampler(.{ .label = "pool test" });
    const group = try device.createBindGroup(.{
        .label = "pool test",
        .layout = layout,
        .entries = &.{
            .{ .binding = 0, .resource = .{ .sampled_texture = gpu } },
            .{ .binding = 1, .resource = .{ .sampler = sampler } },
        },
    });
    return .{ .gpu = gpu, .group = group, .sampler = sampler, .width = 4, .height = 4 };
}

fn createLayout(device: *rhi.Device) !rhi.BindGroupLayoutHandle {
    return device.createBindGroupLayout(.{
        .label = "pool test",
        .entries = &.{
            .{ .binding = 0, .type = .sampled_texture, .visibility = .{ .fragment = true } },
            .{ .binding = 1, .type = .sampler, .visibility = .{ .fragment = true } },
        },
    });
}

test "a destroyed handle stops resolving at once, and the device keeps its objects for unfinished work" {
    const device = try rhi.Device.init(testing.allocator, .{});
    defer device.deinit();
    const layout = try createLayout(device);
    defer device.destroyBindGroupLayout(layout);

    var pool: Pool = .empty;
    defer pool.deinit(testing.allocator, device);
    const handle = try pool.add(testing.allocator, try createState(device, layout));

    // A recording begun before the destroy may use the texture, so the device must keep it.
    const cmd = try device.beginCommandBuffer();
    try testing.expect(pool.destroy(device, handle));

    // The handle is dead immediately: this is the property that turns a use-after-free
    // into a lookup that fails.
    try testing.expect(pool.get(handle) == null);
    // The texture, its sampler and its group are all still held by the device.
    try testing.expectEqual(@as(usize, 3), device.retiredCount());

    // Destroying it again is a no-op rather than a crash: double unload is normal.
    try testing.expect(!pool.destroy(device, handle));

    try cmd.submit();
    device.waitIdle();
    try testing.expectEqual(@as(usize, 0), device.retiredCount());
}

test "a handle from one pool never resolves in another" {
    // The generation makes this a lookup failure rather than a wrong texture, which is
    // the difference between a clear error and a mystery.
    const device = try rhi.Device.init(testing.allocator, .{});
    defer device.deinit();
    const layout = try createLayout(device);
    defer device.destroyBindGroupLayout(layout);

    var a: Pool = .empty;
    var b: Pool = .empty;
    defer {
        a.deinit(testing.allocator, device);
        b.deinit(testing.allocator, device);
    }

    const from_a = try a.add(testing.allocator, try createState(device, layout));
    _ = a.destroy(device, from_a);
    _ = try b.add(testing.allocator, try createState(device, layout));

    // Same index, but `a` has moved on: the stale handle does not resolve.
    try testing.expect(a.get(from_a) == null);
}
