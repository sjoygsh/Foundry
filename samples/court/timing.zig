//! Bounded whole-run costs copied from the existing profiler, never simulation input.
const std = @import("std");
const core = @import("core");
const log = core.log.scoped(.court);

pub const Costs = struct {
    const capacity = 4096;
    frame: [capacity]i64 = undefined,
    character: [capacity]i64 = undefined,
    skin: [capacity]i64 = undefined,
    len: usize = 0,
    character_len: usize = 0,
    skin_len: usize = 0,
    omitted: usize = 0,

    pub fn add(self: *Costs, recorder: *const core.profile.Recorder) void {
        const frame = recorder.latest() orelse return;
        if (self.len == capacity) {
            self.omitted += 1;
            return;
        }
        var character: i64 = 0;
        var skin: i64 = 0;
        var moved = false;
        var skinned = false;
        // Waiting for the compositor to hand back an image is presentation, not work: under
        // Wayland's FIFO it is the display's own interval (M26 Step 7), as the pacing sleep is.
        var presenting: i64 = 0;
        for (frame.spans) |span| {
            const name = recorder.nameOf(span.name);
            if (std.mem.eql(u8, name, "render.acquire")) presenting += span.durationNs();
            if (std.mem.eql(u8, name, "character")) {
                character += span.durationNs();
                moved = true;
            }
            if (std.mem.eql(u8, name, "render.skin")) {
                skin += span.durationNs();
                skinned = true;
            }
        }
        self.frame[self.len] = frame.total_ns - presenting;
        self.len += 1;
        if (moved) {
            self.character[self.character_len] = character;
            self.character_len += 1;
        }
        if (skinned) {
            self.skin[self.skin_len] = skin;
            self.skin_len += 1;
        }
    }

    pub fn report(self: *const Costs) void {
        var scratch: [capacity]i64 = undefined;
        for ([_]struct { name: []const u8, values: []const i64, budget: f64 }{
            .{ .name = "frame work (no pacing sleep or image wait; includes scripted replay)", .values = self.frame[0..self.len], .budget = 16.67 },
            .{ .name = "character (whole game tick and sound dispatch upper bound)", .values = self.character[0..self.character_len], .budget = 0.25 },
            .{ .name = "render.skin (one warden)", .values = self.skin[0..self.skin_len], .budget = 0.25 },
        }) |metric| {
            const summary = core.profile.summarise(metric.values, &scratch);
            log.info("cost {s}: {d} frames, median {d:.4}ms p95 {d:.4}ms; budget {d:.2}ms", .{
                metric.name, summary.count, ms(summary.median_ns), ms(summary.p95_ns), metric.budget,
            });
        }
        log.info("cost collection: {d} frames omitted at the {d}-frame bound", .{ self.omitted, capacity });
    }
};

fn ms(ns: i64) f64 {
    return @as(f64, @floatFromInt(ns)) / core.time.ns_per_ms;
}

test "court: costs collect all frames and sum tick spans without exceeding their bound" {
    const t = std.testing;
    var recorder = try core.profile.Recorder.init(t.allocator, .{ .history = 1 });
    defer recorder.deinit(t.allocator);
    recorder.beginFrame(0, .{ .ns = 0 });
    recorder.open("character", .{ .ns = 1 });
    recorder.close(.{ .ns = 4 });
    recorder.open("character", .{ .ns = 5 });
    recorder.close(.{ .ns = 9 });
    recorder.open("render.skin", .{ .ns = 10 });
    recorder.close(.{ .ns = 12 });
    recorder.open("render.acquire", .{ .ns = 13 });
    recorder.close(.{ .ns = 16 });
    recorder.endFrame(.{ .ns = 20 });
    var costs: Costs = .{};
    for (0..Costs.capacity + 1) |_| costs.add(&recorder);
    try t.expectEqual(Costs.capacity, costs.len);
    try t.expectEqual(@as(usize, 1), costs.omitted);
    try t.expectEqual(@as(i64, 17), costs.frame[0]); // 20, less the 3 ns image wait

    try t.expectEqual(@as(i64, 7), costs.character[0]);
    try t.expectEqual(@as(i64, 2), costs.skin[0]);
}
