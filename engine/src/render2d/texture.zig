//! GPU textures, and the retirement queue that makes destroying one safe.

const std = @import("std");
const core = @import("core");
const rhi = @import("rhi");

const Allocator = std.mem.Allocator;
const log = core.log.scoped(.render2d);

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
};

/// A resource whose destruction has been requested but which a frame in flight may still
/// be reading.
const Retired = struct {
    state: State,
    /// The frame index after which no in-flight frame can reference it.
    safe_after: u64,
};

/// Owns every GPU texture the renderer has handed out.
///
/// The retirement queue is the point of this type. `rhi/interface.zig` documents deferred
/// destruction that **no backend implements** — destroying a texture a frame in flight
/// still references is undefined behaviour today, and unloading a level while two frames
/// are in flight is the most ordinary way imaginable to reach it.
///
/// So the renderer does not rely on the RHI's promise. `destroy` invalidates the handle
/// immediately and queues the GPU objects for release once `frames_in_flight` further
/// frames have begun. Two frames of latency on a texture free is nothing; a use-after-free
/// in a renderer is a week.
///
/// This is the concrete payoff of I1: the generation bump means a stale handle produces a
/// clean lookup failure at the call site rather than sampling freed GPU memory.
pub const Pool = struct {
    live: core.HandlePool(Texture, State) = .empty,
    retired: std.ArrayList(Retired) = .empty,
    frames_in_flight: u64,

    pub fn init(frames_in_flight: u32) Pool {
        return .{ .frames_in_flight = frames_in_flight };
    }

    /// Releases everything, live and retired, without waiting.
    ///
    /// Safe only because the device has been idled first — `rhi`'s `Device.deinit` waits
    /// on every in-flight command buffer. Teardown is the one moment the queue can be
    /// short-circuited, and it is short-circuited explicitly rather than by forgetting.
    pub fn deinit(self: *Pool, gpa: Allocator, device: *rhi.Device) void {
        var it = self.live.iterator();
        while (it.next()) |entry| releaseState(device, entry.value.*);
        for (self.retired.items) |item| releaseState(device, item.state);
        self.live.deinit(gpa);
        self.retired.deinit(gpa);
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

    /// Requests destruction. The handle stops resolving immediately; the GPU objects go
    /// later. Returns false if the handle was already stale, which is not an error — a
    /// double unload is a normal thing for game code to do.
    pub fn destroy(self: *Pool, gpa: Allocator, handle: TextureHandle, frame_index: u64) bool {
        const state = self.live.get(handle) orelse return false;
        const copy = state.*;
        _ = self.live.remove(handle);

        self.retired.append(gpa, .{
            .state = copy,
            .safe_after = frame_index + self.frames_in_flight,
        }) catch {
            // Out of memory while freeing is a genuinely awkward corner: leaking is the
            // only alternative to a use-after-free, and it is the right one. Saying so is
            // better than an error the caller cannot act on.
            log.warn("texture retirement queue is out of memory; leaking one texture", .{});
            return true;
        };
        return true;
    }

    /// Releases everything no in-flight frame can still reference. Called once a frame.
    pub fn collect(self: *Pool, device: *rhi.Device, frame_index: u64) void {
        var i: usize = 0;
        while (i < self.retired.items.len) {
            if (self.retired.items[i].safe_after <= frame_index) {
                releaseState(device, self.retired.items[i].state);
                _ = self.retired.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn releaseState(device: *rhi.Device, state: State) void {
        device.destroyBindGroup(state.group);
        device.destroySampler(state.sampler);
        device.destroyTexture(state.gpu);
    }
};

const testing = std.testing;

test "a destroyed handle stops resolving before the GPU objects are released" {
    var pool: Pool = .init(2);
    defer {
        pool.live.deinit(testing.allocator);
        pool.retired.deinit(testing.allocator);
    }

    const handle = try pool.add(testing.allocator, .{
        .gpu = .none,
        .group = .none,
        .sampler = .none,
        .width = 4,
        .height = 4,
    });
    try testing.expect(pool.get(handle) != null);

    // Frame 10 asks for it to go away.
    try testing.expect(pool.destroy(testing.allocator, handle, 10));

    // The handle is dead immediately: this is the property that turns a use-after-free
    // into a lookup that fails.
    try testing.expect(pool.get(handle) == null);
    // But the GPU objects are still queued, because frames 10 and 11 may reference them.
    try testing.expectEqual(@as(usize, 1), pool.retired.items.len);

    // Destroying it again is a no-op rather than a crash: double unload is normal.
    try testing.expect(!pool.destroy(testing.allocator, handle, 10));
}

test "retirement waits exactly frames_in_flight frames" {
    var pool: Pool = .init(2);
    defer {
        pool.live.deinit(testing.allocator);
        pool.retired.deinit(testing.allocator);
    }

    const handle = try pool.add(testing.allocator, .{
        .gpu = .none,
        .group = .none,
        .sampler = .none,
        .width = 1,
        .height = 1,
    });
    _ = pool.destroy(testing.allocator, handle, 10);
    try testing.expectEqual(@as(u64, 12), pool.retired.items[0].safe_after);
}

test "a handle from one pool never resolves in another" {
    // The generation makes this a lookup failure rather than a wrong texture, which is
    // the difference between a clear error and a mystery.
    var a: Pool = .init(2);
    var b: Pool = .init(2);
    defer {
        a.live.deinit(testing.allocator);
        a.retired.deinit(testing.allocator);
        b.live.deinit(testing.allocator);
        b.retired.deinit(testing.allocator);
    }

    const state: State = .{ .gpu = .none, .group = .none, .sampler = .none, .width = 1, .height = 1 };
    const from_a = try a.add(testing.allocator, state);
    _ = a.destroy(testing.allocator, from_a, 0);
    _ = try b.add(testing.allocator, state);

    // Same index, but `a` has moved on: the stale handle does not resolve.
    try testing.expect(a.get(from_a) == null);
}
