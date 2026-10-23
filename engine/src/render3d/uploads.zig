//! Runtime meshes and textures whose staging fill runs on the background pool, finished in
//! request order at a pump the game calls (`docs/design/runtime-geometry.md` §6).
//!
//! **Main thread, at the request:** what costs nothing to check, where a refusal changes
//! nothing and leaves the bytes the caller's, and the staging reservation. **Pool:** the fill.
//! A mesh is validated and its submesh boxes measured there, both linear in its indices, then
//! copied into the reservation at the offsets `Renderer.uploadMesh` reads; a mesh that does not
//! validate fails at its finish, and `failure` says why (Step 6's Resolution). **Main thread,
//! at the pump:** the copy's command buffer and, for a create, the handle. **Pool,
//! afterwards:** freeing the CPU bytes, which is M27 Step 9's `free_on_pool` reason.
//!
//! **Order is the request's, never the pool's.** Only the oldest unfinished request may finish,
//! so the same requests finish in the same order under any interleaving of fills
//! (`core.tasks.Manual` proves it). **Arrival is presentation** (ADR-0061): a game may draw what
//! `state` calls `done`, and simulation never reads `state`.
//!
//! It is not an `asset.Registry` path, because the registry is keyed by content ID and these
//! resources have none (ADR-0063). `app` does not pump it, because `app` owns no renderer.

const std = @import("std");
const core = @import("core");
const asset = @import("asset");
const renderer_mod = @import("renderer.zig");

const Allocator = std.mem.Allocator;
const Renderer = renderer_mod.Renderer;
const MeshHandle = renderer_mod.MeshHandle;
const TextureHandle = renderer_mod.TextureHandle;
const StagingReservation = renderer_mod.StagingReservation;
const log = core.log.scoped(.render3d);

pub const Upload = opaque {};
pub const UploadHandle = core.Handle(Upload);

/// What one `Uploads` may hold. M48 bounds a mod's by these (`runtime-geometry.md` §9).
pub const Limits = struct {
    /// Requests held at once: pending, or finished and not yet released.
    max_requests: u32 = 256,
    /// Staging that pending requests hold reserved.
    max_pending_bytes: u64 = 64 << 20,
};

pub const State = enum {
    /// Requested, and not yet finished by a pump.
    pending,
    /// Finished: `result` names the mesh or texture.
    done,
    /// Refused at its finish, as `failure` says: its target went, or the device refused.
    failed,
    /// Released while pending, or dropped by `quiesce`: never finished.
    cancelled,
};

pub const Result = union(enum) {
    mesh: MeshHandle,
    texture: TextureHandle,
};

pub const PumpStats = struct {
    finished: u32 = 0,
    failed: u32 = 0,
    /// Still waiting for their turn afterwards.
    pending: u32 = 0,
    /// What the finishes charged the budget.
    bytes: u64 = 0,
};

pub const Error = renderer_mod.Error || core.tasks.StartError || error{
    /// `Limits.max_requests` are held; release finished ones.
    TooManyUploads,
    /// The request would hold more staging than `Limits.max_pending_bytes`.
    TooManyUploadBytes,
};

const Kind = enum { create_mesh, update_mesh, create_texture, write_chain };

/// One request. Its address is stable, because the pool holds it between `start` and `Done`.
/// **What a pool task touches:** the fill reads `mesh` or `chain` and writes `staged`'s bytes;
/// the free frees `mesh` or `chain`. The main thread touches neither until that task's flag is
/// set, and touches nothing else a task does.
const Request = struct {
    handle: UploadHandle = .none,
    kind: Kind,
    gpa: Allocator,
    mesh: asset.OwnedMesh = undefined,
    chain: asset.MipChain = undefined,
    /// Owned: a request outlives the caller's string.
    label: []u8,
    options: renderer_mod.TextureOptions = .{},
    color_space: asset.ColorSpace = .srgb,
    target_mesh: MeshHandle = .none,
    target_texture: TextureHandle = .none,
    staged: ?StagingReservation,
    bytes: u64,
    /// A mesh's submesh boxes, measured by the fill on the pool, with this `Uploads`' allocator.
    prepared: []asset.MeshAabb = &.{},
    /// Why the fill refused the mesh: then it fails at its finish, uploading nothing.
    fill_error: ?renderer_mod.Error = null,
    filled: core.tasks.Done = .{},
    freed: core.tasks.Done = .{},
    /// The CPU bytes are still held: until the free task has run.
    holds_bytes: bool = true,
    state: State = .pending,
    result: ?Result = null,
    failure: ?renderer_mod.Error = null,
    /// The caller is done with the handle; the entry goes once nothing runs for it.
    released: bool = false,

    fn fill(context: *anyopaque) void {
        const self: *Request = @ptrCast(@alignCast(context));
        const staged = self.staged.?;
        switch (self.kind) {
            .create_mesh, .update_mesh => {
                self.mesh.mesh.validate() catch |err| {
                    self.fill_error = err;
                    return;
                };
                self.prepared = renderer_mod.submeshBounds(self.gpa, self.mesh.mesh) catch |err| {
                    self.fill_error = err;
                    return;
                };
                renderer_mod.fillMeshStaging(self.mesh.mesh, staged.bytes);
            },
            .create_texture, .write_chain => @memcpy(staged.bytes[0..self.chain.bytes.len], self.chain.bytes),
        }
    }

    fn freeBytes(context: *anyopaque) void {
        const self: *Request = @ptrCast(@alignCast(context));
        switch (self.kind) {
            .create_mesh, .update_mesh => self.mesh.deinit(self.gpa),
            .create_texture, .write_chain => self.chain.deinit(self.gpa),
        }
    }
};

