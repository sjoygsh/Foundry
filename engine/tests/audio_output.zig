//! Audio outputs through SDL3 on this machine (M45 Step 3, `docs/design/input.md` §5 and §13).
//!
//! **Not part of `zig build test`.** These start SDL's real audio subsystem and open the machine's
//! outputs, which a headless build machine may not have, so `zig build audio-output-test` runs
//! them on a desktop and `check` compiles them so they cannot rot between runs. The device plays
//! silence throughout: nothing is heard, whichever output it is moved to.
//!
//! What it proves is the backend's half of §5: the outputs listed, a running device moved to each
//! one and back to following the default by rebinding its stream, and the handle, `AudioInfo`
//! and the callback's count carrying on across every move. A loss needs a person to unplug
//! something, so it is the court's to prove (Step 8), on the null backend's script until then.

const std = @import("std");
const platform = @import("platform");

const testing = std.testing;
const Platform = platform.Platform;

/// A callback that writes silence and counts the frames it was asked for: the device's own
/// clock, as the mixer's `clock` counts it.
const Counter = struct {
    frames: std.atomic.Value(u64) = .init(0),
    channels: u8 = 2,

    fn fill(ctx: ?*anyopaque, out: []f32) void {
        const self: *Counter = @ptrCast(@alignCast(ctx.?));
        @memset(out, 0);
        _ = self.frames.fetchAdd(out.len / self.channels, .monotonic);
    }
};

/// Waits, pumping, until the device has pulled past `past` frames, at most about two seconds.
/// A move that left the stream unbound would stop the count, and this would say so.
fn waitPast(p: *Platform, counter: *const Counter, past: u64) !u64 {
    for (0..2000) |_| {
        p.pumpEvents();
        while (p.nextEvent()) |ev| if (ev == .audio_output_lost) return error.UnexpectedLoss;
        const now = counter.frames.load(.monotonic);
        if (now > past) return now;
        std.Io.sleep(testing.io, .fromNanoseconds(std.time.ns_per_ms), .awake) catch {};
    }
    return error.Timeout;
}

test "outputs are listed, and a silent device moves to each and back with its handle, info and clock" {
    const p = try Platform.init(testing.allocator, .{ .gamepads = false });
    defer p.deinit();

    var list: [platform.audio.max_outputs]platform.OutputInfo = undefined;
    const n = p.audioOutputs(&list);
    if (n == 0) {
        std.debug.print("audio-output-test: this machine lists no output\n", .{});
        return error.SkipZigTest;
    }
    var defaults: usize = 0;
    for (list[0..n]) |info| {
        try testing.expect(std.unicode.utf8ValidateSlice(info.name()));
        defaults += @intFromBool(info.is_default);
    }
    // Names are never printed, here as in the engine's log: only how many there are.
    std.debug.print("audio-output-test: {d} output(s), {d} marked default\n", .{ n, defaults });
    try testing.expect(defaults <= 1);

    var counter: Counter = .{};
    const device = try p.openAudio(.{ .callback = Counter.fill, .ctx = &counter });
    defer p.closeAudio(device);
    const info = p.audioInfo(device).?;
    counter.channels = info.channels;
    try testing.expect((try p.audioOutput(device)) == null);
    var frames = try waitPast(p, &counter, 0);

    var moved: usize = 0;
    for (list[0..n], 0..) |output, i| {
        p.setAudioOutput(device, output.id) catch |err| {
            // An output the OS lists but will not open, such as a sleeping AirPlay speaker, is
            // refused, and the device stays where it was: still running, still on the default.
            std.debug.print("audio-output-test: output {d} refused the move ({t})\n", .{ i + 1, err });
            try testing.expect((try p.audioOutput(device)) == null);
            frames = try waitPast(p, &counter, frames);
            continue;
        };
        moved += 1;
        try testing.expectEqual(output.id, (try p.audioOutput(device)).?);
        try testing.expectEqual(info, p.audioInfo(device).?);
        frames = try waitPast(p, &counter, frames);

        try p.setAudioOutput(device, null);
        try testing.expect((try p.audioOutput(device)) == null);
        try testing.expectEqual(info, p.audioInfo(device).?);
        frames = try waitPast(p, &counter, frames);
    }
    std.debug.print("audio-output-test: moved to {d} of {d}, {d} frames pulled\n", .{ moved, n, frames });
    // At least the output the default plays through must take the device.
    try testing.expect(moved >= 1);

    // An ID that names no output is refused, and the device does not move.
    try testing.expectError(error.InvalidAudioOutput, p.setAudioOutput(device, .fromInt(0x7fff_fff0)));
    try testing.expect((try p.audioOutput(device)) == null);

    // A closed handle is refused, and a device opened on an output reports it.
    var other: Counter = .{};
    const direct = try p.openAudio(.{ .callback = Counter.fill, .ctx = &other, .output = list[0].id });
    try testing.expectEqual(list[0].id, (try p.audioOutput(direct)).?);
    p.closeAudio(direct);
    try testing.expectError(error.InvalidAudioDevice, p.setAudioOutput(direct, null));
    try testing.expectError(error.InvalidAudioDevice, p.audioOutput(direct));
    _ = try waitPast(p, &counter, frames);
}
