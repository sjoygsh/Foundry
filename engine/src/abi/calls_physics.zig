//! `physics2d` as the public ABI publishes it.
//!
//! The collision world stays below the ABI and receives only validated native values. A host
//! lends it to this module together with the allocator that owns the world's storage. Query
//! results are copied into a mod-owned buffer after the world call succeeds; no internal
//! broadphase or scratch container crosses the boundary.
//!
//! Design: `docs/design/public-abi.md` §9 and `docs/design/tilemaps-and-collision.md` §12.

const std = @import("std");
const core = @import("core");
const physics2d = @import("physics2d");

const types = @import("types.zig");
const wire = @import("physics_types.zig");

const Body = types.Body;
const Result = types.Result;
const log = core.log.scoped(.abi);

/// A per-call bound on memory a mod can make the host use for result conversion. The world
/// still owns and bounds its own broadphase/cast scratch. A caller that needs more results can
/// make several spatially smaller queries; accepting an unbounded capacity here would turn a
/// caller-controlled integer into an allocator request before the engine could answer it.
pub const max_hits: u32 = 4096;

const QueryKind = enum { point, shape };

fn finite(value: f32) bool {
    return std.math.isFinite(value);
}

fn finiteVec(value: wire.Vec2) bool {
    return finite(value.x) and finite(value.y);
}

fn validOutput(comptime T: type, output: ?[*]T, capacity: u32) Result {
    if (capacity > max_hits) return .limit;
    if (capacity != 0 and output == null) return .invalid_argument;
    return .ok;
}

fn toVec(value: wire.Vec2) core.math.Vec2 {
    return .{ .x = value.x, .y = value.y };
}

fn toShape(value: wire.Shape) ?physics2d.Shape {
    return switch (value.kind) {
        0 => if (finite(value.x) and finite(value.y) and value.x > 0 and value.y > 0)
            .{ .box = .{ .x = value.x, .y = value.y } }
        else
            null,
        1 => if (finite(value.x) and value.x > 0 and value.y == 0)
            .{ .circle = value.x }
        else
            null,
        else => null,
    };
}

fn toKind(value: i32) ?physics2d.BodyKind {
    return switch (value) {
        0 => .static,
        1 => .movable,
        2 => .trigger,
        else => null,
    };
}

fn toBody(value: wire.BodyDesc) ?physics2d.Body {
    const shape = toShape(value.shape) orelse return null;
    const kind = toKind(value.kind) orelse return null;
    if (!finiteVec(value.position)) return null;
    return .{
        .shape = shape,
        .position = toVec(value.position),
        .kind = kind,
        .layer = value.layer,
        .mask = value.mask,
        .user = value.user,
    };
}

fn copyHit(destination: *wire.Hit, source: physics2d.Hit) void {
    destination.* = .{
        .body = if (source.body.isNone()) .none else .wrap(source.body),
        .grid = if (source.grid.isNone()) .none else .wrap(source.grid),
        .cell_x = source.cell[0],
        .cell_y = source.cell[1],
        .normal = .{ .x = source.normal.x, .y = source.normal.y },
        .fraction = source.fraction,
        .user = source.user,
    };
}

fn copyQueryHit(destination: *wire.QueryHit, source: physics2d.QueryHit) void {
    destination.* = .{
        .body = if (source.body.isNone()) .none else .wrap(source.body),
        .grid = if (source.grid.isNone()) .none else .wrap(source.grid),
        .cell_x = source.cell[0],
        .cell_y = source.cell[1],
        .user = source.user,
    };
}

fn moveFailure(err: anyerror) Result {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        else => internalFailure(err),
    };
}

fn internalFailure(err: anyerror) Result {
    // The C result vocabulary has no room for every engine error. Keep the underlying name in
    // the host log at warn level: an `err` line makes Zig's test runner fail, while silently
    // turning a collision failure into INTERNAL leaves a mod author no diagnosis.
    log.warn("unmapped physics ABI error: {s}", .{@errorName(err)});
    return .internal;
}

