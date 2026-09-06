//! Which frame of a clip is showing, given how many ticks it has been playing.
//!
//! The whole of the engine's contribution to sprite animation, and it is deliberately this
//! small (`docs/design/sprite-animation.md` §3). A clip — a run of cells and how long each
//! is held — is **content**, and the state that plays one is a component the game owns.
//! What the engine supplies is the arithmetic in between, because that is mechanism and
//! because it is the one part that must not be got wrong.
//!
//! **Everything here is integer arithmetic over a tick count, and that is a decision.** The
//! obvious implementation accumulates a float delta and divides. It is refused on three
//! grounds (§4): it drifts, so two entities started together fall visibly out of step on a
//! long-lived idle animation; it does not survive a save, which reloads to a value that is
//! nearly the same and selects a frame that is sometimes not; and — the deciding one — it
//! makes "which frame at tick 700?" only *nearly* answerable, which is I9's promise broken
//! in the way that is right in nineteen tests out of twenty.
//!
//! These are pure functions of `elapsed`. There is no accumulator, no state, and nothing to
//! reset, so the same tick yields the same frame on every machine, in a replay, and after a
//! reload.
//!
//! **Why here and not in `core`.** No rendering dependency — this is integer division — but
//! it is about sprite sheets, which is a rendering idea, and `core` holds mechanisms with no
//! domain. The placement is about where a reader looks, and a reader looks next to `Region`,
//! whose `cell` turns the number these return into something drawable.
//!
//! Every number reaching these functions came out of a file, so a nonsensical one is a
//! content mistake rather than a bug: it produces a defined, boring answer instead of a
//! division by zero or a frame that does not exist.

const std = @import("std");
const core = @import("core");

/// Which frame is showing after `elapsed` ticks, when every frame is held the same length.
///
/// The common case, and the one a clip schema exposes: `hold` ticks per frame, `count`
/// frames, looping or not. At a 60 Hz fixed timestep a `frame_ticks` of 6 is a
/// ten-frames-per-second animation.
///
/// A non-looping clip **pins to its last frame** and stays there, which is what a one-shot
/// clip should do when whatever was going to replace it has not yet.
///
/// A `frame_ticks` or `frame_count` of zero yields frame 0 rather than dividing by it. Both
/// are content mistakes — a clip with no frames, or one whose frames are held for no time —
/// and both are reachable by a mod editing a record.
pub fn frameAt(elapsed: u32, frame_ticks: u32, frame_count: u32, looping: bool) u32 {
    if (frame_count == 0 or frame_ticks == 0) return 0;

    // `frame_ticks` is at least 1 here, so this cannot exceed `elapsed`.
    const played = elapsed / frame_ticks;
    return if (looping) played % frame_count else @min(played, frame_count - 1);
}

/// The same, when frames are held for different lengths.
///
/// `holds` is one entry per frame, in ticks, and is borrowed for the call only — nothing
/// here retains it.
///
/// **A frame held for zero ticks is never shown**, which falls out of the walk rather than
/// being special-cased: it advances the running total by nothing, so no tick lands on it.
/// That extends to pinning — a non-looping clip whose last entries are zero settles on the
/// last frame that is actually displayed, not on an entry no playthrough would have reached.
///
/// Agrees with `frameAt` exactly when every hold is equal, which is a property the tests
/// hold rather than a coincidence: two functions that disagree about the uniform case would
/// be a seam between "the clip has a hold list" and "the clip has a hold".
pub fn frameAtVarying(elapsed: u32, holds: []const u16, looping: bool) u32 {
    // The frame index is a `u32` everywhere else, so a longer list is out of the domain
    // rather than a content mistake — a caller built that slice, and `data`'s list limits
    // put nothing of the sort in a package.
    core.assert.debugOnly(
        holds.len <= std.math.maxInt(u32),
        "frameAtVarying: {d} frames exceeds the u32 frame index",
        .{holds.len},
    );
    if (holds.len == 0) return 0;

    // Widened: 65,535 ticks per frame across a long clip overflows a u32 easily, and the
    // total is what both the wrap and the pin are computed from.
    var total: u64 = 0;
    for (holds) |hold| total += hold;
    // Every frame held for no time: the clip has no duration, so nothing is ever showing
    // but frame 0. Same answer as `frameAt` gives a `frame_ticks` of zero.
    if (total == 0) return 0;

    // Looping wraps; not looping clamps to the animation's last tick, which makes pinning
    // the same walk rather than a separate case.
    const at: u64 = if (looping)
        @as(u64, elapsed) % total
    else
        @min(@as(u64, elapsed), total - 1);

    var elapsed_through: u64 = 0;
    for (holds, 0..) |hold, index| {
        elapsed_through += hold;
        if (at < elapsed_through) return @intCast(index);
    }
    // `at` is strictly less than `total` on both branches above, and `elapsed_through`
    // finishes equal to `total`, so the walk cannot fall through.
    core.assert.unreachableCode("frameAtVarying: tick {d} of {d} matched no frame", .{ at, total });
}

