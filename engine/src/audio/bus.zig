//! The mix's bus tree, built from `foundry:audio_bus` records (`docs/design/mixing.md` §8,
//! ADR-0067).
//!
//! **Built on the game thread, mixed on the device thread.** `build` reads the records, refuses
//! a broken tree by name, and allocates everything the callback will touch: one buffer per bus
//! below the root, and each bus's gain ramp. The mixer hands the finished tree to the callback
//! in one command and gets the old one back through its events ring, so the callback never
//! allocates or frees.
//!
//! **Order is documented** (I9): buses mix post-order, children before parents, siblings by
//! ascending content ID. It never follows load order, so a mod adding a bus does not reorder
//! anyone else's sums.
//!
//! **A child names its parent**, so a mod adds a bus with one record and overrides nobody's
//! list (ADR-0067). `build` takes every bus whose chain of parents reaches the root it is given.

const std = @import("std");
const core = @import("core");
const asset = @import("asset");

const voice = @import("voice.zig");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const log = core.log.scoped(.audio);

pub const max_buses: usize = 32;
/// The root is depth 0; a bus deeper than this is refused.
pub const max_depth: usize = 8;

pub const BuildError = error{
    /// The root is not a `foundry:audio_bus`, or a bus's parent is not one.
    NotABus,
    /// The root names a parent of its own.
    RootHasParent,
    /// A chain of parents loops back on itself.
    Cycle,
    /// A bus is more than eight parents below the root.
    TooDeep,
    /// More than 32 buses reach the root.
    TooManyBuses,
    /// A bus or one of its effects does not decode against its schema, or an effect is not
    /// an effect record.
    InvalidBus,
    OutOfMemory,
};

/// One bus tree. Index 0 is the root, whose buffer is the device's own.
pub const Tree = struct {
    gpa: Allocator,
    // -- fixed once built; both threads read them -----------------------------------
    ids: []ContentId,
    /// Each bus's parent index; the root's is 0, and the root is never added to anything.
    parents: []u16,
    /// Every bus but the root, children before parents, siblings by ascending content ID.
    order: []u16,
    /// Frames each bus buffer holds; a longer device buffer is mixed in blocks of this.
    block: usize,
    channels: u8,
    /// `block * channels` samples per bus below the root.
    buffers: []f32,
    // -- the game thread's ----------------------------------------------------------
    /// The decoded records, for telling a parameter change from a change of shape.
    records: []asset.mix.Bus,
    /// Each voice's bus in this tree, read by the callback once, when the tree is installed.
    voice_bus: []u16,
    // -- the callback's, once installed -----------------------------------------------
    /// The record's gain, changed by a reload.
    base: []f32,
    /// The game's gain (`setBusGain`), ramped.
    level: []voice.Ramp,

    pub fn count(self: *const Tree) usize {
        return self.ids.len;
    }

    /// The bus `id`'s index, or null when it is not in this tree.
    pub fn indexOf(self: *const Tree, id: ContentId) ?u16 {
        for (self.ids, 0..) |candidate, i| if (candidate.eql(id)) return @intCast(i);
        return null;
    }

    /// Bus `index`'s buffer, `frames` long. Not the root's.
    pub fn buffer(self: *Tree, index: u16, frames: usize) []f32 {
        std.debug.assert(index != 0);
        const stride = self.block * self.channels;
        return self.buffers[(index - 1) * stride ..][0 .. frames * self.channels];
    }

    /// Whether `other` has this tree's buses in the same places with the same parents and
    /// effect chains: a reload between the two is a parameter change, not a swap (§8.3).
    pub fn sameShape(self: *const Tree, other: *const Tree) bool {
        if (self.count() != other.count()) return false;
        for (self.ids, other.ids, self.parents, other.parents, self.records, other.records) |a, b, pa, pb, ra, rb| {
            if (!a.eql(b) or pa != pb) return false;
            if (ra.effect_count != rb.effect_count) return false;
            for (ra.effects(), rb.effects()) |ea, eb| if (!ea.eql(eb)) return false;
        }
        return true;
    }

    pub fn destroy(self: *Tree) void {
        const gpa = self.gpa;
        gpa.free(self.ids);
        gpa.free(self.parents);
        gpa.free(self.order);
        gpa.free(self.buffers);
        gpa.free(self.records);
        gpa.free(self.voice_bus);
        gpa.free(self.base);
        gpa.free(self.level);
        gpa.destroy(self);
    }
};

