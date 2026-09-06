//! What the kernel remembers about a widget between frames, for the few widgets that need
//! anything remembered at all.
//!
//! **Most widgets have no state here and must not gain any.** A checkbox's flag lives with
//! the caller, a slider's value lives with the caller, a plot's samples live with the
//! caller: that is the immediate-mode bargain, and every value the kernel keeps a second
//! copy of is a value that can drift from the real one (`ui.md` §2).
//!
//! What is left is the state that has no owner anywhere else, because it is a property of
//! *looking at* a widget rather than of the thing displayed: how far a list is scrolled,
//! whether a tree node is open, where the caret is in a field. A caller could be made to
//! own those too, and for one panel that would be fine — but an entity inspector with a
//! collapsing header per entity would then need an array of bools parallel to the world,
//! which is exactly the second copy immediate mode exists to avoid.
//!
//! **Nothing here is ever serialized** and nothing is keyed on anything but a `ui.Id`,
//! which is runtime-only by construction (`id.zig`).
//!
//! Design: `docs/design/ui.md` §12, which names this store as one of the three things that
//! can fail to allocate.

const std = @import("std");
const core = @import("core");

const Allocator = std.mem.Allocator;
const Id = @import("id.zig").Id;

/// One widget's memory. A struct rather than a union so that an id reused for a different
/// widget kind — a caller bug, and from M7 possibly a mod's — is harmless rather than a
/// misread field.
pub const State = struct {
    /// How far a scroll region has been scrolled from the top, in points. Never negative.
    scroll: f32 = 0,
    /// Where in a scrollbar's thumb the pointer grabbed it, in points from the thumb's
    /// top. Without it a drag would snap the thumb's centre to the pointer on the frame
    /// it started, which is a visible jump of up to half a thumb.
    grab: f32 = 0,
    /// Whether a collapsing header is showing its contents.
    open: bool = false,
    /// The caret's offset in a text field's buffer, in bytes, always on a codepoint
    /// boundary.
    caret: u32 = 0,
    /// The frame this entry was last asked for.
    ///
    /// **`Input.frame`, which the caller supplies** — the kernel reads no clock (I9), so
    /// ageing is counted in frames described rather than in seconds elapsed. A caller that
    /// never sets it leaves every entry at zero, which makes `sweep` a no-op rather than
    /// making it evict everything.
    touched: u64 = 0,
};

/// Frames an entry survives without being asked for. Ten seconds at 60Hz: long enough that
/// a panel closed and reopened is where it was left, short enough that a list of entities
/// that no longer exist does not accumulate.
pub const max_age: u64 = 600;

/// How often the sweep runs. Every frame would be a hash-map walk per frame to reclaim a
/// few dozen bytes.
pub const sweep_interval: u64 = 300;

/// How many entries one sweep may drop. A bound rather than a limit: what is missed is
/// dropped by the next sweep, and the alternative is an unbounded pass or an allocation in
/// the one place that exists to reclaim memory.
const max_victims = 64;

pub const Store = struct {
    entries: std.AutoHashMapUnmanaged(Id, State) = .empty,
    /// Handed out when the map cannot grow. See `entry`.
    scratch: State = .{},

    pub fn deinit(self: *Store, gpa: Allocator) void {
        self.entries.deinit(gpa);
        self.* = .{};
    }

    /// The entry for `id`, created at its default the first time it is asked for.
    ///
    /// **Never fails.** Under memory pressure the caller gets a scratch entry that is
    /// forgotten as soon as something else asks for one: a scroll region that will not
    /// remember where it was scrolled is a better outcome than a frame that does not
    /// draw, and it is the same call the duplicate-id check already makes.
    pub fn entry(self: *Store, gpa: Allocator, id: Id, frame: u64) *State {
        const found = self.entries.getOrPut(gpa, id) catch {
            self.scratch = .{ .touched = frame };
            return &self.scratch;
        };
        if (!found.found_existing) found.value_ptr.* = .{};
        found.value_ptr.touched = frame;
        return found.value_ptr;
    }

    /// What is remembered about `id`, without creating anything. For tests and for a
    /// caller that wants to know rather than to change.
    pub fn peek(self: *const Store, id: Id) ?State {
        return self.entries.get(id);
    }

    pub fn count(self: *const Store) u32 {
        return self.entries.count();
    }

    /// Drops entries nothing has described for `max_age` frames.
    ///
    /// Called from `Context.begin`. Victims are collected before being removed rather than
    /// removed during iteration, which the hash map does not allow, and the buffer is on
    /// the stack because a function whose job is to give memory back should not ask for
    /// any.
    pub fn sweep(self: *Store, frame: u64) void {
        if (frame == 0 or frame <= max_age) return;
        if (frame % sweep_interval != 0) return;
        const cutoff = frame - max_age;

        var victims: [max_victims]Id = undefined;
        var found: usize = 0;
        var it = self.entries.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.touched >= cutoff) continue;
            victims[found] = e.key_ptr.*;
            found += 1;
            if (found == victims.len) break;
        }
        for (victims[0..found]) |id| _ = self.entries.remove(id);
    }

    /// Forget everything. What a caller does when an overlay closes for good.
    pub fn clear(self: *Store) void {
        self.entries.clearRetainingCapacity();
    }
};