const testing = std.testing;

test "a clip starts on its first frame and holds each one for its full duration" {
    // Eight ticks a frame, four frames. Frame 0 covers ticks 0..7 inclusive, and the
    // transition is at 8 rather than at 7 or 9 — the off-by-one this test exists for.
    try testing.expectEqual(@as(u32, 0), frameAt(0, 8, 4, true));
    try testing.expectEqual(@as(u32, 0), frameAt(7, 8, 4, true));
    try testing.expectEqual(@as(u32, 1), frameAt(8, 8, 4, true));
    try testing.expectEqual(@as(u32, 1), frameAt(15, 8, 4, true));
    try testing.expectEqual(@as(u32, 2), frameAt(16, 8, 4, true));

    // The last frame gets the same eight ticks as the others. A clip that gave its final
    // frame one tick fewer is the classic version of this bug, and it looks fine.
    try testing.expectEqual(@as(u32, 3), frameAt(24, 8, 4, true));
    try testing.expectEqual(@as(u32, 3), frameAt(31, 8, 4, true));
}

test "a looping clip wraps exactly on the boundary" {
    // Tick 32 is the first tick of the second cycle, not the last of the first.
    try testing.expectEqual(@as(u32, 0), frameAt(32, 8, 4, true));
    try testing.expectEqual(@as(u32, 1), frameAt(40, 8, 4, true));

    // And it keeps wrapping, in phase, arbitrarily far out. This is the drift claim in
    // §4 stated as an assertion: an accumulator would be off by now.
    try testing.expectEqual(@as(u32, 0), frameAt(32_000, 8, 4, true));
    try testing.expectEqual(@as(u32, 3), frameAt(32_024, 8, 4, true));
    try testing.expectEqual(@as(u32, 3), frameAt(std.math.maxInt(u32) - 7, 8, 4, true));
}

test "a non-looping clip pins to its last frame" {
    try testing.expectEqual(@as(u32, 3), frameAt(31, 8, 4, false));
    try testing.expectEqual(@as(u32, 3), frameAt(32, 8, 4, false));
    try testing.expectEqual(@as(u32, 3), frameAt(std.math.maxInt(u32), 8, 4, false));

    // A single-frame clip is the degenerate case and is legal: it shows frame 0 forever
    // whether it loops or not.
    try testing.expectEqual(@as(u32, 0), frameAt(999, 8, 1, false));
    try testing.expectEqual(@as(u32, 0), frameAt(999, 8, 1, true));
}

test "a clip with no frames or no duration yields frame zero rather than dividing by it" {
    // Both reachable from a record a mod wrote, so neither may be asserted.
    try testing.expectEqual(@as(u32, 0), frameAt(100, 0, 4, true));
    try testing.expectEqual(@as(u32, 0), frameAt(100, 0, 4, false));
    try testing.expectEqual(@as(u32, 0), frameAt(100, 8, 0, true));
    try testing.expectEqual(@as(u32, 0), frameAt(100, 8, 0, false));
    try testing.expectEqual(@as(u32, 0), frameAt(0, 0, 0, true));
}

