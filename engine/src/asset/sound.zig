//! Decoded sounds, and what every decoder promises about them.
//!
//! The exact counterpart of `image.zig`, and the symmetry is the argument: one layout that
//! every decoder expands to, so the consumer that matters never switches on a format enum
//! in its inner loop (`docs/design/audio.md` §6).

const std = @import("std");

const Allocator = std.mem.Allocator;

/// A sound in memory, decoded and ready to be mixed.
///
/// **Always `f32`, interleaved, one to two channels.** The mixer reads `samples` directly
/// from the device thread, so anything it would have to convert per sample is converted
/// here instead, once, on the thread that is allowed to be slow.
///
/// **Nothing here is resampled.** `sample_rate` is the rate the file declared, and a voice
/// converts to the device's rate as it plays — which is the same operation as pitch, so
/// building it once serves both (ADR-0023, `audio.md` §5).
///
/// Every sample is finite. The decoder refuses a file containing a NaN or an infinity
/// rather than passing one on: a non-finite sample entering the mix accumulator silences
/// *everything* for the rest of the session, which is the least diagnosable failure audio
/// has to offer.
pub const Sound = struct {
    /// `frames * channels` long, interleaved: frame 0's channels, then frame 1's.
    samples: []f32,
    /// 1 or 2. Refused outside that at decode, because the pan model has no answer for a
    /// third channel and silently dropping it would be worse than the sentence.
    channels: u8,
    /// Frames per second, as the file declared it. Never zero.
    sample_rate: u32,

    /// Allocates uninitialised sample storage. The caller fills it.
    pub fn alloc(gpa: Allocator, frames: usize, channels: u8, sample_rate: u32) Allocator.Error!Sound {
        std.debug.assert(channels == 1 or channels == 2);
        std.debug.assert(sample_rate > 0);
        return .{
            .samples = try gpa.alloc(f32, frames * channels),
            .channels = channels,
            .sample_rate = sample_rate,
        };
    }

    pub fn deinit(self: *Sound, gpa: Allocator) void {
        gpa.free(self.samples);
        self.* = undefined;
    }

    pub fn frameCount(self: Sound) usize {
        return self.samples.len / self.channels;
    }

    pub fn byteSize(self: Sound) usize {
        return self.samples.len * @sizeOf(f32);
    }

    /// One frame's channels, in order.
    pub fn frame(self: Sound, index: usize) []f32 {
        std.debug.assert(index < self.frameCount());
        return self.samples[index * self.channels ..][0..self.channels];
    }

    /// How long this sound lasts, in whole nanoseconds, rounded down.
    ///
    /// For a game deciding when to do something *after* a sound, never for the mixer: a
    /// voice advances by frames mixed and never reads a clock (`audio.md` §8).
    pub fn durationNs(self: Sound) u64 {
        return @as(u64, self.frameCount()) * std.time.ns_per_s / self.sample_rate;
    }
};

const testing = std.testing;

test "a sound is tightly packed interleaved f32" {
    var sound = try Sound.alloc(testing.allocator, 3, 2, 48_000);
    defer sound.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 6), sound.samples.len);
    try testing.expectEqual(@as(usize, 3), sound.frameCount());
    try testing.expectEqual(@as(usize, 24), sound.byteSize());

    @memset(sound.samples, 0);
    sound.frame(2)[1] = 0.5;
    // The last channel of the last frame is the last sample: no padding anywhere.
    try testing.expectEqual(@as(f32, 0.5), sound.samples[sound.samples.len - 1]);
}

test "duration comes from frames and rate, not from sample count" {
    // Mono and stereo of the same length last the same time, which is the whole reason
    // `frameCount` exists rather than reading `samples.len`.
    var mono = try Sound.alloc(testing.allocator, 24_000, 1, 48_000);
    defer mono.deinit(testing.allocator);
    var stereo = try Sound.alloc(testing.allocator, 24_000, 2, 48_000);
    defer stereo.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, std.time.ns_per_s / 2), mono.durationNs());
    try testing.expectEqual(mono.durationNs(), stereo.durationNs());
}
