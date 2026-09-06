//! An animation saved mid-clip, reloaded, and drawing the same pixels it was drawing.
//!
//! `sprite-animation.md` §10 step 3 asks for exactly this, and says why: §4 refuses a float
//! accumulator on three grounds and the deciding one is that a reload lands on a value that
//! is *nearly* the same and selects a frame that is sometimes not. That is an assertion
//! about the whole chain rather than about any one function, so this is where it can be
//! held rather than asserted.
//!
//! It also stands where a game stands, which is the other reason it is here. `scene` and
//! `render2d` are both L3 with no dependency between them (I7): the entity side holds a
//! clip id, a tick count and a frame index and has never heard of a texture; the renderer
//! side turns a grid position into a region and has never heard of an entity. Neither can
//! reach the other's tests. Composing them is a consumer's job, and this file is that
//! consumer — the same `cellOf` the sandbox writes, with the disk left out.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const render2d = @import("render2d");
const scene = @import("scene");

const testing = std.testing;
const Allocator = std.mem.Allocator;

// -- what the game defines ----------------------------------------------------------

/// A clip, as the game holds it after reading a content record.
///
/// Plain numbers and no identity of its own beyond the id, because that is all `frameAt`
/// wants and all a component can carry across a save.
const Clip = struct {
    id: core.ContentId,
    columns: u32,
    rows: u32,
    first: u32,
    count: u32,
    hold: u32,
    loops: bool,

    fn duration(self: *const Clip) u64 {
        return @as(u64, self.hold) * @as(u64, self.count);
    }
};

/// Where an entity is in a clip. Three integers, which is the whole of §4's argument.
const Animation = struct {
    pub const component = "demo:animation";
    /// By content id, never by handle or by index into the table below: this is
    /// serialized, and a runtime identity in a save is what I1 and ADR-0021 refuse.
    clip: core.ContentId = .none,
    elapsed_ticks: u32 = 0,
    frame: u32 = 0,
};

/// Present so the world holds something the animation does *not* drive, which is what
/// makes "the reload changed nothing" mean more than one component round-tripping.
const Visual = struct {
    pub const component = "demo:visual";
    cell: u32 = 0,
};

/// Two clips of different lengths, so nothing here can pass by every entity happening to
/// share a period.
const clips = [_]Clip{
    .{
        .id = core.ContentId.fromString("demo:clip.walk"),
        .columns = 4,
        .rows = 4,
        .first = 4,
        .count = 4,
        .hold = 6,
        .loops = true,
    },
    .{
        .id = core.ContentId.fromString("demo:clip.flourish"),
        .columns = 4,
        .rows = 4,
        .first = 0,
        .count = 7,
        .hold = 5,
        .loops = true,
    },
    .{
        .id = core.ContentId.fromString("demo:clip.oneshot"),
        .columns = 4,
        .rows = 4,
        .first = 8,
        .count = 3,
        .hold = 9,
        .loops = false,
    },
};

fn clipOf(id: core.ContentId) ?*const Clip {
    for (&clips) |*clip| if (clip.id.eql(id)) return clip;
    return null;
}

/// The sandbox's animation system, with the clip table compiled in rather than read.
///
/// A looping clip wraps its own elapsed count by the clip's duration, which keeps the
/// saved number small and lets the thing run forever; a one-shot saturates, because
/// wrapping it would replay it.
fn animationSystem(_: ?*anyopaque, world: *scene.World, tick: scene.Tick) void {
    _ = tick;
    var it = world.queryOf(.{Animation});
    while (it.next()) |m| {
        const animation = m.get(Animation);
        const clip = clipOf(animation.clip) orelse continue;

        const total = clip.duration();
        animation.elapsed_ticks = if (clip.loops and total > 0)
            @intCast((@as(u64, animation.elapsed_ticks) + 1) % total)
        else
            animation.elapsed_ticks +| 1;

        animation.frame = render2d.frameAt(
            animation.elapsed_ticks,
            clip.hold,
            clip.count,
            clip.loops,
        );
    }
}

/// The join, which is the same three lines the sandbox's `cellOf` is.
///
/// A 64-pixel sheet as a bare region: no texture, no device, no renderer. `Region.cell` is
/// arithmetic over a rectangle, so the whole of the drawing side is reachable headlessly —
/// which is the same reason the null RHI backend exists.
fn regionFor(from: render2d.Region, animation: Animation, visual: Visual) render2d.Region {
    if (clipOf(animation.clip)) |clip| {
        return from.cell(clip.columns, clip.rows, clip.first +| animation.frame);
    }
    return from.cell(4, 4, visual.cell);
}

const sheet: render2d.Region = .whole(.none, .{ .width = 64, .height = 64 });

// -- the world ----------------------------------------------------------------------