pub const Uploads = struct {
    /// The allocator a request's bytes were made with, and are freed with on the pool: it must
    /// be thread-safe whenever `tasks` has threads, as the asset registry's is.
    gpa: Allocator,
    renderer: *Renderer,
    tasks: core.Tasks,
    limits: Limits,
    requests: core.HandlePool(Upload, *Request) = .empty,
    /// Unfinished requests, oldest first: the order they finish in.
    order: std.ArrayList(*Request) = .empty,
    /// Finished requests whose bytes are being freed on the pool.
    freeing: std.ArrayList(*Request) = .empty,
    pending_bytes: u64 = 0,

    const Self = @This();

    /// Torn down before `renderer`, whose staging pending requests hold reserved.
    pub fn init(gpa: Allocator, renderer: *Renderer, tasks: core.Tasks, limits: Limits) Self {
        return .{ .gpa = gpa, .renderer = renderer, .tasks = tasks, .limits = limits };
    }

    /// Drops whatever is pending, as `quiesce` does, and frees every entry.
    pub fn deinit(self: *Self) void {
        self.quiesce();
        self.reap();
        std.debug.assert(self.freeing.items.len == 0);
        var it = self.requests.iterator();
        while (it.next()) |entry| self.destroyRequest(entry.value.*);
        self.requests.deinit(self.gpa);
        self.order.deinit(self.gpa);
        self.freeing.deinit(self.gpa);
        self.* = undefined;
    }

    /// A new mesh from `mesh`, which must have been made with this `Uploads`' allocator, as
    /// `asset.mesh.Builder` makes one. On success the bytes are this `Uploads`' to free; a
    /// refusal leaves them the caller's. It is validated on the pool, and fails at its finish
    /// if it does not validate.
    pub fn createMesh(self: *Self, mesh: asset.OwnedMesh, label: []const u8) Error!UploadHandle {
        return self.request(.{ .kind = .create_mesh, .gpa = self.gpa, .mesh = mesh, .label = undefined, .staged = null, .bytes = renderer_mod.meshStagingSize(mesh.mesh) }, label);
    }

    /// `Renderer.updateMesh` of `target`, at the request's turn. The target may still go before
    /// then; the request then fails rather than finishing.
    pub fn updateMesh(self: *Self, target: MeshHandle, mesh: asset.OwnedMesh, label: []const u8) Error!UploadHandle {
        if (self.renderer.meshJointCount(target) == null) return error.InvalidMesh;
        return self.request(.{ .kind = .update_mesh, .gpa = self.gpa, .mesh = mesh, .target_mesh = target, .label = undefined, .staged = null, .bytes = renderer_mod.meshStagingSize(mesh.mesh) }, label);
    }

    /// A new texture from `chain`: one level, or every level `asset.mips.generate` makes, in
    /// `options.color_space`. Ownership as `createMesh`'s.
    pub fn createTexture(self: *Self, chain: asset.MipChain, options: renderer_mod.TextureOptions) Error!UploadHandle {
        try self.renderer.checkNewTextureChain(chain);
        return self.request(.{ .kind = .create_texture, .gpa = self.gpa, .chain = chain, .options = options, .label = undefined, .staged = null, .bytes = chain.bytes.len }, options.label);
    }

    /// `Renderer.writeTextureChain` of `target`, at the request's turn. Ownership as
    /// `createMesh`'s.
    pub fn writeTextureChain(self: *Self, target: TextureHandle, chain: asset.MipChain, color_space: asset.ColorSpace) Error!UploadHandle {
        _ = try self.renderer.checkTextureChain(target, chain, color_space);
        return self.request(.{ .kind = .write_chain, .gpa = self.gpa, .chain = chain, .color_space = color_space, .target_texture = target, .label = undefined, .staged = null, .bytes = chain.bytes.len }, "render3d texture write");
    }

    fn request(self: *Self, value: Request, label: []const u8) Error!UploadHandle {
        if (self.requests.count() >= self.limits.max_requests) return error.TooManyUploads;
        if (value.bytes > self.limits.max_pending_bytes -| self.pending_bytes) return error.TooManyUploadBytes;
        try self.order.ensureUnusedCapacity(self.gpa, 1);

        const r = try self.gpa.create(Request);
        errdefer self.gpa.destroy(r);
        r.* = value;
        r.label = try self.gpa.dupe(u8, label);
        errdefer self.gpa.free(r.label);
        r.options.label = r.label;
        r.handle = try self.requests.add(self.gpa, r);
        errdefer _ = self.requests.remove(r.handle);
        r.staged = try self.renderer.reserveStaging(r.label, r.bytes);
        errdefer self.renderer.returnStaging(r.staged.?, false);
        try self.tasks.start(.{ .context = r, .call = Request.fill }, &r.filled);

        self.order.appendAssumeCapacity(r);
        self.pending_bytes += r.bytes;
        return r.handle;
    }

    /// Once a frame, where the game renders and before simulation (ADR-0061, decision 4):
    /// finishes filled requests, oldest first, while `budget` lasts. As every pump, it always
    /// finishes the first ready one under a budget nothing has spent. **Finishes nothing
    /// inside a frame's submission window**, where the writes are refused (§4.2), so a request
    /// keeps its place rather than failing.
    pub fn pump(self: *Self, budget: *core.tasks.Budget) PumpStats {
        var stats: PumpStats = .{};
        const spent = budget.spent_bytes;
        self.reap();
        while (!self.renderer.recording and self.order.items.len != 0) {
            const r = self.order.items[0];
            if (!r.filled.isSet()) break;
            if (r.released) {
                // Released while pending: nothing finishes, and nothing is charged.
                _ = self.order.orderedRemove(0);
                self.drop(r);
                continue;
            }
            if (budget.ran != 0 and budget.exhausted()) break;
            _ = self.order.orderedRemove(0);
            self.pending_bytes -= r.bytes;
            budget.charge(r.bytes);
            budget.ran += 1;
            if (self.finish(r)) stats.finished += 1 else stats.failed += 1;
            self.startFree(r);
        }
        self.reap();
        stats.pending = @intCast(self.order.items.len);
        stats.bytes = budget.spent_bytes - spent;
        return stats;
    }

    fn finish(self: *Self, r: *Request) bool {
        const staged = r.staged.?;
        // Each call consumes the reservation whatever it returns.
        r.staged = null;
        // The boxes are copied by the renderer; this `Uploads`' copy goes with the finish.
        defer {
            self.gpa.free(r.prepared);
            r.prepared = &.{};
        }
        const prepared: renderer_mod.PreparedMesh = .{ .submesh_bounds = r.prepared };
        const outcome: renderer_mod.Error!Result = if (r.fill_error) |err| refused: {
            self.renderer.returnStaging(staged, false);
            break :refused err;
        } else switch (r.kind) {
            .create_mesh => if (self.renderer.createMeshFromStaged(r.mesh.mesh, r.label, staged, prepared)) |mesh| .{ .mesh = mesh } else |err| err,
            .update_mesh => if (self.renderer.updateMeshFromStaged(r.target_mesh, r.mesh.mesh, r.label, staged, prepared)) |_| .{ .mesh = r.target_mesh } else |err| err,
            .create_texture => if (self.renderer.createTextureFromStaged(r.chain.levels[0].width, r.chain.levels[0].height, r.chain, staged, r.options)) |texture| .{ .texture = texture } else |err| err,
            .write_chain => if (self.renderer.writeTextureChainFromStaged(r.target_texture, r.chain, r.color_space, staged)) |_| .{ .texture = r.target_texture } else |err| err,
        };
        if (outcome) |made| {
            r.state = .done;
            r.result = made;
            return true;
        } else |err| {
            r.state = .failed;
            r.failure = err;
            log.warn("upload '{s}' failed at its finish: {t}", .{ r.label, err });
            return false;
        }
    }

    /// Frees a finished request's bytes on the pool; on the main thread when the pool is full,
    /// or there is no room to remember it.
    fn startFree(self: *Self, r: *Request) void {
        self.freeing.append(self.gpa, r) catch {
            Request.freeBytes(r);
            r.holds_bytes = false;
            return;
        };
        self.tasks.start(.{ .context = r, .call = Request.freeBytes }, &r.freed) catch {
            Request.freeBytes(r);
            r.freed.set();
        };
    }

    /// Collects frees that have run, and the entries released meanwhile.
    fn reap(self: *Self) void {
        var i: usize = 0;
        while (i < self.freeing.items.len) {
            const r = self.freeing.items[i];
            if (!r.freed.isSet()) {
                i += 1;
                continue;
            }
            r.holds_bytes = false;
            _ = self.freeing.swapRemove(i);
            if (r.released) self.removeRequest(r);
        }
    }

    /// A pending request that will never finish: its fill has run, so its staging and bytes
    /// go back now, unused.
    fn drop(self: *Self, r: *Request) void {
        std.debug.assert(r.filled.isSet());
        self.pending_bytes -= r.bytes;
        if (r.staged) |staged| self.renderer.returnStaging(staged, false);
        r.staged = null;
        self.gpa.free(r.prepared);
        r.prepared = &.{};
        Request.freeBytes(r);
        r.holds_bytes = false;
        r.state = .cancelled;
        if (r.released) self.removeRequest(r);
    }

    pub fn state(self: *const Self, handle: UploadHandle) ?State {
        const r = self.requests.getConst(handle) orelse return null;
        return r.*.state;
    }

    /// The mesh or texture a `done` request made or wrote; null otherwise. It is the caller's
    /// from then on, as `createMesh`'s result is.
    pub fn result(self: *const Self, handle: UploadHandle) ?Result {
        const r = self.requests.getConst(handle) orelse return null;
        return r.*.result;
    }

    /// Why a `failed` request failed.
    pub fn failure(self: *const Self, handle: UploadHandle) ?renderer_mod.Error {
        const r = self.requests.getConst(handle) orelse return null;
        return r.*.failure;
    }

    /// The caller is done with `handle`, which answers nothing from now on. A pending request
    /// is cancelled and never finishes; what a finished one made stays the caller's.
    pub fn release(self: *Self, handle: UploadHandle) void {
        const r = (self.requests.get(handle) orelse return).*;
        if (r.released) return;
        r.released = true;
        _ = self.requests.remove(handle);
        r.handle = .none;
        if (r.state == .pending) {
            r.state = .cancelled;
            return; // Its turn in `pump` drops it, once its fill has run.
        }
        if (!r.holds_bytes) self.destroyRequest(r);
    }

    /// Returns once nothing runs on the pool for this `Uploads`, with every pending request
    /// dropped as `cancelled`: for teardown, and before whatever its requests name goes.
    /// Never on a frame's path.
    pub fn quiesce(self: *Self) void {
        self.tasks.wait();
        while (self.order.items.len != 0) self.drop(self.order.orderedRemove(0));
        self.reap();
    }

    fn removeRequest(self: *Self, r: *Request) void {
        if (!r.handle.isNone()) _ = self.requests.remove(r.handle);
        self.destroyRequest(r);
    }

    fn destroyRequest(self: *Self, r: *Request) void {
        std.debug.assert(!r.holds_bytes or r.state == .pending);
        if (r.holds_bytes) Request.freeBytes(r);
        self.gpa.free(r.label);
        self.gpa.destroy(r);
    }
};

