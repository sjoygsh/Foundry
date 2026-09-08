//! `audio` as the public ABI publishes it.
//!
//! The mixer remains the owner of devices, sample data, voices and its callback thread. A mod
//! receives only a generational voice handle and controls a sound by content id. Every call is
//! game-thread work: the mixer queues the command and the callback never enters this boundary.
//!
//! Design: `docs/design/public-abi.md` §9 and `docs/design/audio.md` §10.

const std = @import("std");
const audio = @import("audio");
const core = @import("core");

const types = @import("types.zig");

const ContentId = types.ContentId;
const Result = types.Result;
const Voice = types.Voice;
const log = core.log.scoped(.abi);

/// A finite gain is accepted even when it is outside the nominal presentation range: the
/// mixer owns the final clamp and its existing behaviour is part of the audio contract. Pan
/// and pitch likewise retain the mixer policy (pan clamps to [-1,1], pitch to [1/64,64]); the
/// ABI's job here is to reject NaN and infinities before they reach that policy.
fn finite(value: f32) bool {
    return std.math.isFinite(value);
}

pub fn Of(comptime H: type) type {
    return struct {
        /// Starts the sound named by a content id. `out` is untouched on every refusal.
        pub fn audioPlay(
            id: ContentId,
            gain: f32,
            pan: f32,
            pitch: f32,
            looping: types.Bool,
            out: ?*Voice,
        ) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const mixer = h.mixer orelse return .unavailable;
            if (id.isNone() or !finite(gain) or !finite(pan) or !finite(pitch) or pitch <= 0) {
                return .invalid_argument;
            }
            const handle = mixer.play(id, .{
                .gain = gain,
                .pan = pan,
                .pitch = pitch,
                .looping = types.boolIn(looping),
            }) catch |err| return playFailure(err);
            dst.* = .wrap(handle);
            return .ok;
        }

        /// Stops one live voice. The mixer deliberately makes command methods void, but the
        /// public boundary resolves first so an invented or stale handle is diagnosable and
        /// never becomes an unobservable queued no-op.
        pub fn audioStop(handle: Voice) callconv(.c) Result {
            const h = H.current() orelse return .unavailable;
            const mixer = h.mixer orelse return .unavailable;
            const voice = handle.unwrap(audio.VoiceHandle);
            if (handle.isNone() or !mixer.isPlaying(voice)) return .invalid_handle;
            if (!mixer.stopChecked(voice)) return .limit;
            return .ok;
        }

        pub fn audioSetGain(handle: Voice, gain: f32) callconv(.c) Result {
            const h = H.current() orelse return .unavailable;
            const mixer = h.mixer orelse return .unavailable;
            if (!finite(gain)) return .invalid_argument;
            const voice = handle.unwrap(audio.VoiceHandle);
            if (handle.isNone() or !mixer.isPlaying(voice)) return .invalid_handle;
            if (!mixer.setGainChecked(voice, gain)) return .limit;
            return .ok;
        }

        pub fn audioSetPan(handle: Voice, pan: f32) callconv(.c) Result {
            const h = H.current() orelse return .unavailable;
            const mixer = h.mixer orelse return .unavailable;
            if (!finite(pan)) return .invalid_argument;
            const voice = handle.unwrap(audio.VoiceHandle);
            if (handle.isNone() or !mixer.isPlaying(voice)) return .invalid_handle;
            if (!mixer.setPanChecked(voice, pan)) return .limit;
            return .ok;
        }

        pub fn audioSetPitch(handle: Voice, pitch: f32) callconv(.c) Result {
            const h = H.current() orelse return .unavailable;
            const mixer = h.mixer orelse return .unavailable;
            if (!finite(pitch) or pitch <= 0) return .invalid_argument;
            const voice = handle.unwrap(audio.VoiceHandle);
            if (handle.isNone() or !mixer.isPlaying(voice)) return .invalid_handle;
            if (!mixer.setPitchChecked(voice, pitch)) return .limit;
            return .ok;
        }

        pub fn audioSetMasterGain(gain: f32) callconv(.c) Result {
            const h = H.current() orelse return .unavailable;
            const mixer = h.mixer orelse return .unavailable;
            if (!finite(gain)) return .invalid_argument;
            if (!mixer.setMasterGainChecked(gain)) return .limit;
            return .ok;
        }
    };
}

fn playFailure(err: anyerror) Result {
    return switch (err) {
        error.NoFreeVoice, error.CommandQueueFull => .limit,
        error.UnknownSound, error.AssetNotFound, error.SourceMissing => .not_found,
        error.WrongSchema, error.SourceRejected => .invalid_argument,
        error.NoLoader => .unavailable,
        error.UnsupportedVersion => .unsupported,
        error.InvalidAsset => .invalid_argument,
        error.LoadFailed => internalFailure(err),
        error.OutOfMemory => .out_of_memory,
        else => internalFailure(err),
    };
}

