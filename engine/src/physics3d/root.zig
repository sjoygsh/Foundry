//! Foundry `physics3d` — layer L1. Depends on **`core` and nothing else**.
//!
//! Collision, queries and (from M23 Step 4) a character controller; no dynamics (ADR-0051).
//! Shapes, rigid poses, static and kinematic bodies, layers and masks, raycasts, shape casts,
//! overlaps and contacts. There is no mass, no velocity, no time and no step: a caller says
//! *move this by that* and is told where it stopped.
//!
//! **No entities, no content, no I/O.** `scene` and `asset` are above this module and cannot be
//! named from it. A body carries an opaque `u64` the game fills in, and geometry arrives as
//! values the world copies (ADR-0057), so collision works with no ECS and no asset at all.
//!
//! **One narrowphase for every pair** (`collision3d.md` §5): each shape is a convex core plus a
//! radius, GJK measures the cores, conservative advancement turns distance into a cast, and EPA
//! gives depth when the cores themselves meet. Every loop has a fixed budget.
//!
//! **Determinism is interface contract** (I9): bodies are scanned in handle-index order, ties
//! go to the lower handle, iteration counts are fixed, nothing reads a clock or an address, and
//! there is no fast-math. The same calls give the same bytes on the same machine; across
//! machines agreement to the last bit is not promised (ADR-0013).
//!
//! Everything reaching this module comes from a game, and from M25 from a mod, so shapes, poses
//! and queries are **validated and refused, never asserted** (CLAUDE.md §7).
//!
//! Design: `docs/design/collision3d.md`

const std = @import("std");

pub const body = @import("body.zig");
pub const gjk = @import("gjk.zig");
pub const narrow = @import("narrow.zig");
pub const shape = @import("shape.zig");
pub const world = @import("world.zig");
pub const mesh = @import("mesh.zig");
pub const character = @import("character.zig");
pub const Character = character.Character;
pub const CharacterConfig = character.CharacterConfig;
pub const CharacterHandle = character.CharacterHandle;
pub const CharacterMove = character.CharacterMove;
pub const Ground = character.Ground;
pub const AddCharacterError = character.AddCharacterError;
pub const MoveCharacterError = character.MoveCharacterError;
pub const max_slide_iterations = character.max_slide_iterations;
pub const max_depenetration_iterations = character.max_depenetration_iterations;

// The names reached for most often. A game sees them today and a mod from M25, so renaming one
// is a compatibility decision rather than a tidy-up (CLAUDE.md §7).
pub const Aabb = shape.Aabb;
pub const Body = body.Body;
pub const BodyHandle = body.BodyHandle;
pub const BodyKind = body.BodyKind;
pub const Contact = world.Contact;
pub const Filter = body.Filter;
pub const Found = world.Found;
pub const Hit = world.Hit;
pub const HullHandle = shape.HullHandle;
pub const MeshHandle = shape.MeshHandle;
pub const Overlap = world.Overlap;
pub const Pose = shape.Pose;
pub const RayHit = world.RayHit;
pub const Shape = shape.Shape;
pub const World = world.World;

pub const AddBodyError = world.AddBodyError;
pub const AddHullError = world.AddHullError;
pub const AddMeshError = world.AddMeshError;
pub const RemoveMeshError = world.RemoveMeshError;
pub const QueryError = world.QueryError;
pub const RemoveHullError = world.RemoveHullError;
pub const SetPoseError = world.SetPoseError;
pub const SetShapeError = world.SetShapeError;

/// Interface constants: a caller can observe each (`collision3d.md` §5).
pub const contact_skin = narrow.contact_skin;
pub const max_cast_iterations = narrow.max_cast_iterations;
pub const max_gjk_iterations = gjk.max_gjk_iterations;
pub const max_epa_iterations = gjk.max_epa_iterations;
pub const max_coordinate = shape.max_coordinate;
pub const none_triangle = world.none_triangle;

pub const filtersAdmit = body.filtersAdmit;
pub const maskAdmits = body.maskAdmits;

test {
    _ = body;
    _ = gjk;
    _ = narrow;
    _ = shape;
    _ = world;
    _ = mesh;
    _ = @import("tests.zig");
    _ = @import("mesh_tests.zig");
    _ = @import("character_tests.zig");
}
