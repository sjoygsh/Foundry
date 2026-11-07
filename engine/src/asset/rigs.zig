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
//!
//! **Machines are built here too** (`animation-states.md` §10): a `foundry:animation_machine`
//! against the rig of a set, checked by `anim.Machine.validate`, rebuilt with its rig.
//!
//! **Version 3's legs, aim chains and blends** (`animation-ik.md` §6) are built here as well. A blend
//! is an entry of the rig's clips. A leg's `sole` is read from the rest pose, and every looping clip's
//! contacts from its foot heights, once, when the rig is built: a tick reads neither.

const std = @import("std");
const anim = @import("anim");
const core = @import("core");
const data = @import("data");

const animation = @import("animation.zig");
const machine_mod = @import("animation_machine.zig");
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
    /// An additive clip's `reference` is not a clip of the model.
    UnknownReference,
};

const MachineTag = opaque {};

/// A machine, by handle (I1), built against one set's rig.
pub const MachineHandle = core.Handle(MachineTag);

pub const MachineError = BuildError || machine_mod.DecodeError || anim.Machine.ValidateError || error{
    MissingMachine,
    NotAMachine,
    /// The set's rig does not build, so there is nothing to check the machine against.
    RigUnavailable,
};

/// Everything one rig owns besides its asset handles. A rebuild makes a new one and swaps it in.
const Built = struct {
    skeleton: AssetHandle = .none,
    assets: []AssetHandle = &.{},
    clips: []anim.RigClip = &.{},
    tracks: []anim.Track = &.{},
    events: []anim.Event = &.{},
    labels: []u8 = &.{},
    /// Version 2's: masks, their weights and names, and additive clips' reference poses.
    masks: []anim.Mask = &.{},
    weights: []f32 = &.{},
    mask_labels: []u8 = &.{},
    references: []core.math.Transform = &.{},
    /// Version 3's: blends' arrangements, legs, aim chains and their joints, their names, and every
    /// clip's contacts.
    blends: []anim.Blend = &.{},
    legs: []anim.Leg = &.{},
    aims: []anim.RigAim = &.{},
    aim_joints: []anim.AimJoint = &.{},
    part_labels: []u8 = &.{},
    contacts: []anim.Contact = &.{},
    rig: anim.Rig = undefined,

    fn release(self: *Built, gpa: Allocator, assets: *Registry) void {
        if (!self.skeleton.isNone()) assets.release(self.skeleton);
        for (self.assets) |handle| assets.release(handle);
        gpa.free(self.assets);
        gpa.free(self.clips);
        gpa.free(self.tracks);
        gpa.free(self.events);
        gpa.free(self.labels);
        gpa.free(self.masks);
        gpa.free(self.weights);
        gpa.free(self.mask_labels);
        gpa.free(self.references);
        gpa.free(self.blends);
        gpa.free(self.legs);
        gpa.free(self.aims);
        gpa.free(self.aim_joints);
        gpa.free(self.part_labels);
        gpa.free(self.contacts);
        self.* = .{};
    }
};

const MachineKey = struct { set: u64, machine: u64 };