// -- tests -------------------------------------------------------------------------------

const testing = std.testing;
const rhi = @import("rhi");
const Vec3 = core.math.Vec3;

const Fixture = struct {
    device: *rhi.Device,
    renderer: Renderer,

    fn init(fx: *Fixture) !void {
        fx.device = try rhi.Device.init(testing.allocator, .{ .surface_size = .{ .width = 32, .height = 32 }, .frames_in_flight = 2 });
        errdefer fx.device.deinit();
        fx.renderer = try Renderer.init(testing.allocator, fx.device, .{ .frames_in_flight = 2 });
    }

    fn deinit(fx: *Fixture) void {
        fx.renderer.deinit();
        fx.device.deinit();
    }

    /// A frame with nothing drawn, so the next one's counts start clean.
    fn frame(fx: *Fixture) !void {
        try fx.renderer.begin(.{ .camera = .{}, .target_size = .{ .width = 32, .height = 32 } });
        const ctx = try fx.device.beginFrame();
        var cmd = try fx.device.beginCommandBuffer();
        try fx.renderer.prepare(cmd, ctx);
        try fx.renderer.recordFrame(cmd, ctx, false);
        try cmd.submit();
        try fx.device.endFrame();
    }
};

/// A fan of `sides` triangles at depth `z`: distinct sizes, so each request is told apart.
fn fan(sides: u16, z: f32) !asset.OwnedMesh {
    var builder: asset.MeshBuilder = .init(testing.allocator, .{});
    defer builder.deinit();
    var positions: [17]Vec3 = undefined;
    var indices: [48]u16 = undefined;
    positions[0] = .init(0, 0, z);
    for (0..sides) |i| {
        const angle = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sides)) * std.math.tau;
        positions[i + 1] = .init(@cos(angle), @sin(angle), z);
        indices[i * 3 ..][0..3].* = .{ 0, @intCast(i + 1), @intCast((i + 1) % sides + 1) };
    }
    try builder.positions(positions[0 .. sides + 1]);
    try builder.indices16(indices[0 .. sides * 3]);
    return builder.finish();
}