fn runOverlap(
    world: *physics2d.World,
    gpa: std.mem.Allocator,
    kind: QueryKind,
    shape: ?physics2d.Shape,
    at: wire.Vec2,
    mask: u32,
    hits: ?[*]wire.QueryHit,
    capacity: u32,
    written: *u32,
    all: *u32,
) Result {
    const inner_hits = if (capacity == 0)
        @as(?[]physics2d.QueryHit, null)
    else
        gpa.alloc(physics2d.QueryHit, capacity) catch return .out_of_memory;
    defer if (inner_hits) |allocated| gpa.free(allocated);

    const answer = if (kind == .point)
        world.overlapPoint(gpa, toVec(at), mask, if (inner_hits) |allocated| allocated else &.{})
    else
        world.overlapShape(gpa, shape.?, toVec(at), mask, if (inner_hits) |allocated| allocated else &.{});
    const result = answer catch |err| return moveFailure(err);
    if (inner_hits) |allocated| {
        for (allocated[0..result.count], 0..) |hit, i| copyQueryHit(&hits.?[i], hit);
    }
    written.* = result.count;
    all.* = result.total;
    return .ok;
}

pub fn Of(comptime H: type) type {
    return struct {
        /// Creates one body and copies the descriptor before returning. The world owns the
        /// body; the descriptor and every value it contains may be stack storage in the mod.
        pub fn physicsCreateBody(desc: ?*const wire.BodyDesc, out: ?*Body) callconv(.c) Result {
            const supplied = desc orelse return .invalid_argument;
            const destination = out orelse return .invalid_argument;

            const h = H.current() orelse return .unavailable;
            const world = h.collision orelse return .unavailable;
            const gpa = h.collision_allocator orelse return .unavailable;
            const body = toBody(supplied.*) orelse return .invalid_argument;
            const handle = world.addBody(gpa, body) catch |err| return switch (err) {
                error.InvalidShape => .invalid_argument,
                error.OutOfMemory => .out_of_memory,
            };
            destination.* = .wrap(handle);
            return .ok;
        }

        pub fn physicsDestroyBody(handle: Body) callconv(.c) Result {
            const h = H.current() orelse return .unavailable;
            const world = h.collision orelse return .unavailable;
            const gpa = h.collision_allocator orelse return .unavailable;
            if (handle.isNone()) return .invalid_handle;
            const inner = handle.unwrap(physics2d.BodyHandle);
            if (world.body(inner) == null) return .invalid_handle;
            if (!world.removeBody(gpa, inner)) return .invalid_handle;
            return .ok;
        }

        /// Moves a body through the collision world and converts its contacts into the
        /// caller's buffer. The move result and hits are left untouched on every refusal.
        pub fn physicsMoveBody(
            handle: Body,
            motion: wire.Vec2,
            hits: ?[*]wire.Hit,
            capacity: u32,
            out: ?*wire.MoveResult,
        ) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const world = h.collision orelse return .unavailable;
            const gpa = h.collision_allocator orelse return .unavailable;
            const output_status = validOutput(wire.Hit, hits, capacity);
            if (output_status != .ok) return output_status;
            if (!finiteVec(motion)) return .invalid_argument;
            if (handle.isNone()) return .invalid_handle;

            const inner_hits = if (capacity == 0)
                @as(?[]physics2d.Hit, null)
            else
                gpa.alloc(physics2d.Hit, capacity) catch return .out_of_memory;
            defer if (inner_hits) |allocated| gpa.free(allocated);

            const moved = world.moveAndSlide(
                gpa,
                handle.unwrap(physics2d.BodyHandle),
                toVec(motion),
                if (inner_hits) |allocated| allocated else &.{},
            ) catch |err| return moveFailure(err);
            const answer = moved orelse return .invalid_handle;

            if (inner_hits) |allocated| {
                for (allocated[0..answer.hit_count], 0..) |hit, i| copyHit(&hits.?[i], hit);
            }
            destination.* = .{
                .position = .{ .x = answer.position.x, .y = answer.position.y },
                .hit_count = answer.hit_count,
                .total_hits = answer.total_hits,
                .started_inside = types.boolOut(answer.started_inside),
            };
            return .ok;
        }

        pub fn physicsQueryPoint(
            point: wire.Vec2,
            mask: u32,
            hits: ?[*]wire.QueryHit,
            capacity: u32,
            count: ?*u32,
            total: ?*u32,
        ) callconv(.c) Result {
            return queryOverlap(.point, null, point, mask, hits, capacity, count, total);
        }

        pub fn physicsQueryAabb(
            min: wire.Vec2,
            max: wire.Vec2,
            mask: u32,
            hits: ?[*]wire.QueryHit,
            capacity: u32,
            count: ?*u32,
            total: ?*u32,
        ) callconv(.c) Result {
            const written = count orelse return .invalid_argument;
            const all = total orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const world = h.collision orelse return .unavailable;
            const gpa = h.collision_allocator orelse return .unavailable;
            const output_status = validOutput(wire.QueryHit, hits, capacity);
            if (output_status != .ok) return output_status;
            if (!finiteVec(min) or !finiteVec(max) or !(max.x > min.x) or !(max.y > min.y)) {
                return .invalid_argument;
            }
            const centre: wire.Vec2 = .{ .x = (min.x + max.x) * 0.5, .y = (min.y + max.y) * 0.5 };
            const half: wire.Vec2 = .{ .x = (max.x - min.x) * 0.5, .y = (max.y - min.y) * 0.5 };
            if (!finiteVec(centre) or !finiteVec(half)) return .invalid_argument;
            return runOverlap(world, gpa, .shape, .{ .box = toVec(half) }, centre, mask, hits, capacity, written, all);
        }

        pub fn physicsQueryRay(
            from: wire.Vec2,
            to: wire.Vec2,
            mask: u32,
            hits: ?[*]wire.Hit,
            capacity: u32,
            count: ?*u32,
            total: ?*u32,
        ) callconv(.c) Result {
            const written = count orelse return .invalid_argument;
            const all = total orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const world = h.collision orelse return .unavailable;
            const gpa = h.collision_allocator orelse return .unavailable;
            const output_status = validOutput(wire.Hit, hits, capacity);
            if (output_status != .ok) return output_status;
            if (!finiteVec(from) or !finiteVec(to)) return .invalid_argument;
            const inner_hits = if (capacity == 0)
                @as(?[]physics2d.Hit, null)
            else
                gpa.alloc(physics2d.Hit, capacity) catch return .out_of_memory;
            defer if (inner_hits) |allocated| gpa.free(allocated);

            const answer = world.raycast(
                gpa,
                toVec(from),
                toVec(to),
                mask,
                if (inner_hits) |allocated| allocated else &.{},
            ) catch |err| return moveFailure(err);
            if (inner_hits) |allocated| {
                for (allocated[0..answer.count], 0..) |hit, i| copyHit(&hits.?[i], hit);
            }
            written.* = answer.count;
            all.* = answer.total;
            return .ok;
        }

        /// Reports the shape's current overlaps. `World.overlapShape` is intentionally used
        /// rather than exposing broadphase internals; it includes triggers, as all overlap
        /// queries do. The body itself is removed from the result before it is returned.
        pub fn physicsBodyContacts(
            handle: Body,
            hits: ?[*]wire.QueryHit,
            capacity: u32,
            count: ?*u32,
            total: ?*u32,
        ) callconv(.c) Result {
            const written = count orelse return .invalid_argument;
            const all = total orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const world = h.collision orelse return .unavailable;
            const gpa = h.collision_allocator orelse return .unavailable;
            const output_status = validOutput(wire.QueryHit, hits, capacity);
            if (output_status != .ok) return output_status;
            if (handle.isNone()) return .invalid_handle;
            const inner_body = handle.unwrap(physics2d.BodyHandle);
            const body = world.body(inner_body) orelse return .invalid_handle;

            // A body overlaps itself, and the public meaning of "contacts" excludes that
            // self-pair. Keep one extra scratch entry beyond the caller's capacity so the
            // self hit never consumes the only slot the caller asked to receive. A counting
            // query needs no conversion buffer at all; its self subtraction is derived from
            // the query mask below rather than from a truncated output buffer.
            // `validOutput` bounded capacity before this calculation, so saturating addition is
            // safe and exact here while still leaving the caller's capacity capped at max_hits.
            const scratch_capacity = capacity +| 1;
            const scratch = if (capacity == 0)
                @as(?[]physics2d.QueryHit, null)
            else
                gpa.alloc(physics2d.QueryHit, scratch_capacity) catch return .out_of_memory;
            defer if (scratch) |allocated| gpa.free(allocated);
            const answer = world.overlapShape(
                gpa,
                body.shape,
                body.position,
                body.mask,
                if (scratch) |allocated| allocated else &.{},
            ) catch |err| {
                return moveFailure(err);
            };

            var output_count: u32 = 0;
            if (scratch) |allocated| {
                const available = @min(answer.count, scratch_capacity);
                for (allocated[0..available]) |hit| {
                    if (!hit.body.isNone() and hit.body.eql(inner_body)) {
                        continue;
                    }
                    if (output_count < capacity) {
                        copyQueryHit(&hits.?[output_count], hit);
                        output_count += 1;
                    }
                }
            }
            // `overlapShape` uses the query mask as a one-sided filter, so the body is present
            // exactly when its own layer passes its own mask. This remains correct for a
            // zero-capacity counting query, where no scratch hit exists to inspect, and keeps
            // the subtraction independent of truncation.
            const self_included: u32 = if (body.mask & body.layer != 0) 1 else 0;
            const actual_total = answer.total -| self_included;
            written.* = @min(output_count, capacity);
            all.* = actual_total;
            return .ok;
        }

        fn queryOverlap(
            kind: QueryKind,
            shape: ?physics2d.Shape,
            at: wire.Vec2,
            mask: u32,
            hits: ?[*]wire.QueryHit,
            capacity: u32,
            count: ?*u32,
            total: ?*u32,
        ) Result {
            const written = count orelse return .invalid_argument;
            const all = total orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const world = h.collision orelse return .unavailable;
            const gpa = h.collision_allocator orelse return .unavailable;
            const output_status = validOutput(wire.QueryHit, hits, capacity);
            if (output_status != .ok) return output_status;
            if (!finiteVec(at)) return .invalid_argument;
            return runOverlap(world, gpa, kind, shape, at, mask, hits, capacity, written, all);
        }
    };
}

