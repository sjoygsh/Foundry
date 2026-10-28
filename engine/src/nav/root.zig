//! Foundry `nav` — layer L1. Depends on **`core` and nothing else**.
//!
//! Navigation meshes built from collision triangles (ADR-0069): the surface an agent may stand
//! on, cut into convex polygons with neighbour links, built by the published voxel method —
//! rasterise, filter, erode, partition, trace, polygonise, add detail. It finds no path; M33
//! searches the graph this builds.
//!
//! **No assets, no collision world, no entities, no renderer, no clock.** `asset` decodes the
//! `foundry:nav_mesh` recipe and a game hands this module the triangles it names, as values the
//! build copies (ADR-0057's rule for `physics3d`). A test or a tool builds a mesh with no
//! package at all.
//!
//! **Everything reaching this module comes from content**, and from M48 from a mod, so inputs
//! are **validated and refused, never asserted** (CLAUDE.md §7), before anything is allocated.
//!
//! **Determinism is interface contract** (I9): stages run in a fixed order, ties go to the lower
//! index, and nothing reads a clock or an address. The same inputs give the same bytes on the
//! same machine; across machines the last bit is not promised (ADR-0013).
//!
//! Design: `docs/design/navigation.md`

pub const config = @import("config.zig");
pub const input = @import("input.zig");

// A game sees these today and a mod from M48, so renaming one is a compatibility decision
// rather than a tidy-up (CLAUDE.md §7).
pub const Config = config.Config;
pub const Grid = input.Grid;
pub const InputError = input.InputError;
pub const Pose = input.Pose;
pub const Source = input.Source;

pub const max_cells_high = input.max_cells_high;
pub const max_columns = input.max_columns;
pub const max_coordinate = input.max_coordinate;
pub const max_polygon_vertices = config.max_polygon_vertices;
pub const max_positions = input.max_positions;
pub const max_sources = input.max_sources;
pub const max_triangles = input.max_triangles;

pub const measure = input.measure;

test {
    _ = config;
    _ = input;
}