/// What a `Manual` holds, in its own order, so a test can run a named task wherever it sits.
const Held = union(enum) { fill: usize, free: usize };

fn runHeld(manual: *core.tasks.Manual, held: *std.ArrayList(Held), task: Held) void {
    for (held.items, 0..) |item, i| if (std.meta.eql(item, task)) {
        manual.runAt(@intCast(i));
        _ = held.orderedRemove(i);
        return;
    };
    unreachable;
}

test "the same requests finish in the same order under every interleaving of their fills" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const count = 4;
    // Every permutation of four fills: 24 interleavings, each with a pump between fills.
    var permutation: [count]usize = .{ 0, 1, 2, 3 };
    var runs: usize = 0;
    while (true) : (runs += 1) {
        var manual = try core.tasks.Manual.init(testing.allocator, 2 * count);
        defer manual.deinit();
        var uploads = Uploads.init(testing.allocator, &fx.renderer, manual.tasks(), .{});
        defer uploads.deinit();
        var held: std.ArrayList(Held) = .empty;
        defer held.deinit(testing.allocator);

        var handles: [count]UploadHandle = undefined;
        for (&handles, 0..) |*handle, i| {
            handle.* = try uploads.createMesh(try fan(@intCast(3 + i), -2), "fan");
            try held.append(testing.allocator, .{ .fill = i });
        }
        var finished: std.ArrayList(usize) = .empty;
        defer finished.deinit(testing.allocator);
        for (permutation) |next| {
            runHeld(&manual, &held, .{ .fill = next });
            var budget: core.tasks.Budget = .unlimited;
            _ = uploads.pump(&budget);
            for (handles, 0..) |handle, i| {
                if (uploads.state(handle) != .done or std.mem.indexOfScalar(usize, finished.items, i) != null) continue;
                try finished.append(testing.allocator, i);
                try held.append(testing.allocator, .{ .free = i });
            }
        }
        // Whatever the order the fills ran in, the finishes ran in the requests'.
        try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, finished.items);
        for (handles, 0..) |handle, i| {
            const mesh = uploads.result(handle).?.mesh;
            // Each request made its own mesh, with its own fan.
            try testing.expectEqual(@as(u32, @intCast(3 * (3 + i))), fx.renderer.meshes.getConst(mesh).?.submeshes[0].index_count);
            fx.renderer.destroyMesh(mesh);
            uploads.release(handle);
        }
        manual.runAll();
        if (!nextPermutation(&permutation)) break;
    }
    try testing.expectEqual(@as(usize, 23), runs);
    if (rhi.backend == .null) try testing.expectEqual(@as(usize, 0), fx.device.violationCount());
}