comptime {
    _ = std;
}

test "physics ABI creates, queries, and refuses a stale body" {
    const testing = std.testing;
    const host_mod = @import("host.zig");
    const test_engine = @import("test_engine.zig");
    const audio = @import("audio");

    const Host = host_mod.HostWithMixer(test_engine.TestEngine, audio.Mixer);
    const Calls = Of(Host);

    var world = physics2d.World.init(.{});
    defer world.deinit(testing.allocator);

    var host: Host = .{
        .collision = &world,
        .collision_allocator = testing.allocator,
    };
    host.bind();
    defer host.unbind();

    const desc: wire.BodyDesc = .{
        .shape = .{ .kind = 0, .x = 2, .y = 2 },
        .position = .{ .x = 4, .y = 5 },
        .kind = 0,
        .layer = 1,
        .mask = ~@as(u32, 0),
        .user = 0xfeed,
    };
    var body: Body = .none;
    try testing.expectEqual(Result.ok, Calls.physicsCreateBody(&desc, &body));
    try testing.expect(!body.isNone());

    var hits = [_]wire.QueryHit{.{}};
    var count: u32 = 99;
    var total: u32 = 99;
    try testing.expectEqual(
        Result.ok,
        Calls.physicsQueryPoint(.{ .x = 4, .y = 5 }, ~@as(u32, 0), &hits, 1, &count, &total),
    );
    try testing.expectEqual(@as(u32, 1), count);
    try testing.expectEqual(@as(u32, 1), total);
    try testing.expect(hits[0].body.eql(body));
    try testing.expectEqual(@as(u64, 0xfeed), hits[0].user);

    try testing.expectEqual(Result.ok, Calls.physicsDestroyBody(body));
    // The same bits must not address a slot after destruction.
    try testing.expectEqual(Result.invalid_handle, Calls.physicsDestroyBody(body));
    var move_hits = [_]wire.Hit{.{}};
    var move_result: wire.MoveResult = .{};
    try testing.expectEqual(Result.invalid_handle, Calls.physicsMoveBody(
        body,
        .{ .x = 1, .y = 0 },
        &move_hits,
        1,
        &move_result,
    ));
}