test "varying holds select the frame whose span contains the tick" {
    // A four-frame clip with a long pose in the middle: 4 + 12 + 4 + 4 = 24 ticks.
    const holds = [_]u16{ 4, 12, 4, 4 };

    try testing.expectEqual(@as(u32, 0), frameAtVarying(0, &holds, true));
    try testing.expectEqual(@as(u32, 0), frameAtVarying(3, &holds, true));
    try testing.expectEqual(@as(u32, 1), frameAtVarying(4, &holds, true));
    try testing.expectEqual(@as(u32, 1), frameAtVarying(15, &holds, true));
    try testing.expectEqual(@as(u32, 2), frameAtVarying(16, &holds, true));
    try testing.expectEqual(@as(u32, 3), frameAtVarying(20, &holds, true));
    try testing.expectEqual(@as(u32, 3), frameAtVarying(23, &holds, true));

    // Wrap on the boundary, same rule as the uniform case.
    try testing.expectEqual(@as(u32, 0), frameAtVarying(24, &holds, true));
    try testing.expectEqual(@as(u32, 1), frameAtVarying(24 * 1000 + 5, &holds, true));

    // Not looping: pin to the last frame, forever.
    try testing.expectEqual(@as(u32, 3), frameAtVarying(24, &holds, false));
    try testing.expectEqual(@as(u32, 3), frameAtVarying(std.math.maxInt(u32), &holds, false));
}

test "varying holds agree with the uniform case when every hold is equal" {
    // The seam this closes: a clip schema that grows a hold *list* later (§8, question 5)
    // must not quietly change what an existing uniform clip shows.
    const holds = [_]u16{ 8, 8, 8, 8 };
    var elapsed: u32 = 0;
    while (elapsed < 200) : (elapsed += 1) {
        try testing.expectEqual(frameAt(elapsed, 8, 4, true), frameAtVarying(elapsed, &holds, true));
        try testing.expectEqual(frameAt(elapsed, 8, 4, false), frameAtVarying(elapsed, &holds, false));
    }
}

test "a frame held for zero ticks is never shown" {
    // Not a special case in the code: a zero hold advances the running total by nothing,
    // so no tick can land inside it.
    const holds = [_]u16{ 4, 0, 4 };

    try testing.expectEqual(@as(u32, 0), frameAtVarying(0, &holds, true));
    try testing.expectEqual(@as(u32, 2), frameAtVarying(4, &holds, true));
    try testing.expectEqual(@as(u32, 2), frameAtVarying(7, &holds, true));
    try testing.expectEqual(@as(u32, 0), frameAtVarying(8, &holds, true));

    // Pinning follows it: the clip settles on frame 0, the last one actually displayed,
    // rather than on a trailing entry no playthrough would have reached.
    const trailing = [_]u16{ 4, 0, 0 };
    try testing.expectEqual(@as(u32, 0), frameAtVarying(4, &trailing, false));
    try testing.expectEqual(@as(u32, 0), frameAtVarying(1_000, &trailing, false));
}

test "an empty or motionless hold list yields frame zero" {
    const none = [_]u16{};
    try testing.expectEqual(@as(u32, 0), frameAtVarying(100, &none, true));
    try testing.expectEqual(@as(u32, 0), frameAtVarying(100, &none, false));

    // Every frame held for nothing: the same answer `frameAt` gives a zero `frame_ticks`.
    const still = [_]u16{ 0, 0, 0 };
    try testing.expectEqual(@as(u32, 0), frameAtVarying(100, &still, true));
    try testing.expectEqual(@as(u32, 0), frameAtVarying(100, &still, false));
}

test "a total duration past a u32 does not wrap the wrong way" {
    // 70,000 frames at 65,535 ticks each is about 4.6 billion ticks, which overflows the
    // u32 the elapsed count is kept in. The widened total is what keeps the wrap honest.
    const holds = try testing.allocator.alloc(u16, 70_000);
    defer testing.allocator.free(holds);
    @memset(holds, std.math.maxInt(u16));

    // Every tick a u32 can hold still lands inside the first cycle, so nothing wraps.
    try testing.expectEqual(@as(u32, 0), frameAtVarying(0, holds, true));
    try testing.expectEqual(@as(u32, 1), frameAtVarying(65_535, holds, true));
    const last_u32 = std.math.maxInt(u32);
    try testing.expectEqual(@as(u32, last_u32 / 65_535), frameAtVarying(last_u32, holds, true));
}
