//! Foundry `physics2d` — layer L1. Depends on **`core` and nothing else**.
//!
//! Collision, not dynamics (ADR-0022). Shapes, tile grids, sweeps, queries and a sliding
//! response. There is no mass, no inertia, no restitution, no friction solving, no joints, no
//! stacking, no torque and no rotation, and their absence is the decision rather than a
//! backlog: a top-down tile game needs a moving box tested against static geometry with a
//! response that slides, and the rest is most of what a rigid-body engine is made of.
//!
//! **No entities, no content, no I/O.** `scene` is above this module and cannot be named from
//! it, so a body carries an opaque `u64` the game fills in — `entity.bits()`, in practice.
//! That is the entire coupling to the rest of the engine, and it is why collision works with
//! no ECS at all. A tile grid's arrays are borrowed from whoever loaded them, so the module
//! never learns what an asset is either.
//!
//! **Why our own, when Box2D v3 and Chipmunk2D are both MIT and both permitted.** Licensing
//! did not decide it; I9 did. A solver's contact-resolution order changes its answers, that
//! order is an implementation detail a library is free to change between versions, and I9
//! requires it documented and stable — so resting determinism on someone else's solver means
//! auditing it as carefully as writing our own (ADR-0022).
//!
//! **Determinism is interface contract here, not an implementation note.** Bodies iterate in
//! handle-index order; grid cells in row-major order; grids before bodies; the broadphase
//! never determines order, because candidates are sorted before use; no clock, no RNG, no
//! global state, and no behaviour derived from an address.
//!
//! Everything reaching this module comes from a game, and from M7 from a mod, so shapes and
//! grids are **validated and refused, never asserted** (CLAUDE.md §7).
//!
//! Design: `docs/design/tilemaps-and-collision.md`

pub const body = @import("body.zig");
pub const grid = @import("grid.zig");
pub const shape = @import("shape.zig");
pub const world = @import("world.zig");

// The names reached for most often. These are seen by people we do not control — a game
// today, compiled mods from M7 — so renaming one is a compatibility decision rather than a
// tidy-up (CLAUDE.md §7).
pub const Body = body.Body;
pub const BodyHandle = body.BodyHandle;
pub const BodyKind = body.BodyKind;
pub const Bounds = shape.Bounds;
pub const Contact = shape.Contact;
pub const Face = shape.Face;
pub const FaceMask = shape.FaceMask;
pub const Grid = grid.Grid;
pub const GridHandle = grid.GridHandle;
pub const GridHit = grid.GridHit;
pub const Shape = shape.Shape;
pub const Sweep = shape.Sweep;
pub const World = world.World;

pub const AddBodyError = world.AddBodyError;
pub const AddGridError = world.AddGridError;
pub const GridError = grid.GridError;

/// The static test between any two shapes.
pub const overlap = shape.overlap;
/// The swept test of a box against an axis-aligned box.
pub const sweepBox = shape.sweepBox;
/// Whether two bodies' layer/mask filters admit the pair. Symmetric.
pub const filtersAdmit = body.filtersAdmit;

test {
    _ = body;
    _ = grid;
    _ = shape;
    _ = world;
}