fn nextPermutation(values: []usize) bool {
    var i = values.len - 1;
    while (i > 0 and values[i - 1] >= values[i]) i -= 1;
    if (i == 0) return false;
    var j = values.len - 1;
    while (values[j] <= values[i - 1]) j -= 1;
    std.mem.swap(usize, &values[i - 1], &values[j]);
    std.mem.reverse(usize, values[i..]);
    return true;
}

test "a pump finishes within its budget, always one, and nothing inside the window" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var uploads = Uploads.init(testing.allocator, &fx.renderer, core.tasks.immediate, .{});
    defer uploads.deinit();
    var handles: [3]UploadHandle = undefined;
    for (&handles) |*handle| handle.* = try uploads.createMesh(try fan(4, -2), "fan");

    // A budget spent before the pump starts still finishes the first, so a large finish
    // never waits forever.
    var tight: core.tasks.Budget = .{ .bytes = 0 };
    var stats = uploads.pump(&tight);
    try testing.expectEqual(@as(u32, 1), stats.finished);
    try testing.expectEqual(@as(u32, 2), stats.pending);
    var sample = try fan(4, -2);
    defer sample.deinit(testing.allocator);
    try testing.expectEqual(renderer_mod.meshStagingSize(sample.mesh), stats.bytes);
    try testing.expectEqual(State.done, uploads.state(handles[0]).?);
    try testing.expectEqual(State.pending, uploads.state(handles[1]).?);

    // Inside the window nothing finishes, and nothing loses its place.
    try fx.renderer.begin(.{ .camera = .{}, .target_size = .{ .width = 32, .height = 32 } });
    var open: core.tasks.Budget = .unlimited;
    stats = uploads.pump(&open);
    try testing.expectEqual(@as(u32, 0), stats.finished);
    try testing.expectEqual(@as(u32, 2), stats.pending);
    const ctx = try fx.device.beginFrame();
    var cmd = try fx.device.beginCommandBuffer();
    try fx.renderer.prepare(cmd, ctx);
    try fx.renderer.recordFrame(cmd, ctx, false);
    try cmd.submit();
    try fx.device.endFrame();

    // One node's worth, then the rest.
    var one: core.tasks.Budget = .{ .nodes = 1 };
    try testing.expectEqual(@as(u32, 1), uploads.pump(&one).finished);
    try testing.expectEqual(State.pending, uploads.state(handles[2]).?);
    var rest: core.tasks.Budget = .unlimited;
    try testing.expectEqual(@as(u32, 1), uploads.pump(&rest).finished);
    for (handles) |handle| {
        fx.renderer.destroyMesh(uploads.result(handle).?.mesh);
        uploads.release(handle);
    }
}

