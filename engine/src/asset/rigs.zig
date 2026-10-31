//! `Rigs`: rigs built from `foundry:animation_set` records (`docs/design/animation-logic.md` §4,
//! ADR-0071).
//!
//! **Below any renderer,** because root motion and events are simulation: a tick, a replay or a
//! server has to reach a clip with no `render3d` linked. It converts and does not evaluate, so
//! ADR-0058's objection to evaluation in `asset` stands.
//!
//! **A clip is validated here, once.** `anim.Rig.validate` walks every key when a rig is built, and
//! nothing walks one on a tick.
//!
//! **A rig borrows its keys and skeleton from the registry.** A `*const anim.Rig` lasts until the
//! next `acquire` or `contentChanged`, which a game calls at the seam where it already rebuilds
//! what depends on content, after the registry's reload and before the next tick. A handle lasts
//! until released.

const std = @import("std");
const anim = @import("anim");
const core = @import("core");
const data = @import("data");

const animation = @import("animation.zig");
const registry_mod = @import("registry.zig");
const schemas = @import("schemas.zig");
const set_mod = @import("animation_set.zig");
const skeleton_mod = @import("skeleton.zig");

const Allocator = std.mem.Allocator;
const AssetHandle = registry_mod.AssetHandle;
const ContentId = core.ContentId;
const Registry = registry_mod.Registry;
const log = core.log.scoped(.asset);

const RigTag = opaque {};

/// A rig, by handle (I1). It survives a reload, including one that breaks the rig.
pub const RigHandle = core.Handle(RigTag);

pub const BuildError = Allocator.Error || set_mod.DecodeError || anim.Rig.ValidateError || error{
    MissingSet,
    NotASet,
    MissingModel,
    NotAModel,
    /// The model names no skeleton, or no clips.
    NotSkinned,
    /// The model's skeleton or one of its clips did not load.
    AssetUnavailable,
    /// The set or its `start` names a clip the model does not have.
    UnknownClip,
    /// A clip was made for a different skeleton.
    JointCountMismatch,
};

/// Everything one rig owns besides its asset handles. A rebuild makes a new one and swaps it in.
const Built = struct {
    skeleton: AssetHandle = .none,
    assets: []AssetHandle = &.{},
    clips: []anim.RigClip = &.{},
    tracks: []anim.Track = &.{},
    events: []anim.Event = &.{},
    labels: []u8 = &.{},
    rig: anim.Rig = undefined,

    fn release(self: *Built, gpa: Allocator, assets: *Registry) void {
        if (!self.skeleton.isNone()) assets.release(self.skeleton);
        for (self.assets) |handle| assets.release(handle);
        gpa.free(self.assets);
        gpa.free(self.clips);
        gpa.free(self.tracks);
        gpa.free(self.events);
        gpa.free(self.labels);
        self.* = .{};
    }
};

const Entry = struct {
    id: ContentId,
    refs: u32,
    /// Null while the set does not build.
    built: ?Built,
};

