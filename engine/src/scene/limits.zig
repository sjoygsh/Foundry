//! Hard bounds on anything a world builds from input it did not write.
//!
//! The same reasoning as `data.Limits`, and for the same reason: a save file says how many
//! entities to create and a content package says how many components a template has, and
//! both are input from mods. A bound is what turns a hostile or merely broken file into an
//! error message rather than an allocation the size of the disk (CLAUDE.md §5).
//!
//! Engine and game code creating entities directly is *not* the case these exist for, but
//! it is checked by the same bound, because two paths with two limits is how one of them
//! ends up unchecked.
//!
//! See `docs/design/entity-storage.md` §12.

/// Chosen so that no plausible world hits one, and no implausible one gets far.
pub const Limits = struct {
    /// Live entities. A million is well past what a 2D game keeps simulated at once, and
    /// far short of what a `u32` slot index can address.
    max_entities: u32 = 1 << 20,

    /// Registered component types. Every engine, game and mod type in one world. A
    /// thousand is generous for an engine that has zero of them today, and small enough
    /// that per-type work in `destroy` stays trivial.
    max_component_types: u32 = 1024,

    /// Registered systems. Engine, game and mod systems in one world.
    max_systems: u32 = 256,

    pub const default: Limits = .{};
};
