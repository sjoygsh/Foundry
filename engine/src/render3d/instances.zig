//! Retained instances and lights (`docs/design/public3d.md` §4, ADR-0059).
//!
//! `render3d` draws immediately: whoever records a frame submits it. Code that never runs
//! inside a frame — a mod's systems and loader callbacks — needs somewhere to leave what it
//! wants drawn. This is that place: a bounded set of models by content ID, each with a world
//! matrix, slot overrides and a visibility flag, and of lights, which the host submits once
//! in its own frame.
//!
//! **Every value is checked once, at the call that sets it.** `submit` only replays what was
//! accepted. What content can still change underneath — a model reloaded into one this path
//! cannot draw — is counted in `Stats.instances_refused` and the frame goes on, as a light
//! the frame has no room for is counted in `Stats.instance_lights_dropped`.
//!
//! **Each entry carries an `owner` this file never reads.** The public boundary tags what a
//! mod creates and refuses another caller's changes (ADR-0059); here it is only stored, as
//! `physics3d` stores a body's `user`.
//!
//! **Order is ascending slot index** (`core.HandlePool`'s documented iteration), lights then
//! instances. A slot freed and reused returns to its old place, deterministically.

const std = @import("std");
const core = @import("core");

const content_mod = @import("content.zig");
const lighting = @import("lighting.zig");
const renderer_mod = @import("renderer.zig");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Mat4 = core.math.Mat4;
const Content = content_mod.Content;
const Light = lighting.Light;
const MaterialHandle = renderer_mod.MaterialHandle;
const ModelHandle = content_mod.ModelHandle;
const Renderer = renderer_mod.Renderer;
const SlotOverride = content_mod.SlotOverride;
const log = core.log.scoped(.render3d);

pub const Instance = opaque {};
pub const InstanceHandle = core.Handle(Instance);
pub const InstanceLight = opaque {};
pub const LightHandle = core.Handle(InstanceLight);

/// Overrides one instance may hold, one per slot.
pub const max_overrides = 8;

pub const Limits = struct {
    max_instances: u32 = 1024,
    /// At most `lighting.max_lights`, the frame's whole capacity; the default leaves the
    /// host half of it.
    max_lights: u32 = 8,

    pub const default: Limits = .{};
};

pub const Error = error{
    InvalidConfig,
    /// A stale or never-issued handle.
    InvalidHandle,
    InvalidLight,
    InvalidTransform,
    InvalidOverride,
    /// A retained light never casts the frame's one shadow; that is the host's.
    InvalidShadowCaster,
    TooManyInstances,
    TooManyLights,
    TooManyOverrides,
    /// A model with a skeleton: drawing it needs a palette this path does not carry.
    Unsupported,
} || content_mod.Error;

const Override = struct {
    slot: u32,
    id: ContentId,
    /// `Content`'s, held for as long as the override is.
    material: MaterialHandle,
};

const InstanceEntry = struct {
    owner: u64,
    model: ModelHandle,
    world: Mat4,
    visible: bool = true,
    overrides: [max_overrides]Override = undefined,
    override_count: u8 = 0,

    fn overrideSlice(self: *const InstanceEntry) []const Override {
        return self.overrides[0..self.override_count];
    }
};

const LightEntry = struct { owner: u64, light: Light };