/// Builds the tree of every bus whose chain of parents reaches `root`, from `store`. `block`
/// is the frames each bus buffer holds and `voices` the voice count, so `voice_bus` has a place
/// for each. Bus records that do not reach `root` are left out; they may be another root's.
pub fn build(gpa: Allocator, store: *const asset.Store, root: ContentId, block: usize, channels: u8, voices: usize) BuildError!*Tree {
    // The root: a bus with no parent.
    const root_record = store.lookup(root) orelse return error.NotABus;
    if (!root_record.schema_id.eql(asset.mix.bus.id)) return error.NotABus;
    const root_bus = decode(root_record) orelse return error.InvalidBus;
    if (root_bus.parent != null) return error.RootHasParent;

    // Every bus record, decoded, with its effects checked where their IDs resolve.
    var all: std.ArrayList(struct { id: ContentId, bus: asset.mix.Bus }) = .empty;
    defer all.deinit(gpa);
    var it = store.iterate(asset.mix.bus.id);
    while (it.next()) |record| {
        const value = decode(record) orelse return error.InvalidBus;
        try all.append(gpa, .{ .id = record.id, .bus = value });
    }

    // Which reach the root, and how deep. A parent that is not a bus is a broken package, and
    // a chain longer than the number of buses has looped.
    var members: std.ArrayList(usize) = .empty;
    defer members.deinit(gpa);
    for (all.items, 0..) |entry, i| {
        if (entry.id.eql(root)) continue;
        var at = entry.bus;
        var depth: usize = 0;
        const reaches = while (true) {
            const parent = at.parent orelse break false;
            depth += 1;
            if (depth > all.items.len) return error.Cycle;
            if (parent.eql(root)) break true;
            const next = for (all.items) |other| {
                if (other.id.eql(parent)) break other;
            } else return error.NotABus;
            at = next.bus;
        };
        if (!reaches) continue;
        if (depth > max_depth) return error.TooDeep;
        try members.append(gpa, i);
    }
    if (members.items.len + 1 > max_buses) return error.TooManyBuses;
    for (members.items) |i| asset.mix.checkBusReferences(&all.items[i].bus, store) catch |err| {
        log.warn("{f}: audio bus {s}", .{ all.items[i].id, asset.mix.describe(err) });
        return error.InvalidBus;
    };
    asset.mix.checkBusReferences(&root_bus, store) catch |err| {
        log.warn("{f}: audio bus {s}", .{ root, asset.mix.describe(err) });
        return error.InvalidBus;
    };

    // Indices: the root first, then the rest by ascending content ID.
    const n = members.items.len + 1;
    std.mem.sort(usize, members.items, all.items, struct {
        fn less(items: @TypeOf(all.items), a: usize, b: usize) bool {
            return items[a].id.hash < items[b].id.hash;
        }
    }.less);

    const tree = try gpa.create(Tree);
    errdefer gpa.destroy(tree);
    tree.gpa = gpa;
    tree.block = @max(block, 1);
    tree.channels = channels;
    tree.ids = try gpa.alloc(ContentId, n);
    errdefer gpa.free(tree.ids);
    tree.records = try gpa.alloc(asset.mix.Bus, n);
    errdefer gpa.free(tree.records);
    tree.parents = try gpa.alloc(u16, n);
    errdefer gpa.free(tree.parents);
    tree.order = try gpa.alloc(u16, n - 1);
    errdefer gpa.free(tree.order);
    tree.buffers = try gpa.alloc(f32, (n - 1) * tree.block * channels);
    errdefer gpa.free(tree.buffers);
    tree.voice_bus = try gpa.alloc(u16, voices);
    errdefer gpa.free(tree.voice_bus);
    tree.base = try gpa.alloc(f32, n);
    errdefer gpa.free(tree.base);
    tree.level = try gpa.alloc(voice.Ramp, n);
    errdefer gpa.free(tree.level);

    tree.ids[0] = root;
    tree.records[0] = root_bus;
    for (members.items, 1..) |i, k| {
        tree.ids[k] = all.items[i].id;
        tree.records[k] = all.items[i].bus;
    }
    for (tree.records, 0..) |record, k| {
        tree.parents[k] = if (record.parent) |p| tree.indexOf(p).? else 0;
        tree.base[k] = record.gain;
        tree.level[k] = .hold(1);
    }
    @memset(tree.voice_bus, 0);

    // Post-order: each bus after all of its children, siblings by index, which is ascending
    // content ID. The root is not in `order`; the callback finishes with it.
    var written: usize = 0;
    visit(tree, 0, &written);
    std.debug.assert(written == n - 1);
    return tree;
}

fn visit(tree: *Tree, index: u16, written: *usize) void {
    for (tree.parents, 0..) |parent, child| {
        if (child == 0 or parent != index) continue;
        visit(tree, @intCast(child), written);
    }
    if (index == 0) return;
    tree.order[written.*] = index;
    written.* += 1;
}

fn decode(record: asset.Record) ?asset.mix.Bus {
    return asset.mix.decodeBus(record.fields) catch |err| {
        log.warn("{f}: audio bus {s}", .{ record.id, asset.mix.describe(err) });
        return null;
    };
}
