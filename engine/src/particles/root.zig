//! Foundry `particles` — layer L1. Depends on **`core` and nothing else**.
//!
//! A CPU particle system as a simulation below the renderers (ADR-0064): an emitter's
//! description as a validated value, a fixed-capacity store per running emitter, and a
//! deterministic step that ages, moves and spawns, and the expansion of live particles into
//! sorted, camera-facing quads written into the caller's buffers.
//!
//! **No assets, no entities, no renderer, no I/O.** `asset` decodes the
//! `foundry:particle_emitter` record and `render3d` converts it into an `Emitter`; neither is
//! nameable from here, so the simulation tests with no file, no ECS and no device, and either
//! renderer could draw it.
//!
//! **Time is the caller's** (I9): a tick and a fixed delta. Nothing reads a clock or an address,
//! randomness is a `core.rng.Pcg32` per system, and particles are kept in spawn order. The same
//! binary and inputs give the same bytes; across machines the last bit is not promised
//! (ADR-0013).
//!
//! **Allocation happens once**, in `System.init`, at the store's capacity.
//!
//! Design: `docs/design/particles.md`

pub const emitter = @import("emitter.zig");
pub const expand = @import("expand.zig");
pub const system = @import("system.zig");

// A game sees these today and a mod may later, so renaming one is a compatibility decision
// rather than a tidy-up (CLAUDE.md §7).
pub const Aabb = system.Aabb;
pub const Burst = emitter.Burst;
pub const ColorKey = emitter.ColorKey;
pub const Counts = system.Counts;
pub const Emitter = emitter.Emitter;
pub const Expanded = expand.Expanded;
pub const Expander = expand.Expander;
pub const Output = expand.Output;
pub const View = expand.View;
pub const Error = emitter.Error;
pub const Facing = emitter.Facing;
pub const Key = emitter.Key;
pub const Particle = system.Particle;
pub const Range = emitter.Range;
pub const Shape = emitter.Shape;
pub const ShapeKind = emitter.ShapeKind;
pub const Sheet = emitter.Sheet;
pub const Space = emitter.Space;
pub const System = system.System;
pub const max_bursts = emitter.max_bursts;
pub const max_capacity = emitter.max_capacity;
pub const max_curve_keys = emitter.max_curve_keys;

test {
    _ = emitter;
    _ = expand;
    _ = system;
    _ = @import("tests.zig");
    _ = @import("expand_tests.zig");
}