const MachineEntry = struct {
    set: ContentId,
    machine: ContentId,
    /// Held while the machine is, so its rig lives as long.
    rig: RigHandle,
    refs: u32,
    /// Null while the machine does not build. Its arena holds everything the machine borrows.
    built: ?std.heap.ArenaAllocator,
    machine_value: anim.Machine = .{ .layers = &.{} },
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
    machines: core.HandlePool(MachineTag, MachineEntry) = .empty,
    by_pair: std.AutoHashMapUnmanaged(MachineKey, MachineHandle) = .empty,

    /// Records are read from `assets`' own store, so the two can never disagree about which
    /// packages are loaded.
    pub fn init(gpa: Allocator, assets: *Registry) Rigs {
        return .{ .gpa = gpa, .assets = assets };
    }

    pub fn deinit(self: *Rigs) void {
        var machines = self.machines.iterator();
        while (machines.next()) |entry| {
            if (entry.value.built) |*arena| arena.deinit();
        }
        self.machines.deinit(self.gpa);
        self.by_pair.deinit(self.gpa);
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

    /// The machine `machine` builds against `set`'s rig. The same pair is one machine, counted, and
    /// it holds the rig. A refusal leaves nothing behind.
    pub fn acquireMachine(self: *Rigs, set: ContentId, machine: ContentId) MachineError!MachineHandle {
        const key: MachineKey = .{ .set = set.hash, .machine = machine.hash };
        if (self.by_pair.get(key)) |handle| {
            const entry = self.machines.get(handle).?;
            if (entry.built == null) try self.buildMachine(entry);
            entry.refs += 1;
            return handle;
        }
        const rig = try self.acquire(set);
        errdefer self.release(rig);
        var entry: MachineEntry = .{ .set = set, .machine = machine, .rig = rig, .refs = 1, .built = null };
        try self.buildMachine(&entry);
        errdefer entry.built.?.deinit();
        try self.by_pair.ensureUnusedCapacity(self.gpa, 1);
        const handle = try self.machines.add(self.gpa, entry);
        self.by_pair.putAssumeCapacity(key, handle);
        return handle;
    }

    pub fn releaseMachine(self: *Rigs, handle: MachineHandle) void {
        const entry = self.machines.get(handle) orelse return;
        entry.refs -= 1;
        if (entry.refs != 0) return;
        if (entry.built) |*arena| arena.deinit();
        const rig = entry.rig;
        _ = self.by_pair.remove(.{ .set = entry.set.hash, .machine = entry.machine.hash });
        _ = self.machines.remove(handle);
        self.release(rig);
    }

    /// The machine, or null while it does not build. Borrowed as a rig is.
    pub fn getMachine(self: *const Rigs, handle: MachineHandle) ?*const anim.Machine {
        const entry = self.machines.getConst(handle) orelse return null;
        return if (entry.built != null) &entry.machine_value else null;
    }

    /// The machine of a set and a machine record, for what names both by content ID, as
    /// `foundry:animator` does. Null for a pair nobody acquired.
    pub fn lookupMachine(self: *const Rigs, set: ContentId, machine: ContentId) ?*const anim.Machine {
        return self.getMachine(self.by_pair.get(.{ .set = set.hash, .machine = machine.hash }) orelse return null);
    }

    fn buildMachine(self: *Rigs, entry: *MachineEntry) MachineError!void {
        const record = self.assets.store.lookup(entry.machine) orelse return error.MissingMachine;
        if (!record.schema_id.eql(machine_mod.schema.id)) return error.NotAMachine;
        const rig = self.get(entry.rig) orelse return error.RigUnavailable;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        errdefer arena.deinit();
        const machine = try machine_mod.decode(arena.allocator(), record.fields);
        try machine.validate(rig.*);
        entry.built = arena;
        entry.machine_value = machine;
    }

    /// Rebuilds every rig from what is loaded now, keeping handles, and then every machine against
    /// its rebuilt rig. Call it after the registry's reload. A rig or machine that no longer builds
    /// answers null, and is said once. It can't keep what it had, because what it borrowed may be
    /// gone. It is tried again at the next call.
    pub fn contentChanged(self: *Rigs) Allocator.Error!void {
        try self.rebuildRigs();
        var it = self.machines.iterator();
        while (it.next()) |entry| {
            const slot = self.machines.get(entry.id).?;
            const had = slot.built != null;
            if (slot.built) |*arena| arena.deinit();
            slot.built = null;
            self.buildMachine(slot) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                if (had) log.warn("animation machine {f} for set {f} no longer builds ({t}); it is gone until it does", .{ slot.machine, slot.set, err });
            };
        }
    }

    fn rebuildRigs(self: *Rigs) Allocator.Error!void {
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
        const blend_list = try set_mod.blends(fields);
        const blend_count: usize = if (blend_list) |list| list.len else 0;
        if (model_clips.len + blend_count > anim.max_rig_clips) return error.TooManyClips;

        var built: Built = .{};
        errdefer built.release(gpa, self.assets);
        built.skeleton = self.assets.acquireWith(gpa, skeleton_id, skeleton_mod.skeletonLoader()) catch |err| return loadRefusal(err);
        const skeleton = skeleton_mod.fromPayload(self.assets.getIfLoader(built.skeleton, skeleton_mod.skeletonLoader()).?.payload);
        const joints: u32 = @intCast(skeleton.parents.len);

        // First the shape, so that a rig's arrays are allocated once and never move.
        built.assets = try gpa.alloc(AssetHandle, model_clips.len);
        @memset(built.assets, .none);
        built.clips = try gpa.alloc(anim.RigClip, model_clips.len + blend_count);
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
        if (blend_list) |list| for (0..list.len) |i| {
            label_bytes += (try set_mod.blendAt(list, @intCast(i))).name.len;
        };
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
        for (built.clips[0..model_clips.len], sources, 0..) |*out, source, i| {
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
        if (blend_list) |list| {
            // A blend is a clip's entry, so it can't share a name with one.
            built.blends = try gpa.alloc(anim.Blend, list.len);
            for (built.blends, built.clips[model_clips.len..], 0..) |*arrangement, *out, i| {
                const blend = try set_mod.blendAt(list, @intCast(i));
                if (hasClip(model_clips, blend.name)) return error.BlendNameCollision;
                arrangement.* = try set_mod.arrangement(blend);
                var moves = false;
                for (arrangement.places()) |place| {
                    for (built.clips[0..model_clips.len]) |clip| {
                        if (clip.name == place) moves = moves or clip.motion;
                    }
                }
                const label = built.labels[next_label..][0..blend.name.len];
                next_label += label.len;
                @memcpy(label, blend.name);
                out.* = anim.blend_space.entryFor(anim.clipName(blend.name), arrangement, moves, hashOf(blend.sync), label);
            }
        }
        std.mem.sort(anim.RigClip, built.clips, {}, lessByName);

        const start_name = (try set_mod.start(fields)) orelse stringField((try model_clips.nestedAt(0)).?, "name").?;
        if (!hasClip(model_clips, start_name) and !try hasBlend(blend_list, start_name)) return error.UnknownClip;
        const anim_skeleton: anim.Skeleton = .{ .parents = skeleton.parents, .rest = skeleton.rest, .inverse_bind = skeleton.inverse_bind, .root = skeleton.root };
        try anim_skeleton.validate();
        try self.applyVersion2(&built, fields, anim_skeleton, skeleton);
        try self.applyVersion3(&built, fields, anim_skeleton, skeleton);
        built.rig = .{
            .skeleton = anim_skeleton,
            .clips = built.clips,
            .start = anim.clipName(start_name),
            .motion_joint = if (try set_mod.motionJoint(fields)) |joint| try jointNamed(skeleton, joint) else anim.no_parent,
            .masks = built.masks,
            .legs = built.legs,
            .aims = built.aims,
        };
        try built.rig.validate();
        try self.readContacts(&built);
        return built;
    }

    /// Version 3's legs and aim chains, their joints found by name. Blends were built with the clips.
    fn applyVersion3(self: *Rigs, built: *Built, fields: data.fpk.Fields, anim_skeleton: anim.Skeleton, skeleton: *const skeleton_mod.Skeleton) BuildError!void {
        const gpa = self.gpa;
        const leg_list = try set_mod.legs(fields);
        const aim_list = try set_mod.aims(fields);
        const leg_count: usize = if (leg_list) |list| list.len else 0;
        const aim_count: usize = if (aim_list) |list| list.len else 0;
        if (leg_count > anim.max_legs) return error.TooManyLegs;
        if (aim_count > anim.gaze.max_aims) return error.TooManyAims;
        var label_bytes: usize = 0;
        for (0..leg_count) |i| label_bytes += (try set_mod.legAt(leg_list.?, @intCast(i))).name.len;
        for (0..aim_count) |i| label_bytes += (try set_mod.aimAt(aim_list.?, @intCast(i))).name.len;
        built.part_labels = try gpa.alloc(u8, label_bytes);
        built.legs = try gpa.alloc(anim.Leg, leg_count);
        built.aims = try gpa.alloc(anim.RigAim, aim_count);
        built.aim_joints = try gpa.alloc(anim.AimJoint, aim_count * anim.ik.max_aim_joints);
        var next_label: usize = 0;
        for (built.legs, 0..) |*out, i| {
            const leg = try set_mod.legAt(leg_list.?, @intCast(i));
            const chain: anim.TwoBone = .{
                .root = try jointNamed(skeleton, leg.hip),
                .middle = try jointNamed(skeleton, leg.knee),
                .end = try jointNamed(skeleton, leg.foot),
            };
            const label = built.part_labels[next_label..][0..leg.name.len];
            next_label += label.len;
            @memcpy(label, leg.name);
            out.* = .{
                .name = anim.clipName(leg.name),
                .chain = chain,
                .sole = anim.feet.soleOf(anim_skeleton, chain.end),
                .contact_height = leg.contact_height,
                .max_raise = leg.max_raise,
                .max_drop = leg.max_drop,
                .label = label,
            };
        }
        for (built.aims, 0..) |*out, i| {
            const aim = try set_mod.aimAt(aim_list.?, @intCast(i));
            if (aim.joints.len == 0 or aim.joints.len > anim.ik.max_aim_joints) return error.NotAChain;
            const joints = built.aim_joints[i * anim.ik.max_aim_joints ..][0..aim.joints.len];
            for (joints, 0..) |*joint, j| {
                const entry = try set_mod.aimJointAt(aim.joints, @intCast(j));
                joint.* = .{ .joint = try jointNamed(skeleton, entry.joint), .share = entry.weight };
            }
            const label = built.part_labels[next_label..][0..aim.name.len];
            next_label += label.len;
            @memcpy(label, aim.name);
            out.* = .{ .name = anim.clipName(aim.name), .chain = .{ .joints = joints, .forward = aim.forward, .limit = aim.limit }, .label = label };
        }
    }

    /// Every looping clip's contacts, read from its foot heights now its keys are validated. An
    /// additive clip has none: contact is the base layer's.
    fn readContacts(self: *Rigs, built: *Built) BuildError!void {
        if (built.legs.len == 0) return;
        const gpa = self.gpa;
        const per_clip = anim.max_legs * anim.feet.max_contacts;
        built.contacts = try gpa.alloc(anim.Contact, built.clips.len * per_clip);
        const scratch = try gpa.alloc(core.math.Transform, built.rig.skeleton.jointCount());
        defer gpa.free(scratch);
        for (built.clips, 0..) |*clip, i| {
            if (clip.additive) continue;
            const out = built.contacts[i * per_clip ..][0..per_clip];
            const count = anim.feet.deriveContacts(built.rig.skeleton, clip, built.legs, .{ .local = scratch }, out);
            clip.contacts = out[0..count];
        }
        built.rig.clips = built.clips;
        try anim.feet.validateLegs(built.rig);
    }

    /// Version 2's lists, applied to clips already built: sync groups, rises, additive clips with
    /// their reference poses sampled once, and masks filled from their joints' subtrees.
    fn applyVersion2(self: *Rigs, built: *Built, fields: data.fpk.Fields, anim_skeleton: anim.Skeleton, skeleton: *const skeleton_mod.Skeleton) BuildError!void {
        const gpa = self.gpa;
        const joints = anim_skeleton.jointCount();
        if (try set_mod.syncs(fields)) |list| for (0..list.len) |i| {
            const entry = try set_mod.syncAt(list, @intCast(i));
            (try clipOf(built.clips, entry.clip)).sync = anim.clipName(entry.group);
        };
        if (try set_mod.rises(fields)) |list| for (0..list.len) |i| {
            const entry = try set_mod.riseAt(list, @intCast(i));
            (try clipOf(built.clips, entry.clip)).rise = entry.rise;
        };
        if (try set_mod.additives(fields)) |list| {
            built.references = try gpa.alloc(core.math.Transform, list.len * joints);
            for (0..list.len) |i| {
                const entry = try set_mod.additiveAt(list, @intCast(i));
                const clip = try clipOf(built.clips, entry.clip);
                const reference = if (entry.reference) |name_| (clipOf(built.clips, name_) catch return error.UnknownReference) else clip;
                // Sampled before `Rig.validate`, so the one clip sampled is validated first.
                try reference.clip.validate(joints);
                const pose = built.references[i * joints ..][0..joints];
                anim.sample(anim_skeleton, reference.clip, 0, .{ .local = pose });
                clip.additive = true;
                clip.reference = pose;
            }
        }
        const list = (try set_mod.masks(fields)) orelse return;
        built.masks = try gpa.alloc(anim.Mask, list.len);
        built.weights = try gpa.alloc(f32, list.len * joints);
        var label_bytes: usize = 0;
        for (0..list.len) |i| label_bytes += (try set_mod.maskAt(list, @intCast(i))).name.len;
        built.mask_labels = try gpa.alloc(u8, label_bytes);
        var next_label: usize = 0;
        for (built.masks, 0..) |*out, i| {
            const mask = try set_mod.maskAt(list, @intCast(i));
            if (mask.joints.len > anim.rig.max_mask_entries) return error.TooManyMaskJoints;
            var entries: [anim.rig.max_mask_entries]anim.MaskEntry = undefined;
            for (0..mask.joints.len) |j| {
                const joint = try set_mod.maskJointAt(mask.joints, @intCast(j));
                entries[j] = .{ .joint = try jointNamed(skeleton, joint.joint), .weight = joint.weight };
            }
            const weights = built.weights[i * joints ..][0..joints];
            anim.fillMask(anim_skeleton, entries[0..mask.joints.len], weights) catch |err| return switch (err) {
                error.UnknownJoint => error.UnknownJoint,
                error.InvalidMaskWeight => error.InvalidMaskWeight,
                error.TooManyMaskEntries => error.TooManyMaskJoints,
            };
            const label = built.mask_labels[next_label..][0..mask.name.len];
            next_label += label.len;
            @memcpy(label, mask.name);
            out.* = .{ .name = anim.clipName(mask.name), .weights = weights, .label = label };
        }
    }
};

/// The built clip a set names, or `UnknownClip`. A walk: a set lists few.
fn clipOf(clips: []anim.RigClip, clip_name: []const u8) BuildError!*anim.RigClip {
    const hash = anim.clipName(clip_name);
    for (clips) |*clip| {
        if (clip.name == hash) return clip;
    }
    return error.UnknownClip;
}

fn hashOf(text: ?[]const u8) u64 {
    return if (text) |t| anim.clipName(t) else 0;
}

fn hasBlend(list: ?data.fpk.List, blend_name: []const u8) set_mod.DecodeError!bool {
    const l = list orelse return false;
    for (0..l.len) |i| {
        if (std.mem.eql(u8, (try set_mod.blendAt(l, @intCast(i))).name, blend_name)) return true;
    }
    return false;
}

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