const Game = struct {
    gpa: Allocator,
    schemas: data.Registry,
    world: scene.World,
    animation: scene.ComponentType = .none,
    visual: scene.ComponentType = .none,

    fn init(gpa: Allocator) !*Game {
        const self = try gpa.create(Game);
        self.* = .{ .gpa = gpa, .schemas = .init(gpa, .default), .world = undefined };
        self.world = .init(gpa, &self.schemas, .default);
        self.animation = try self.world.registerComponent(scene.componentType(Animation));
        self.visual = try self.world.registerComponent(scene.componentType(Visual));
        _ = try self.world.registerSystem(.{
            .id = try data.contentId("demo:system.animation"),
            .name = "demo:system.animation",
            .update = &animationSystem,
        });
        return self;
    }

    fn deinit(self: *Game) void {
        self.world.deinit();
        self.schemas.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn spawn(self: *Game, clip: core.ContentId, start: u32, cell: u32) !scene.Entity {
        const entity = try self.world.create();
        var animation: Animation = .{ .clip = clip, .elapsed_ticks = start };
        var visual: Visual = .{ .cell = cell };
        _ = try self.world.addComponent(entity, self.animation, std.mem.asBytes(&animation));
        _ = try self.world.addComponent(entity, self.visual, std.mem.asBytes(&visual));
        return entity;
    }

    fn run(self: *Game, from: u64, ticks: u64) void {
        var tick = from;
        while (tick < from + ticks) : (tick += 1) {
            self.world.update(.{ .tick = tick, .delta = core.time.Duration.fromNanos(16_666_667) });
        }
    }

    /// What every animated entity is showing, in query order — which is dense order, and
    /// which is what a reload has to preserve for these to be comparable at all.
    fn showing(self: *Game, gpa: Allocator) ![]Shown {
        var out: std.ArrayList(Shown) = .empty;
        errdefer out.deinit(gpa);
        var it = self.world.queryOf(.{ Animation, Visual });
        while (it.next()) |m| {
            const animation = m.get(Animation).*;
            const visual = m.get(Visual).*;
            try out.append(gpa, .{
                .animation = animation,
                .region = regionFor(sheet, animation, visual),
            });
        }
        return out.toOwnedSlice(gpa);
    }
};

const Shown = struct {
    animation: Animation,
    region: render2d.Region,
};

fn expectSameFrames(a: []const Shown, b: []const Shown) !void {
    try testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| {
        try testing.expect(x.animation.clip.eql(y.animation.clip));
        try testing.expectEqual(x.animation.elapsed_ticks, y.animation.elapsed_ticks);
        try testing.expectEqual(x.animation.frame, y.animation.frame);
        // **Bit-exact, and that is the whole point.** These are the UVs a draw call would
        // carry. An epsilon here would pass for a float accumulator too, which is the
        // comparison §4 says is right in nineteen tests out of twenty.
        try testing.expectEqual(x.region.uv.x, y.region.uv.x);
        try testing.expectEqual(x.region.uv.y, y.region.uv.y);
        try testing.expectEqual(x.region.uv.w, y.region.uv.w);
        try testing.expectEqual(x.region.uv.h, y.region.uv.h);
        try testing.expectEqual(x.region.size_px.width, y.region.size_px.width);
    }
}

// -- the check step 3 exists for ----------------------------------------------------

test "an animation saved mid-clip reloads onto the frame it was drawing" {
    const gpa = testing.allocator;

    const first = try Game.init(gpa);
    defer first.deinit();

    // Three phases, three clips, two periods and a one-shot — so nothing passes because
    // every entity happens to be at the same place in the same cycle.
    _ = try first.spawn(core.ContentId.fromString("demo:clip.walk"), 0, 1);
    _ = try first.spawn(core.ContentId.fromString("demo:clip.flourish"), 13, 2);
    _ = try first.spawn(core.ContentId.fromString("demo:clip.oneshot"), 0, 3);
    // One that animates nothing, to prove the fallback survives the trip as well.
    _ = try first.spawn(.none, 0, 11);

    // A number that is not a multiple of any clip's period, so every entity is stopped
    // partway through a frame rather than tidily on a boundary.
    first.run(0, 137);

    const before = try first.showing(gpa);
    defer gpa.free(before);

    var saved: std.ArrayList(u8) = .empty;
    defer saved.deinit(gpa);
    try first.world.save(&saved);

    // A second world, built the way a restart builds one: fresh registry, fresh world,
    // the same component types, and nothing in it until the save is read.
    const second = try Game.init(gpa);
    defer second.deinit();
    _ = try second.world.load(saved.items, .default);

    const after = try second.showing(gpa);
    defer gpa.free(after);

    // The claim: the reloaded world is drawing the same cells of the same sheet.
    try expectSameFrames(before, after);

    // And it carries on the same rather than merely starting the same. A save that
    // restored the frame but lost the elapsed count would pass the line above and fail
    // here on the very next tick — which is exactly the failure a float accumulator has.
    first.run(137, 400);
    second.run(137, 400);

    const first_later = try first.showing(gpa);
    defer gpa.free(first_later);
    const second_later = try second.showing(gpa);
    defer gpa.free(second_later);
    try expectSameFrames(first_later, second_later);

    // Not vacuous: the field moved between the two comparisons.
    try testing.expect(before[0].animation.elapsed_ticks != first_later[0].animation.elapsed_ticks);
}

test "a clip is still in phase after a hundred thousand ticks" {
    const gpa = testing.allocator;

    const game = try Game.init(gpa);
    defer game.deinit();

    const walk = core.ContentId.fromString("demo:clip.walk");
    _ = try game.spawn(walk, 0, 0);
    game.run(0, 100_000);

    const shown = try game.showing(gpa);
    defer gpa.free(shown);

    const clip = clipOf(walk).?;
    // Computed from the tick count and nothing else, by the same arithmetic the sandbox
    // would use to answer "which frame at tick 100,000?" — which is the question §4 says a
    // float answers only nearly.
    try testing.expectEqual(
        render2d.frameAt(100_000, clip.hold, clip.count, clip.loops),
        shown[0].animation.frame,
    );

    // Wrapping the elapsed count by the clip's duration is invisible, which is what makes
    // the wrap safe to do at all: the frame after 100,000 ticks is the same whether the
    // count kept climbing or came back round.
    try testing.expectEqual(
        @as(u32, @intCast(100_000 % clip.duration())),
        shown[0].animation.elapsed_ticks,
    );
}

test "a one-shot clip pins, and the pinned frame survives a reload" {
    const gpa = testing.allocator;

    const first = try Game.init(gpa);
    defer first.deinit();

    const oneshot = core.ContentId.fromString("demo:clip.oneshot");
    _ = try first.spawn(oneshot, 0, 0);
    // Three frames at nine ticks is 27; run well past the end of it.
    first.run(0, 500);

    const clip = clipOf(oneshot).?;
    const before = try first.showing(gpa);
    defer gpa.free(before);
    try testing.expectEqual(clip.count - 1, before[0].animation.frame);

    var saved: std.ArrayList(u8) = .empty;
    defer saved.deinit(gpa);
    try first.world.save(&saved);

    const second = try Game.init(gpa);
    defer second.deinit();
    _ = try second.world.load(saved.items, .default);

    const after = try second.showing(gpa);
    defer gpa.free(after);
    try expectSameFrames(before, after);

    // It stays pinned rather than wrapping once the saturated count is reloaded.
    second.run(500, 1_000);
    const later = try second.showing(gpa);
    defer gpa.free(later);
    try testing.expectEqual(clip.count - 1, later[0].animation.frame);
}

test "one cycle of a clip visits every one of its cells, in order, and wraps exactly" {
    // The join checked frame by frame rather than only at the ends: what a run of ticks
    // actually puts on screen is a run of *distinct* regions, and the last one is followed
    // by the first rather than by a repeat or a skip.
    const gpa = testing.allocator;

    const game = try Game.init(gpa);
    defer game.deinit();

    const walk = core.ContentId.fromString("demo:clip.walk");
    const clip = clipOf(walk).?;
    _ = try game.spawn(walk, 0, 0);

    var seen: [4]render2d.Region = undefined;
    var tick: u64 = 0;
    for (0..clip.count) |index| {
        // Land in the middle of each frame's hold, so this is testing the frame rather
        // than the boundary the unit tests already pin.
        const target = index * clip.hold + clip.hold / 2;
        while (tick < target) : (tick += 1) game.run(tick, 1);

        const shown = try game.showing(gpa);
        defer gpa.free(shown);
        try testing.expectEqual(@as(u32, @intCast(index)), shown[0].animation.frame);
        seen[index] = shown[0].region;
    }

    // Four different cells of the sheet, not four copies of one. A `cell` that ignored its
    // index would pass every assertion above this line.
    for (seen[0 .. clip.count - 1], 1..) |earlier, next| {
        try testing.expect(earlier.uv.x != seen[next].uv.x or earlier.uv.y != seen[next].uv.y);
    }

    // Row-major from `first`: this clip starts at cell 4, which is the start of row 1.
    try testing.expectEqual(sheet.cell(4, 4, 4).uv.x, seen[0].uv.x);
    try testing.expectEqual(sheet.cell(4, 4, 7).uv.x, seen[3].uv.x);

    // And it comes back round to the first cell rather than to a fifth one.
    while (tick < clip.duration()) : (tick += 1) game.run(tick, 1);
    const wrapped = try game.showing(gpa);
    defer gpa.free(wrapped);
    try testing.expectEqual(@as(u32, 0), wrapped[0].animation.frame);
    try testing.expectEqual(seen[0].uv.x, wrapped[0].region.uv.x);
}