// Leaked when `cleanup` is wrong: the testing allocator reports it, and the renderer asserts
// every staging reservation was given back.
fn teardownWhilePending(stage: enum { unfilled, filled, unfreed }) !void {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var manual = try core.tasks.Manual.init(testing.allocator, 8);
    defer manual.deinit();
    var uploads = Uploads.init(testing.allocator, &fx.renderer, manual.tasks(), .{});
    const first = try uploads.createMesh(try fan(3, -2), "first");
    _ = try uploads.createMesh(try fan(5, -2), "second");
    var pixels = [_]u8{255} ** 16;
    _ = try uploads.createTexture(try asset.mips.generate(testing.allocator, .{ .width = 2, .height = 2, .pixels = &pixels }, .srgb), .{ .mipmaps = true });
    switch (stage) {
        .unfilled => {},
        .filled => manual.runAll(),
        .unfreed => {
            manual.runNext();
            var budget: core.tasks.Budget = .{ .nodes = 1 };
            try testing.expectEqual(@as(u32, 1), uploads.pump(&budget).finished);
            fx.renderer.destroyMesh(uploads.result(first).?.mesh);
        },
    }
    uploads.deinit();
    try testing.expectEqual(@as(u32, 0), manual.pending());
    for (fx.renderer.staging.items) |entry| try testing.expect(!entry.reserved);
}

test "teardown while pending leaks nothing, whatever has run" {
    try teardownWhilePending(.unfilled);
    try teardownWhilePending(.filled);
    try teardownWhilePending(.unfreed);
}

test "bytes are freed on the pool after the finish, not before" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var manual = try core.tasks.Manual.init(testing.allocator, 4);
    defer manual.deinit();
    var uploads = Uploads.init(testing.allocator, &fx.renderer, manual.tasks(), .{});
    defer uploads.deinit();
    const handle = try uploads.createMesh(try fan(3, -2), "fan");
    manual.runNext();
    var budget: core.tasks.Budget = .unlimited;
    try testing.expectEqual(@as(u32, 1), uploads.pump(&budget).finished);
    // Finished, and its free is the pool's: still held until that task runs.
    const request = uploads.requests.getConst(handle).?.*;
    try testing.expect(request.holds_bytes);
    try testing.expectEqual(@as(u32, 1), manual.pending());
    manual.runNext();
    _ = uploads.pump(&budget);
    try testing.expect(!request.holds_bytes);
    fx.renderer.destroyMesh(uploads.result(handle).?.mesh);
    uploads.release(handle);
}

test "a released request never finishes, and those after it still do" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var manual = try core.tasks.Manual.init(testing.allocator, 8);
    defer manual.deinit();
    var uploads = Uploads.init(testing.allocator, &fx.renderer, manual.tasks(), .{});
    defer uploads.deinit();
    const meshes = fx.renderer.meshes.count();
    const dropped = try uploads.createMesh(try fan(3, -2), "dropped");
    const kept = try uploads.createMesh(try fan(4, -2), "kept");
    uploads.release(dropped);
    try testing.expect(uploads.state(dropped) == null);
    manual.runAll();
    var budget: core.tasks.Budget = .{ .nodes = 1 };
    // The released one is dropped without charging the budget, so the next one finishes.
    try testing.expectEqual(@as(u32, 1), uploads.pump(&budget).finished);
    try testing.expectEqual(meshes + 1, fx.renderer.meshes.count());
    manual.runAll();
    const mesh = uploads.result(kept).?.mesh;
    uploads.release(kept);
    // Released after its finish: what it made stays the caller's.
    try testing.expect(fx.renderer.meshJointCount(mesh) != null);
    fx.renderer.destroyMesh(mesh);
    for (fx.renderer.staging.items) |entry| try testing.expect(!entry.reserved);
}