test "physics ABI preserves outputs when validation or scratch allocation refuses" {
    const testing = std.testing;
    const host_mod = @import("host.zig");
    const test_engine = @import("test_engine.zig");
    const audio = @import("audio");

    const Host = host_mod.HostWithMixer(test_engine.TestEngine, audio.Mixer);
    const Calls = Of(Host);
    var world = physics2d.World.init(.{});
    defer world.deinit(testing.allocator);
    var host: Host = .{ .collision = &world, .collision_allocator = testing.allocator };
    host.bind();
    defer host.unbind();

    const desc: wire.BodyDesc = .{ .shape = .{ .kind = 0, .x = 1, .y = 1 } };
    var body: Body = .{ .bits = 0x1234 };
    try testing.expectEqual(Result.invalid_argument, Calls.physicsCreateBody(
        &wire.BodyDesc{ .shape = .{ .kind = 0, .x = 0, .y = 1 } },
        &body,
    ));
    try testing.expectEqual(@as(u64, 0x1234), body.bits);
    try testing.expectEqual(Result.ok, Calls.physicsCreateBody(&desc, &body));

    var hits = [_]wire.QueryHit{.{ .user = 7 }};
    var count: u32 = 41;
    var total: u32 = 42;
    try testing.expectEqual(Result.invalid_argument, Calls.physicsQueryPoint(
        .{ .x = std.math.nan(f32), .y = 0 },
        ~@as(u32, 0),
        &hits,
        1,
        &count,
        &total,
    ));
    try testing.expectEqual(@as(u32, 41), count);
    try testing.expectEqual(@as(u32, 42), total);
    try testing.expectEqual(@as(u64, 7), hits[0].user);

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    host.collision_allocator = failing.allocator();
    count = 51;
    total = 52;
    try testing.expectEqual(Result.out_of_memory, Calls.physicsQueryPoint(
        .{ .x = 0, .y = 0 },
        ~@as(u32, 0),
        &hits,
        1,
        &count,
        &total,
    ));
    try testing.expectEqual(@as(u32, 51), count);
    try testing.expectEqual(@as(u32, 52), total);
}