const testing = std.testing;

test "an entry appears at its default and persists" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);
    const id = Id.root.child("list");

    try testing.expectEqual(@as(?State, null), store.peek(id));

    store.entry(testing.allocator, id, 1).scroll = 42;
    try testing.expectEqual(@as(f32, 42), store.peek(id).?.scroll);
    try testing.expectEqual(@as(f32, 42), store.entry(testing.allocator, id, 2).scroll);
    try testing.expectEqual(@as(u64, 2), store.peek(id).?.touched);
}

test "two ids remember two things" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);

    store.entry(testing.allocator, Id.root.child("a"), 1).open = true;
    _ = store.entry(testing.allocator, Id.root.child("b"), 1);

    try testing.expect(store.peek(Id.root.child("a")).?.open);
    try testing.expect(!store.peek(Id.root.child("b")).?.open);
    try testing.expectEqual(@as(u32, 2), store.count());
}

test "a stale entry is swept and a live one is not" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);
    const stale = Id.root.child("closed");
    const live = Id.root.child("open");

    _ = store.entry(testing.allocator, stale, 1);
    _ = store.entry(testing.allocator, live, 1);

    // A frame the sweep runs on, far enough past both to make them candidates...
    const frame = sweep_interval * 4;
    _ = store.entry(testing.allocator, live, frame);
    store.sweep(frame);

    try testing.expectEqual(@as(?State, null), store.peek(stale));
    try testing.expect(store.peek(live) != null);
}

test "a caller that never counts frames never loses anything" {
    // `Input.frame` defaults to zero, and a caller driving the UI without setting it would
    // otherwise have every entry look infinitely old on the first sweep.
    var store: Store = .{};
    defer store.deinit(testing.allocator);
    const id = Id.root.child("list");

    _ = store.entry(testing.allocator, id, 0);
    for (0..4) |_| store.sweep(0);
    try testing.expect(store.peek(id) != null);
}

test "a sweep between intervals does nothing" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);
    const id = Id.root.child("list");

    _ = store.entry(testing.allocator, id, 1);
    store.sweep(sweep_interval * 4 + 1);
    try testing.expect(store.peek(id) != null);

    store.sweep(sweep_interval * 4);
    try testing.expectEqual(@as(?State, null), store.peek(id));
}

test "clearing forgets everything and keeps the capacity" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);

    for (0..8) |i| _ = store.entry(testing.allocator, Id.root.childIndex(i), 1);
    try testing.expectEqual(@as(u32, 8), store.count());

    store.clear();
    try testing.expectEqual(@as(u32, 0), store.count());
    _ = store.entry(testing.allocator, Id.root.childIndex(0), 1);
    try testing.expectEqual(@as(u32, 1), store.count());
}

test "an entry survives the map growing under it, because it is asked for again" {
    // The pointer `entry` returns is valid until the next insertion, which is the same
    // rule every hash map has. Widgets read it and write it inside one call and never keep
    // it, and this pins that the *value* survives regardless.
    var store: Store = .{};
    defer store.deinit(testing.allocator);
    const first = Id.root.child("first");

    store.entry(testing.allocator, first, 1).caret = 7;
    for (0..512) |i| _ = store.entry(testing.allocator, Id.root.childIndex(i), 1);
    try testing.expectEqual(@as(u32, 7), store.entry(testing.allocator, first, 1).caret);
}