pub const Instances = struct {
    gpa: Allocator,
    limits: Limits,
    instances: core.HandlePool(Instance, InstanceEntry) = .empty,
    lights: core.HandlePool(InstanceLight, LightEntry) = .empty,

    const Self = @This();

    pub fn init(gpa: Allocator, limits: Limits) error{InvalidConfig}!Self {
        if (limits.max_lights > lighting.max_lights) return error.InvalidConfig;
        return .{ .gpa = gpa, .limits = limits };
    }

    /// Releases every acquisition through the `Content` that made them.
    pub fn deinit(self: *Self, content: *Content) void {
        var it = self.instances.iterator();
        while (it.next()) |entry| releaseEntry(content, entry.value);
        self.instances.deinit(self.gpa);
        self.lights.deinit(self.gpa);
        self.* = undefined;
    }

    // -- instances ---------------------------------------------------------------------

    /// Removes one owner's retained objects after a refused native initialization.
    /// The tag remains opaque to render3d.
    pub fn releaseOwner(self: *Self, content: ?*Content, owner: u64) void {
        if (content) |lent| {
            var entries = self.instances.iterator();
            while (entries.next()) |entry| {
                if (entry.value.owner == owner) self.destroy(lent, entry.id) catch unreachable;
            }
        }
        var lights = self.lights.iterator();
        while (lights.next()) |entry| {
            if (entry.value.owner == owner) self.destroyLight(entry.id) catch unreachable;
        }
    }

    /// Acquires `model` and draws it at `world` until destroyed. The bound is checked
    /// before anything is acquired, and a refusal holds nothing.
    pub fn create(self: *Self, content: *Content, owner: u64, model: ContentId, world: Mat4) Error!InstanceHandle {
        if (self.instances.count() >= self.limits.max_instances) return error.TooManyInstances;
        if (!affine(world)) return error.InvalidTransform;
        const handle = try content.acquireModel(model);
        errdefer content.releaseModel(handle);
        if (content.isSkinned(handle)) return error.Unsupported;
        return self.instances.add(self.gpa, .{ .owner = owner, .model = handle, .world = world });
    }

    pub fn destroy(self: *Self, content: *Content, instance: InstanceHandle) error{InvalidHandle}!void {
        const entry = self.instances.getConst(instance) orelse return error.InvalidHandle;
        releaseEntry(content, entry);
        _ = self.instances.remove(instance);
    }

    pub fn setWorld(self: *Self, instance: InstanceHandle, world: Mat4) error{ InvalidHandle, InvalidTransform }!void {
        const entry = self.instances.get(instance) orelse return error.InvalidHandle;
        if (!affine(world)) return error.InvalidTransform;
        entry.world = world;
    }

    /// Replaces one slot's material on this instance, or clears the override with `null`.
    /// The new material is acquired before the old is released, so a refusal changes nothing.
    pub fn setMaterial(self: *Self, content: *Content, instance: InstanceHandle, slot: u32, material: ?ContentId) Error!void {
        const model = (self.instances.getConst(instance) orelse return error.InvalidHandle).model;
        const slots = content.slotCount(model) orelse return error.InvalidModel;
        if (slot >= slots) return error.InvalidOverride;
        const existing = for (self.instances.getConst(instance).?.overrideSlice(), 0..) |override, i| {
            if (override.slot == slot) break i;
        } else null;
        const id = material orelse {
            const i = existing orelse return;
            const entry = self.instances.get(instance).?;
            content.releaseMaterial(entry.overrides[i].material);
            // Order among overrides does not matter: each names its own slot.
            entry.overrides[i] = entry.overrides[entry.override_count - 1];
            entry.override_count -= 1;
            return;
        };
        if (existing == null and self.instances.getConst(instance).?.override_count == max_overrides) return error.TooManyOverrides;
        const handle = try content.acquireMaterial(id);
        const entry = self.instances.get(instance).?;
        if (existing) |i| {
            content.releaseMaterial(entry.overrides[i].material);
            entry.overrides[i] = .{ .slot = slot, .id = id, .material = handle };
        } else {
            entry.overrides[entry.override_count] = .{ .slot = slot, .id = id, .material = handle };
            entry.override_count += 1;
        }
    }

    pub fn setVisible(self: *Self, instance: InstanceHandle, visible: bool) error{InvalidHandle}!void {
        const entry = self.instances.get(instance) orelse return error.InvalidHandle;
        entry.visible = visible;
    }

    /// The tag `create` was given, or null for a stale handle.
    pub fn instanceOwner(self: *const Self, instance: InstanceHandle) ?u64 {
        return (self.instances.getConst(instance) orelse return null).owner;
    }

    // -- lights ------------------------------------------------------------------------

    pub fn createLight(self: *Self, owner_tag: u64, light: Light) Error!LightHandle {
        if (self.lights.count() >= self.limits.max_lights) return error.TooManyLights;
        try checkLight(light);
        return self.lights.add(self.gpa, .{ .owner = owner_tag, .light = light });
    }

    pub fn setLight(self: *Self, handle: LightHandle, light: Light) error{ InvalidHandle, InvalidLight, InvalidShadowCaster }!void {
        const entry = self.lights.get(handle) orelse return error.InvalidHandle;
        try checkLight(light);
        entry.light = light;
    }

    pub fn destroyLight(self: *Self, handle: LightHandle) error{InvalidHandle}!void {
        if (!self.lights.remove(handle)) return error.InvalidHandle;
    }

    pub fn lightOwner(self: *const Self, handle: LightHandle) ?u64 {
        return (self.lights.getConst(handle) orelse return null).owner;
    }

    // -- the frame ---------------------------------------------------------------------

    /// Adds every light, then draws every visible instance, each in ascending slot order.
    /// Call it once while `renderer` is recording, after the host's own lights, so a full
    /// frame drops these and never the host's. Only what a frame itself fails at — not
    /// recording, allocation, the device — is an error.
    pub fn submit(self: *Self, content: *Content, renderer: *Renderer) Error!void {
        var lights = self.lights.iterator();
        while (lights.next()) |entry| renderer.addLight(entry.value.light) catch |err| switch (err) {
            error.TooManyLights => renderer.stats.instance_lights_dropped += 1,
            else => return err,
        };
        var instances = self.instances.iterator();
        while (instances.next()) |entry| {
            const instance = entry.value;
            if (!instance.visible) continue;
            var overrides: [max_overrides]SlotOverride = undefined;
            for (instance.overrideSlice(), overrides[0..instance.override_count]) |override, *out| {
                out.* = .{ .slot = override.slot, .material = override.material };
            }
            content.drawModel(.{
                .model = instance.model,
                .world = instance.world,
                .overrides = overrides[0..instance.override_count],
            }) catch |err| switch (err) {
                // What a reload can make of an accepted instance. `drawModel` records
                // nothing when it refuses, and `Content` reports the content once.
                error.InvalidModel,
                error.InvalidOverride,
                error.InvalidMaterial,
                error.InvalidMesh,
                error.MissingSkin,
                error.SkeletonMismatch,
                error.InvalidSkinCount,
                error.InvalidSkinMatrix,
                => renderer.stats.instances_refused += 1,
                else => return err,
            };
        }
    }
};

