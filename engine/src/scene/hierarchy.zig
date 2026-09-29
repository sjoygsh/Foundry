//! The engine's transform hierarchy: `foundry:transform`, `foundry:parent` and
//! `foundry:world_transform` (ADR-0050, `docs/design/hierarchy.md`).
//!
//! **The first engine-declared component types.** M5 declared none, so that no name was
//! chosen before a game said what belonged on it. A 3D hierarchy is the exception ADR-0050
//! makes: propagation, collision sync, animation and render extraction all need one answer to
//! "where is this, relative to what", and a mod could not attach to another's object if each
//! invented its own. Every name below is permanent (CLAUDE.md §7).
//!
//! **A world opts in** with `World.enableHierarchy`, which registers the three types and
//! remembers them, so that rules that must hold for every caller of the world (the despawn
//! cascade, Step 3) can. A 2D world never calls it and never carries them (§3.1).
//!
//! What exists so far is Step 1's: the types, their layouts, and what content may author.
//! Propagation, re-parenting and the cascade follow in Steps 2 and 3.

const std = @import("std");
const core = @import("core");
const data = @import("data");

const component = @import("component.zig");
const derive = @import("derive.zig");
const entity_mod = @import("entity.zig");

const ComponentType = component.ComponentType;
const ComponentTypeInfo = component.ComponentTypeInfo;
const Entity = entity_mod.Entity;
const Mat4 = core.math.Mat4;
const Quat = core.math.Quat;
const Vec3 = core.math.Vec3;

pub const transform_name = "foundry:transform";
pub const parent_name = "foundry:parent";
pub const world_transform_name = "foundry:world_transform";

/// A local pose: `core.Transform`'s layout under its engine name. Saved and authorable.
///
/// A struct of its own only because the component's name is a declaration on the type, and
/// `core` cannot carry `scene`'s names. `fromCore` and `toCore` are bit casts, and the
/// layout check below keeps them honest.
pub const Transform = extern struct {
    pub const component = transform_name;

    /// Metres, in the parent's frame.
    translation: Vec3 = Vec3.zero,
    /// A unit quaternion, `(x, y, z, w)` (ADR-0048).
    rotation: Quat = Quat.identity,
    /// Along the rotated axes. Zero collapses an axis and a negative value reflects it; both
    /// are legal to author (`core.Transform.isValid`).
    scale: Vec3 = Vec3.one,

    pub fn fromCore(t: core.math.Transform) Transform {
        return @bitCast(t);
    }

    pub fn toCore(t: Transform) core.math.Transform {
        return @bitCast(t);
    }

    pub fn isValid(t: Transform) bool {
        return t.toCore().isValid();
    }
};

comptime {
    const C = core.math.Transform;
    std.debug.assert(@sizeOf(Transform) == @sizeOf(C));
    std.debug.assert(@alignOf(Transform) == @alignOf(C));
    for (.{ "translation", "rotation", "scale" }) |field| {
        std.debug.assert(@offsetOf(Transform, field) == @offsetOf(C, field));
    }
}

/// The entity this one's pose is relative to. Saved as the handle's packing, which a save
/// preserves exactly (`entity-storage.md` §9); never authored (§3.3), because a number in a
/// template would name whatever entity happened to hold that slot.
pub const Parent = extern struct {
    pub const component = parent_name;

    entity: Entity = .none,
};

/// The derived world pose, column-major. Written only by propagation (Step 2), never saved,
/// never authored: it has no serializer and no deserializer, so its schema has no fields and
/// a save or an inspector leaves it out. `hierarchy.worldTransform` reads it (§4.3).
pub const WorldTransform = extern struct {
    matrix: Mat4 = Mat4.identity,
};

/// The three types, as one world registered them.
pub const Types = struct {
    transform: ComponentType,
    parent: ComponentType,
    world_transform: ComponentType,
};

/// `foundry:transform`'s registration: derived, with a deserializer that refuses a pose
/// `isValid` refuses. A template and a save both arrive through it, and both are untrusted.
pub fn transformInfo() ComponentTypeInfo {
    var info = derive.componentType(Transform);
    info.deserialize = &deserializeTransform;
    return info;
}

/// The schema content is compiled against. The same value the world registers, so the two
/// can never disagree about a field or a default.
pub const transform_schema: data.Schema = derive.componentType(Transform).schema;

fn deserializeTransform(ctx: ?*anyopaque, fields: data.fpk.Fields, out: [*]u8) component.DeserializeError!void {
    const derived = comptime derive.componentType(Transform).deserialize.?;
    try derived(ctx, fields, out);
    const value: *const Transform = @ptrCast(@alignCast(out));
    if (!value.isValid()) return error.ValueOutOfRange;
}

pub fn parentInfo() ComponentTypeInfo {
    return derive.componentType(Parent);
}

pub fn worldTransformInfo() ComponentTypeInfo {
    return .{
        .schema = .{
            .id = data.SchemaId.fromStringUnchecked(world_transform_name),
            .version = 1,
            .fields = &.{},
        },
        .name = world_transform_name,
        .size = @sizeOf(WorldTransform),
        .alignment = @alignOf(WorldTransform),
        .construct = &constructWorldTransform,
    };
}

fn constructWorldTransform(_: ?*anyopaque, out: [*]u8) void {
    const value: *WorldTransform = @ptrCast(@alignCast(out));
    value.* = .{};
}

// -- tests ---------------------------------------------------------------------------
//
// Registration through `World.enableHierarchy` and the content rules are tested in
// `world.zig`, beside the calls they exercise.

const testing = std.testing;

test "the transform's schema is its public layout, with the identity as defaults" {
    const schema = transform_schema;
    try testing.expectEqual(@as(u32, 1), schema.version);
    try testing.expectEqual(@as(usize, 3), schema.fields.len);
    try testing.expectEqualStrings("translation", schema.fields[0].name);
    try testing.expectEqualStrings("rotation", schema.fields[1].name);
    try testing.expectEqualStrings("scale", schema.fields[2].name);
    const rotation = schema.fields[1].type.nested;
    try testing.expectEqual(@as(usize, 4), rotation.len);
    try testing.expectEqualStrings("w", rotation[3].name);
    try testing.expectEqual(@as(usize, @sizeOf(core.math.Transform)), transformInfo().size);
}

test "a parent is one entity, and a world transform has nothing to save" {
    const parent = parentInfo();
    try testing.expectEqual(@as(usize, 1), parent.schema.fields.len);
    try testing.expectEqualStrings("entity", parent.schema.fields[0].name);
    try testing.expect(parent.serialize != null and parent.deserialize != null);

    const world = worldTransformInfo();
    try testing.expectEqual(@as(usize, 0), world.schema.fields.len);
    try testing.expect(world.serialize == null and world.deserialize == null);
    try testing.expectEqual(@as(u32, 64), world.size);
}