test "physics ABI contacts keep hits when the body's own filter excludes itself" {
    const testing = std.testing;
    const host_mod = @import("host.zig");
    const test_engine = @import("test_engine.zig");
    const audio = @import("audio");

    const Host = host_mod.HostWithMixer(test_engine.TestEngine, audio.Mixer);
    const Calls = Of(Host);
    var world = physics2d.World.init(.{});
    defer world.deinit(testing.allocator);
    var host: Host = .{ .collision = &world, .collision_allocator = testing.allocator };
    host.bind();
    defer host.unbind();

    // The subject cannot overlap itself (layer 1 is absent from its mask), but it can
    // overlap the second body (layer 2), which is the case that catches unconditional
    // `total - 1` accounting.
    const subject: wire.BodyDesc = .{
        .shape = .{ .kind = 0, .x = 2, .y = 2 },
        .position = .{ .x = 0, .y = 0 },
        .kind = 0,
        .layer = 1,
        .mask = 2,
    };
    const other: wire.BodyDesc = .{
        .shape = .{ .kind = 0, .x = 2, .y = 2 },
        .position = .{ .x = 1, .y = 0 },
        .kind = 0,
        .layer = 2,
        .mask = 1,
        .user = 99,
    };
    var subject_handle: Body = .none;
    var other_handle: Body = .none;
    try testing.expectEqual(Result.ok, Calls.physicsCreateBody(&subject, &subject_handle));
    try testing.expectEqual(Result.ok, Calls.physicsCreateBody(&other, &other_handle));

    var hits = [_]wire.QueryHit{.{}};
    var count: u32 = 0;
    var total: u32 = 0;
    try testing.expectEqual(Result.ok, Calls.physicsBodyContacts(
        subject_handle,
        &hits,
        1,
        &count,
        &total,
    ));
    try testing.expectEqual(@as(u32, 1), count);
    try testing.expectEqual(@as(u32, 1), total);
    try testing.expect(hits[0].body.eql(other_handle));

    // A zero-capacity query is still required to report the exact contact count. The
    // subject below passes its own one-sided mask, but has no other body nearby; relying on
    // the truncated scratch buffer would miss that self hit and return one.
    const self_only: wire.BodyDesc = .{
        .shape = .{ .kind = 0, .x = 1, .y = 1 },
        .position = .{ .x = 100, .y = 100 },
        .kind = 0,
        .layer = 4,
        .mask = 4,
    };
    var self_only_handle: Body = .none;
    try testing.expectEqual(Result.ok, Calls.physicsCreateBody(&self_only, &self_only_handle));
    var count_only: u32 = 7;
    var total_only: u32 = 7;
    try testing.expectEqual(Result.ok, Calls.physicsBodyContacts(
        self_only_handle,
        null,
        0,
        &count_only,
        &total_only,
    ));
    try testing.expectEqual(@as(u32, 0), count_only);
    try testing.expectEqual(@as(u32, 0), total_only);
}