fn releaseEntry(content: *Content, entry: *const InstanceEntry) void {
    for (entry.overrideSlice()) |override| content.releaseMaterial(override.material);
    content.releaseModel(entry.model);
}

fn checkLight(light: Light) error{ InvalidLight, InvalidShadowCaster }!void {
    if (!lighting.valid(light) or !affine(light.world)) return error.InvalidLight;
    if (light.casts_shadow) return error.InvalidShadowCaster;
}

/// Finite, with the last row `(0, 0, 0, 1)`: a pose, never a projection.
fn affine(m: Mat4) bool {
    for (m.cols) |column| for (column) |value| {
        if (!std.math.isFinite(value)) return false;
    };
    return m.cols[0][3] == 0 and m.cols[1][3] == 0 and m.cols[2][3] == 0 and m.cols[3][3] == 1;
}

// Lights need no content, so their rules are tested here; instances are tested against
// compiled packages in `engine/tests/instances.zig`.

const testing = std.testing;

fn testLight() Light {
    return .{ .kind = .point, .intensity = 100, .range = 5, .world = Mat4.translation(.init(0, 2, 0)) };
}

test "retained lights refuse what the frame would, and their bound, and keep their owner" {
    var set = try Instances.init(testing.allocator, .{ .max_lights = 2 });
    defer set.lights.deinit(testing.allocator);
    try testing.expectError(error.InvalidConfig, Instances.init(testing.allocator, .{ .max_lights = lighting.max_lights + 1 }));

    var light = testLight();
    light.intensity = std.math.nan(f32);
    try testing.expectError(error.InvalidLight, set.createLight(1, light));
    light = testLight();
    light.world.cols[0][3] = 0.5;
    try testing.expectError(error.InvalidLight, set.createLight(1, light));
    light = testLight();
    light.color[1] = 2;
    try testing.expectError(error.InvalidLight, set.createLight(1, light));
    light = .{ .kind = .directional, .intensity = 1, .casts_shadow = true, .world = .identity };
    try testing.expectError(error.InvalidShadowCaster, set.createLight(1, light));
    try testing.expectEqual(@as(u32, 0), set.lights.count());

    const a = try set.createLight(7, testLight());
    const b = try set.createLight(9, testLight());
    try testing.expectError(error.TooManyLights, set.createLight(7, testLight()));
    try testing.expectEqual(@as(?u64, 7), set.lightOwner(a));
    try testing.expectEqual(@as(?u64, 9), set.lightOwner(b));

    var moved = testLight();
    moved.world = Mat4.translation(.init(1, 2, 3));
    var bad = moved;
    bad.range = -1;
    try testing.expectError(error.InvalidLight, set.setLight(a, bad));
    try testing.expectEqual(@as(f32, 0), set.lights.getConst(a).?.light.world.cols[3][0]);
    try set.setLight(a, moved);
    try testing.expectEqual(@as(f32, 1), set.lights.getConst(a).?.light.world.cols[3][0]);

    try set.destroyLight(a);
    try testing.expectError(error.InvalidHandle, set.destroyLight(a));
    try testing.expectError(error.InvalidHandle, set.setLight(a, moved));
    try testing.expect(set.lightOwner(a) == null);
    // The slot is reused under a new generation: the old handle stays refused.
    const c = try set.createLight(3, testLight());
    try testing.expectEqual(a.index, c.index);
    try testing.expect(set.lightOwner(a) == null);
    try testing.expectEqual(@as(?u64, 3), set.lightOwner(c));
}

test "an affine pose has a finite body and a (0, 0, 0, 1) last row" {
    try testing.expect(affine(.identity));
    try testing.expect(affine(Mat4.translation(.init(1e30, -4, 2))));
    var m = Mat4.identity;
    m.cols[3][3] = 2;
    try testing.expect(!affine(m));
    m = .identity;
    m.cols[2][3] = -1;
    try testing.expect(!affine(m));
    m = .identity;
    m.cols[1][1] = std.math.inf(f32);
    try testing.expect(!affine(m));
}
