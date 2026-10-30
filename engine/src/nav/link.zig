//! Off-mesh links: a jump, a drop or a ladder from one polygon to another (`agents.md` §4). A
//! recipe places them by their ends, and the build attaches each end to the polygon under it.
//!
//! **A link that lands on no polygon is left out and counted, never refused:** a mod may have
//! cut the floor it stood on. A sample logs the count.

const std = @import("std");
const core = @import("core");

const features = @import("features.zig");
const poly = @import("poly.zig");

const Allocator = std.mem.Allocator;
const Vec3 = core.math.Vec3;

/// No link: a step of a path reached by walking.
pub const none_link: u32 = std.math.maxInt(u32);

pub const Link = struct {
    kind: features.LinkKind,
    two_way: bool,
    from_polygon: u32,
    to_polygon: u32,
    /// Each end on its polygon's detail surface.
    from: Vec3,
    to: Vec3,
    cost: f32,
    arc: f32,
};

/// Attaches `inputs` to `mesh`, whose detail is built, and fills its link tables.
pub fn attach(gpa: Allocator, mesh: *poly.Mesh, inputs: []const features.LinkInput) Allocator.Error!void {
    var links: std.ArrayList(Link) = try .initCapacity(gpa, inputs.len);
    errdefer links.deinit(gpa);
    for (inputs) |input| {
        const extent: Vec3 = .init(input.snap, input.snap, input.snap);
        const from = mesh.locate(input.from, extent);
        const to = mesh.locate(input.to, extent);
        if (from == null or to == null) {
            mesh.links_unattached += 1;
            continue;
        }
        links.appendAssumeCapacity(.{
            .kind = input.kind,
            .two_way = input.two_way,
            .from_polygon = from.?.polygon,
            .to_polygon = to.?.polygon,
            .from = from.?.point,
            .to = to.?.point,
            .cost = input.cost,
            .arc = input.arc,
        });
    }
    if (links.items.len == 0) {
        links.deinit(gpa);
        return;
    }

    // Counted, then filled, so each polygon's links stay in link order.
    const first = try gpa.alloc(u32, mesh.polygons.len + 1);
    errdefer gpa.free(first);
    @memset(first, 0);
    var entries: u32 = 0;
    for (links.items) |l| {
        first[l.from_polygon + 1] += 1;
        entries += 1;
        if (l.two_way and l.to_polygon != l.from_polygon) {
            first[l.to_polygon + 1] += 1;
            entries += 1;
        }
    }
    for (first[1..], first[0 .. first.len - 1]) |*count, before| count.* += before;
    const index = try gpa.alloc(u32, entries);
    errdefer gpa.free(index);
    const cursor = try gpa.dupe(u32, first);
    defer gpa.free(cursor);
    for (links.items, 0..) |l, i| {
        index[cursor[l.from_polygon]] = @intCast(i);
        cursor[l.from_polygon] += 1;
        if (l.two_way and l.to_polygon != l.from_polygon) {
            index[cursor[l.to_polygon]] = @intCast(i);
            cursor[l.to_polygon] += 1;
        }
    }
    mesh.links = try links.toOwnedSlice(gpa);
    mesh.link_first = first;
    mesh.link_index = index;
}