fn internalFailure(err: anyerror) Result {
    // Keep the unmapped engine error visible while staying below Zig's test runner rule that
    // an `err` line fails the test binary. The C caller still receives one stable result code.
    log.warn("unmapped audio ABI error: {s}", .{@errorName(err)});
    return .internal;
}

test "audio ABI reports mapping, invalid input, and an absent mixer" {
    const testing = std.testing;
    try testing.expectEqual(Result.limit, playFailure(error.NoFreeVoice));
    try testing.expectEqual(Result.not_found, playFailure(error.UnknownSound));
    try testing.expectEqual(Result.unavailable, playFailure(error.NoLoader));
    try testing.expectEqual(Result.unsupported, playFailure(error.UnsupportedVersion));
    try testing.expectEqual(Result.invalid_argument, playFailure(error.WrongSchema));
    try testing.expectEqual(Result.out_of_memory, playFailure(error.OutOfMemory));

    const host_mod = @import("host.zig");
    const test_engine = @import("test_engine.zig");
    const Host = host_mod.HostWithMixer(test_engine.TestEngine, audio.Mixer);
    const Calls = Of(Host);
    var host: Host = .{};
    host.bind();
    defer host.unbind();

    var voice: Voice = .{ .bits = 0xdecafbad };
    try testing.expectEqual(Result.unavailable, Calls.audioPlay(
        .none,
        1,
        0,
        1,
        0,
        &voice,
    ));
    // The absent-subsystem answer is intentional even for a malformed value: only pointer
    // arguments are host-independent, while the id is meaningful only to the mixer.
    try testing.expectEqual(Result.unavailable, Calls.audioStop(.none));
    try testing.expectEqual(@as(u64, 0xdecafbad), voice.bits);
}

test "audio ABI controls a null-device voice, then rejects its stale handle" {
    const testing = std.testing;
    const asset = @import("asset");
    const host_mod = @import("host.zig");
    const test_engine = @import("test_engine.zig");
    const platform = @import("platform");

    const NullPlatform = platform.null_backend.Platform;
    const TestMixer = audio.MixerOf(NullPlatform);
    const Host = host_mod.HostWithMixer(test_engine.TestEngine, TestMixer);
    const Calls = Of(Host);

    var engine = try test_engine.TestEngine.init(testing.allocator);
    defer engine.deinit();
    engine.settle();
    var plat = try NullPlatform.init(testing.allocator, .{});
    defer plat.deinit();
    const mixer = try TestMixer.init(testing.allocator, plat, &engine.assets, .{
        .voices = 1,
        .command_capacity = 8,
        .sample_rate = 48_000,
        .channels = 1,
        .buffer_frames = 1,
    });
    defer {
        mixer.shutdown();
        mixer.deinit();
    }

    var sound = try asset.Sound.alloc(testing.allocator, 1, 1, 48_000);
    sound.samples[0] = 0.25;
    const sound_handle = try mixer.insertSound(sound);
    const inner_voice = try mixer.playSound(sound_handle, .{});
    const public_voice = Voice.wrap(inner_voice);

    var host: Host = .{ .engine = &engine, .mixer = mixer };
    host.bind();
    defer host.unbind();

    try testing.expectEqual(Result.ok, Calls.audioSetGain(public_voice, 0.5));
    try testing.expectEqual(Result.ok, Calls.audioSetPan(public_voice, -1));
    try testing.expectEqual(Result.ok, Calls.audioSetPitch(public_voice, 2));
    try testing.expectEqual(Result.ok, Calls.audioStop(public_voice));

    // The null device is stepped synchronously, so the queued stop is consumed and the
    // mixer gives the slot back only after the game-thread update drains retirement.
    _ = try plat.stepAudio(mixer.device, 1);
    mixer.update();
    try testing.expectEqual(Result.invalid_handle, Calls.audioStop(public_voice));
}

test "audio ABI reports command-ring refusal instead of claiming success" {
    const testing = std.testing;
    const host_mod = @import("host.zig");
    const test_engine = @import("test_engine.zig");
    const platform = @import("platform");

    const NullPlatform = platform.null_backend.Platform;
    const TestMixer = audio.MixerOf(NullPlatform);
    const Host = host_mod.HostWithMixer(test_engine.TestEngine, TestMixer);
    const Calls = Of(Host);
    var engine = try test_engine.TestEngine.init(testing.allocator);
    defer engine.deinit();
    engine.settle();
    var plat = try NullPlatform.init(testing.allocator, .{});
    defer plat.deinit();
    const mixer = try TestMixer.init(testing.allocator, plat, &engine.assets, .{
        .voices = 1,
        .command_capacity = 2,
        .channels = 1,
        .buffer_frames = 1,
    });
    defer {
        mixer.shutdown();
        mixer.deinit();
    }
    var host: Host = .{ .engine = &engine, .mixer = mixer };
    host.bind();
    defer host.unbind();

    try testing.expectEqual(Result.ok, Calls.audioSetMasterGain(0.75));
    try testing.expectEqual(Result.ok, Calls.audioSetMasterGain(0.5));
    try testing.expectEqual(Result.limit, Calls.audioSetMasterGain(0.25));
}