test "physics ABI contacts fill max capacity after skipping the self hit" {
    const testing = std.testing;
    const host_mod = @import("host.zig");
    const test_engine = @import("test_engine.zig");
    const audio = @import("audio");

    const Host = host_mod.HostWithMixer(test_engine.TestEngine, audio.Mixer);
    const Calls = Of(Host);
    var world = physics2d.World.init(.{});
    defer world.deinit(testing.allocator);
    var host: Host = .{ .collision = &world, .collision_allocator = testing.allocator };
    host.bind();
    defer host.unbind();

    // Grid cells are reported before bodies. A one-row grid with max_hits - 1 overlapping
    // cells therefore leaves exactly one slot for the subject's self hit in the old
    // cap-at-max_hits scratch buffer; the other body would be dropped before self filtering.
    const tile_count: u32 = max_hits - 1;
    var tiles: [max_hits - 1]u16 = undefined;
    @memset(&tiles, 1);
    const solid = [_]u32{0b10};
    _ = try world.addGrid(testing.allocator, .{
        .origin = .zero,
        .cell = .one,
        .width = tile_count,
        .height = 1,
        .tiles = &tiles,
        .solid = &solid,
    });

    const half_width: f32 = @as(f32, @floatFromInt(tile_count)) * 0.5;
    const subject_desc: wire.BodyDesc = .{
        .shape = .{ .kind = 0, .x = half_width, .y = 0.5 },
        .position = .{ .x = half_width, .y = 0.5 },
        .kind = 0,
        .layer = 1,
        .mask = ~@as(u32, 0),
    };
    const other_desc: wire.BodyDesc = .{
        .shape = .{ .kind = 0, .x = 0.5, .y = 0.5 },
        .position = .{ .x = half_width, .y = 0.5 },
        .kind = 0,
        .layer = 1,
        .mask = ~@as(u32, 0),
        .user = 99,
    };
    var subject: Body = .none;
    var other: Body = .none;
    try testing.expectEqual(Result.ok, Calls.physicsCreateBody(&subject_desc, &subject));
    try testing.expectEqual(Result.ok, Calls.physicsCreateBody(&other_desc, &other));

    var hits: [max_hits]wire.QueryHit = undefined;
    var count: u32 = 0;
    var total: u32 = 0;
    try testing.expectEqual(Result.ok, Calls.physicsBodyContacts(
        subject,
        &hits,
        max_hits,
        &count,
        &total,
    ));
    try testing.expectEqual(max_hits, count);
    try testing.expectEqual(max_hits, total);
    try testing.expect(hits[max_hits - 1].body.eql(other));
    try testing.expectEqual(@as(u64, 99), hits[max_hits - 1].user);
}
