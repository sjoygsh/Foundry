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
pub const features = @import("features.zig");
pub const funnel = @import("funnel.zig");
pub const heightfield = @import("heightfield.zig");
pub const open = @import("open.zig");
pub const regions = @import("regions.zig");
pub const search = @import("search.zig");
pub const surface = @import("surface.zig");
pub const avoidance = @import("avoidance.zig");
pub const contour = @import("contour.zig");
pub const crossing = @import("crossing.zig");
pub const crowd = @import("crowd.zig");
pub const poly = @import("poly.zig");
pub const detail = @import("detail.zig");
pub const link = @import("link.zig");
pub const locate = @import("locate.zig");
pub const task = @import("task.zig");
pub const view = @import("view.zig");

// A game sees these today and a mod from M48, so renaming one is a compatibility decision
// rather than a tidy-up (CLAUDE.md §7).
pub const AgentHandle = crowd.AgentHandle;
pub const AgentParams = crowd.AgentParams;
pub const AgentState = crowd.AgentState;
pub const AgentView = crowd.AgentView;
pub const Config = config.Config;
pub const Corner = funnel.Corner;
pub const Crowd = crowd.Crowd;
pub const Features = features.Features;
pub const Filter = search.Filter;
pub const Link = link.Link;
pub const LinkInput = features.LinkInput;
pub const LinkKind = features.LinkKind;
pub const Volume = features.Volume;
pub const Grid = input.Grid;
pub const Heightfield = heightfield.Heightfield;
pub const OpenField = open.OpenField;
pub const Mesh = poly.Mesh;
pub const Path = search.Path;
pub const Polygon = poly.Polygon;
pub const Query = search.Query;
pub const Step = search.Step;
pub const Wish = crowd.Wish;
pub const Build = task.Build;
pub const BuildError = poly.BuildError;
pub const Detail = detail.Detail;
pub const Located = locate.Located;
pub const ViewVertex = view.ViewVertex;
pub const none_link = link.none_link;
pub const none_polygon = poly.none_polygon;
pub const InputError = input.InputError;
pub const Pose = input.Pose;
pub const Source = input.Source;

pub const max_cells_high = input.max_cells_high;
pub const max_columns = input.max_columns;
pub const max_coordinate = input.max_coordinate;
pub const max_areas = features.max_areas;
pub const max_links = features.max_links;
pub const max_polygon_vertices = config.max_polygon_vertices;
pub const max_positions = input.max_positions;
pub const max_sources = input.max_sources;
pub const max_spans = heightfield.max_spans;
pub const max_triangles = input.max_triangles;
pub const max_volumes = features.max_volumes;

pub const measure = input.measure;
pub const solid = heightfield.solid;
pub const build = poly.build;
pub const buildWith = poly.buildWith;
pub const buildPolygons = poly.buildPolygons;
pub const corners = funnel.corners;
pub const debugView = view.debugView;
pub const debugViewCount = view.debugViewCount;

test {
    _ = config;
    _ = features;
    _ = input;
    _ = heightfield;
    _ = open;
    _ = regions;
    _ = contour;
    _ = poly;
    _ = @import("poly_tests.zig");
    _ = detail;
    _ = locate;
    _ = task;
    _ = view;
    _ = @import("build_tests.zig");
    _ = link;
    _ = @import("features_tests.zig");
    _ = search;
    _ = funnel;
    _ = @import("search_tests.zig");
    _ = avoidance;
    _ = @import("avoidance_tests.zig");
    _ = surface;
    _ = crossing;
    _ = crowd;
    _ = @import("crowd_tests.zig");
}