test "requests are refused before anything is reserved, and a gone target fails its finish" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var manual = try core.tasks.Manual.init(testing.allocator, 1);
    defer manual.deinit();
    var uploads = Uploads.init(testing.allocator, &fx.renderer, manual.tasks(), .{ .max_requests = 2, .max_pending_bytes = 4096 });
    defer uploads.deinit();

    // Each refusal leaves the bytes the caller's.
    var invalid = try fan(3, -2);
    defer invalid.deinit(testing.allocator);
    try testing.expectError(error.InvalidMesh, uploads.updateMesh(.none, invalid, "no target"));
    var pixels = [_]u8{255} ** 16;
    var chain = try asset.mips.generate(testing.allocator, .{ .width = 2, .height = 2, .pixels = &pixels }, .srgb);
    defer chain.deinit(testing.allocator);
    // A chain that lies about a level's size: never reserved for.
    var levels: [2]asset.mips.Level = chain.levels[0..2].*;
    levels[1].width = 2;
    var lying = chain;
    lying.levels = &levels;
    try testing.expectError(error.InvalidMipChain, uploads.createTexture(lying, .{}));
    try testing.expectError(error.InvalidTexture, uploads.writeTextureChain(fx.renderer.white_texture, chain, .srgb));

    var big = [_]u8{255} ** (64 * 64 * 4);
    var large = try asset.mips.generate(testing.allocator, .{ .width = 64, .height = 64, .pixels = &big }, .srgb);
    defer large.deinit(testing.allocator);
    try testing.expectError(error.TooManyUploadBytes, uploads.createTexture(large, .{ .mipmaps = true }));

    // A target destroyed between the request and its turn fails, and says why.
    var target_bytes = try fan(3, -2);
    defer target_bytes.deinit(testing.allocator);
    const target = try fx.renderer.createMesh(target_bytes.mesh, "target");
    var replacement = try fan(3, -2);
    const update = uploads.updateMesh(target, replacement, "update") catch |err| {
        replacement.deinit(testing.allocator);
        return err;
    };
    // The executor is full now: the next request is refused, and gives back what it reserved.
    try testing.expectError(error.Full, uploads.createMesh(invalid, "full"));
    var reserved: usize = 0;
    for (fx.renderer.staging.items) |entry| reserved += @intFromBool(entry.reserved);
    try testing.expectEqual(@as(usize, 1), reserved);
    fx.renderer.destroyMesh(target);
    manual.runAll();
    var budget: core.tasks.Budget = .unlimited;
    const stats = uploads.pump(&budget);
    try testing.expectEqual(@as(u32, 1), stats.failed);
    try testing.expectEqual(State.failed, uploads.state(update).?);
    try testing.expectEqual(@as(?renderer_mod.Error, error.InvalidMesh), uploads.failure(update));
    manual.runAll();

    // Two held, finished or not, is the limit until one is released.
    const a = try uploads.createMesh(try fan(3, -2), "a");
    manual.runAll();
    try testing.expectError(error.TooManyUploads, uploads.createMesh(invalid, "over"));
    uploads.release(update);
    _ = uploads.pump(&budget);
    manual.runAll();
    fx.renderer.destroyMesh(uploads.result(a).?.mesh);
    uploads.release(a);
}

test "a mesh that does not validate fails at its finish, measured on the pool, and gives everything back" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var manual = try core.tasks.Manual.init(testing.allocator, 4);
    defer manual.deinit();
    var uploads = Uploads.init(testing.allocator, &fx.renderer, manual.tasks(), .{});
    defer uploads.deinit();
    const meshes = fx.renderer.meshes.count();
    var broken = try fan(3, -2);
    // Its streams no longer match its count: only a linear check over it can tell.
    broken.mesh.vertex_count = 99;
    const handle = try uploads.createMesh(broken, "broken");
    manual.runNext();
    var budget: core.tasks.Budget = .unlimited;
    try testing.expectEqual(@as(u32, 1), uploads.pump(&budget).failed);
    try testing.expectEqual(State.failed, uploads.state(handle).?);
    try testing.expectEqual(@as(?renderer_mod.Error, error.InvalidStreamLength), uploads.failure(handle));
    try testing.expectEqual(meshes, fx.renderer.meshes.count());
    manual.runAll();
    uploads.release(handle);
    for (fx.renderer.staging.items) |entry| try testing.expect(!entry.reserved);
}

