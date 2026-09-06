//! Widget identity: how a widget is recognised as the same widget next frame.
//!
//! An immediate-mode UI describes every widget afresh each frame, but the interaction
//! state — a half-finished drag, where the keyboard is, how far a list is scrolled — must
//! survive between them. An `Id` is the only thing carrying that continuity, so where it
//! comes from decides what the UI can do.
//!
//! **Not the pointer.** I9 forbids behaviour that depends on an address, and a UI keyed on
//! them changes behaviour when an allocator hands back a different block.
//!
//! **Not the displayed text**, which is what every other immediate-mode UI does and is the
//! right trade for a debug tool nobody translates. Foundry's game UI is translated content
//! (ADR-0024), and an id derived from an on-screen string changes for *every* widget at once
//! when the language does — resetting scroll positions, dropping focus, collapsing open
//! trees. The bug appears only in the language a developer does not test, and by then every
//! call site has to change to fix it. So identity and display text are separate parameters
//! in every kernel call, and only the debug widget set may derive one from the other.
//!
//! Design: `docs/design/ui.md` §3.

const std = @import("std");

/// FNV-1a's constants. Deliberately **not** `core.id.fnv1a64`: see `Id`.
const offset_basis: u64 = 0xcbf29ce484222325;
const prime: u64 = 0x100000001b3;

/// A widget's identity within one UI context.
///
/// **This is not a `ContentId`, and the resemblance is a trap.** Both are 64-bit FNV
/// values, and that is where it ends. A `ContentId` is stable across builds, reaches
/// compiled packages and save files, and `core/id.zig` freezes its algorithm for exactly
/// that reason. A `ui.Id` is **runtime-only, never serialized, never persisted**, and free
/// to change the moment a layout does. Calling `core.id.fnv1a64` here would work and would
/// invite a future session to assume the guarantees travel with the function.
pub const Id = enum(u64) {
    /// No widget. Nothing is hot, active or focused.
    none = 0,
    _,

    /// The seed every id descends from. A context starts its stack here.
    pub const root: Id = @enumFromInt(offset_basis);

    /// Mix a name into a parent seed. Order matters: `a.child("x").child("y")` is not
    /// `a.child("y").child("x")`, which is what makes nesting meaningful.
    pub fn child(parent: Id, name: []const u8) Id {
        var hash: u64 = @intFromEnum(parent);
        for (name) |b| {
            hash ^= b;
            hash = hash *% prime;
        }
        return fromHash(hash);
    }

    /// The same, for a loop over things that have no names. A list of two hundred entities
    /// needs two hundred ids and not two hundred strings.
    pub fn childIndex(parent: Id, index: usize) Id {
        // Little-endian bytes rather than native, so the id a layout produces does not
        // depend on the machine. I9 does not promise bit-exactness across machines and
        // this is not load-bearing for it; it costs nothing and removes a surprise.
        const bytes = std.mem.toBytes(std.mem.nativeToLittle(u64, index));
        var hash: u64 = @intFromEnum(parent);
        for (bytes) |b| {
            hash ^= b;
            hash = hash *% prime;
        }
        return fromHash(hash);
    }

    pub fn isNone(self: Id) bool {
        return self == .none;
    }

    /// The raw value, for a caller that must store or compare one. Not for serializing:
    /// see the type's documentation for why an id must not outlive the run that made it.
    pub fn bits(self: Id) u64 {
        return @intFromEnum(self);
    }

    /// One value in 2^64 is remapped, so that a real widget can never hash to `none` and
    /// silently become un-interactable. Which value is arbitrary; that there is one is not.
    fn fromHash(hash: u64) Id {
        return @enumFromInt(if (hash == 0) 1 else hash);
    }
};

const testing = std.testing;

test "a name always produces the same id" {
    try testing.expectEqual(Id.root.child("save"), Id.root.child("save"));
    try testing.expect(Id.root.child("save") != Id.root.child("load"));
}

test "nesting is ordered, and a parent separates otherwise-identical children" {
    const panel_a = Id.root.child("panel.a");
    const panel_b = Id.root.child("panel.b");

    // The same leaf name under two parents is two widgets. This is the whole reason the
    // id stack exists.
    try testing.expect(panel_a.child("ok") != panel_b.child("ok"));

    // And order is not commutative, so a nesting mistake shows up as a different widget
    // rather than as an accidental collision.
    try testing.expect(Id.root.child("x").child("y") != Id.root.child("y").child("x"));
}

test "indices are ids too, and do not collide with their own digits" {
    const list = Id.root.child("entities");
    try testing.expectEqual(list.childIndex(7), list.childIndex(7));
    try testing.expect(list.childIndex(7) != list.childIndex(8));

    // An index is not its decimal spelling: `childIndex(7)` and `child("7")` are different
    // widgets, which is correct and worth pinning so nobody "simplifies" one into the other.
    try testing.expect(list.childIndex(7) != list.child("7"));
}

test "no id is ever none" {
    try testing.expect(!Id.root.child("").isNone());
    try testing.expect(!Id.root.childIndex(0).isNone());
    try testing.expect(Id.none.isNone());
}

test "an empty name is still a step" {
    // `child("")` returns the parent's hash unchanged, which would make a widget share its
    // parent's id. That is legal and detectable rather than an error, but the *value* must
    // not be none even when the parent seed is.
    try testing.expectEqual(@as(u64, offset_basis), Id.root.child("").bits());
    try testing.expectEqual(@as(u64, 1), Id.none.child("").bits());
}