pub const Rigs = struct {
    gpa: Allocator,
    assets: *Registry,
    entries: core.HandlePool(RigTag, Entry) = .empty,
    by_id: std.AutoHashMapUnmanaged(u64, RigHandle) = .empty,

    /// Records are read from `assets`' own store, so the two can never disagree about which
    /// packages are loaded.
    pub fn init(gpa: Allocator, assets: *Registry) Rigs {
        return .{ .gpa = gpa, .assets = assets };
    }

    pub fn deinit(self: *Rigs) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value.built) |*built| built.release(self.gpa, self.assets);
        }
        self.entries.deinit(self.gpa);
        self.by_id.deinit(self.gpa);
    }

    /// The rig `set` builds. The same ID is one rig, counted. A refusal leaves nothing behind.
    pub fn acquire(self: *Rigs, set: ContentId) BuildError!RigHandle {
        if (self.by_id.get(set.hash)) |handle| {
            const entry = self.entries.get(handle).?;
            // A rig a reload broke says why, and mends if its set now builds.
            if (entry.built == null) entry.built = try self.build(set);
            entry.refs += 1;
            return handle;
        }
        var built = try self.build(set);
        errdefer built.release(self.gpa, self.assets);
        try self.by_id.ensureUnusedCapacity(self.gpa, 1);
        const handle = try self.entries.add(self.gpa, .{ .id = set, .refs = 1, .built = built });
        self.by_id.putAssumeCapacity(set.hash, handle);
        return handle;
    }

    pub fn release(self: *Rigs, handle: RigHandle) void {
        const entry = self.entries.get(handle) orelse return;
        entry.refs -= 1;
        if (entry.refs != 0) return;
        if (entry.built) |*built| built.release(self.gpa, self.assets);
        _ = self.by_id.remove(entry.id.hash);
        _ = self.entries.remove(handle);
    }

    /// The rig, or null while its set does not build. Borrowed until the next `acquire` or
    /// `contentChanged`, so a game keeps the handle and asks.
    pub fn get(self: *const Rigs, handle: RigHandle) ?*const anim.Rig {
        const entry = self.entries.getConst(handle) orelse return null;
        return if (entry.built) |*built| &built.rig else null;
    }

    /// The rig of a set, for what names a set by content ID, as `foundry:animator` does. Null for
    /// a set nobody acquired.
    pub fn lookup(self: *const Rigs, set: ContentId) ?*const anim.Rig {
        return self.get(self.by_id.get(set.hash) orelse return null);
    }

    /// Rebuilds every rig from what is loaded now, keeping handles. Call it after the registry's
    /// reload. A rig that no longer builds answers null, and is said once. It can't keep what it
    /// had, because what it borrowed may be gone. It is tried again at the next call.
    pub fn contentChanged(self: *Rigs) Allocator.Error!void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            const had = entry.value.built != null;
            const fresh: ?Built = self.build(entry.value.id) catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                if (had) log.warn("animation set {f} no longer builds ({t}); its rig is gone until it does", .{ entry.value.id, err });
                break :blk null;
            };
            const slot = self.entries.get(entry.id).?;
            if (slot.built) |*old| old.release(self.gpa, self.assets);
            slot.built = fresh;
        }
    }

    fn build(self: *Rigs, set: ContentId) BuildError!Built {
        const gpa = self.gpa;
        const store = self.assets.store;
        const record = store.lookup(set) orelse return error.MissingSet;
        if (!record.schema_id.eql(set_mod.schema.id)) return error.NotASet;
        const fields = record.fields;
        try set_mod.check(fields);

        const model_id = try set_mod.model(fields);
        const model = store.lookup(model_id) orelse return error.MissingModel;
        if (!model.schema_id.eql(schemas.model.id)) return error.NotAModel;
        const skeleton_id = idField(model.fields, "skeleton") orelse return error.NotSkinned;
        const model_clips = listField(model.fields, "clips") orelse return error.NotSkinned;
        if (model_clips.len == 0) return error.NotSkinned;
        if (model_clips.len > anim.max_rig_clips) return error.TooManyClips;

        var built: Built = .{};
        errdefer built.release(gpa, self.assets);
        built.skeleton = self.assets.acquireWith(gpa, skeleton_id, skeleton_mod.skeletonLoader()) catch |err| return loadRefusal(err);
        const skeleton = skeleton_mod.fromPayload(self.assets.getIfLoader(built.skeleton, skeleton_mod.skeletonLoader()).?.payload);
        const joints: u32 = @intCast(skeleton.parents.len);

        // First the shape, so that a rig's arrays are allocated once and never move.
        built.assets = try gpa.alloc(AssetHandle, model_clips.len);
        @memset(built.assets, .none);
        built.clips = try gpa.alloc(anim.RigClip, model_clips.len);
        const listed = try set_mod.clips(fields);
        var track_count: usize = 0;
        var event_count: usize = 0;
        var label_bytes: usize = 0;
        const sources = try gpa.alloc(*const animation.Animation, model_clips.len);
        defer gpa.free(sources);
        for (0..model_clips.len) |i| {
            const entry = (try model_clips.nestedAt(@intCast(i))) orelse return error.NotSkinned;
            const clip_id = idField(entry, "clip") orelse return error.NotSkinned;
            const clip_name = stringField(entry, "name") orelse return error.NotSkinned;
            built.assets[i] = self.assets.acquireWith(gpa, clip_id, animation.animationLoader()) catch |err| return loadRefusal(err);
            const source = animation.fromPayload(self.assets.getIfLoader(built.assets[i], animation.animationLoader()).?.payload);
            source.checkJointCount(joints) catch return error.JointCountMismatch;
            sources[i] = source;
            track_count += source.tracks.len;
            label_bytes += clip_name.len;
            if (try listedClip(listed, clip_name)) |clip| {
                if (clip.events) |events| event_count += events.len;
            }
        }
        // A set listing a clip the model lacks is a mistake to be told about, not one to skip.
        if (listed) |list| for (0..list.len) |i| {
            if (!hasClip(model_clips, (try set_mod.clipAt(list, @intCast(i))).name)) return error.UnknownClip;
        };

        built.tracks = try gpa.alloc(anim.Track, track_count);
        built.events = try gpa.alloc(anim.Event, event_count);
        built.labels = try gpa.alloc(u8, label_bytes);
        var next_track: usize = 0;
        var next_event: usize = 0;
        var next_label: usize = 0;
        for (built.clips, sources, 0..) |*out, source, i| {
            const entry = (try model_clips.nestedAt(@intCast(i))).?;
            const clip_name = stringField(entry, "name").?;
            const tracks = built.tracks[next_track..][0..source.tracks.len];
            next_track += tracks.len;
            for (tracks, source.tracks) |*to, from| to.* = .{
                .joint = from.joint,
                .path = @enumFromInt(@intFromEnum(from.path)),
                .interpolation = @enumFromInt(@intFromEnum(from.interpolation)),
                .times = from.times,
                .values = from.values,
            };
            const label = built.labels[next_label..][0..clip_name.len];
            next_label += label.len;
            @memcpy(label, clip_name);

            out.* = .{ .name = anim.clipName(clip_name), .clip = .{ .duration = source.duration, .tracks = tracks }, .label = label };
            const meaning = (try listedClip(listed, clip_name)) orelse continue;
            out.loop = meaning.loop;
            out.speed = meaning.speed;
            out.motion = meaning.motion;
            const list = meaning.events orelse continue;
            const events = built.events[next_event..][0..list.len];
            next_event += events.len;
            for (events, 0..) |*event, e| event.* = try set_mod.eventAt(list, @intCast(e));
            out.events = events;
        }
        std.mem.sort(anim.RigClip, built.clips, {}, lessByName);

        const start_name = (try set_mod.start(fields)) orelse stringField((try model_clips.nestedAt(0)).?, "name").?;
        if (!hasClip(model_clips, start_name)) return error.UnknownClip;
        built.rig = .{
            .skeleton = .{ .parents = skeleton.parents, .rest = skeleton.rest, .inverse_bind = skeleton.inverse_bind, .root = skeleton.root },
            .clips = built.clips,
            .start = anim.clipName(start_name),
            .motion_joint = if (try set_mod.motionJoint(fields)) |joint| try jointNamed(skeleton, joint) else anim.no_parent,
        };
        try built.rig.validate();
        return built;
    }
};