test "an update and a chain write through Uploads keep their targets' handles" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var uploads = Uploads.init(testing.allocator, &fx.renderer, core.tasks.immediate, .{});
    defer uploads.deinit();
    var original = try fan(3, -2);
    defer original.deinit(testing.allocator);
    const mesh = try fx.renderer.createMesh(original.mesh, "water");
    var pixels = [_]u8{255} ** 64;
    const texture = try fx.renderer.createTexture(.{ .width = 4, .height = 4, .pixels = &pixels }, .{ .mipmaps = true });
    try fx.frame();

    const update = try uploads.updateMesh(mesh, try fan(8, -2), "water");
    var red: [64]u8 = undefined;
    for (0..16) |i| red[i * 4 ..][0..4].* = .{ 255, 0, 0, 255 };
    const write = try uploads.writeTextureChain(texture, try asset.mips.generate(testing.allocator, .{ .width = 4, .height = 4, .pixels = &red }, .srgb), .srgb);
    var budget: core.tasks.Budget = .unlimited;
    try testing.expectEqual(@as(u32, 2), uploads.pump(&budget).finished);
    try testing.expect(uploads.result(update).?.mesh.eql(mesh));
    try testing.expect(uploads.result(write).?.texture.eql(texture));
    try testing.expectEqual(@as(u32, 24), fx.renderer.meshes.getConst(mesh).?.submeshes[0].index_count);
    try fx.frame();
    try testing.expectEqual(@as(u32, 1), fx.renderer.frameStats().mesh_updates);
    try testing.expectEqual(@as(u32, 1), fx.renderer.frameStats().texture_writes);
    uploads.release(update);
    uploads.release(write);
    fx.renderer.destroyMesh(mesh);
    fx.renderer.destroyTexture(texture);
    if (rhi.backend == .null) try testing.expectEqual(@as(usize, 0), fx.device.violationCount());
}

/// One frame of `mesh` in white on black, read back.
fn readMesh(fx: *Fixture, mesh: MeshHandle, material: renderer_mod.MaterialHandle) ![32 * 32 * 4]u8 {
    const readback = try fx.device.createBuffer(.{ .label = "uploads readback", .size = 32 * 32 * 4, .usage = .{ .copy_dst = true }, .memory = .readback });
    defer fx.device.destroyBuffer(readback);
    try fx.renderer.begin(.{ .camera = .{ .vertical_fov = std.math.pi / 2.0, .near = 0.1, .far = 10 }, .target_size = .{ .width = 32, .height = 32 } });
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = material, .world = .identity });
    const ctx = try fx.device.beginFrame();
    var cmd = try fx.device.beginCommandBuffer();
    try fx.renderer.prepare(cmd, ctx);
    try fx.renderer.recordFrame(cmd, ctx, false);
    try cmd.textureBarrier(&.{.{ .texture = ctx.surface_texture, .from = .present, .to = .copy_src }});
    try cmd.copyTextureToBuffer(.{ .src = ctx.surface_texture, .size = .{ .width = 32, .height = 32 }, .dst = readback });
    try cmd.textureBarrier(&.{.{ .texture = ctx.surface_texture, .from = .copy_src, .to = .present }});
    try cmd.submit();
    try fx.device.endFrame();
    fx.device.waitIdle();
    var pixels: [32 * 32 * 4]u8 = undefined;
    const mapped = try fx.device.mapBuffer(readback);
    @memcpy(&pixels, mapped[0..pixels.len]);
    fx.device.unmapBuffer(readback);
    return pixels;
}

test "a mesh made by Uploads draws exactly as createMesh's" {
    // Pixels are Metal's evidence here, and Vulkan's on the Windows target (Step 7).
    if (rhi.backend == .null) return;
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var uploads = Uploads.init(testing.allocator, &fx.renderer, core.tasks.immediate, .{});
    defer uploads.deinit();
    const material = try fx.renderer.createMaterial(.{ .double_sided = true }, "white");
    defer fx.renderer.destroyMaterial(material);
    var direct_bytes = try fan(7, -2);
    defer direct_bytes.deinit(testing.allocator);
    const direct = try fx.renderer.createMesh(direct_bytes.mesh, "direct");
    defer fx.renderer.destroyMesh(direct);
    const handle = try uploads.createMesh(try fan(7, -2), "uploaded");
    var budget: core.tasks.Budget = .unlimited;
    try testing.expectEqual(@as(u32, 1), uploads.pump(&budget).finished);
    const uploaded = uploads.result(handle).?.mesh;
    defer fx.renderer.destroyMesh(uploaded);
    uploads.release(handle);

    const expected = try readMesh(&fx, direct, material);
    const actual = try readMesh(&fx, uploaded, material);
    try testing.expectEqualSlices(u8, &expected, &actual);
    // And the fan was drawn at all: the centre is lit, a corner is not.
    try testing.expect(!std.mem.eql(u8, expected[(16 * 32 + 16) * 4 ..][0..4], expected[0..4]));
}
