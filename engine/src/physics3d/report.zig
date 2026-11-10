//! What a world holds and what it was asked (`collision-scale.md` §3).
//!
//! **A `Report` is a plain value,** as `nav.Report` is: the world fills it, a game hands it to an
//! overlay, and nothing reads it to decide anything. The counters are not simulation state. Two
//! worlds that made the same calls hold the same counters, but a determinism test compares worlds
//! by their bodies and never by these.

const std = @import("std");

/// The calls a world counts. The order is `Report.queries`' and is part of the interface.
pub const QueryKind = enum(u8) {
    ray,
    cast,
    sweep,
    overlap,
    contacts,
    /// A character's move, a pushed character's included.
    move,
};

pub const query_kinds = @typeInfo(QueryKind).@"enum".fields.len;

/// Work done since the counters were last taken. Each wraps, as a count of work may.
pub const Counters = struct {
    queries: [query_kinds]u32 = @splat(0),
    /// Steps of the search for bodies near a query: every live body under a scan, and the
    /// broadphase's nodes once it exists (§4).
    bodies_visited: u32 = 0,
    /// Bodies whose exact bounds were tested against a query's area.
    bodies_tested: u32 = 0,
    /// Narrowphase tests against a mesh's triangle.
    triangles_tested: u32 = 0,
    /// Narrowphase tests answered by a closed-form routine (§8). None until one exists.
    pairs_closed: u32 = 0,
    /// Narrowphase tests answered by GJK.
    pairs_gjk: u32 = 0,
    /// Bodies whose place in the broadphase changed (§4). None until it exists.
    refits: u32 = 0,
};

pub const Report = struct {
    bodies_static: u32 = 0,
    /// Characters' own bodies included.
    bodies_kinematic: u32 = 0,
    characters: u32 = 0,
    meshes: u32 = 0,
    /// Over every mesh, whether a body names it or not.
    triangles: u64 = 0,
    /// Meshes that arrived with their tree (§5).
    meshes_baked: u32 = 0,
    hulls: u32 = 0,
    /// Over every hull (§6). None until a hull has faces.
    hull_faces: u32 = 0,
    /// The broadphase's nodes and height (§4). Zero until it exists.
    tree_nodes: u32 = 0,
    tree_height: u32 = 0,
    /// The counters as they stood, not taken.
    queries: [query_kinds]u32 = @splat(0),
    bodies_visited: u32 = 0,
    bodies_tested: u32 = 0,
    triangles_tested: u32 = 0,
    pairs_closed: u32 = 0,
    pairs_gjk: u32 = 0,
    refits: u32 = 0,
    /// The game's own timing of a character's move, which it fills. Zero when it has none.
    move_p95_ms: f32 = 0,

    pub fn count(self: Report, kind: QueryKind) u32 {
        return self.queries[@intFromEnum(kind)];
    }

    /// Replaces the counters with ones a game took itself, a tick's or a frame's.
    pub fn withCounters(self: Report, counters: Counters) Report {
        var out = self;
        inline for (@typeInfo(Counters).@"struct".fields) |f| @field(out, f.name) = @field(counters, f.name);
        return out;
    }
};

test "a report takes a game's own counters" {
    var c: Counters = .{ .bodies_tested = 7, .pairs_gjk = 3 };
    c.queries[@intFromEnum(QueryKind.move)] = 2;
    const r = (Report{ .meshes = 1 }).withCounters(c);
    try std.testing.expectEqual(@as(u32, 1), r.meshes);
    try std.testing.expectEqual(@as(u32, 7), r.bodies_tested);
    try std.testing.expectEqual(@as(u32, 3), r.pairs_gjk);
    try std.testing.expectEqual(@as(u32, 2), r.count(.move));
}
