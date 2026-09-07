//! Memory, per allocator (`debug-overlay.md` §5).
//!
//! **Only what somebody registered.** There is no global allocator in Foundry and therefore
//! no global to enumerate: the owner of an allocator is the only one who can answer for it,
//! and registering a counter is how an owner volunteers. A report that listed anything else
//! would be reporting a fiction.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ui = @import("ui");

const overlay = @import("overlay.zig");
const View = overlay.View;

pub const State = struct {
    pub fn describe(_: ?*anyopaque, view: *View) anyerror!void {
        const counters = view.frame.memory;
        if (counters.len == 0) {
            try view.line("no allocators registered (Engine.registerMemory)", .{});
        }

        var live: usize = 0;
        for (counters) |c| {
            live += c.live_bytes;
            try view.line("{s}  {d} KiB live  {d} KiB peak  {d} allocs", .{
                c.name,
                c.live_bytes / 1024,
                c.peak_bytes / 1024,
                c.allocations,
            });
            // Only when there is something to say. A counter's outstanding allocations are
            // interesting; a line of zeroes under every counter is not.
            if (c.failures != 0 or c.allocations != c.frees) {
                try view.line("    {d} live allocations, {d} failures", .{
                    c.allocations -| c.frees,
                    c.failures,
                });
            }
        }

        if (counters.len > 1) try view.line("{d} KiB live in total", .{live / 1024});

        // The arena is a different question from a counter: it holds nothing between frames,
        // so what it costs is its peak. **Zero is a real answer** — it means nothing in the
        // frame called `Engine.frameAllocator()` — and the panel says so rather than hiding
        // a number it does not like.
        try view.line("frame arena peak {d} B", .{view.frame.arena_peak});
    }
};

// -- tests -----------------------------------------------------------------------------

const testing = std.testing;

test "a registered counter is one row, and an empty registry says so" {
    var test_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer test_arena.deinit();
    var ctx = ui.Context.init(testing.allocator, overlay.testStyle());
    defer ctx.deinit();
    ctx.begin(.{}, .init(0, 0, 400, 300));
    var view: View = .{ .ui = &ctx, .arena = test_arena.allocator(), .frame = .{}, .sources = .{} };
    try State.describe(null, &view);
    ctx.end();

    try testing.expect(overlay.findText(&ctx, "no allocators registered"));
    try testing.expect(overlay.findText(&ctx, "frame arena peak 0 B"));
}

test "live, peak and outstanding allocations are reported separately" {
    var test_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer test_arena.deinit();
    var ctx = ui.Context.init(testing.allocator, overlay.testStyle());
    defer ctx.deinit();
    ctx.begin(.{}, .init(0, 0, 400, 300));

    const reports = [_]@import("app").MemoryReport{.{
        .handle = .{ .index = 0, .generation = 1 },
        .name = "engine",
        .live_bytes = 4096,
        .peak_bytes = 16384,
        .allocations = 10,
        .frees = 6,
        .failures = 1,
    }};
    var view: View = .{
        .ui = &ctx,
        .arena = test_arena.allocator(),
        .frame = .{ .memory = &reports, .arena_peak = 696 },
        .sources = .{},
    };
    try State.describe(null, &view);
    ctx.end();

    try testing.expect(overlay.findText(&ctx, "engine  4 KiB live  16 KiB peak  10 allocs"));
    try testing.expect(overlay.findText(&ctx, "4 live allocations, 1 failures"));
    try testing.expect(overlay.findText(&ctx, "frame arena peak 696 B"));
}