fn lessByName(_: void, a: anim.RigClip, b: anim.RigClip) bool {
    return a.name < b.name;
}

fn loadRefusal(err: registry_mod.AcquireError) BuildError {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.AssetUnavailable;
}

fn jointNamed(skeleton: *const skeleton_mod.Skeleton, joint: []const u8) BuildError!u16 {
    for (skeleton.names, 0..) |candidate, i| {
        if (std.mem.eql(u8, candidate, joint)) return @intCast(i);
    }
    return error.UnknownJoint;
}

fn listedClip(listed: ?data.fpk.List, clip_name: []const u8) set_mod.DecodeError!?set_mod.Clip {
    const list = listed orelse return null;
    for (0..list.len) |i| {
        const clip = try set_mod.clipAt(list, @intCast(i));
        if (std.mem.eql(u8, clip.name, clip_name)) return clip;
    }
    return null;
}

fn hasClip(model_clips: data.fpk.List, clip_name: []const u8) bool {
    for (0..model_clips.len) |i| {
        const entry = (model_clips.nestedAt(@intCast(i)) catch null) orelse continue;
        if (std.mem.eql(u8, stringField(entry, "name") orelse continue, clip_name)) return true;
    }
    return false;
}

fn indexOf(fields: data.fpk.Fields, name: []const u8) ?u32 {
    for (fields.fields, 0..) |field, i| {
        if (std.mem.eql(u8, field.name, name)) return @intCast(i);
    }
    return null;
}

fn idField(fields: data.fpk.Fields, name: []const u8) ?ContentId {
    return (fields.idAt(indexOf(fields, name) orelse return null) catch null) orelse null;
}

fn stringField(fields: data.fpk.Fields, name: []const u8) ?[]const u8 {
    return (fields.stringAt(indexOf(fields, name) orelse return null) catch null) orelse null;
}

fn listField(fields: data.fpk.Fields, name: []const u8) ?data.fpk.List {
    return (fields.listAt(indexOf(fields, name) orelse return null) catch null) orelse null;
}
